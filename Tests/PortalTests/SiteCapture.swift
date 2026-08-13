import Testing
import SwiftUI
@testable import Portal

/// Regenerates the product site's screenshots (`site/img/*.png`) into /tmp.
///
/// Every image on the site is a real render of a shipping view rather than a
/// mock-up, which only stays true if regenerating them is cheap. Run the suite
/// and copy the output over when a captured surface changes:
///
///     swift test --filter SiteCapture
///     cp /tmp/site-chat.png site/img/chat.png   # …and the rest
///
/// These assert only that a render succeeded — they are not a visual gate, and
/// nothing in CI depends on them. The value is the accumulated knowledge of
/// what `ImageRenderer` can and cannot capture, recorded per test below: any
/// `NSViewRepresentable` renders as an opaque placeholder box, so does
/// `.buttonStyle(.borderless)` (it resolves to an AppKit-backed style),
/// Highlightr and markdown tables populate asynchronously and come out empty, a
/// `ScrollView` renders blank with no workaround, `.task` never runs so
/// self-loading views capture their spinner, an under-tall frame compresses text
/// into an ellipsis instead of clipping, and hierarchical foreground styles
/// resolve against black unless an ancestor foreground is supplied. Swift
/// `Charts` capture fine. Each of those cost a debugging round trip;
/// re-deriving them is the expensive part, not the PNGs.
@Suite("SiteCapture")
@MainActor
internal struct SiteCapture {

