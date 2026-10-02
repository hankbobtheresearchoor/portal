import Foundation
import Testing
@testable import Portal

/// Coverage for the code behind a cron node — `source_files` on the wire, the
/// tolerant snapshot decoding, the explorer's grouping, and the prompt
/// preservation that keeps a fetched full prompt alive across `list` refreshes.
/// Pure model logic: no gateway, no view.
@Suite("Cron source files")
internal struct CronSourceFilesTests {

    private func file(
        _ path: String,
        role: String = "declared",
        root: String? = "hermes",
        rel: String? = nil,
        exists: Bool = true
    ) -> CronSourceFile {
        CronSourceFile(
            path: path,
            declared: (path as NSString).lastPathComponent,
            role: role,
            root: root,
            relativePath: rel ?? (root == nil ? nil : "scripts/" + (path as NSString).lastPathComponent),
            exists: exists
        )
    }

    private func node(_ id: String, kind: String = "cron", sourceFiles: [CronSourceFile] = []) -> CronGraphNode {
        CronGraphNode(
            id: id, kind: kind, type: kind, label: id, description: "",
            schedule: nil, enabled: true, usesLLM: false, lastStatus: nil, deliver: nil,
            sourceFiles: sourceFiles
        )
    }

    private func decode(_ json: String) throws -> CronGraph {
        let value = try JSONDecoder().decode(AnyCodable.self, from: Data(json.utf8))
        return try CronGraph.decodeGatewayValue(value)
    }

    // MARK: - Wire decoding

    @Test("source_files decode onto the cron node with root, relative path, role and existence")
    internal func decodesSourceFilesFromGateway() throws {
        let json = """
        {"nodes":[{"id":"abc","kind":"cron","label":"ingest","source_files":[
            {"path":"/Users/x/.hermes/scripts/w.sh","declared":"w.sh","role":"script","root":"hermes","rel":"scripts/w.sh","exists":true},
            {"path":"/tmp/gone.py","declared":"/tmp/gone.py","role":"declared","root":null,"rel":null,"exists":false}
        ]}],"edges":[]}
        """
        let graph = try decode(json)
        let files = try #require(graph.nodes.first?.sourceFiles)

        #expect(files.count == 2)
        #expect(files[0].role == "script")
        #expect(files[0].root == "hermes")
        #expect(files[0].relativePath == "scripts/w.sh")
        #expect(files[0].isOpenable)
        #expect(files[0].exists)
        #expect(files[1].root == nil)
        #expect(!files[1].isOpenable)
        #expect(!files[1].exists)
    }

    @Test("a node without source_files, and an entry without a path, decode to nothing")
    internal func tolerantOfAbsentOrMalformedEntries() throws {
        let json = #"{"nodes":[{"id":"a","kind":"cron"},{"id":"b","kind":"cron","source_files":[{"role":"script"}]}],"edges":[]}"#
        let graph = try decode(json)
        #expect(graph.nodes[0].sourceFiles.isEmpty)
        #expect(graph.nodes[1].sourceFiles.isEmpty)
    }

