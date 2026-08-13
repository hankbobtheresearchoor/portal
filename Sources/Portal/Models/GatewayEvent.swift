import Foundation

/// Typed representation of all gateway event types the server can emit.
/// Each case carries a strongly-typed payload where possible.
///
/// Source: tui_gateway/server.py _emit() calls
enum GatewayEvent {
    var debugName: String {
        switch self {
        case .gatewayReady: "gateway.ready"
        case .sessionInfo: "session.info"
        case .sessionTitle: "session.title"
        case .messageStart: "message.start"
        case .messageDelta: "message.delta"
        case .messageComplete: "message.complete"
        case .toolStart: "tool.start"
        case .toolComplete: "tool.complete"
        case .toolProgress: "tool.progress"
        case .toolGenerating: "tool.generating"
        case .toolOutputRisk: "tool.output_risk"
        case .moaReference: "moa.reference"
        case .moaAggregating: "moa.aggregating"
        case .reaction: "reaction"
        case .reasoningDelta: "reasoning.delta"
        case .reasoningAvailable: "reasoning.available"
        case .thinkingDelta: "thinking.delta"
        case .subagentSpawnRequested: "subagent.spawn_requested"
        case .subagentStart: "subagent.start"
        case .subagentComplete: "subagent.complete"
        case .subagentTool: "subagent.tool"
        case .subagentProgress: "subagent.progress"
        case .subagentThinking: "subagent.thinking"
        case .backgroundComplete: "background.complete"
        case .approvalRequest: "approval.request"
        case .clarifyRequest: "clarify.request"
        case .sudoRequest: "sudo.request"
        case .secretRequest: "secret.request"
        case .statusUpdate: "status.update"
        case .error: "error"
        case .unknown(let type): "unknown(\(type))"
        case .skinChanged: "skin.changed"
        case .voiceTranscript: "voice.transcript"
        case .voiceStatus: "voice.status"
        case .activityCreated: "activity.created"
        case .activityUpdated: "activity.updated"
        case .reviewSummary: "review.summary"
        case .artifactChanged: "artifact.changed"
        }
    }

    var isLiveTurnEvent: Bool {
        switch self {
        // toolOutputRisk is deliberately not live-turn: the output scanner is
        // async and its verdict may trail messageComplete — dropping it as a
        // "late live event" would lose the risk badge on the finished turn.
        case .messageStart, .messageDelta, .messageComplete,
             .toolStart, .toolComplete, .toolProgress, .toolGenerating,
             .moaReference, .moaAggregating,
             .reasoningDelta, .reasoningAvailable, .thinkingDelta:
            true
        default:
            false
        }
    }

    /// Events that prove a turn is still running on the gateway, and so may
    /// re-open a local stream that `isStreaming == false` claims has ended.
    ///
    /// `isLiveTurnEvent` alone is a one-way gate: it drops every live-turn event
    /// except `messageStart` whenever local state says the turn is over. That is
    /// right for the case it was written for — draining frames after the user
    /// hits Stop — but wrong when the two have merely desynced, because the
    /// terminal `messageComplete` is itself a live-turn event and gets dropped
    /// too. The turn then never finishes locally: the avatar holds "Thinking…",
    /// the thought graph pauses on whichever operation was last applied, and no
    /// later event can clear it, which is why only a restart or an explicit stop
    /// recovered the session.
    ///
    /// A `messageComplete` / `error` is a turn *ending*, so honouring it can
    /// only ever settle local state — it cannot resurrect an interrupted turn
    /// (the foreground path already guards on `streamingMessageID` being nil,
    /// and the background path on finding the message to stamp). Treat those two
    /// as re-entry points alongside `messageStart` and the desync self-heals on
    /// the next frame instead of persisting until relaunch.
    internal var resumesLiveTurn: Bool {
        switch self {
        case .messageStart, .messageComplete, .error:
            true
        default:
            false
        }
    }

    var isSessionScopedRequestEvent: Bool {
        switch self {
        case .approvalRequest, .clarifyRequest, .sudoRequest, .secretRequest:
            true
        default:
            false
        }
    }

    // Connection lifecycle
    case gatewayReady(skin: String)

    // Session
    case sessionInfo(SessionInfo)
    /// Async titler result — the gateway pushes the generated title so the
    /// sidebar renames without waiting for the next session.list refresh.
    case sessionTitle(sessionKey: String, title: String)

    // Chat streaming
    case messageStart
    case messageDelta(text: String, rendered: String?)
    case messageComplete(payload: MessageCompletePayload)