    /// `ViewSnapshot.png` frames the view at exactly `size`, so the background
    /// has to be applied *outside* that frame or it paints only the content's
    /// intrinsic height and leaves white letterboxing above and below.
    private func write(_ view: some View, _ name: String, _ size: CGSize) throws {
        let framed = view
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Theme.background)
        let png = try #require(ViewSnapshot.png(framed, size: size))
        try png.write(to: URL(fileURLWithPath: "/tmp/site-\(name).png"))
    }

    /// Chat prose only — no fenced code and no markdown table.
    ///
    /// Both of those populate asynchronously (Highlightr highlights off the
    /// render pass; the table builds its `AttributedString` the same way), so
    /// `ImageRenderer`'s synchronous snapshot catches the chrome with an empty
    /// body. A screenshot showing an empty code block would misrepresent the
    /// app, so the transcript sticks to what renders in one pass and the tool
    /// pills are captured separately below.
    @Test("chat transcript")
    internal func chatTranscript() throws {
        let messages = [
            ChatMessage(role: .user, content: "Which surfaces break if I change the app-wide typeface?"),
            ChatMessage(
                role: .assistant,
                content: """
                Every surface that asks for a fixed-width font **inside** its own \
                `.font(...)` call. A root `.fontDesign(_:)` overrides the design \
                written there, so code blocks, logs, diffs, IDs and timestamps all \
                silently lose their alignment.

                Only a view-level `.monospaced()` wins it back — so 160 sites now \
                re-assert it, and an architecture test fails if a new one forgets.
                """,
                status: "complete"
            ),
        ]
        let transcript = VStack(alignment: .leading, spacing: 16) {
            ForEach(messages) { message in
                MessageBubbleView(message: message)
            }
        }
        .padding(24)
        .environmentObject(PersonaManager())

        // Height is generous on purpose. `write` frames the view at exactly
        // `size`, and a VStack that doesn't fit gets *compressed* rather than
        // clipped: SwiftUI squeezes each `Text` until it truncates, so a frame
        // 20pt too short silently turns a wrapped paragraph into one line
        // ending in an ellipsis — which reads as a bug in the app.
        try write(transcript, "chat", CGSize(width: 880, height: 244))
    }

    @Test("tool call pills")
    internal func toolPills() throws {
        let tools = [
            ToolCallRecord(
                id: "t1",
                name: "read_file",
                context: "Sources/Portal/Views/ChatView.swift",
                summary: "412 lines",
                durationSeconds: 0.4,
                isComplete: true
            ),
            ToolCallRecord(
                id: "t2",
                name: "grep",
                context: "design: .monospaced",
                summary: "160 matches across 63 files",
                durationSeconds: 1.2,
                isComplete: true
            ),
            ToolCallRecord(
                id: "t3",
                name: "edit_file",
                context: "Sources/Portal/Views/Theme.swift",
                summary: "4 insertions",
                durationSeconds: 0.3,
                isComplete: true
            ),
        ]
        let pills = VStack(alignment: .leading, spacing: 8) {
            ForEach(tools) { tool in
                ToolPillView(tool: tool, isRunning: false)
            }
        }
        .padding(24)

        try write(pills, "tools", CGSize(width: 720, height: 136))
    }

    @Test("appearance settings")
    internal func appearance() throws {
        let pane = VStack(alignment: .leading, spacing: 26) {
            AppFontSettingsSection()
            Divider()
            ButtonThemeSettingsSection()
        }
        .padding(28)

        try write(pane, "appearance", CGSize(width: 860, height: 522))
    }

    @Test("toolbar icon treatments")
    internal func toolbarTreatments() throws {
        let slots: [ToolbarIconSlot] = [.settings, .sessions, .cron, .activity, .skills, .wiki, .artifacts]
        let grid = VStack(alignment: .leading, spacing: 16) {
            ForEach(ToolbarIconTreatment.allCases) { treatment in
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(treatment.label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.primary)
                        Text(treatment.detail)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.secondary)
                    }
                    .frame(width: 150, alignment: .leading)

                    ForEach([ToolbarIconTint.neutral, .theme, .warning], id: \.self) { tint in
                        HStack(spacing: 7) {
                            ForEach(slots, id: \.self) { slot in
                                Button {} label: { Image(systemName: slot.systemImage) }
                                    .buttonStyle(ToolbarIconButtonStyle(
                                        appearance: ToolbarIconAppearance(
                                            treatment: treatment, tint: tint, isOverridden: false
                                        )
                                    ))
                            }
                        }
                    }
                }
            }
        }
        .padding(28)

        try write(grid, "toolbar", CGSize(width: 1020, height: 250))
    }

    @Test("typeface options")
    internal func typefaces() throws {
        let grid = VStack(alignment: .leading, spacing: 18) {
            ForEach(AppFontTheme.allCases) { theme in
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    Text(theme.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 96, alignment: .leading)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("The agent finished gathering 12 sessions.")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.primary)
                        HStack(spacing: 12) {
                            Text("2026-08-10 04:12:55")
                                .font(.system(size: 11, design: .monospaced))
                                .monospaced()
                                .foregroundStyle(Theme.secondary)
                            Text("sess_9fA3c1")
                                .font(.system(size: 11, design: .monospaced))
                                .monospaced()
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
                .fontDesign(Self.design(for: theme))
                .fontWidth(theme == .condensed ? .condensed : .standard)
            }
        }
        .padding(28)

        try write(grid, "typefaces", CGSize(width: 760, height: 306))
    }

    /// The turn's tool-call chain, captured as the two surfaces that render
    /// offline: the inline timeline strip that sits in the chat, and the node
    /// cards the full flamechart draws.
    ///
    /// The *expanded* `ThoughtGraphView` cannot be captured here. Its `Canvas`
    /// renders fine on its own (verified with a probe), but on macOS the view
    /// overlays a `GraphMouseInterceptor` — an `NSViewRepresentable` for pan and
    /// hit-testing — across the whole graph, and `ImageRenderer` draws any
    /// representable as a yellow placeholder box, covering everything beneath
    /// it. Same failure mode as `Picker`. So the site shows the real strip and
    /// the real cards rather than a mock-up of the expanded view.
    @Test("turn timeline")
    internal func turnTimeline() throws {
        // Anchored to *now*, not a fixed epoch: the strip relayouts on appear
        // with the live `Date()`, so a still-running node pinned to a past
        // origin would span the gap to today and compress every bar to a
        // sliver. The turn reads as having started 8 seconds ago.
        let origin = Date(timeIntervalSinceNow: -8)
        func at(_ offset: Double) -> Date { origin.addingTimeInterval(offset) }

        let nodes: [ThoughtGraphNode] = [
            ThoughtGraphNode(
                id: "n1", name: "grep", context: "design: .monospaced",
                summary: "160 matches", isComplete: true, durationSeconds: 1.2,
                startedAt: at(0), completedAt: at(1.2)
            ),
            ThoughtGraphNode(
                // Trimmed to 24 chars: the card truncates a reasoning gist at
                // exactly that width, and a mid-word cut in a screenshot reads
                // like a rendering bug rather than the design.
                id: "n2", name: "reasoning", context: "only .monospaced() wins",
                isComplete: true, depth: 1, parentIDs: ["n1"],
                startedAt: at(1.3), completedAt: at(1.3), role: .reasoning
            ),
            ThoughtGraphNode(
                id: "n3", name: "read_file", context: "Views/Theme.swift",
                summary: "1,204 lines", isComplete: true, durationSeconds: 0.6,
                depth: 1, parentIDs: ["n1"], startedAt: at(1.4), completedAt: at(2.0)
            ),
            ThoughtGraphNode(
                id: "a1", name: "sweep-monospaced", summary: "63 files",
                isComplete: true, durationSeconds: 4.4, depth: 1, parentIDs: ["n1"],
                startedAt: at(2.1), completedAt: at(6.5),
                agentID: "sub-1", modelName: "opus", costUSD: 0.21, totalTokens: 41_200
            ),
            ThoughtGraphNode(
                id: "n4", name: "edit_file", context: "Views/CronListView.swift",
                summary: "4 insertions", isComplete: true, durationSeconds: 1.8,
                depth: 2, parentIDs: ["a1"], startedAt: at(2.3), completedAt: at(4.1),
                ownerAgentID: "sub-1"
            ),
            ThoughtGraphNode(
                id: "n5", name: "edit_file", context: "Views/ArtifactsPane.swift",
                summary: "2 insertions", isComplete: true, durationSeconds: 1.5,
                depth: 2, parentIDs: ["a1"], startedAt: at(4.2), completedAt: at(5.7),
                ownerAgentID: "sub-1"
            ),
            ThoughtGraphNode(
                id: "n6", name: "swift build", context: "PortalPackageTests",
                isComplete: false, depth: 1, parentIDs: ["n1"], startedAt: at(6.6)
            ),
        ]

        let strip = InlineTurnTimelineStrip(nodes: nodes, isStreaming: true)
            .padding(24)
        try write(strip, "timeline", CGSize(width: 860, height: 216))

        // The cards the flamechart draws, at the sizes the layout engine gives
        // them — so the site shows real geometry, not a hand-picked frame.
        let engine = ThoughtGraphLayoutEngine()
        engine.layout(nodes: nodes, now: at(8.0))
        let carded = ["n1", "n2", "a1", "n6"].compactMap { id -> (ThoughtGraphNode, ThoughtGraphLayout)? in
            guard let node = nodes.first(where: { $0.id == id }),
                  let layout = engine.layout(for: id) else { return nil }
            return (node, layout)
        }
        let cards = VStack(alignment: .leading, spacing: 12) {
            ForEach(carded, id: \.0.id) { node, layout in
                ThoughtGraphNodeView(
                    node: node,
                    layout: ThoughtGraphLayout(
                        nodeID: layout.nodeID,
                        x: 0, y: 0,
                        width: max(layout.width, 230),
                        height: max(layout.height, 44)
                    ),
                    isSelected: node.id == "a1",
                    isHovered: false,
                    collapsedStepCount: node.id == "a1" ? 2 : nil
                )
            }
        }
        .padding(24)
        try write(cards, "graphnodes", CGSize(width: 300, height: 268))
    }

    /// The cron list. `CronJobRow` is the shipping row and takes only a
    /// `CronJob`, so this is the real surface with no view model standing in.
    @Test("cron jobs")
    internal func cronJobs() throws {
        // Relative timestamps ("in 4h", "2h ago") are computed against the live
        // clock, so the fixtures are offsets from now — a fixed epoch would
        // render as a date years in the past by the time anyone looks.
        let jobs: [CronJob] = [
            CronJob(
                id: "job-1", name: "life/training/morning-run",
                schedule: "every day at 06:30",
                nextRunAt: Date(timeIntervalSinceNow: 8 * 3_600),
                lastRunAt: Date(timeIntervalSinceNow: -16 * 3_600),
                lastStatus: "ok", enabled: true, state: "scheduled",
                deliver: "telegram", promptPreview: "Summarise yesterday's splits and flag anything unusual."
            ),
            CronJob(
                id: "job-2", name: "repo/nightly-ratchet",
                schedule: "every day at 02:00",
                nextRunAt: Date(timeIntervalSinceNow: 4 * 3_600),
                lastRunAt: Date(timeIntervalSinceNow: -7_200),
                lastStatus: "error", enabled: true, state: "scheduled",
                // Under 60 chars: the row truncates a preview at exactly that
                // width, and an ellipsis in every screenshot row reads as a
                // layout fault rather than the deliberate one-line summary.
                deliver: "local", promptPreview: "Ratchet metrics against main and report regressions.",
                lastError: "swift test timed out after 30m"
            ),
            CronJob(
                id: "job-3", name: "reading/arxiv-digest",
                schedule: "every 360m",
                nextRunAt: nil,
                lastRunAt: Date(timeIntervalSinceNow: -4 * 86_400),
                lastStatus: "ok", enabled: false, state: "paused",
                deliver: "local", promptPreview: "Rank new cs.PL preprints against my open questions."
            ),
        ]

        let list = VStack(spacing: 10) {
            ForEach(jobs) { job in
                CronJobRow(job: job)
            }
        }
        // The row leans on hierarchical styles (`.secondary`, `.tertiary`,
        // `.quaternary`) for everything under the job name. Those derive from
        // the *ancestor's* foreground style, which in the app is the List's
        // light-on-dark default — captured standalone they'd resolve against
        // black and the timestamps would come out invisible. Supplying the
        // foreground here is what the enclosing view does at runtime.
        .foregroundStyle(Theme.primary)
        .padding(24)

        try write(list, "cron", CGSize(width: 760, height: 262))
    }

    @Test("activity inbox")
    internal func activityInbox() throws {
        let items: [ActivityItem] = [
            ActivityItem(
                id: "act-1",
                createdAt: Date(timeIntervalSinceNow: -240),
                kind: "approval",
                severity: .warning,
                source: "hermes",
                title: "Approve edit to CronListView.swift",
                summary: "The agent wants to insert 4 lines re-asserting .monospaced() on the cron row's timestamp columns.",
                sessionID: "20260810_041255_d91274",
                isRead: false,
                isDismissed: false,
                actions: [
                    ActivityAction(type: "approve", label: "Approve"),
                    ActivityAction(type: "deny", label: "Deny"),
                ],
                artifacts: [],
                externalRefs: []
            ),
            ActivityItem(
                id: "act-2",
                createdAt: Date(timeIntervalSinceNow: -1_920),
                kind: "artifact",
                severity: .info,
                source: "hermes",
                title: "Coverage report ready",
                summary: "Patch coverage 85.7% across 197 of 230 added executable lines.",
                sessionID: "20260810_035010_4ab7f2",
                isRead: false,
                isDismissed: false,
                actions: [],
                artifacts: [
                    ActivityArtifact(
                        id: "art-1", name: "coverage.html",
                        mimeType: "text/html", size: 48_213
                    ),
                ],
                externalRefs: []
            ),
            ActivityItem(
                id: "act-3",
                createdAt: Date(timeIntervalSinceNow: -7_200),
                kind: "error",
                severity: .error,
                source: "cron",
                title: "nightly-ratchet failed",
                summary: "swift test timed out after 30m — blocked reading the login Keychain.",
                sessionID: "20260810_020000_11c3aa",
                isRead: true,
                isDismissed: false,
                actions: [],
                artifacts: [],
                externalRefs: []
            ),
        ]

        let inbox = VStack(spacing: 8) {
            ForEach(items) { item in
                ActivityRowView(item: item)
            }
        }
        .padding(24)

        try write(inbox, "activity", CGSize(width: 820, height: 288))
    }

    /// The wiki: the ingestion event plot beside the event feed, and the
    /// knowledge-accrued pane that reads input events against page edits.
    ///
    /// Neither force graph can be captured here, for the same reason the
    /// expanded `ThoughtGraphView` can't: `WikiGraph2DCanvas` overlays a
    /// `GraphMouseInterceptor` — an `NSViewRepresentable` for pan, drag and
    /// hit-testing — across the whole surface, and `ImageRenderer` paints any
    /// representable as an opaque placeholder over everything beneath it.
    /// `WikiGraph3DView` is SceneKit, which is the same problem.
    ///
    /// Three further constraints shape what's assembled below, each verified
    /// with a probe rather than assumed:
    ///
    /// - A `ScrollView` renders blank — `.scrollDisabled(true)`, `.fixedSize()`,
    ///   an inner explicit frame and `.defaultScrollAnchor(.top)` all fail
    ///   identically, so there is no workaround, only a different seam. That
    ///   rules out `WikiEventsPageView`, `WikiReaderPane`, `WikiFileTreeSidebar`
    ///   and `WikiPageReaderBody` as whole views (the reader wraps its loaded
    ///   content in one, which is why the page reader isn't a figure on the
    ///   site). Their scroll-free inner surfaces do render: `WikiEventFeedList`
    ///   is the row list both feed hosts embed, and the knowledge pane's tiles
    ///   and charts are the same views `WikiEventsKnowledgePane` composes.
    /// - `.buttonStyle(.borderless)` renders as the same yellow placeholder as a
    ///   representable — it resolves to an AppKit-backed style. So the fixtures
    ///   omit the fields whose affordances are borderless buttons (an event's
    ///   source URL, its changeset chips, a directive's target-page chips), and
    ///   the knowledge pane is assembled from its parts rather than used whole,
    ///   because it carries a segmented `Picker` and a pages-touched list of
    ///   borderless rows. Every one of those is real and optional on the wire;
    ///   leaving them out shows fewer affordances than the app has, never a
    ///   fake one.
    /// - `.task` never runs under `ImageRenderer`, so any view that loads its
    ///   own content captures its spinner unless the state is pre-seeded.
    @Test("wiki events and knowledge accrued")
    internal func wiki() throws {
        // Relative to now, like the cron and activity fixtures: the plot's
        // domain and the feed's "1h ago" are both read against the live clock.
        func ago(_ seconds: Double) -> Date { Date(timeIntervalSinceNow: -seconds) }

        // A ten-day window, with per-day ingestion volume and per-day page-edit
        // volume derived from ONE shape. The knowledge pane's whole claim is that
        // input events and output edits are readable against each other on a
        // shared x, so a fixture with flat input and spiky output would picture
        // the view while contradicting its point.
        let calendar = Calendar.current
        let windowSeconds = 10 * 86_400.0
        let dailyEdits = [14, 9, 31, 22, 6, 47, 38, 12, 26, 19]
        let today: Date = calendar.startOfDay(for: Date())
        let elapsedToday = Date().timeIntervalSince(today)

        // Kinds cycle through a weighted pattern rather than round-robin: a
        // real vault's sources are lopsided (PRs dominate, a stats job posts
        // once a day), and five lanes with an identical count in the legend
        // reads as generated data, which is exactly what it would be.
        let kinds = [
            "github_pr", "linear", "github_pr", "drive", "github_pr",
            "directive", "github_pr", "linear", "openrouter_stats", "github_pr",
            "directive", "linear", "github_pr", "drive",
        ]
        var plotted: [WikiTimelineEvent] = []
        for day in 0..<10 {
            let dayStart: Date = calendar.startOfDay(for: ago(Double(9 - day) * 86_400))
            // Roughly one event per two edits, floored so a quiet day still
            // shows a lane or two rather than a gap the plot can't explain.
            let count = max(2, dailyEdits[day] / 2)
            // Only the elapsed part of today can hold events.
            let span = day == 9 ? elapsedToday : 86_400
            for slot in 0..<count {
                let i = plotted.count
                let when: Date = dayStart.addingTimeInterval(
                    span * (Double(slot) + 0.5) / Double(count)
                )
                plotted.append(WikiTimelineEvent(
                    sourceKey: "e\(i)", kindRaw: kinds[i % kinds.count],
                    label: "event \(i)", url: "",
                    occurredAt: when, ingestedAt: when,
                    // A source that only recorded ingest time plots as a hollow
                    // diamond; a real log has a few. Off the index, not an RNG —
                    // `SiteCapture` renders have to be reproducible.
                    eventTimeEstimated: i.isMultiple(of: 11),
                    actorSlackID: nil, actorName: nil, directiveBody: nil,
                    directiveExcerpt: nil, targetPages: nil, directiveStatus: nil,
                    resultingRevisionIDs: nil
                ))
            }
        }
        // Legend counts read off the same events the plot draws, the way
        // `events_by_kind` does on the wire.
        let eventsByKind = Dictionary(grouping: plotted, by: \.kindRaw).mapValues(\.count)

        let feedRows = [
            WikiTimelineEvent(
                sourceKey: "raw/github/pr-2211.md", kindRaw: "github_pr",
                label: "researchoors/hermes-agent#2211 — pin the draft model revision per request",
                url: "", occurredAt: ago(6_900), ingestedAt: ago(6_600),
                eventTimeEstimated: false,
                actorSlackID: nil, actorName: nil, directiveBody: nil,
                directiveExcerpt: nil, targetPages: nil, directiveStatus: nil,
                resultingRevisionIDs: nil,
                // Shown on the selected row: the leading bytes are what you
                // compare by eye to tell a re-ingest from a new version.
                sha256: "9f2ac41b77e0d3c85a1e"
            ),
            WikiTimelineEvent(
                sourceKey: "raw/slack/directive-4471.md", kindRaw: "directive",
                label: "keep the acceptance numbers on the concept page", url: "",
                occurredAt: ago(19_400), ingestedAt: ago(19_100),
                eventTimeEstimated: false,
                actorSlackID: "U04KQ", actorName: "Ethen", directiveBody: nil,
                directiveExcerpt: "keep the acceptance-rate numbers on the concept page, not the comparison",
                targetPages: nil, directiveStatus: "applied",
                resultingRevisionIDs: [4_471]
            ),
            WikiTimelineEvent(
                sourceKey: "raw/openrouter/2026-08-12.md", kindRaw: "openrouter_stats",
                label: "Daily token spend rollup — 41.2M tokens across 9 models",
                url: "", occurredAt: nil, ingestedAt: ago(48_000),
                eventTimeEstimated: true,
                actorSlackID: nil, actorName: nil, directiveBody: nil,
                directiveExcerpt: nil, targetPages: nil, directiveStatus: nil,
                resultingRevisionIDs: nil
            ),
        ]

        // The macOS split: plot and legend left, feed right, one selection
        // across both — the dot for `e6` is enlarged and the matching feed row
        // is the expanded one. Assembled here because the page itself is a
        // ScrollView; the panes are the shipping views.
        let eventsPage = HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                WikiEventKindLegend(eventsByKind: eventsByKind)
                WikiEventDotChart(
                    events: plotted,
                    window: ago(windowSeconds)...Date(),
                    selectedEventID: .constant("e6")
                )
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Event Feed")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primary)
                WikiEventFeedList(
                    events: feedRows,
                    selectedEventID: .constant("raw/github/pr-2211.md")
                )
            }
            .frame(width: 350)
        }
        .padding(22)

        try write(eventsPage, "wikievents", CGSize(width: 1040, height: 300))

        // The output side: page-edit volume per day, the same series the input
        // events above were scaled from.
        var buckets: [WikiRevisionsTimeline.Bucket] = []
        for day in 0..<10 {
            let start: Date = calendar.startOfDay(for: ago(Double(9 - day) * 86_400))
            buckets.append(WikiRevisionsTimeline.Bucket(bucket: start, count: dailyEdits[day]))
        }
        let totalInWindow = dailyEdits.reduce(0, +)
        // The window ends at the END of today, not `now`: a day-unit `BarMark`
        // spans its whole bucket, so a domain stopping mid-day clips the newest
        // bar in half against the plot edge.
        let windowEnd: Date = today.addingTimeInterval(86_400)
        let revisions = WikiRevisionsTimeline(
            unit: "day",
            since: ago(windowSeconds), until: windowEnd,
            // Pre-window total. Kept the same order of magnitude as the window's
            // own edits — a baseline ten times the window flattens the accrued
            // curve into a straight line, which is true to the view but says
            // nothing about it.
            baseline: 612,
            totalInWindow: totalInWindow,
            buckets: buckets
        )
        let window: ClosedRange<Date> = ago(windowSeconds)...windowEnd

        // The knowledge-accrued pane, assembled from the views
        // `WikiEventsKnowledgePane` composes: it can't be captured whole because
        // it carries a segmented Picker and a list of borderless rows. The tiles
        // read off the same timeline the charts plot, the way the pane's own
        // `statTiles` does, so no figure value can disagree with the plot beside
        // it. Only "Pages touched" is a literal — it comes from a separate
        // `/wiki/changes` response.
        func compact(_ value: Int) -> String { value.formatted(.number.notation(.compactName)) }
        let accrued = VStack(alignment: .leading, spacing: 14) {
            WikiEventsSectionLabel(
                "Knowledge accrued",
                detail: "\(revisions.totalInWindow) page edits in window · \(revisions.baseline) before"
            )
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 130, maximum: 220), spacing: 8, alignment: .topLeading)],
                alignment: .leading,
                spacing: 8
            ) {
                WikiEventsStatTile(
                    label: "Total revisions",
                    value: compact(revisions.totalAllTime),
                    detail: "all time"
                )
                WikiEventsStatTile(
                    label: "This window",
                    value: compact(revisions.totalInWindow),
                    detail: "\(plotted.count) input events"
                )
                WikiEventsStatTile(
                    label: "Busiest day",
                    value: (revisions.busiestBucket?.count).map(compact) ?? "—",
                    detail: revisions.busiestBucket?.bucket?
                        .formatted(date: .abbreviated, time: .omitted) ?? "no edits"
                )
                WikiEventsStatTile(
                    label: "Pages touched",
                    value: "63",
                    detail: "38 concept · 17 entity · 8 topic"
                )
            }
            WikiRevisionsChart(timeline: revisions, window: window, showCumulative: true)
            Divider().overlay(Theme.border)
            WikiEventsInputOutputChart(events: plotted, revisions: revisions, window: window)
        }
        .padding(22)

        try write(accrued, "wikiaccrued", CGSize(width: 900, height: 636))
    }

    @Test("learning dashboard")
    internal func learning() throws {
        var course = Curriculum(
            title: "Swift concurrency, end to end",
            summary: "Actors, isolation, and Sendable in a real app.",
            modules: [
                CurriculumModule(title: "Isolation", overview: "", steps: [
                    CurriculumStep(title: "What @MainActor actually guarantees", kind: .lesson(markdown: "…")),
                    CurriculumStep(title: "Checkpoint", kind: .quiz(questions: [
                        QuizQuestion(
                            q: "What does @MainActor guarantee?",
                            options: ["Serial execution on the main thread", "Thread safety for all members", "No data races anywhere", "Faster UI updates"],
                            correct: "A",
                            explanation: "It pins execution to the main actor's serial executor."
                        ),
                    ])),
                ]),
                CurriculumModule(title: "Sendable", overview: "", steps: [
                    CurriculumStep(title: "Crossing isolation boundaries", kind: .lesson(markdown: "…")),
                    CurriculumStep(title: "nonisolated(unsafe), and when it's a lie", kind: .lesson(markdown: "…")),
                ]),
            ]
        )
        let ordered = course.orderedSteps
        course.markLessonRead(stepID: ordered[0].id)
        course.recordQuizAttempt(stepID: ordered[1].id, scorePercent: 80)

        let quiz = PersistedQuizSession(
            questions: [
                QuizQuestion(q: "…", options: ["a", "b", "c", "d"], correct: "A", explanation: "…"),
                QuizQuestion(q: "…", options: ["a", "b", "c", "d"], correct: "B", explanation: "…"),
                QuizQuestion(q: "…", options: ["a", "b", "c", "d"], correct: "C", explanation: "…"),
                QuizQuestion(q: "…", options: ["a", "b", "c", "d"], correct: "D", explanation: "…"),
                QuizQuestion(q: "…", options: ["a", "b", "c", "d"], correct: "A", explanation: "…"),
            ],
            topic: "WebSocket reconnect + session resume",
            selectedAnswers: [:],
            score: 4,
            sourceSessionID: "20260810_041255_d91274"
        )

        let dashboard = VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                LearningStatTile(value: "3", label: "Courses", icon: "book", iconColor: Theme.accent)
                LearningStatTile(value: "17", label: "Quizzes taken", icon: "checkmark.circle", iconColor: Theme.success)
                LearningStatTile(value: "12", label: "Cards due", icon: "bell", iconColor: Theme.warning)
                LearningStatTile(value: "84%", label: "Avg score")
            }
            CurriculumCard(curriculum: course, onOpen: {}, onDelete: {})
            LearningQuizCard(quiz: quiz, onOpen: {}, onDelete: {})
        }
        .padding(24)

        try write(dashboard, "learning", CGSize(width: 820, height: 248))
    }

    private static func design(for theme: AppFontTheme) -> Font.Design {
        switch theme {
        case .rounded: return .rounded
        case .serif: return .serif
        case .monospaced: return .monospaced
        case .condensed, .system: return .default
        }
    }
}