    @Test("an entry's optional fields default to the path and a declared role")
    internal func entryDefaults() throws {
        let value = try JSONDecoder().decode(AnyCodable.self, from: Data(#"{"path":"/a/b.py"}"#.utf8))
        let entry = try #require(CronSourceFile.decodeGatewayValue(value))
        #expect(entry.declared == "/a/b.py")
        #expect(entry.role == "declared")
        #expect(entry.root == nil)
        #expect(!entry.exists)
    }

    // MARK: - Snapshot persistence

    @Test("a revision snapshot written before sourceFiles existed still decodes, with an empty list")
    internal func legacySnapshotDecodes() throws {
        let legacy = """
        {"id":"abc","kind":"cron","type":"cron","label":"job","description":"",
         "schedule":"every 60m","enabled":true,"usesLLM":true,"lastStatus":null,"deliver":"local"}
        """
        let decoded = try JSONDecoder().decode(CronGraphNode.self, from: Data(legacy.utf8))
        #expect(decoded.id == "abc")
        #expect(decoded.sourceFiles.isEmpty)
        #expect(decoded.health == nil)
    }

    @Test("sourceFiles round-trip through the snapshot encoding")
    internal func roundTrip() throws {
        let original = node("abc", sourceFiles: [file("/x/scripts/a.py", role: "script")])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CronGraphNode.self, from: data)
        #expect(decoded == original)
        #expect(decoded.sourceFiles.first?.role == "script")
    }

    // MARK: - Commitment parity

    @Test("declaring code does not move the graph commitment or its layout form")
    internal func sourceFilesStayOutOfTheDigest() {
        let bare = CronGraph(nodes: [node("abc")], edges: [])
        let withCode = CronGraph(nodes: [node("abc", sourceFiles: [file("/x/a.py")])], edges: [])

        // Mirrors the gateway: cron/changesets.py hashes the same node row and
        // neither side includes source files, so both must agree.
        #expect(CronGraphDigest.over(bare) == CronGraphDigest.over(withCode))
        #expect(CronGraphDigest.layoutForm(bare) == CronGraphDigest.layoutForm(withCode))
    }

    @Test("the stored configuration keeps the files while stripping runtime fields")
    internal func configurationSnapshotKeepsFiles() {
        let graph = CronGraph(nodes: [node("abc", sourceFiles: [file("/x/a.py")])], edges: [])
        let stored = CronGraphDigest.configuration(of: graph)
        #expect(stored.nodes.first?.sourceFiles.count == 1)
        #expect(stored.nodes.first?.lastStatus == nil)
    }

    // MARK: - Explorer grouping

    @Test("files group by root alphabetically, rootless last, mechanical roles first within a group")
    internal func groupingOrder() {
        let files = [
            file("/repo/indexing/x.py", role: "declared", root: "repo", rel: "indexing/x.py"),
            file("/tmp/elsewhere.py", role: "declared", root: nil),
            file("/h/scripts/helper.py", role: "declared", root: "hermes", rel: "scripts/helper.py"),
            file("/h/scripts/probe.sh", role: "monitor", root: "hermes", rel: "scripts/probe.sh"),
            file("/h/scripts/w.sh", role: "script", root: "hermes", rel: "scripts/w.sh"),
        ]
        let groups = CronSourceFileGroup.grouping(files)

        #expect(groups.map(\.root) == ["hermes", "repo", nil])
        #expect(groups[0].files.map(\.role) == ["script", "monitor", "declared"])
        #expect(groups[2].files.map(\.path) == ["/tmp/elsewhere.py"])
        // Stable identities so a ForEach can key on them.
        #expect(Set(groups.map(\.id)).count == 3)
    }

    @Test("role rank puts what the scheduler runs ahead of what the agent declared")
    internal func roleRank() {
        #expect(file("/a", role: "script").roleRank < file("/a", role: "monitor").roleRank)
        #expect(file("/a", role: "monitor").roleRank < file("/a", role: "declared").roleRank)
        #expect(file("/a", role: "browsed").roleRank == file("/a", role: "declared").roleRank)
    }

    @Test("display helpers read identity, leaf and folder off the path")
    internal func displayHelpers() {
        let script = file("/h/scripts/sub/w.sh", role: "script", root: "hermes", rel: "scripts/sub/w.sh")
        #expect(script.id == "/h/scripts/sub/w.sh")
        #expect(script.fileName == "w.sh")
        #expect(script.relativeDirectory == "scripts/sub")

        let topLevel = file("/h/README.md", root: "hermes", rel: "README.md")
        #expect(topLevel.relativeDirectory?.isEmpty == true)

        let outside = file("/tmp/x.py", root: nil)
        #expect(outside.relativeDirectory == nil)
        #expect(!outside.isOpenable)
    }

    @Test("a browsed neighbour takes the root's absolute path when known, else a root:rel identity")
    internal func browsedEntryIdentity() {
        let entry = FileEntry(root: "repo", path: "indexing/helper.py", name: "helper.py",
                              isDirectory: false, size: 10, hasChildren: false)
        let known = CronSourceFilesViewModel.sourceFile(for: entry, rootPath: "/Users/x/hermes-agent")
        #expect(known.path == "/Users/x/hermes-agent/indexing/helper.py")
        #expect(known.role == "browsed")
        #expect(known.isOpenable)

        let unknown = CronSourceFilesViewModel.sourceFile(for: entry, rootPath: nil)
        #expect(unknown.path == "repo:indexing/helper.py")
    }

    // MARK: - Job lookup

    @Test("sourceFiles(for:) reads the cron node's files and ignores other kinds")
    @MainActor
    internal func viewModelLookup() {
        let vm = CronGraphViewModel()
        vm.setGraphForTesting(CronGraph(
            nodes: [node("abc", sourceFiles: [file("/x/a.py")]), node("wiki:x", kind: "artifact")],
            edges: []
        ))
        #expect(vm.graph.nodes.first { $0.id == "abc" }?.sourceFiles.count == 1)
        #expect(vm.graph.nodes.first { $0.id == "wiki:x" }?.sourceFiles.isEmpty == true)
    }
}

/// The `list` refresh must not undo what `describe` fetched: the badge that
/// says "may be truncated" was reappearing on every poll because the array was
/// replaced wholesale with preview-only records.
@Suite("Cron prompt preservation across refresh")
internal struct CronPromptPreservationTests {

