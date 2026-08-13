import Foundation
import Testing
@testable import Portal

/// A live Portal process was found holding **30 ESTABLISHED TCP connections** to
/// the gateway where there should be exactly one, with unread bytes queued in the
/// kernel receive buffer of several of them — the harness was streaming a turn
/// into sockets nobody was reading. Only one `GatewayClient` existed in the heap,
/// matched 1:1 by 30 live `__NSURLSessionWebSocketTask` objects, so this was not
/// many clients each with a socket: one client had opened 30 transports and closed
/// none of them.
///
/// That matters beyond the fd count, because every delegate callback in
/// `GatewayClient` is gated on `session === self.urlSession`. A frame arriving on
/// a stale-but-open socket is therefore discarded with no log line and no
/// `recordDroppedEvent` — it presents as a session that is "still streaming" with
/// no updates arriving and nothing in the thought graph. That is the reported
/// symptom, and it is why this is a silent failure rather than a noisy one.
///
/// The mechanism was established experimentally against a WebSocket server that
/// completes the upgrade and then never answers a Close frame. Three sockets per
/// teardown strategy:
///
/// | teardown                                              | survivors |
/// |-------------------------------------------------------|-----------|
/// | `task.cancel(with:reason:)` + `invalidateAndCancel()`  | 0         |
/// | `invalidateAndCancel()` alone                          | 0         |
/// | `task.cancel(with:reason:)` alone                      | 0         |
/// | `cancel` + `finishTasksAndInvalidate()`                | 0         |
/// | drop both references, no invalidate, no cancel         | **3**     |
///
/// Read the table carefully, because it rules out the obvious explanations. Every
/// teardown that *executes* closes the socket — including a graceful close the
/// peer never answers, and the exact sequence the shipped code used. `netstat`
/// agreed: all 30 were ESTABLISHED with Send-Q 0, so no FIN *and* no Close frame
/// in flight. Nothing had been sent on them at all.
///
/// So the defect was never which calls the teardown makes. It was that the whole
/// teardown lived inside a `Task.detached(priority: .utility)` and that task never
/// ran — a sample of the leaking process showed no live cooperative-pool threads,
/// while the main actor rendered normally. The fix is therefore about reachability:
/// close the socket inline (a non-blocking signal), and defer only the invalidation
/// that can actually block. The tests below assert promptness rather than eventual
/// consistency, because "it closes once something schedules it" is exactly the
/// property that failed in the field.
///
/// The last row still earns its place. A dropped `URLSession` does NOT close its
/// connection when merely released — it retains itself and its delegate until
/// invalidated — which is why an un-invalidated session is a second, distinct leak
/// that pins the entire client graph while `leaks` reports nothing.
@Suite("Gateway transport leak")
internal struct GatewayTransportLeakTests {

