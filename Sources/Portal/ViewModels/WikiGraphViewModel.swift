import SwiftUI
import Combine
import os.log
import simd

private let log = Logger(subsystem: "com.ethenotethan.Portal", category: "WikiGraphViewModel")

@MainActor
final class WikiGraphViewModel: ObservableObject {

    @Published var graph: WikiGraph = .empty {
        didSet { rebuildBacklinks(); rebuildNestedTypeColors() }
    }

    // MARK: - Adaptive layout state
    // One surface: the graph is the wiki home. Everything else is an
    // attachment — the reader opens on selection, the file tree is a
    // toggleable sidebar, and the changeset timeline is a drawer.

    /// Reader visibility: true presents the reader for `selectedPath` over the
    /// always-alive graph — a right-docked panel on macOS, a sheet on iOS. One
    /// reader, driven by the shared selection plane (no per-card history).
    @Published var showPageDetail = false
    /// macOS: the docked reader fills over the whole graph. A pure toggle —
    /// Peek (docked beside the graph) ⇄ fullscreen (reader owns the surface).
    /// iOS presents a sheet, so this stays false there.
    @Published internal var readerFullscreen = false
    /// macOS: width of the right-docked reader panel, set by dragging its
    /// divider. Clamped by `setReaderWidth` against the live surface on drag.
    @Published internal var readerWidth: CGFloat = 460
    /// macOS Compare: additional pages pinned beside the active reader. The
    /// grid renders these plus the current `selectedPath`; empty = plain Peek.
    /// Read-only snapshots keyed by path — no per-tile history, unlike the
    /// retired floating cards.
    @Published internal private(set) var pinnedPaths: [String] = []
    /// Folder-tree sidebar (macOS) / browse sheet (iOS) visibility.
    @Published var showFileTree = false
    /// Changeset-timeline drawer (macOS) / sheet (iOS) visibility.
    /// Hermes-only; the hosting view hides the affordance for sources that
    /// don't conform to WikiChangesetSource.
    @Published var showTimeline = false
    /// Full-surface events page: while true the adaptive host swaps the graph
    /// surface for the events page (a page WITHIN the wiki, not an overlay).
    /// The toggle affordance gates on WikiEventLogSource conformance — both
    /// backends have an ingestion log — on the same plane as the graph.
    @Published var showEventsPage = false
    /// An event the events page should land on, by source key.
    ///
    /// Set by a changeset's provenance chip: "this change came from that event"
    /// is only half a link if you can't follow it. The events page consumes and
    /// clears it, widening its window when the event predates the current one —
    /// arriving at a feed that doesn't contain what you clicked would read as
    /// the event not existing.
    @Published internal var focusedEventKey: String?
    @Published var selectedNodeIndex: Int?
    @Published var hoveredNodeIndex: Int?

    /// What the wiki says its ingestion sources ARE, built from its
    /// `type: event-type` pages. `.empty` until those pages are read (and
    /// legitimately forever, for a wiki that declares none) — every lookup
    /// still answers, deriving label and color from the wire kind, so no
    /// surface has to branch on whether the taxonomy has loaded.
    /// Written only by `loadEventTypes` (see WikiGraphViewModel+EventTypes).
    @Published internal var eventTypes: WikiEventTypeRegistry = .empty

    /// True while the 2D layout is being pre-settled off the main thread.
    /// The canvas withholds drawing until this clears, so the graph appears
    /// already relaxed and framed instead of animating apart on screen.
    @Published private(set) var isSettling = false

    // MARK: - Shared page selection plane
    // One "current page" across every surface: the reader, the graph's node
    // selection, the file-tree sidebar, and the timeline drawer all read and
    // write this.

    @Published var selectedPath: String?
    @Published private(set) var backStack: [String] = []
    @Published private(set) var forwardStack: [String] = []
    @Published private(set) var contentCache: [String: WikiPageContent] = [:]
    @Published var failedPath: String?
    private(set) var backlinkIndex: [String: [WikiPage]] = [:]

    var selectedPage: WikiPage? {
        guard let path = selectedPath else { return nil }
        return graph.pages.first { $0.path == path }
    }

    var selectedNodeTitle: String? {
        guard let idx = selectedNodeIndex, simNodes.indices.contains(idx) else { return nil }
        return simNodes[idx].label
    }
    @Published var isLoading = false
    @Published var error: String?
    @Published var searchQuery = "" {
        didSet { updateFilteredNodes() }
    }

    /// Node indices that match the current search query OR taxonomy filter. Empty = show all.
    var filteredNodeIndices: Set<Int> = []
    private var cachedQuery: String = ""
    private var cachedTaxonomyPath: String?

    /// Whether filtering is active (search or taxonomy)
    var isFiltering: Bool {
        !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty || selectedTaxonomyPath != nil
    }

    /// Taxonomy tree built from the graph's tag_path values.
    var taxonomyTree: TaxonomyNode { graph.tagPathTree }

    private func updateFilteredNodes() {
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let tp = selectedTaxonomyPath
        guard cachedQuery != q || cachedTaxonomyPath != tp else { return }
        cachedQuery = q
        cachedTaxonomyPath = tp

        if q.isEmpty && tp == nil {
            filteredNodeIndices.removeAll()
            return
        }

        let terms = q.split(separator: " ").map(String.init)

        filteredNodeIndices = Set(simNodes.indices.filter { idx in
            guard simNodes.indices.contains(idx) else { return false }
            let pageIdx = indexLookup[simNodes[idx].id]
            guard let pi = pageIdx, graph.pages.indices.contains(pi) else { return true }

            let page = graph.pages[pi]

            // Taxonomy filter: must have a tag_path matching the selected prefix
            if let tp = tp, !tp.isEmpty {
                let matches = page.tagPath.contains { $0.hasPrefix(tp) }
                if !matches { return false }
            }

            // Search filter: must match label or type
            if !terms.isEmpty {
                let node = simNodes[idx]
                let haystack = "\(node.label.lowercased()) \(node.type.lowercased())"
                return terms.allSatisfy { haystack.contains($0) }
            }

            return true
        })
    }

