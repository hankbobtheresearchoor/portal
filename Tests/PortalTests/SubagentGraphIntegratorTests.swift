import Testing
import Foundation
@testable import Portal

@Suite("Subagent Graph Integrator")
@MainActor
struct SubagentGraphIntegratorTests {

    private func spawnPayload(
        id: String,
        parentID: String? = nil,
        goal: String = "test goal",
        model: String? = "claude-sonnet-5"
    ) -> SubagentPayload {
        SubagentPayload(
            goal: goal, taskCount: 1, taskIndex: 0,
            subagentID: id, parentID: parentID, depth: 0, model: model
        )
    }

    @Test("spawn creates an agent node parented to the delegating tool")
    func spawnCreatesAgentNode() {
        let integrator = SubagentGraphIntegrator()
        integrator.upsertAgent(payload: spawnPayload(id: "s1"), running: true, delegatingToolID: "tool_9")

        #expect(integrator.agentNodes.count == 1)
        let node = integrator.agentNodes[0]
        #expect(node.id == "agent-s1")
        #expect(node.isAgent)
        #expect(node.parentIDs == ["tool_9"])
        #expect(node.context == "test goal")
        #expect(node.modelName == "claude-sonnet-5")
        #expect(node.status == .running)
    }

    @Test("subagent tools chain sequentially under the agent node")
    func toolsChainUnderAgent() {
        let integrator = SubagentGraphIntegrator()
        integrator.upsertAgent(payload: spawnPayload(id: "s1"), running: true, delegatingToolID: nil)
        integrator.recordTool(payload: SubagentToolPayload(
            goal: "", taskCount: 1, taskIndex: 0,
            subagentID: "s1", toolName: "grep", toolPreview: "pattern", text: nil
        ))
        integrator.recordTool(payload: SubagentToolPayload(
            goal: "", taskCount: 1, taskIndex: 0,
            subagentID: "s1", toolName: "read_file", toolPreview: "a.swift", text: nil
        ))

        #expect(integrator.agentNodes.count == 3)
        let t1 = integrator.agentNodes[1]
        let t2 = integrator.agentNodes[2]
        #expect(t1.parentIDs == ["agent-s1"])
        #expect(t2.parentIDs == [t1.id])
        #expect(t1.ownerAgentID == "s1")
        #expect(t2.name == "read_file")
    }

    @Test("recursive spawn parents onto the parent agent node")
    func recursiveSpawnParentsOntoAgent() {
        let integrator = SubagentGraphIntegrator()
        integrator.upsertAgent(payload: spawnPayload(id: "s1"), running: true, delegatingToolID: "tool_1")
        integrator.upsertAgent(payload: spawnPayload(id: "s2", parentID: "s1"), running: true, delegatingToolID: "tool_1")

        let child = integrator.agentNodes.first { $0.id == "agent-s2" }
        #expect(child?.parentIDs == ["agent-s1"])
    }

    @Test("complete marks node done and records cost/tokens")
    func completeRollsUpUsage() {
        let integrator = SubagentGraphIntegrator()
        integrator.upsertAgent(payload: spawnPayload(id: "s1"), running: true, delegatingToolID: nil)
        integrator.completeAgent(payload: SubagentCompletePayload(
            goal: "", taskCount: 1, taskIndex: 0,
            subagentID: "s1", parentID: nil, depth: 0,
            inputTokens: 1200, outputTokens: 300, apiCalls: 4, costUSD: 0.05,
            filesRead: nil, filesWritten: nil
        ))

        let node = integrator.agentNodes[0]
        #expect(node.isComplete)
        #expect(node.costUSD == 0.05)
        #expect(node.totalTokens == 1500)
    }

