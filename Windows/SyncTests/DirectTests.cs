using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography.X509Certificates;
using System.Threading;
using System.Threading.Tasks;
using static ClipBubble.SyncTests.Program;

namespace ClipBubble.SyncTests;

static class DirectTests
{
    public static IEnumerable<(string, Action)> All()
    {
        yield return ("Direct identity survives a restart with its P-256 certificate", Identity);
        yield return ("Direct SAS matches the six-digit golden vector in both directions", Sas);
        yield return ("Direct TLS 1.2 suite check reads a fragmented ServerHello", Tls12Suite);
        yield return ("Direct sync rejects untrusted certificates and mismatched device IDs", Untrusted);
        yield return ("Direct Nearby pairing checks the SAS, handles decline and limits requests", Nearby);
        yield return ("Direct QR pairs once, locks after five guesses and pins before sending the token", Qr);
        yield return ("Direct host aliases sync frames over mTLS and unlink closes the session", EngineSession);
    }

    static string DirectoryForTest() => Path.Combine(Paths.Dir, "direct-" + Guid.NewGuid().ToString("N"));

    static void Identity()
    {
        var folder = DirectoryForTest();
        var id = Guid.NewGuid().ToString().ToUpperInvariant();
        var start = DateTime.UtcNow;
        string fp;
        using (var identity = DirectIdentity.Open(folder, id))
        {
            var cert = identity.Certificate;
            using var key = cert.GetECDsaPrivateKey();
            Check(identity.Id == id.ToLowerInvariant() && key?.KeySize == 256, "use the existing UUID and a P-256 private key");
            Check(cert.Version == 3 && cert.Subject == "CN=clipbubble-" + identity.Id && cert.Issuer == cert.Subject, "self-issued X.509 v3");
            Check(cert.SignatureAlgorithm.Value == "1.2.840.10045.4.3.2", "ECDSA with SHA-256");
            Check(Math.Abs((cert.NotBefore.ToUniversalTime() - start.AddDays(-1)).TotalMinutes) < 1 &&
                Math.Abs((cert.NotAfter.ToUniversalTime() - start.AddYears(20)).TotalMinutes) < 1, "validity window");
            Check(cert.Extensions.OfType<X509BasicConstraintsExtension>().Single() is { CertificateAuthority: false, Critical: true },
                "non-CA constraints");
            Check(cert.Extensions.OfType<X509KeyUsageExtension>().Single() is { KeyUsages: X509KeyUsageFlags.DigitalSignature, Critical: true },
                "digital signature key usage");
            Check(cert.Extensions.OfType<X509EnhancedKeyUsageExtension>().Single().EnhancedKeyUsages
                .Cast<System.Security.Cryptography.Oid>().Select(o => o.Value).OrderBy(s => s, StringComparer.Ordinal).SequenceEqual(new[] { "1.3.6.1.5.5.7.3.1", "1.3.6.1.5.5.7.3.2" }), "both TLS roles");
            fp = identity.Fingerprint;
            Check(DirectWire.Hex(fp, 64) && fp == Store.Sha(cert.RawData), "SHA-256 of the leaf DER");
        }
        using var reopened = DirectIdentity.Open(folder, id);
        Check(reopened.Fingerprint == fp && File.Exists(Path.Combine(folder, "direct-identity.pfx")), "reuse the stored identity");
    }

    static void Sas()
    {
        var a = new string('0', 64);
        var b = new string('0', 63) + "5";
        Check(DirectSas.Code(a, b) == "027982" && DirectSas.Formatted(b, a) == "027 982", "compute the unsigned big-endian SAS and preserve its leading zero");
    }

    static void Tls12Suite()
    {
        // A maximal session ID makes the cipher suite the last two bytes inspected.
        var hello = new byte[73];
        hello[0] = 2;
        hello[3] = 69;
        hello[4] = hello[5] = 3;
        hello[38] = 32;
        hello[71] = 0xc0;
        bool Accepted(byte suite)
        {
            hello[72] = suite;
            var transcript = new DirectServerHello();
            foreach (var b in hello)
                transcript.Append(new byte[] { 22, 3, 3, 0, 1, b }, 0, 6);
            return transcript.IsEcdsaGcm;
        }
        Check(Accepted(0x2b) && Accepted(0x2c) && !Accepted(0x23), "accept ECDHE-ECDSA AES-GCM and reject AES-CBC");
    }

