using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace ClipBubble;

sealed class DirectIdentity : IDisposable
{
    public string Id { get; }
    public string Fingerprint { get; }
    internal X509Certificate2 Certificate { get; }

    DirectIdentity(string id, X509Certificate2 certificate)
    {
        if (!certificate.HasPrivateKey || certificate.GetNameInfo(X509NameType.SimpleName, false) != "clipbubble-" + id)
        {
            certificate.Dispose();
            throw new CryptographicException("The Direct identity does not match this device.");
        }
        Id = id;
        Certificate = certificate;
        Fingerprint = Store.Sha(certificate.RawData);
    }

    static X509Certificate2 Generate(string id)
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var request = new CertificateRequest("CN=clipbubble-" + id, key, HashAlgorithmName.SHA256);
        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
        request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature, true));
        request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(new OidCollection
        {
            new Oid("1.3.6.1.5.5.7.3.1"), new Oid("1.3.6.1.5.5.7.3.2"),
        }, false));
        var now = DateTimeOffset.UtcNow;
        return request.CreateSelfSigned(now.AddHours(-24), now.AddYears(20));
    }

    static X509Certificate2 Import(byte[] pfx, bool persistent)
    {
        var flags = X509KeyStorageFlags.UserKeySet | X509KeyStorageFlags.Exportable;
        if (persistent) flags |= X509KeyStorageFlags.PersistKeySet;
#if NETFRAMEWORK
        return new X509Certificate2(pfx, (string?)null, flags);
#else
        return X509CertificateLoader.LoadPkcs12(pfx, null, flags);
#endif
    }

    public static DirectIdentity Open(string directory, string device)
    {
        var id = Guid.Parse(device).ToString("D");
        var path = Path.Combine(directory, "direct-identity.pfx");
        if (!File.Exists(path))
        {
            Directory.CreateDirectory(directory);
            using var cert = Generate(id);
            var pfx = cert.Export(X509ContentType.Pkcs12);
            var tmp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                using (var file = CreatePrivate(tmp)) file.Write(pfx, 0, pfx.Length);
                // Another process using this profile may have won the first-use race.
                try { File.Move(tmp, path); }
                catch (IOException) when (File.Exists(path)) { }
            }
            finally { File.Delete(tmp); }
        }
        return new DirectIdentity(id, Import(File.ReadAllBytes(path), persistent: true));
    }

    static FileStream CreatePrivate(string path)
    {
#if !NETFRAMEWORK
        if (!OperatingSystem.IsWindows())
            return new FileStream(path, new FileStreamOptions
            {
                Mode = FileMode.CreateNew, Access = FileAccess.Write,
                UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite,
            });
#endif
        using var identity = System.Security.Principal.WindowsIdentity.GetCurrent();
        var acl = new System.Security.AccessControl.FileSecurity();
        acl.SetAccessRuleProtection(true, false);
        acl.AddAccessRule(new System.Security.AccessControl.FileSystemAccessRule(identity.User!,
            System.Security.AccessControl.FileSystemRights.FullControl, System.Security.AccessControl.AccessControlType.Allow));
#if NETFRAMEWORK
        return new FileStream(path, FileMode.CreateNew, System.Security.AccessControl.FileSystemRights.Write, FileShare.None, 4096, FileOptions.None, acl);
#else
        return System.IO.FileSystemAclExtensions.Create(new FileInfo(path), FileMode.CreateNew,
            System.Security.AccessControl.FileSystemRights.Write, FileShare.None, 4096, FileOptions.None, acl);
#endif
    }

    internal static DirectIdentity Ephemeral(string device)
    {
        var id = Guid.Parse(device).ToString("D");
        using var cert = Generate(id);
        // SChannel needs a key it can open through the user key provider. The test import is
        // temporary and is released when the certificate is disposed.
        return new DirectIdentity(id, Import(cert.Export(X509ContentType.Pkcs12), persistent: false));
    }

    public void Dispose() => Certificate.Dispose();
}

static class DirectSas
{
    public static string Code(string localFp, string peerFp)
    {
        var (lo, hi) = string.CompareOrdinal(localFp, peerFp) < 0 ? (localFp, peerFp) : (peerFp, localFp);
        using var sha = SHA256.Create();
        var d = sha.ComputeHash(Encoding.UTF8.GetBytes("clipbubble-pair-v2:" + lo + ":" + hi));
        uint number = (uint)d[0] << 24 | (uint)d[1] << 16 | (uint)d[2] << 8 | d[3];
        return (number % 1_000_000).ToString("D6", CultureInfo.InvariantCulture);
    }

    public static string Formatted(string localFp, string peerFp) => Code(localFp, peerFp).Insert(3, " ");
}

sealed record DirectPeer
{
    public string Id { get; init; } = "";
    public string Name { get; init; } = "";
    public string Os { get; init; } = "";
    public string Fingerprint { get; init; } = "";
    public string[] Addresses { get; init; } = Array.Empty<string>();
    public int Port { get; init; }
    public string Alias() => DirectPeers.Prefix + Id;

    internal bool Valid => DirectWire.DeviceId(Id) && DirectWire.Hex(Fingerprint, 64)
        && !string.IsNullOrWhiteSpace(Name) && DirectWire.KnownOs(Os);
}

sealed class DirectPeers
{
    public const string Prefix = "direct:";
    readonly string path;
    readonly object gate = new();
    DirectPeer[] peers;

    public event Action? Changed;