    @Test("thinking with nil subagentID falls back to the running agent")
    func thinkingFallsBackToRunningAgent() async throws {
        let integrator = SubagentGraphIntegrator()
        integrator.upsertAgent(payload: spawnPayload(id: "s1"), running: true, delegatingToolID: nil)
        integrator.appendThinking("pondering...", subagentID: nil)

        // Thinking publishes are debounced (250ms) to avoid per-token graph
        // re-renders. Poll rather than a single fixed sleep — under parallel
        // test load a one-shot 400ms wait races the debounce timer.
        for _ in 0..<40 where integrator.agentNodes[0].agentThinking == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(integrator.agentNodes[0].agentThinking == "pondering...")
    }

    /// A second spawn for the SAME subagent id updates the existing run in
    /// place rather than creating a duplicate: a deferred start_request arrives
    /// after spawn_requested, so `running` backfills `startedAt`, and a goal
    /// that wasn't on the initial request is filled into the empty context.
    /// Guards the whole `if var run = runs[sid]` update branch.
    @Test("re-spawn with same id backfills startedAt and empty context")
    internal func reSpawnUpdatesExistingRun() throws {
        let integrator = SubagentGraphIntegrator()

        // First event: spawn_requested — not running yet, no goal provided.
        let initial = SubagentPayload(
            goal: "", taskCount: 1, taskIndex: 0,
            subagentID: "s1", parentID: nil, depth: 0, model: "claude-sonnet-5"
        )
        integrator.upsertAgent(payload: initial, running: false, delegatingToolID: "tool_1")

        #expect(integrator.agentNodes.count == 1)
        var node = try #require(integrator.agentNodes.first { $0.id == "agent-s1" })
        #expect(node.startedAt == nil)
        #expect(node.context == nil || node.context?.isEmpty == true)

        // Second event: start arrives — running flips true and the goal is now
        // known. Both should update the EXISTING node, not append a new one.
        integrator.upsertAgent(payload: spawnPayload(id: "s1", goal: "summarize the logs"),
                               running: true, delegatingToolID: "tool_1")

        #expect(integrator.agentNodes.count == 1)
        node = try #require(integrator.agentNodes.first { $0.id == "agent-s1" })
        #expect(node.startedAt != nil)
        #expect(node.context == "summarize the logs")
    }

    @Test("reset clears all runs")
    func resetClears() {
        let integrator = SubagentGraphIntegrator()
        integrator.upsertAgent(payload: spawnPayload(id: "s1"), running: true, delegatingToolID: nil)
        integrator.reset()
        #expect(integrator.agentNodes.isEmpty)
    }

    @Test("layout assigns lanes: main loop first, one lane per agent")
    internal func layoutAssignsLanes() throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        // Completed, short, non-overlapping durations so each lane's bars are
        // sequential (share a sub-row) — this test validates lane ASSIGNMENT,
        // not the concurrent-bar packing (covered separately).
        let nodes = [
            ThoughtGraphNode(id: "t1", name: "search_files", isComplete: true,
                             durationSeconds: 0.3, startedAt: t0, completedAt: t0.addingTimeInterval(0.3)),
            ThoughtGraphNode(id: "t2", name: "delegate_task", isComplete: true,
                             durationSeconds: 0.3, startedAt: t0.addingTimeInterval(1), completedAt: t0.addingTimeInterval(1.3)),
            ThoughtGraphNode(id: "agent-s1", name: "agent", isComplete: true, durationSeconds: 0.3,
                             parentIDs: ["t2"], startedAt: t0.addingTimeInterval(2),
                             completedAt: t0.addingTimeInterval(2.3), agentID: "s1"),
            ThoughtGraphNode(id: "agent-s1-t1", name: "grep", isComplete: true, durationSeconds: 0.3,
                             parentIDs: ["agent-s1"], startedAt: t0.addingTimeInterval(3),
                             completedAt: t0.addingTimeInterval(3.3), ownerAgentID: "s1"),
            ThoughtGraphNode(id: "t3", name: "read_file", isComplete: true,
                             durationSeconds: 0.3, startedAt: t0.addingTimeInterval(4), completedAt: t0.addingTimeInterval(4.3)),
        ]

        let engine = ThoughtGraphLayoutEngine()
        engine.layout(nodes: nodes)

