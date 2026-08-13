// swiftlint:disable file_length type_body_length
// Legacy giant — split tracked as debt; do not add to this file.
import Foundation
import Combine
import os

private let log = Logger(subsystem: "com.ethenotethan.Portal", category: "ChatViewModel")

private let MIMETypeMap: [String: String] = [
    "pdf": "application/pdf",
    "doc": "application/msword",
    "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "xls": "application/vnd.ms-excel",
    "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "ppt": "application/vnd.ms-powerpoint",
    "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    "zip": "application/zip",
    "gz": "application/gzip",
    "tar": "application/x-tar",
    "json": "application/json",
    "xml": "application/xml",
    "csv": "text/csv",
    "html": "text/html",
    "rtf": "application/rtf",
    "mp3": "audio/mpeg",
    "mp4": "video/mp4",
    "wav": "audio/wav",
    "png": "image/png",
    "jpg": "image/jpeg",
    "jpeg": "image/jpeg",
    "gif": "image/gif",
    "webp": "image/webp",
    "svg": "image/svg+xml",
]

/// Core chat ViewModel — manages conversation state and interacts with the gateway.
@MainActor
final class ChatViewModel: ObservableObject {

    // MARK: - App Formatting Prompt
    // Injected as ephemeral system prompt so the model uses mermaid diagrams
    // and rich markdown — matching the app's native rendering capabilities.

    static let appFormattingPrompt = """
    ## Response Formatting (Portal App)

    You are running inside a native app that renders rich markdown and Mermaid diagrams. Use these capabilities:

    - **Mermaid diagrams** for any visual explanation. Wrap in ```mermaid blocks. One concept per diagram. Use the best type for the job:
      - `flowchart` / `graph` — processes, decision trees, architecture, data flows
      - `sequenceDiagram` — API calls, message passing, protocol exchanges, interactions between actors
      - `classDiagram` — OOP design, type hierarchies, entity relationships with attributes/methods
      - `stateDiagram-v2` — state machines, lifecycle transitions, status flows
      - `erDiagram` — database schemas, entity-relationship models, data modeling
      - `gantt` — project timelines, milestones, scheduling
      - `mindmap` — brainstorming, topic trees, concept hierarchies, org charts
      - `timeline` — chronological events, project history, release schedules
      - `pie` — proportional breakdowns, market share, distribution
      - `gitGraph` — branching strategies, release workflows, version history
      - `journey` — user journeys, experience maps, onboarding flows
      - `sankey` — resource flows, budget allocation, energy transfer
      - `quadrantChart` — priority matrices, risk/impact analysis, effort/value
      - `radar` — skill profiles, comparison across dimensions, performance metrics
      - `xychart` — trends, comparisons with axes, metrics over time
      - `treemap` — hierarchical proportions, storage breakdown, budget categories
      - `block` — block diagrams, high-level system composition
    - **Native data charts** for anything with numbers: wrap a JSON spec in a ```chart block.
      The app renders these as interactive native charts (hover readouts, legend toggling, zoom).
      NEVER generate chart images with matplotlib or other plotting tools, and never draw charts
      as ASCII or mermaid xychart when a ```chart block fits. Spec:
      ```chart
      {"type": "bar", "title": "…", "xLabel": "…", "yLabel": "…", "stacked": false,
       "series": [{"name": "Series A", "points": [{"x": "Jan", "y": 12.5}, {"x": "Feb", "y": 3}]}]}
      ```
      - `bar`, `line`, `area`, `scatter` — points of `{"x": number|string, "y": number}`; multiple series allowed; `"stacked": true` for stacked bars/areas
      - `pie` — one series; each point's `x` is the slice label, `y` its value
      - `heatmap` — points of `{"x": column, "y": row, "v": value}` (both axes categorical, `v` is the magnitude); one series
      - `histogram` — series carry RAW samples in `"values": [12.1, 13.4, …]` (no points); the app bins client-side; optional top-level `"bins": 15`
      - `boxplot` — same `"values"` shape, one series per group; the app computes quartiles — never pre-compute min/median/quartiles yourself
      - `waterfall` — financial bridges / where-did-it-go: one series of signed deltas in point order ({"x": "Refunds", "y": -12000});
        mark running-total checkpoints with {"x": "Gross", "total": true} (no y needed). The app computes the running levels
    - **Markdown headings** (##, ###) to structure longer responses
    - **Bold** for key terms, *italic* for emphasis
    - **Code blocks** with language tags (```python, ```swift, ```bash, ```sql, ```go, etc.)
    - **Ordered/unordered lists** for steps and enumerations
    - **Blockquotes** for important callouts
    - **Tables** for structured comparisons and data
    - **Diffs** in ```diff blocks (unified format, -/+ prefixes) whenever you show code changes — never a plain code block of before/after
    - **File trees** in ```tree blocks (box-drawing or indented, directories ending in /) for project structures
    - **Math** in $$…$$ blocks (LaTeX) — rendered as typeset equations, so prefer real TeX over unicode approximations
    - **Stat tiles** in ```stats blocks for key-metric summaries (renders as a native KPI row — prefer this over a table or list when the answer is a handful of headline numbers):
      ```stats
      {"tiles": [{"label": "Requests", "value": 128400, "unit": "/day", "delta": 12.5, "deltaLabel": "vs last week", "upIsGood": true, "trend": [98, 102, 110, 108, 121, 128]}]}
      ```
    - **Maps** in ```map blocks for spatial data — locations, listings, geographic comparisons (native MapKit, pins colored by group, tap for the note):
      ```map
      {"title": "BKK Apartments", "markers": [{"lat": 13.7248, "lon": 100.5847, "label": "Ekkamai loft", "group": "shortlist", "note": "38k/mo, 2BR"}]}
      ```
    - **Datasets** in ```dataset blocks for row-keyed records — contributor tables, client lists, spend
      entries (renders as a sortable table; rows merge by the declared key so partial updates are safe):
      ```dataset
      {"id": "clients", "key": "name", "columns": ["name", "tier", "arr"],
       "rows": [{"name": "Acme", "tier": "enterprise", "arr": 120000}]}
      ```
    - **Timelines / Gantt** in ```timeline blocks for scheduled or dated work — project plans, incident
      chronologies, release schedules (native swimlane chart with duration bars, diamond milestones, a
      today line, and date scrubbing — prefer over mermaid gantt/timeline):
      ```timeline
      {"title": "Q3 Launch", "items": [
        {"label": "Design", "start": "2026-07-01", "end": "2026-07-14", "lane": "Product", "group": "done"},
        {"label": "Build", "start": "2026-07-10", "end": "2026-08-15", "lane": "Eng"},
        {"label": "GA", "at": "2026-08-20", "lane": "Launch", "note": "public release"}]}
      ```
      Items with start+end are bars; items with "at" are milestones. "lane" groups rows, "group" colors them.
    - **Living artifacts**: add an "id" field to any map/chart/graph/stats/dataset/timeline block to make it a
      PERSISTENT model the user keeps across sessions. When the user adds or changes items, re-emit the
      block with the SAME id — maps merge markers by label and datasets merge rows by key (emit only
      new/changed entries or the full set; both work), other kinds replace wholesale so emit the
      complete block. Example: a ```map block with "id": "bkk-apartments" updated as the user
      evaluates listings.
      Dataset and map artifacts may also declare per-entry USER ACTIONS — controls the user taps to
      triage entries, writing back into the artifact where you'll see them on your next read:
      "actions": [{"field": "status", "type": "choice", "options": ["going", "not going"]},
      {"field": "reached_out", "type": "toggle"}, {"type": "delete"}]
      Declare actions matching what the artifact represents (apartments → reached_out/delete;
      conferences → going/not going). Entries with "_deleted": true are user-removed tombstones:
      NEVER re-emit or resurrect them, and never set _deleted yourself unless the user asks.
    - **Ensemble models** in ```model blocks when ONE subject has entity sets, relationships, and deserves
      multiple simultaneous views (apartment hunt = apartments + gyms on a map + status table + walkability
      graph; a company = clients + spend as table + chart). Views stack on one surface with linked selection:
      ```model
      {"id": "bkk-life", "title": "Bangkok Base",
       "entities": {"apartments": {"key": "name", "items": [{"name": "Seed Mingle", "lat": 13.716, "lon": 100.54, "rent": 22000}]},
                    "gyms": {"key": "name", "items": [{"name": "FelixMuayThai", "lat": 13.729, "lon": 100.539}]}},
       "relations": [{"from": "apartments/Seed Mingle", "to": "gyms/FelixMuayThai", "type": "walkable", "note": "8 min"}],
       "views": [{"type": "markdown", "text": "## Hunt status\\nDown to **3 candidates**."},
                 {"type": "map"}, {"type": "table", "entities": ["apartments"], "columns": ["name", "rent", "status"]},
                 {"type": "graph"}, {"type": "chart", "chart": "bar", "entities": ["apartments"], "x": "name", "y": "rent"}],
       "actions": {"apartments": [{"field": "status", "type": "choice", "options": ["interested", "viewed", "ruled out"]}, {"type": "delete"}]}}
      ```
      Entity refs are "set/keyValue". Views render in declaration order — markdown views carry the
      artifact-level narrative (summary, criteria, decision log) and can be interleaved anywhere in the
      stack; update the prose alongside the data. Entity sets merge by key and relations by (from,to,type),
      so emit only new/changed items when updating (views replace wholesale — re-emit the full views array).
      Prefer upgrading a map/dataset to a model over emitting parallel artifacts when the user wants
      relationships or multiple lenses on the same data.
    - **Sankey diagrams** in ```sankey blocks for branching flows — budget allocation, token/traffic routing,
      funnels (nodes are implicit from link endpoints; ribbon thickness ∝ value):
      ```sankey
      {"title": "Q2 Budget", "links": [{"from": "Revenue", "to": "Engineering", "value": 400},
        {"from": "Revenue", "to": "Marketing", "value": 150}, {"from": "Engineering", "to": "Salaries", "value": 320}]}
      ```
    - **Network graphs** in ```graph blocks for node-link structures — dependency graphs, service topologies,
      entity networks (interactive force-directed diagram; prefer over mermaid flowchart when the story is
      the CONNECTIVITY, not a sequence):
      ```graph
      {"title": "Services", "directed": true,
       "nodes": [{"id": "api", "label": "API", "group": "backend", "size": 2}, {"id": "db", "label": "Postgres", "group": "data"}],
       "edges": [{"from": "api", "to": "db", "label": "reads"}]}
      ```
    - **Interactive HTML worlds** (games, 3D scenes, simulations emitted as html artifacts): the app
      hosts these in a WKWebView that CAPTURES the mouse via the Pointer Lock API — the host requests
      the lock on the user's first click anywhere over the scene, and Esc releases it. Author input
      code against that contract or navigation feels broken:
      - Look/turn must read `event.movementX` / `event.movementY` from `mousemove` whenever
        `document.pointerLockElement` is set. NEVER implement click-and-drag camera controls as the
        primary scheme — the cursor is hidden and locked while navigating, so drag gestures cannot
        happen. (A drag fallback for the unlocked state is fine.)
      - Movement: WASD plus arrow keys, handled via `keydown`/`keyup` on `document` (not the canvas —
        focus is not guaranteed). Track held keys in a Set; never rely on key repeat.
      - Do not bind Escape — the host owns it (first press releases the mouse, second exits).
      - Do not call `requestPointerLock()` from a `click` handler yourself; the host already does it
        from the first trusted click. Calling it again is harmless but redundant.
      - HUD overlays (crosshair, stats, help text) must be `pointer-events: none` unless they are real
        buttons, so clicks pass through to the scene.
    - **Backend intents in HTML artifacts** — an html artifact (a dashboard, a world, any page) can carry
      buttons that DISPATCH REAL BACKEND ACTIONS, including kicking off contained agent sessions. Two parts:
      1. Declare the intents in the artifact's action manifest (same "actions" array as datasets):
         {"type": "intent", "id": "archive-issue", "label": "Archive", "intent": "linear.issue.archive",
          "presentation": {"role": "destructive"}}. Only declared bindings can ever fire; the gateway
         re-validates every click against the stored revision.
      2. Mark up the page with INERT attributes — no JS, no fetch, no scheme URLs (the host injects the
         only bridge that exists and ignores everything else):
         <button data-hermes-binding="archive-issue" data-hermes-entity="issues/ARC-42">Archive</button>
         `data-hermes-binding` names the declared intent id; `data-hermes-entity` (optional, ≤512 bytes)
         says which entity the click is about. The host reflects progress back onto the SAME element as
         `data-hermes-status` = "pending" | "needs-confirmation" | "succeeded" | "failed" | "conflict" |
         "unsupported" — style those states with CSS attribute selectors (e.g.
         [data-hermes-status="pending"] { opacity: .5 }) so the control shows its own progress.
      In a 3D world, stage the binding from your raycast instead of wiring click handlers: while
      `document.pointerLockElement` is set and the crosshair hits an actionable object, setAttribute the
      binding and entity ONTO THE CANVAS (removeAttribute when it leaves, and whenever the lock is not
      held — the first unlocked click must capture the mouse, not fire an action). The user's trusted
      click then dispatches whatever they were aiming at — never call dispatchEvent or element.click(),
      synthetic clicks are deliberately ignored. Confirmation for destructive intents is native chrome;
      don't build your own.
    - **Courses** when the user asks to be TAUGHT a subject rather than told about it — "teach me X",
      "build me a curriculum/course on X", "I want to learn X properly". Emit a curriculum envelope and
      the app files it in Learning as a course with per-step progress, instead of a wall of chat prose
      the user has to scroll back through. 3-5 modules, each 2-4 lesson steps then one quiz step over
      that module's material; lesson `content` is markdown (explain, give a concrete example, a few
      hundred words); quiz options are labeled "A) …"–"D) …" and `correct` is the letter alone:
      ```json
      {"curriculum": {"title": "…", "summary": "one paragraph", "modules": [
        {"title": "…", "overview": "one sentence", "steps": [
          {"type": "lesson", "title": "…", "content": "markdown body"},
          {"type": "quiz", "title": "…", "questions": [
            {"q": "…", "options": ["A) …", "B) …", "C) …", "D) …"], "correct": "A", "explanation": "…"}]}]}]}}
      ```
      Emit the envelope ALONE with no prose around it — the app renders the course, so a chat summary
      is redundant. For a single quick knowledge check rather than a course, use a bare
      {"questions": [...]} array in the same question shape.
    """
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isStreaming: Bool = false
    @Published var isSessionReady: Bool = false
    @Published var currentModel: String = ""
    /// Live model inventory from the gateway's model.options RPC. nil until
    /// the first successful fetch (or forever, on gateways without the RPC) —
    /// the picker then falls back to the static AgentModel.catalog.
    @Published private(set) var modelCatalog: ModelCatalog?
    /// Expensive-model confirmation gate from config.set: the switch did not
    /// apply; the picker shows this and resends with confirm on approval.
    @Published var pendingModelConfirmation: ModelSwitchConfirmation?
    /// Every approval this session is blocked on, oldest first. Multiple agent
    /// threads (parallel subagents, concurrent execute_code) can block at once,
    /// and the gateway queues them — see `ApprovalQueue`.
    @Published internal private(set) var approvalQueue = ApprovalQueue()
    /// The approval currently being asked about: the head of `approvalQueue`,
    /// which is also the one the gateway will resolve next (it pops oldest-first
    /// and `approval.respond` carries no request id). Kept as a published
    /// property so existing views and `if pendingApproval != nil` layout checks
    /// keep working unchanged.
    @Published internal private(set) var pendingApproval: ApprovalPayload?
    /// Active backend's feature flags — views hide affordances the backend
    /// can't serve (attachments/skills pickers on Centaur sessions).
    @Published private(set) var backendCapabilities: BackendCapabilities = .hermes
    /// Blocking clarify question awaiting an answer (clarify.request).
    @Published var pendingClarify: ClarifyPayload?
    @Published var activeToolCalls: [String: ToolCallRecord] = [:] // tool_id → record
    @Published var error: String?
    @Published var avatarState: AvatarState = .idle
    /// Short-lived status line (status.update / moa.aggregating) shown under
    /// the streaming panel; auto-clears so stale text never lingers.
    @Published private(set) var transientStatus: String?
    private var transientStatusClearTask: Task<Void, Never>?

    /// Context-compaction folds observed during the CURRENTLY-DISPLAYED turn —
    /// the live strip and the session graph draw these as full-height rules.
    /// Reset each turn (like the graph integrators) and snapshotted onto the
    /// turn's `graphSnapshot` at message-complete for past-turn replay.
    @Published internal private(set) var currentTurnCompactions: [CompactionMarker] = []