    public DirectPeers(string directory)
    {
        path = Path.Combine(directory, "direct-peers.json");
        peers = File.Exists(path) ? Store.Json.Deserialize<DirectPeer[]>(Store.ReadText(path))
            ?? Array.Empty<DirectPeer>() : Array.Empty<DirectPeer>();
        peers = peers.Where(p => p is { Valid: true }).ToArray();
    }

    public DirectPeer[] All() { lock (gate) return peers.Select(Copy).ToArray(); }
    public DirectPeer? ById(string id) { lock (gate) return Find(p => p.Id == id); }
    public DirectPeer? ByFingerprint(string fp) { lock (gate) return Find(p => p.Fingerprint == fp); }

    DirectPeer? Find(Func<DirectPeer, bool> match) => peers.FirstOrDefault(match) is { } peer ? Copy(peer) : null;
    static DirectPeer Copy(DirectPeer peer) => peer with { Addresses = peer.Addresses?.ToArray() ?? Array.Empty<string>() };

    public void Save(DirectPeer peer)
    {
        if (!peer.Valid) throw new ArgumentException("Invalid Direct peer.", nameof(peer));
        lock (gate) Write(peers.Where(p => p.Id != peer.Id && p.Fingerprint != peer.Fingerprint).Append(Copy(peer)).ToArray());
        Changed?.Invoke();
    }

    public void Remove(string id)
    {
        lock (gate)
        {
            var next = peers.Where(p => p.Id != id).ToArray();
            if (next.Length == peers.Length) return;
            Write(next);
        }
        Changed?.Invoke();
    }

    void Write(DirectPeer[] next)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        Store.WriteAtomic(path, Encoding.UTF8.GetBytes(Store.Json.Serialize(next)));
        peers = next;
    }
}

sealed class DirectException(string kind, string message) : IOException(message)
{
    public string Kind { get; } = kind;
}

static class DirectWire
{
    public const int Version = 2;
    public const int TimeoutMs = 15_000;
    public const int ApprovalMs = 90_000;
    public const string Os = "windows";
    const int MaxLine = 4096;
    static readonly UTF8Encoding Utf8 = new(false, true);

    public static string Field(Dictionary<string, object?> fields, string key) =>
        fields.TryGetValue(key, out var v) && v is string s ? s : "";

    public static bool Hex(string value, int length) => value.Length == length
        && value.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');
    public static bool DeviceId(string value) => Guid.TryParseExact(value, "D", out var id) && value == id.ToString("D");
    public static bool KnownOs(string os) => os is "macos" or "ios" or "linux" or "windows";
    public static bool V2(Dictionary<string, object?> fields) =>
        fields.TryGetValue("v", out var v) && (v is int i && i == Version || v is double d && d == Version);
    public static bool Ok(Dictionary<string, object?> fields) => fields.TryGetValue("ok", out var v) && v is true;

    public static bool ConnectionError(Exception e) =>
        e is IOException or SocketException or InvalidOperationException or AuthenticationException
            or OperationCanceledException or ArgumentException or CryptographicException;

    public static async Task<Dictionary<string, object?>> Read(Stream stream)
    {
        // Read exactly to the newline. The next byte can already belong to the sync frame codec.
        var bytes = new byte[MaxLine];
        var b = new byte[1];
        for (var n = 0; n <= MaxLine; n++)
        {
            if (await stream.ReadAsync(b, 0, 1).ConfigureAwait(false) == 0) throw new EndOfStreamException();
            if (b[0] == 10)
            {
                try
                {
                    return Store.Json.Deserialize<Dictionary<string, object?>>(Utf8.GetString(bytes, 0, n))
                        ?? throw new IOException("Missing Direct preamble.");
                }
                catch (Exception e) when (e is ArgumentException or InvalidOperationException
#if !NETFRAMEWORK
                    or System.Text.Json.JsonException
#endif
                ) { throw new IOException("Invalid Direct preamble.", e); }
            }
            if (n < MaxLine) bytes[n] = b[0];
        }
        throw new IOException("Direct preamble is too long.");
    }

    public static Task Write(Stream stream, Dictionary<string, object?> fields)
    {
        var data = Utf8.GetBytes(Store.Json.Serialize(fields) + "\n");
        if (data.Length > MaxLine + 1) throw new IOException("Direct preamble is too long.");
        return stream.WriteAsync(data, 0, data.Length);
    }

    public static Dictionary<string, object?> Reply(string? error = null) => error == null
        ? new() { ["ok"] = true } : new() { ["ok"] = false, ["error"] = error };

    public static DirectPeer Peer(Dictionary<string, object?> fields, string fingerprint) => new()
    {
        Id = Field(fields, "device"), Name = Field(fields, "name"), Os = Field(fields, "os"), Fingerprint = fingerprint,
    };
}

/// Owns the transport across the preamble and the frame session. Closing the socket wakes blocked I/O.
sealed class DirectConnection : IDisposable
{
    readonly TcpClient client;
#if NETFRAMEWORK
    readonly DirectHandshakeStream handshake;
#endif
    public SslStream Stream { get; }
    public string Fingerprint { get; private set; } = "";

    public DirectConnection(TcpClient client, DirectIdentity identity)
    {
        this.client = client;
        Stream transport = client.GetStream();
#if NETFRAMEWORK
        transport = handshake = new DirectHandshakeStream(transport);
#endif
        Stream = new SslStream(transport, false, (_, cert, _, _) =>
        {
            if (cert == null) return false;
            Fingerprint = Store.Sha(cert.GetRawCertData());
            return true;
        }, (_, _, _, _, _) => identity.Certificate);
    }