    @Test("replacing a transport closes the socket it replaced")
    @MainActor
    internal func reconnectDoesNotLeakSockets() async throws {
        let server = try SilentWebSocketServer()
        defer { server.stop() }

        let client = GatewayClient(
            gatewayURL: server.endpoint,
            apiKey: ""
        )
        defer { client.disconnect() }

        client.connect()
        try await waitFor { server.upgradeCount >= 1 }

        // Rebuild the transport several times, the way a flaky link plus macOS
        // window focus does over a long session. Each rebuild must leave exactly
        // one live WebSocket behind, not accumulate one per attempt.
        // Each redial must be allowed to land before the next one starts.
        // `forceReconnectAndWait` returns as soon as `connectionState` reads
        // `.connected`, which after the first socket opens is *already* true —
        // the delegate hasn't been told the old transport died yet — so firing
        // them back to back had each teardown killing the previous dial while it
        // was still handshaking, and only 2 of 5 ever reached the server. A
        // reconnect the user actually experiences completes; wait for that.
        let dials = 5
        for dial in 1..<dials {
            await client.forceReconnectAndWait(timeout: 3)
            try await waitFor { server.upgradeCount > dial }
        }
        try await waitFor { server.upgradeCount >= dials }
        // Then let the closes land. The task cancel is synchronous, but the
        // server learns of the close by reading EOF, so allow for that hop.
        try await waitFor { server.liveConnectionCount <= 1 }

        let live = server.liveConnectionCount
        let upgrades = server.upgradeCount
        // Guard against a vacuous pass. "Zero sockets left open" is trivially
        // true if the client never opened any, so require that the redials
        // actually reached the server before believing the count above.
        #expect(
            upgrades >= dials,
            """
            Only \(upgrades) WebSocket upgrades reached the server for \(dials) \
            dials, so the leak assertion below proves nothing. The client never \
            got far enough to have a transport to leak — fix the fixture, don't \
            trust the result.
            """
        )
        #expect(
            live <= 1,
            """
            The gateway still sees \(live) open WebSockets after \(dials) dials \
            (\(upgrades) upgrades total); expected 1. A URLSession keeps its \
            connection — and retains its delegate — until invalidateAndCancel() \
            runs; dropping the reference is not enough. Every leaked socket stays \
            subscribed on the gateway, and because the delegate methods are gated \
            on `session === self.urlSession`, frames arriving on one are discarded \
            silently: the session reads as still streaming while no updates arrive \
            and the thought graph stays empty.
            """
        )
    }

    /// Reconnect must close the old socket even when the cooperative pool has no
    /// free thread to run deferred work on.
    ///
    /// This is the condition the live leak happened under, and the only condition
    /// under which any of this is observable: on an idle machine a deferred
    /// teardown runs promptly and the assertions above pass either way (verified
    /// by mutation). Every teardown that *executes* closes the socket — see the
    /// table on the suite — so 30 survivors can only mean the teardown never
    /// executed. It lived entirely in a `Task.detached(priority: .utility)`, and a
    /// sample of the leaking process showed no live cooperative-pool threads while
    /// the main actor rendered normally.
    ///
    /// The starvation is by QoS, not Task-vs-GCD: measured with the utility band
    /// saturated, `Task.detached(.utility)` and `DispatchQueue.global(qos: .utility)`
    /// both failed to run within 5s, while `.default`/`.userInitiated` globals and a
    /// dedicated serial queue ran immediately. So the fix has to close inline; the
    /// dedicated queue only rescues the invalidation.
    ///
    /// The hogs **block** rather than spin. Blocking a cooperative thread is the
    /// cardinal sin of Swift concurrency and it starves the pool just as
    /// thoroughly, but at zero CPU cost. A spinning version of this test worked
    /// too, and then starved swift-testing's own parallel suites badly enough to
    /// fail five unrelated tests — the harness has to be invisible to everything
    /// except the code under test.
    @Test("reconnect closes the old socket with the cooperative pool starved")
    @MainActor
    internal func closeSurvivesAStarvedCooperativePool() async throws {
        let server = try SilentWebSocketServer()
        defer { server.stop() }

        let client = GatewayClient(gatewayURL: server.endpoint, apiKey: "")
        defer { client.disconnect() }

        client.connect()
        try await waitFor { server.upgradeCount >= 1 }
        try await waitFor { server.liveConnectionCount >= 1 }

        // Park every cooperative worker on a semaphore. Oversubscribed 2x so the
        // pool cannot grow its way out, and released in `defer` so a failure here
        // never leaves threads parked for the rest of the run.
        let gate = DispatchSemaphore(value: 0)
        let hogs = ProcessInfo.processInfo.activeProcessorCount * 2
        for _ in 0..<hogs {
            Task.detached(priority: .utility) { PoolHog.block(on: gate) }
        }
        defer {
            for _ in 0..<hogs { gate.signal() }
        }
        // Let the hogs actually claim the threads before measuring.
        try await Task.sleep(nanoseconds: 500_000_000)

        // Exercise exactly one replacement. URLSession's dial itself uses system
        // scheduling that this fixture may starve, so do not require the replacement
        // to upgrade. The initial upgrade above proves there is a real old socket;
        // fewer live sockets than completed upgrades proves that socket closed,
        // whether or not the replacement manages to reach the server.
        await client.forceReconnectAndWait(timeout: 3)
        try await waitFor(timeout: 5) {
            server.liveConnectionCount < server.upgradeCount
        }

        let live = server.liveConnectionCount
        let upgrades = server.upgradeCount
        #expect(
            live < upgrades,
            """
            All \(live) of \(upgrades) upgraded WebSocket(s) remain after reconnect \
            with the cooperative pool starved; the old transport did not close. \
            The teardown is waiting on a thread it will never get. Cancel the old \
            task inline — it's a non-blocking signal — and defer only \
            invalidateAndCancel(), which can block, to a dedicated queue rather \
            than to a `.utility` task or global queue. This is the live defect: 30 \
            ESTABLISHED sockets to the gateway, bytes unread in several of them, \
            and because the delegate methods are gated on \
            `session === self.urlSession` those frames were dropped silently — the \
            session reads as still streaming while no updates arrive and the \
            thought graph stays empty.
            """
        )
    }

    /// Invalidation must reach a thread too — the second half of the field
    /// evidence, and a leak distinct from the socket.
    ///
    /// The live process held 30 `__NSURLSessionLocal` objects alongside its 30
    /// sockets. A `URLSession` retains *itself and its delegate* until it is
    /// invalidated, so a session left un-invalidated pins the whole
    /// `GatewayClient` graph — and `leaks` reports nothing, because it is all
    /// genuinely still reachable. That is why the scheduling of the invalidate
    /// still matters now that the cancel closes the socket inline.
    ///
    /// Asserted through the socket, because that is what is observable: this drives
    /// the real `invalidateOffMainActor` with no `cancel()` at all, so the socket
    /// can only close if the invalidation ran.
    @Test("session invalidation is not blocked by a starved cooperative pool")
    internal func invalidationSurvivesAStarvedCooperativePool() async throws {
        let server = try SilentWebSocketServer()
        defer { server.stop() }

        let gate = DispatchSemaphore(value: 0)
        let hogs = ProcessInfo.processInfo.activeProcessorCount * 2
        for _ in 0..<hogs {
            Task.detached(priority: .utility) { PoolHog.block(on: gate) }
        }
        defer {
            for _ in 0..<hogs { gate.signal() }
        }
        try await Task.sleep(nanoseconds: 500_000_000)

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: server.endpoint)
        task.resume()
        try await waitFor { server.upgradeCount >= 1 }
        try await waitFor { server.liveConnectionCount >= 1 }

        // Invalidate only — deliberately no cancel(), so the socket closing is
        // proof that the invalidation itself got a thread.
        GatewayClient.invalidateOffMainActor(session)
        try await waitFor(timeout: 5) { server.liveConnectionCount == 0 }

        #expect(
            server.liveConnectionCount == 0,
            """
            The socket is still open after invalidateOffMainActor with the \
            cooperative pool starved, so the invalidation never got a thread to \
            run on. A URLSession retains itself and its delegate until it is \
            invalidated: every session left un-invalidated pins the entire \
            GatewayClient graph, which is why the leaking process held 30 sessions \
            while `leaks` reported nothing — it was all reachable. Keep this on a \
            dedicated queue; a `.utility` task or global queue is what stalled.
            """
        )
    }

    /// The lower-level claim the fix rests on, pinned directly so a future
    /// refactor that "simplifies" `teardownTransport` into a plain nil-out fails
    /// here with the reason attached rather than leaking sockets in production.
    @Test("a released URLSession does not close its connection on its own")
    internal func releasingASessionLeavesTheSocketOpen() async throws {
        let server = try SilentWebSocketServer()
        defer { server.stop() }

        do {
            let session = URLSession(configuration: .default)
            let task = session.webSocketTask(with: server.endpoint)
            task.resume()
            try await waitFor { server.upgradeCount >= 1 }
            // Both references go out of scope here WITHOUT invalidating — the
            // leak shape. Scoping them is the drop; no reassignment needed.
        }
        // Give ARC and the URL loading system every chance to close it.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        #expect(
            server.liveConnectionCount >= 1,
            """
            A released-but-not-invalidated URLSession closed its socket, which \
            contradicts the measurement this fix is built on. If URLSession \
            semantics changed, teardownTransport's contract should be revisited \
            — but do not weaken it on the strength of this test alone.
            """
        )
    }

    /// Poll until `condition` holds or the deadline passes. Returns quietly on
    /// timeout; the caller asserts, so the failure message stays on the claim
    /// rather than on the waiting.
    private func waitFor(
        timeout: TimeInterval = 8,
        _ condition: @Sendable () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}

