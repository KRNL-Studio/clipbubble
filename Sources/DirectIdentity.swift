import Foundation
import Security
import CryptoKit

struct DirectIdentity {
    let deviceId: String
    let identity: SecIdentity
    let der: Data
    let fingerprint: String

    private init(deviceId: String, key: SecKey, der: Data) throws {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData),
              let identity = Self.makeSecIdentity(certificate: certificate, key: key) else {
            throw IdentityError.invalidCertificate
        }
        self.deviceId = deviceId
        self.identity = identity
        self.der = der
        fingerprint = Self.fingerprint(of: der)
    }

    private static func makeSecIdentity(certificate: SecCertificate, key: SecKey) -> SecIdentity? {
        #if os(macOS)
        // SecIdentityCreate is exported by Security.framework on macOS 10.12+, but its header
        // declaration only became public in the macOS 26 SDK (absent on Xcode 16 / macos-15).
        typealias CreateFn = @convention(c) (CFAllocator?, SecCertificate, SecKey) -> Unmanaged<SecIdentity>?
        guard let framework = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY) else {
            return nil
        }
        defer { dlclose(framework) }
        guard let sym = dlsym(framework, "SecIdentityCreate") else { return nil }
        let create = unsafeBitCast(sym, to: CreateFn.self)
        return create(nil, certificate, key)?.takeRetainedValue()
        #else
        return SecIdentityCreate(nil, certificate, key)
        #endif
    }

    static func fingerprint(of der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    private static let lock = NSLock()
    private static var loaded: [String: DirectIdentity] = [:]

    static func shared(deviceId: String) throws -> DirectIdentity {
        try lock.withLock {
            let id = deviceId.lowercased()
            if let existing = loaded[id] { return existing }
            let identity = try loadOrCreate(deviceId: id)
            loaded[id] = identity
            return identity
        }
    }

    static func ephemeral(deviceId: String) throws -> DirectIdentity {
        try generate(deviceId: deviceId.lowercased()).identity
    }

    // Store the certificate and private key in one item so concurrent app/extension
    // launches cannot leave a key without its certificate, or pin different certificates.
    private struct Credential: Codable {
        let privateKey: Data
        let certificate: Data

        func makeIdentity(deviceId: String) throws -> DirectIdentity {
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                kSecAttrKeySizeInBits as String: 256
            ]
            var error: Unmanaged<CFError>?
            guard let key = SecKeyCreateWithData(privateKey as CFData, attributes as CFDictionary, &error) else {
                throw error?.takeRetainedValue() as Error? ?? IdentityError.keyUnavailable
            }
            return try DirectIdentity(deviceId: deviceId, key: key, der: certificate)
        }
    }

    private static func generate(deviceId: String) throws -> (identity: DirectIdentity, credential: Credential) {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error?.takeRetainedValue() as Error? ?? IdentityError.keyUnavailable
        }
        let der = try DirectCertificate.make(deviceId: deviceId, key: key)
        let identity = try DirectIdentity(deviceId: deviceId, key: key, der: der)
        guard let privateKey = SecKeyCopyExternalRepresentation(key, &error) else {
            throw error?.takeRetainedValue() as Error? ?? IdentityError.keyUnavailable
        }
        return (identity, Credential(privateKey: privateKey as Data, certificate: der))
    }

    private static func keychainQuery(deviceId: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "studio.krnl.clipbubble.direct-identity.v2",
            kSecAttrAccount as String: deviceId,
            kSecUseDataProtectionKeychain as String: dataProtection
        ]
        #if os(iOS)
        query[kSecAttrAccessGroup as String] = Platform.group
        #endif
        return query
    }

    // Also used by the macOS tests to exercise a fresh Keychain read instead of the cache.
    static func loadOrCreate(deviceId: String) throws -> DirectIdentity {
        do {
            return try loadOrCreate(deviceId: deviceId, dataProtection: true)
        } catch IdentityError.keychain(errSecMissingEntitlement) {
            #if os(macOS)
            // Developer ID/ad-hoc builds without a provisioned App ID use the login Keychain.
            return try withoutLegacyKeychainInteraction {
                try loadOrCreate(deviceId: deviceId, dataProtection: false)
            }
            #else
            throw IdentityError.keychain(errSecMissingEntitlement)
            #endif
        }
    }

    private static func loadOrCreate(deviceId: String, dataProtection: Bool) throws -> DirectIdentity {
        let query = keychainQuery(deviceId: deviceId, dataProtection: dataProtection)
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        func read() throws -> DirectIdentity {
            var result: CFTypeRef?
            let status = SecItemCopyMatching(lookup as CFDictionary, &result)
            guard status == errSecSuccess else { throw IdentityError.keychain(status) }
            guard let data = result as? Data else { throw IdentityError.invalidCertificate }
            return try JSONDecoder().decode(Credential.self, from: data).makeIdentity(deviceId: deviceId)
        }
        do {
            return try read()
        } catch IdentityError.keychain(errSecItemNotFound) {
            let (identity, credential) = try generate(deviceId: deviceId)
            var item = query
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecValueData as String] = try JSONEncoder().encode(credential)
            let status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecDuplicateItem { return try read() }
            guard status == errSecSuccess else { throw IdentityError.keychain(status) }
            return identity
        }
    }

    #if os(macOS)
    private static let legacyKeychainLock = NSLock()

    /// SecItem's authentication UI options apply to the data-protection Keychain.
    /// These public legacy APIs are the interaction control for file-based Keychains.
    /// Resolve them only on the fallback path and fail closed if they are unavailable.
    private static func withoutLegacyKeychainInteraction<T>(_ action: () throws -> T) throws -> T {
        try legacyKeychainLock.withLock {
            guard let framework = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY) else {
                throw IdentityError.keychain(errSecNotAvailable)
            }
            defer { dlclose(framework) }
            guard let get = dlsym(framework, "SecKeychainGetUserInteractionAllowed"),
                  let set = dlsym(framework, "SecKeychainSetUserInteractionAllowed") else {
                throw IdentityError.keychain(errSecNotAvailable)
            }
            let getInteraction = unsafeBitCast(get, to: (@convention(c) (UnsafeMutablePointer<DarwinBoolean>) -> OSStatus).self)
            let setInteraction = unsafeBitCast(set, to: (@convention(c) (Bool) -> OSStatus).self)
            var previous = DarwinBoolean(false)
            let status = getInteraction(&previous)
            guard status == errSecSuccess else { throw IdentityError.keychain(status) }
            if !previous.boolValue { return try action() }
            let disabled = setInteraction(false)
            guard disabled == errSecSuccess else { throw IdentityError.keychain(disabled) }
            defer { _ = setInteraction(true) }
            return try action()
        }
    }

    static func removeTestIdentity(deviceId: String) -> Bool {
        lock.withLock {
            loaded[deviceId] = nil
            let protected = SecItemDelete(keychainQuery(deviceId: deviceId, dataProtection: true) as CFDictionary)
            let legacy = try? withoutLegacyKeychainInteraction {
                SecItemDelete(keychainQuery(deviceId: deviceId, dataProtection: false) as CFDictionary)
            }
            return [errSecSuccess, errSecItemNotFound, errSecMissingEntitlement].contains(protected)
                && (legacy == errSecSuccess || legacy == errSecItemNotFound)
        }
    }
    #endif

    private enum IdentityError: LocalizedError {
        case keyUnavailable, invalidCertificate, keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .keyUnavailable: return "The Direct Sync private key is unavailable."
            case .invalidCertificate: return "The Direct Sync certificate could not be loaded."
            case .keychain(let status):
                return "Direct Sync Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? String(status))"
            }
        }
    }
}