    public async Task Authenticate(DirectIdentity identity, string? host)
    {
#if NETFRAMEWORK
        handshake.ReadServerHello = host != null;
#endif
        if (host == null)
            await Stream.AuthenticateAsServerAsync(identity.Certificate, clientCertificateRequired: true, checkCertificateRevocation: false).ConfigureAwait(false);
        else
            await Stream.AuthenticateAsClientAsync(host, new X509CertificateCollection { identity.Certificate },
                SslProtocols.None, checkCertificateRevocation: false).ConfigureAwait(false);
        // None uses the OS policy, so explicitly reject a connection below the protocol minimum.
        // TLS 1.3 has value 12288 even on framework versions whose reference enums omit it.
        if (!Stream.IsMutuallyAuthenticated || Fingerprint.Length == 0 ||
            Stream.SslProtocol != SslProtocols.Tls12 && (int)Stream.SslProtocol != 12288)
            throw new AuthenticationException("Direct requires mutually authenticated TLS 1.2 or newer.");
        if (Stream.SslProtocol == SslProtocols.Tls12 &&
#if NETFRAMEWORK
            !handshake.IsEcdsaGcm
#else
            Stream.NegotiatedCipherSuite is not (TlsCipherSuite.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256 or TlsCipherSuite.TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384)
#endif
        )
            throw new AuthenticationException("Direct TLS 1.2 requires ECDHE-ECDSA with AES-GCM.");
#if NETFRAMEWORK
        handshake.Finish();
#endif
    }

    public void Abort() => client.Close();

    public void Dispose()
    {
        Abort();
        Stream.Dispose();
    }
}

/// .NET Framework exposes the TLS version but has no NegotiatedCipherSuite property.
/// Inspect the suite selected in the plaintext ServerHello after SChannel authenticates it.
/// This has no role in certificate validation and never retains application data.
sealed class DirectServerHello
{
    // 73 bytes to reach the suite even with a 32-byte session ID. Allow a separate
    // five-byte record header for each of those bytes in a maximally fragmented hello.
    readonly byte[] prefix = new byte[73 * 6];
    int length;

    public void Append(byte[] bytes, int offset, int count)
    {
        count = Math.Min(prefix.Length - length, count);
        Array.Copy(bytes, offset, prefix, length, count);
        length += count;
    }

    public bool IsEcdsaGcm
    {
        get
        {
            var message = new byte[73];
            var used = 0;
            for (var offset = 0; offset + 5 < length && used < message.Length;)
            {
                if (prefix[offset] != 22) break; // TLS handshake record
                var recordSize = prefix[offset + 3] * 256 + prefix[offset + 4];
                offset += 5;
                var n = Math.Min(recordSize, Math.Min(length - offset, message.Length - used));
                Array.Copy(prefix, offset, message, used, n);
                used += n;
                offset += n;
            }
            if (used < 41 || message[0] != 2 || message[4] != 3 || message[5] != 3) return false;
            // Handshake header (4), version (2), random (32), then a length-prefixed session ID.
            var sessionSize = message[38];
            var suite = 39 + sessionSize;
            return sessionSize <= 32 && used >= suite + 2 && message[suite] == 0xc0
                && message[suite + 1] is 0x2b or 0x2c;
        }
    }
}

#if NETFRAMEWORK
sealed class DirectHandshakeStream(Stream transport) : Stream
{
    DirectServerHello? hello = new();
    public bool ReadServerHello { get; set; }
    public bool IsEcdsaGcm => hello?.IsEcdsaGcm == true;
    public void Finish() => hello = null;

    public override int Read(byte[] buffer, int offset, int count)
    {
        var n = transport.Read(buffer, offset, count);
        if (ReadServerHello) hello?.Append(buffer, offset, n);
        return n;
    }

    public override void Write(byte[] buffer, int offset, int count)
    {
        if (!ReadServerHello) hello?.Append(buffer, offset, count);
        transport.Write(buffer, offset, count);
    }

    public override async Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken token)
    {
        var n = await transport.ReadAsync(buffer, offset, count, token).ConfigureAwait(false);
        if (ReadServerHello) hello?.Append(buffer, offset, n);
        return n;
    }

    public override Task WriteAsync(byte[] buffer, int offset, int count, CancellationToken token)
    {
        if (!ReadServerHello) hello?.Append(buffer, offset, count);
        return transport.WriteAsync(buffer, offset, count, token);
    }

    public override IAsyncResult BeginRead(byte[] buffer, int offset, int count, AsyncCallback? callback, object? state) =>
        Begin(ReadAsync(buffer, offset, count, default), callback, state);

    public override IAsyncResult BeginWrite(byte[] buffer, int offset, int count, AsyncCallback? callback, object? state) =>
        Begin(Written(buffer, offset, count), callback, state);

    async Task<bool> Written(byte[] buffer, int offset, int count)
    {
        await WriteAsync(buffer, offset, count, default).ConfigureAwait(false);
        return true;
    }

    static IAsyncResult Begin<T>(Task<T> task, AsyncCallback? callback, object? state)
    {
        var result = new TaskCompletionSource<T>(state);
        _ = task.ContinueWith(t =>
        {
            if (t.IsCanceled) result.SetCanceled();
            else if (t.Exception is { } failure) result.SetException(failure.InnerExceptions);
            else result.SetResult(t.Result);
            callback?.Invoke(result.Task);
        }, TaskScheduler.Default);
        return result.Task;
    }

    public override int EndRead(IAsyncResult result) => ((Task<int>)result).GetAwaiter().GetResult();
    public override void EndWrite(IAsyncResult result) => ((Task)result).GetAwaiter().GetResult();
    public override bool CanRead => transport.CanRead;
    public override bool CanWrite => transport.CanWrite;
    public override bool CanSeek => false;
    public override long Length => throw new NotSupportedException();
    public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Flush() => transport.Flush();

    protected override void Dispose(bool disposing)
    {
        if (disposing) transport.Dispose();
        base.Dispose(disposing);
    }
}
#endif