/// Parks a cooperative-pool thread on a semaphore.
///
/// Blocking a cooperative thread is precisely what Swift concurrency forbids, and
/// the compiler enforces it: `DispatchSemaphore.wait()` is unavailable from an
/// async context. Going through a synchronous function is the deliberate escape,
/// because starving the pool is the *point* here — it reproduces the condition the
/// live socket leak occurred under, at no CPU cost. Test-only; never do this in
/// `Sources`.
private enum PoolHog {
    internal static func block(on gate: DispatchSemaphore) {
        gate.wait()
    }
}

/// A WebSocket server that completes the upgrade handshake and then goes silent
/// — it never answers a Close frame and never sends a frame of its own.
///
/// Silence is the point. A server that echoes the close would tear the socket
/// down from its side, which would mask exactly the defect under test: whether
/// the *client* closes what it abandons.
private final class SilentWebSocketServer: @unchecked Sendable {
    internal let port: UInt16
    /// The WebSocket endpoint, built once here so no test has to force-unwrap a
    /// `URL(string:)` that cannot fail.
    internal var endpoint: URL {
        guard let url = URL(string: "ws://127.0.0.1:\(port)/v1/ws") else {
            preconditionFailure("a loopback URL with a numeric port cannot fail to parse")
        }
        return url
    }
    private let listener: FileHandle
    private let queue = DispatchQueue(label: "portal.tests.silent-ws")
    private var stopped = false
    /// Open connection fds, and the single source of truth for who may close
    /// them. A reader thread and `stop()` both want to close, and closing an fd
    /// twice is not merely untidy: the number is recycled immediately, so the
    /// second close lands on whatever the process opened next. When that turned
    /// out to be one of CFNetwork's *guarded* descriptors the kernel killed the
    /// test process outright with `EXC_GUARD` — which is what the first version
    /// of this server did. Whoever removes the fd from this set under the lock
    /// owns closing it; the other side finds it gone and does nothing.
    private var openConnections: Set<Int32> = []
    private var upgrades = 0
    private var live = 0
    private let lock = NSLock()