    /// Maps node IDs to page indices for quick lookup
    private var indexLookup: [String: Int] {
        var lookup: [String: Int] = [:]
        for (i, page) in graph.pages.enumerated() {
            lookup[page.id] = i
        }
        return lookup
    }

    struct SimNode: Identifiable, Sendable {
        let id: String
        var position: CGPoint
        var velocity: CGVector = .zero
        var position3D: SIMD3<Float> = .zero
        var velocity3D: SIMD3<Float> = .zero
        var isDragging = false
        let type: String
        let label: String
        /// The page's file path, e.g. "entities/chain/base.md". The graph colors
        /// nodes by their folder branch (see `color(forNode:)`), which is derived
        /// from this rather than `type` — real compendia keep `type` flat.
        internal let path: String
    }

    @Published var simNodes: [SimNode] = []
    @Published var simLinks: [(sourceIndex: Int, targetIndex: Int)] = []
    /// Per-edge relationship label, aligned 1:1 with `simLinks` (built in the
    /// same pass). `nil` = a plain, untyped wikilink with nothing to render.
    @Published internal private(set) var simLinkLabels: [String?] = []
    /// Node indices sorted by Y (painter's order for the 2D canvas).
    /// Recomputed ONLY when positions actually change — setup, applied
    /// physics frames, drags, settle adoption — never per canvas frame, so
    /// panning doesn't pay an O(n log n) sort at 60 Hz.
    internal private(set) var drawOrder: [Int] = []
    private(set) var degrees: [Int] = []
    private(set) var adjacency: [Set<Int>] = []

    private func recomputeDrawOrder() {
        drawOrder = simNodes.indices.sorted { simNodes[$0].position.y < simNodes[$1].position.y }
    }

    private let friction: CGFloat = 0.92
    private let springLength: CGFloat = 120
    private let springConstant: CGFloat = 0.008
    private let chargeConstant: CGFloat = 8000
    private let centerPull: CGFloat = 0.0005
    private let iterationsPerFrame = 2
    private let maxVelocity: CGFloat = 30
    private let maxRepulsionForce: CGFloat = 500

    private var alpha: CGFloat = 1.0
    private let alphaDecay: CGFloat = 0.0228
    private let alphaMin: CGFloat = 0.002
    /// Bumped per settle so a stale background relaxation can't overwrite a
    /// newer graph (see WikiGraphViewModel+Layout).
    var settleGeneration = 0
    private let dragReheat: CGFloat = 0.15
    var simAlpha: CGFloat { alpha }
    /// 2D canvas vs 3D SceneKit rendering of the same graph — a toggle in
    /// the graph controls, not a separate top-level mode.
    @Published var is3D = false

    private let springLength3D: Float = 160
    private let chargeConstant3D: Float = 20000
    private let centerPull3D: Float = 0.0008
    private let maxVelocity3D: Float = 30
    private let seedSpacing3D: Float = 50

    @Published var zoom: CGFloat = 1.0
    @Published var panOffset: CGSize = .zero
    var canvasSize: CGSize = .zero

    /// Per-graph color for each folder branch (e.g. "entities/chain"), rebuilt
    /// whenever `graph` changes. Every branch present in the graph gets its own
    /// hue so no two families collide; empty when no page lives in a folder.
    /// Rebuilt in `rebuildNestedTypeColors` (WikiGraphViewModel+TypeColors).
    internal var nestedTypeColors: [String: Color] = [:]

    /// The fill for a graph node: its folder-branch hue when the page sits in a
    /// colored folder, else the flat-type palette below.
    ///
    /// The graph colors by folder because that's where a real compendium's
    /// hierarchy lives — every `type` is flat ("org", "chain", "meta") while the
    /// nesting is entirely in the path ("entities/chain/base.md"). Keying color
    /// off `type` left ~all nodes grey; keying off the path folder groups them.
    internal func color(forNode node: SimNode) -> Color {
        if let branch = Self.branchKey(for: node.path), let color = nestedTypeColors[branch] {
            return color
        }
        return color(for: node.type)
    }

    func color(for type: String) -> Color {
        switch type {
        case "entity": return Color(hex: "7c7cff")!
        case "concept", "topic": return Color(hex: "5cb85c")!
        case "comparison": return Color(hex: "e8a838")!
        case "query": return Color(hex: "ff6b9d")!
        case "raw": return Color(hex: "888888")!
        case "meta", "index", "log": return Color(hex: "5ad4e6")!  // root pages (index.md, log.md)
        // Centaur wiki-api kinds beyond the hermes set.
        case "glossary": return Color(hex: "5ad4e6")!   // taxonomy definitions
        case "project": return Color(hex: "e8a838")!
        case "goal": return Color(hex: "ff6b9d")!
        default: return Color(hex: "aaaaaa")!
        }
    }

    func nodeRadius(for type: String) -> CGFloat {
        switch type {
        case "entity": return 7
        case "meta", "index", "log", "glossary": return 8  // hub/definition pages read larger
        default: return 5
        }
    }

    /// Per-node radii, PRECOMPUTED when degrees change. nodeRadius(at:) is
    /// on the Canvas draw path (every node, every frame at 30fps); computing
    /// sqrt-normalized sizing there — with an O(n) degrees.max() inside —
    /// cost ~16M comparisons/sec on a 747-node graph and dragged the whole
    /// canvas (the choppy-navigation regression).
    private var cachedRadii: [CGFloat] = []

    /// Node radius scales with connectivity RELATIVE to the graph's hub —
    /// sqrt-normalized so a degree-248 hub visibly dwarfs a degree-6 median
    /// node (the old log-with-cap formula rendered them near-identical),
    /// while sqrt keeps mid-degree nodes distinguishable instead of letting
    /// one hub flatten everything else. Matches the docs-site frontend's
    /// presentation (size ∝ ingress+egress).
    func recomputeRadii() {
        let maxDegree = degrees.max() ?? 0
        cachedRadii = simNodes.indices.map { index in
            let base = nodeRadius(for: simNodes[index].type)
            let degree = degrees.indices.contains(index) ? degrees[index] : 0
            guard maxDegree > 0, degree > 0 else { return base }
            return base + sqrt(CGFloat(degree) / CGFloat(maxDegree)) * 16
        }
    }