    /// Last-seen cumulative `usage.compressions` per DISPLAY session id. The
    /// delta between turns is how an AUTOMATIC compaction is detected (it has
    /// no live event). Per-session and seeded-without-emitting on first sight so
    /// switching sessions never fabricates a fold from another session's count.
    private var compactionCounterBaseline: [String: Int] = [:]
    /// Count of MANUAL compaction folds already recorded live this turn, so the
    /// counter-delta pass at message-complete doesn't double-count them.
    private var manualCompactionsThisTurn = 0
    @Published var sessionTitle: String = "New Chat"
    /// The visible session's current turn was started on another device.
    @Published private(set) var isRemoteTurn: Bool = false
    @Published private(set) var createGeneration: Int = 0
    /// Voice recording state — true while the gateway is capturing audio via VAD.
    @Published internal private(set) var isVoiceRecording: Bool = false
    /// Pending media attachments for the next user message.
    @Published var pendingAttachments: [MediaAttachment] = []
    /// Skills attached to this session (their instructions are prepended to prompts).
    @Published var activeSkills: [SkillInfo] = []
    /// Skills the agent has pulled in *itself* during the in-flight turn, via the
    /// gateway's `skill_view` tool.
    ///
    /// Separate from `activeSkills` because the app doesn't choose these and
    /// can't know them in advance — they're observed as they happen, by watching
    /// tool calls. Surfacing them is the difference between "the model quietly
    /// read a skill" and the user being able to see that it did.
    @Published internal private(set) var loadedSkills: [TurnSkillRecord] = []

    /// Everything shaping the current turn, attached and agent-loaded, in the
    /// order it arrived. This is what the live skills lens renders.
    internal var currentTurnSkills: [TurnSkillRecord] {
        var records = activeSkills.map(TurnSkillRecord.attached)
        for loaded in loadedSkills {
            records.appendSkillRecord(loaded)
        }
        return records
    }
    /// How the agent shapes answers for this session (deep map / balanced / direct).
    /// Composed into the ephemeral system prompt; per-session, sticky as the
    /// default for new sessions.
    @Published var responseStyle: ResponseStyle = .storedDefault
    /// Slash-command autocomplete suggestions.
    @Published var slashSuggestions: [SkillInfo] = []
    @Published var slashMode: Bool = false
    /// Currently selected suggestion index for keyboard navigation.
    @Published var slashSelectedIndex: Int = 0
    @Published var refocusInput: Int = 0
    private var pendingResumeKey: String?

    // MARK: - Quiz Mode
    /// When non-nil, quiz questions are available and the QuizSheet should be shown.
    @Published var quizQuestions: [QuizQuestion]?
    /// The topic the quiz was generated for (displayed in the sheet header).
    @Published var quizTopic: String = ""
    /// True while waiting for the agent to return quiz JSON.
    private var awaitingQuizResponse = false
    /// The quiz-related prompt that was sent (for tracking).
    private var lastQuizPrompt: String = ""
    /// Error message when quiz JSON parsing fails (displayed in the quiz sheet).
    @Published var errorMessageForQuiz: String?

    // MARK: - Flashcard Mode
    /// When non-nil, a flashcard deck is available and the QuizSheet should show it.
    @Published var flashcardDeckReady: FlashcardDeck?

    // MARK: - Curriculum Mode
    /// Set when the agent returns a parseable course. The view opens Learning
    /// rather than a sheet — a curriculum is a multi-session artifact, so it is
    /// persisted first and studied from the Learning page.
    @Published internal var curriculumReady: Curriculum?

    /// Where a generated course is written before the Learning page opens it.
    /// Owned rather than shared: the store is stateless beyond its directory, so
    /// each owner holding its own instance reads and writes the same courses.
    private let curriculumStore = CurriculumStore()

    /// Monotonic token for user-driven session switches/creates. Async resume
    /// calls must check this before committing returned history; otherwise a
    /// slower first resume can overwrite the newer selected session after rapid
    /// sidebar clicks while another turn is streaming.
    private var sessionSwitchGeneration = 0

    private struct SessionRuntimeState {
        var messages: [ChatMessage] = []
        var isStreaming: Bool = false
        var isSessionReady: Bool = false
        var approvalQueue = ApprovalQueue()
        var pendingClarify: ClarifyPayload?
        var activeToolCalls: [String: ToolCallRecord] = [:]
        var error: String?
        var avatarState: AvatarState = .idle
        var sessionTitle: String = "New Chat"
        var streamingMessageID: UUID?
        /// Turn was started by another device/client on the same session.
        var isRemoteTurn: Bool = false
        var responseStyle: ResponseStyle = .storedDefault
        /// Model this session reported via session.info (or the user picked).
        /// Per-session so switching sessions shows each one's actual model.
        var currentModel: String = ""
        /// Skills the user attached to this session. Per-session because
        /// attachment is a property of the conversation: without this, switching
        /// away and back silently dropped every attached skill, so the next turn
        /// went out with no SKILL.md prepended while the UI had already stopped
        /// showing them.
        var activeSkills: [SkillInfo] = []
        /// Skills the agent read via `skill_view` during the in-flight turn,
        /// accumulated until the turn completes and they are stamped onto the
        /// assistant message. Cleared at the start of each turn.
        var pendingLoadedSkills: [TurnSkillRecord] = []
    }


    private var gatewayClient: (any AgentBackend)?
    /// True when the chat pipeline is already driven by `client`. Lets routing
    /// code (ContentView) avoid a redundant reset+re-subscribe when re-applying
    /// the same backend — `setGatewayClient` is identity-guarded, but the reset
    /// that precedes it is not, so callers check identity first.
    internal func isDriven(by client: any AgentBackend) -> Bool { gatewayClient === client }
    private var sessionID: String?
    private var stableSessionByGatewayID: [String: String] = [:]
    private var gatewayIDByStableSession: [String: String] = [:]

    /// Manager for downloading remote file attachments from the gateway.
    var fileDownloadManager = FileDownloadManager()
    /// Live reasoning summarization — extracts decision structure from agent
    /// thought traces during streaming; results feed the ThoughtGraphView.
    /// Uses the heuristic pattern-matcher by default (instant, zero deps).
    /// On macOS, the user can opt in to the experimental MLX model (Gemma 3 1B)
    /// via Settings → Thought Graph → Experimental. The MLX path itself degrades
    /// to the heuristic when the model isn't loaded yet.
    internal lazy var reasoningGraph: ReasoningGraphIntegrator = {
        #if canImport(MLXLLM) && os(macOS)
        if UserDefaults.standard.bool(forKey: "portal.mlxReasoningEnabled") {
            return ReasoningGraphIntegrator(summarizer: MLXReasoningSummarizer())
        }
        #endif
        return ReasoningGraphIntegrator(summarizer: HeuristicReasoningSummarizer())
    }()
    /// Live subagent dispatch tracking — folds subagent.* events into agent
    /// subtrees rendered inside the ThoughtGraphView. Turn-scoped like
    /// reasoningGraph.
    let subagentGraph = SubagentGraphIntegrator()

    /// Snapshot the live thought-graph depth (subagent + reasoning nodes) for
    /// the turn that's completing. Called at message-complete, BEFORE the
    /// integrators reset on the next message-start, so the per-session graph
    /// can replay this turn with full depth. Returns nil when there's nothing
    /// beyond tool calls (which persist separately on the message) to keep
    /// tool-only turns from bloating the session JSON.
    private func captureGraphSnapshot() -> TurnGraphSnapshot? {
        let snapshot = TurnGraphSnapshot(
            agentNodes: subagentGraph.agentNodes,
            reasoningNodes: reasoningGraph.reasoningNodes,
            compactions: currentTurnCompactions
        )
        return snapshot.isEmpty ? nil : snapshot
    }

    private var sessionStates: [String: SessionRuntimeState] = [:]
    private var streamingMessageID: UUID?
    private var streamStartDate: Date?
    private var cancellables = Set<AnyCancellable>()
    private(set) var isCreatingSession = false
    /// Display IDs with an interrupt in flight. Per-session: a Stop on session
    /// A must not gate submits on B, and must not make B's incoming
    /// `message.start` look like a local stop-drain rather than a remote turn.
    private var stoppingSessions: Set<String> = []
    private var isStopping: Bool {
        guard let sessionID else { return false }
        return stoppingSessions.contains(displaySessionID(for: sessionID))
    }
    /// True when the active session hasn't been properly resumed on the gateway
    /// (e.g. after WebSocket reconnection). Prompt submission will auto-resume first.
    private var needsGatewayResume = false
    private var pendingVisibleEventFlush: Task<Void, Never>?
    private var pendingVisibleMessageDelta = ""
    private var pendingVisibleReasoningDelta = ""
    private var pendingVisibleThinkingDelta = ""
    /// Display ID the buffered deltas above belong to. The buffers feed the
    /// PUBLISHED arrays, which only ever show one session — so a buffer filled
    /// while session A was visible must never be applied after a switch to B.
    /// Set on the first append of a batch, cleared on flush/cancel.
    private var pendingVisibleDeltaOwner: String?
    private var perfEventCounts: [String: Int] = [:]
    private var perfLastLog = Date()
    private var perfFlushCount = 0
    private var perfVisibleFlushLogCount = 0
    private var perfWriteCount = 0
    private let perfLoggingEnabled = ProcessInfo.processInfo.arguments.contains("--long-session-perf")

