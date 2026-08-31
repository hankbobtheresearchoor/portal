import Testing
import Foundation
@testable import Portal

@Suite("Activity Inbox ViewModel")
@MainActor
struct ActivityInboxViewModelTests {

    init() {
        NotificationService.isTestEnvironment = true
        ActivityStore.shared.clearAll()
    }

    @Test("items are loaded from store on init")
    func loadsFromStoreOnInit() {
        let testItem = ActivityItem(
            id: "test-init-item",
            createdAt: Date(timeIntervalSince1970: 10),
            kind: "activity",
            severity: .info,
            source: "test",
            title: "Stored",
            summary: "",
            isRead: false,
            isDismissed: false,
            actions: [],
            artifacts: [],
            externalRefs: []
        )
        ActivityStore.shared.upsert(testItem)
        let vm = ActivityInboxViewModel()
        #expect(vm.items.contains { $0.id == "test-init-item" })
        ActivityStore.shared.dismiss(id: "test-init-item")
    }

    @Test("handle approval request creates unread item")
    func handleApprovalRequest() {
        let vm = ActivityInboxViewModel()
        vm.handle(.approvalRequest(payload: ApprovalPayload(
            command: "rm -rf /",
            sessionKey: "sess1",
            toolName: "shell",
            rawArgs: nil
        )), eventSessionID: "sess1")

        #expect(vm.items.count >= 1)
        #expect(vm.items.contains { $0.kind == "approval.request" && $0.isRead == false && $0.sessionID == "sess1" })
    }

    @Test("handle error event creates error-severity item")
    func handleErrorEvent() {
        let vm = ActivityInboxViewModel()
        vm.handle(.error(message: "something went wrong"), eventSessionID: nil)

        #expect(vm.items.contains { $0.severity == .error && $0.title == "Harness Error" })
    }

    @Test("handle sudo request creates warning item")
    func handleSudoRequest() {
        let vm = ActivityInboxViewModel()
        vm.handle(.sudoRequest, eventSessionID: "s1")

        #expect(vm.items.contains { $0.kind == "sudo.request" && $0.severity == .warning })
    }

    @Test("handle secret request creates warning item")
    func handleSecretRequest() {
        let vm = ActivityInboxViewModel()
        vm.handle(.secretRequest(prompt: "Enter API key", envVar: "MY_KEY"), eventSessionID: "s2")

        #expect(vm.items.contains { $0.kind == "secret.request" })
    }

    @Test("handle clarify request creates info item")
    func handleClarifyRequest() {
        let vm = ActivityInboxViewModel()
        vm.handle(.clarifyRequest(payload: ClarifyPayload(question: "Which file?", choices: ["a", "b"], requestID: "req1")), eventSessionID: "s1")

        #expect(vm.items.contains { $0.kind == "clarify.request" && $0.summary == "Which file?" })
    }

    @Test("handle background complete creates info item")
    func handleBackgroundComplete() {
        let vm = ActivityInboxViewModel()
        vm.handle(.backgroundComplete(taskID: "task1", text: "Task finished"), eventSessionID: nil)

        #expect(vm.items.contains { $0.kind == "background.complete" })
    }

    @Test("handle subagent complete creates info item")
    func handleSubagentComplete() {
        let vm = ActivityInboxViewModel()
        vm.handle(.subagentComplete(payload: SubagentCompletePayload(
            goal: "Refactor module",
            taskCount: 1,
            taskIndex: 0,
            subagentID: "sub1",
            parentID: nil,
            depth: nil,
            inputTokens: nil,
            outputTokens: nil,
            apiCalls: nil,
            costUSD: nil,
            filesRead: nil,
            filesWritten: nil
        )), eventSessionID: "s1")

        #expect(vm.items.contains { $0.kind == "subagent.complete" })
    }

    @Test("dismiss removes item")
    internal func dismissLocallyOnRPCFail() async throws {
        let vm = ActivityInboxViewModel()
        vm.handle(.approvalRequest(payload: ApprovalPayload(
            command: "ls", sessionKey: "s1", toolName: nil, rawArgs: nil
        )), eventSessionID: "s1")
        let before = vm.items.count
        #expect(before >= 1)
        let item = try #require(vm.items.first { $0.kind == "approval.request" })
        await vm.dismiss(item)
        #expect(!vm.items.contains { $0.id == item.id })
    }

    @Test("markRead updates item")
    internal func markReadLocallyOnRPCFail() async throws {
        let vm = ActivityInboxViewModel()
        vm.handle(.approvalRequest(payload: ApprovalPayload(
            command: "ls", sessionKey: "s1", toolName: nil, rawArgs: nil
        )), eventSessionID: "s1")
        let item = try #require(vm.items.first { $0.kind == "approval.request" })
        #expect(item.isRead == false)
        await vm.markRead(item)
        #expect(vm.items.first { $0.id == item.id }?.isRead == true)
    }

    @Test("markAllRead marks all items as read")
    func markAllRead() {
        let vm = ActivityInboxViewModel()
        vm.handle(.approvalRequest(payload: ApprovalPayload(
            command: "ls", sessionKey: "s1", toolName: nil, rawArgs: nil
        )), eventSessionID: "s1")
        vm.handle(.error(message: "err"), eventSessionID: nil)
        vm.markAllRead()
        #expect(vm.unreadCount == 0)
    }

    @Test("clearAll removes all items from VM")
    func clearAll() {
        let vm = ActivityInboxViewModel()
        vm.handle(.error(message: "err"), eventSessionID: nil)
        vm.clearAll()
        #expect(vm.items.isEmpty)
        #expect(vm.selectedItem == nil)
    }

    @Test("activity.created event upserts item")
    func handleActivityCreated() {
        let vm = ActivityInboxViewModel()
        let item = ActivityItem(
            id: "act-created-test",
            createdAt: Date(timeIntervalSince1970: 10),
            kind: "activity",
            severity: .info,
            source: "gateway",
            title: "Test Activity",
            summary: "test",
            isRead: false,
            isDismissed: false,
            actions: [],
            artifacts: [],
            externalRefs: []
        )
        vm.handle(.activityCreated(item), eventSessionID: nil)
        #expect(vm.items.contains { $0.id == "act-created-test" })
    }

    @Test("activity.updated event upserts item")
    func handleActivityUpdated() {
        let vm = ActivityInboxViewModel()
        let item = ActivityItem(
            id: "act-updated-test",
            createdAt: Date(timeIntervalSince1970: 10),
            kind: "activity",
            severity: .info,
            source: "gateway",
            title: "Original",
            summary: "test",
            isRead: false,
            isDismissed: false,
            actions: [],
            artifacts: [],
            externalRefs: []
        )
        vm.handle(.activityCreated(item), eventSessionID: nil)
        #expect(vm.items.contains { $0.id == "act-updated-test" && $0.title == "Original" })

        var updated = item
        updated.title = "Updated"
        vm.handle(.activityUpdated(updated), eventSessionID: nil)
        #expect(vm.items.contains { $0.id == "act-updated-test" && $0.title == "Updated" })
    }
}