    // Tool calls
    case toolStart(payload: ToolStartPayload)
    case toolComplete(payload: ToolCompletePayload)
    case toolProgress(name: String, preview: String)
    case toolGenerating(name: String)
    /// Output-security scanner verdict for a completed tool call.
    case toolOutputRisk(payload: ToolOutputRiskPayload)

    // Mixture-of-Agents intermediate outputs
    /// A discrete labelled reference answer from one MoA slot — lands whole,
    /// not as deltas.
    case moaReference(label: String, text: String, count: Int?)
    case moaAggregating(aggregator: String)

    // Affection detection (hearts etc.)
    case reaction(kind: String)

    // Reasoning / thinking
    case reasoningDelta(text: String)
    case reasoningAvailable(text: String)
    case thinkingDelta(text: String)

    // Subagent delegation
    case subagentSpawnRequested(payload: SubagentPayload)
    case subagentStart(payload: SubagentPayload)
    case subagentComplete(payload: SubagentCompletePayload)
    case subagentTool(payload: SubagentToolPayload)
    case subagentProgress(text: String, subagentID: String?)
    case subagentThinking(text: String, subagentID: String?)

    // Background tasks
    case backgroundComplete(taskID: String, text: String)

    // Approvals / blocking requests
    case approvalRequest(payload: ApprovalPayload)
    case clarifyRequest(payload: ClarifyPayload)
    case sudoRequest
    case secretRequest(prompt: String, envVar: String)

    // Status
    case statusUpdate(kind: String, text: String)
    case error(message: String)
    /// Event type the app doesn't (yet) understand. Benign: logged, never
    /// rendered. Keeps the app forward-compatible with gateway additions.
    case unknown(type: String)

    // Skin
    case skinChanged(skin: String?)

    // Voice
    case voiceTranscript(text: String, noSpeechLimit: Bool)
    case voiceStatus(state: String)

    // Activity inbox
    case activityCreated(ActivityItem)
    case activityUpdated(ActivityItem)

    // Review
    case reviewSummary(text: String)

    // Living artifacts (gateway store mutations — id + summary fields;
    // clients refetch content via artifact.get when they care)
    case artifactChanged(id: String, deleted: Bool)

