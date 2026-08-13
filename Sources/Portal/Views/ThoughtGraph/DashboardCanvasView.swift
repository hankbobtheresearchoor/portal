import SwiftUI

/// A free-form dashboard canvas: floating panels the user drags by the title
/// bar and resizes from any edge or corner, Grafana-style. It knows nothing
/// about WHAT a panel shows — the caller supplies a title, an icon, and a
/// content view per panel via closures — so the same canvas hosts the built-in
/// lenses and any custom sub-view registered later.
///
/// z-order is `layout.panels` array order (last = frontmost); focusing a panel
/// brings it to the end. Frames live in the canvas's own coordinate space, so
/// every drag reads a stable translation from a named space and never feeds
/// back on the moving panel. The layout binding mutates live during a drag
/// (so motion is immediate) but only persists via `onLayoutCommitted` on
/// drag-end, keeping UserDefaults writes off the per-frame path.
internal struct DashboardCanvasView: View {
    @Binding internal var layout: DashboardLayout
    /// Edit vs. use. In **edit** mode the whole panel is a drag surface (its
    /// content goes inert), resize grips show, and the border is a dashed accent
    /// — you rearrange freely without hunting for the title bar or fighting a
    /// scroll view. In **use** mode frames are locked, no grips or drag, and the
    /// content is fully interactive (scroll the chat, pan the flamechart). This
    /// mode split is what makes dragging reliable: there's no scroll-vs-move
    /// ambiguity because the two never coexist.
    internal var isEditing: Bool = true
    /// Show each panel's title bar (icon + name). Toggled off for a clean,
    /// chrome-free canvas where the panels are just their content. Independent of
    /// edit mode — you can rearrange with headers hidden (the move layer covers
    /// the whole panel and the resize grips/delete button are their own layers).
    internal var showsTitleBars: Bool = true
    internal let title: (PanelKind) -> String
    internal let icon: (PanelKind) -> String
    internal let onLayoutCommitted: () -> Void
    internal let content: (DashboardPanel) -> AnyView

    /// The in-flight drag: which panel, which handle, and the frame it started
    /// from. Nil when nothing is being dragged.
    @State private var activeDrag: ActiveDrag?

    private struct ActiveDrag: Equatable {
        internal let id: UUID
        internal let handle: PanelHandle
        internal let startFrame: CGRect
        /// The other panels' frames captured at drag-begin, so an auto-fill
        /// resize recomputes neighbour positions from the pristine layout each
        /// change — never from frames a previous change already moved.
        internal var others: [PanelSnapshot] = []
    }

    private struct PanelSnapshot: Equatable {
        internal let id: UUID
        internal let frame: CGRect
    }

    /// Which grip the pointer is currently over, so it can highlight (and only
    /// that one). Cleared on exit.
    @State private var hoveredHandle: HandleRef?

    private struct HandleRef: Equatable {
        internal let id: UUID
        internal let handle: PanelHandle
    }

    private static let coordSpace = "thoughtDashboardCanvas"
    private static let titleBarHeight: CGFloat = 28
    /// Hit-target thickness for an edge / corner grab zone (invisible, generous).
    private static let edgeGrip: CGFloat = 9
    private static let cornerGrip: CGFloat = 20
    /// Visible handle chrome drawn on the focused panel so resizing is obvious.
    private static let edgeHandleThickness: CGFloat = 4
    private static let edgeHandleLength: CGFloat = 26
    private static let cornerHandleSize: CGFloat = 11

    internal var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Backdrop — a subtle dotted field reads as "canvas", not a card.
                Theme.background