    private func job(_ id: String, preview: String?, prompt: String?) -> CronJob {
        CronJob(
            id: id, name: id, schedule: "every 60m", nextRunAt: nil, lastRunAt: nil,
            lastStatus: nil, enabled: true, state: "scheduled", deliver: "local",
            promptPreview: preview, prompt: prompt, lastError: nil
        )
    }

    private let full = String(repeating: "x", count: 140)
    private var preview: String { String(full.prefix(100)) + "..." }

    @Test("previewMatches accepts the gateway's own preview and rejects an unrelated one")
    internal func previewMatching() {
        #expect(CronJob.previewMatches(full: full, preview: preview))
        #expect(CronJob.previewMatches(full: full, preview: String(full.prefix(100)) + "…"))
        #expect(CronJob.previewMatches(full: "short", preview: "short"))
        #expect(CronJob.previewMatches(full: full, preview: nil))
        #expect(!CronJob.previewMatches(full: "edited elsewhere", preview: preview))
        // A preview without an ellipsis is the whole prompt; anything longer disagrees.
        #expect(!CronJob.previewMatches(full: "short and then some", preview: "short"))
        #expect(!CronJob.previewMatches(full: full, preview: "..."))
    }

    @Test("the truncation badge follows the preview until a distinct full prompt arrives")
    internal func truncationBadgeState() {
        #expect(!job("none", preview: nil, prompt: nil).isPromptTruncated)
        #expect(job("ascii", preview: preview, prompt: nil).isPromptTruncated)
        #expect(job("unicode", preview: String(full.prefix(100)) + "…", prompt: nil).isPromptTruncated)
        #expect(job("same", preview: preview, prompt: preview).isPromptTruncated)
        #expect(!job("full", preview: preview, prompt: full).isPromptTruncated)
        #expect(!job("short", preview: "complete", prompt: nil).isPromptTruncated)
    }

    @Test("cron job equality and hashing use stable gateway identity")
    internal func identityEqualityAndHashing() {
        let original = job("same-id", preview: "before", prompt: nil)
        let refreshed = job("same-id", preview: "after", prompt: "after")
        let other = job("other-id", preview: "before", prompt: nil)

        #expect(original == refreshed)
        #expect(original != other)
        #expect(Set([original, refreshed, other]).count == 2)
    }

    @Test("a fetched full prompt survives a list refresh whose preview still matches it")
    internal func keepsMatchingPrompt() {
        let previous = [job("a", preview: preview, prompt: full)]
        let fresh = [job("a", preview: preview, prompt: nil)]

        let merged = CronListViewModel.preservingFetchedPrompts(in: fresh, from: previous)
        #expect(merged.first?.prompt == full)
        #expect(merged.first?.isPromptTruncated == false)
    }