    func nodeRadius(at index: Int) -> CGFloat {
        cachedRadii.indices.contains(index) ? cachedRadii[index] : 5
    }

    @Published var selectedWikiPath: String?
    @Published var availableWikis: [String] = []

    /// Currently selected taxonomy path for hierarchical filtering.
    /// When set, only nodes whose tag_path starts with this prefix are shown.
    @Published var selectedTaxonomyPath: String? {
        didSet { updateFilteredNodes() }
    }

    internal var loadGeneration = 0
    /// Read-only view of the load counter for extensions that run async work
    /// against a load and must drop out when a newer one supersedes it.
    internal var currentLoadGeneration: Int { loadGeneration }
    private var loadedWiki: String?
    private var hasLoadedOnce = false

    /// On-disk cache of the last-known graph. On a cold open we paint the
    /// cached graph instantly (so the surface isn't blank behind a "Loading…"
    /// overlay while the serial wiki.list → wiki.scan round-trips complete),
    /// then replace it with the fresh scan. Injectable so tests use a scratch
    /// dir. Only the home gateway (GatewayClient) has a stable cacheIdentity;
    /// override sources (Centaur) skip the cache.
    private let graphCache: WikiGraphCache

    internal init(graphCache: WikiGraphCache = WikiGraphCache()) {
        self.graphCache = graphCache
    }
    /// The source the current graph was loaded from; the reader fetches page
    /// bodies through it so override wikis (Centaur) don't hit the home gateway.
    /// Strong on purpose: ContentView rebuilds its override client on every
    /// body evaluation, so a weak ref here dies between graph load and page
    /// read and the reader silently falls back to the home gateway (which
    /// 404s every Centaur page). No cycle: sources hold no view-model refs.
    private var loadedSource: (any WikiSource)?

    internal func load(client: GatewayClient, wiki: String? = nil, generation: Int? = nil) async {
        await load(source: client, wiki: wiki, generation: generation)
    }

    /// Source-generic load: Hermes (GatewayClient) and Centaur
    /// (CentaurWikiClient) both conform to WikiSource. `wiki` selection is
    /// Hermes-only (multi-wiki gateways); other sources ignore it.
    internal func load(source: any WikiSource, wiki: String? = nil, generation: Int? = nil) async {
        let generation = generation ?? beginLoad(wiki: wiki)
        // A named selection establishes its generation synchronously in the
        // button action. If this task was scheduled after a newer click, drop
        // it before it can mutate source, graph, or loading state.
        guard generation == loadGeneration else { return }
        loadedSource = source
        defer { if generation == loadGeneration { isLoading = false } }

        // Cold-open fast path: paint the last-known graph immediately so the
        // surface isn't blank behind the "Loading…" overlay while the scan
        // runs. Home gateway only — override sources have no stable identity.
        // Skipped once we already have data on screen (warm revisit / retry).
        let gateway = source as? GatewayClient
        if let gateway, graph.pages.isEmpty {
            let identity = gateway.cacheIdentity
            if let cached = await graphCache.load(identity: identity, wiki: wiki) {
                guard generation == loadGeneration else { return }
                // Don't clobber a fresh graph that landed while we read disk.
                if graph.pages.isEmpty {
                    self.graph = cached
                    // Settle in the background even before the surface exists
                    // (canvasSize == .zero → nominal fallback), so the first
                    // open paints a framed graph.
                    setupSimulation()
                }
            }
        }

        do {
            let newGraph: WikiGraph
            if let gateway {
                newGraph = try await gateway.wikiScan(wiki: wiki)
            } else {
                newGraph = try await source.fetchGraph()
            }
            // Drop stale responses if a newer load was started meanwhile.
            guard generation == loadGeneration else { return }
            self.graph = newGraph
            setupSimulation()
            // Refresh the cache with the fresh scan (home gateway only).
            if let gateway {
                graphCache.store(newGraph, identity: gateway.cacheIdentity, wiki: wiki)
            }
            // Resolve the wiki's event-type taxonomy off the graph we just
            // loaded. The loading state is dropped FIRST: definition pages are
            // extra round-trips, and holding the overlay up for them would
            // regress the cold-open latency work for a taxonomy that every
            // surface can already answer from its derived fallback.
            isLoading = false
            await loadEventTypes(source: source)
        } catch {
            guard generation == loadGeneration else { return }
            log.error("wiki.scan failed: \(error.localizedDescription)")
            self.error = error.localizedDescription
        }
    }

    func discoverWikis(client: GatewayClient) async {
        do { let wikis = try await client.wikiList(); self.availableWikis = wikis.map { $0.name } }
        catch { log.warning("wiki.list failed: \(error.localizedDescription)") }
    }

    func loadPage(client: GatewayClient, path: String, wiki: String? = nil) async -> WikiPageContent? {
        do { return try await client.wikiPage(path: path, wiki: wiki) }
        catch { log.error("wiki.page failed: \(error.localizedDescription)"); return nil }
    }

    // MARK: - Shared navigation (history + content cache)

    /// Selection and history are wiki-scoped: switching wikis invalidates
    /// paths, cache, and stacks. Any reload drops the content cache so the
    /// reader picks up fresh page bodies. Internal for tests.
    func prepareForLoad(wiki: String?) {
        contentCache.removeAll()
        if hasLoadedOnce && wiki != loadedWiki {
            clearPageSelection()
        }
        loadedWiki = wiki
        hasLoadedOnce = true
    }

    func clearPageSelection() {
        selectedPath = nil
        backStack.removeAll()
        forwardStack.removeAll()
        contentCache.removeAll()
        failedPath = nil
        showPageDetail = false
        readerFullscreen = false
        pinnedPaths.removeAll()
        selectedNodeIndex = nil
        // Wiki switch: the events surface belongs to the previous source.
        showEventsPage = false
    }