    private var perfLogURL: URL? {
        guard perfLoggingEnabled else { return nil }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("portal", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("long-session-perf.log")
    }

    private func writePerfLog(_ line: String) {
        guard perfLoggingEnabled else { return }
        perfWriteCount += 1
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let fullLine = "\(timestamp) #\(perfWriteCount) \(line)\n"
        log.info("\(fullLine)")
        guard let url = perfLogURL, let data = fullLine.data(using: .utf8) else { return }
        Task.detached(priority: .background) {
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func writePerfSnapshot(_ label: String) {
        guard perfLoggingEnabled else { return }
        let last = messages.last
        let counts = perfEventCounts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        let fields = [
            "snapshot=\(label)",
            "session=\(sessionID ?? "nil")",
            "messages=\(messages.count)",
            "streaming=\(isStreaming)",
            "content=\(last?.content.count ?? 0)",
            "reasoning=\(last?.reasoning?.count ?? 0)",
            "activeTools=\(activeToolCalls.count)",
            "flushes=\(perfFlushCount)",
            "pendingMessageBytes=\(pendingVisibleMessageDelta.count)",
            "pendingReasoningBytes=\(pendingVisibleReasoningDelta.count)",
            "pendingThinkingBytes=\(pendingVisibleThinkingDelta.count)",
            counts,
        ]
        writePerfLog("[PortalPerf] \(fields.joined(separator: " "))")
    }

    // MARK: - Setup

    init() {
        LeakTracker.track(self)
    }

    func setGatewayClient(_ client: any AgentBackend) {
        // ContentView can wire the same app-level client repeatedly during
        // connect/session-create flows. Avoid stacking duplicate Combine
        // subscriptions, because every gateway event would otherwise be applied
        // N times and parallel sessions quickly corrupt local chat state.
        guard gatewayClient !== client else { return }

        cancellables.removeAll()
        pendingVisibleEventFlush?.cancel()
        pendingVisibleEventFlush = nil
        gatewayClient = client
        backendCapabilities = client.capabilities

        // Subscribe to gateway events. Events are multiplexed over one app-level
        // WebSocket, so only apply events whose session_id matches this chat's
        // current session. Legacy/global events may have no session_id.
        // Use collect(.byTimeOrCount) to batch rapid events (e.g. reasoning.delta
        // floods) into fewer main-thread dispatches, preventing layout recursion
        // and spinning-wheel freezes during heavy streaming.
client.eventStream
            .collect(.byTimeOrCount(RunLoop.main, .milliseconds(32), 30))
            .sink { [weak self] batch in
                DispatchQueue.main.async {
                    for (event, eventSessionID) in batch {
                        self?.handleEvent(event, eventSessionID: eventSessionID)
                    }
                }
            }
            .store(in: &cancellables)

        // Observe connection state
        client.connectionStatePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                switch state {
                case .connected:
                    self?.error = nil
                case .reconnecting:
                    self?.error = nil
                    self?.needsGatewayResume = true
                    // Do not mark the active turn as stopped during a transient
                    // reconnect. The gateway agent may still be running, and
                    // clearing isStreaming makes later frames look stale.
                    if self?.isStreaming == true {
                        self?.avatarState = .thinking
                    }
                case .error(let msg):
                    self?.error = msg
                    if self?.sessionID == nil {
                        self?.isSessionReady = false
                    }
                    if self?.isStreaming == true {
                        self?.avatarState = .error
                    }
                default:
                    break
                }
            }
            .store(in: &cancellables)

        // session.info is applied via the eventStream path (handleEvent /
        // applySessionEvent), which routes by the event's session_id. Do NOT
        // also subscribe to sessionInfoPublisher here: it carries no session
        // ID, so a session.info from ANY session (peekSession observers,
        // subagents, cron, another device) would clobber the active chat's
        // model badge with that session's model — e.g. snapping back to the
        // gateway default right after the user picked a different model.

        // Handle reconnection. Session creation is explicit from the Sessions UI;
        // reconnect should not implicitly create an invisible chat that races with
        // the New Session button and leaves the list empty on compact iOS.
        client.onReconnected = { [weak self] in
            guard let self else { return }
            if let resumedID = self.gatewayClient?.activeSessionID, self.sessionID != resumedID {
                self.sessionID = resumedID
                self.createGeneration += 1
                self.isSessionReady = true
                self.error = nil
} else if let sid = self.sessionID, self.isSessionReady,
                       self.gatewayClient?.activeSessionID == nil {
                // Gateway didn't auto-resume — explicitly re-resume so the
                // session is re-registered and streaming events will flow.
                let displayID = self.displaySessionID(for: sid)
                Task {
                    let _ = try? await self.gatewayClient?.resumeSession(key: displayID)
                    if let resumedID = self.gatewayClient?.activeSessionID,
                       self.sessionID != resumedID {
                        self.sessionID = resumedID
                    }
                    self.isSessionReady = true
                    self.error = nil
                    self.needsGatewayResume = false
                }
            }
        }
    }

    /// The session ID currently active in this chat view.
    var currentSessionID: String? { sessionID }

    /// Reset all in-memory conversation state when switching to a different
    /// gateway. The previous gateway's sessions/messages do not belong to the
    /// new one, so clear everything and force a fresh resume on the new client.
    /// Persisted history is keyed per session ID, so nothing is lost on disk.
    func resetForGatewaySwitch() {
        cancellables.removeAll()
        pendingVisibleEventFlush?.cancel()
        pendingVisibleEventFlush = nil
        gatewayClient = nil
        sessionSwitchGeneration += 1
        sessionStates.removeAll()
        stableSessionByGatewayID.removeAll()
        gatewayIDByStableSession.removeAll()
        sessionID = nil
        streamingMessageID = nil
        needsGatewayResume = false
        messages = []
        isStreaming = false
        isSessionReady = false
        currentModel = ""
        modelCatalog = nil
        pendingModelConfirmation = nil
        setApprovalQueue(ApprovalQueue())
        pendingClarify = nil
        activeToolCalls = [:]
        error = nil
        avatarState = .idle
        sessionTitle = "New Chat"
        isRemoteTurn = false
        pendingAttachments = []
        activeSkills = []
        loadedSkills = []
        responseStyle = .storedDefault
        slashSuggestions = []
        slashMode = false
    }

    /// Test/debug hook for applying a gateway event exactly as the shared
    /// WebSocket subscriber would receive it.
    func receiveGatewayEventForTesting(_ event: GatewayEvent, sessionID: String?) {
        handleEvent(event, eventSessionID: sessionID)
    }

    /// Desync local streaming state from the gateway's, the way a mid-turn
    /// reconnect + resume does. No production path sets this in isolation —
    /// that's the point: the wedge only reproduces once the two disagree.
    internal func forceStreamingStateForTesting(_ streaming: Bool, sessionID: String) {
        mutateSessionState(for: sessionID) { $0.isStreaming = streaming }
    }

    /// Drop a session's cached transcript while leaving its turn flags alone —
    /// the state eviction used to produce for a streaming session.
    internal func dropCachedMessagesForTesting(sessionID: String) {
        let displayID = displaySessionID(for: sessionID)
        sessionStates[displayID]?.messages = []
        if displaySessionID(for: self.sessionID ?? "") == displayID {
            messages = []
        }
    }

    internal func cachedMessageCountForTesting(sessionID: String) -> Int? {
        sessionStates[displaySessionID(for: sessionID)]?.messages.count
    }

    internal func activeToolCallsForTesting(sessionID: String) -> [String: ToolCallRecord]? {
        sessionStates[displaySessionID(for: sessionID)]?.activeToolCalls
    }

    internal var streamingSessionIDsForTesting: Set<String> {
        Set(sessionStates.filter { $0.value.isStreaming }.keys)
    }

    /// Link the active short-lived gateway ID with the stable database ID shown
    /// in the sessions list. History is saved under both IDs so switching away
    /// and back does not depend on which ID is current at that exact moment.
    func bindCurrentGatewaySession(toStableSessionID stableID: String) {
        guard let runtimeID = sessionID, !stableID.isEmpty else { return }
        bindRuntimeSession(displayID: stableID, runtimeID: runtimeID)
    }

    private func displaySessionID(for runtimeID: String) -> String {
        stableSessionByGatewayID[runtimeID] ?? runtimeID
    }

    private func runtimeSessionID(for displayID: String) -> String {
        gatewayIDByStableSession[displayID] ?? displayID
    }

    /// Bind the stable database ID shown by the session list to the runtime
    /// gateway ID carried by live events. A newly-created session starts out
    /// keyed only by its short runtime ID, then `session.title` later resolves
    /// to a database ID. Without moving that cached runtime state, clicking
    /// away from a live turn and back via the database ID restores an empty
    /// history and makes the running session look like it disappeared.
    func bindRuntimeSession(displayID: String, runtimeID: String) {
        guard !displayID.isEmpty, !runtimeID.isEmpty else { return }
        stableSessionByGatewayID[runtimeID] = displayID
        gatewayIDByStableSession[displayID] = runtimeID

        if displayID != runtimeID, let runtimeState = sessionStates.removeValue(forKey: runtimeID) {
            if var displayState = sessionStates[displayID] {
                // Preserve any locally visible state that is newer/richer than
                // disk history, but prefer the live runtime stream fields.
                displayState.messages = runtimeState.messages
                displayState.isStreaming = runtimeState.isStreaming
                displayState.streamingMessageID = runtimeState.streamingMessageID
                displayState.approvalQueue = runtimeState.approvalQueue
                displayState.pendingClarify = runtimeState.pendingClarify
                displayState.activeToolCalls = runtimeState.activeToolCalls
                displayState.avatarState = runtimeState.avatarState
                displayState.error = runtimeState.error
                sessionStates[displayID] = displayState
            } else {
                sessionStates[displayID] = runtimeState
            }
        }

        if sessionID == runtimeID {
            snapshotCurrentSessionState()
            if !messages.isEmpty {
                ChatHistoryStore.shared.saveMessages(messages, forSession: displayID)
            }
        }
    }

    private func snapshotCurrentSessionState() {
        guard let sessionID else { return }
        let displayID = displaySessionID(for: sessionID)
        sessionStates[displayID] = SessionRuntimeState(
            messages: messages,
            isStreaming: isStreaming,
            isSessionReady: isSessionReady,
            approvalQueue: approvalQueue,
            pendingClarify: pendingClarify,
            activeToolCalls: activeToolCalls,
            error: error,
            avatarState: avatarState,
            sessionTitle: sessionTitle,
            streamingMessageID: streamingMessageID,
            isRemoteTurn: isRemoteTurn,
            responseStyle: responseStyle,
            currentModel: currentModel,
            activeSkills: activeSkills,
            pendingLoadedSkills: loadedSkills
        )
        evictColdSessionMessages(keeping: displayID)
    }

    /// Cap in-memory session state: each cached session holds its full
    /// messages array, so heavy switching accumulates multi-MB state per
    /// session. macOS shrugs; iOS jetsam kills the app (perceived as random
    /// crashes). Keep full messages only for the most recent sessions and
    /// drop message arrays (not the whole state) for the rest — history is
    /// persisted per session and lazily reloaded on restore.
    private static let maxWarmSessionStates = 6

    private func evictColdSessionMessages(keeping activeDisplayID: String) {
        var warmIDs = sessionStates.filter { !$0.value.messages.isEmpty }.map(\.key)
        guard warmIDs.count > Self.maxWarmSessionStates else { return }
        warmIDs.removeAll { $0 == activeDisplayID }
        // Never evict a session with a turn in flight. Eviction is safe only
        // because the transcript is recoverable from disk — and a streaming
        // session's transcript is NOT: it holds the in-flight assistant shell,
        // which exists nowhere else until `message.complete` persists it, and
        // `restoreSessionState` deliberately skips the disk reload while
        // `isStreaming` is true (disk history would clobber the live turn).
        //
        // Dropping it wedged the session on "Thinking…" with an empty
        // transcript: `message.complete` could no longer find the shell to
        // stamp, so the turn never settled. That is why this needed a long
        // session (7+ warm states to trigger eviction at all) and a click away
        // and back (the snapshot that runs it) to reproduce.
        warmIDs.removeAll { sessionStates[$0]?.isStreaming == true }
        // Restore lazily reloads from ChatHistoryStore, so eviction only
        // costs a disk read on the next switch back to that session.
        let excess = warmIDs.count + 1 - Self.maxWarmSessionStates
        for id in warmIDs.prefix(max(0, excess)) {
            sessionStates[id]?.messages = []
        }
    }

    private func restoreSessionState(displayID: String, runtimeID: String? = nil) -> Bool {
        guard let state = sessionStates[displayID] else { return false }
        // Lazy-reload messages evicted on session switch — use background load
        sessionID = runtimeID ?? runtimeSessionID(for: displayID)
        messages = state.messages
        isStreaming = state.isStreaming
        isSessionReady = state.isSessionReady
        setApprovalQueue(state.approvalQueue)
        pendingClarify = state.pendingClarify
        activeToolCalls = state.activeToolCalls
        error = state.error
        avatarState = state.avatarState
        sessionTitle = state.sessionTitle
        streamingMessageID = state.streamingMessageID
        isRemoteTurn = state.isRemoteTurn
        responseStyle = state.responseStyle
        currentModel = state.currentModel
        activeSkills = state.activeSkills
        loadedSkills = state.pendingLoadedSkills
        if state.messages.isEmpty && !state.isStreaming,
           ChatHistoryStore.shared.hasLocalMessages(forSession: displayID) {
            let generation = sessionSwitchGeneration
            Task {
                if let cached = await ChatHistoryStore.shared.loadMessagesBackground(forSession: displayID) {
                    // Re-read state: a live event may have mutated it while the
                    // disk read was in flight, and `state` here is a stale copy.
                    var latest = self.sessionStates[displayID] ?? state
                    if latest.messages.isEmpty {
                        latest.messages = cached
                        self.sessionStates[displayID] = latest
                    }
                    // Compare DISPLAY ids: `sessionID` holds a runtime id, so the
                    // old `sessionID == (runtimeID ?? displayID)` test silently
                    // failed for bound sessions (never applying the load) and
                    // could pass for the wrong session after a switch.
                    guard generation == self.sessionSwitchGeneration,
                          let current = self.sessionID,
                          self.displaySessionID(for: current) == displayID else { return }
                    self.messages = latest.messages
                }
            }
        }
        return true
    }

    private func mutateSessionState(for eventSessionID: String, _ mutation: (inout SessionRuntimeState) -> Void) {
        let displayID = displaySessionID(for: eventSessionID)
        var state = sessionStates[displayID] ?? SessionRuntimeState()
        mutation(&state)
        sessionStates[displayID] = state
        if sessionID == eventSessionID || displaySessionID(for: sessionID ?? "") == displayID {
            _ = restoreSessionState(displayID: displayID, runtimeID: eventSessionID)
        }
    }

    /// Create a new session on the gateway.
    func createSession() async {
        guard let client = gatewayClient else {
            self.error = "No harness client"
            return
        }
        log.info("ChatViewModel createSession invoked state=\(String(describing: client.connectionState))")
        guard !isCreatingSession else {
            log.info("ChatViewModel createSession ignored: already creating")
            return
        }
        isCreatingSession = true
        do {
            let sid = try await client.createSession(cols: 120)
            log.info("ChatViewModel createSession succeeded sid=\(sid)")
            snapshotCurrentSessionState()
            self.sessionID = sid
            self.createGeneration += 1
            self.isSessionReady = true
            self.messages = []
            self.activeToolCalls = [:]
            self.setApprovalQueue(ApprovalQueue())
        self.pendingClarify = nil
            self.pendingClarify = nil
            self.streamingMessageID = nil
            self.isStreaming = false
            self.avatarState = .idle
            self.error = nil
            cancelPendingFlush()
            snapshotCurrentSessionState()

            await applyEphemeralPrompt(for: sid, using: client)
            await applySessionSkills(for: sid, using: client)
            await applyDefaultModel(for: sid, using: client)
        } catch {
            self.error = "Session create failed: \(error.localizedDescription)"
        }
        isCreatingSession = false
    }

    /// Starts a user-visible switch immediately from local cache and returns a
    /// generation token. Call `resumeSession(key:generation:)` to revalidate the
    /// same selection from the gateway; stale generations are ignored.
    @discardableResult
    func beginSwitchToSession(key: String) -> Int {
        flushPendingVisibleEventDeltas()
        snapshotCurrentSessionState()
        if let oldDisplayID = sessionID.map({ displaySessionID(for: $0) }),
           oldDisplayID != key,
           var oldState = sessionStates[oldDisplayID],
           !oldState.isStreaming {
            oldState.messages = []
            sessionStates[oldDisplayID] = oldState
        }
        sessionSwitchGeneration += 1
        let generation = sessionSwitchGeneration

if restoreSessionState(displayID: key) {
            return generation
        }

        // Show empty chat immediately to avoid spinning wheel.
        // Load messages from disk in background and apply when ready.
        self.sessionID = runtimeSessionID(for: key)
        self.messages = []
        self.isSessionReady = true
        self.isStreaming = false
        self.streamingMessageID = nil
        self.activeToolCalls = [:]
        self.setApprovalQueue(ApprovalQueue())
        self.pendingClarify = nil
        self.avatarState = .idle
        self.error = nil
        self.activeSkills = []
        self.loadedSkills = []
        snapshotCurrentSessionState()

        if ChatHistoryStore.shared.hasLocalMessages(forSession: key) {
            let gen = generation
            Task {
                if let cachedMessages = await ChatHistoryStore.shared.loadMessagesBackground(forSession: key),
                   gen == self.sessionSwitchGeneration {
                    self.messages = cachedMessages
                }
            }
        }
        return generation
    }

    /// Resume an existing session by key, replacing the currently visible chat state.
    /// Existing live state for the previously selected session is snapshotted first,
    /// so switching away from an active reasoning/tool turn does not discard it.
    @discardableResult
    func resumeSession(key: String) async -> Bool {
        let generation = beginSwitchToSession(key: key)
        return await resumeSession(key: key, generation: generation)
    }

    @discardableResult
    func resumeSession(key: String, generation: Int) async -> Bool {
        guard let client = gatewayClient else {
            if generation == sessionSwitchGeneration {
                self.error = "No harness client"
            }
            return false
        }
        guard case .connected = client.connectionState else {
            if generation == sessionSwitchGeneration {
                needsGatewayResume = true
                self.error = "Not connected to harness"
            }
            return false
        }

        guard pendingResumeKey != key else {
            log.info("skipping duplicate resume for key=\(key) generation=\(generation)")
            return false
        }
        pendingResumeKey = key
        defer { pendingResumeKey = nil }

        let cachedBeforeResume = sessionStates[key]

        do {
            let result = try await client.resumeSession(key: key)
            guard generation == sessionSwitchGeneration else {
                log.info("ignoring stale resume for \(key) generation=\(generation) current=\(self.sessionSwitchGeneration)")
                return false
            }

            stableSessionByGatewayID[result.sessionID] = key
            gatewayIDByStableSession[key] = result.sessionID

            // Parse + merge off the main thread — result.messages can be
            // hundreds of entries and the loop + object allocation is pure CPU
            // work that blocks the run loop when done inline on @MainActor.
            let rawMessages = result.messages
            let hasLocal = ChatHistoryStore.shared.hasLocalMessages(forSession: key)
            let localMessages = hasLocal
                ? await ChatHistoryStore.shared.loadMessagesBackground(forSession: key)
                : nil
            let parsedMessages: [ChatMessage] = await Task.detached(priority: .userInitiated) {
                var parsed = Self.parseHistoryMessages(rawMessages)
                if !parsed.isEmpty, let local = localMessages {
                    parsed = Self.mergeHistory(gateway: parsed, local: local)
                }
                return parsed
            }.value
            if !parsedMessages.isEmpty {
                if var liveState = sessionStates[key], liveState.isStreaming {
                    // The gateway history returned by session.resume is a persisted
                    // snapshot and can lag behind the currently running turn. Do not
                    // replace an in-memory live stream with non-streaming history when
                    // the user clicks away and back mid-tool-use; that is the exact
                    // path that made the live session appear to disappear.
                    //
                    // However, background delta events are skipped for performance
                    // (see applySessionEvent), so the cached state may only contain
                    // the empty assistant placeholder from messageStart.  When the
                    // cache is stale (no assistant message with content), fall back
                    // to the gateway's persisted history.
                    let cachedHasContent = liveState.messages.contains(where: {
                        $0.role == .assistant && (!$0.isStreaming || !$0.content.isEmpty)
                    })
                    if !cachedHasContent {
                        liveState.messages = parsedMessages
                    }
                    liveState.isSessionReady = true
                    sessionStates[key] = liveState
                } else {
                    sessionStates[key] = SessionRuntimeState(
                        messages: parsedMessages,
                        isStreaming: false,
                        isSessionReady: true,
                        sessionTitle: cachedBeforeResume?.sessionTitle ?? sessionTitle
                    )
                }
            } else if cachedBeforeResume == nil, ChatHistoryStore.shared.hasLocalMessages(forSession: key) {
                if let cachedMessages = await ChatHistoryStore.shared.loadMessagesBackground(forSession: key) {
                    sessionStates[key] = SessionRuntimeState(
                        messages: cachedMessages,
                        isStreaming: false,
                        isSessionReady: true
                    )
                }
            }

            if !restoreSessionState(displayID: key, runtimeID: result.sessionID) {
                self.sessionID = result.sessionID
                self.isSessionReady = true
                self.messages = []
                self.activeToolCalls = [:]
                self.setApprovalQueue(ApprovalQueue())
        self.pendingClarify = nil
            self.pendingClarify = nil
                self.isStreaming = false
                self.streamingMessageID = nil
                self.avatarState = .idle
                self.error = nil
                snapshotCurrentSessionState()
            }

            await applyEphemeralPrompt(for: result.sessionID, using: client)
            needsGatewayResume = false
            return true
        } catch {
            if generation == sessionSwitchGeneration {
                self.needsGatewayResume = true
                self.error = "Session resume failed: \(error.localizedDescription)"
            }
            return false
        }
    }

    private func applyEphemeralPrompt(for sessionID: String, using client: any AgentBackend) async {
        guard client.capabilities.supportsResponseStyles else { return }
        let prompt = Self.appFormattingPrompt + "\n\n" + responseStyle.preamble
        try? await client.setEphemeralPrompt(sessionID: sessionID, prompt: prompt)
    }

    /// Sessions that already received the formatting prompt inline (backends
    /// with no system-prompt channel). In-memory: harness threads have
    /// conversational memory, so once per session per launch is enough — a
    /// re-send after app restart is redundant but harmless.
    private var inlineFormattingPromptSent: Set<String> = []

    /// The formatting contract for backends that can't take an ephemeral
    /// system prompt (Centaur): folded into the FIRST user message of the
    /// session instead. Without this the harness model never learns the
    /// app's native fences (```chart/graph/stats/tree, typeset math, diff
    /// rendering) and answers in plain markdown — "Centaur doesn't support
    /// the pretty viz" was exactly this gap, not a renderer limitation.
    private func inlineFormattingPreamble(for sessionID: String) -> String {
        guard !backendCapabilities.supportsResponseStyles,
              !inlineFormattingPromptSent.contains(sessionID) else { return "" }
        inlineFormattingPromptSent.insert(sessionID)
        return Self.appFormattingPrompt + "\n\n---\n\n"
    }

    /// Route a newly created session to the user's last-picked model. No-op
    /// when the user never picked one (gateway default stays in charge) or
    /// the backend can't switch models. Best-effort like the ephemeral
    /// prompt: session.info remains the source of truth for the badge.
    private func applyDefaultModel(for sessionID: String, using client: any AgentBackend) async {
        guard backendCapabilities.supportsModelSwitching,
              let model = AgentModel.storedDefaultID else { return }
        try? await client.setConfig(key: "model", value: model, sessionID: sessionID)
    }

    /// Change the response style for the active session and push the updated
    /// ephemeral prompt to the gateway. The choice also becomes the default
    /// for new sessions.
    func setResponseStyle(_ style: ResponseStyle) {
        guard style != responseStyle else { return }
        responseStyle = style
        ResponseStyle.storedDefault = style
        snapshotCurrentSessionState()
        guard let sid = sessionID, let client = gatewayClient else { return }
        Task {
            await applyEphemeralPrompt(for: sid, using: client)
        }
    }

    private func applySessionSkills(for sessionID: String, using client: any AgentBackend) async {
        let names = activeSkills.map { $0.name }
        guard !names.isEmpty else { return }
        try? await client.setSessionSkills(sessionID: sessionID, skillNames: names)
    }

    /// The gateway tool the agent calls to read a skill on its own initiative.
    /// `skills_list` is deliberately not included — listing the catalog is the
    /// agent browsing, not a skill shaping the turn.
    private static let skillViewToolName = "skill_view"

    /// Note a skill the agent read mid-turn, from the `skill_view` tool call.
    ///
    /// This is the only visibility the app has into agent-initiated skill use:
    /// the gateway exposes `skill_view` as a normal tool, so a dynamic load
    /// arrives as an ordinary tool call and is otherwise indistinguishable from
    /// a `Read`. The skill name comes from the call's display label; a label
    /// nothing name-shaped can be read out of is skipped rather than recorded as
    /// an empty skill.
    ///
    /// The category is resolved from the local catalog so a dynamically loaded
    /// skill gets the same chip color as the attached one, falling back to
    /// "general" for skills the client's catalog doesn't know (host-side or
    /// plugin skills the app never listed).
    private func skillRecord(forToolNamed name: String, context: String?) -> TurnSkillRecord? {
        guard name == Self.skillViewToolName,
              let context,
              let skillName = TurnSkillRecord.skillName(fromViewLabel: context) else { return nil }
        let category = SkillStore.shared.skills
            .first { $0.name == skillName }?.category ?? "general"
        return TurnSkillRecord(name: skillName, category: category, origin: .loaded)
    }

    /// Build a preamble prepending attached skill instructions.
    private func skillPreamble() -> String {
        guard !activeSkills.isEmpty else { return "" }
        let sections = activeSkills.compactMap { skill -> String? in
            let content = skill.skillMdFullContent ?? skill.skillMdPreview
            guard let content, !content.isEmpty else { return nil }
            return "## Skill: \(skill.name)\n\(content)"
        }
        guard !sections.isEmpty else { return "" }
        return "# Attached Skills\n\n" + sections.joined(separator: "\n\n---\n\n") + "\n\n---\n\n"
    }

    // MARK: - Slash Command Autocomplete & Skill Attachment

    /// Call this whenever `inputText` changes to update slash suggestions.
    func updateSlashSuggestions() {
        let text = inputText
        // Skills are Hermes gateway state; offering them on a harness
        // backend would attach nothing (setSessionSkills is a no-op there).
        guard backendCapabilities.supportsSkills else {
            slashMode = false
            slashSuggestions = []
            slashSelectedIndex = 0
            return
        }
        guard text.hasPrefix("/") else {
            slashMode = false
            slashSuggestions = []
            slashSelectedIndex = 0
            return
        }
        let query = String(text.dropFirst()).lowercased().trimmingCharacters(in: .whitespaces)
        let all = SkillStore.shared.skills
        slashSuggestions = all.filter {
            let nameMatch = $0.name.lowercased().contains(query)
            let cmdMatch = $0.slashCommand.lowercased().contains(query)
            return nameMatch || cmdMatch
        }.sorted { $0.name < $1.name }
        slashMode = !slashSuggestions.isEmpty
        slashSelectedIndex = 0
    }

    /// Attach a skill to the active session and clear slash mode.
    func attachSkill(_ skill: SkillInfo) {
        guard !activeSkills.contains(where: { $0.name == skill.name }) else { return }
        activeSkills.append(skill)
        snapshotCurrentSessionState()
        inputText = ""
        slashMode = false
        slashSuggestions = []
        Task {
            // Lazy-load full content if needed
            if skill.skillMdFullContent == nil,
               let content = await SkillStore.shared.readSkillContent(name: skill.name),
               let idx = activeSkills.firstIndex(where: { $0.name == skill.name }) {
                activeSkills[idx].skillMdFullContent = content
            }
            if let sid = sessionID, let client = gatewayClient {
                try? await client.setSessionSkills(sessionID: sid, skillNames: activeSkills.map { $0.name })
            }
        }
    }

    func detachSkill(named name: String) {
        activeSkills.removeAll { $0.name == name }
        snapshotCurrentSessionState()
        Task {
            if let sid = sessionID, let client = gatewayClient {
                let names = activeSkills.map { $0.name }
                try? await client.setSessionSkills(sessionID: sid, skillNames: names)
            }
        }
    }

    // MARK: - Keyboard Navigation for Slash Menu

    func navigateSlashDown() {
        guard slashMode else { return }
        slashSelectedIndex = min(slashSelectedIndex + 1, slashSuggestions.count - 1)
    }

    func navigateSlashUp() {
        guard slashMode else { return }
        slashSelectedIndex = max(slashSelectedIndex - 1, 0)
    }

    func confirmSlashSelection() {
        guard slashMode, slashSelectedIndex < slashSuggestions.count else { return }
        attachSkill(slashSuggestions[slashSelectedIndex])
    }

    // MARK: - Quiz Actions

    /// Clear quiz state (called when the quiz sheet is dismissed).
    func clearQuiz() {
        quizQuestions = nil
        quizTopic = ""
        errorMessageForQuiz = nil
        awaitingQuizResponse = false
        flashcardDeckReady = nil
    }

    /// Clear the pending course signal once the view has acted on it. The course
    /// itself is already on disk, so this only drops the "just arrived" flag.
    internal func clearCurriculumSignal() {
        curriculumReady = nil
    }

    /// Send a review prompt to the agent and close the quiz.
    func reviewQuizWithAgent(prompt: String) async {
        quizQuestions = nil
        quizTopic = ""
        errorMessageForQuiz = nil
        awaitingQuizResponse = false

        // Set the prompt text and submit
        inputText = prompt
        await submitPrompt()
    }

    /// The generation prompt for `/curriculum`. Spells out the JSON shape
    /// `CurriculumResponse` parses, and asks for a quiz after each group of
    /// lessons so progress has something to measure.
    internal static func curriculumPrompt(topic: String) -> String {
        """
        Design a structured course on "\(topic)": 3-5 modules, each with 2-4 lesson \
        steps followed by one quiz step that tests that module's material.

        Lesson `content` is markdown — explain the idea, give a concrete example, \
        keep each lesson to a few hundred words. Quiz questions have 4 plausible \
        options labeled "A) …" through "D) …" and `correct` is the letter alone.

        Return ONLY valid JSON, no prose around it:
        {"curriculum":{"title":"...","summary":"one paragraph","modules":[\
        {"title":"...","overview":"one sentence","steps":[\
        {"type":"lesson","title":"...","content":"markdown body"},\
        {"type":"quiz","title":"...","questions":[\
        {"q":"...","options":["A) ...","B) ...","C) ...","D) ..."],"correct":"A","explanation":"..."}]}]}]}}
        """
    }

    /// Surface an inline quiz / flashcard deck, or act on a `[[QUIZ:topic]]`
    /// marker, from a completed turn's text. Both the foreground and
    /// session-routed messageComplete paths call this, and BOTH only call it for
    /// the session currently on screen: these open sheets and submit follow-up
    /// prompts, so a background turn firing them hijacks the visible chat.
    private func applyLearningArtifacts(from text: String, sessionID eventSessionID: String?) {
        if let questions = QuizResponse.extract(from: text), questions.count >= 3 {
            log.info("Quiz parsed (auto-detect): \(questions.count) questions")
            let inferredTopic = questions.first?.q.prefix(80) ?? "Quiz"
            quizTopic = String(inferredTopic)
            quizQuestions = questions
            return
        }
        if let deck = FlashcardResponse.extract(from: text), deck.cards.count >= 3 {
            log.info("Flashcard deck parsed (auto-detect): \(deck.cards.count) cards on \"\(deck.topic)\"")
            quizTopic = deck.topic
            flashcardDeckReady = deck
            return
        }
        guard let quizMatch = text.range(of: #"\[\[QUIZ:([^\]]+)\]\]"#, options: .regularExpression) else { return }
        let matchText = String(text[quizMatch])
        guard let topicRange = matchText.range(of: #"(?<=\[\[QUIZ:)[^\]]+"#, options: .regularExpression) else { return }
        let topic = String(matchText[topicRange]).trimmingCharacters(in: .whitespaces)
        guard !topic.isEmpty else { return }
        log.info("Quiz marker detected: \(topic)")
        quizTopic = topic
        awaitingQuizResponse = true
        Task { await autoGenerateQuiz(topic: topic, questionCount: 5) }
    }

    /// Agent embedded [[QUIZ:topic]] — fire a quiz generation prompt.
    func autoGenerateQuiz(topic: String, questionCount: Int = 5) async {
        guard let client = gatewayClient, let sid = sessionID else { return }
        let prompt = """
        Generate a \(questionCount)-question multiple choice quiz about "\(topic)".
        Questions should test understanding, not trivia. Each with 4 plausible options.
        Return ONLY valid JSON with format:
        {"questions":[{"q":"question text","options":["A) ...","B) ...","C) ...","D) ..."],"correct":"A","explanation":"brief explanation"}]}
        """
        do {
            try await client.submitPrompt(sessionID: sid, text: prompt)
        } catch {
            log.error("Auto quiz generation failed: \(error.localizedDescription)")
            awaitingQuizResponse = false
        }
    }

    /// Load history for the current session (for reconnects where resume isn't used).
    func loadSessionHistory() async {
        guard let client = gatewayClient, let sid = sessionID else { return }
        let generation = sessionSwitchGeneration
        do {
            let historyMessages = try await client.sessionHistory(sessionID: sid)
            let parsed = Self.parseHistoryMessages(historyMessages)
            // Same staleness guard as loadSessionHistoryPreservingStream: drop
            // history that arrived after the user switched away.
            if !parsed.isEmpty, generation == sessionSwitchGeneration, sessionID == sid {
                self.messages = parsed
            }
        } catch {
            // Non-critical — show what we have
        }
    }

    /// Reconcile with gateway history without losing an in-flight streaming
    /// message. Used when another device starts a turn on this session: the
    /// remote user prompt only exists in server history, while the streaming
    /// assistant placeholder only exists locally.
    func loadSessionHistoryPreservingStream() async {
        guard let client = gatewayClient, let sid = sessionID else { return }
        let generation = sessionSwitchGeneration
        do {
            let historyMessages = try await client.sessionHistory(sessionID: sid)
            let parsed = Self.parseHistoryMessages(historyMessages)
            guard !parsed.isEmpty else { return }
            // The fetch is async: if the user switched sessions while it was in
            // flight, this history belongs to a chat that is no longer on screen
            // and writing it to `messages` would replace the visible transcript
            // with another session's.
            guard generation == sessionSwitchGeneration, sessionID == sid else { return }
            let streaming = messages.filter { $0.isStreaming }
            self.messages = parsed + streaming
            snapshotCurrentSessionState()
        } catch {
            // Non-critical — the stream still renders, only the remote user
            // prompt may be missing until the next resume.
        }
    }

    /// Parse gateway history messages into ChatMessage array.
    /// Gateway format: {"role": "user"|"assistant"|"tool", "text": "...", "name": "...", "context": "..."}
    /// Merge gateway-resumed history with locally-cached messages, preferring
    /// local content when it is richer.
    ///
    /// Why: the gateway's session.resume history can return assistant messages
    /// with truncated/preview text that drops fenced blocks (e.g. ```html```),
    /// so blindly replacing the local cache with gateway history loses the HTML
    /// "Open Page" content after a restart. The local on-disk cache stores the
    /// full original message text. We use the gateway list as the structural
    /// baseline (it may contain newer turns from other devices) but, for each
    /// aligned assistant message, keep whichever content is longer — which
    /// restores the full HTML the user already had.
    nonisolated internal static func mergeHistory(gateway: [ChatMessage], local: [ChatMessage]) -> [ChatMessage] {
        guard !local.isEmpty else { return gateway }
        guard !gateway.isEmpty else { return local }

        // Align same-role messages by their order of appearance. Keep the full
        // local message — not just its text — because delivered attachments
        // carry stable IDs that point at their persisted download-cache files.
        var localByRole: [ChatMessage.Role: [ChatMessage]] = [:]
        for message in local { localByRole[message.role, default: []].append(message) }
        var cursor: [ChatMessage.Role: Int] = [:]

        var merged = gateway
        for i in merged.indices {
            let role = merged[i].role
            let idx = cursor[role, default: 0]
            cursor[role] = idx + 1
            guard let localMessages = localByRole[role], idx < localMessages.count else { continue }
            let localMessage = localMessages[idx]
            let localContent = localMessage.content
            // Keep the longer text — the local full body beats a gateway preview
            // that dropped the fenced HTML/code block.
            if localContent.count > merged[i].content.count {
                merged[i].content = localContent
            }
            if !localMessage.attachments.isEmpty {
                merged[i].attachments = localMessage.attachments
            }
        }
        return merged
    }

    nonisolated internal static func parseHistoryMessages(_ rawMessages: [[String: AnyCodable]]) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        var currentToolCalls: [ToolCallRecord] = []

        for raw in rawMessages {
            guard let roleStr = raw["role"]?.stringValue else { continue }

            switch roleStr {
            case "user":
                let text = raw["text"]?.stringValue ?? ""
                guard !text.isEmpty else { continue }
                messages.append(ChatMessage(role: .user, content: text))

            case "assistant":
                // Flush any pending tool calls before this assistant message
                if !currentToolCalls.isEmpty {
                    if let lastIdx = messages.lastIndex(where: { $0.role == .assistant }) {
                        messages[lastIdx].toolCalls = currentToolCalls
                    }
                    currentToolCalls = []
                }

                // Fall back to a preview field if the gateway omitted full text
                // (some history responses are preview-only). mergeHistory then
                // upgrades this to the full local content when available.
                let text = raw["text"]?.stringValue ?? raw["preview"]?.stringValue ?? ""
                guard !text.isEmpty else { continue }
                var message = ChatMessage(role: .assistant, content: text, status: "complete")
                message.attachments = MediaParser.extractAttachments(from: text)
                messages.append(message)

            case "tool":
                let name = raw["name"]?.stringValue ?? "tool"
                let context = raw["context"]?.stringValue
                let toolID = "hist_\(messages.count)"
                currentToolCalls.append(ToolCallRecord(
                    id: toolID,
                    name: name,
                    context: context,
                    summary: context,
                    isComplete: true
                ))

            default:
                break
            }
        }

        // Flush remaining tool calls
        if !currentToolCalls.isEmpty {
            if let lastIdx = messages.lastIndex(where: { $0.role == .assistant }) {
                messages[lastIdx].toolCalls = currentToolCalls
            }
        }

        return messages
    }

    // MARK: - User Input

    // MARK: Media Attachments

    /// Add an image file to pending attachments for the next message.
    func addAttachment(path: String) {
        let thumbnail = MediaAttachment.generateThumbnail(for: path)
        let attachment = MediaAttachment(path: path, thumbnailData: thumbnail)
        pendingAttachments.append(attachment)
    }

    /// Remove a pending attachment.
    func removeAttachment(_ attachment: MediaAttachment) {
        pendingAttachments.removeAll { $0.id == attachment.id }
    }

    /// Remove all pending attachments.
    func clearAttachments() {
        pendingAttachments.removeAll()
    }

    /// Send the current input text as a prompt.
    func submitPrompt() async {
        var text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments

        // ── /brief: one-message direct-style override ──
        // Strips the command and appends a style note to just this prompt,
        // leaving the session's response style untouched.
        var briefOverride = false
        if text.hasPrefix("/brief") {
            briefOverride = true
            text = text.dropFirst("/brief".count).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                self.error = "Usage: /brief <your question>"
                return
            }
        }
        // Allow submit if there is text OR pending attachments
        guard (!text.isEmpty || !attachments.isEmpty),
              let client = gatewayClient, let sid = sessionID else { return }
        guard !isStreaming && !isStopping else {
            log.info("ChatViewModel submitPrompt ignored while streaming/stopping")
            return
        }

        // ── Curriculum Detection ──
        // Checked before /quiz so the longer command isn't shadowed by a prefix
        // match, and so the course prompt (not the raw text) reaches the agent.
        if text.hasPrefix("/curriculum") {
            let topic = text.dropFirst("/curriculum".count).trimmingCharacters(in: .whitespaces)
            guard !topic.isEmpty else {
                self.error = "Usage: /curriculum <topic>"
                return
            }

            inputText = ""
            pendingAttachments = []
            isStreaming = true

            let userMessage = ChatMessage(role: .user, content: "/curriculum \(topic)")
            messages.append(userMessage)

            if messages.filter({ $0.role == .user }).count == 1 {
                sessionTitle = "Course: \(String(topic.prefix(40)))"
            }

            saveHistory()
            snapshotCurrentSessionState()

            let assistantMessage = ChatMessage(role: .assistant, content: "", isStreaming: true)
            streamingMessageID = assistantMessage.id
            streamStartDate = Date()
            messages.append(assistantMessage)
            snapshotCurrentSessionState()

            do {
                try await client.submitPrompt(sessionID: sid, text: Self.curriculumPrompt(topic: topic))
            } catch {
                log.error("Curriculum prompt submission failed: \(error.localizedDescription)")
                self.error = error.localizedDescription
                finishStreaming(status: "error")
            }
            return
        }

        // ── Quiz Mode Detection ──
        if text.hasPrefix("/quiz") {
            let quizParts = text.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !quizParts.isEmpty else {
                self.error = "Usage: /quiz <topic> [questionCount]"
                return
            }
            // Parse optional question count: /quiz ML 10
            let components = quizParts.split(separator: " ", omittingEmptySubsequences: true)
            let questionCount: Int
            let topic: String
            if let last = components.last, let count = Int(last), count > 0 {
                questionCount = count
                topic = components.dropLast().joined(separator: " ")
            } else {
                questionCount = 5
                topic = quizParts
            }
            guard !topic.isEmpty else {
                self.error = "Usage: /quiz <topic> [questionCount]"
                return
            }

            inputText = ""
            pendingAttachments = []
            isStreaming = true
            awaitingQuizResponse = true
            quizTopic = topic
            lastQuizPrompt = """
                Generate a \(questionCount)-question multiple choice quiz about \(topic).
                Return ONLY valid JSON: {"questions":[{"q":"...","options":["A) ...","B) ...","C) ...","D) ..."],"correct":"A","explanation":"..."}]}
                """

            // Add user message
            let userMessage = ChatMessage(role: .user, content: "/quiz \(topic)")
            messages.append(userMessage)

            let isFirstMessage = messages.filter({ $0.role == .user }).count == 1
            if isFirstMessage {
                sessionTitle = "Quiz: \(String(topic.prefix(40)))"
            }

            saveHistory()
            snapshotCurrentSessionState()

            // Prepare streaming assistant message
            let assistantMessage = ChatMessage(role: .assistant, content: "", isStreaming: true)
            streamingMessageID = assistantMessage.id
            streamStartDate = Date()
            messages.append(assistantMessage)
            snapshotCurrentSessionState()

            // Send the quiz prompt instead of the raw user text
            do {
                try await client.submitPrompt(sessionID: sid, text: lastQuizPrompt)
            } catch {
                log.error("Quiz prompt submission failed: \(error.localizedDescription)")
                self.error = error.localizedDescription
                finishStreaming(status: "error")
                awaitingQuizResponse = false
            }
            return
        }

        if needsGatewayResume, let sid = sessionID {
            let key = displaySessionID(for: sid)
            log.info("Auto-resume before submit: key=\(key)")
            if await resumeSession(key: key) {
                needsGatewayResume = false
            } else {
                self.error = "Session connection lost. Please try again."
                return
            }
        }

        inputText = ""
        pendingAttachments = []
        isStreaming = true
        // Agent-loaded skills are per-turn: the previous turn's dynamic loads
        // are already stamped onto its message, and carrying them forward would
        // claim this turn read a skill it hasn't.
        loadedSkills = []

        // Add user message to conversation (with attachments), recording the
        // skills attached when it was sent — the prompt carries their SKILL.md,
        // so this is what the user chose for this turn.
        var userMessage = ChatMessage(
            role: .user,
            content: text,
            userAttachments: attachments
        )
        userMessage.skills = activeSkills.map(TurnSkillRecord.attached)
        messages.append(userMessage)

        // Auto-title from first user message
        let isFirstMessage = messages.filter({ $0.role == .user }).count == 1
        if isFirstMessage {
            sessionTitle = text.isEmpty
                ? "Image chat"
                : String(text.prefix(60))
            CelebrationManager.shared.onFirstMessage(sessionID: sid)
        }

        // Persist user message immediately
        saveHistory()
        snapshotCurrentSessionState()

        // Prepare streaming assistant message
        let assistantMessage = ChatMessage(
            role: .assistant,
            content: "",
            isStreaming: true
        )
        streamingMessageID = assistantMessage.id
        streamStartDate = Date()
        messages.append(assistantMessage)
        snapshotCurrentSessionState()

        do {
            var promptParts: [String] = []

            for attachment in attachments {
                // Each attachment is best-effort: a single failure must never
                // abort the whole message send (it used to throw out of the
                // loop and the prompt was lost). Failures are logged and the
                // attachment is skipped instead.
                if let part = await ingestAttachment(attachment, client: client, sessionID: sid) {
                    promptParts.append(part)
                }
            }

            var promptText: String
            if !promptParts.isEmpty && !text.isEmpty {
                promptText = text + "\n\n" + promptParts.joined(separator: "\n\n")
            } else if !promptParts.isEmpty {
                promptText = promptParts.joined(separator: "\n\n")
            } else {
                promptText = text
            }

            if briefOverride {
                promptText += "\n\n" + ResponseStyle.briefOverridePreamble
            }

            log.info("Submitting prompt with \(attachments.count) attachments, text length: \(promptText.count)")
            let promptWithSkills = inlineFormattingPreamble(for: sid) + skillPreamble() + promptText
            try await client.submitPrompt(sessionID: sid, text: promptWithSkills)
        } catch {
            log.error("Submit failed: \(error.localizedDescription)")
            self.error = error.localizedDescription
            finishStreaming(status: "error")
        }
    }

    // MARK: - Voice Recording

    /// Start VAD-bounded voice recording. The gateway captures audio, runs
    /// STT, and emits a `voice.transcript` event which is auto-submitted.
    internal func startVoiceRecording() async {
        guard let client = gatewayClient else { return }
        guard backendCapabilities.supportsVoice else { return }
        guard !isVoiceRecording else { return }
        do {
            _ = try await client.voiceToggle(action: "on")
            try await client.voiceRecord(action: "start")
            // voice.status event will set isVoiceRecording = true when the
            // gateway confirms recording state.
        } catch {
            log.error("Voice recording start failed: \(error.localizedDescription)")
            self.error = "Voice recording failed to start"
        }
    }

    /// Stop the current voice recording session.
    internal func stopVoiceRecording() async {
        guard let client = gatewayClient else { return }
        guard isVoiceRecording else { return }
        do {
            try await client.voiceRecord(action: "stop")
            _ = try await client.voiceToggle(action: "off")
            isVoiceRecording = false
        } catch {
            log.error("Voice recording stop failed: \(error.localizedDescription)")
            isVoiceRecording = false
        }
    }

    /// Ingest one attachment and return the prompt fragment representing it, or
    /// nil if the attachment couldn't be ingested (missing/empty/failed upload).
    /// Best-effort by contract: this never throws, so one bad attachment can't
    /// sink the whole message send.
    ///
    /// Routing by type:
    ///   • image    → upload + image.attach (vision analysis on the gateway)
    ///   • document → extract text on-device and embed it inline
    ///   • fallback → upload and reference the server-side path so the agent
    ///                can read it with its own file tools
    private func ingestAttachment(_ attachment: MediaAttachment,
                                  client: any AgentBackend,
                                  sessionID sid: String) async -> String? {
        let path = attachment.path
        let ext = attachment.fileExtension.lowercased()

        // Read off the main actor — attachments can be tens of MB and
        // synchronous file I/O here would beachball the UI.
        let fileData = await Task.detached(priority: .userInitiated) { () -> Data? in
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return FileManager.default.contents(atPath: path)
        }.value
        guard let fileData, !fileData.isEmpty else {
            log.warning("Attachment file missing or empty, skipping: \(attachment.fileName)")
            return nil
        }

        // Images: existing vision path. image.attach is image-only on the
        // gateway, so only real images go through it.
        if attachment.category == .image {
            let mime = (ext == "jpg" || ext == "jpeg") ? "image/jpeg" : "image/\(ext)"
            do {
                let serverPath = try await client.uploadFile(
                    data: fileData, filename: attachment.fileName, mimeType: mime, sessionID: sid)
                try await client.attachImage(path: serverPath, sessionID: sid)
                return "[Image: \(attachment.fileName)]"
            } catch {
                log.error("Image attach failed for \(attachment.fileName): \(error.localizedDescription)")
                return nil
            }
        }

        // Documents: try on-device text extraction first so the model gets the
        // content directly (no server file-format support required).
        if DocumentTextExtractor.isLikelyExtractable(ext) {
            let extracted = await Task.detached(priority: .userInitiated) { () -> String? in
                DocumentTextExtractor.extractText(path: path, fileExtension: ext)
            }.value
            if let extracted, !extracted.isEmpty {
                log.info("Embedding document inline: \(attachment.fileName), \(extracted.count) chars")
                return "Attached document \"\(attachment.fileName)\":\n\n\(extracted)"
            }
            log.info("On-device extraction yielded nothing for \(attachment.fileName); uploading instead")
        }

        // Fallback: upload the bytes and hand the agent a readable server path.
        let mime = MIMETypeMap[ext] ?? "application/octet-stream"
        do {
            let serverPath = try await client.uploadFile(
                data: fileData, filename: attachment.fileName, mimeType: mime, sessionID: sid)
            return "[The user attached a file \"\(attachment.fileName)\" at \(serverPath) — read it with your file tools if relevant.]"
        } catch {
            log.error("File upload failed for \(attachment.fileName): \(error.localizedDescription)")
            return nil
        }
    }

    /// Interrupt the current agent turn.
    func interrupt() async {
        guard !isStopping else { return }
        guard let client = gatewayClient, let sid = sessionID else {
            finishStreaming(status: "interrupted")
            await reasoningGraph.finalize()
            return
        }

        let stoppingID = displaySessionID(for: sid)
        stoppingSessions.insert(stoppingID)
        defer { stoppingSessions.remove(stoppingID) }

        // Update the UI immediately. On iOS this avoids the Stop button looking
        // dead while the gateway waits for the in-flight turn to unwind.
        finishStreaming(status: "interrupted")

        do {
            try await client.interrupt(sessionID: sid)
        } catch {
            self.error = error.localizedDescription
        }
        await reasoningGraph.finalize()
    }

    /// - Parameter completedTurn: whether a live turn actually ended here. False
    ///   when the gateway drained a `message.complete` for a turn local state had
    ///   already finished — the settle below still has to run (that is what
    ///   unwedges a desynced session), but a turn the user stopped must not fire
    ///   the completion celebration or read its answer aloud.
    private func finishStreaming(status: String? = nil, completedTurn: Bool = true) {
        if let msgID = streamingMessageID,
           let idx = messages.firstIndex(where: { $0.id == msgID }) {
            messages[idx].isStreaming = false
            if let status {
                messages[idx].status = status
            }
            if messages[idx].content.isEmpty && status == "interrupted" {
                messages[idx].content = "_Interrupted_"
            }
        }
        activeToolCalls = [:]
        isStreaming = false
        isRemoteTurn = false
        streamingMessageID = nil
        let duration = streamStartDate.map { Date().timeIntervalSince($0) } ?? 0
        streamStartDate = nil
        avatarState = .idle
        saveHistory()
        // Keep sessionStates consistent: the late-event drop guard in
        // applySessionEvent reads state.isStreaming from the snapshot, and a
        // remote messageStart is distinguished from late local frames by it.
        snapshotCurrentSessionState()

        guard completedTurn else { return }

        // Positive reinforcement celebration
        if status == nil || status == "complete" {
            CelebrationManager.shared.onResponseComplete(sessionID: currentSessionID ?? "", duration: duration)
        }

        // Text-to-speech summary
        TTSService.shared.speakLastAssistantMessage(messages)
    }

    // MARK: - Remote Attachment Downloads

    /// Parse MEDIA: attachments, rewriting any loopback host on remote URLs to
    /// the connected backend's reachable host so delivered PDFs/videos open and
    /// download off-device (agents emit `http://localhost:8642/v1/files/…`).
    private func attachments(from text: String) -> [FileAttachment] {
        MediaParser.extractAttachments(from: text) { [gatewayClient] raw in
            gatewayClient?.resolvedMediaURL(raw) ?? raw
        }
    }

    /// Trigger pre-fetch for any remote attachments in the last assistant message.
    /// Called after message.complete to start downloading files so they're ready
    /// by the time the user taps a chip.
    private func prefetchRemoteAttachments() {
        guard let client = gatewayClient,
              let lastIdx = messages.lastIndex(where: { $0.role == .assistant }) else { return }

        let remoteAttachments = messages[lastIdx].attachments.filter { $0.isRemote }

        for attachment in remoteAttachments {
            guard case .remote(let url) = attachment.source else { continue }
            guard case .notStarted = attachment.downloadState else { continue }

            let attachmentID = attachment.id
            let token = client.apiKey

            log.info("Pre-fetching remote attachment: \(attachment.fileName)")

            Task { [weak self] in
                guard let self else { return }
                do {
                    let data = try await client.downloadFile(from: url, token: token)
                    // Update the attachment in the message
                    if let msgIdx = self.messages.lastIndex(where: { $0.role == .assistant }),
                       let attIdx = self.messages[msgIdx].attachments.firstIndex(where: { $0.id == attachmentID }) {
                        self.messages[msgIdx].attachments[attIdx].downloadState = .ready(data: data)
                        // Persist to disk cache so file survives app restarts
                        self.messages[msgIdx].attachments[attIdx].persistToDisk(data: data)
                    }
                } catch {
                    log.error("Pre-fetch failed for \(attachment.fileName): \(error)")
                    if let msgIdx = self.messages.lastIndex(where: { $0.role == .assistant }),
                       let attIdx = self.messages[msgIdx].attachments.firstIndex(where: { $0.id == attachmentID }) {
                        self.messages[msgIdx].attachments[attIdx].downloadState = .failed(error: error.localizedDescription)
                    }
                }
            }
        }
    }

    /// Point `approvalQueue` at a new value and re-derive `pendingApproval` from
    /// it. The two must only ever change together — a head that disagrees with
    /// the queue is exactly the "prompt on screen isn't the one the gateway will
    /// resolve" bug this type exists to prevent.
    private func setApprovalQueue(_ queue: ApprovalQueue) {
        approvalQueue = queue
        pendingApproval = queue.head
    }

    /// Respond to the approval currently on screen.
    ///
    /// The gateway resolves its FIFO queue positionally — `approval.respond`
    /// has no request id, so this necessarily answers the OLDEST pending
    /// approval, which is why the UI only ever shows the head. Pass
    /// `applyToAll` for the "answer everything waiting" path, which maps to the
    /// gateway's `resolve_all` and unblocks every queued agent thread at once.
    internal func respondApproval(choice: String, applyToAll: Bool = false) async {
        guard let client = gatewayClient, let sid = sessionID else { return }
        guard !approvalQueue.isEmpty else { return }

        var queue = approvalQueue
        if applyToAll {
            queue.removeAll()
        } else {
            queue.removeHead()
        }
        setApprovalQueue(queue)
        // Session-wide scopes ("session"/"always") allowlist the command pattern
        // on the gateway, but that only auto-approves FUTURE matches — threads
        // already blocked in the queue are waiting on their own events and are
        // not retroactively released. So they stay queued and get asked, rather
        // than being optimistically cleared here.
        do {
            try await client.respondApproval(sessionID: sid, choice: choice, all: applyToAll)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Answer a pending clarify question. An empty answer cancels the
    /// prompt (the gateway treats "" as no answer and the agent proceeds).
    func respondClarify(answer: String) async {
        guard let client = gatewayClient, let clarify = pendingClarify else { return }
        pendingClarify = nil
        snapshotCurrentSessionState()
        do {
            try await client.respondClarify(requestID: clarify.requestID, answer: answer)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Switch the active session's model via config.set. Optimistic: the
    /// badge updates immediately and session.info confirms (or corrects) it.
    /// The choice also becomes the default for new sessions.
    ///
    /// The gateway may veto instead of applying: an expensive model returns
    /// confirm_required, published as `pendingModelConfirmation` for the UI
    /// to show; confirming resends with the confirmation flag.
    func switchModel(_ model: String, provider: String? = nil, confirmed: Bool = false) async {
        guard backendCapabilities.supportsModelSwitching else { return }
        // Record the pick as the new-session default BEFORE any early return.
        // If no session is wired yet (picker used from a fresh chat before
        // session.create lands), the guard below bails — the pick must still
        // stick so applyDefaultModel routes the upcoming session to it
        // instead of silently dropping the user's choice.
        AgentModel.storedDefaultID = model
        guard let client = gatewayClient, let sid = sessionID else {
            currentModel = model
            return
        }
        guard confirmed || AgentModel.normalize(model) != AgentModel.normalize(currentModel) else { return }
        let previousModel = currentModel
        currentModel = model
        snapshotCurrentSessionState()
        do {
            let outcome = try await client.switchModel(model, provider: provider, sessionID: sid, confirm: confirmed)
            if outcome.confirmRequired {
                // Not applied — roll the badge back and surface the gate.
                currentModel = previousModel
                snapshotCurrentSessionState()
                pendingModelConfirmation = ModelSwitchConfirmation(
                    model: model,
                    message: outcome.confirmMessage.isEmpty
                        ? "Switching to \(AgentModel.displayName(for: model)) may be expensive. Continue?"
                        : outcome.confirmMessage,
                    provider: provider
                )
            } else if !outcome.warning.isEmpty {
                self.error = outcome.warning
            }
        } catch {
            currentModel = previousModel
            snapshotCurrentSessionState()
            self.error = "Model switch failed: \(error.localizedDescription)"
        }
    }

    /// Fetch the live model inventory for the picker. Errors degrade to the
    /// static catalog silently — the menu must never break over inventory.
    func refreshModelCatalog(force: Bool = false) async {
        guard backendCapabilities.supportsModelSwitching,
              let client = gatewayClient else { return }
        if modelCatalog != nil && !force { return }
        do {
            if let catalog = try await client.modelOptions(sessionID: sessionID, refresh: force) {
                modelCatalog = catalog
                // model.options names the actual current model (session's or
                // gateway default). Fill the badge when session.info hasn't.
                if currentModel.isEmpty, !catalog.currentModel.isEmpty {
                    currentModel = catalog.currentModel
                }
            }
        } catch {
            log.info("model.options fetch failed (static catalog fallback): \(error.localizedDescription)")
        }
    }

    // MARK: - Local Persistence

    private var saveHistoryTask: Task<Void, Never>?

    /// Save current messages to disk immediately.
    func saveHistory() {
        guard let sid = sessionID, !messages.isEmpty else { return }
        ChatHistoryStore.shared.saveMessages(messages, forSession: sid)
        let displayID = displaySessionID(for: sid)
        if displayID != sid {
            ChatHistoryStore.shared.saveMessages(messages, forSession: displayID)
        }
    }

    /// Debounced save — coalesces rapid calls during streaming into at most one save per second.
    func saveHistoryDebounced() {
        saveHistoryTask?.cancel()
        saveHistoryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.saveHistory()
        }
    }

    /// Load messages from local disk for a session (instant, no network).
    func loadLocalHistory(sessionID: String) {
        snapshotCurrentSessionState()
        if restoreSessionState(displayID: sessionID) {
            return
        }
        if let cached = ChatHistoryStore.shared.loadMessages(forSession: sessionID) {
            self.messages = cached
            self.sessionID = runtimeSessionID(for: sessionID)
            self.isSessionReady = true
            self.isStreaming = false
            self.streamingMessageID = nil
            self.activeToolCalls = [:]
            snapshotCurrentSessionState()
        }
    }

    /// Delete local history for a session.
    func deleteLocalHistory(sessionID: String) {
        cancelPendingFlush()
        ChatHistoryStore.shared.deleteMessages(forSession: sessionID)
        sessionStates.removeValue(forKey: sessionID)
        gatewayIDByStableSession.removeValue(forKey: sessionID)
        for (gatewayID, displayID) in stableSessionByGatewayID where displayID == sessionID {
            stableSessionByGatewayID.removeValue(forKey: gatewayID)
        }
    }

#if DEBUG
    @discardableResult
    func createLocalTestSession(id: String) -> String {
        snapshotCurrentSessionState()
        sessionID = id
        messages = []
        isStreaming = false
        isSessionReady = true
        setApprovalQueue(ApprovalQueue())
        pendingClarify = nil
        activeToolCalls = [:]
        error = nil
        avatarState = .idle
        sessionTitle = "New Chat"
        streamingMessageID = nil
        snapshotCurrentSessionState()
        return id
    }

    func switchToLocalTestSession(id: String) {
        snapshotCurrentSessionState()
        _ = restoreSessionState(displayID: id, runtimeID: runtimeSessionID(for: id))
    }

    var testCachedMessageCount: Int {
        guard let sessionID else { return 0 }
        return sessionStates[displaySessionID(for: sessionID)]?.messages.count ?? 0
    }

    func simulateTestResumeResult(displayID: String, runtimeID: String, history: [ChatMessage]) {
        stableSessionByGatewayID[runtimeID] = displayID
        gatewayIDByStableSession[displayID] = runtimeID
        if var liveState = sessionStates[displayID], liveState.isStreaming {
            if liveState.messages.isEmpty {
                liveState.messages = history
            }
            liveState.isSessionReady = true
            sessionStates[displayID] = liveState
        } else {
            sessionStates[displayID] = SessionRuntimeState(
                messages: history,
                isStreaming: false,
                isSessionReady: true
            )
        }
        _ = restoreSessionState(displayID: displayID, runtimeID: runtimeID)
    }

    func applyTestEvent(_ event: GatewayEvent, sessionID: String) {
        applySessionEvent(event, to: sessionID)
    }

    /// Drain the coalesced delta buffers synchronously, as the 500ms timer
    /// would. Tests use this to assert WHERE buffered tokens land across a
    /// session switch without waiting on the real cadence.
    internal func flushDeltaBuffersForTesting() {
        flushPendingVisibleEventDeltas()
    }

    /// Messages cached for a session that isn't necessarily on screen.
    internal func testCachedMessages(displayID: String) -> [ChatMessage] {
        sessionStates[displayID]?.messages ?? []
    }
#endif


    /// Show a short-lived status line ("aggregating via …"); auto-clears.
    private func showTransientStatus(_ text: String) {
        guard !text.isEmpty else { return }
        transientStatus = text
        transientStatusClearTask?.cancel()
        transientStatusClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.transientStatus = nil
        }
    }

    // MARK: - Context Compaction (thought-graph folds)

    /// A live `status.update kind="compressing"` for the displayed session —
    /// the precise moment a `/compress` folded the context. Record a MANUAL
    /// fold now; the counter delta at message-complete will subtract these so
    /// the same event isn't also counted as automatic. Caller guards that this
    /// is the displayed session.
    private func recordManualCompaction() {
        currentTurnCompactions.append(CompactionMarker(
            id: "manual-\(UUID().uuidString)",
            at: Date(),
            trigger: .manual,
            detail: "context compacted"
        ))
        manualCompactionsThisTurn += 1
    }

    /// Seed a session's compaction counter WITHOUT emitting a fold — used on
    /// session.info (connect/resume) so a session that already compacted before
    /// we were watching doesn't fabricate a fold on its next turn. Idempotent;
    /// only the first observation of a session sets the baseline.
    private func seedCompactionBaseline(displayID: String, usage: UsageInfo?) {
        guard let usage, compactionCounterBaseline[displayID] == nil else { return }
        compactionCounterBaseline[displayID] = usage.compressions
    }

    /// Reconcile the cumulative `usage.compressions` counter at message-complete.
    /// The delta since the last turn is how AUTOMATIC compaction is detected —
    /// it emits no live event, only ticks this counter. Manual folds already
    /// recorded live this turn are subtracted so they aren't double-counted.
    /// The baseline is always advanced (so cross-session counts stay accurate),
    /// but a fold is only appended for the displayed turn — automatic folds
    /// carry no timestamp, so they're stamped at the turn's end.
    private func noteCompactionCounter(displayID: String, usage: UsageInfo?, isDisplayed: Bool) {
        guard let usage else { return }
        let newCount = usage.compressions
        guard let baseline = compactionCounterBaseline[displayID] else {
            compactionCounterBaseline[displayID] = newCount   // first sight — seed, don't emit
            return
        }
        compactionCounterBaseline[displayID] = newCount
        let delta = newCount - baseline
        guard delta > 0, isDisplayed else { return }
        // Manual folds already drawn live this turn also ticked the counter.
        let autoCount = max(0, delta - manualCompactionsThisTurn)
        guard autoCount >= 1 else { return }
        let detail = autoCount == 1 ? "context compacted" : "context compacted ×\(autoCount)"
        currentTurnCompactions.append(CompactionMarker(
            id: "auto-\(displayID)-\(newCount)",
            at: Date(),
            trigger: .automatic,
            detail: detail
        ))
    }

    /// Land a whole MoA reference answer as a labelled discrete thinking
    /// block on the streaming assistant message.
    private func appendMoAReference(label: String, text: String, to messages: inout [ChatMessage]) {
        guard !text.isEmpty,
              let idx = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) else { return }
        if messages[idx].thinkingTrace == nil {
            messages[idx].thinkingTrace = ThinkingTrace(isStreaming: true)
        }
        let header = label.isEmpty ? "reference" : label
        messages[idx].thinkingTrace?.appendDiscreteBlock(text, kind: .moaReference, label: header)
    }

    /// Attach an output-risk verdict to the matching tool record. The scanner
    /// is async, so the verdict may land while the tool is active or after
    /// the turn completed (record already merged into a message).
    private func applyToolRisk(
        _ payload: ToolOutputRiskPayload,
        activeToolCalls: inout [String: ToolCallRecord],
        messages: inout [ChatMessage]
    ) {
        guard !payload.toolID.isEmpty else { return }
        if var record = activeToolCalls[payload.toolID] {
            record.applyRisk(payload)
            activeToolCalls[payload.toolID] = record
            return
        }
        for msgIdx in messages.indices.reversed() {
            if let toolIdx = messages[msgIdx].toolCalls.firstIndex(where: { $0.id == payload.toolID }) {
                messages[msgIdx].toolCalls[toolIdx].applyRisk(payload)
                return
            }
        }
    }

    /// Affection-detection reaction → celebration. Unknown kinds stay safe.
    private func handleReaction(kind: String) {
        switch kind {
        case "hearts":
            CelebrationManager.shared.onReaction(occasion: "Hearts received!")
        case "":
            break
        default:
            // Unknown kinds are benign — celebrate generically rather than
            // dropping the gateway's affection signal.
            CelebrationManager.shared.onReaction(occasion: "Reaction: \(kind)")
        }
    }

    private func appendThinkingTrace(_ text: String, kind: ThinkingBlock.Kind, to message: inout ChatMessage) {
        if message.thinkingTrace == nil {
            message.thinkingTrace = ThinkingTrace(isStreaming: message.isStreaming)
        }
        message.thinkingTrace?.append(text, kind: kind)
    }

    private func finishThinkingTrace(on message: inout ChatMessage, finalReasoning: String?) {
        if let finalReasoning, !finalReasoning.isEmpty {
            if message.thinkingTrace == nil {
                message.thinkingTrace = ThinkingTrace(
                    blocks: [ThinkingBlock(kind: .reasoning, text: finalReasoning)],
                    isStreaming: false
                )
            } else if message.thinkingTrace?.blocks.contains(where: { $0.kind == .reasoning }) == false {
                // Trace already exists mid-stream (MoA reference blocks) —
                // the final reasoning must still land or it's lost.
                message.thinkingTrace?.append(finalReasoning, kind: .reasoning)
            }
        }
        message.thinkingTrace?.finish()
        // Keep the legacy reasoning field populated for persistence/search and
        // backward-compatible views, but the UI prefers the structured trace.
        if let traceText = message.thinkingTrace?.fullText, !traceText.isEmpty {
            message.reasoning = traceText
        } else {
            message.reasoning = finalReasoning ?? message.reasoning
        }
    }

    // MARK: - Event Handling

    private func shouldApplyGlobalEvent(_ event: GatewayEvent) -> Bool {
        switch event {
        case .gatewayReady, .backgroundComplete, .skinChanged, .voiceTranscript, .voiceStatus:
            return true
        case .sessionInfo:
            // The gateway emits a session-less session.info on connect that
            // describes its current default model. It must populate the model
            // badge even before any session exists — dropping it leaves the
            // picker showing "No model" with nothing checked. Session-scoped
            // session.info never reaches this path (it routes through
            // applySessionEvent by session_id).
            return true
        default:
            return false
        }
    }

    private func recordPerfEvent(_ name: String, bytes: Int = 0) {
        guard perfLoggingEnabled else { return }
        perfEventCounts[name, default: 0] += 1
        if bytes > 0 { perfEventCounts["\(name).bytes", default: 0] += bytes }
        let now = Date()
        guard now.timeIntervalSince(perfLastLog) >= 5 else { return }
        perfLastLog = now
        let counts = perfEventCounts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        let fields = [
            "visible",
            "session=\(sessionID ?? "nil")",
            "messages=\(messages.count)",
            "streaming=\(isStreaming)",
            "content=\(messages.last?.content.count ?? 0)",
            "reasoning=\(messages.last?.reasoning?.count ?? 0)",
            "activeTools=\(activeToolCalls.count)",
            "flushes=\(perfFlushCount)",
            counts,
        ]
        writePerfLog("[PortalPerf] \(fields.joined(separator: " "))")
    }

    /// Claim the delta buffers for `displayID`, flushing anything another
    /// session left behind first. Deltas are coalesced across a 500ms window,
    /// so without this a session switch mid-window would splice one session's
    /// tokens into the other's transcript.
    private func claimDeltaBuffers(for displayID: String) {
        guard pendingVisibleDeltaOwner != displayID else { return }
        if pendingVisibleDeltaOwner != nil {
            flushPendingVisibleEventDeltas()
        }
        pendingVisibleDeltaOwner = displayID
    }

    private func appendPendingVisibleMessageDelta(_ text: String, owner: String) {
        recordPerfEvent("messageDelta", bytes: text.count)
        claimDeltaBuffers(for: owner)
        pendingVisibleMessageDelta += text
        scheduleVisibleEventFlush()
    }

    private func appendPendingVisibleReasoningDelta(_ text: String, owner: String, separator: String = "") {
        recordPerfEvent("reasoningDelta", bytes: text.count)
        claimDeltaBuffers(for: owner)
        if !pendingVisibleReasoningDelta.isEmpty || !pendingVisibleThinkingDelta.isEmpty {
            pendingVisibleReasoningDelta += separator
        }
        pendingVisibleReasoningDelta += text
        scheduleVisibleEventFlush()
    }

    private func appendPendingVisibleThinkingDelta(_ text: String, owner: String, separator: String = "") {
        recordPerfEvent("thinkingDelta", bytes: text.count)
        claimDeltaBuffers(for: owner)
        if !pendingVisibleThinkingDelta.isEmpty || !pendingVisibleReasoningDelta.isEmpty {
            pendingVisibleThinkingDelta += separator
        }
        pendingVisibleThinkingDelta += text
        scheduleVisibleEventFlush()
    }

    private func cancelPendingFlush() {
        pendingVisibleEventFlush?.cancel()
        pendingVisibleEventFlush = nil
        pendingVisibleMessageDelta = ""
        pendingVisibleReasoningDelta = ""
        pendingVisibleThinkingDelta = ""
        pendingVisibleDeltaOwner = nil
    }

    private func scheduleVisibleEventFlush() {
        guard pendingVisibleEventFlush == nil else { return }
        pendingVisibleEventFlush = Task {
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                if error is CancellationError { return }
            }
            guard !Task.isCancelled else { return }
            flushPendingVisibleEventDeltas()
        }
    }

    private func flushPendingVisibleEventDeltas() {
        pendingVisibleEventFlush = nil
        let messageDelta = pendingVisibleMessageDelta
        let reasoningDelta = pendingVisibleReasoningDelta
        let thinkingDelta = pendingVisibleThinkingDelta
        let owner = pendingVisibleDeltaOwner
        pendingVisibleMessageDelta = ""
        pendingVisibleReasoningDelta = ""
        pendingVisibleThinkingDelta = ""
        pendingVisibleDeltaOwner = nil

        guard !messageDelta.isEmpty || !reasoningDelta.isEmpty || !thinkingDelta.isEmpty else { return }
        // The buffers only ever hold the visible session's tokens, but the user
        // may have switched away during the 500ms coalescing window. Those
        // tokens belong to the session that produced them: fold them into its
        // cached state and leave the published arrays (now showing a different
        // session) alone.
        if let owner, displaySessionID(for: sessionID ?? "") != owner {
            applyDeltasToCachedState(
                displayID: owner,
                message: messageDelta,
                reasoning: reasoningDelta,
                thinking: thinkingDelta
            )
            return
        }
        perfFlushCount += 1
        recordPerfEvent("visibleFlush")
        if perfLoggingEnabled {
            perfVisibleFlushLogCount += 1
            if perfVisibleFlushLogCount <= 20 || perfVisibleFlushLogCount.isMultiple(of: 20) {
                writePerfLog("[PortalPerf] flush=\(perfVisibleFlushLogCount) " +
                    "messageBytes=\(messageDelta.count) " +
                    "reasoningBytes=\(reasoningDelta.count) " +
                    "thinkingBytes=\(thinkingDelta.count) " +
                    "pendingMessages=\(messages.count)")
            }
        }

        // Update the streaming message in-place instead of replacing the
        // entire messages array.  This avoids a full SwiftUI re-render of
        // every message view on each 500ms flush tick.
        //
        // Applied SYNCHRONOUSLY: we are already on the main actor, and the old
        // DispatchQueue.main.async hop deferred the append past any session
        // switch queued behind it — so tokens were appended to whichever chat
        // the user had clicked to by the time the block ran. The hop bought
        // nothing (same thread, same runloop turn's end) and cost correctness.
        if !messageDelta.isEmpty {
            if let msgID = streamingMessageID,
               let idx = messages.firstIndex(where: { $0.id == msgID }) {
                messages[idx].content += messageDelta
            } else if isStreaming, let idx = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
                messages[idx].content += messageDelta
            }
        }
        let thoughtDelta = reasoningDelta + thinkingDelta
        if !thoughtDelta.isEmpty,
           let idx = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
            messages[idx].reasoning = (messages[idx].reasoning ?? "") + thoughtDelta
        }
        snapshotCurrentSessionState()
    }