    /// Take ownership of `fd` for closing, or report that someone else already
    /// has it. Never close a connection fd without this returning true.
    private func claimForClose(_ fd: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return openConnections.remove(fd) != nil
    }

    /// WebSocket upgrades completed since the server started. Monotonic, so it
    /// measures how many transports the client *dialed*.
    internal var upgradeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return upgrades
    }

    /// Upgraded connections the server has not yet seen close. This is the
    /// number the test asserts on, and it is counted HERE rather than with
    /// `lsof` on the test process for two reasons: it is the gateway's own view
    /// (the thing that actually matters — a socket the server still considers
    /// subscribed), and a client-side fd census also catches `URLSession.shared`'s
    /// keep-alive pool, which `connect()`'s HTTP health probe populates against
    /// this same host:port. That contamination made an earlier version of this
    /// test report a leak that wasn't there.
    internal var liveConnectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return live
    }

    internal init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socketFailed }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0  // let the kernel choose a free port
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 64) == 0 else {
            close(fd)
            throw ServerError.bindFailed
        }

        var bound_addr = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &bound_addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            close(fd)
            throw ServerError.bindFailed
        }
        self.port = bound_addr.sin_port.byteSwapped
        self.listener = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        acceptLoop(fd)
    }

    private func acceptLoop(_ fd: Int32) {
        queue.async { [weak self] in
            while true {
                let conn = accept(fd, nil, nil)
                guard let self, conn >= 0 else { return }
                self.lock.lock()
                let isStopped = self.stopped
                if !isStopped { self.openConnections.insert(conn) }
                self.lock.unlock()
                if isStopped {
                    close(conn)
                    return
                }
                self.handshake(conn)
            }
        }
    }

    /// Read the request, answer it, then hold the connection open and silent
    /// until the peer closes it. No frame is ever sent after the handshake —
    /// including a reply to a Close frame.
    ///
    /// Non-upgrade requests (`connect()` probes `/health` over plain HTTP before
    /// dialing) get a 200 and are closed immediately, and are NOT counted: they
    /// are not transports, and counting them would make the health probe look
    /// like a leak.
    private func handshake(_ conn: Int32) {
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            var request = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !request.contains(Data("\r\n\r\n".utf8)) {
                let count = read(conn, &buffer, buffer.count)
                guard count > 0 else {
                    if self.claimForClose(conn) { close(conn) }
                    return
                }
                request.append(contentsOf: buffer[0..<count])
            }
            let text = String(bytes: request, encoding: .utf8) ?? ""
            let key = text
                .split(separator: "\r\n")
                .first { $0.lowercased().hasPrefix("sec-websocket-key:") }?
                .split(separator: ":", maxSplits: 1).last?
                .trimmingCharacters(in: .whitespaces)

            guard let key else {
                let body = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
                _ = Data(body.utf8).withUnsafeBytes { write(conn, $0.baseAddress, $0.count) }
                if self.claimForClose(conn) { close(conn) }
                return
            }

            let accept = Data(Insecure.sha1(of: key + Self.handshakeGUID)).base64EncodedString()
            let response = "HTTP/1.1 101 Switching Protocols\r\n"
                + "Upgrade: websocket\r\n"
                + "Connection: Upgrade\r\n"
                + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
            _ = Data(response.utf8).withUnsafeBytes { write(conn, $0.baseAddress, $0.count) }

            self.lock.lock()
            self.upgrades += 1
            self.live += 1
            self.lock.unlock()

            // Drain and discard until the peer goes away. Reading is what makes
            // `live` accurate — it's how the server learns the socket closed —
            // and nothing is ever written back, so a client that sends a Close
            // frame and waits for the reply waits forever, exactly like the
            // gateway behaviour that exposed the leak.
            while true {
                let count = read(conn, &buffer, buffer.count)
                if count > 0 { continue }
                break
            }
            self.lock.lock()
            self.live -= 1
            self.lock.unlock()
            if self.claimForClose(conn) { close(conn) }
        }
    }

    private static let handshakeGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    internal func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        // Take every fd out of the set in one go, so the reader threads find
        // theirs already claimed and don't close it a second time.
        let connections = openConnections
        openConnections = []
        lock.unlock()
        // `shutdown` before `close`: it wakes the blocked reader immediately so
        // the thread exits, where a bare close on a descriptor another thread is
        // parked in `read()` on leaves that thread parked on a recycled fd.
        for conn in connections {
            shutdown(conn, SHUT_RDWR)
            close(conn)
        }
        close(listener.fileDescriptor)
    }

    internal enum ServerError: Error {
        case socketFailed
        case bindFailed
    }
}