                if layout.isEmpty {
                    emptyHint
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                ForEach(layout.panels) { panel in
                    panelView(panel, bounds: geo.size)
                        // Cut the alignment query at the panel boundary. Every
                        // panel is placed absolutely by `.position()`, so this
                        // ZStack's `.topLeading` contributes nothing to where a
                        // panel lands — but the container still *resolves* that
                        // guide against each child, and resolving it walks the
                        // child's whole layout: explicitAlignment →
                        // childPlacement → commonPlacement →
                        // LayoutProxy.dimensions → sizeThatFits, straight down
                        // into whatever the panel hosts. When that content is a
                        // ScrollView over a LazyVStack (the transcript), the
                        // walk measures it at its ideal — i.e. unbounded —
                        // height, so LazyStack.measureEstimates enumerates every
                        // row, misses its estimates, and calls
                        // LazyLayoutViewCache.signalPrefetch, which lands in
                        // NSHostingView.requestUpdate(after:) → setNeedsUpdate.
                        // That schedules the next pass, which does it all again:
                        // a self-sustaining relayout loop at 100% CPU that never
                        // reaches idle. Sampled live (25 minutes of spin, RSS
                        // flat, so churn rather than growth), the recursion was
                        // ~170 frames deep with that exact cycle repeating.
                        //
                        // A constant guide is read directly, so the container
                        // never asks the subtree for a dimension and the descent
                        // never starts. Zero is the panel's own top-left, which
                        // is what `.topLeading` would have resolved to anyway.
                        .alignmentGuide(.leading) { _ in 0 }
                        .alignmentGuide(.top) { _ in 0 }
                }
            }
            // Size the canvas from the reader, not from its children. The
            // backdrop already fills it and the panels report the proposed size
            // back through `.position()`, so this is the size ZStack computed
            // regardless — stating it keeps a panel's content off the container's
            // sizing path entirely.
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .coordinateSpace(name: Self.coordSpace)
            .onChange(of: geo.size) { oldSize, newSize in
                // Window resized: scale the layout proportionally so a full
                // arrangement stays full (no dead space going fullscreen) and a
                // shrunk window packs panels back in. Never reflow mid-drag —
                // that would fight the user's hand.
                // Skip the zero→real transition: the layout hasn't been seeded
                // yet at that point, and reflowed(from:.zero) would clamped()
                // an empty layout and stomp the seed that's about to land.
                guard activeDrag == nil, oldSize.width > 0, oldSize.height > 0 else { return }
                // Dead band. This writes @State from a GeometryReader whose own
                // children are the panels it resizes, so the write re-enters this
                // handler on the next pass — an unguarded measure→adopt pair here
                // spins the view graph forever (the beachball; same reason
                // ChatLayoutMath gates every measurement on the chat surface).
                // Sub-point size churn carries no user intent, so ignore it
                // entirely rather than relying on the write being a no-op.
                guard DashboardLayout.quantize(oldSize) != DashboardLayout.quantize(newSize) else { return }
                let reflowed = layout.reflowed(from: oldSize, to: newSize)
                // Equatable guard: even a real resize can leave the layout
                // untouched (already clamped, or every panel at minSize), and an
                // identical-value @State write still invalidates the graph.
                guard reflowed != layout else { return }
                layout = reflowed
            }
        }
    }

    // MARK: - One panel

    // A panel is a strict z-stack so every gesture has an unambiguous owner —
    // the earlier bug was a resize grip whose hit area silently covered the whole
    // panel and swallowed every drag. Bottom → top:
    //   1. the card (title bar + content)
    //   2. the move layer (edit only): drag anywhere to move
    //   3. the resize handles (edit only): thin edge/corner strips
    //   4. the delete button (edit only): always the topmost hit target
    // Each layer above the card is exactly as big as its own hit target, so no
    // layer can eat another's input.
    @ViewBuilder
    private func panelView(_ panel: DashboardPanel, bounds: CGSize) -> some View {
        // Only the frontmost panel "focuses" (accent chrome) — and only while
        // editing, since use mode has no movable/selected panel.
        let isFocused = isEditing && layout.panels.last?.id == panel.id
        // Collapsed panels render only their title bar; the full frame is kept in
        // the layout so expanding snaps back to the original size.
        let visibleHeight: CGFloat = panel.isCollapsed ? Self.titleBarHeight : panel.frame.height
        ZStack(alignment: .topLeading) {
            card(panel, isFocused: isFocused, visibleHeight: visibleHeight)
                // The SECOND alignment-resolution site, and the one that kept the
                // relayout loop alive after the outer ZStack's guides were pinned
                // (below, in `body`). Same mechanism, one level down: this stack
                // resolves `.topLeading` against the card, which walks the card's
                // layout — `.frame(width:height:)` → VStack → `content(panel)` →
                // the transcript's ScrollView → LazyVStack — and measuring a lazy
                // stack at its ideal height enumerates every row, misses the
                // estimates, and re-arms the next update pass.
                //
                // Pinning the outer container alone was not enough because the
                // descent doesn't need the whole path to be guide-driven: any
                // ancestor that asks for a dimension restarts it. Sampled on a
                // build that already carried the outer fix, the surviving chain
                // was still `_ZStackLayout.sizeThatFits` → `explicitAlignment` →
                // `childPlacement` → `_FrameLayout` → … → `LazyStack`, which is
                // precisely this stack over `card`'s fixed frame.
                //
                // The card is already sized explicitly and the layers above it are
                // each sized to their own hit target, so `.topLeading` has nothing
                // to compute — zero is where it resolves anyway.
                .alignmentGuide(.leading) { _ in 0 }
                .alignmentGuide(.top) { _ in 0 }

            if isEditing {
                // 2. Move layer — sized to the visible area so the grab zone matches
                // what the user sees (no invisible drag surface below a collapsed bar).
                Color.clear
                    .frame(width: panel.frame.width, height: visibleHeight)
                    .contentShape(Rectangle())
                    .gesture(dragGesture(.move, panel: panel, bounds: bounds))
                    .pointerStyleGrab()

                // 3. Resize handles — only meaningful on the expanded card.
                if !panel.isCollapsed {
                    resizeGrips(panel, bounds: bounds, isFocused: isFocused)
                        .frame(width: panel.frame.width, height: panel.frame.height)
                }

                // 4. Delete — topmost, so its click is never eaten by the move layer.
                deleteButton(panel)
                    .frame(width: panel.frame.width, height: visibleHeight, alignment: .topTrailing)
            }
        }
        .frame(width: panel.frame.width, height: visibleHeight)
        .position(
            x: panel.frame.minX + panel.frame.width / 2,
            y: panel.frame.minY + visibleHeight / 2
        )
    }

    /// The visual card: title bar + content, with the panel chrome. In use mode
    /// its content is fully interactive; in edit mode the move layer above covers
    /// it, so hit-testing here doesn't matter.
    private func card(_ panel: DashboardPanel, isFocused: Bool, visibleHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            if showsTitleBars {
                titleBar(panel, isFocused: isFocused)
            }
            if !panel.isCollapsed {
                content(panel)
                    // `minHeight: 0` for the same reason ConversationPanel's scroll
                    // view carries it: a bare flexible max still answers an
                    // *ideal*-height query with the full content height, and the
                    // sampled loop descends through this exact frame
                    // (`_FlexFrameLayout.sizeThatFits` → `ScrollViewLayoutComputer`
                    // → `LazyStack.measureEstimates`). Answering 0 satisfies the
                    // measurement without enumerating the panel's content, and the
                    // flexible max still fills the card exactly as before.
                    .frame(
                        minWidth: 0, maxWidth: .infinity,
                        minHeight: 0, maxHeight: .infinity,
                        alignment: .topLeading
                    )
                    .clipped()
            }
        }
        .frame(width: panel.frame.width, height: visibleHeight)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(panelBorder(isFocused: isFocused))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(isFocused ? 0.35 : 0.2), radius: isFocused ? 12 : 6, y: 3)
        // Raise this panel when tapped while editing; in use mode taps fall
        // through to the live content.
        .simultaneousGesture(TapGesture().onEnded {
            if isEditing { layout.bringToFront(panel.id) }
        })
    }

    /// The remove (×) button, drawn as its own top-of-stack layer so nothing can
    /// intercept its click.
    private func deleteButton(_ panel: DashboardPanel) -> some View {
        Button {
            layout.remove(panel.id)
            onLayoutCommitted()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondary, Theme.surface)
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Remove panel")
    }

    /// Dashed accent border while editing (reads as "editable"); a quiet solid
    /// hairline in use mode (reads as a settled, locked panel).
    private func panelBorder(isFocused: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(
                isFocused ? Theme.accent.opacity(0.7) : (isEditing ? Theme.accent.opacity(0.3) : Theme.border),
                style: StrokeStyle(
                    lineWidth: isFocused ? 1.5 : 1,
                    dash: isEditing ? [5, 4] : []
                )
            )
    }

    /// Title bar — chrome (icon + name + collapse chevron). In use mode a tap on
    /// the bar toggles the panel collapsed/expanded. In edit mode the move layer
    /// sits above so the tap falls through to the drag gesture instead — collapse
    /// is intentionally disabled while rearranging.
    private func titleBar(_ panel: DashboardPanel, isFocused: Bool) -> some View {
        HStack(spacing: 6) {
            if isEditing {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isFocused ? Theme.secondary : Theme.tertiary)
            }
            Image(systemName: icon(panel.kind))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isFocused ? Theme.accent : Theme.secondary)
            Text(title(panel.kind))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            // Collapse chevron — only in use mode; edit mode uses the move layer.
            if !isEditing {
                Image(systemName: panel.isCollapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            // Leave room for the delete layer's × so the title doesn't run under it.
            if isEditing { Color.clear.frame(width: 22, height: 1) }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.titleBarHeight)
        .frame(maxWidth: .infinity)
        .background(isFocused ? Theme.surfaceHover : Theme.surface.opacity(0.6))
        // Tap the title bar to collapse/expand in use mode.
        .onTapGesture {
            guard !isEditing else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                layout.toggleCollapsed(panel.id)
            }
            onLayoutCommitted()
        }
    }

    // MARK: - Resize grips (4 edges + 4 corners)
    //
    // The invariant that keeps this correct: `.contentShape` + `.gesture` attach
    // to a view whose RENDERED size equals the intended hit zone (a thin edge
    // strip or a small corner square). Positioning is done by a SEPARATE outer
    // `.frame(...alignment:)` that carries no gesture, so it never widens the hit
    // area. The old code applied `.contentShape` AFTER the fill-frame, which made
    // each corner's hit zone the whole panel — the last corner drawn then
    // swallowed every drag as a bottom-right resize. Corners are drawn last so
    // they win over the edges they overlap.

    private func resizeGrips(_ panel: DashboardPanel, bounds: CGSize, isFocused: Bool) -> some View {
        ZStack {
            edgeGrip(panel, .top, bounds: bounds, isFocused: isFocused)
            edgeGrip(panel, .bottom, bounds: bounds, isFocused: isFocused)
            edgeGrip(panel, .leading, bounds: bounds, isFocused: isFocused)
            edgeGrip(panel, .trailing, bounds: bounds, isFocused: isFocused)
            cornerGrip(panel, .topLeading, bounds: bounds, isFocused: isFocused)
            cornerGrip(panel, .topTrailing, bounds: bounds, isFocused: isFocused)
            cornerGrip(panel, .bottomLeading, bounds: bounds, isFocused: isFocused)
            cornerGrip(panel, .bottomTrailing, bounds: bounds, isFocused: isFocused)
        }
    }

    /// A thin, full-length hit strip pinned to one edge. The gesture lives on the
    /// sized strip; the outer positioning frame carries none.
    private func edgeGrip(_ panel: DashboardPanel, _ handle: PanelHandle, bounds: CGSize, isFocused: Bool) -> some View {
        let isHot = hoveredHandle == HandleRef(id: panel.id, handle: handle)
        let horizontal = handle == .top || handle == .bottom
        let alignment: Alignment = handle == .top ? .top
            : handle == .bottom ? .bottom
            : handle == .leading ? .leading : .trailing
        return Color.clear
            .frame(
                maxWidth: horizontal ? .infinity : Self.edgeGrip,
                maxHeight: horizontal ? Self.edgeGrip : .infinity
            )
            .overlay {
                if isFocused {
                    Capsule()
                        .fill(isHot ? Theme.accent : Theme.secondary.opacity(0.7))
                        .frame(
                            width: horizontal ? Self.edgeHandleLength : Self.edgeHandleThickness,
                            height: horizontal ? Self.edgeHandleThickness : Self.edgeHandleLength
                        )
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(handle, panel: panel, bounds: bounds))
            .onHover { inside in setHover(inside, panel: panel, handle: handle) }
            .pointerStyleResize(handle)
            // Position only — no gesture/contentShape here, so it can't widen the
            // grabbable strip.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    /// A small fixed-size hit square pinned to one corner. Same invariant: the
    /// gesture is on the `cornerGrip`-sized view, positioned by an outer frame.
    private func cornerGrip(_ panel: DashboardPanel, _ handle: PanelHandle, bounds: CGSize, isFocused: Bool) -> some View {
        let isHot = hoveredHandle == HandleRef(id: panel.id, handle: handle)
        let alignment: Alignment = handle == .topLeading ? .topLeading
            : handle == .topTrailing ? .topTrailing
            : handle == .bottomLeading ? .bottomLeading : .bottomTrailing
        return Color.clear
            .frame(width: Self.cornerGrip, height: Self.cornerGrip)
            .overlay {
                if isFocused {
                    Circle()
                        .fill(isHot ? Theme.accent : Theme.surface)
                        .overlay(Circle().stroke(isHot ? Theme.accent : Theme.secondary, lineWidth: 1.5))
                        .frame(width: Self.cornerHandleSize, height: Self.cornerHandleSize)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(handle, panel: panel, bounds: bounds))
            .onHover { inside in setHover(inside, panel: panel, handle: handle) }
            .pointerStyleResize(handle)
            // Position only.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    private func setHover(_ inside: Bool, panel: DashboardPanel, handle: PanelHandle) {
        let ref = HandleRef(id: panel.id, handle: handle)
        if inside {
            hoveredHandle = ref
        } else if hoveredHandle == ref {
            hoveredHandle = nil
        }
    }

    // MARK: - Drag/resize gesture

    private func dragGesture(_ handle: PanelHandle, panel: DashboardPanel, bounds: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.coordSpace))
            .onChanged { value in
                // First change of a new drag: capture the start frame once and
                // raise the panel. Subsequent changes recompute from this frame,
                // so translation never accumulates rounding error.
                if activeDrag?.id != panel.id || activeDrag?.handle != handle {
                    let snapshot = layout.panels
                        .filter { $0.id != panel.id }
                        .map { PanelSnapshot(id: $0.id, frame: $0.frame) }
                    activeDrag = ActiveDrag(id: panel.id, handle: handle, startFrame: panel.frame, others: snapshot)
                    layout.bringToFront(panel.id)
                }
                guard let drag = activeDrag else { return }
                let start = drag.startFrame
                let others = drag.others.map(\.frame)
                let candidate = PanelResizeMath.apply(
                    handle: handle,
                    startFrame: start,
                    translation: value.translation,
                    bounds: bounds
                )
                // Snap edges flush to walls/neighbours so panels can sit edge-to-edge.
                let snapped = PanelResizeMath.snap(
                    frame: candidate,
                    handle: handle,
                    others: others,
                    bounds: bounds
                )
                if handle == .move {
                    // A move follows the cursor freely and may pass OVER neighbours
                    // mid-drag — overlap is settled on release (nearestVacant), so a
                    // panel boxed in by others can be dragged across them into open
                    // space instead of being blocked at every step.
                    layout.setFrame(snapped, for: panel.id)
                } else {
                    // A resize auto-fills: a flush neighbour tracks the dragged edge
                    // (shrinking down to its min as the panel grows, growing into the
                    // gap as the panel shrinks) so the canvas stays tiled. A
                    // non-adjacent neighbour is still a hard wall the panel stops at.
                    // Recomputed from the pristine drag-begin snapshot each change, so
                    // neighbours don't drift as the drag continues.
                    let filled = PanelResizeMath.autoFillResize(
                        candidate: snapped,
                        startFrame: start,
                        handle: handle,
                        others: others,
                        bounds: bounds
                    )
                    layout.setFrame(filled.frame, for: panel.id)
                    for (index, frame) in filled.neighbours {
                        layout.setFrame(frame, for: drag.others[index].id)
                    }
                }
            }
            .onEnded { _ in
                // On release, a moved panel settles onto the non-overlapping spot
                // nearest where it was dropped — a drop in the clear stays put; a
                // drop over neighbours slides to the closest open space.
                if let drag = activeDrag, drag.handle == .move,
                   let dropped = layout.panels.first(where: { $0.id == drag.id })?.frame {
                    let others = layout.panels.filter { $0.id != drag.id }.map(\.frame)
                    let settled = PanelResizeMath.nearestVacant(to: dropped, others: others, bounds: bounds)
                    withAnimation(.easeOut(duration: 0.18)) { layout.setFrame(settled, for: drag.id) }
                }
                activeDrag = nil
                onLayoutCommitted()
            }
    }

    // MARK: - Empty state

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 30))
                .foregroundStyle(Theme.tertiary)
            Text("Empty canvas")
                .font(.headline)
                .foregroundStyle(Theme.secondary)
            Text("Add a panel to start composing this turn's view.")
                .font(.caption)
                .foregroundStyle(Theme.tertiary)
        }
    }
}

// MARK: - Pointer style helpers (macOS gets resize cursors; iOS no-ops)

private extension View {
    /// Show a resize cursor over a grip on macOS, matching the handle direction.
    @ViewBuilder
    func pointerStyleResize(_ handle: PanelHandle) -> some View {
        #if os(macOS)
        self.onHover { inside in
            if inside {
                Self.resizeCursor(for: handle).set()
            } else {
                NSCursor.arrow.set()
            }
        }
        #else
        self
        #endif
    }

    /// Show an open-hand cursor over a draggable surface on macOS — only when
    /// `active` (edit mode); in use mode the panel is locked so the cursor stays
    /// the plain arrow.
    @ViewBuilder
    func pointerStyleGrab(active: Bool = true) -> some View {
        #if os(macOS)
        self.onHover { inside in
            if inside && active { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
        }
        #else
        self
        #endif
    }

    #if os(macOS)
    static func resizeCursor(for handle: PanelHandle) -> NSCursor {
        switch handle {
        case .leading, .trailing: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        // No public diagonal cursor; crosshair reads clearly as "corner resize".
        case .topLeading, .topTrailing, .bottomLeading, .bottomTrailing, .move: return .crosshair
        }
    }
    #endif
}