    static DirectPeer Endpoint(DirectIdentity identity, int port) => new()
    {
        Id = identity.Id, Name = "Host", Os = "windows", Fingerprint = identity.Fingerprint, Addresses = new[] { "127.0.0.1" }, Port = port,
    };

    static void Untrusted()
    {
        using var host = DirectIdentity.Ephemeral(Guid.NewGuid().ToString());
        using var client = DirectIdentity.Ephemeral(Guid.NewGuid().ToString());
        var peers = new DirectPeers(DirectoryForTest());
        var syncs = 0;
        using var server = new DirectServer(host, peers, () => "Host", (_, c) => { Interlocked.Increment(ref syncs); c.Dispose(); }, 0);
        var endpoint = Endpoint(host, server.Port);
        Expect<DirectException>(() => DirectTunnel.Connect(client, endpoint, default), e => e.Kind == "needs-key");
        peers.Save(Endpoint(client, 0));
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        using var connection = DirectTunnel.Open(client, endpoint.Addresses, endpoint.Port, endpoint.Fingerprint, timeout.Token).GetAwaiter().GetResult();
        using var abort = timeout.Token.Register(connection.Abort);
        DirectWire.Write(connection.Stream, new() { ["mode"] = "sync", ["v"] = 2, ["device"] = Guid.NewGuid().ToString() }).GetAwaiter().GetResult();
        var reply = DirectWire.Read(connection.Stream).GetAwaiter().GetResult();
        Check(!DirectWire.Ok(reply) && DirectWire.Field(reply, "error") == "unpaired" && syncs == 0, "a pin cannot claim a different device ID");
    }

    static void Nearby()
    {
        using var host = DirectIdentity.Ephemeral(Guid.NewGuid().ToString());
        using var client = DirectIdentity.Ephemeral(Guid.NewGuid().ToString());
        var dir = DirectoryForTest();
        var peers = new DirectPeers(dir);
        var approvals = 0;
        var serverCode = "";
        using var occupied = new TcpListener(IPAddress.IPv6Any, 0);
        occupied.Server.DualMode = true;
        occupied.Start();
        var preferredPort = ((IPEndPoint)occupied.LocalEndpoint).Port;
        using var server = new DirectServer(host, peers, () => "Host", (_, c) => c.Dispose(), preferredPort);
        Check(server.Port != preferredPort, "fall back to an ephemeral port when the preferred port is busy");
        server.Approve = (request, _) =>
        {
            serverCode = request.Code;
            return Task.FromResult(++approvals == 5 && request.Name == "Client" && request.Os == "windows");
        };
        var nearby = new DirectNearby(host.Id, "Host", "windows", host.Fingerprint.Substring(0, 16), new[] { "127.0.0.1" }, server.Port);
        var clientCode = "";
        Task<DirectPeer> Pair() => DirectPairingClient.Nearby(client, "Client", nearby, (r, _) =>
        {
            clientCode = r.Code;
            return Task.FromResult(true);
        });
        for (var i = 0; i < 4; i++)
        {
            Expect<PairingException>(Pair, e => e.Message == "Declined on Host.");
            Check(peers.ById(client.Id) == null, "decline grants no trust");
        }
        var peer = Pair().GetAwaiter().GetResult();
        Check(peer.Fingerprint == host.Fingerprint && clientCode == serverCode &&
            clientCode == DirectSas.Formatted(host.Fingerprint, client.Fingerprint), "both prompts see the same SAS");
        Check(new DirectPeers(dir).ByFingerprint(client.Fingerprint)?.Id == client.Id, "allow persists the exact certificate pin");
        Expect<PairingException>(Pair, e => e.Message == "Too many pairing requests. Wait a moment and try again.");
        Check(approvals == 5, "rate limit precedes the prompt");
    }