    /// Parse from raw JSON-RPC event params.
    static func from(type: String, payload: AnyCodable?) -> GatewayEvent {
        let p = payload?.dictionaryValue ?? [:]

        switch type {
        case "gateway.ready":
            let skin = p["skin"]?.stringValue ?? ""
            return .gatewayReady(skin: skin)

        case "session.info":
            return .sessionInfo(SessionInfo.from(p))

        case "session.title":
            return .sessionTitle(
                sessionKey: p["session_id"]?.stringValue ?? "",
                title: p["title"]?.stringValue ?? ""
            )

        case "message.start":
            return .messageStart

        case "message.delta":
            return .messageDelta(
                text: p["text"]?.stringValue ?? "",
                rendered: p["rendered"]?.stringValue
            )

        case "message.complete":
            return .messageComplete(payload: MessageCompletePayload.from(p))

        case "tool.start":
            return .toolStart(payload: ToolStartPayload.from(p))

        case "tool.complete":
            return .toolComplete(payload: ToolCompletePayload.from(p))

        case "tool.progress":
            return .toolProgress(
                name: p["name"]?.stringValue ?? "",
                preview: p["preview"]?.stringValue ?? ""
            )

        case "tool.generating":
            return .toolGenerating(name: p["name"]?.stringValue ?? "")

        case "tool.output_risk":
            return .toolOutputRisk(payload: ToolOutputRiskPayload.from(p))

        case "moa.reference":
            return .moaReference(
                label: p["label"]?.stringValue ?? "",
                text: p["text"]?.stringValue ?? p["preview"]?.stringValue ?? "",
                count: p["count"]?.intValue
            )

        case "moa.aggregating":
            return .moaAggregating(aggregator: p["aggregator"]?.stringValue ?? "")

        case "reaction":
            return .reaction(kind: p["kind"]?.stringValue ?? "")

        // Progress pushes with no dedicated UI — fold into the generic
        // status line rather than growing three near-identical cases.
        case "browser.progress":
            return .statusUpdate(
                kind: "browser",
                text: p["message"]?.stringValue ?? ""
            )

        case "preview.restart.progress", "preview.restart.complete":
            return .statusUpdate(
                kind: "preview",
                text: p["text"]?.stringValue ?? ""
            )

        case "reasoning.delta":
            return .reasoningDelta(text: p["text"]?.stringValue ?? "")

        case "reasoning.available":
            return .reasoningAvailable(text: p["text"]?.stringValue ?? "")

        case "thinking.delta":
            return .thinkingDelta(text: p["text"]?.stringValue ?? "")

        case "subagent.spawn_requested":
            return .subagentSpawnRequested(payload: SubagentPayload.from(p))

        case "subagent.start":
            return .subagentStart(payload: SubagentPayload.from(p))

        case "subagent.complete":
            return .subagentComplete(payload: SubagentCompletePayload.from(p))

        case "subagent.tool":
            return .subagentTool(payload: SubagentToolPayload.from(p))

        case "subagent.progress":
            return .subagentProgress(
                text: p["text"]?.stringValue ?? "",
                subagentID: p["subagent_id"]?.stringValue
            )

        case "subagent.thinking":
            return .subagentThinking(
                text: p["text"]?.stringValue ?? "",
                subagentID: p["subagent_id"]?.stringValue
            )

        case "background.complete":
            return .backgroundComplete(
                taskID: p["task_id"]?.stringValue ?? "",
                text: p["text"]?.stringValue ?? ""
            )

        case "approval.request":
            return .approvalRequest(payload: ApprovalPayload.from(p))

        case "clarify.request":
            return .clarifyRequest(payload: ClarifyPayload.from(p))

        case "sudo.request":
            return .sudoRequest

        case "secret.request":
            return .secretRequest(
                prompt: p["prompt"]?.stringValue ?? "",
                envVar: p["env_var"]?.stringValue ?? ""
            )

        case "status.update":
            return .statusUpdate(
                kind: p["kind"]?.stringValue ?? "status",
                text: p["text"]?.stringValue ?? ""
            )

        case "error":
            return .error(message: p["message"]?.stringValue ?? "unknown error")

        case "skin.changed":
            return .skinChanged(skin: p["skin"]?.stringValue)

        case "voice.transcript":
            return .voiceTranscript(
                text: p["text"]?.stringValue ?? "",
                noSpeechLimit: p["no_speech_limit"]?.boolValue ?? false
            )

        case "voice.status":
            return .voiceStatus(state: p["state"]?.stringValue ?? "")

        case "activity.created":
            if let activity = p["activity"]?.dictionaryValue.flatMap(ActivityItem.from) ?? ActivityItem.from(p) {
                return .activityCreated(activity)
            }
            return .error(message: "invalid activity.created payload")

        case "activity.updated", "activity.read", "activity.dismissed":
            if let activity = p["activity"]?.dictionaryValue.flatMap(ActivityItem.from) ?? ActivityItem.from(p) {
                return .activityUpdated(activity)
            }
            return .error(message: "invalid activity.updated payload")

        case "artifact.changed":
            return .artifactChanged(
                id: p["id"]?.stringValue ?? "",
                deleted: p["deleted"]?.boolValue ?? false
            )

        case "review.summary":
            return .reviewSummary(text: p["text"]?.stringValue ?? "")

        default:
            // Tolerance, not error: the gateway grows event types faster than
            // the app learns them (agent.terminal.output, pet.*, …).
            // Surfacing them as .error painted a red banner in chat for
            // benign pushes. Consumers ignore .unknown; GatewayClient logs it.
            return .unknown(type: type)
        }
    }
}

// MARK: - Payload Types

struct SessionInfo {
    let model: String
    let reasoningEffort: String
    let fast: Bool
    let tools: [String: [String]]
    let skills: [String: String]
    let cwd: String
    let version: String
    let usage: UsageInfo?
    let mcpServers: [MCPServerInfo]?

    static func from(_ p: [String: AnyCodable]) -> SessionInfo {
        var tools: [String: [String]] = [:]
        if let toolsDict = p["tools"]?.dictionaryValue {
            for (key, value) in toolsDict {
                tools[key] = value.arrayValue?.map { $0.stringValue ?? "" } ?? []
            }
        }

        var skills: [String: String] = [:]
        if let skillsDict = p["skills"]?.dictionaryValue {
            for (key, value) in skillsDict {
                skills[key] = value.stringValue ?? ""
            }
        }

        return SessionInfo(
            model: p["model"]?.stringValue ?? "",
            reasoningEffort: p["reasoning_effort"]?.stringValue ?? "",
            fast: p["fast"]?.boolValue ?? false,
            tools: tools,
            skills: skills,
            cwd: p["cwd"]?.stringValue ?? "",
            version: p["version"]?.stringValue ?? "",
            usage: p["usage"].flatMap { UsageInfo.from($0) },
            mcpServers: nil
        )
    }
}