sealed record DirectPairRequest(string Name, string Os, string Code);

sealed class DirectServer : IDisposable
{
    public const int DefaultPort = 47822;
    readonly DirectIdentity identity;
    readonly DirectPeers peers;
    readonly Func<string> name;
    readonly Action<DirectPeer, DirectConnection> sync;
    readonly TcpListener listener;
    readonly CancellationTokenSource stop = new();
    readonly object gate = new();
    readonly Queue<long> pairTimes = new();
    string? qrToken;
    long qrIssued;
    int qrWrong;
    bool disposed;

    public Func<DirectPairRequest, CancellationToken, Task<bool>>? Approve { get; set; }
    public int Port { get; }

    public DirectServer(DirectIdentity identity, DirectPeers peers, Func<string> name,
        Action<DirectPeer, DirectConnection> sync, int preferredPort = DefaultPort)
    {
        this.identity = identity;
        this.peers = peers;
        this.name = name;
        this.sync = sync;
        try { listener = Listen(preferredPort); }
        catch (SocketException) when (preferredPort != 0) { listener = Listen(0); }
        Port = ((IPEndPoint)listener.LocalEndpoint).Port;
        _ = Accept(stop.Token);
    }

    static TcpListener Listen(int port)
    {
        var dualMode = Socket.OSSupportsIPv6;
        var listener = new TcpListener(dualMode ? IPAddress.IPv6Any : IPAddress.Any, port);
        try
        {
            if (dualMode) listener.Server.DualMode = true;
            listener.Start();
            return listener;
        }
        catch { listener.Stop(); throw; }
    }

    async Task Accept(CancellationToken stopped)
    {
        try
        {
            while (!stopped.IsCancellationRequested)
            {
                var client = await listener.AcceptTcpClientAsync().ConfigureAwait(false);
                _ = Serve(client, stopped);
            }
        }
        catch (Exception e) when (DirectWire.ConnectionError(e))
        {
            if (!stopped.IsCancellationRequested) SyncLog.Write("Direct listener: " + e.Message);
        }
    }

    async Task Serve(TcpClient client, CancellationToken stopped)
    {
        DirectConnection? connection = null;
        var handedOff = false;
        try
        {
            connection = new DirectConnection(client, identity);
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(stopped);
            deadline.CancelAfter(DirectWire.TimeoutMs);
            using var abort = deadline.Token.Register(connection.Abort);
            await connection.Authenticate(identity, null).ConfigureAwait(false);
            var fields = await DirectWire.Read(connection.Stream).ConfigureAwait(false);
            if (!DirectWire.V2(fields))
            {
                await DirectWire.Write(connection.Stream, DirectWire.Reply("Unsupported Direct protocol.")).ConfigureAwait(false);
                return;
            }
            var mode = DirectWire.Field(fields, "mode");
            if (mode == "sync")
            {
                var peer = peers.ByFingerprint(connection.Fingerprint);
                if (peer == null || fields.ContainsKey("device") && DirectWire.Field(fields, "device") != peer.Id)
                {
                    await DirectWire.Write(connection.Stream, DirectWire.Reply("unpaired")).ConfigureAwait(false);
                    return;
                }
                await DirectWire.Write(connection.Stream, DirectWire.Reply()).ConfigureAwait(false);
                abort.Dispose();
                deadline.Token.ThrowIfCancellationRequested();
                sync(peer, connection);
                handedOff = true;
                return;
            }
            if (mode == "pair") deadline.CancelAfter(DirectWire.ApprovalMs + DirectWire.TimeoutMs);
            var reply = await Pair(mode, fields, connection, deadline.Token).ConfigureAwait(false);
            await DirectWire.Write(connection.Stream, reply).ConfigureAwait(false);
        }
        catch (Exception e) when (DirectWire.ConnectionError(e) || e is UnauthorizedAccessException)
        {
            if (e is UnauthorizedAccessException) SyncLog.Write("Direct pairing: " + e.Message);
        }
        finally
        {
            if (!handedOff)
            {
                if (connection != null) connection.Dispose();
                else client.Close();
            }
        }
    }

    async Task<Dictionary<string, object?>> Pair(string mode, Dictionary<string, object?> fields, DirectConnection connection, CancellationToken token)
    {
        if (mode is not ("pair" or "pair-qr")) return DirectWire.Reply("Unknown Direct mode.");
        if (mode == "pair" && !AllowRequest())
            return DirectWire.Reply("Too many pairing requests. Wait a moment and try again.");

        var peer = DirectWire.Peer(fields, connection.Fingerprint);
        if (!peer.Valid || peer.Id == identity.Id || peer.Fingerprint == identity.Fingerprint)
            return DirectWire.Reply("Invalid Direct device.");

        if (mode == "pair-qr")
        {
            if (!ClaimQr(DirectWire.Field(fields, "code"))) return DirectWire.Reply("Invalid or expired pairing code.");
        }
        else
        {
            var request = new DirectPairRequest(peer.Name, peer.Os, DirectSas.Formatted(identity.Fingerprint, peer.Fingerprint));
            if (!await DirectPairingClient.Confirm(Approve, request, token).ConfigureAwait(false))
                return DirectWire.Reply($"Declined on {name()}.");
        }
        token.ThrowIfCancellationRequested();
        if (peers.ById(peer.Id) is { } old && old.Fingerprint == peer.Fingerprint)
            peer = peer with { Addresses = old.Addresses, Port = old.Port };
        peers.Save(peer);
        var reply = DirectWire.Reply();
        reply["device"] = identity.Id;
        reply["name"] = name();
        reply["os"] = DirectWire.Os;
        return reply;
    }