    /// Drop the graph and all navigation state on a gateway switch. The graph
    /// belongs to the previous gateway; without this the stale graph both stays
    /// on screen and blocks the connect-time prefetch / onAppear reload (both
    /// guard on an empty graph), so the new gateway's wiki would never load.
    /// Bumps the generation so any in-flight scan for the old gateway is dropped.
    internal func resetForGatewaySwitch() {
        loadGeneration += 1
        graph = .empty
        simNodes.removeAll()
        loadedSource = nil
        loadedWiki = nil
        hasLoadedOnce = false
        availableWikis = []
        selectedWikiPath = nil
        isLoading = false
        error = nil
        // The taxonomy is the previous wiki's declaration, not a global.
        eventTypes = .empty
        clearPageSelection()
    }

    /// Navigates the shared reader to a page, pushing the current page onto
    /// the back stack. Also mirrors the selection into the graph node.
    func navigate(to path: String) {
        guard path != selectedPath else { return }
        if let current = selectedPath { backStack.append(current) }
        forwardStack.removeAll()
        select(path)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        if let current = selectedPath { forwardStack.append(current) }
        select(previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        if let current = selectedPath { backStack.append(current) }
        select(next)
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func closePage() {
        selectedPath = nil
        backStack.removeAll()
        forwardStack.removeAll()
        showPageDetail = false
        readerFullscreen = false
        pinnedPaths.removeAll()
        selectedNodeIndex = nil
    }

    private func select(_ path: String) {
        selectedPath = path
        if failedPath == path { failedPath = nil }
        syncNodeSelection(toPath: path)
    }

    func cachedContent(for path: String) -> WikiPageContent? { contentCache[path] }

    func storeContent(_ content: WikiPageContent?, for path: String) {
        if let content {
            contentCache[path] = content
            if failedPath == path { failedPath = nil }
        } else if selectedPath == path {
            failedPath = path
        }
    }

    /// Single load seam for every reader surface: fetches from the same
    /// source the graph loaded from (the selected wiki) and fills the cache.
    func ensureContentLoaded(client: GatewayClient, path: String) async {
        guard contentCache[path] == nil else { return }
        let content: WikiPageContent?
        if let source = loadedSource, !(source is GatewayClient) {
            // Override wiki (Centaur): page bodies come from the same source
            // the graph did, never the home gateway.
            content = await loadPage(source: source, path: path)
        } else {
            content = await loadPage(client: client, path: path, wiki: loadedWiki)
        }
        storeContent(content, for: path)
    }

    // MARK: - Selection sync (graph node <-> page path)

    /// Mirrors a page selection into the corresponding sim node, if the page
    /// exists in the loaded graph.
    func syncNodeSelection(toPath path: String?) {
        guard let path,
              let page = graph.pages.first(where: { $0.path == path }),
              let idx = simNodes.firstIndex(where: { $0.id == page.id }) else {
            selectedNodeIndex = nil
            return
        }
        selectedNodeIndex = idx
    }

    /// Selects the graph node AND makes its page the shared current page,
    /// pushing the previous page onto the reader's back stack.
    func selectNode(_ index: Int) {
        guard simNodes.indices.contains(index) else { return }
        selectedNodeIndex = index
        if let page = graph.pages.first(where: { $0.id == simNodes[index].id }) {
            navigate(to: page.path)
        }
    }

    /// Centers the 2D viewport on a node at the current zoom.
    func centerOnNode(_ index: Int) {
        guard simNodes.indices.contains(index), canvasSize != .zero else { return }
        let pos = simNodes[index].position
        panOffset = CGSize(
            width: canvasSize.width / 2 - pos.x * zoom,
            height: canvasSize.height / 2 - pos.y * zoom
        )
    }

    /// Opens the reader for the currently selected page: a right-docked panel
    /// on macOS, the reader sheet on iOS. Every "jump into a page" path funnels
    /// through here, so the two platforms diverge in exactly one place.
    func openReaderForSelection() {
        guard selectedPath != nil else { return }
        showPageDetail = true
    }

    // MARK: - Docked reader (macOS)

    /// Peek ⇄ fullscreen. Inert when no page is open, so the toggle can't strand
    /// the surface on a fullscreen blank.
    internal func toggleReaderFullscreen() {
        guard showPageDetail, selectedPath != nil else { return }
        readerFullscreen.toggle()
    }

    /// Clamp the docked reader width to the surface as the divider drags. The
    /// panel never eats more than ~70% of the width or shrinks below its floor.
    internal func setReaderWidth(_ width: CGFloat, surfaceWidth: CGFloat) {
        let maxWidth = max(Self.minReaderWidth, surfaceWidth * 0.7)
        readerWidth = min(max(Self.minReaderWidth, width), maxWidth)
    }

    internal static let minReaderWidth: CGFloat = 320

    // MARK: - Compare (macOS)

    /// Pages shown together in the reader: the active page first, then every
    /// pinned page (de-duplicated). One entry = plain Peek; more = the grid.
    internal var comparePaths: [String] {
        guard let active = selectedPath else { return pinnedPaths }
        return [active] + pinnedPaths.filter { $0 != active }
    }

    internal var isComparing: Bool { comparePaths.count > 1 }
    internal func isPinned(_ path: String) -> Bool { pinnedPaths.contains(path) }

    /// Pin the current page so opening another keeps it on-screen for
    /// side-by-side reading. No-op if there's nothing selected or it's already
    /// pinned.
    internal func pinCurrentPage() {
        guard let path = selectedPath, !pinnedPaths.contains(path) else { return }
        pinnedPaths.append(path)
    }

    internal func unpin(_ path: String) {
        pinnedPaths.removeAll { $0 == path }
    }

    internal func clearComparison() {
        pinnedPaths.removeAll()
    }

    // MARK: - Cross-surface affordances

    /// "Show in Graph": close the reader and reveal the current page's node
    /// selected and centered on the 2D canvas.
    func showCurrentPageInGraph() {
        showPageDetail = false
        readerFullscreen = false
        if is3D { is3D = false; setupSimulation() }
        syncNodeSelection(toPath: selectedPath)
        if let idx = selectedNodeIndex { centerOnNode(idx) }
    }

    /// Flips the 2D canvas / 3D SceneKit rendering, reseeding the simulation
    /// and carrying the shared page selection into the fresh node set.
    func setRendering3D(_ enabled: Bool) {
        guard is3D != enabled else { return }
        is3D = enabled
        setupSimulation()
        if !enabled, let idx = selectedNodeIndex { centerOnNode(idx) }
    }

    /// "Reveal in sidebar": open the file tree with the page selected.
    func revealInFileTree(path: String) {
        showFileTree = true
        navigate(to: path)
    }

    private func rebuildBacklinks() {
        let byId = Dictionary(graph.pages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var index: [String: [WikiPage]] = [:]
        var seen: [String: Set<String>] = [:]
        for link in graph.links {
            guard let source = byId[link.source] else { continue }
            if seen[link.target, default: []].insert(source.id).inserted {
                index[link.target, default: []].append(source)
            }
        }
        for key in index.keys {
            index[key]?.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        backlinkIndex = index
    }

    func backlinks(for page: WikiPage?) -> [WikiPage] {
        page.flatMap { backlinkIndex[$0.id] } ?? []
    }

    func loadPage(source: any WikiSource, path: String) async -> WikiPageContent? {
        do { return try await source.fetchPage(path: path) }
        catch { log.error("wiki page fetch failed: \(error.localizedDescription)"); return nil }
    }

    func setupSimulation() {
        guard !graph.pages.isEmpty else { return }
        if is3D { setup3D() } else { setup2D() }
    }

    /// True when the current layout was settled against the nominal size
    /// (never displayed yet). The canvas clears this via
    /// `refitForFirstDisplayIfNeeded` on its first real frame.
    internal private(set) var settledAgainstNominalSize = false

    private func setup2D() {
        let center = CGPoint(x: effectiveCanvasSize.width / 2, y: effectiveCanvasSize.height / 2)
        var rng = SystemRandomNumberGenerator()
        simNodes = graph.pages.map { page in
            let angle = Double.random(in: 0...(2 * .pi), using: &rng)
            let dist = Double.random(in: 50...200, using: &rng)
            return SimNode(id: page.id, position: CGPoint(x: center.x + cos(angle) * dist, y: center.y + sin(angle) * dist), type: page.type, label: page.title, path: page.path)
        }
        finishSetup()
        settleAndReveal()
    }

    private func setup3D() {
        var rng = SystemRandomNumberGenerator()
        // Seed radius grows with cbrt(n) so node density stays roughly constant.
        let spread = Float(cbrt(Double(max(graph.pages.count, 1)))) * seedSpacing3D
        simNodes = graph.pages.map { page in
            let phi = Float.random(in: 0...(2 * .pi), using: &rng)
            let theta = Float.random(in: (-Float.pi / 2)...(Float.pi / 2), using: &rng)
            let r = Float.random(in: (spread * 0.4)...spread, using: &rng)
            let position3D = SIMD3(r * cos(theta) * cos(phi), r * cos(theta) * sin(phi), r * sin(theta))
            return SimNode(id: page.id, position: .zero, position3D: position3D, type: page.type, label: page.title, path: page.path)
        }
        finishSetup()
    }

    private func finishSetup() {
        var seenIds = Set<String>()
        simNodes = simNodes.filter { node in guard !seenIds.contains(node.id) else { return false }; seenIds.insert(node.id); return true }
        let idToIndex = Dictionary(uniqueKeysWithValues: simNodes.enumerated().map { ($1.id, $0) })
        let resolved: [(edge: (sourceIndex: Int, targetIndex: Int), label: String?)] = graph.links.compactMap { link in
            guard let si = idToIndex[link.source], let ti = idToIndex[link.target] else { return nil }
            return ((si, ti), link.displayRelation)
        }
        simLinks = resolved.map(\.edge)
        simLinkLabels = resolved.map(\.label)
        degrees = Array(repeating: 0, count: simNodes.count)
        adjacency = Array(repeating: Set<Int>(), count: simNodes.count)
        for (si, ti) in simLinks {
            if degrees.indices.contains(si) { degrees[si] += 1; adjacency[si].insert(ti) }
            if degrees.indices.contains(ti) { degrees[ti] += 1; adjacency[ti].insert(si) }
        }
        recomputeRadii()
        recomputeDrawOrder()
        alpha = 1.0
        // Invalidate any physics frame still computing against the old node set.
        physicsGeneration += 1
        physicsInFlight = false
        updateFilteredNodes()
        // Rebuilding invalidates node indices; carry the shared page
        // selection back into the fresh sim so mode switches keep context.
        syncNodeSelection(toPath: selectedPath)
    }

    func tick() { if is3D { tick3D() } else { tick2D() } }

    /// True while a 2D physics frame is being computed off the main thread.
    /// The Timer tick skips kicking off a new frame while one is in flight, so
    /// slow frames drop cleanly instead of queueing up main-thread work.
    private var physicsInFlight = false
    /// Bumped whenever the node set is rebuilt (setup / mode switch). A physics
    /// frame computed against a stale generation is discarded on completion, so
    /// a reload mid-drag can't write old positions over the fresh graph.
    private var physicsGeneration = 0

    /// Advance the 2D layout one frame — OFF the main thread. The O(n²) force
    /// integration used to run synchronously here on @MainActor, so dragging
    /// (which keeps alpha hot) saturated the same thread that processes mouse
    /// events and redraws the Canvas — the choppy-navigation regression on
    /// large graphs. Now the step runs on a background executor via the
    /// `nonisolated static stepPhysics2D`, and only the (cheap) position
    /// write-back and single @Published publish happen on main.
    private func tick2D() {
        guard !physicsInFlight, canvasSize != .zero, simNodes.count > 1 else { return }
        let anyDragging = simNodes.contains { $0.isDragging }
        guard alpha > alphaMin || anyDragging else { return }

        physicsInFlight = true
        let generation = physicsGeneration
        let snapshot = simNodes
        let links = simLinks
        let currentAlpha = alpha
        let size = canvasSize
        let iterations = iterationsPerFrame
        let params = physicsParams

        Task.detached(priority: .userInitiated) { [weak self] in
            let stepped = Self.stepPhysics2D(
                nodes: snapshot, links: links, alpha: currentAlpha,
                canvasSize: size, iterations: iterations, params: params
            )
            await self?.applyPhysicsFrame(stepped, generation: generation)
        }
    }

    /// Merge an off-main physics frame back into the published node set. Runs
    /// on the main actor. Nodes the user is actively dragging keep their LIVE
    /// position (the drag moved them since the snapshot) — the physics step
    /// already froze them, but the user may have dragged further meanwhile.
    private func applyPhysicsFrame(_ stepped: [SimNode], generation: Int) {
        // A stale frame (graph rebuilt underneath us) must not release the
        // in-flight guard — a newer frame already owns it. Bail without
        // touching the flag or the node set.
        guard generation == physicsGeneration else { return }
        physicsInFlight = false
        // Drop the frame if we flipped to 3D or the node set changed shape.
        guard !is3D, stepped.count == simNodes.count else { return }

        let anyDragging = simNodes.contains { $0.isDragging }
        var merged = simNodes
        for i in merged.indices where !merged[i].isDragging {
            merged[i].position = stepped[i].position
            merged[i].velocity = stepped[i].velocity
        }
        simNodes = merged
        recomputeDrawOrder()
        if anyDragging { alpha = max(alpha, dragReheat) } else { alpha += (alphaMin - alpha) * alphaDecay }
    }

    private func tick3D() {
        guard simNodes.count > 1 else { return }
        let anyDragging = simNodes.contains { $0.isDragging }
        guard alpha > alphaMin || anyDragging else { return }
        let charge: Float = chargeConstant3D
        let maxForce = Float(maxRepulsionForce)
        let springK = Float(springConstant)
        // Simulate into a local copy so the @Published publisher fires once per tick.
        var nodes = simNodes
        for _ in 0..<iterationsPerFrame {
            var forces = Array(repeating: SIMD3<Float>.zero, count: nodes.count)
            for i in 0..<nodes.count {
                guard !nodes[i].isDragging else { continue }
                for j in (i + 1)..<nodes.count {
                    let d = nodes[i].position3D - nodes[j].position3D
                    let distSq = simd_length_squared(d)
                    guard distSq > 0.01 else { continue }
                    let raw = charge / distSq
                    let f = min(raw, maxForce)
                    let dir = d / sqrt(distSq)
                    forces[i] += dir * f; forces[j] -= dir * f
                }
            }
            for (si, ti) in simLinks {
                let d = nodes[ti].position3D - nodes[si].position3D
                let dist = simd_length(d)
                guard dist > 0 else { continue }
                let f = (dist - springLength3D) * springK
                let dir = d / dist
                forces[si] += dir * f; forces[ti] -= dir * f
            }
            // d3 forceX/Y/Z-style centering: pull each node toward the origin so
            // disconnected components stay bounded (the old uniform -mean shift didn't).
            for i in 0..<nodes.count {
                guard !nodes[i].isDragging else { continue }
                forces[i] -= nodes[i].position3D * centerPull3D
            }
            let fAlpha = Float(CGFloat(alpha))
            for i in 0..<nodes.count {
                guard !nodes[i].isDragging else { continue }
                var v = nodes[i].velocity3D
                v = (v + forces[i] * fAlpha) * Float(friction)
                let speed = simd_length(v)
                if speed > maxVelocity3D { v *= maxVelocity3D / speed }
                nodes[i].velocity3D = v
                nodes[i].position3D += v
            }
        }
        simNodes = nodes
        if anyDragging { alpha = max(alpha, dragReheat) } else { alpha += (alphaMin - alpha) * alphaDecay }
    }

    func startDragging(index: Int, at point: CGPoint) {
        guard simNodes.indices.contains(index) else { return }
        simNodes[index].isDragging = true; simNodes[index].velocity = .zero
        alpha = max(alpha, dragReheat)
    }

    func dragNode(index: Int, to point: CGPoint) {
        guard simNodes.indices.contains(index) else { return }
        let mx = (point.x - panOffset.width) / zoom
        let my = (point.y - panOffset.height) / zoom
        simNodes[index].position = CGPoint(x: mx, y: my)
        recomputeDrawOrder()
        alpha = max(alpha, dragReheat)
    }

    func stopDragging(index: Int) { guard simNodes.indices.contains(index) else { return }; simNodes[index].isDragging = false }
    internal func updateHover(at point: CGPoint) {
        noteInteraction()
        let idx = hitTest(point: CGPoint(x: point.x, y: point.y)); if idx != hoveredNodeIndex { hoveredNodeIndex = idx }
    }
    func clearHover() { if hoveredNodeIndex != nil { hoveredNodeIndex = nil } }
    var highlightAnchor: Int? { selectedNodeIndex ?? hoveredNodeIndex }

    /// True while the user is actively moving the camera or cursor over the
    /// canvas — hovering, pinch-zooming, or scroll-panning. The 2D canvas draws
    /// a cheaper frame while this holds (no ambient per-node glow, no gradient
    /// body fills, no label pass — the expensive passes on a large graph) and
    /// restores the full-fidelity render once motion stops. The drag/pan states
    /// the canvas already tracks locally cover click-drag; this covers the input
    /// paths that leave `mouseState` idle (hover, magnify, scroll wheel), which
    /// otherwise repaint every node's radial gradients on each event.
    @Published internal private(set) var isInteracting = false
    private var interactionSettleTask: Task<Void, Never>?

    /// Mark a camera/cursor interaction as ongoing and (re)arm the settle timer.
    /// Publishes only on the leading edge, so a continuous gesture flips the flag
    /// once, not once per event. Full fidelity returns a beat after the last move.
    internal func noteInteraction() {
        if !isInteracting { isInteracting = true }
        interactionSettleTask?.cancel()
        interactionSettleTask = Task { @MainActor [weak self] in
            // Cancellation (a newer interaction re-armed the timer) is the
            // expected exit — swallow only that, and don't clear the flag.
            do { try await Task.sleep(nanoseconds: 120_000_000) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.isInteracting = false
        }
    }

    func selectedNodeNeighbors() -> [Int] {
        guard let sel = selectedNodeIndex else { return [] }
        return Array(neighbors(of: sel))
    }

    func neighbors(of anchor: Int) -> Set<Int> {
        guard adjacency.indices.contains(anchor) else { return [] }
        return adjacency[anchor]
    }

    func isNodeConnectedToSelection(_ index: Int) -> Bool {
        guard let anchor = highlightAnchor else { return true }
        if index == anchor { return true }
        return adjacency.indices.contains(anchor) && adjacency[anchor].contains(index)
    }

    func linkIsConnectedToSelection(_ source: Int, _ target: Int) -> Bool {
        guard let anchor = highlightAnchor else { return true }
        return source == anchor || target == anchor
    }

    func zoomAtPoint(factor: CGFloat, around point: CGPoint) {
        guard factor.isFinite, factor > 0 else { return }
        let oldZoom = zoom; let newZoom = max(0.3, min(5.0, oldZoom * factor))
        guard newZoom != oldZoom else { return }
        noteInteraction()
        panOffset.width += point.x * (oldZoom - newZoom)
        panOffset.height += point.y * (oldZoom - newZoom)
        zoom = newZoom
    }

    func resetView() { panOffset = .zero; zoom = 1.0 }
}

// MARK: - Page editing (wiki.update)

extension WikiGraphViewModel {

    /// True when the loaded source supports page writes — the home gateway's
    /// Hermes wiki. Centaur override sources are read-only HTTP, so their
    /// readers hide the Edit affordance.
    internal var supportsPageEditing: Bool {
        loadedSource == nil || loadedSource is GatewayClient
    }

    /// Save an edited page through `wiki.update` against the SELECTED wiki,
    /// then refresh the cache entry and rescan the graph in place (title/
    /// type/tag/link changes need a fresh scan; the reader keeps its
    /// selection and the loading overlay stays down).
    ///
    /// Throws `WikiUpdateConflict` when the page changed since `ifMatch` was
    /// read — the editor offers reload-latest / force-save from it.
    internal func savePage(
        client: GatewayClient,
        path: String,
        body: String,
        frontmatter: [String: String]?,
        ifMatch: String?,
        force: Bool = false
    ) async throws -> WikiPageContent {
        let content = try await client.wikiUpdate(
            path: path, body: body, frontmatter: frontmatter,
            ifMatch: ifMatch, force: force, wiki: loadedWiki
        )
        storeContent(content, for: path)
        await rescanGraphInPlace(client: client, wiki: loadedWiki)
        return content
    }

    /// Lightweight rescan after a page save — refreshes the graph (edits can
    /// add/remove wikilinks or change title/type/tags) without the full
    /// `load` ceremony: the content cache survives and the surface doesn't
    /// flash its loading overlay.
    private func rescanGraphInPlace(client: GatewayClient, wiki: String?) async {
        loadGeneration += 1
        let generation = loadGeneration
        do {
            let newGraph = try await client.wikiScan(wiki: wiki)
            guard generation == loadGeneration else { return }
            self.graph = newGraph
            setupSimulation()
            graphCache.store(newGraph, identity: client.cacheIdentity, wiki: wiki)
        } catch {
            // The save itself succeeded — a rescan hiccup just leaves the
            // pre-save graph on screen until the next load.
            log.warning("post-save wiki.scan failed: \(error.localizedDescription)")
        }
    }
}

extension CGPoint { var width: CGFloat { x }; var height: CGFloat { y } }
extension CGVector { static let zero = CGVector.zero }

// MARK: - Layout: pre-settle, fit-to-view, and the shared 2D physics step

extension WikiGraphViewModel {

    /// Canvas size used for seeding, settling, and framing. When the graph
    /// loads BEFORE the surface is ever shown (the connect-time warm load),
    /// canvasSize is still zero — fall back to a nominal size so the layout
    /// settles in the background and the first open paints an already-framed
    /// graph instead of the "Laying out…" spinner. The one-time re-fit on
    /// first display (`refitForFirstDisplayIfNeeded`) corrects the framing
    /// for the real size.
    private static let nominalCanvasSize = CGSize(width: 1280, height: 800)
    internal var effectiveCanvasSize: CGSize {
        canvasSize == .zero ? Self.nominalCanvasSize : canvasSize
    }

    /// One-time framing correction when the surface first appears after a
    /// background (nominal-size) settle. Mid-settle first-opens are left to
    /// the settle completion, which already frames for the live size.
    internal func refitForFirstDisplayIfNeeded() {
        guard settledAgainstNominalSize, canvasSize != .zero, !isSettling else { return }
        settledAgainstNominalSize = false
        fitToView()
    }

    /// Immutable snapshot of the 2D force constants so the physics step can
    /// run as a `nonisolated static` (usable from a background task) without
    /// touching @MainActor instance state.
    struct Physics2DParams: Sendable {
        let friction, springLength, springConstant, chargeConstant: CGFloat
        let centerPull, maxVelocity, maxRepulsionForce: CGFloat
    }

    var physicsParams: Physics2DParams {
        Physics2DParams(
            friction: friction, springLength: springLength, springConstant: springConstant,
            chargeConstant: chargeConstant, centerPull: centerPull,
            maxVelocity: maxVelocity, maxRepulsionForce: maxRepulsionForce
        )
    }

    /// Relaxes the freshly-seeded 2D layout off the main thread, then reveals
    /// it already-settled and framed — the graph "clicks into place" instead
    /// of visibly exploding apart. Cheap graphs settle in a couple frames;
    /// large ones are capped so this never blocks perceptibly. The live tick
    /// still runs afterward (alpha is low), so dragging/reheat behave as before.
    func settleAndReveal() {
        guard !is3D, simNodes.count > 1 else {
            isSettling = false
            return
        }
        settleGeneration += 1
        let generation = settleGeneration
        isSettling = true
        // Track whether this settle ran before any real canvas existed
        // (the connect-time preload) — the canvas re-frames once on its
        // first display to correct for its real size.
        settledAgainstNominalSize = canvasSize == .zero

        let seed = simNodes
        let links = simLinks
        let size = effectiveCanvasSize
        let params = physicsParams
        let iterations = iterationsPerFrame
        // More nodes need more relaxation, but cap the work so the pause is
        // imperceptible even on large graphs.
        let steps = min(300, max(60, seed.count))

        Task.detached(priority: .userInitiated) {
            var nodes = seed
            var a: CGFloat = 1.0
            for _ in 0..<steps {
                nodes = Self.stepPhysics2D(
                    nodes: nodes, links: links, alpha: a,
                    canvasSize: size, iterations: iterations, params: params
                )
                a += (0.002 - a) * 0.0228
                if a < 0.02 { break }
            }
            let settled = nodes
            await MainActor.run { [weak self] in
                guard let self, generation == self.settleGeneration else { return }
                // Only adopt if the graph hasn't been rebuilt underneath us.
                guard self.simNodes.count == settled.count else {
                    self.isSettling = false
                    return
                }
                for i in settled.indices where self.simNodes.indices.contains(i) {
                    self.simNodes[i].position = settled[i].position
                    self.simNodes[i].velocity = .zero
                }
                self.recomputeDrawOrder()
                self.alpha = self.alphaMin      // arrive at rest; no on-screen spread
                // Frame the whole graph, unless a page is already selected —
                // then keep that node centered (Show in Graph / mode switch).
                if let sel = self.selectedNodeIndex, self.simNodes.indices.contains(sel) {
                    self.centerOnNode(sel)
                } else {
                    self.fitToView()
                }
                // fitToView just framed for the LIVE effective size — if a
                // real canvas appeared mid-settle it got the right frame; if
                // not, the first display re-fits once via the flag.
                self.settledAgainstNominalSize = self.canvasSize == .zero
                self.isSettling = false
            }
        }
    }

    /// Frames the whole 2D graph in the canvas: centers its bounding box and
    /// picks a zoom that leaves a comfortable margin, so nodes read at a
    /// legible size the moment the view appears (clamped to the pinch range).
    func fitToView() {
        guard !is3D, simNodes.count > 1 else { return }
        let size = effectiveCanvasSize
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for node in simNodes {
            minX = min(minX, node.position.x); maxX = max(maxX, node.position.x)
            minY = min(minY, node.position.y); maxY = max(maxY, node.position.y)
        }
        let graphW = max(maxX - minX, 1), graphH = max(maxY - minY, 1)
        let margin: CGFloat = 80
        let fitZoom = min(
            (size.width - margin * 2) / graphW,
            (size.height - margin * 2) / graphH
        )
        let newZoom = max(0.3, min(1.6, fitZoom))
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        zoom = newZoom
        panOffset = CGSize(
            width: size.width / 2 - cx * newZoom,
            height: size.height / 2 - cy * newZoom
        )
    }

    /// One frame of 2D force integration over `iterations` sub-steps. Pure:
    /// takes node/link state in, returns advanced nodes out. Shared by the
    /// live tick and the off-main pre-settle so both produce identical layouts.
    nonisolated static func stepPhysics2D(
        nodes input: [SimNode], links: [(sourceIndex: Int, targetIndex: Int)],
        alpha: CGFloat, canvasSize: CGSize, iterations: Int, params: Physics2DParams
    ) -> [SimNode] {
        var nodes = input
        for _ in 0..<iterations {
            var forces = Array(repeating: CGVector.zero, count: nodes.count)
            for i in 0..<nodes.count {
                guard !nodes[i].isDragging else { continue }
                for j in (i + 1)..<nodes.count {
                    let dx = nodes[i].position.x - nodes[j].position.x
                    let dy = nodes[i].position.y - nodes[j].position.y
                    let distSq = dx * dx + dy * dy
                    guard distSq > 0.01 else { continue }
                    let rawForce = params.chargeConstant / distSq
                    let force = min(rawForce, params.maxRepulsionForce)
                    let dist = sqrt(distSq)
                    let fx = (dx / dist) * force; let fy = (dy / dist) * force
                    forces[i].dx += fx; forces[i].dy += fy
                    forces[j].dx -= fx; forces[j].dy -= fy
                }
            }
            for (si, ti) in links {
                let dx = nodes[ti].position.x - nodes[si].position.x
                let dy = nodes[ti].position.y - nodes[si].position.y
                let dist = sqrt(dx * dx + dy * dy)
                guard dist > 0 else { continue }
                let force = (dist - params.springLength) * params.springConstant
                let fx = (dx / dist) * force; let fy = (dy / dist) * force
                forces[si].dx += fx; forces[si].dy += fy
                forces[ti].dx -= fx; forces[ti].dy -= fy
            }
            let meanX = nodes.reduce(0) { $0 + $1.position.x } / CGFloat(nodes.count)
            let meanY = nodes.reduce(0) { $0 + $1.position.y } / CGFloat(nodes.count)
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            for i in 0..<nodes.count {
                guard !nodes[i].isDragging else { continue }
                forces[i].dx += (center.x - meanX) * params.centerPull
                forces[i].dy += (center.y - meanY) * params.centerPull
            }
            for i in 0..<nodes.count {
                guard !nodes[i].isDragging else { continue }
                var v = nodes[i].velocity
                v.dx = (v.dx + forces[i].dx * alpha) * params.friction
                v.dy = (v.dy + forces[i].dy * alpha) * params.friction
                let speed = sqrt(v.dx * v.dx + v.dy * v.dy)
                if speed > params.maxVelocity { let scale = params.maxVelocity / speed; v.dx *= scale; v.dy *= scale }
                nodes[i].velocity = v
                nodes[i].position.x += v.dx; nodes[i].position.y += v.dy
            }
        }
        return nodes
    }
}