    /// Fold coalesced deltas into a session's CACHED state, for tokens whose
    /// session left the screen before the buffer flushed. Mirrors the published
    /// path above so switching back shows the tokens rather than dropping them.
    private func applyDeltasToCachedState(
        displayID: String,
        message: String,
        reasoning: String,
        thinking: String
    ) {
        guard var state = sessionStates[displayID] else { return }
        // Slim (evicted) background state has no messages array to append to;
        // its transcript is recovered from disk/session.resume on switch-back.
        guard !state.messages.isEmpty else { return }
        if !message.isEmpty {
            if let msgID = state.streamingMessageID,
               let idx = state.messages.firstIndex(where: { $0.id == msgID }) {
                state.messages[idx].content += message
            }
        }
        let thoughts = reasoning + thinking
        if !thoughts.isEmpty,
           let idx = state.messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
            state.messages[idx].reasoning = (state.messages[idx].reasoning ?? "") + thoughts
        }
        sessionStates[displayID] = state
    }

    private func applySessionEvent(_ event: GatewayEvent, to eventSessionID: String) {
        let displayID = displaySessionID(for: eventSessionID)
        /// Whether we have ANY local record of this session. Absence is not
        /// evidence that a turn ended here — see the drop guard below.
        let isKnownSession = sessionStates[displayID] != nil
        var state = sessionStates[displayID] ?? SessionRuntimeState()
        /// Whether this session had a live turn BEFORE this event was applied.
        /// Distinguishes a turn genuinely finishing here from the gateway
        /// draining a turn the user already stopped — the two need the same
        /// state settling but only the first is a completion to celebrate.
        let wasStreaming = state.isStreaming

        // Drop live-turn frames that arrive after the turn ended locally — the
        // gateway can drain one in-flight turn after the UI has stopped it.
        //
        // `resumesLiveTurn` is the escape hatch, and it is load-bearing: local
        // `isStreaming` and the gateway's view of the turn CAN desync (a
        // reconnect mid-turn, an `error` frame for a turn the agent then keeps
        // running, a resume whose persisted history lags the live turn). Without
        // it the guard was one-way — the terminal `messageComplete` is itself a
        // live-turn event, so it was dropped along with everything else and the
        // turn could never finish locally. The avatar sat on "Thinking…", the
        // thought graph paused on the last operation it had applied, and no
        // subsequent event could clear it; only a relaunch or an explicit Stop
        // recovered it. Honouring the turn-ending frames lets the desync
        // self-heal on the next event.
        //
        // `isKnownSession` narrows it further: with no cached state at all, the
        // freshly-defaulted `isStreaming == false` above is a default, not an
        // observation, so it is no evidence the turn ended. Dropping on it
        // silently discarded every frame of a session this client had not
        // cached yet — another client's turn on a shared session, or one whose
        // state was cleared by a gateway switch.
        if event.isLiveTurnEvent && isKnownSession && !state.isStreaming && !event.resumesLiveTurn {
            let reason = "late live-turn event after stream ended"
            log.info("ChatViewModel ignored late live event after stream ended: \(event.debugName)")
            gatewayClient?.recordDroppedEvent(event, sessionID: eventSessionID, reason: reason)
            return
        }

        // Skip high-frequency delta events for background (non-visible)
        // sessions.  Every delta triggers a copy-on-write clone of the full
        // messages array — for long sessions this saturates the main thread
        // and causes the spinning wheel.  Background session state is
        // re-synced via the session.resume RPC when the user switches back.
        switch event {
        case .messageDelta, .reasoningDelta, .thinkingDelta:
            if displaySessionID(for: sessionID ?? "") != displayID {
                return
            }
        case .subagentSpawnRequested, .subagentStart, .subagentComplete,
             .subagentTool, .subagentThinking, .subagentProgress:
            // Subagent events never mutate chat state — they feed the
            // thought-graph integrator (which debounces token-rate thinking
            // publishes itself). Bail before the @Published reassignment and
            // state-clone machinery below: running that per event fires
            // objectWillChange on the whole ChatView and pins the main
            // thread in layout (spinning wheel).
            if displaySessionID(for: sessionID ?? "") == displayID {
                applySubagentEvent(event, toolCalls: state.activeToolCalls)
            }
            return
        default:
            break
        }

        switch event {
        case .artifactChanged, .unknown:
            // Store-level concern; ArtifactStore subscribes directly.
            // .unknown never reaches consumers (GatewayClient drops it).
            break

        case .sessionTitle:
            // Sidebar concern; SessionListViewModel subscribes directly.
            break

        case .sessionInfo(let info):
            state.currentModel = info.model
            if displaySessionID(for: sessionID ?? "") == displayID {
                currentModel = info.model
            }
            // Seed the compaction counter (without emitting) so compactions
            // that happened before we connected don't fabricate a fold later.
            seedCompactionBaseline(displayID: displayID, usage: info.usage)
            state.isSessionReady = true

        case .messageStart:
            // A turn we didn't submit locally — another device/client started
            // it on this shared session. Mirror it: the local user prompt is
            // missing, so pull history (which includes the just-submitted
            // user message) before streaming content arrives.
            let isRemoteStart = !state.isStreaming && !stoppingSessions.contains(displayID)
            if isRemoteStart {
                state.isRemoteTurn = true
                if displaySessionID(for: sessionID ?? "") == displayID {
                    Task { await loadSessionHistoryPreservingStream() }
                }
            }
            state.isStreaming = true
            state.avatarState = .speaking
            if state.streamingMessageID == nil {
                let assistantMessage = ChatMessage(role: .assistant, content: "", isStreaming: true)
                state.streamingMessageID = assistantMessage.id
                state.messages.append(assistantMessage)
            }
            if displaySessionID(for: sessionID ?? "") == displayID {
                streamingMessageID = state.streamingMessageID
                reasoningGraph.reset()
                subagentGraph.reset()
                currentTurnCompactions = []
                manualCompactionsThisTurn = 0
            }
            // Attribute the run to the session the EVENT belongs to, not to
            // whichever session happens to be on screen — a background turn
            // starting while another session is visible used to file its run
            // (and, at message-complete, its token usage) under the visible one.
            SessionRunHistoryStore.shared.recordRunStart(sessionID: displayID)

        case .messageDelta(let text, _):
            if let msgID = state.streamingMessageID,
               let idx = state.messages.firstIndex(where: { $0.id == msgID }) {
                state.messages[idx].content += text
                if displaySessionID(for: sessionID ?? "") == displayID {
                    recordPerfEvent("sessionMessageDelta", bytes: text.count)
                    claimDeltaBuffers(for: displayID)
                    pendingVisibleMessageDelta += text
                    scheduleVisibleEventFlush()
                }
            }

        case .messageComplete(payload: let payload):
            if displaySessionID(for: sessionID ?? "") == displayID {
                flushPendingVisibleEventDeltas()
                // Reload state to pick up flushed reasoning from snapshot
                state = sessionStates[displayID] ?? state
                Task { await reasoningGraph.finalize() }
            }
            guard let msgID = state.streamingMessageID,
                  let idx = state.messages.firstIndex(where: { $0.id == msgID }) else {
                // No message to stamp — but the turn IS over on the gateway, so
                // settle the flags anyway. This `break` used to leave
                // `isStreaming` true forever, which is the second way a session
                // wedged on "Thinking…": a background turn whose transcript was
                // dropped (message eviction, or a slim state that outlived its
                // shell) can't find its shell here, and the stuck flag then
                // blocked `submitPrompt`'s `guard !isStreaming` too — so the
                // session could neither finish nor accept a new prompt until
                // Stop (which calls finishStreaming) or a relaunch cleared it.
                state.activeToolCalls = [:]
                state.isStreaming = false
                state.streamingMessageID = nil
                state.avatarState = .idle
                state.isRemoteTurn = false
                break
            }
            state.messages[idx].content = payload.text
            state.messages[idx].isStreaming = false
            state.messages[idx].usage = payload.usage
            state.messages[idx].status = payload.status
            state.messages[idx].attachments = attachments(from: payload.text)
            state.messages[idx]._contentWithoutAttachments = MediaParser.stripMediaTags(from: payload.text)
            finishThinkingTrace(on: &state.messages[idx], finalReasoning: payload.reasoning)
            state.messages[idx].toolCalls = Array(state.activeToolCalls.values)
            // Reconcile the compaction counter BEFORE snapshotting so an
            // automatic fold detected at turn-end persists on this turn. Only
            // the displayed turn owns the live `currentTurnCompactions` the
            // snapshot reads; the baseline advances for every session.
            let isDisplayedTurn = displaySessionID(for: sessionID ?? "") == displayID
            noteCompactionCounter(displayID: displayID, usage: payload.usage, isDisplayed: isDisplayedTurn)
            // The integrators are turn-scoped to the DISPLAYED session, so a
            // background turn completing must not snapshot them — that grafted
            // the visible session's thinking/subagent tree onto this message.
            if isDisplayedTurn {
                state.messages[idx].graphSnapshot = captureGraphSnapshot()
            }
            // Stamp what shaped this turn while the record is still in hand —
            // both are per-session state, so a background turn attributes its own
            // skills rather than the visible session's.
            var turnSkills = state.activeSkills.map(TurnSkillRecord.attached)
            for loaded in state.pendingLoadedSkills {
                turnSkills.appendSkillRecord(loaded)
            }
            state.messages[idx].skills = turnSkills
            state.pendingLoadedSkills = []
            state.activeToolCalls = [:]
            state.isStreaming = false
            state.streamingMessageID = nil
            state.avatarState = .idle
            state.isRemoteTurn = false
            let runStatus: SessionRunEvent.RunStatus = payload.status == "error" ? .failed : .completed
            SessionRunHistoryStore.shared.recordRunEnd(
                sessionID: displayID,
                inputTokens: payload.usage?.inputTokens,
                outputTokens: payload.usage?.outputTokens,
                totalTokens: payload.usage?.totalTokens,
                apiCalls: 1,
                status: runStatus
            )

            // ── Curriculum Response Handling ──
            // Checked before the quiz parser: a course carries `questions`
            // arrays inside its steps, so `QuizResponse.extract` would claim it
            // first and reduce a whole course to one loose quiz.
            //
            // A course is PERSISTED for any session (it's a Learning artifact,
            // not chat UI), but the quiz/flashcard sheets and the Learning
            // navigation only fire for the session on screen: a background turn
            // used to yank the user out of the chat they were watching, and its
            // [[QUIZ:…]] marker submitted a follow-up prompt into the VISIBLE
            // session (autoGenerateQuiz uses `sessionID`).
            if let course = CurriculumResponse.extract(from: payload.text) {
                log.info("Curriculum parsed: \(course.modules.count) modules, \(course.totalSteps) steps")
                curriculumStore.save(course)
                if isDisplayedTurn {
                    curriculumReady = course
                }
            } else if isDisplayedTurn {
                applyLearningArtifacts(from: payload.text, sessionID: eventSessionID)
            }

        case .toolStart(payload: let payload):
            state.avatarState = .toolUse
            state.activeToolCalls[payload.toolID] = ToolCallRecord(
                id: payload.toolID,
                name: payload.name,
                context: payload.context,
                startedAt: Date()
            )
            if let record = skillRecord(forToolNamed: payload.name, context: payload.context) {
                state.pendingLoadedSkills.appendSkillRecord(record)
            }

        case .toolComplete(payload: let payload):
            if var record = state.activeToolCalls[payload.toolID] {
                record.summary = payload.summary
                record.durationSeconds = payload.durationSeconds
                record.inlineDiff = payload.inlineDiff
                record.isComplete = true
                record.completedAt = Date()
                state.activeToolCalls[payload.toolID] = record
            }

        case .toolProgress(let name, let preview):
            for (key, var record) in state.activeToolCalls where record.name == name && !record.isComplete {
                record.context = preview
                state.activeToolCalls[key] = record
            }

        case .toolOutputRisk(let payload):
            applyToolRisk(payload, activeToolCalls: &state.activeToolCalls, messages: &state.messages)
            // Non-lifecycle events don't republish messages below — apply to
            // the published copies too so a post-turn verdict shows at once.
            if displaySessionID(for: sessionID ?? "") == displayID {
                applyToolRisk(payload, activeToolCalls: &activeToolCalls, messages: &messages)
            }

        case .moaReference(let label, let text, _):
            appendMoAReference(label: label, text: text, to: &state.messages)
            if displaySessionID(for: sessionID ?? "") == displayID {
                appendMoAReference(label: label, text: text, to: &messages)
            }

        case .moaAggregating(let aggregator):
            if displaySessionID(for: sessionID ?? "") == displayID {
                showTransientStatus(aggregator.isEmpty ? "aggregating" : "aggregating via \(aggregator)")
            }

        case .reaction(let kind):
            if displaySessionID(for: sessionID ?? "") == displayID {
                handleReaction(kind: kind)
            }

        case .reasoningDelta(let text):
            if state.avatarState != .toolUse && state.avatarState != .thinking { state.avatarState = .thinking }
            if state.messages.last(where: { $0.role == .assistant && $0.isStreaming }) != nil {
                if let idx = state.messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
                    let existing = state.messages[idx].reasoning ?? ""
                    state.messages[idx].reasoning = existing + text
                }
                if displaySessionID(for: sessionID ?? "") == displayID {
                    claimDeltaBuffers(for: displayID)
                    pendingVisibleReasoningDelta += text
                    scheduleVisibleEventFlush()
                    reasoningGraph.feed(delta: text)
                }
            }

        case .thinkingDelta(let text):
            if state.avatarState != .toolUse && state.avatarState != .thinking { state.avatarState = .thinking }
            if state.messages.last(where: { $0.role == .assistant && $0.isStreaming }) != nil {
                if displaySessionID(for: sessionID ?? "") == displayID {
                    appendPendingVisibleThinkingDelta(text, owner: displayID, separator: "\n")
                    reasoningGraph.feed(delta: text)
                }
            }

        case .approvalRequest(payload: let payload):
            state.approvalQueue.enqueue(payload)

        case .clarifyRequest(payload: let payload):
            state.pendingClarify = payload

        case .error(let message):
            state.error = message
            state.isStreaming = false
            state.isRemoteTurn = false
            state.avatarState = .error
            // Finalize the last streaming assistant message so it doesn't appear stuck
            if let msgID = state.streamingMessageID,
               let idx = state.messages.firstIndex(where: { $0.id == msgID }) {
                state.messages[idx].isStreaming = false
                state.messages[idx].status = "error"
                state.streamingMessageID = nil
            }
            state.activeToolCalls = [:]

        case .subagentSpawnRequested, .subagentStart, .subagentComplete,
             .subagentTool, .subagentProgress, .subagentThinking:
            // Already fed to the thought graph by the early-exit above;
            // unreachable here, kept only for switch exhaustiveness.
            break

        case .statusUpdate(let kind, let text):
            // Includes browser.progress / preview.restart.* (folded into
            // statusUpdate at decode) — transient line, no transcript entry.
            if displaySessionID(for: sessionID ?? "") == displayID {
                // A live `/compress` — the precise moment of a manual fold. Draw
                // it on the graph as well as flashing the transient line.
                if kind == "compressing" {
                    recordManualCompaction()
                }
                showTransientStatus(text)
            }

        case .toolGenerating, .reasoningAvailable,
             .gatewayReady, .skinChanged, .backgroundComplete,
             .sudoRequest, .secretRequest,
             .activityCreated, .activityUpdated,
              .reviewSummary:
            break

        case .voiceTranscript(let text, let noSpeechLimit):
            // Walkie-talkie mode: auto-submit transcribed speech as a prompt.
            // Only for the session on screen: `isVoiceRecording` and
            // `submitPrompt` are both bound to the VISIBLE session, so acting on
            // another session's transcript would type its speech into this chat.
            guard displaySessionID(for: sessionID ?? "") == displayID else { break }
            guard !isStopping, let client = gatewayClient, sessionID != nil else { break }
            // If gateway says no_speech or text is empty, just stop recording.
            guard !noSpeechLimit, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                isVoiceRecording = false
                break
            }
            isVoiceRecording = false
            // Stop recording first, then submit the transcript as the user's prompt.
            Task {
                do {
                    try await client.voiceRecord(action: "stop")
                } catch {
                    log.warning("Voice recording cleanup failed: \(error.localizedDescription)")
                }
                do {
                    _ = try await client.voiceToggle(action: "off")
                } catch {
                    log.warning("Voice mode cleanup failed: \(error.localizedDescription)")
                }
                inputText = text
                await submitPrompt()
            }

        case .voiceStatus(let voiceState):
            // Same reason as voiceTranscript: the mic indicator describes the
            // visible chat's composer.
            if displaySessionID(for: sessionID ?? "") == displayID {
                isVoiceRecording = (voiceState == "recording")
            }
        }

        // Persist state for lifecycle events, but use slim metadata for
        // background (non-visible) sessions. The full [ChatMessage] array
        // is a COW clone on every write — for sessions with 1,000+ messages
        // running in the background this saturates the main thread.
        // Background session messages are persisted to ChatHistoryStore on
        // messageComplete so the session.resume RPC can reload them later.
        let isVisibleSession = displaySessionID(for: sessionID ?? "") == displayID
        switch event {
        case .messageDelta, .reasoningDelta, .thinkingDelta:
            break
        default:
            if isVisibleSession {
                sessionStates[displayID] = state  // full clone
            } else {
                // Persist messages to disk BEFORE discarding from state
                if case .messageComplete = event {
                    ChatHistoryStore.shared.saveMessages(state.messages, forSession: displayID)
                }
                var slimState = sessionStates[displayID] ?? SessionRuntimeState()
                // Keep the in-flight assistant shell across sparse lifecycle
                // events. Dropping it after message.start meant the following
                // tool.start/message.complete could no longer find the message
                // to stamp or persist. Once complete, the transcript is on disk
                // and can be released again.
                slimState.messages = state.isStreaming ? state.messages : []
                slimState.isStreaming = state.isStreaming
                slimState.isSessionReady = state.isSessionReady
                slimState.approvalQueue = state.approvalQueue
                slimState.pendingClarify = state.pendingClarify
                slimState.activeToolCalls = state.activeToolCalls
                slimState.error = state.error
                slimState.avatarState = state.avatarState
                slimState.sessionTitle = state.sessionTitle
                slimState.streamingMessageID = state.streamingMessageID
                slimState.currentModel = state.currentModel
                slimState.activeSkills = state.activeSkills
                // Carried like the other in-flight turn state: these accumulate
                // across a background turn's tool calls and are consumed when it
                // completes, so dropping them here would lose every skill the
                // agent loaded in a session the user wasn't watching. (Messages
                // are deliberately NOT carried — they were just persisted to
                // disk — but this is turn state, not transcript.)
                slimState.pendingLoadedSkills = state.pendingLoadedSkills
                sessionStates[displayID] = slimState
            }
        }
        let isVisibleCoalescedDelta: Bool
        switch event {
        case .messageDelta, .reasoningDelta, .thinkingDelta:
            isVisibleCoalescedDelta = displaySessionID(for: sessionID ?? "") == displayID
        default:
            isVisibleCoalescedDelta = false
        }
        if displaySessionID(for: sessionID ?? "") == displayID {
            if isVisibleCoalescedDelta {
                // Coalesced delta events are published on a 500ms cadence via
                // scheduleVisibleEventFlush() — do NOT publish immediately here
                // or every token triggers a full SwiftUI re-render cycle.
            } else {
                // Only replace the entire messages array for lifecycle events
                // that create or finalize a message.  Tool and thinking events
                // update tool records and reasoning text in-place — replacing
                // the array on every event causes SwiftUI to re-render every
                // WKWebView in the tree, saturating IPC with WebContent processes.
                switch event {
                case .messageStart, .messageComplete, .error:
                    _ = restoreSessionState(displayID: displayID, runtimeID: eventSessionID)
                default:
                    isStreaming = state.isStreaming
                    isSessionReady = state.isSessionReady
                    setApprovalQueue(state.approvalQueue)
                    pendingClarify = state.pendingClarify
                    activeToolCalls = state.activeToolCalls
                    avatarState = state.avatarState
                    streamingMessageID = state.streamingMessageID
                    loadedSkills = state.pendingLoadedSkills
                }
            }
            if case .messageComplete(let payload) = event {
                // `completedTurn: wasStreaming` — a completion the guard above
                // now lets through for a session that was NOT streaming is
                // either a post-Stop drain or a desync heal. Both need the
                // settle; neither is a turn the user waited for, so suppress
                // the celebration and the spoken summary.
                finishStreaming(status: payload.status, completedTurn: wasStreaming)
                // Extract attachments and pre-fetch remote ones
                if let msgID = state.streamingMessageID ?? streamingMessageID,
                   let idx = messages.firstIndex(where: { $0.id == msgID }) {
                    messages[idx].attachments = attachments(from: payload.text)
                }
                prefetchRemoteAttachments()
            }
        }

        if case .messageComplete(let payload) = event {
            saveHistoryDebounced()
            // Turn-completion notification. NotificationService suppresses it
            // when the app is foregrounded AND this is the active session, so
            // it only surfaces for backgrounded or non-active sessions. Was
            // previously compiled out of DEBUG builds entirely, which meant no
            // completion notification ever fired while backgrounded.
            // Same reason as `completedTurn` above: only notify for a turn that
            // was actually live here, or a drained post-Stop completion would
            // push "your turn finished" for a turn the user cancelled.
            if payload.status == "complete", wasStreaming {
                NotificationService.shared.notifyTurnComplete(
                    sessionTitle: state.sessionTitle,
                    preview: payload.text.truncated(to: 80),
                    sessionID: eventSessionID
                )
            }
        }
    }

    /// The main-chain tool call a subagent spawn should attach to: the
    /// currently-running delegate/dispatch tool, falling back to the most
    /// recently started running tool (spawns only ever occur inside one).
    private func delegatingToolID(in toolCalls: [String: ToolCallRecord]) -> String? {
        let running = toolCalls.values.filter { !$0.isComplete }
        let delegates = running.filter {
            ThoughtGraphLayoutEngine.ToolCategory.classify(name: $0.name) == .agent
        }
        let pool = delegates.isEmpty ? running : delegates
        return pool.max(by: {
            ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast)
        })?.id
    }

    /// Feed a subagent.* event into the thought-graph integrator.
    /// Only the visible session's turn is tracked (the graph is turn-scoped).
    private func applySubagentEvent(_ event: GatewayEvent, toolCalls: [String: ToolCallRecord]) {
        switch event {
        case .subagentSpawnRequested(let payload):
            subagentGraph.upsertAgent(
                payload: payload,
                running: false,
                delegatingToolID: delegatingToolID(in: toolCalls)
            )
        case .subagentStart(let payload):
            subagentGraph.upsertAgent(
                payload: payload,
                running: true,
                delegatingToolID: delegatingToolID(in: toolCalls)
            )
        case .subagentComplete(let payload):
            subagentGraph.completeAgent(payload: payload)
        case .subagentTool(let payload):
            subagentGraph.recordTool(payload: payload)
        case .subagentThinking(let text, let subagentID),
             .subagentProgress(let text, let subagentID):
            subagentGraph.appendThinking(text, subagentID: subagentID)
        default:
            break
        }
    }

    private func handleEvent(_ event: GatewayEvent, eventSessionID: String?) {
        if let eventSessionID, !eventSessionID.isEmpty {
            applySessionEvent(event, to: eventSessionID)
            return
        }

        guard shouldApplyGlobalEvent(event) || sessionID != nil else {
            log.info("ChatViewModel ignored global event current=\(self.sessionID ?? "nil") event=\(event.debugName)")
            gatewayClient?.recordDroppedEvent(event, sessionID: eventSessionID, reason: "no active session")
            return
        }

        switch event {
        case .gatewayReady, .activityCreated, .activityUpdated, .reviewSummary, .artifactChanged,
             .sessionTitle, .unknown:
            break

        case .sessionInfo(let info):
            currentModel = info.model
            // A session-less session.info (gateway default announcement on
            // connect) must not mark a nonexistent session ready — that would
            // unlock the composer/picker before session.create succeeds.
            if sessionID != nil {
                isSessionReady = true
            }
            // Seed the compaction counter (without emitting) so a session that
            // already compacted before connect doesn't fabricate a fold later.
            if let sid = sessionID {
                seedCompactionBaseline(displayID: displaySessionID(for: sid), usage: info.usage)
            }

        case .messageStart:
            // Streaming begins — avatar is speaking
            guard isStreaming else { break }
            avatarState = .speaking
            reasoningGraph.reset()
            subagentGraph.reset()
            currentTurnCompactions = []
            manualCompactionsThisTurn = 0

        case .messageDelta(let text, _):
            recordPerfEvent("messageDelta", bytes: text.count)
            // Append streaming text to the current assistant message. Ignore
            // late deltas after an interrupt; the gateway can still drain one
            // in-flight turn after the UI has already stopped it locally.
            guard isStreaming else { break }
            appendPendingVisibleMessageDelta(text, owner: displaySessionID(for: sessionID ?? ""))

        case .messageComplete(payload: let payload):
            flushPendingVisibleEventDeltas()
            // Finalize the assistant message. If the user already hit Stop,
            // `streamingMessageID` is nil; ignore the late completion so it
            // doesn't resurrect an interrupted turn in the UI.
            guard let msgID = streamingMessageID,
                  let idx = messages.firstIndex(where: { $0.id == msgID }) else {
                // Nothing to stamp, but the turn ended — settle the flags rather
                // than leaving `isStreaming` latched on. See the same guard on
                // the session-scoped path: a stuck flag both holds the avatar on
                // "Thinking…" and blocks the next submit.
                activeToolCalls = [:]
                isStreaming = false
                avatarState = .idle
                isRemoteTurn = false
                Task { await reasoningGraph.finalize() }
                return
            }

            messages[idx].content = payload.text
            messages[idx].isStreaming = false
            messages[idx].usage = payload.usage
            messages[idx].status = payload.status
            finishThinkingTrace(on: &messages[idx], finalReasoning: payload.reasoning)
            // Merge any accumulated tool calls into the message
            messages[idx].toolCalls = Array(activeToolCalls.values)
            // Detect an automatic compaction from the counter delta BEFORE
            // snapshotting so the fold persists on this turn (foreground path is
            // always the displayed session). Keyed by the same displayID as the
            // background path so both reconcile against one baseline.
            noteCompactionCounter(
                displayID: displaySessionID(for: sessionID ?? ""),
                usage: payload.usage,
                isDisplayed: true
            )
            messages[idx].graphSnapshot = captureGraphSnapshot()
            // Record the skills that shaped this turn — attached up front plus
            // whatever the agent read via `skill_view` — so the turn stays
            // attributable after the attachment set moves on.
            messages[idx].skills = currentTurnSkills
            loadedSkills = []

            activeToolCalls = [:]
            isStreaming = false
            streamingMessageID = nil
            streamStartDate = nil
            avatarState = .idle

            // Extract attachments and pre-fetch remote ones
            messages[idx].attachments = attachments(from: payload.text)
            prefetchRemoteAttachments()

            writePerfSnapshot("messageComplete")

            // Persist to local storage after each completed response
            saveHistory()

            // Positive reinforcement celebration
            CelebrationManager.shared.onResponseComplete(sessionID: sessionID ?? "", duration: 0)

            // Text-to-speech summary
            TTSService.shared.speakLastAssistantMessage(messages)

            // Notify if app is backgrounded or this isn't the active session
            let preview = payload.text.truncated(to: 80)
            if let sid = sessionID {
                NotificationService.shared.notifyResponseComplete(
                    sessionTitle: sessionTitle,
                    preview: preview,
                    sessionID: sid
                )
            }

            Task { await reasoningGraph.finalize() }

            // ── Quiz Response Handling ──
            // Always check for quiz JSON and [[QUIZ:topic]] markers
            applyLearningArtifacts(from: payload.text, sessionID: eventSessionID)

        case .toolStart(payload: let payload):
            recordPerfEvent("toolStart")
            guard isStreaming else { break }
            avatarState = .toolUse
            activeToolCalls[payload.toolID] = ToolCallRecord(
                id: payload.toolID,
                name: payload.name,
                context: payload.context,
                startedAt: Date()
            )
            if let record = skillRecord(forToolNamed: payload.name, context: payload.context) {
                loadedSkills.appendSkillRecord(record)
            }

        case .toolComplete(payload: let payload):
            recordPerfEvent("toolComplete")
            guard isStreaming else { break }
            if var record = activeToolCalls[payload.toolID] {
                record.summary = payload.summary
                record.durationSeconds = payload.durationSeconds
                record.inlineDiff = payload.inlineDiff
                record.isComplete = true
                record.completedAt = Date()
                activeToolCalls[payload.toolID] = record
            }

        case .toolProgress(let name, let preview):
            recordPerfEvent("toolProgress", bytes: preview.count)
            guard isStreaming else { break }
            // Update matching tool call's progress display
            for (key, var record) in activeToolCalls where record.name == name && !record.isComplete {
                record.context = preview
                activeToolCalls[key] = record
            }

        case .toolGenerating:
            break

        case .toolOutputRisk(let payload):
            // No isStreaming gate: the scanner's verdict can trail the turn.
            applyToolRisk(payload, activeToolCalls: &activeToolCalls, messages: &messages)

        case .moaReference(let label, let text, _):
            guard isStreaming else { break }
            appendMoAReference(label: label, text: text, to: &messages)

        case .moaAggregating(let aggregator):
            guard isStreaming else { break }
            showTransientStatus(aggregator.isEmpty ? "aggregating" : "aggregating via \(aggregator)")

        case .reaction(let kind):
            handleReaction(kind: kind)

        case .reasoningDelta(let text):
            // Thinking/reasoning — avatar thinks
            guard isStreaming else { break }
            if avatarState != .toolUse && avatarState != .thinking { avatarState = .thinking }
            appendPendingVisibleReasoningDelta(text, owner: displaySessionID(for: sessionID ?? ""))
            reasoningGraph.feed(delta: text)

        case .thinkingDelta(let text):
            guard isStreaming else { break }
            if avatarState != .toolUse && avatarState != .thinking { avatarState = .thinking }
            // Append to last assistant message's reasoning (thinking IS reasoning
            // from the model's perspective — e.g. GLM-5.1 fires thinking.delta
            // not reasoning.delta).  Show it live so the user sees progress.
            let separator: String
            if let idx = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }),
               messages[idx].reasoning?.isEmpty == false {
                separator = "\n"
            } else {
                separator = ""
            }
            appendPendingVisibleThinkingDelta(
                text,
                owner: displaySessionID(for: sessionID ?? ""),
                separator: separator
            )

        case .reasoningAvailable:
            break

        case .approvalRequest(payload: let payload):
            // Append, never replace: a concurrent subagent's request arriving
            // here used to overwrite the visible one while its agent thread
            // stayed blocked until the gateway timed it out.
            var queue = approvalQueue
            queue.enqueue(payload)
            setApprovalQueue(queue)

        case .statusUpdate(let kind, let text):
            // Includes browser.progress / preview.restart.* (folded into
            // statusUpdate at decode) — transient line, no transcript entry.
            // A live `/compress` (kind="compressing") is the precise moment of a
            // manual fold — draw it on the graph as well as flashing the line.
            if kind == "compressing" {
                recordManualCompaction()
            }
            showTransientStatus(text)

        case .error(let message):
            self.error = message
            isStreaming = false
            avatarState = .error
            finishStreaming(status: "error")
            writePerfSnapshot("error")

        case .skinChanged:
            break

        case .subagentSpawnRequested, .subagentStart, .subagentComplete, .subagentTool, .subagentProgress, .subagentThinking:
            // Spawn-tree bookkeeping lives in SpawnTreeStore; feed the
            // thought graph's agent subtrees here.
            applySubagentEvent(event, toolCalls: activeToolCalls)

        case .backgroundComplete:
            break

        case .clarifyRequest(payload: let payload):
            pendingClarify = payload

        case .sudoRequest:
            // TODO: Present sudo password dialog
            break

        case .secretRequest:
            // TODO: Present secret input dialog
            break

        case .voiceTranscript, .voiceStatus:
            break
        }
    }

    private func notifyResponseCompleteIfNeeded(payload: MessageCompletePayload, eventSessionID: String?) {
        guard payload.status == "complete" else { return }
        let sid = eventSessionID ?? sessionID
        guard let sid, !sid.isEmpty else { return }

        let title: String
        if sid == sessionID {
            title = sessionTitle.isEmpty ? "Response complete" : sessionTitle
        } else {
            title = "Session \(sid.prefix(8))"
        }

        let preview = payload.text.isEmpty ? "Response complete" : payload.text.truncated(to: 80)
        NotificationService.shared.notifyResponseComplete(
            sessionTitle: title,
            preview: preview,
            sessionID: sid
        )
    }
}