    bool AllowRequest()
    {
        lock (gate)
        {
            var now = Stopwatch.GetTimestamp();
            while (pairTimes.Count != 0 && now - pairTimes.Peek() >= 60 * Stopwatch.Frequency) pairTimes.Dequeue();
            if (pairTimes.Count >= 5) return false;
            pairTimes.Enqueue(now);
            return true;
        }
    }

    public string CreateQrLink(IEnumerable<string> addresses)
    {
        var bytes = new byte[16];
        using (var rng = RandomNumberGenerator.Create()) rng.GetBytes(bytes);
        lock (gate)
        {
            if (disposed) throw new ObjectDisposedException(nameof(DirectServer));
            qrToken = string.Concat(bytes.Select(b => b.ToString("x2", CultureInfo.InvariantCulture)));
            qrWrong = 0;
            qrIssued = Stopwatch.GetTimestamp();
            return $"clipbubble://direct?v=2&id={identity.Id}&fp={identity.Fingerprint}&h={string.Join(",", addresses.Select(Uri.EscapeDataString))}" +
                $"&p={Port}&c={qrToken}&n={Uri.EscapeDataString(name())}&os={DirectWire.Os}";
        }
    }

    bool ClaimQr(string code)
    {
        lock (gate)
        {
            if (qrToken == null || Stopwatch.GetTimestamp() - qrIssued >= 600 * Stopwatch.Frequency) return false;
            var diff = code.Length ^ qrToken.Length;
            for (var i = 0; i < qrToken.Length; i++) diff |= qrToken[i] ^ (i < code.Length ? code[i] : 0);
            if (diff == 0) { qrToken = null; return true; }
            if (++qrWrong >= 5) qrToken = null;
            return false;
        }
    }

    public void Dispose()
    {
        lock (gate)
        {
            if (disposed) return;
            disposed = true;
        }
        stop.Cancel();
        listener.Stop();
        stop.Dispose();
    }
}

static class DirectTunnel
{
    internal static async Task<DirectConnection> Open(DirectIdentity identity, IEnumerable<string> addresses, int port,
        string? expectedFp, CancellationToken token)
    {
        using var race = CancellationTokenSource.CreateLinkedTokenSource(token);
        var attempts = addresses.Distinct().Select(a => Dial(identity, a, port, expectedFp, race.Token)).ToList();
        DirectException? mismatch = null;
        while (attempts.Count > 0)
        {
            var finished = await Task.WhenAny(attempts).ConfigureAwait(false);
            attempts.Remove(finished);
            DirectConnection connection;
            try { connection = await finished.ConfigureAwait(false); }
            catch (DirectException e) { mismatch = e; continue; }
            catch (Exception e) when (DirectWire.ConnectionError(e)) { continue; }
            race.Cancel();
            foreach (var attempt in attempts) _ = DisposeLoser(attempt);
            if (!token.IsCancellationRequested) return connection;
            connection.Dispose();
            token.ThrowIfCancellationRequested();
        }
        if (mismatch != null) throw mismatch;
        token.ThrowIfCancellationRequested();
        throw new DirectException("offline", "Could not reach the Direct peer.");
    }

    static async Task DisposeLoser(Task<DirectConnection> attempt)
    {
        try { (await attempt.ConfigureAwait(false)).Dispose(); }
        catch (Exception e) when (DirectWire.ConnectionError(e)) { }
    }

    static async Task<DirectConnection> Dial(DirectIdentity identity, string host, int port, string? expectedFp, CancellationToken token)
    {
        var client = new TcpClient();
        // The AddressFamily constructor is needed for IPv6 literals on .NET Framework.
        if (IPAddress.TryParse(host, out var ip) && ip.AddressFamily == AddressFamily.InterNetworkV6)
        {
            client.Dispose();
            client = new TcpClient(AddressFamily.InterNetworkV6);
        }
        DirectConnection? connection = null;
        var handedOff = false;
        try
        {
            using (token.Register(client.Close))
            {
                await client.ConnectAsync(host, port).ConfigureAwait(false);
                connection = new DirectConnection(client, identity);
                await connection.Authenticate(identity, host).ConfigureAwait(false);
                if (expectedFp != null && connection.Fingerprint != expectedFp)
                    throw new DirectException("host-key-changed", "The Direct peer's identity changed.");
            }
            token.ThrowIfCancellationRequested();
            handedOff = true;
            return connection;
        }
        finally
        {
            if (!handedOff)
            {
                if (connection == null) client.Close();
                else connection.Dispose();
            }
        }
    }

    public static async Task<DirectConnection> Connect(DirectIdentity identity, DirectPeer peer, CancellationToken token)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(DirectWire.TimeoutMs);
        var connection = await Open(identity, peer.Addresses, peer.Port, peer.Fingerprint, deadline.Token).ConfigureAwait(false);
        try
        {
            using (deadline.Token.Register(connection.Abort))
            {
                await DirectWire.Write(connection.Stream, new()
                {
                    ["mode"] = "sync", ["v"] = DirectWire.Version, ["device"] = identity.Id,
                }).ConfigureAwait(false);
                var reply = await DirectWire.Read(connection.Stream).ConfigureAwait(false);
                if (!DirectWire.Ok(reply))
                    throw DirectWire.Field(reply, "error") == "unpaired"
                        ? new DirectException("needs-key", "The Direct peer no longer trusts this device.")
                        : new IOException("The Direct peer rejected sync.");
            }
            deadline.Token.ThrowIfCancellationRequested();
            return connection;
        }
        catch { connection.Dispose(); throw; }
    }
}