        #expect(engine.lanes.count == 2)
        #expect(engine.lanes[0].id == "main")
        #expect(engine.lanes[1].id == "s1")
        #expect(engine.lanes[1].isAgent)

        // Time-plot: lanes stack on the y-axis, so an actor's nodes share a y;
        // time runs on x, so nodes with different starts get different x.
        func x(_ id: String) throws -> Double { try #require(engine.layout(for: id)).x }
        func y(_ id: String) throws -> Double { try #require(engine.layout(for: id)).y }
        #expect(try y("t1") == y("t2"))                 // both main lane
        #expect(try y("t2") == y("t3"))
        #expect(try y("agent-s1") == y("agent-s1-t1"))  // both the subagent lane
        #expect(try y("t1") != y("agent-s1"))           // different lanes
        #expect(try x("t1") != x("t2"))                 // started 1s apart
    }

    @Test("layout positions nodes by start time and links spawns")
    internal func layoutOrdersChronologically() throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        let nodes = [
            ThoughtGraphNode(id: "t2", name: "delegate_task", startedAt: t0.addingTimeInterval(1)),
            // Deliberately out of array order — startedAt must win.
            ThoughtGraphNode(id: "t1", name: "search_files", isComplete: true, startedAt: t0),
            ThoughtGraphNode(id: "agent-s1", name: "agent", parentIDs: ["t2"],
                             startedAt: t0.addingTimeInterval(2), agentID: "s1"),
        ]

        let engine = ThoughtGraphLayoutEngine()
        engine.layout(nodes: nodes)

        // Time flows on x now: an earlier start is further left.
        func x(_ id: String) throws -> Double { try #require(engine.layout(for: id)).x }
        #expect(try x("t1") < x("t2"))

        // Only spawn edges are drawn (t2 delegated agent-s1); within-lane
        // sequence is conveyed by left→right adjacency, not a .main edge.
        #expect(engine.edges.contains(.init(from: "t2", to: "agent-s1", kind: .spawn)))
        #expect(!engine.edges.contains { $0.kind == .main })
    }

    @Test("agent with unknown parent spawn-links to the latest main-lane node")
    func orphanAgentFallsBack() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        let nodes = [
            ThoughtGraphNode(id: "t1", name: "search_files", isComplete: true, startedAt: t0),
            ThoughtGraphNode(id: "t2", name: "read_file", isComplete: true,
                             startedAt: t0.addingTimeInterval(1)),
            ThoughtGraphNode(id: "agent-s1", name: "agent", parentIDs: ["missing"],
                             startedAt: t0.addingTimeInterval(2), agentID: "s1"),
        ]

        let engine = ThoughtGraphLayoutEngine()
        engine.layout(nodes: nodes)

        #expect(engine.edges.contains(.init(from: "t2", to: "agent-s1", kind: .spawn)))
    }

    @Test("composeTimeline merges tools, agents, and reasoning nodes")
    func composeTimelineMerges() {
        let nodes = ThoughtGraphLayoutEngine.composeTimeline(
            tools: [ToolCallRecord(id: "t1", name: "read_file", isComplete: true)],
            agentNodes: [ThoughtGraphNode(id: "agent-s1", name: "agent", agentID: "s1")],
            reasoningNodes: [ThoughtGraphNode(id: "r1", name: "reasoning", isComplete: true)]
        )
        #expect(nodes.count == 3)
        #expect(nodes.contains { $0.id == "t1" })
        #expect(nodes.contains { $0.isAgent })
        #expect(nodes.contains { $0.category == .reasoning })
    }

    @Test("delegate tool names classify as agent category")
    func delegateClassification() {
        #expect(ThoughtGraphLayoutEngine.ToolCategory.classify(name: "delegate_task") == .agent)
        #expect(ThoughtGraphLayoutEngine.ToolCategory.classify(name: "spawn_subagent") == .agent)
        #expect(ThoughtGraphLayoutEngine.ToolCategory.classify(name: "read_file") == .read)
    }
}
