// swiftlint:disable file_length type_body_length
// Legacy giant — split tracked as debt; do not add to this file.
import Foundation
import Combine
import os.log

private let log = Logger(subsystem: "com.portal", category: "Gateway")

/// Resolves a liveness probe exactly once when its ping callback and timeout
/// race. `NSLock` provides the synchronization promised by `@unchecked
/// Sendable`; the continuation is cleared before it is resumed.
internal final class LivenessProbeCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    internal init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    internal func resume(returning value: Bool) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
    }
}

/// WebSocket client for the Hermes gateway JSON-RPC protocol.
///
/// Features:
/// - Ping/pong keepalive every 15s to prevent idle disconnects during long thinking
/// - Auto-reconnect with exponential backoff (1s → 2s → 4s → max 30s)
/// - Session resume on reconnect (preserves conversation context)
/// - Authenticates via Bearer token + optional CF_Authorization cookie on WS upgrade.
@MainActor
final class GatewayClient: NSObject, ObservableObject, URLSessionWebSocketDelegate {

    // MARK: - Published State

    @Published var connectionState: ConnectionState = .disconnected
    @Published var sessionInfo: SessionInfo?
    /// Last WebSocket ping round-trip time (updated every ~15s while
    /// connected; nil until the first pong or after a ping failure).
    @Published private(set) var lastPingRTT: TimeInterval?
    private var debugSnapshot: GatewayDebugSnapshot = GatewayDebugSnapshot()
    var onDebugSnapshotChange: (() -> Void)?
    var snapshotForDebug: GatewayDebugSnapshot {
        // recentEvents is stored oldest-first (append + cap, avoids per-event
        // insert(at: 0) churn during streaming floods); the panel expects
        // newest-first, so reverse only when the panel actually reads it.
        var snapshot = debugSnapshot
        snapshot.recentEvents.reverse()
        return snapshot
    }
    private var debugNotifyTask: Task<Void, Never>?
    private var debugNeedsNotify = false

    // MARK: - Event Stream

    let eventStream = PassthroughSubject<(GatewayEvent, String?), Never>()

    /// Callback for connection log messages (shown in UI).
    var onLog: ((String, Bool) -> Void)?

    // MARK: - Types

    enum ConnectionState: Sendable {
        case disconnected
        case connecting
        case connected
        case reconnecting(attempt: Int)  // auto-reconnect in progress
        case error(String)
    }


    // MARK: - Delegation RPCs

    /// Get delegation status (active subagent counts, depth/cap limits).
    func delegationStatus() async throws -> [String: AnyCodable]? {
        let response = try await call("delegation.status")
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        return response.result?.dictionaryValue
    }

    /// Interrupt a subagent by ID.
    func subagentInterrupt(subagentID: String, sessionID: String? = nil) async throws {
        var params: [String: AnyCodable] = ["subagent_id": AnyCodable(subagentID)]
        if let sid = sessionID {
            params["session_id"] = AnyCodable(sid)
        }
        let response = try await call("subagent.interrupt", params: params)
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
    }

        // MARK: - Spawn Tree RPCs

    /// List saved spawn tree snapshots. Set crossSession=true to list across all sessions.
    func spawnTreeList(sessionID: String? = nil, crossSession: Bool = false, limit: Int = 50) async throws -> [SpawnTreeEntry] {
        var params: [String: AnyCodable] = [
            "limit": AnyCodable(limit),
            "cross_session": AnyCodable(crossSession),
        ]
        if let sid = sessionID {
            params["session_id"] = AnyCodable(sid)
        }
        let response = try await call("spawn_tree.list", params: params)
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result?.dictionaryValue,
              let entries = result["entries"]?.arrayValue else {
            return []
        }
        return entries.compactMap { item -> SpawnTreeEntry? in
            guard let d = item.dictionaryValue else { return nil }
            return SpawnTreeEntry(
                path: d["path"]?.stringValue ?? "",
                sessionID: d["session_id"]?.stringValue ?? "",
                startedAt: d["started_at"]?.doubleValue,
                finishedAt: d["finished_at"]?.doubleValue ?? 0,
                label: d["label"]?.stringValue ?? "",
                subagentCount: d["count"]?.intValue ?? 0
            )
        }
    }

    /// Load a specific spawn tree snapshot by path.
    func spawnTreeLoad(path: String) async throws -> SpawnTreeSnapshot? {
        let response = try await call("spawn_tree.load", params: ["path": AnyCodable(path)])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result?.dictionaryValue else { return nil }
        return SpawnTreeSnapshot.from(result)
    }

    /// Get usage stats for a session.
    func sessionUsage(sessionID: String) async throws -> SessionUsage? {
        let response = try await call("session.usage", params: ["session_id": AnyCodable(sessionID)])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let d = response.result?.dictionaryValue else { return nil }
        return SessionUsage.from(d)
    }

    // MARK: - Session Visualization RPCs

    /// Fetch a timeline of all events in a session for playback visualization (Swift Charts bar/line chart).
    func sessionTimeline(sessionID: String) async throws -> SessionTimeline {
        let response = try await call("session.timeline", params: ["session_id": AnyCodable(sessionID)])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let d = response.result?.dictionaryValue else {
            throw GatewayError.invalidResponse("missing result in session.timeline response")
        }
        let jsonData = try JSONEncoder().encode(d)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(SessionTimeline.self, from: jsonData)
    }

    /// Fetch the prompt assembly breakdown for a session, showing token allocation across
    /// system prompt sections, tool definitions, and conversation history.
    /// Falls back to mock data when the gateway RPC is unavailable.
    func promptBreakdown(sessionID: String) async throws -> PromptBreakdown {
        let response = try await call("session.prompt_breakdown", params: ["session_id": AnyCodable(sessionID)])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result?.dictionaryValue else {
            return PromptBreakdown.mock(sessionID: sessionID)
        }
        let sections = result["sections"]?.arrayValue?.compactMap { s -> PromptSection? in
            guard let sd = s.dictionaryValue else { return nil }
            return PromptSection(
                id: sd["name"]?.stringValue ?? UUID().uuidString,
                name: sd["name"]?.stringValue ?? "",
                source: sd["source"]?.stringValue ?? "",
                contentPreview: String((sd["content"]?.stringValue ?? "").prefix(200)),
                fullContent: sd["content"]?.stringValue ?? "",
                tokenCount: sd["tokens"]?.intValue ?? 0,
                charCount: sd["char_count"]?.intValue ?? 0,
                colorHex: sd["color"]?.stringValue ?? "#888888"
            )
        } ?? []

        return PromptBreakdown(
            sessionID: sessionID,
            model: result["model"]?.stringValue ?? "",
            contextLimit: result["context_limit"]?.intValue ?? 131072,
            totalSystemTokens: result["total_system_tokens"]?.intValue ?? 0,
            sections: sections,
            toolDefinitionsTokenCount: result["tool_definition_tokens"]?.intValue ?? 0,
            toolDefinitionsCount: result["tool_definition_count"]?.intValue ?? 0,
            conversationHistoryTokenCount: result["conversation_tokens"]?.intValue ?? 0,
            conversationHistoryMessageCount: result["conversation_message_count"]?.intValue ?? 0
        )
    }

    // ThoughtGraph visualisation does not require a dedicated RPC method.
    // It is built entirely from existing stream events — toolStart / toolComplete
    // are emitted by the gateway during normal agent execution. ChatViewModel
    // accumulates tool-event pairs and the new ThoughtGraphView renders the
    // DAG from those events, so no new RPC surface is needed.

    // MARK: - Private State

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var requestIDCounter = 0
    private var pendingRequests: [Int: CheckedContinuation<JSONRPCResponse, Error>] = [:]
    private var pendingRequestMethods: [Int: String] = [:]
    private let pendingRequestsLock = NSLock()
    private var gatewayURL: URL
    private(set) var apiKey: String

    /// CF_Authorization cookie from browser-based CF Access login.
    var cfAuthCookie: HTTPCookie?

    // MARK: - Keepalive

    private var pingTimer: Task<Void, Never>?
    private static let pingInterval: TimeInterval = 15  // seconds

    // MARK: - Reconnect

    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt: Int = 0
    private var isHandlingDisconnect = false
    /// True from the moment a backoff timer is armed until it fires and
    /// openWebSocket actually runs. Dedupes the multiple failure signals a
    /// single dead socket emits (receiveLoop error + delegate close) without
    /// blocking the NEXT attempt: guarding on `connectionState ==
    /// .reconnecting` instead meant a failed reconnect attempt could never
    /// schedule another one, wedging the client in `.reconnecting` forever
    /// until app restart (#178).
    private var isReconnectScheduled = false
    private static let maxReconnectDelay: TimeInterval = 30
    static let maxReconnectAttempts: Int = 10
    private var isIntentionalDisconnect = false

    /// True once a socket has actually opened since the reconnect budget was
    /// last granted. This is what makes `resetReconnectBudget` safe.
    ///
    /// #178 made every foreground and every explicit connect grant a fresh
    /// budget so "max retries exceeded" was never a dead end. But the grant was
    /// unconditional, so against a host that is simply unreachable the cap could
    /// never be reached: each reset put `reconnectAttempt` back to 0 and the
    /// client cycled at the 30s ceiling forever. On macOS `scenePhase` flips on
    /// window focus, so clicking away and back was enough to re-arm it. Every
    /// one of those attempts published `.reconnecting`, which the wrapper
    /// collapsed into `isConnecting` — so an endless loop read as a permanent
    /// "Connecting…", the "it never actually opens" report.
    ///
    /// Gating the reset on a real success keeps #178's fix for the case it was
    /// written for (a flaky link that does come back, so each recovery earns the
    /// next budget) while letting a genuinely dead address exhaust its attempts
    /// once and stop with an error the user can act on.
    internal private(set) var hasConnectedSinceBudgetGrant = false

    // MARK: - Session Resume

    /// The session key from the last session.create — used to resume on reconnect.
    private(set) var lastSessionKey: String?
    /// The session ID currently in use.
    private(set) var activeSessionID: String?

    /// Callback for ChatViewModel to handle reconnection (resume vs create).
    var onReconnected: (() async -> Void)?

    // MARK: - Init

    override init() {
        self.gatewayURL = URL(string: Constants.defaultGatewayURL) ?? URL(string: "ws://localhost:8642/v1/ws")!
        self.apiKey = ""
        super.init()
        refreshDebugSnapshot()
        LeakTracker.track(self)
    }

    init(gatewayURL: URL, apiKey: String) {
        self.gatewayURL = gatewayURL
        self.apiKey = apiKey
        super.init()
        refreshDebugSnapshot()
        LeakTracker.track(self)
    }