sealed record DirectNearby(string Id, string Name, string Os, string FingerprintHint, string[] Addresses, int Port);

/// A DNS-SD responder and browser on the IPv4 mDNS group. RRs can arrive in separate packets,
/// so cache them by DNS name until both the service and its target can be resolved.
sealed class DirectMdns : IDisposable
{
    const string Service = "_clipbubble._tcp.local";
    const ushort A = 1, Ptr = 12, Txt = 16, Aaaa = 28, Srv = 33, Any = 255;
    const int Port = 5353, Ttl = 120;
    static readonly IPEndPoint Group = new(IPAddress.Parse("224.0.0.251"), Port);
    readonly DirectIdentity identity;
    readonly Func<string> name;
    readonly int servicePort;
    readonly string host;
    readonly UdpClient udp = new(AddressFamily.InterNetwork);
    readonly object gate = new();
    readonly HashSet<IPAddress> interfaces = new();
    readonly Dictionary<string, long> pointers = new(StringComparer.OrdinalIgnoreCase);
    readonly Dictionary<string, (string Host, int Port, long Expires)> services = new(StringComparer.OrdinalIgnoreCase);
    readonly Dictionary<string, (Dictionary<string, string> Values, long Expires)> texts = new(StringComparer.OrdinalIgnoreCase);
    readonly Dictionary<string, Dictionary<IPAddress, long>> hosts = new(StringComparer.OrdinalIgnoreCase);
    readonly Timer refresh;
    bool collision;
    bool disposed;
    int ticks;