struct UsageInfo: Codable, TokenAccountable {
    let inputTokens: Int?
    let outputTokens: Int?
    /// Cumulative count of context compactions so far this session. This is
    /// auto-compaction's ONLY client-visible trace (it otherwise just prints to
    /// the gateway's stderr) — the delta between turns is how the thought graph
    /// detects one happened. 0 when the gateway doesn't report it.
    internal let compressions: Int

    var totalTokens: Int? {
        guard let i = inputTokens, let o = outputTokens else { return nil }
        return i + o
    }
    var costUSD: Double? { nil }

    enum CodingKeys: String, CodingKey {
        case inputTokens = "prompt_tokens"
        case outputTokens = "completion_tokens"
        case compressions
    }

    static func from(_ v: AnyCodable) -> UsageInfo? {
        guard let d = v.dictionaryValue else { return nil }
        return UsageInfo(
            inputTokens: d["prompt_tokens"]?.intValue,
            outputTokens: d["completion_tokens"]?.intValue,
            compressions: d["compressions"]?.intValue ?? 0
        )
    }
}

struct MCPServerInfo {
    let name: String
    let status: String
}

struct MessageCompletePayload {
    let text: String
    let status: String // "complete", "interrupted", "error"
    let usage: UsageInfo?
    let reasoning: String?
    let rendered: String?
    let warning: String?

    static func from(_ p: [String: AnyCodable]) -> MessageCompletePayload {
        MessageCompletePayload(
            text: p["text"]?.stringValue ?? "",
            status: p["status"]?.stringValue ?? "complete",
            usage: p["usage"].flatMap { UsageInfo.from($0) },
            reasoning: p["reasoning"]?.stringValue,
            rendered: p["rendered"]?.stringValue,
            warning: p["warning"]?.stringValue
        )
    }
}

struct ToolStartPayload {
    let toolID: String
    let name: String
    let context: String

    static func from(_ p: [String: AnyCodable]) -> ToolStartPayload {
        ToolStartPayload(
            toolID: p["tool_id"]?.stringValue ?? "",
            name: p["name"]?.stringValue ?? "",
            context: p["context"]?.stringValue ?? ""
        )
    }
}

struct ToolCompletePayload {
    let toolID: String
    let name: String
    let summary: String?
    let durationSeconds: Double?
    let inlineDiff: String?
    let todos: [TodoItem]?

    static func from(_ p: [String: AnyCodable]) -> ToolCompletePayload {
        var todos: [TodoItem]?
        if let todoArray = p["todos"]?.arrayValue {
            todos = todoArray.compactMap { item -> TodoItem? in
                guard let d = item.dictionaryValue else { return nil }
                return TodoItem(
                    id: d["id"]?.stringValue ?? "",
                    content: d["content"]?.stringValue ?? "",
                    status: d["status"]?.stringValue ?? "pending"
                )
            }
        }

        return ToolCompletePayload(
            toolID: p["tool_id"]?.stringValue ?? "",
            name: p["name"]?.stringValue ?? "",
            summary: p["summary"]?.stringValue,
            durationSeconds: p["duration_seconds"]?.doubleValue,
            inlineDiff: p["inline_diff"]?.stringValue,
            todos: todos
        )
    }
}

struct TodoItem {
    let id: String
    let content: String
    let status: String
}

/// Output-security scanner verdict for a tool call (tool.output_risk).
struct ToolOutputRiskPayload {
    let toolID: String
    let name: String
    let risk: ToolRiskLevel
    let findings: [String]
    let redacted: Bool

    static func from(_ p: [String: AnyCodable]) -> ToolOutputRiskPayload {
        ToolOutputRiskPayload(
            toolID: p["tool_id"]?.stringValue ?? "",
            name: p["name"]?.stringValue ?? "",
            risk: ToolRiskLevel(rawValue: p["risk"]?.stringValue ?? "") ?? .low,
            findings: p["findings"]?.arrayValue?.compactMap { $0.stringValue } ?? [],
            redacted: p["redacted"]?.boolValue ?? false
        )
    }
}

/// Risk level the gateway's output scanner assigns to a tool call's output.
/// Codable so it persists on ToolCallRecord with chat history.
enum ToolRiskLevel: String, Codable {
    case low
    case medium
    case high
}

internal struct ApprovalPayload: Equatable {
    internal let command: String
    internal let sessionKey: String
    internal let toolName: String?
    internal let rawArgs: String?
    /// Why this command needs approval (the gateway's `description` — which
    /// dangerous pattern matched, or the security scanner's summary).
    internal let description: String?
    /// The scopes the gateway is willing to accept for THIS request. It narrows
    /// them itself: a smart-denied command offers only `["once", "deny"]`, and
    /// one with `allow_permanent: false` omits `always`. Empty means the gateway
    /// sent none, and the client falls back to offering all four.
    internal let choices: [String]