enum DirectSAS {
    static func code(localFP: String, peerFP: String) -> String {
        let first = min(localFP, peerFP), last = max(localFP, peerFP)
        let digest = SHA256.hash(data: Data("clipbubble-pair-v2:\(first):\(last)".utf8))
        let number = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return String(format: "%06u", number % 1_000_000)
    }

    static func formatted(localFP: String, peerFP: String) -> String {
        let digits = code(localFP: localFP, peerFP: peerFP)
        return "\(digits.prefix(3)) \(digits.suffix(3))"
    }
}

private enum DirectCertificate {
    static func make(deviceId: String, key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let publicKey = SecKeyCopyPublicKey(key),
              let point = SecKeyCopyExternalRepresentation(publicKey, &error) else {
            throw error?.takeRetainedValue() as Error? ?? CertificateError.publicKey
        }
        let signatureAlgorithm = DER.sequence(DER.oid([0x2a, 0x86, 0x48, 0xce, 0x3d, 4, 3, 2])) // ecdsa-with-SHA256
        let curveAlgorithm = DER.sequence(
            DER.oid([0x2a, 0x86, 0x48, 0xce, 0x3d, 2, 1]), // id-ecPublicKey
            DER.oid([0x2a, 0x86, 0x48, 0xce, 0x3d, 3, 1, 7]) // prime256v1
        )
        let name = DER.sequence(DER.value(0x31, DER.sequence(
            DER.oid([0x55, 4, 3]), DER.value(0x0c, Data("clipbubble-\(deviceId)".utf8))
        )))
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let validity = DER.sequence(
            DER.time(now.addingTimeInterval(-86_400), calendar: calendar),
            DER.time(calendar.date(byAdding: .year, value: 20, to: now)!, calendar: calendar)
        )
        let extensions = DER.value(0xa3, DER.sequence(
            DER.certificateExtension(19, critical: true, DER.sequence()), // CA defaults to FALSE
            DER.certificateExtension(15, critical: true, DER.bits(Data([0x80]), unused: 7)), // digitalSignature
            DER.certificateExtension(37, critical: false, DER.sequence(
                DER.oid([0x2b, 6, 1, 5, 5, 7, 3, 1]), // serverAuth
                DER.oid([0x2b, 6, 1, 5, 5, 7, 3, 2]) // clientAuth
            ))
        ))
        var serial = Data(count: 16)
        let status = serial.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw CertificateError.random(status) }
        // Positive and nonzero with a canonical DER INTEGER representation.
        serial[0] = (serial[0] & 0x7f) | 0x40
        let tbs = DER.sequence(
            DER.value(0xa0, DER.value(2, Data([2]))), DER.value(2, serial),
            signatureAlgorithm, name, validity, name, DER.sequence(curveAlgorithm, DER.bits(point as Data)), extensions
        )
        guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &error) else {
            throw error?.takeRetainedValue() as Error? ?? CertificateError.signature
        }
        return DER.sequence(tbs, signatureAlgorithm, DER.bits(signature as Data))
    }

    private enum CertificateError: Error {
        case publicKey, signature, random(OSStatus)
    }
}