    static void Qr()
    {
        using var host = DirectIdentity.Ephemeral(Guid.NewGuid().ToString());
        using var client = DirectIdentity.Ephemeral(Guid.NewGuid().ToString());
        using var impostor = DirectIdentity.Ephemeral(Guid.NewGuid().ToString());
        var peers = new DirectPeers(DirectoryForTest());
        var otherPeers = new DirectPeers(DirectoryForTest());
        using var server = new DirectServer(host, peers, () => "Host & café", (_, c) => c.Dispose(), 0);
        using var fake = new DirectServer(impostor, otherPeers, () => "Other", (_, c) => c.Dispose(), 0);
        var addresses = new[] { "::1", "127.0.0.1" };
        var qr = DirectQr.Parse(server.CreateQrLink(addresses));
        Check(qr.Id == host.Id && qr.Fingerprint == host.Fingerprint && qr.Name == "Host & café" && qr.Addresses.SequenceEqual(addresses), "QR URL fields round-trip");

        // Ask the wrong server to pair with its own valid token, while expecting the real server's fingerprint.
        // The wrong server's token must still work afterwards: no pairing preamble reached it.
        var otherQr = DirectQr.Parse(fake.CreateQrLink(addresses));
        Expect<DirectException>(() => DirectPairingClient.Scan(client, "Client", otherQr with { Fingerprint = qr.Fingerprint }),
            e => e.Kind == "host-key-changed");
        Check(otherPeers.ById(client.Id) == null, "wrong certificate never gets trust");
        Check(DirectPairingClient.Scan(client, "Client", otherQr).GetAwaiter().GetResult().Id == impostor.Id, "the token was never sent to the wrong server");

        var wrong = qr.Code == new string('a', 32) ? new string('b', 32) : new string('a', 32);
        for (var i = 0; i < 5; i++)
            Expect<PairingException>(() => DirectPairingClient.Scan(client, "Client", qr with { Code = wrong }), InvalidCode);
        Expect<PairingException>(() => DirectPairingClient.Scan(client, "Client", qr), InvalidCode);
        Check(peers.ById(client.Id) == null, "wrong guesses cannot add a peer");

        qr = DirectQr.Parse(server.CreateQrLink(addresses));
        var peer = DirectPairingClient.Scan(client, "Client", qr).GetAwaiter().GetResult();
        Check(peer.Fingerprint == host.Fingerprint && peer.Addresses.SequenceEqual(addresses) &&
            peers.ById(client.Id)?.Fingerprint == client.Fingerprint, "successful QR keeps the endpoints and mutual pins");
        Expect<PairingException>(() => DirectPairingClient.Scan(client, "Client", qr), InvalidCode);

        static bool InvalidCode(PairingException e) => e.Message == "Invalid or expired pairing code.";
    }

    static void EngineSession()
    {
        var engine = new Engine("Direct Windows");
        engine.Start();
        Check(WaitFor(() => engine.Direct != null), "the Direct service starts alongside the pipe");
        using var direct = engine.Direct!;
        using var host = DirectIdentity.Ephemeral(Guid.NewGuid().ToString());
        var accepted = new TaskCompletionSource<DirectConnection>(TaskCreationOptions.RunContinuationsAsynchronously);
        using var server = new DirectServer(host, new DirectPeers(DirectoryForTest()), () => "TLS host", (_, c) =>
        {
            if (!accepted.TrySetResult(c)) c.Dispose();
        }, 0);
        var peer = direct.PairQr(server.CreateQrLink(new[] { "127.0.0.1" })).GetAwaiter().GetResult();
        using var remote = accepted.Task.WaitAsync(TimeSpan.FromSeconds(10)).GetAwaiter().GetResult();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        using var abort = timeout.Token.Register(remote.Abort);
        var hello = Codec.Encode(new Hello(SyncProto.Version, host.Id, "TLS host", "windows", "2.0", Engine.Now));
        var summary = Codec.Encode(new Summary(Array.Empty<Stamp>()));
        remote.Stream.Write(hello.Concat(summary).ToArray());
        var buffer = new byte[65536];
        var frames = new FrameReader();
        var got = new List<Frame>();
        while (!got.Any(f => f is Summary))
        {
            var n = remote.Stream.Read(buffer);
            Check(n > 0, "sync stays connected until the engine sends its summary");
            got.AddRange(frames.Feed(buffer, n));
        }
        Check(got[0] is Hello h && h.Device == direct.Identity.Id && remote.Fingerprint == direct.Identity.Fingerprint, "the signed TLS session carries the engine's hello");
        Check(WaitFor(() => Engine.Hosts.Contains(peer.Alias()) && engine.Statuses.TryGetValue(peer.Alias(), out var s) && s.Kind == "live"), "pairing enabled and dialled the Direct alias");
        direct.Unlink(peer.Id);
        Check(WaitFor(() => !Engine.Hosts.Contains(peer.Alias()) && engine.Linked.All(h => h.Device != peer.Id)), "revoke trust, disable the alias and close its active session");
    }

    static void Expect<T>(Func<Task> act, Func<T, bool> expected) where T : Exception
    {
        try { act().GetAwaiter().GetResult(); }
        catch (T e) when (expected(e)) { return; }
        throw new Exception("Expected " + typeof(T).Name);
    }
}