    /// Stable identity for on-disk caches keyed to a specific backend (e.g.
    /// the wiki graph cache). The host+port of the socket URL distinguishes
    /// gateways without leaking the auth key or per-launch state, and it
    /// survives restarts so cold-open caches actually hit.
    internal var cacheIdentity: String {
        let comps = URLComponents(url: gatewayURL, resolvingAgainstBaseURL: false)
        let host = comps?.host ?? gatewayURL.absoluteString
        let port = comps?.port.map { ":\($0)" } ?? ""
        return "\(host)\(port)"
    }

    // MARK: - Debug Telemetry

    private var stateDescription: String {
        switch connectionState {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reconnecting(let attempt): return "reconnecting #\(attempt)"
        case .error(let message): return "error: \(message)"
        }
    }

    private func refreshDebugSnapshot() {
        pendingRequestsLock.lock()
        let pendingIDs = pendingRequests.keys.sorted()
        let pendingMethods = pendingRequestMethods
        pendingRequestsLock.unlock()

        debugSnapshot.connectionState = stateDescription
        debugSnapshot.socketURL = gatewayURL.absoluteString
        debugSnapshot.isAuthenticated = !apiKey.isEmpty
        debugSnapshot.hasCFAuthCookie = cfAuthCookie != nil
        debugSnapshot.activeSessionID = activeSessionID
        debugSnapshot.lastSessionKey = lastSessionKey
        debugSnapshot.pendingRequestIDs = pendingIDs
        debugSnapshot.pendingRequestMethods = pendingMethods
        debugSnapshot.reconnectAttempt = reconnectAttempt
        scheduleDebugNotify()
    }

    internal func recordDebugEvent(
        _ direction: GatewayDebugSnapshot.EventRecord.Direction,
        name: String,
        sessionID: String? = nil,
        detail: String = ""
    ) {
        let record = GatewayDebugSnapshot.EventRecord(
            timestamp: Date(),
            direction: direction,
            name: name,
            sessionID: sessionID,
            detail: detail
        )
        // Append + cap (oldest-first) instead of insert(at: 0) — avoids O(n)
        // element shifting on every inbound event during streaming floods.
        debugSnapshot.recentEvents.append(record)
        if debugSnapshot.recentEvents.count > 40 {
            debugSnapshot.recentEvents.removeFirst(debugSnapshot.recentEvents.count - 40)
        }
        if direction == .error {
            debugSnapshot.lastErrorAt = record.timestamp
            debugSnapshot.lastError = detail.isEmpty ? name : detail
        }
        if direction == .dropped {
            let reason = detail.isEmpty ? "unspecified" : detail
            if let index = debugSnapshot.droppedEventReasons.firstIndex(where: { $0.reason == reason }) {
                debugSnapshot.droppedEventReasons[index].count += 1
                debugSnapshot.droppedEventReasons[index].lastAt = record.timestamp
            } else {
                debugSnapshot.droppedEventReasons.insert(
                    GatewayDebugSnapshot.DroppedEventReason(reason: reason, count: 1, lastAt: record.timestamp),
                    at: 0
                )
            }
            debugSnapshot.droppedEventReasons.sort { $0.lastAt > $1.lastAt }
            if debugSnapshot.droppedEventReasons.count > 12 {
                debugSnapshot.droppedEventReasons.removeLast(debugSnapshot.droppedEventReasons.count - 12)
            }
        }
        scheduleDebugNotify()
    }

    private func scheduleDebugNotify() {
        guard debugNotifyTask == nil else {
            debugNeedsNotify = true
            return
        }
        debugNeedsNotify = false
        debugNotifyTask = Task { @MainActor in
            onDebugSnapshotChange?()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            debugNotifyTask = nil
            if debugNeedsNotify {
                scheduleDebugNotify()
            }
        }
    }

    func recordDroppedEvent(_ event: GatewayEvent, sessionID: String?, reason: String) {
        recordDebugEvent(.dropped, name: event.debugName, sessionID: sessionID, detail: reason)
    }

    // MARK: - Connection

    func connect() {
        let canConnect: Bool
        switch connectionState {
        case .disconnected, .error:
            canConnect = true
        default:
            canConnect = false
        }
        guard canConnect else { return }

        isIntentionalDisconnect = false
        reconnectAttempt = 0
        isReconnectScheduled = false
        // A fresh dial has earned nothing yet — the next grant must wait for
        // this attempt to actually open, or the cap becomes unreachable again.
        hasConnectedSinceBudgetGrant = false
        connectionState = .connecting
        refreshDebugSnapshot()
        recordDebugEvent(.state, name: "connect", detail: "opening")

        Task {
            // Probe HTTP first for a useful status in the logs, but NEVER
            // let the probe veto the connection — a wrong-looking answer
            // here (proxy quirk, HEAD 405, unrelated server on the default
            // port) used to hard-fail with "HTTP status 404" while the
            // WebSocket itself would have connected fine.
            let httpStatus = await probeHTTPHealth()
            if httpStatus != 200 {
                onLog?("⚠ HTTP health returned \(httpStatus) — trying WS anyway", true)
            }

            // If we have a CF_Authorization cookie, verify it's still valid first
            if cfAuthCookie != nil {
                await verifyCFCookieThenConnect()
            } else {
                openWebSocket()
            }
        }
    }

    /// Grant auto-reconnect a fresh budget. iOS tears the socket down on
    /// every backgrounding, so a flaky stretch can exhaust
    /// `maxReconnectAttempts` — after which `handleDisconnect` parks the
    /// client in a terminal `.error` state and nothing ever reconnects until
    /// process restart. Called on app foreground and on explicit user
    /// connection requests so "max retries exceeded" is never a dead end (#178).
    ///
    /// The grant is **success-gated**: it only applies if a socket has opened
    /// since the last grant (see `hasConnectedSinceBudgetGrant`). Without that
    /// condition an unreachable harness never reaches the cap, because ambient
    /// triggers — macOS window focus, every `connectIfNeeded` — kept zeroing the
    /// counter, and the client retried at the 30s ceiling indefinitely while the
    /// UI showed a motionless "Connecting…".
    ///
    /// A user asking to connect *again* is a different signal from the window
    /// regaining focus, so an explicit retry passes `force: true` to get the old
    /// unconditional behavior.
    internal func resetReconnectBudget(force: Bool = false) {
        guard force || hasConnectedSinceBudgetGrant else {
            log.debug("resetReconnectBudget ignored — no successful connection since the last grant")
            return
        }
        hasConnectedSinceBudgetGrant = false
        guard reconnectAttempt != 0 else { return }
        reconnectAttempt = 0
        refreshDebugSnapshot()
    }

    /// Test seam: drive the private attempt counter without a live socket.
    func setReconnectAttemptForTesting(_ attempt: Int) {
        reconnectAttempt = attempt
        refreshDebugSnapshot()
    }

    /// Test seam: enter `.connecting` without dialing, so the "socket never
    /// opened" failure path can be exercised against no server.
    internal func beginConnectingForTesting() {
        connectionState = .connecting
        refreshDebugSnapshot()
    }

    /// Test seam: stand in for a socket having opened. The real flag is only set
    /// from the `didOpenWithProtocol` delegate callback, which needs a live
    /// server — so the success-gated reset is otherwise untestable.
    internal func markConnectedForTesting() {
        hasConnectedSinceBudgetGrant = true
    }

    /// Test seam: run the disconnect/backoff state machine without a socket.
    func handleDisconnectForTesting(reason: String) {
        handleDisconnect(reason: reason)
    }

    /// Test seam: stand in for the armed backoff timer firing. `openWebSocket`
    /// clears this flag when the scheduled attempt begins; without it a test
    /// walking several attempts is deduped down to one.
    internal func clearReconnectScheduleForTesting() {
        isReconnectScheduled = false
    }

    /// /health on the gateway's own scheme+host+PORT. Dropping the port sent
    /// the probe to whatever squats on :80/:443 (an unrelated local nginx
    /// answered 404 and connect() gave up before ever dialing the socket).
    nonisolated static func healthProbeURL(for gatewayURL: URL) -> URL? {
        guard var components = URLComponents(url: gatewayURL, resolvingAgainstBaseURL: false) else { return nil }
        switch components.scheme {
        case "ws": components.scheme = "http"
        case "wss": components.scheme = "https"
        default: break
        }
        components.path = "/health"
        components.query = nil
        return components.url
    }