private enum DER {
    static func value(_ tag: UInt8, _ bytes: Data) -> Data {
        var size = bytes.count
        var header = Data([tag])
        if size < 128 {
            header.append(UInt8(size))
        } else {
            var length: [UInt8] = []
            while size > 0 {
                length.append(UInt8(truncatingIfNeeded: size))
                size >>= 8
            }
            header.append(0x80 | UInt8(length.count))
            header.append(contentsOf: length.reversed())
        }
        header.append(bytes)
        return header
    }

    static func sequence(_ elements: Data...) -> Data {
        value(0x30, elements.reduce(into: Data()) { $0.append($1) })
    }

    static func oid(_ bytes: [UInt8]) -> Data { value(6, Data(bytes)) }

    static func bits(_ bytes: Data, unused: UInt8 = 0) -> Data { value(3, Data([unused]) + bytes) }

    static func certificateExtension(_ id: UInt8, critical: Bool, _ content: Data) -> Data {
        sequence(oid([0x55, 0x1d, id]), critical ? value(1, Data([0xff])) : Data(), value(4, content))
    }

    static func time(_ date: Date, calendar: Calendar) -> Data {
        let generalized = calendar.component(.year, from: date) >= 2050
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = generalized ? "yyyyMMddHHmmss'Z'" : "yyMMddHHmmss'Z'"
        return value(generalized ? 0x18 : 0x17, Data(formatter.string(from: date).utf8))
    }
}