    /// Spelled out rather than left to the memberwise init so the two fields the
    /// gateway may omit can default, and callers that only care about the
    /// command don't have to name them.
    internal init(
        command: String,
        sessionKey: String,
        toolName: String? = nil,
        rawArgs: String? = nil,
        description: String? = nil,
        choices: [String] = []
    ) {
        self.command = command
        self.sessionKey = sessionKey
        self.toolName = toolName
        self.rawArgs = rawArgs
        self.description = description
        self.choices = choices
    }

    /// Identity for queueing. Two blocked agent threads running the same command
    /// are genuinely distinct, so this is deliberately NOT used to deduplicate —
    /// see `ApprovalQueue.enqueue`.
    internal static func from(_ p: [String: AnyCodable]) -> ApprovalPayload {
        ApprovalPayload(
            command: p["command"]?.stringValue ?? "",
            sessionKey: p["session_key"]?.stringValue ?? "",
            toolName: p["tool_name"]?.stringValue,
            rawArgs: p["raw_args"]?.stringValue,
            description: p["description"]?.stringValue,
            choices: p["choices"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        )
    }
}

/// Payload for the blocking clarify.request prompt. `requestID` is the
/// gateway's pending-prompt key — clarify.respond must echo it back or the
/// agent thread waits out its full 300s timeout (the "infinite hang").
struct ClarifyPayload {
    let question: String
    internal let choices: [String]
    let requestID: String

    static func from(_ p: [String: AnyCodable]) -> ClarifyPayload {
        ClarifyPayload(
            question: p["question"]?.stringValue ?? "",
            choices: p["choices"]?.arrayValue?.compactMap { $0.stringValue } ?? [],
            requestID: p["request_id"]?.stringValue ?? ""
        )
    }
}

struct SubagentPayload {
    let goal: String
    let taskCount: Int
    let taskIndex: Int
    let subagentID: String?
    let parentID: String?
    let depth: Int?
    let model: String?

    static func from(_ p: [String: AnyCodable]) -> SubagentPayload {
        SubagentPayload(
            goal: p["goal"]?.stringValue ?? "",
            taskCount: p["task_count"]?.intValue ?? 1,
            taskIndex: p["task_index"]?.intValue ?? 0,
            subagentID: p["subagent_id"]?.stringValue,
            parentID: p["parent_id"]?.stringValue,
            depth: p["depth"]?.intValue,
            model: p["model"]?.stringValue
        )
    }
}

struct SubagentCompletePayload {
    let goal: String
    let taskCount: Int
    let taskIndex: Int
    let subagentID: String?
    let parentID: String?
    let depth: Int?
    let inputTokens: Int?
    let outputTokens: Int?
    let apiCalls: Int?
    let costUSD: Double?
    let filesRead: [String]?
    let filesWritten: [String]?

    static func from(_ p: [String: AnyCodable]) -> SubagentCompletePayload {
        SubagentCompletePayload(
            goal: p["goal"]?.stringValue ?? "",
            taskCount: p["task_count"]?.intValue ?? 1,
            taskIndex: p["task_index"]?.intValue ?? 0,
            subagentID: p["subagent_id"]?.stringValue,
            parentID: p["parent_id"]?.stringValue,
            depth: p["depth"]?.intValue,
            inputTokens: p["input_tokens"]?.intValue,
            outputTokens: p["output_tokens"]?.intValue,
            apiCalls: p["api_calls"]?.intValue,
            costUSD: p["cost_usd"]?.doubleValue,
            filesRead: p["files_read"]?.arrayValue?.map { $0.stringValue ?? "" },
            filesWritten: p["files_written"]?.arrayValue?.map { $0.stringValue ?? "" }
        )
    }
}

struct SubagentToolPayload {
    let goal: String
    let taskCount: Int
    let taskIndex: Int
    let subagentID: String?
    let toolName: String?
    let toolPreview: String?
    let text: String?

    static func from(_ p: [String: AnyCodable]) -> SubagentToolPayload {
        SubagentToolPayload(
            goal: p["goal"]?.stringValue ?? "",
            taskCount: p["task_count"]?.intValue ?? 1,
            taskIndex: p["task_index"]?.intValue ?? 0,
            subagentID: p["subagent_id"]?.stringValue,
            toolName: p["tool_name"]?.stringValue,
            toolPreview: p["tool_preview"]?.stringValue,
            text: p["text"]?.stringValue
        )
    }
}