    public DirectMdns(DirectIdentity identity, Func<string> name, int port)
    {
        this.identity = identity;
        this.name = name;
        servicePort = port;
        host = "clipbubble-" + identity.Id + ".local";
        try
        {
            udp.ExclusiveAddressUse = false;
            udp.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            udp.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastTimeToLive, 255);
            udp.Client.Bind(new IPEndPoint(IPAddress.Any, Port));
            UpdateInterfaces();
        }
        catch { udp.Dispose(); throw; }
        _ = Receive();
        refresh = new Timer(_ => Refresh(), null, TimeSpan.Zero, TimeSpan.FromSeconds(10));
    }

    static string ClipUtf8(string value, int limit)
    {
        while (Encoding.UTF8.GetByteCount(value) > limit) value = Store.Head(value, value.Length - 1);
        return value;
    }

    string Name => string.IsNullOrWhiteSpace(name()) ? "ClipBubble" : ClipUtf8(name(), 48);
    string Instance => Name + (collision ? " (" + identity.Id.Substring(0, 8) + ")" : "");
    string QualifiedInstance => Instance + "." + Service;

    void UpdateInterfaces()
    {
        var available = new HashSet<IPAddress>(NetworkInterface.GetAllNetworkInterfaces()
            .Where(n => n.OperationalStatus == OperationalStatus.Up && n.SupportsMulticast && n.NetworkInterfaceType != NetworkInterfaceType.Loopback)
            .SelectMany(n => n.GetIPProperties().UnicastAddresses)
            .Select(a => a.Address).Where(a => a.AddressFamily == AddressFamily.InterNetwork));
        foreach (var address in interfaces.Where(a => !available.Contains(a)).ToArray())
        {
            try { udp.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.DropMembership, new MulticastOption(Group.Address, address)); }
            catch (SocketException) { }
            interfaces.Remove(address);
        }
        foreach (var address in available.Where(a => !interfaces.Contains(a)))
        {
            try { udp.JoinMulticastGroup(Group.Address, address); interfaces.Add(address); }
            catch (SocketException) { }
        }
    }

    void Refresh()
    {
        lock (gate)
        {
            if (disposed) return;
            try
            {
                UpdateInterfaces();
                Prune(Stopwatch.GetTimestamp());
                Browse();
                if (ticks++ % 6 == 0) Send(a => Announcement(a, Ttl), Group);
            }
            catch (Exception e) when (e is SocketException or NetworkInformationException) { }
        }
    }

    public void Browse()
    {
        lock (gate)
        {
            if (disposed) return;
            Query(Service, Ptr);
            // Some responders send only the PTR. Resolve its SRV and TXT and then the
            // target addresses explicitly when the additional records are missing.
            foreach (var instance in pointers.Keys.Where(k => !Equal(k, QualifiedInstance)).Take(32))
            {
                var suffix = "." + Service;
                if (!instance.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)) continue;
                var label = instance.Substring(0, instance.Length - suffix.Length);
                if (!services.TryGetValue(instance, out var service)) Query(Service, Srv, label);
                else if (!hosts.ContainsKey(service.Host))
                {
                    Query(service.Host, A);
                    Query(service.Host, Aaaa);
                }
                if (!texts.ContainsKey(instance)) Query(Service, Txt, label);
            }
        }
    }

    void Query(string name, ushort type, string? label = null)
    {
        using var packet = new MemoryStream();
        Header(packet, 0, 0, 1, 0, 0);
        DnsName(packet, name, label);
        U16(packet, type);
        U16(packet, 1);
        var query = packet.ToArray();
        Send(_ => query, Group);
    }

    public DirectNearby[] Nearby()
    {
        lock (gate)
        {
            Prune(Stopwatch.GetTimestamp());
            var devices = new List<DirectNearby>();
            foreach (var instance in pointers.Keys)
            {
                if (!services.TryGetValue(instance, out var service) || !texts.TryGetValue(instance, out var txt)
                    || !hosts.TryGetValue(service.Host, out var addresses) || addresses.Count == 0) continue;
                var values = txt.Values;
                if (!values.TryGetValue("v", out var v) || v != "2" || !values.TryGetValue("id", out var id)
                    || !DirectWire.DeviceId(id) || id == identity.Id || !values.TryGetValue("name", out var display)
                    || string.IsNullOrWhiteSpace(display) || Encoding.UTF8.GetByteCount(display) > 48
                    || !values.TryGetValue("os", out var os) || !DirectWire.KnownOs(os)
                    || !values.TryGetValue("fp", out var fp) || !DirectWire.Hex(fp, 16) || service.Port == 0) continue;
                devices.Add(new DirectNearby(id, display, os, fp, addresses.Keys.Select(a => a.ToString()).ToArray(), service.Port));
            }
            return devices.GroupBy(d => d.Id).Select(g => g.First()).OrderBy(d => d.Name, StringComparer.OrdinalIgnoreCase).ToArray();
        }
    }

    async Task Receive()
    {
        while (true)
        {
            UdpReceiveResult message;
            try { message = await udp.ReceiveAsync().ConfigureAwait(false); }
            catch (Exception e) when (e is ObjectDisposedException or SocketException)
            {
                lock (gate) { if (disposed) return; }
                if (e is ObjectDisposedException) return;
                await Task.Delay(1000).ConfigureAwait(false);
                continue;
            }
            lock (gate)
            {
                if (disposed) return;
                try { Process(message.Buffer, message.RemoteEndPoint); }
                catch (Exception e) when (e is InvalidDataException or SocketException) { }
            }
        }
    }

    void Process(byte[] bytes, IPEndPoint from)
    {
        if (bytes.Length < 12) return;
        var packet = new DnsPacket(bytes);
        var id = packet.U16();
        var flags = packet.U16();
        var questions = packet.U16();
        var records = packet.U16() + packet.U16() + packet.U16();
        var questionStart = packet.Position;
        var unicast = false;
        var answer = false;
        for (var i = 0; i < questions; i++)
        {
            var question = packet.Name();
            var type = packet.U16();
            var cls = packet.U16();
            if ((cls & 0x7fff) != 1) continue;
            if (Equal(question, Service) && type is Ptr or Any ||
                Equal(question, QualifiedInstance) && type is Srv or Txt or Any ||
                Equal(question, host) && type is A or Any)
            {
                answer = true;
                unicast |= (cls & 0x8000) != 0;
            }
        }
        if ((flags & 0x8000) == 0)
        {
            if (!answer) return;
            var legacy = from.Port != Port;
            var questionData = legacy ? bytes.Skip(questionStart).Take(packet.Position - questionStart).ToArray() : null;
            Send(a => Announcement(a, legacy ? 10 : Ttl, legacy ? id : 0, legacy ? questions : 0, questionData),
                unicast || legacy ? from : Group);
            return;
        }
        var now = Stopwatch.GetTimestamp();
        var rename = false;
        for (var i = 0; i < records; i++)
        {
            var owner = packet.Name();
            var type = packet.U16();
            var cls = packet.U16() & 0x7fff;
            var ttl = ((uint)packet.U16() << 16) | packet.U16();
            var length = packet.U16();
            var end = packet.Position + length;
            if (end > bytes.Length) throw new InvalidDataException();
            var expires = now + Math.Min(ttl, 4500u) * Stopwatch.Frequency;
            if (cls == 1)
            {
                if (type == Ptr && Equal(owner, Service))
                {
                    var target = packet.Name();
                    if (packet.Position != end) throw new InvalidDataException();
                    Remember(pointers, target, expires, ttl);
                }
                else if ((type is Srv or Txt) && owner.EndsWith("." + Service, StringComparison.OrdinalIgnoreCase))
                {
                    if (type == Srv && length >= 7)
                    {
                        packet.U16(); // priority
                        packet.U16(); // weight
                        var port = packet.U16();
                        var target = packet.Name();
                        if (packet.Position != end) throw new InvalidDataException();
                        Remember(services, owner, (target, port, expires), ttl);
                    }
                    if (type == Txt)
                    {
                        var txt = packet.Text(end);
                        if (!collision && Equal(owner, QualifiedInstance) && txt.TryGetValue("id", out var theirId)
                            && DirectWire.DeviceId(theirId) && theirId != identity.Id) rename = true;
                        if (!txt.TryGetValue("id", out var deviceId) || deviceId != identity.Id)
                            Remember(texts, owner, (txt, expires), ttl);
                    }
                }
                else if (type == A && length == 4 || type == Aaaa && length == 16)
                {
                    var address = new IPAddress(bytes.Skip(packet.Position).Take(length).ToArray());
                    // An IPv6 link-local address would need a zone from the receiving interface.
                    if (!address.IsIPv6LinkLocal)
                    {
                        if (!hosts.TryGetValue(owner, out var addresses))
                        {
                            addresses = new();
                            Remember(hosts, owner, addresses, ttl);
                        }
                        Remember(addresses, address, expires, ttl);
                    }
                }
            }
            packet.Position = end;
        }
        if (rename)
        {
            collision = true;
            Send(a => Announcement(a, Ttl), Group);
        }
    }

    static bool Equal(string a, string b) => string.Equals(a, b, StringComparison.OrdinalIgnoreCase);

    static void Remember<K, V>(Dictionary<K, V> cache, K key, V value, uint ttl) where K : notnull
    {
        if (ttl == 0) cache.Remove(key);
        else if (cache.Count < 512 || cache.ContainsKey(key)) cache[key] = value;
    }

    void Prune(long now)
    {
        static void Expire<K, V>(Dictionary<K, V> cache, Func<V, bool> expired) where K : notnull
        {
            foreach (var key in cache.Where(p => expired(p.Value)).Select(p => p.Key).ToArray()) cache.Remove(key);
        }
        Expire(pointers, t => t <= now);
        Expire(services, s => s.Expires <= now);
        Expire(texts, t => t.Expires <= now);
        foreach (var addresses in hosts.Values) Expire(addresses, t => t <= now);
        Expire(hosts, h => h.Count == 0);
    }

    void Send(Func<IPAddress, byte[]> packet, IPEndPoint to)
    {
        foreach (var address in interfaces)
        {
            try
            {
                udp.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastInterface, address.GetAddressBytes());
                var data = packet(address);
                udp.Send(data, data.Length, to);
                if (!to.Equals(Group)) break;
            }
            catch (SocketException) { }
        }
    }

    byte[] Announcement(IPAddress address, int ttl, int id = 0, int questions = 0, byte[]? questionData = null)
    {
        using var packet = new MemoryStream();
        Header(packet, id, 0x8400, questions, 4, 0);
        if (questionData != null) packet.Write(questionData, 0, questionData.Length);
        var flush = questionData == null ? 0x8001 : 1;
        var display = Name;
        var instance = display + (collision ? " (" + identity.Id.Substring(0, 8) + ")" : "");
        DnsName(packet, Service);
        Record(packet, Ptr, 1, ttl, data => DnsName(data, Service, instance));
        DnsName(packet, Service, instance);
        Record(packet, Srv, flush, ttl, data =>
        {
            U16(data, 0); U16(data, 0); U16(data, servicePort); DnsName(data, host);
        });
        DnsName(packet, Service, instance);
        Record(packet, Txt, flush, ttl, data =>
        {
            foreach (var field in new[] { "v=2", "id=" + identity.Id, "name=" + display, "os=" + DirectWire.Os, "fp=" + identity.Fingerprint.Substring(0, 16) })
                Label(data, field);
        });
        DnsName(packet, host);
        var ip = address.GetAddressBytes();
        Record(packet, A, flush, ttl, data => data.Write(ip, 0, ip.Length));
        return packet.ToArray();
    }

    static void Header(Stream packet, int id, int flags, int questions, int answers, int additional)
    {
        U16(packet, id); U16(packet, flags); U16(packet, questions);
        U16(packet, answers); U16(packet, 0); U16(packet, additional);
    }

    static void Record(Stream packet, int type, int cls, int ttl, Action<Stream> body)
    {
        using var data = new MemoryStream();
        body(data);
        U16(packet, type); U16(packet, cls); U16(packet, 0); U16(packet, ttl); U16(packet, (int)data.Length);
        data.WriteTo(packet);
    }

    static void DnsName(Stream packet, string name, string? leadingLabel = null)
    {
        if (leadingLabel != null) Label(packet, leadingLabel);
        foreach (var part in name.Split('.')) Label(packet, part);
        packet.WriteByte(0);
    }

    static void Label(Stream packet, string label)
    {
        var data = Encoding.UTF8.GetBytes(label);
        packet.WriteByte((byte)data.Length);
        packet.Write(data, 0, data.Length);
    }

    static void U16(Stream packet, int value)
    {
        packet.WriteByte((byte)(value >> 8));
        packet.WriteByte((byte)value);
    }

    public void Dispose()
    {
        lock (gate)
        {
            if (disposed) return;
            disposed = true;
            refresh.Dispose();
            Send(a => Announcement(a, 0), Group);
            udp.Dispose();
        }
    }

    sealed class DnsPacket(byte[] bytes)
    {
        public int Position { get; set; }

        public ushort U16()
        {
            if (Position + 2 > bytes.Length) throw new InvalidDataException();
            var value = (ushort)((bytes[Position] << 8) | bytes[Position + 1]);
            Position += 2;
            return value;
        }

        public string Name()
        {
            var pos = Position;
            var originalEnd = -1;
            var labels = new List<string>();
            var expanded = 0;
            var jumps = 0;
            while (pos < bytes.Length)
            {
                var size = bytes[pos++];
                if (size == 0)
                {
                    Position = originalEnd < 0 ? pos : originalEnd;
                    return string.Join(".", labels);
                }
                if ((size & 0xc0) == 0xc0 && pos < bytes.Length)
                {
                    var target = ((size & 0x3f) << 8) | bytes[pos++];
                    if (target >= pos - 2 || ++jumps > 32) break;
                    if (originalEnd < 0) originalEnd = pos;
                    pos = target;
                    continue;
                }
                expanded += size + 1;
                if (size > 63 || pos + size > bytes.Length || expanded >= 255) break;
                labels.Add(Encoding.UTF8.GetString(bytes, pos, size));
                pos += size;
            }
            throw new InvalidDataException();
        }

        public Dictionary<string, string> Text(int end)
        {
            var fields = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            while (Position < end)
            {
                var size = bytes[Position++];
                if (Position + size > end) throw new InvalidDataException();
                var pair = Encoding.UTF8.GetString(bytes, Position, size);
                Position += size;
                var eq = pair.IndexOf('=');
                if (eq > 0) fields[pair.Substring(0, eq)] = pair.Substring(eq + 1);
            }
            return fields;
        }
    }
}