    /// Quick HTTP HEAD to the gateway to confirm reachability.
    /// Returns the HTTP status code, or -1 if the request itself failed.
    private func probeHTTPHealth() async -> Int {
        guard let url = Self.healthProbeURL(for: gatewayURL) else { return -1 }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        // GET, not HEAD — the gateway's /health rejects HEAD with 405.
        request.httpMethod = "GET"
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if let cookie = cfAuthCookie {
            HTTPCookieStorage.shared.setCookie(cookie)
        }

        onLog?("Probing HTTP health at \(url)…", false)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            onLog?("HTTP health status: \(status)", status != 200)
            return status
        } catch {
            onLog?("HTTP health probe failed: \(error.localizedDescription)", true)
            return -1
        }
    }

    /// Verify the CF_Authorization cookie is still valid via a quick HTTP check.
    private func verifyCFCookieThenConnect() async {
        guard let healthURL = Self.healthProbeURL(for: gatewayURL) else {
            openWebSocket()
            return
        }

        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 5
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        // Attach CF cookie
        if let cookie = cfAuthCookie {
            HTTPCookieStorage.shared.setCookie(cookie)
        }

        onLog?("Verifying CF Access session…", false)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

            if statusCode == 200 {
                onLog?("✓ CF Access session valid", false)
                openWebSocket()
            } else if statusCode == 302 || statusCode == 401 || statusCode == 403 {
                onLog?("⚠ CF Access session expired (HTTP \(statusCode)), re-auth needed", true)
                cfAuthCookie = nil
                connectionState = .error("CF Access session expired — please re-authenticate")
            } else {
                onLog?("⚠ Unexpected HTTP \(statusCode), trying WS anyway", false)
                openWebSocket()
            }
        } catch {
            onLog?("⚠ HTTP check failed: \(error.localizedDescription), trying WS anyway", false)
            openWebSocket()
        }
    }

    /// How long the WebSocket upgrade may hang before URLSession gives up.
    /// Bounded because a black-holed host (packets dropped with no RST — the
    /// normal failure for a tailnet peer that is up but not serving) would
    /// otherwise inherit the 60s default and show a full minute of
    /// "Connecting…".
    internal static let handshakeTimeout: TimeInterval = 15

    /// The transport config for the gateway socket.
    ///
    /// Extracted from `openWebSocket` so the connectivity semantics below are
    /// assertable in tests — the bug they encode is invisible in a unit test
    /// otherwise, because it manifests as the *absence* of a delegate callback.
    ///
    /// `waitsForConnectivity` must stay FALSE. When true, URLSession treats an
    /// unreachable host as "no path yet" and silently waits for one rather than
    /// failing: no delegate callback fires at all, so `handleDisconnect` never
    /// runs, no `.error` is published, and no reconnect is scheduled. The client
    /// parks in `.connecting`, which every surface renders as "Connecting…",
    /// until `timeoutIntervalForResource` expires five minutes later. That is
    /// the "it says Connecting forever and never opens" bug, and a tailnet
    /// address is its worst case: while Tailscale is down or logged out, a
    /// `100.x` peer is unreachable, so the app looked hung instead of broken.
    ///
    /// Measured against an unreachable `100.64.0.1:8642` — with `true`: no
    /// callback after 25s, task still `.running`. With `false`: `-1004 Could not
    /// connect to the server` in about a second, which drives
    /// `handleDisconnect` → `.error` → backoff retry.
    ///
    /// The tradeoff is deliberate. A genuinely offline device now reports a
    /// failure and retries on backoff instead of hanging on an invisible wait,
    /// and `handleDisconnect` already retries up to `maxReconnectAttempts` —
    /// which is the honest version of "wait for the network", because it says
    /// so on screen.
    internal static func makeSessionConfig() -> URLSessionConfiguration {
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.httpShouldUsePipelining = false
        sessionConfig.waitsForConnectivity = false
        sessionConfig.timeoutIntervalForRequest = handshakeTimeout
        sessionConfig.timeoutIntervalForResource = 300
        return sessionConfig
    }

    private func openWebSocket() {
        let url = gatewayURL, hasKey = !apiKey.isEmpty, hasCookie = cfAuthCookie != nil
        log.debug("Connecting to WS: \(url) auth=\(hasKey) cookie=\(hasCookie)")
        onLog?("Opening WebSocket to \(gatewayURL)…", false)

        // Clean up previous connection. Hand the old session/socket to a
        // background task — invalidateAndCancel() can stall the main actor
        // during reconnect churn (the wake/resume beachball). Nil them out
        // first so the delegate's `session === urlSession` guard drops any late
        // callback the teardown queues against the transport we're replacing.
        stopPingTimer()
        receiveTask?.cancel()
        receiveTask = nil
        teardownTransport(session: urlSession, task: webSocketTask)
        webSocketTask = nil
        urlSession = nil
        failAllPendingRequests(error: GatewayError.disconnected)

        let sessionConfig = Self.makeSessionConfig()

        // Carry CF_Authorization cookie
        if let cookie = cfAuthCookie {
            sessionConfig.httpCookieStorage?.setCookie(cookie)
        }

        var request = URLRequest(url: gatewayURL)
        if !apiKey.isEmpty {
            let authValue = "Bearer \(apiKey)"
            request.setValue(authValue, forHTTPHeaderField: "Authorization")
            // URLSessionWebSocketTask can drop URLRequest headers on some OS
            // releases even though the same code works on others. Keep the
            // header on both the upgrade request and the session config so the
            // API server auth path is reliable in iOS simulator/TestFlight.
            // This must be set before URLSession is created; configuration is
            // copied at init time.
            sessionConfig.httpAdditionalHeaders = ["Authorization": authValue]
        }

        let newSession = URLSession(configuration: sessionConfig, delegate: self, delegateQueue: nil)
        self.urlSession = newSession

        let task = newSession.webSocketTask(with: request)
        self.webSocketTask = task
        debugSnapshot.lastOpenAt = Date()
        refreshDebugSnapshot()
        task.resume()

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    func disconnect() {
        isIntentionalDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        // The armed backoff timer above never fires once cancelled; clear the
        // flag or a later connect()'s disconnects would be treated as
        // already-scheduled and never reconnect.
        isReconnectScheduled = false
        stopPingTimer()
        stopConnection()
    }

    private func stopConnection() {
        receiveTask?.cancel()
        receiveTask = nil
        teardownTransport(session: urlSession, task: webSocketTask)
        webSocketTask = nil
        urlSession = nil

        failAllPendingRequests(error: GatewayError.disconnected)

        debugSnapshot.lastCloseAt = Date()
        refreshDebugSnapshot()

        connectionState = .disconnected
    }

    /// Tear down a WebSocket transport. `invalidateAndCancel()` can block the
    /// caller (it drains delegate callbacks + connection state); on the main
    /// actor during reconnect churn that stall IS the beachball, so it still
    /// runs off-main. Any late delegate callback from this dying session is
    /// ignored by the `session === urlSession` guard in the delegate methods,
    /// since callers nil out `urlSession` before handing it here.
    ///
    /// Two details here are load-bearing, both learned from a live process found
    /// holding **30 ESTABLISHED sockets** to the gateway — one `GatewayClient`
    /// that had dialled 30 transports and closed none. Bytes sat unread in the
    /// kernel receive buffers of several, i.e. the harness was streaming a turn
    /// into sockets nobody was reading. Because every delegate method is gated on
    /// `session === self.urlSession`, those frames were discarded with no log
    /// line and no `recordDroppedEvent`: the session read as "still streaming"
    /// while no updates arrived and the thought graph stayed empty.
    ///
    /// The whole teardown used to sit inside a `Task.detached(priority: .utility)`,
    /// so *nothing* closed the socket unless that task ran — and on the evidence
    /// it didn't. All 30 connections were ESTABLISHED with Send-Q 0: no FIN, and
    /// no Close frame in flight either. Measured against a server that completes
    /// the upgrade and then answers nothing, every teardown that actually executes
    /// closes the socket (`cancel` alone → 0 survivors; `invalidateAndCancel`
    /// alone → 0; both → 0). Only "never ran" reproduces 30 survivors. So the bug
    /// was never *which* calls we make, it was that they were unreachable. Both
    /// halves below are therefore about reachability, not about URLSession:
    ///
    /// 1. **The cancel is synchronous.** `cancel(with:reason:)` is a
    ///    non-blocking signal — it queues a Close frame and returns — so there
    ///    was never a reason to defer it. Inline, closing the socket depends on
    ///    nothing being scheduled at all.
    /// 2. **The deferred invalidation runs on a dedicated queue, not a
    ///    `.utility` pool.** Whatever starves the teardown starves it by QoS:
    ///    measured with the utility band saturated, `Task.detached(.utility)` and
    ///    `DispatchQueue.global(qos: .utility)` both failed to run within 5s,
    ///    while `.default`/`.userInitiated` globals and a dedicated serial queue
    ///    all ran immediately. A global queue is *not* safer than a task here;
    ///    the queue below is, because it brings its own thread.
    nonisolated private func teardownTransport(session: URLSession?, task: URLSessionWebSocketTask?) {
        guard session != nil || task != nil else { return }
        // Close the transport here and now — see (1) above.
        task?.cancel(with: .normalClosure, reason: nil)
        guard let session else { return }
        Self.invalidateOffMainActor(session)
    }

    /// Serial queue for session invalidation — see (2) on `teardownTransport`.
    /// Serial because invalidation is rare and ordering costs nothing, and
    /// dedicated because a shared `.utility` band is exactly what was measured to
    /// stall.
    nonisolated private static let teardownQueue = DispatchQueue(
        label: "com.ethenotethan.Portal.gateway-teardown",
        qos: .utility
    )

    /// Invalidate `session` off the main actor. Split out from `teardownTransport`
    /// so the scheduling choice is assertable on its own: the socket close and the
    /// invalidation are separate leaks. A closed socket whose session was never
    /// invalidated still pins the whole client, because a `URLSession` retains
    /// itself and its delegate until it is invalidated — which is why the leaking
    /// process held 30 sessions while `leaks` reported nothing.
    nonisolated internal static func invalidateOffMainActor(_ session: URLSession) {
        teardownQueue.async {
            session.invalidateAndCancel()
        }
    }

    /// Fails every pending JSON-RPC continuation so no caller hangs forever.
    private func failAllPendingRequests(error: Error) {
        pendingRequestsLock.lock()
        let pending = pendingRequests
        pendingRequests.removeAll()
        pendingRequestMethods.removeAll()
        pendingRequestsLock.unlock()

        for (id, cont) in pending {
            log.debug("failAllPendingRequests: failing id=\(id)")
            cont.resume(throwing: error)
        }
    }

    // MARK: - Ping/Pong Keepalive

    private func startPingTimer() {
        stopPingTimer()
        pingTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.pingInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.sendPing()
            }
        }
    }

    private func stopPingTimer() {
        pingTimer?.cancel()
        pingTimer = nil
    }

    private func sendPing() async {
        guard let task = webSocketTask else { return }
        let start = Date()
        task.sendPing { [weak self] error in
            if let error = error {
                log.debug("Ping failed: \(error)")
                Task { @MainActor in
                    self?.lastPingRTT = nil
                    self?.handleDisconnect(reason: "Ping failed: \(error.localizedDescription)")
                }
            } else {
                // Pong round-trip time — the toolbar status pill's health signal.
                let rtt = Date().timeIntervalSince(start)
                Task { @MainActor in
                    self?.lastPingRTT = rtt
                }
            }
        }
    }

    // MARK: - Auto-Reconnect

    private func handleDisconnect(reason: String) {
        guard !isHandlingDisconnect else {
            log.debug("handleDisconnect skipped (already in progress): \(reason)")
            return
        }
        isHandlingDisconnect = true
        defer { isHandlingDisconnect = false }
        log.debug("Disconnected: \(reason)")
        stopPingTimer()

        failAllPendingRequests(error: GatewayError.disconnected)

        debugSnapshot.lastCloseAt = Date()
        recordDebugEvent(.error, name: "disconnect", detail: reason)

        guard !isIntentionalDisconnect else { return }
        guard !isReconnectScheduled else { return }

        if reconnectAttempt >= Self.maxReconnectAttempts {
            onLog?("✗ Gave up after \(Self.maxReconnectAttempts) attempts — \(reason)", true)
            // Terminal, and now genuinely reachable: with the budget grant
            // success-gated, ambient triggers no longer silently re-arm the
            // loop, so this state persists until the user retries. Name the
            // address — the usual cause is a harness that isn't listening or
            // isn't routable, not a transient blip.
            connectionState = .error(
                "Can't reach \(gatewayURL.host ?? "the harness") after "
                    + "\(Self.maxReconnectAttempts) attempts. \(reason)"
            )
            return
        }

        reconnectAttempt += 1
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)), Self.maxReconnectDelay)
        isReconnectScheduled = true
        connectionState = .reconnecting(attempt: reconnectAttempt)
        refreshDebugSnapshot()
        onLog?("Reconnecting (attempt \(reconnectAttempt), \(String(format: "%.0f", delay))s)…", true)

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            // Attempt in flight: clear the schedule flag so a failure of THIS
            // attempt can schedule the next one (or hit the attempt cap).
            self.isReconnectScheduled = false
            self.openWebSocket()
        }
    }

    // MARK: - JSON-RPC Calls

    /// - Parameter timeout: when non-nil, the call fails with
    ///   `GatewayError.timedOut` if no response arrives within this many
    ///   seconds. Without it a slow or wedged handler leaves the continuation
    ///   pending forever (the "stuck on Loading" class of bug). Off by default
    ///   so existing callers are unchanged; opt in for user-facing fetches.
    internal func call(
        _ method: String,
        params: [String: AnyCodable]? = nil,
        timeout: Double? = nil
    ) async throws -> JSONRPCResponse {
        let id = nextRequestID()

        let request = JSONRPCRequest(id: id, method: method, params: params)
        let data = try JSONEncoder().encode(request)

        guard let webSocketTask = webSocketTask else {
            throw GatewayError.notConnected
        }

        // Register continuation BEFORE sending so the response can't arrive
        // before we're ready to fulfill it (was the root cause of infinite hang).
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequestsLock.lock()
            pendingRequests[id] = continuation
            pendingRequestMethods[id] = method
            let count = pendingRequests.count
            log.debug("call: registered continuation for id=\(id), pending count=\(count)")
            pendingRequestsLock.unlock()
            refreshDebugSnapshot()

            // Arm a timeout, if requested. removePendingRequest returns the
            // continuation only if it's still pending, so the response path and
            // this timer can race safely — whichever wins resumes exactly once.
            if let timeout {
                Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    } catch {
                        // Cancelled before the deadline — leave the request to
                        // the response/disconnect path; don't force a timeout.
                        return
                    }
                    guard let self, let pending = self.removePendingRequest(id: id) else { return }
                    self.recordDebugEvent(.error, name: method, detail: "timed out after \(timeout)s id=\(id)")
                    self.onLog?("✗ \(method) timed out after \(Int(timeout))s (id=\(id))", true)
                    pending.resume(throwing: GatewayError.timedOut(method: method, seconds: timeout))
                }
            }

            // Send AFTER registration — continuation is now safe to fulfill.
            log.debug("call: sending \(method) id=\(id)")
            recordDebugEvent(.outbound, name: method, detail: "id=\(id)")
            onLog?("→ \(method) (id=\(id))", false)
            Task { @MainActor in
                do {
                    guard let jsonString = String(data: data, encoding: .utf8) else {
                        log.error("call: failed to encode JSON as UTF-8 for \(method) id=\(id)")
                        if self.removePendingRequest(id: id) != nil {
                            self.recordDebugEvent(.error, name: method, detail: "UTF-8 encode failed id=\(id)")
                            continuation.resume(throwing: GatewayError.invalidResponse("JSON UTF-8 encoding failed"))
                        }
                        return
                    }
                    try await webSocketTask.send(.string(jsonString))
                } catch {
                    // Send failed — remove continuation and propagate error.
                    // Only resume if it is still pending; a fast disconnect may
                    // already have resumed it via stopConnection().
                    if self.removePendingRequest(id: id) != nil {
                        self.recordDebugEvent(.error, name: method, detail: "send failed id=\(id): \(error.localizedDescription)")
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Default timeout for user-facing RPCs. A wedged or half-open socket
    /// (the wake-from-idle / stale-connection case) must never park the
    /// awaiting main-actor caller forever — that is the beachball. This bounds
    /// the wait; `callWithRetry` turns a single timeout into a transparent
    /// reconnect + one retry so the user's action still lands.
    internal static let hotPathTimeout: Double = 12

    /// Issue an RPC with a bounded timeout; on timeout — the signature of a
    /// half-open socket after wake-from-idle — force a fresh transport and
    /// retry exactly once. Any non-timeout error propagates immediately.
    /// Use this for every user-initiated call (send, resume, create) so the UI
    /// can't hang on a dead connection.
    internal func callWithRetry(
        _ method: String,
        params: [String: AnyCodable]? = nil,
        timeout: Double = GatewayClient.hotPathTimeout
    ) async throws -> JSONRPCResponse {
        do {
            return try await call(method, params: params, timeout: timeout)
        } catch GatewayError.timedOut(_, _) {
            onLog?("⟳ \(method) timed out — reconnecting and retrying once", true)
            recordDebugEvent(.state, name: "retry", detail: "\(method): reconnect after timeout")
            await forceReconnectAndWait(timeout: timeout)
            return try await call(method, params: params, timeout: timeout)
        }
    }

    /// Tear down the (possibly half-open) socket and bring up a fresh one,
    /// waiting up to `timeout` seconds for it to connect. Resets the reconnect
    /// budget so a prior flaky stretch can't veto this user-triggered attempt.
    /// The teardown/dial itself is the same path auto-reconnect uses.
    internal func forceReconnectAndWait(timeout: Double) async {
        reconnectAttempt = 0
        isReconnectScheduled = false
        hasConnectedSinceBudgetGrant = false
        reconnectTask?.cancel()
        reconnectTask = nil
        // The transport being replaced may still report `.connected`. Publish the
        // new dial before opening it so the wait below cannot return success for
        // the stale socket instead of the replacement.
        connectionState = .connecting
        refreshDebugSnapshot()
        openWebSocket()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .connected = connectionState { return }
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return  // cancelled — stop waiting
            }
        }
    }

    /// On wake/foreground the socket may be half-open: the TCP connection has
    /// not been reset, so `connectionState` still reads `.connected` while
    /// nothing actually flows — and the next `call` would hang until the 15s
    /// ping happens to notice (or forever). Send a ping with a short deadline;
    /// if no pong arrives in time, force a fresh transport BEFORE the user's
    /// next action rather than letting that action beachball.
    internal func verifyLivenessOrReconnect(timeout: Double = 4) async {
        guard case .connected = connectionState, let task = webSocketTask else { return }
        let alive = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let completion = LivenessProbeCompletion(cont)
            task.sendPing { error in completion.resume(returning: error == nil) }
            // Guard against sendPing's completion never firing on a half-open
            // socket — the deadline is the real tripwire here.
            Task { @MainActor in
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                } catch {
                    // Cancelled before the deadline — treat as inconclusive and
                    // don't force a reconnect off a cancelled probe.
                    return
                }
                completion.resume(returning: false)
            }
        }
        if !alive {
            onLog?("⚠ wake liveness ping failed — reconnecting", true)
            recordDebugEvent(.state, name: "liveness", detail: "stale socket on wake; reconnecting")
            await forceReconnectAndWait(timeout: GatewayClient.hotPathTimeout)
        }
    }

    // MARK: - Convenience Methods

    /// Resolve gateway-reported Hermes capabilities with conservative fallback.
    func capabilities() async -> GatewayCapabilities {
        let methods = ["gateway.capabilities", "portal.capabilities", "portal.version"]
        var lastError: String?

        for method in methods {
            do {
                let response = try await call(method)
                if let error = response.error {
                    lastError = "\(method): \(error.message)"
                    if error.code == JSONRPCError.methodNotFound.code {
                        continue
                    }
                    continue
                }
                return GatewayCapabilities.from(result: response.result, method: method)
            } catch {
                lastError = "\(method): \(error.localizedDescription)"
                continue
            }
        }

        return GatewayCapabilities.fallback(reason: lastError ?? "Capabilities RPC unsupported")
    }

    /// Create a new agent session.
    func createSession(cols: Int = 120) async throws -> String {
        let response = try await callWithRetry("session.create", params: ["cols": AnyCodable(cols)])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result?.dictionaryValue,
              let sessionID = result["session_id"]?.stringValue else {
            throw GatewayError.invalidResponse("missing session_id in session.create response")
        }
        // Save session key for resume on reconnect
        if let key = result["session_key"]?.stringValue {
            lastSessionKey = key
        }
        activeSessionID = sessionID
        refreshDebugSnapshot()
        return sessionID
    }

    /// Set an ephemeral system prompt on the live agent for a session.
    /// The prompt is appended to the agent's system prompt on every API call
    /// but is NOT persisted to trajectories. Setting empty string clears it.
    func setEphemeralPrompt(sessionID: String, prompt: String) async throws {
        let response = try await call("session.set_prompt", params: [
            "session_id": AnyCodable(sessionID),
            "prompt": AnyCodable(prompt),
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
    }

    /// List active sessions.
    /// Gateway returns: id, title, preview, started_at, message_count, source
    func listSessions() async throws -> [Session] {
        let response = try await call("session.list")
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result?.dictionaryValue,
              let sessionsArray = result["sessions"]?.arrayValue else {
            return []
        }
        return sessionsArray.compactMap { item -> Session? in
            guard let d = item.dictionaryValue else { return nil }
            let id = d["id"]?.stringValue ?? ""
            guard !id.isEmpty else { return nil }

            let startedAt: Date? = {
                if let ts = d["started_at"]?.doubleValue, ts > 0 {
                    return Date(timeIntervalSince1970: ts)
                }
                return nil
            }()

            let endedAt: Date? = {
                if let ts = d["ended_at"]?.doubleValue, ts > 0 {
                    return Date(timeIntervalSince1970: ts)
                }
                return nil
            }()

            let lastActive: Date? = {
                if let ts = d["last_active"]?.doubleValue, ts > 0 {
                    return Date(timeIntervalSince1970: ts)
                }
                return nil
            }()

            return Session(
                id: id,
                title: d["title"]?.stringValue,
                preview: d["preview"]?.stringValue,
                source: d["source"]?.stringValue,
                messageCount: d["message_count"]?.intValue ?? 0,
                startedAt: startedAt,
                endedAt: endedAt,
                lastActive: lastActive,
                runState: SessionRunState(gatewayValue:
                    d["latest_run_state"]?.stringValue
                    ?? d["run_state"]?.stringValue
                    ?? d["state"]?.stringValue
                    ?? d["status"]?.stringValue
                )
            )
        }
    }

    /// List cron jobs via `cron.manage` with action "list".
    /// Gateway returns: {"success": true, "count": N, "jobs": [...]}
    /// Each job has: job_id, name, schedule, next_run_at (ISO8601), last_run_at (ISO8601),
    /// last_status, enabled, state, deliver, prompt_preview.
    func listCronJobs() async throws -> [CronJob] {
        let response = try await call("cron.manage", params: [
            "action": AnyCodable("list")
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result?.dictionaryValue,
              let jobsArray = result["jobs"]?.arrayValue else {
            return []
        }

        let iso8601Formatter = Self.cronISO8601Formatter()

        return jobsArray.compactMap { Self.decodeCronJob(from: $0, using: iso8601Formatter) }
    }

    /// Fetch a single job with its **full** (untruncated) prompt via `cron.manage`
    /// action "describe". Used for lazy fetch when a card expands — `list` only
    /// returns a 100-char `prompt_preview`.
    /// Gateway returns: {"success": true, "job": {..., "prompt": <full>}}
    internal func describeCronJob(id: String) async throws -> CronJob? {
        let response = try await call("cron.manage", params: [
            "action": AnyCodable("describe"),
            "name": AnyCodable(id)
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result?.dictionaryValue,
              let jobDict = result["job"] else {
            return nil
        }
        return Self.decodeCronJob(from: jobDict, using: Self.cronISO8601Formatter())
    }

    /// Fetch the execution ledger for a job via `cron.manage` action "history".
    /// Gateway returns newest-first: {"success": true, "job_id", "count",
    /// "runs": [{started_at, finished_at, status, error, ...}]}.
    internal func cronJobHistory(id: String, limit: Int? = nil) async throws -> [CronRunRecord] {
        var params: [String: AnyCodable] = [
            "action": AnyCodable("history"),
            "name": AnyCodable(id)
        ]
        if let limit {
            params["limit"] = AnyCodable(limit)
        }
        let response = try await call("cron.manage", params: params)
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result?.dictionaryValue,
              let runsArray = result["runs"]?.arrayValue else {
            return []
        }
        let jobName = result["job_name"]?.stringValue ?? id
        let iso8601Formatter = Self.cronISO8601Formatter()
        return runsArray.compactMap { item -> CronRunRecord? in
            guard let d = item.dictionaryValue else { return nil }

            let started: Date? = d["started_at"]?.stringValue.flatMap { iso8601Formatter.date(from: $0) }
            let finished: Date? = d["finished_at"]?.stringValue.flatMap { iso8601Formatter.date(from: $0) }
            let firedAt = started ?? d["claimed_at"]?.stringValue.flatMap { iso8601Formatter.date(from: $0) }

            let duration: TimeInterval? = {
                if let start = started, let end = finished {
                    return max(0, end.timeIntervalSince(start))
                }
                return nil
            }()

            // Normalize backend ledger statuses (completed/failed/running) to the
            // client convention where `isOk` == "ok".
            let rawStatus = d["status"]?.stringValue ?? "unknown"
            let status: String
            switch rawStatus {
            case "completed", "success": status = "ok"
            case "failed": status = "error"
            default: status = rawStatus
            }
            let error = [
                d["error"]?.stringValue,
                d["error_message"]?.stringValue
            ].compactMap { $0 }.first

            return CronRunRecord(
                id: UUID(),
                jobID: id,
                jobName: jobName,
                firedAt: firedAt ?? Date(timeIntervalSince1970: 0),
                status: status,
                duration: duration,
                errorMessage: error
            )
        }
    }

    private static func cronISO8601Formatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    /// Decode one job dict (from `list` or `describe`) into a `CronJob`.
    /// `describe` supplies the full `prompt`; `list` only `prompt_preview`.
    private static func decodeCronJob(from item: AnyCodable, using iso8601Formatter: ISO8601DateFormatter) -> CronJob? {
        guard let d = item.dictionaryValue,
              let jobID = d["job_id"]?.stringValue, !jobID.isEmpty else { return nil }

        let nextRunAt: Date? = d["next_run_at"]?.stringValue.flatMap { iso8601Formatter.date(from: $0) }
        let lastRunAt: Date? = d["last_run_at"]?.stringValue.flatMap { iso8601Formatter.date(from: $0) }

        let promptValue: String? = {
            let candidates = [
                d["prompt"]?.stringValue,
                d["full_prompt"]?.stringValue,
                d["prompt_text"]?.stringValue,
                d["cron_prompt"]?.stringValue,
                d["command"]?.stringValue,
                d["task"]?.stringValue,
                d["script"]?.stringValue,
                d["description"]?.stringValue,
                d["body"]?.stringValue,
                d["text"]?.stringValue,
                d["message"]?.stringValue,
                d["query"]?.stringValue,
                d["content"]?.stringValue,
                d["args"]?.stringValue,
                d["input"]?.stringValue,
                d["prompt_preview"]?.stringValue
            ]
            return candidates.compactMap { $0 }.first
        }()

        let lastError: String? = [
            d["last_error"]?.stringValue,
            d["error_message"]?.stringValue,
            d["error"]?.stringValue,
            d["last_error_message"]?.stringValue
        ].compactMap { $0 }.first

        return CronJob(
            id: jobID,
            name: d["name"]?.stringValue ?? jobID,
            schedule: d["schedule"]?.stringValue ?? "",
            nextRunAt: nextRunAt,
            lastRunAt: lastRunAt,
            lastStatus: d["last_status"]?.stringValue,
            enabled: d["enabled"]?.boolValue ?? true,
            state: d["state"]?.stringValue ?? "scheduled",
            deliver: d["deliver"]?.stringValue ?? "local",
            promptPreview: d["prompt_preview"]?.stringValue,
            prompt: promptValue,
            lastError: lastError
        )
    }

    // MARK: - Skills RPCs

    func listSkills() async throws -> [String: [String]] {
        let response = try await call("skills.manage", params: [
            "action": AnyCodable("list")
        ])
        if let error = response.error {
            log.error("listSkills: RPC error code=\(error.code) message=\(error.message)")
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }

        // Handle case where result is a string (e.g. "No skills configured")
        if let stringResult = response.result?.stringValue {
            log.info("listSkills: result is a string: '\(stringResult)'")
            return [:]
        }

        guard let result = response.result?.dictionaryValue else {
            log.info("listSkills: result is nil or not a dict, raw=\(String(describing: response.result))")
            return [:]
        }

        let keys = result.keys.sorted()
        log.info("listSkills: result keys=\(keys)")
        for k in keys {
            let v = result[k]
            log.info("listSkills: key=\(k) type=\(type(of: v)) value=\(String(describing: v))")
        }

        var categories: [String: [String]] = [:]

        // Gateway may return flat {category: [names]} or nested under "skills"/"categories" key
        let sourceDict: [String: AnyCodable]
        if let nested = result["skills"]?.dictionaryValue {
            sourceDict = nested
            log.info("listSkills: using nested 'skills' key")
        } else if let nested = result["categories"]?.dictionaryValue {
            sourceDict = nested
            log.info("listSkills: using nested 'categories' key")
        } else {
            sourceDict = result
            log.info("listSkills: using flat result dict")
        }

        for (key, value) in sourceDict {
            if key == "action" || key == "status" || key == "message" { continue }
            if let arr = value.arrayValue {
                let names = arr.compactMap { $0.stringValue }
                if !names.isEmpty {
                    categories[key] = names
                    log.info("listSkills: category=\(key) names=\(names)")
                }
            } else if let str = value.stringValue {
                categories[key] = [str]
                log.info("listSkills: category=\(key) single=\(str)")
            }
        }

        if categories.isEmpty {
            log.warning("listSkills: no categories parsed from \(sourceDict.count) source keys")
        }

        return categories
    }

    func scanSkillCommands() async throws -> [SkillInfo] {
        let response = try await call("commands.catalog")
        if let error = response.error {
            log.error("scanSkillCommands: RPC error code=\(error.code) message=\(error.message)")
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result?.dictionaryValue else {
            log.info("scanSkillCommands: result is nil")
            return []
        }

        log.info("scanSkillCommands: result keys=\(result.keys.sorted())")

        var skills: [SkillInfo] = []
        if let pairs = result["commands"]?.arrayValue {
            for pair in pairs {
                guard let arr = pair.arrayValue, arr.count >= 2,
                      let key = arr[0].stringValue,
                      key.hasPrefix("/") else { continue }
                let desc = arr[1].stringValue ?? ""
                skills.append(SkillInfo(
                    name: key,
                    description: desc,
                    category: "general",
                    source: "local",
                    identifier: nil,
                    tags: [],
                    skillMdPath: nil,
                    skillDir: nil,
                    skillMdPreview: nil,
                    skillMdFullContent: nil,
                    slashCommand: key
                ))
            }
        }
        log.info("scanSkillCommands: found \(skills.count) skill commands")
        return skills
    }

    func inspectSkill(name: String) async throws -> SkillInfo? {
        let response = try await call("skills.manage", params: [
            "action": AnyCodable("inspect"),
            "query": AnyCodable(name)
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let infoDict = response.result?.dictionaryValue?["info"]?.dictionaryValue else { return nil }
        return SkillInfo.fromInspectDict(infoDict)
    }

    /// Read the full SKILL.md content for a skill.
    func readSkillMarkdown(name: String) async throws -> String {
        let response = try await call("skills.manage", params: [
            "action": AnyCodable("read"),
            "query": AnyCodable(name)
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        // Try multiple response formats:
        // 1. {"content": "..."} - standard wrapper
        // 2. {"skill_md_full": "..."} - inspect-style field
        // 3. {"content": {"text": "..."}} - nested content
        // 4. raw string - direct content
        if let dict = response.result?.dictionaryValue {
            if let content = dict["content"]?.stringValue, !content.isEmpty {
                return content
            }
            if let full = dict["skill_md_full"]?.stringValue, !full.isEmpty {
                return full
            }
            if let nested = dict["content"]?.dictionaryValue?["text"]?.stringValue, !nested.isEmpty {
                return nested
            }
            if let result = dict["result"]?.stringValue, !result.isEmpty {
                return result
            }
        }
        if let raw = response.result?.stringValue, !raw.isEmpty {
            return raw
        }
        return ""
    }

    /// Write (overwrite) the full SKILL.md content for a skill.
    func writeSkillMarkdown(name: String, content: String) async throws -> Bool {
        let response = try await call("skills.manage", params: [
            "action": AnyCodable("write"),
            "query": AnyCodable(name),
            "content": AnyCodable(content)
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        return response.result?.dictionaryValue?["success"]?.boolValue ?? true
    }

    func searchSkills(query: String) async throws -> [SkillSearchResult] {
        let response = try await call("skills.manage", params: [
            "action": AnyCodable("search"),
            "query": AnyCodable(query)
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let results = response.result?.dictionaryValue?["results"]?.arrayValue else { return [] }
        return results.compactMap { SkillSearchResult.from($0.dictionaryValue ?? [:]) }
    }

    func installSkill(name: String) async throws -> Bool {
        let response = try await call("skills.manage", params: [
            "action": AnyCodable("install"),
            "query": AnyCodable(name)
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        return response.result?.dictionaryValue?["installed"]?.boolValue ?? false
    }

    func uninstallSkill(name: String) async throws -> Bool {
        let response = try await call("skills.manage", params: [
            "action": AnyCodable("uninstall"),
            "query": AnyCodable(name)
        ])
        if let error = response.error {
            if error.code == 4017 {
                return try await uninstallSkillViaSlashExec(name)
            }
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        return true
    }

    private func uninstallSkillViaSlashExec(_ name: String) async throws -> Bool {
        let response = try await call("slash.exec", params: [
            "command": AnyCodable("skills uninstall \(name)"),
            "session_id": AnyCodable(activeSessionID ?? "")
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        return true
    }

    func reloadSkills() async throws -> SkillsReloadResult {
        let response = try await call("skills.reload")
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result?.dictionaryValue else {
            return SkillsReloadResult(output: "Reloaded", added: [], removed: [], total: 0)
        }
        let added = result["result"]?.dictionaryValue?["added"]?.arrayValue?.compactMap { $0.dictionaryValue?["name"]?.stringValue } ?? []
        let removed = result["result"]?.dictionaryValue?["removed"]?.arrayValue?.compactMap { $0.dictionaryValue?["name"]?.stringValue } ?? []
        let total = result["result"]?.dictionaryValue?["total"]?.intValue ?? 0
        let output = result["output"]?.stringValue ?? "Reloaded"
        return SkillsReloadResult(output: output, added: added, removed: removed, total: total)
    }

    /// Record the active skills for a session.
    ///
    /// Intentionally a no-op against the gateway. This used to call
    /// `session.attach_skills`, which no gateway has ever implemented — every
    /// attach fired an RPC that came back method-not-found, and all three call
    /// sites discarded that error rather than surfacing it, so the failure was
    /// invisible while looking like the mechanism that made skills work.
    ///
    /// What actually delivers a skill is the client: `ChatViewModel` prepends
    /// each attached skill's SKILL.md to the outgoing prompt. Attachment is
    /// therefore client-side state, and the app records it per turn on
    /// `ChatMessage.skills`.
    ///
    /// Kept as a method (rather than deleted from `AgentBackend`) because the
    /// gateway owning session-skill state is a reasonable future: it would let
    /// other clients see what a session is using, and `session.info` already has
    /// a `skills` field — one that currently reports the host's whole installed
    /// catalog rather than the session's, so it can't be read as attachment
    /// today. When that RPC exists, this is where it goes.
    internal func setSessionSkills(sessionID _: String, skillNames _: [String]) async throws {}

    // MARK: - Activity Inbox RPCs

    func listActivityItems(limit: Int = 100, includeRead: Bool = true, includeDismissed: Bool = false) async throws -> [ActivityItem] {
        let response = try await call("activity.list", params: [
            "limit": AnyCodable(limit),
            "include_read": AnyCodable(includeRead),
            "include_dismissed": AnyCodable(includeDismissed),
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result?.dictionaryValue else {
            if let arr = response.result?.arrayValue {
                return arr.compactMap { $0.dictionaryValue.flatMap(ActivityItem.from) }
            }
            return []
        }
        let itemsArray = result["items"]?.arrayValue
            ?? result["activities"]?.arrayValue
            ?? result["records"]?.arrayValue
        guard let itemsArray else {
            return []
        }
        return itemsArray.compactMap { $0.dictionaryValue.flatMap(ActivityItem.from) }
    }

    func markActivityRead(activityID: String, read: Bool = true) async throws -> ActivityItem {
        let response = try await call("activity.mark_read", params: [
            "activity_id": AnyCodable(activityID),
            "read": AnyCodable(read),
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let activity = response.result?.dictionaryValue?["activity"]?.dictionaryValue.flatMap(ActivityItem.from) else {
            throw GatewayError.invalidResponse("missing activity in activity.mark_read response")
        }
        return activity
    }

    func dismissActivity(activityID: String) async throws -> ActivityItem {
        let response = try await call("activity.dismiss", params: [
            "activity_id": AnyCodable(activityID)
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let activity = response.result?.dictionaryValue?["activity"]?.dictionaryValue.flatMap(ActivityItem.from) else {
            throw GatewayError.invalidResponse("missing activity in activity.dismiss response")
        }
        return activity
    }

    func getActivityArtifact(artifactID: String) async throws -> ActivityArtifactContent {
        let response = try await call("activity.artifacts.get", params: [
            "artifact_id": AnyCodable(artifactID)
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let artifact = response.result?.dictionaryValue?["artifact"]?.dictionaryValue.flatMap(ActivityArtifactContent.from) else {
            throw GatewayError.invalidResponse("missing artifact in activity.artifacts.get response")
        }
        return artifact
    }

    func submitPrompt(sessionID: String, text: String) async throws {
        // Retry-once on timeout: after wake-from-idle the socket is often
        // half-open, so the first submit can wedge — reconnect and resend
        // rather than leave the composer spinning forever.
        let response = try await callWithRetry("prompt.submit", params: [
            "session_id": AnyCodable(sessionID),
            "text": AnyCodable(text),
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
    }

    // MARK: - File Upload (HTTP)

    /// Convert the WebSocket URL to an HTTP base URL for file downloads/uploads.
    /// e.g. ws://127.0.0.1:8642/v1/ws → http://127.0.0.1:8642
    private var httpBaseURL: URL? {
        URL(string: gatewayURL.absoluteString.replacingOccurrences(
            of: "/v1/ws", with: ""
        ).replacingOccurrences(
            of: "ws://", with: "http://"
        ).replacingOccurrences(
            of: "wss://", with: "https://"
        ))
    }

    /// Rewrites a server-provided media/asset URL to use THIS gateway's host
    /// when the server handed back a loopback address.
    ///
    /// The digest pipeline builds video_url with a hardcoded `localhost:8642`
    /// base instead of the request's public host, so a client connected to a
    /// remote gateway gets an unreachable `http://localhost:8642/v1/media/…`
    /// URL (connection refused → the player hangs forever). Swap the host/port
    /// for the gateway we're actually connected to; the path is preserved.
    /// Non-loopback URLs are returned unchanged.
    func resolvedMediaURL(_ raw: String) -> String {
        guard let comps = URLComponents(string: raw),
              let host = comps.host,
              host == "localhost" || host == "127.0.0.1" || host == "::1",
              let base = httpBaseURL,
              let baseComps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { return raw }

        var rewritten = comps
        rewritten.scheme = baseComps.scheme
        rewritten.host = baseComps.host
        rewritten.port = baseComps.port
        return rewritten.string ?? raw
    }

    /// Download a file from the gateway HTTP endpoint.
    /// - Parameters:
    ///   - url: The full URL to download (e.g. http://gateway:8642/v1/files/{session}/{file}.ext)
    ///   - token: Bearer token for authorization.
    /// - Returns: The downloaded file data.
    func downloadFile(from url: URL, token: String? = nil) async throws -> Data {
        log.info("Downloading file: \(url.lastPathComponent)")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 120

        let authToken = token ?? apiKey
        if !authToken.isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        if let cookie = cfAuthCookie {
            HTTPCookieStorage.shared.setCookie(cookie)
        }

        let (responseData, httpResponse) = try await URLSession.shared.data(for: request)

        guard let http = httpResponse as? HTTPURLResponse else {
            throw GatewayError.invalidResponse("download failed: no HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: responseData, encoding: .utf8) ?? "(binary)"
            throw GatewayError.invalidResponse("download failed: HTTP \(http.statusCode) — \(body)")
        }

        log.info("Download succeeded: \(responseData.count) bytes")
        return responseData
    }

    /// Upload file data to the gateway via HTTP multipart POST.
    /// Returns the server-side file path on success.
    func uploadFile(data: Data, filename: String, mimeType: String, sessionID: String? = nil) async throws -> String {
        guard let httpBase = httpBaseURL else {
            throw GatewayError.invalidResponse("cannot derive HTTP base URL from \(gatewayURL)")
        }

        var components = URLComponents(url: httpBase, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.append(URLQueryItem(name: "filename", value: filename))
        if let sid = sessionID {
            queryItems.append(URLQueryItem(name: "session_id", value: sid))
        }
        components?.queryItems = queryItems

        guard let uploadURL = components?.url?.appendingPathComponent("v1/upload") else {
            throw GatewayError.invalidResponse("cannot build upload URL")
        }

        log.info("Uploading file: \(filename) (\(data.count) bytes) to \(uploadURL.host ?? "unknown")")

        let boundary = "Boundary-\(UUID().uuidString)"
        var requestBody = Data()

        requestBody.append(Data("--\(boundary)\r\n".utf8))
        requestBody.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        requestBody.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        requestBody.append(data)
        requestBody.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if let cookie = cfAuthCookie {
            HTTPCookieStorage.shared.setCookie(cookie)
        }

        let (responseData, httpResponse) = try await URLSession.shared.data(for: request)

        guard let http = httpResponse as? HTTPURLResponse else {
            throw GatewayError.invalidResponse("upload failed: no HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: responseData, encoding: .utf8) ?? "(binary)"
            throw GatewayError.invalidResponse("upload failed: HTTP \(http.statusCode) — \(body)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let serverPath = json["path"] as? String else {
            throw GatewayError.invalidResponse("upload response missing 'path' field")
        }

        log.info("Upload succeeded: \(serverPath)")
        return serverPath
    }

    /// Attach an image to the current session. Must be called before submitPrompt.
    /// The gateway validates the file extension and stores it in session state.
    func attachImage(path: String, sessionID: String? = nil) async throws {
        var params: [String: AnyCodable] = ["path": AnyCodable(path)]
        if let sid = sessionID {
            params["session_id"] = AnyCodable(sid)
        }
        let response = try await call("image.attach", params: params)
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
    }

    func interrupt(sessionID: String) async throws {
        let response = try await call("session.interrupt", params: [
            "session_id": AnyCodable(sessionID),
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
    }

    func respondApproval(sessionID: String, choice: String, all: Bool = false) async throws {
        let response = try await call("approval.respond", params: [
            "session_id": AnyCodable(sessionID),
            "choice": AnyCodable(choice),
            "all": AnyCodable(all),
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
    }

    /// Answer a blocking clarify.request prompt. `requestID` must be the
    /// request_id from the clarify.request event; the gateway resolves the
    /// waiting agent thread by that key.
    func respondClarify(requestID: String, answer: String) async throws {
        let response = try await call("clarify.respond", params: [
            "request_id": AnyCodable(requestID),
            "answer": AnyCodable(answer),
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
    }

    func closeSession(sessionID: String) async throws {
        let response = try await call("session.close", params: [
            "session_id": AnyCodable(sessionID),
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
    }

    /// Resume an existing session by database-format ID.
    /// Returns the new short hex session ID and any history messages from the gateway.
    /// The `sessionID` param should be the database-format ID (e.g., "20260501_112429_d91274").
    func resumeSession(key: String) async throws -> (sessionID: String, messages: [[String: AnyCodable]]) {
        let response = try await callWithRetry("session.resume", params: [
            "session_id": AnyCodable(key),
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result?.dictionaryValue,
              let sessionID = result["session_id"]?.stringValue else {
            throw GatewayError.invalidResponse("missing session_id in session.resume response")
        }
        activeSessionID = sessionID
        refreshDebugSnapshot()

        // Parse history messages if present
        let historyMessages = result["messages"]?.arrayValue?.compactMap { $0.dictionaryValue } ?? []
        return (sessionID: sessionID, messages: historyMessages)
    }

    /// Fetch conversation history for a session.
    func sessionHistory(sessionID: String) async throws -> [[String: AnyCodable]] {
        let response = try await call("session.history", params: [
            "session_id": AnyCodable(sessionID),
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result?.dictionaryValue else {
            return []
        }
        return result["messages"]?.arrayValue?.compactMap { $0.dictionaryValue } ?? []
    }

    /// Get session title + session_key (database ID) from the gateway.
    /// `session_id` param must be the short hex ID (gatewayID).
    /// Returns (title, sessionKey) where sessionKey is the database-format ID.
    func sessionTitle(sessionID: String) async throws -> (title: String, sessionKey: String?) {
        let response = try await call("session.title", params: [
            "session_id": AnyCodable(sessionID),
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result?.dictionaryValue else {
            return (title: "", sessionKey: nil)
        }
        let title = result["title"]?.stringValue ?? ""
        let sessionKey = result["session_key"]?.stringValue
        return (title: title, sessionKey: sessionKey)
    }

    /// Peek at a session owned by another transport.
    /// Uses `session.resume` to temporarily load the session, captures history
    /// and usage, then closes the peek session to clean up.
    /// IMPORTANT: This is expensive (creates a full agent) and overwrites the
    /// approval callback for the session_key. Use sparingly.
    func peekSession(sessionKey: String) async throws -> PeekResult {
        // 1. Resume with the database-format ID
        let response = try await call("session.resume", params: [
            "session_id": AnyCodable(sessionKey),
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result?.dictionaryValue,
              let shortID = result["session_id"]?.stringValue else {
            throw GatewayError.invalidResponse("missing session_id in peek resume")
        }

        // 2. Parse messages from the resume response
        let messages = result["messages"]?.arrayValue?.compactMap { $0.dictionaryValue } ?? []

        // 3. Get usage via the new short ID
        var usage: SessionUsage?
        if let usageResult = try? await sessionUsage(sessionID: shortID) {
            usage = usageResult
        }

        // 4. Close the peek session immediately
        _ = try? await call("session.close", params: [
            "session_id": AnyCodable(shortID),
        ])

        return PeekResult(
            sessionKey: sessionKey,
            gatewayID: shortID,
            messages: messages,
            usage: usage
        )
    }

    struct PeekResult {
        let sessionKey: String
        let gatewayID: String
        let messages: [[String: AnyCodable]]
        let usage: SessionUsage?
    }

    func setConfig(key: String, value: String, sessionID: String? = nil) async throws {
        var params: [String: AnyCodable] = [
            "key": AnyCodable(key),
            "value": AnyCodable(value),
        ]
        if let sid = sessionID {
            params["session_id"] = AnyCodable(sid)
        }
        let response = try await call("config.set", params: params)
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
    }

    /// Switch the session's model via config.set, surfacing the gateway's
    /// verdict: it may accept with a warning, or gate an expensive model
    /// behind confirmation (`confirmRequired` — resend with `confirm: true`
    /// after the user agrees). Plain setConfig discards those fields.
    func switchModel(_ model: String, provider: String? = nil, sessionID: String, confirm: Bool = false) async throws -> ModelSwitchOutcome {
        // A bare model ID resolves against the gateway's CURRENT provider —
        // picks from another provider's picker section must say which one.
        // The gateway's parse_model_flags handles "--provider <slug>" inside
        // the value (same syntax as the TUI's /model command).
        let value = provider.map { "\(model) --provider \($0)" } ?? model
        var params: [String: AnyCodable] = [
            "key": AnyCodable("model"),
            "value": AnyCodable(value),
            "session_id": AnyCodable(sessionID),
        ]
        if confirm {
            params["confirm_expensive_model"] = AnyCodable(true)
        }
        let response = try await call("config.set", params: params)
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        return ModelSwitchOutcome.from(response.result?.dictionaryValue)
    }

    /// Fetch the gateway's model inventory (`model.options`) — providers with
    /// curated model lists, auth state, and the current model. Returns nil on
    /// gateways that predate the RPC so callers fall back to the static
    /// catalog. `refresh` busts the gateway's 1h provider-catalog cache.
    func modelOptions(sessionID: String? = nil, refresh: Bool = false) async throws -> ModelCatalog? {
        var params: [String: AnyCodable] = [:]
        if let sid = sessionID {
            params["session_id"] = AnyCodable(sid)
        }
        if refresh {
            params["refresh"] = AnyCodable(true)
        }
        let response = try await call("model.options", params: params)
        if let error = response.error {
            // Method-not-found on an older gateway is a fallback, not a failure.
            if error.code == -32601 { return nil }
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result?.dictionaryValue else { return nil }
        return ModelCatalog.from(result)
    }

    // MARK: - Living Artifact RPCs

    /// Upsert a living artifact (server merges per kind; revisioned).
    func artifactSet(
        id: String, kind: String, content: String,
        title: String? = nil, replace: Bool = false
    ) async throws -> LivingArtifact? {
        var params: [String: AnyCodable] = [
            "id": AnyCodable(id),
            "kind": AnyCodable(kind),
            "content": AnyCodable(content),
            "updated_by": AnyCodable("app:\(SessionMetaSyncService.deviceID.prefix(8))"),
        ]
        if let title { params["title"] = AnyCodable(title) }
        if replace { params["replace"] = AnyCodable(true) }
        let response = try await call("artifact.set", params: params)
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        return LivingArtifact.from(response.result?.dictionaryValue?["artifact"]?.dictionaryValue)
    }

    /// Fetch one artifact with content; nil when not found.
    func artifactGet(id: String) async throws -> LivingArtifact? {
        let response = try await call("artifact.get", params: ["id": AnyCodable(id)])
        if let error = response.error {
            if error.code == 4004 { return nil }
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        return LivingArtifact.from(response.result?.dictionaryValue?["artifact"]?.dictionaryValue)
    }

    /// All artifacts without content, newest first. nil = gateway predates
    /// the artifact surface (method not found) — callers stay local-only.
    func artifactList() async throws -> [LivingArtifact]? {
        let response = try await call("artifact.list")
        if let error = response.error {
            if error.code == -32601 { return nil }
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        let rows = response.result?.dictionaryValue?["artifacts"]?.arrayValue ?? []
        return rows.compactMap { LivingArtifact.from($0.dictionaryValue) }
    }

    func artifactDelete(id: String) async throws {
        let response = try await call("artifact.delete", params: ["id": AnyCodable(id)])
        if let error = response.error, error.code != 4004 {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
    }

    /// Revision metadata (no content), newest first.
    func artifactRevisions(id: String) async throws -> [ArtifactRevision] {
        let response = try await call("artifact.revisions", params: ["id": AnyCodable(id)])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        let rows = response.result?.dictionaryValue?["revisions"]?.arrayValue ?? []
        return rows.compactMap { ArtifactRevision.from($0.dictionaryValue) }
    }

    /// Invoke a backend intent declared in an artifact's action manifest.
    /// The gateway resolves the binding from `artifactRev` and validates the
    /// registered handler — the client sends only stable identifiers, never
    /// executable content or intent names. Returns nil on method-not-found
    /// (gateway predates the action surface).
    internal func artifactActionInvoke(
        artifactID: String,
        artifactRev: Int,
        bindingID: String,
        entityRef: String,
        idempotencyKey: String
    ) async throws -> ArtifactActionInvokeResult? {
        let params: [String: AnyCodable] = [
            "artifact_id": AnyCodable(artifactID),
            "artifact_rev": AnyCodable(artifactRev),
            "binding_id": AnyCodable(bindingID),
            "entity_ref": AnyCodable(entityRef),
            "idempotency_key": AnyCodable(idempotencyKey),
        ]
        let response = try await call("artifact.action.invoke", params: params)
        if let error = response.error {
            if error.code == -32601 { return nil }
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        return ArtifactActionInvokeResult.from(response.result?.dictionaryValue)
    }

    /// Query the invocation ledger for an artifact — newest first.
    /// Used to re-hydrate intent badge state after an app restart.
    /// Returns nil on method-not-found (gateway predates §2).
    internal func artifactActionLog(
        artifactID: String,
        bindingID: String? = nil,
        limit: Int = 50
    ) async throws -> [[String: AnyCodable]]? {
        var params: [String: AnyCodable] = [
            "artifact_id": AnyCodable(artifactID),
            "limit": AnyCodable(limit),
        ]
        if let bindingID { params["binding_id"] = AnyCodable(bindingID) }
        let response = try await call("artifact.action.log", params: params)
        if let error = response.error {
            if error.code == -32601 { return nil }
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        return response.result?.dictionaryValue?["records"]?.arrayValue?
            .compactMap { $0.dictionaryValue }
    }

    /// Confirm a pending backend intent (destructive actions require this
    /// second step). `challenge` comes from the invoke response — it is
    /// bound to actor, artifact revision, binding, resolved target, and expiry
    /// on the server. An artifact cannot weaken confirmation policy by
    /// declaring `confirm: false`.
    internal func artifactActionConfirm(
        artifactID: String,
        challenge: String
    ) async throws -> ArtifactActionInvokeResult? {
        let params: [String: AnyCodable] = [
            "artifact_id": AnyCodable(artifactID),
            "challenge": AnyCodable(challenge),
        ]
        let response = try await call("artifact.action.confirm", params: params)
        if let error = response.error {
            if error.code == -32601 { return nil }
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        return ArtifactActionInvokeResult.from(response.result?.dictionaryValue)
    }

    /// One revision's full content.
    func artifactRevision(id: String, rev: Int) async throws -> ArtifactRevision? {
        let response = try await call("artifact.revision", params: [
            "id": AnyCodable(id), "rev": AnyCodable(rev),
        ])
        if let error = response.error {
            if error.code == 4004 { return nil }
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        return ArtifactRevision.from(response.result?.dictionaryValue?["revision"]?.dictionaryValue)
    }

    // MARK: - Voice RPCs

    /// Toggle voice mode on/off or check status.
    internal func voiceToggle(action: String) async throws -> [String: AnyCodable]? {
        let response = try await call("voice.toggle", params: ["action": AnyCodable(action)])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        return response.result?.dictionaryValue
    }

    /// Start or stop VAD-bounded push-to-talk capture.
    /// On start, the gateway emits `voice.transcript` events with transcribed text.
    internal func voiceRecord(action: String) async throws {
        let response = try await call("voice.record", params: ["action": AnyCodable(action)])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
    }

    // MARK: - Private

    /// Get a config value from the gateway.
    func getConfig(key: String) async throws -> [String: AnyCodable]? {
        let response = try await call("config.get", params: ["key": AnyCodable(key)])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        return response.result?.dictionaryValue
    }

    private func nextRequestID() -> Int {
        requestIDCounter += 1
        return requestIDCounter
    }

    private func receiveLoop() async {
        guard let webSocketTask = webSocketTask else { return }

        do {
            while true {
                let message = try await webSocketTask.receive()

                let data: Data?
                switch message {
                case .data(let d):
                    data = d
                case .string(let text):
                    data = text.data(using: .utf8)
                @unknown default:
                    data = nil
                }
                guard let data else { continue }

                // Parse off the main actor so streaming floods (dozens of
                // events/sec, payloads up to hundreds of KB) don't stall the
                // UI. Awaited inline so per-connection event ordering is
                // preserved — do NOT parallelize parsing across messages.
                // (No PerfSignposter wrap here: the parsed value is non-Sendable
                // and crossing it back out of a signpost closure trips Swift 6
                // strict concurrency. The detached parse is the measured work
                // anyway; signposts cover the higher-level feed/video paths.)
                let parsed = await Task.detached(priority: .userInitiated) {
                    Self.parseMessage(data)
                }.value
                // Connection may have been torn down while parsing.
                guard !Task.isCancelled else { return }
                applyParsedMessage(parsed)
            }
        } catch {
            log.debug("receiveLoop error: \(error)")
            switch connectionState {
            case .connecting, .connected, .reconnecting:
                let nsError = error as NSError
                if nsError.domain == NSPOSIXErrorDomain && nsError.code == 57 {
                    log.debug("receiveLoop ended after socket close; waiting for delegate close")
                    return
                }
                // `.connecting` used to be special-cased into a bare `.error`
                // with no retry scheduled, which left a failed FIRST connect
                // permanently dead — the case that matters most, since a
                // harness that isn't up yet is exactly when you want a retry.
                // It now takes the same path as a drop from `.connected`;
                // handleDisconnect owns the terminal-vs-retry decision and
                // dedupes the several signals one dead socket emits.
                handleDisconnect(reason: error.localizedDescription)
            default:
                break
            }
        }
    }

    /// Result of decoding one inbound WebSocket frame, produced off the main
    /// actor so state application stays cheap.
    private enum ParsedMessage: Sendable {
        case response(id: Int, response: JSONRPCResponse)
        case responseDecodeFailed(id: Int, rawPrefix: String)
        case event(type: String, sessionID: String?, event: GatewayEvent)
        case eventPayloadFailed(type: String, detail: String)
        case parseFailed
        case ignored
    }

    /// Pure bytes → decoded message. Runs in a detached task so streaming
    /// floods (large payloads, dozens of events/sec) never block the UI.
    /// Must stay free of any GatewayClient state access.
    nonisolated private static func parseMessage(_ data: Data) -> ParsedMessage {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .parseFailed
        }

        // Response (has numeric "id" > 0)
        if let id = json["id"] as? Int, id > 0 {
            if let response = try? JSONDecoder().decode(JSONRPCResponse.self, from: data) {
                return .response(id: id, response: response)
            }
            let raw = String(data: data, encoding: .utf8)?.prefix(300) ?? "nil"
            return .responseDecodeFailed(id: id, rawPrefix: String(raw))
        }

        // Event (method == "event")
        if json["method"] as? String == "event",
           let params = json["params"] as? [String: Any],
           let type = params["type"] as? String {
            let payloadData: Data
            do {
                payloadData = try JSONSerialization.data(withJSONObject: params["payload"] ?? [:])
            } catch {
                return .eventPayloadFailed(type: type, detail: "Serialize failed: \(error.localizedDescription)")
            }
            let payload: AnyCodable?
            do {
                payload = try JSONDecoder().decode(AnyCodable.self, from: payloadData)
            } catch {
                return .eventPayloadFailed(type: type, detail: "Decode failed: \(error.localizedDescription)")
            }
            let event = GatewayEvent.from(type: type, payload: payload)
            return .event(type: type, sessionID: params["session_id"] as? String, event: event)
        }

        return .ignored
    }

    /// Apply an already-decoded message to client state. MainActor-only:
    /// pendingRequests fulfillment, @Published vars, and debug snapshot.
    private func applyParsedMessage(_ parsed: ParsedMessage) {
        switch parsed {
        case .parseFailed:
            log.debug("handleMessage: failed to parse JSON")
            onLog?("⚠ Failed to parse WS message", true)

        case .response(let id, let response):
            log.debug("handleMessage: response id=\(id)")
            onLog?("← response id=\(id)", false)
            fulfillRequest(id: id, response: response)

        case .responseDecodeFailed(let id, let raw):
            log.debug("handleMessage: failed to decode response for id=\(id), raw: \(raw)")
            onLog?("⚠ Decode failed for id=\(id): \(raw)", true)

        case .eventPayloadFailed(let type, let detail):
            log.error("event payload parse failed for \(type): \(detail)")
            onLog?("⚠ \(detail) for \(type)", true)

        case .event(let type, let sessionID, let event):
            log.debug("handleMessage: event type=\(type)")
            if type != "message.delta" && type != "reasoning.delta" && type != "thinking.delta" {
                onLog?("← event: \(type)", false)
            }
            recordDebugEvent(.inbound, name: type, sessionID: sessionID)

            if case .sessionInfo(let info) = event {
                sessionInfo = info
            }

            // Unrecognized gateway events are logged, not forwarded — no
            // consumer can act on them, and forwarding risks a future
            // consumer misrendering them (they used to surface as .error).
            if case .unknown(let unknownType) = event {
                log.info("ignoring unknown gateway event type: \(unknownType)")
                return
            }

            eventStream.send((event, sessionID))

        case .ignored:
            break
        }
    }

    private func fulfillRequest(id: Int, response: JSONRPCResponse) {
        pendingRequestsLock.lock()
        let continuation = pendingRequests.removeValue(forKey: id)
        let method = pendingRequestMethods.removeValue(forKey: id) ?? "response"
        let remaining = pendingRequests.count
        let found = continuation != nil
        log.debug("fulfillRequest: id=\(id), found=\(found), remaining=\(remaining)")
        pendingRequestsLock.unlock()
        recordDebugEvent(.inbound, name: method, detail: "response id=\(id)")

        continuation?.resume(returning: response)
    }

    /// Thread-safe removal of a pending request continuation.
    private func removePendingRequest(id: Int) -> CheckedContinuation<JSONRPCResponse, Error>? {
        pendingRequestsLock.lock()
        let continuation = pendingRequests.removeValue(forKey: id)
        pendingRequestMethods.removeValue(forKey: id)
        pendingRequestsLock.unlock()
        refreshDebugSnapshot()
        return continuation
    }

    // MARK: - URLSessionWebSocketDelegate

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        Task { @MainActor in
            // Ignore callbacks from a session we've already replaced/torn down —
            // teardownTransport() invalidates old sessions off-main, so a stale
            // one can report failure after the new socket is live.
            guard session === self.urlSession else { return }
            if let error = error as NSError? {
                let code = error.code
                let domain = error.domain
                let description = error.localizedDescription
                recordDebugEvent(.error, name: "websocket.failed", detail: "[\(domain) \(code)] \(description)")
                onLog?("✗ WebSocket handshake failed: [\(domain) \(code)] \(description)", true)

                // If it's a bad server response (-1011), try to read the HTTP status
                if code == NSURLErrorBadServerResponse,
                   let response = task.response as? HTTPURLResponse {
                    let status = response.statusCode
                    let headers = response.allHeaderFields
                    recordDebugEvent(.error, name: "websocket.http", detail: "status=\(status) headers=\(headers)")
                    onLog?("  HTTP status on upgrade: \(status)", true)
                }

                // Don't spin-reconnect on permanent errors
                if code == NSURLErrorBadServerResponse || code == NSURLErrorNotConnectedToInternet {
                    connectionState = .error("Server rejected connection (\(code): \(description))")
                    return
                }

                // Every other failure — notably -1004 (cannot connect) and
                // -1001 (timed out), the two an unreachable or non-listening
                // harness produces — is transient, so hand it to the reconnect
                // state machine.
                //
                // This handler used to just log and return. The client was left
                // in `.error` with reconnectAttempt=0 and NOTHING scheduled a
                // retry: `connect()` only auto-reconnects after a socket has
                // opened, and this was the socket failing to open. Measured
                // against an unreachable host, the client sat at
                // `.error("Could not connect to the server.")` forever. The UI
                // read that as "Connecting…" because the wrapper's connectTask
                // was still awaiting, holding `isConnecting` true — the actual
                // "hangs on Connecting" bug, upstream of the backoff loop and
                // the wait-timeout race both.
                handleDisconnect(reason: description)
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { @MainActor in
            guard session === self.urlSession else { return }
            onLog?("✓ WebSocket connected", false)
            connectionState = .connected
            reconnectAttempt = 0
            // The one place a budget grant is earned: the socket really opened,
            // so a later drop deserves a full set of retries.
            hasConnectedSinceBudgetGrant = true
            recordDebugEvent(.state, name: "websocket.open", detail: "connected")

            // Start keepalive pings
            startPingTimer()

            await onReconnected?()
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith code: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task { @MainActor in
            // A close from a session we've already swapped out must not tear
            // down or reconnect the live one (concurrent-session churn races).
            guard session === self.urlSession else { return }
            stopPingTimer()
            let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            debugSnapshot.lastCloseAt = Date()
            recordDebugEvent(.state, name: "websocket.close", detail: "code=\(code.rawValue) \(reasonStr)")
            if case .connecting = connectionState {
                onLog?("✗ WebSocket closed during handshake: \(code) \(reasonStr)", true)
                connectionState = .error("Connection closed during handshake (code \(code.rawValue))")
            } else if isIntentionalDisconnect {
                connectionState = .disconnected
            } else {
                handleDisconnect(reason: "WebSocket closed (\(code.rawValue)) \(reasonStr)")
            }
        }
    }
}

// MARK: - Errors

enum GatewayError: LocalizedError {
    case notConnected
    case disconnected
    case invalidResponse(String)
    case rpcError(JSONRPCError)
    case timedOut(method: String, seconds: Double)

    var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to gateway"
        case .disconnected: "Connection lost"
        case .invalidResponse(let msg): "Invalid response: \(msg)"
        case .rpcError(let err): "RPC error [\(err.code)]: \(err.message)"
        case .timedOut(let method, let seconds):
            "\(method) timed out after \(Int(seconds))s"
        }
    }
}