    @Test("a prompt edited elsewhere is not masked by the stale full text")
    internal func dropsStalePrompt() {
        let previous = [job("a", preview: preview, prompt: full)]
        let fresh = [job("a", preview: "rewritten on the host and now long enough to be clipped by the gateway preview cap at...", prompt: nil)]

        let merged = CronListViewModel.preservingFetchedPrompts(in: fresh, from: previous)
        #expect(merged.first?.prompt == nil)
        #expect(merged.first?.isPromptTruncated == true)
    }

    @Test("a fresh record that already carries a full prompt, or a new job, is left alone")
    internal func leavesFreshPromptsAndNewJobs() {
        let previous = [job("a", preview: preview, prompt: full)]
        let fresh = [job("a", preview: preview, prompt: "authoritative"), job("b", preview: "new job", prompt: nil)]

        let merged = CronListViewModel.preservingFetchedPrompts(in: fresh, from: previous)
        #expect(merged[0].prompt == "authoritative")
        #expect(merged[1].prompt == nil)
        #expect(merged.count == 2)
    }
}

// MARK: - Explorer view model

/// A gateway stand-in for the explorer: canned files and listings keyed
/// `root:path`, an optional failure, and a record of what was asked for.
@MainActor
private final class StubSourceReader: CronSourceFileReading {
    var contents: [String: FileContent] = [:]
    var listings: [String: FileListing] = [:]
    var failure: Error?
    var reads: [String] = []
    var lists: [String] = []

    func readFile(root: String, path: String) async throws -> FileContent {
        reads.append("\(root):\(path)")
        if let failure { throw failure }
        guard let content = contents["\(root):\(path)"] else { throw GatewayError.invalidResponse("no such file") }
        return content
    }

    func listFiles(root: String, path: String) async throws -> FileListing {
        lists.append("\(root):\(path)")
        if let failure { throw failure }
        guard let listing = listings["\(root):\(path)"] else { throw GatewayError.invalidResponse("no such folder") }
        return listing
    }
}

@MainActor
@Suite("Cron source-file explorer view model")
internal struct CronSourceFilesViewModelTests {

    private let script = CronSourceFile(
        path: "/h/scripts/w.sh", declared: "w.sh", role: "script",
        root: "hermes", relativePath: "scripts/w.sh", exists: true
    )
    private let outside = CronSourceFile(
        path: "/opt/gone.py", declared: "/opt/gone.py", role: "declared",
        root: nil, relativePath: nil, exists: false
    )

    private func content(_ text: String) -> FileContent {
        FileContent(root: "hermes", path: "scripts/w.sh", content: text, size: text.utf8.count, readOnly: true, language: "sh")
    }

    private func entry(_ name: String, dir: String = "scripts", isDirectory: Bool = false) -> FileEntry {
        FileEntry(root: "hermes", path: dir.isEmpty ? name : "\(dir)/\(name)", name: name,
                  isDirectory: isDirectory, size: 3, hasChildren: false)
    }

    private func make(_ reader: StubSourceReader) -> CronSourceFilesViewModel {
        let vm = CronSourceFilesViewModel()
        vm.setClient(reader)
        return vm
    }

    @Test("opening an openable file reads it under its root and presents the reader")
    internal func opensFile() async {
        let reader = StubSourceReader()
        reader.contents["hermes:scripts/w.sh"] = content("echo hi")
        let vm = make(reader)

        await vm.open(script)

        #expect(reader.reads == ["hermes:scripts/w.sh"])
        #expect(vm.isPresentingReader)
        #expect(vm.openSource == script)
        #expect(vm.openFile?.content == "echo hi")
        #expect(!vm.isLoadingFile)
        #expect(vm.errorMessage == nil)
    }

    @Test("a refused read keeps the pane open on the error, with the gateway's own message")
    internal func surfacesReadFailure() async {
        let reader = StubSourceReader()
        reader.failure = GatewayError.rpcError(JSONRPCError(code: 4020, message: "path escapes the root"))
        let vm = make(reader)

        await vm.open(script)

        #expect(vm.isPresentingReader)
        #expect(vm.openFile == nil)
        #expect(vm.errorMessage == "path escapes the root")
        #expect(!vm.isLoadingFile)
    }