/// SHA-1 for the WebSocket handshake accept token. CryptoKit's `Insecure.SHA1`
/// would do, but importing CryptoKit for one digest in a test server isn't worth
/// it — and the algorithm is fixed by RFC 6455, so it can't drift.
private enum Insecure {
    internal static func sha1(of string: String) -> [UInt8] {
        var h: [UInt32] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0]
        var message = Array(string.utf8)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
        }

        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 80)
            for index in 0..<16 {
                let base = chunkStart + index * 4
                w[index] = (UInt32(message[base]) << 24)
                    | (UInt32(message[base + 1]) << 16)
                    | (UInt32(message[base + 2]) << 8)
                    | UInt32(message[base + 3])
            }
            for index in 16..<80 {
                w[index] = rotateLeft(w[index - 3] ^ w[index - 8] ^ w[index - 14] ^ w[index - 16], 1)
            }
            var (a, b, c, d, e) = (h[0], h[1], h[2], h[3], h[4])
            for index in 0..<80 {
                let (f, k): (UInt32, UInt32)
                switch index {
                case 0..<20: (f, k) = ((b & c) | (~b & d), 0x5A82_7999)
                case 20..<40: (f, k) = (b ^ c ^ d, 0x6ED9_EBA1)
                case 40..<60: (f, k) = ((b & c) | (b & d) | (c & d), 0x8F1B_BCDC)
                default: (f, k) = (b ^ c ^ d, 0xCA62_C1D6)
                }
                let temp = rotateLeft(a, 5) &+ f &+ e &+ k &+ w[index]
                e = d
                d = c
                c = rotateLeft(b, 30)
                b = a
                a = temp
            }
            h[0] = h[0] &+ a
            h[1] = h[1] &+ b
            h[2] = h[2] &+ c
            h[3] = h[3] &+ d
            h[4] = h[4] &+ e
        }
        return h.flatMap { word in
            [UInt8((word >> 24) & 0xFF), UInt8((word >> 16) & 0xFF),
             UInt8((word >> 8) & 0xFF), UInt8(word & 0xFF)]
        }
    }

    private static func rotateLeft(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value << count) | (value >> (32 - count))
    }
}