    @Test("a file outside every root is reported, not requested")
    internal func refusesUnopenable() async {
        let reader = StubSourceReader()
        let vm = make(reader)

        await vm.open(outside)

        #expect(reader.reads.isEmpty)
        #expect(!vm.isPresentingReader)
        #expect(vm.errorMessage?.contains("gone.py") == true)
    }

    @Test("without a client an open is a no-op rather than a crash")
    internal func openWithoutClient() async {
        let vm = CronSourceFilesViewModel()
        await vm.open(script)
        #expect(!vm.isPresentingReader)
        #expect(vm.errorMessage == nil)
    }

    @Test("close clears the reader and its error")
    internal func closeClears() async {
        let reader = StubSourceReader()
        reader.contents["hermes:scripts/w.sh"] = content("x")
        let vm = make(reader)
        await vm.open(script)

        vm.close()

        #expect(!vm.isPresentingReader)
        #expect(vm.openFile == nil)
        #expect(vm.openSource == nil)
        #expect(vm.errorMessage == nil)
    }

    @Test("disclosing a folder lists it once, collapsing hides without refetching, re-opening reuses the cache")
    internal func folderToggle() async {
        let reader = StubSourceReader()
        reader.listings["hermes:scripts"] = FileListing(
            root: "hermes", rootPath: "/h", path: "scripts",
            entries: [entry("helper.py"), entry("w.sh"), entry("lib", isDirectory: true)]
        )
        let vm = make(reader)
        #expect(vm.children(root: "hermes", path: "scripts") == nil)

        await vm.toggleFolder(root: "hermes", path: "scripts")
        #expect(vm.isExpanded(root: "hermes", path: "scripts"))
        #expect(vm.children(root: "hermes", path: "scripts")?.map(\.name) == ["helper.py", "w.sh", "lib"])
        #expect(!vm.isLoading(root: "hermes", path: "scripts"))

        await vm.toggleFolder(root: "hermes", path: "scripts")
        #expect(!vm.isExpanded(root: "hermes", path: "scripts"))

        await vm.toggleFolder(root: "hermes", path: "scripts")
        #expect(vm.isExpanded(root: "hermes", path: "scripts"))
        #expect(reader.lists == ["hermes:scripts"])
    }

    @Test("a failed listing drops the optimistic expansion and reports why")
    internal func folderFailure() async {
        let reader = StubSourceReader()
        reader.failure = GatewayError.rpcError(JSONRPCError(code: 4404, message: "unknown root 'x'"))
        let vm = make(reader)

        await vm.toggleFolder(root: "x", path: "")

        #expect(!vm.isExpanded(root: "x", path: ""))
        #expect(vm.children(root: "x", path: "") == nil)
        #expect(vm.errorMessage == "unknown root 'x'")
    }

    @Test("a neighbour opened from a listing gets the root's absolute path and the browsed role")
    internal func opensNeighbour() async {
        let reader = StubSourceReader()
        reader.listings["hermes:scripts"] = FileListing(root: "hermes", rootPath: "/h", path: "scripts", entries: [entry("helper.py")])
        reader.contents["hermes:scripts/helper.py"] = FileContent(
            root: "hermes", path: "scripts/helper.py", content: "print(1)", size: 8, readOnly: true, language: "py"
        )
        let vm = make(reader)
        await vm.toggleFolder(root: "hermes", path: "scripts")

        await vm.open(entry: entry("helper.py"))

        #expect(vm.openSource?.path == "/h/scripts/helper.py")
        #expect(vm.openSource?.role == "browsed")
        #expect(vm.openFile?.content == "print(1)")

        // Folders are for disclosing, not reading.
        await vm.open(entry: entry("lib", isDirectory: true))
        #expect(vm.openSource?.path == "/h/scripts/helper.py")
        #expect(reader.reads.count == 1)
    }

    @Test("a non-RPC failure falls back to the error's description")
    internal func genericFailureMessage() async {
        let reader = StubSourceReader()
        reader.failure = GatewayError.invalidResponse("files.read missing result")
        let vm = make(reader)

        await vm.open(script)

        #expect(vm.errorMessage?.isEmpty == false)
        #expect(vm.openFile == nil)
    }
}
