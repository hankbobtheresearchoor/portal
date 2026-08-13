import SwiftUI

/// The live chat conversation as a dashboard panel: the real transcript — the
/// same messages, streaming the same way — rendered inside a resizable canvas
/// panel instead of owning the whole screen. It is NOT a snapshot or a copy: it
/// observes the live `ChatViewModel`, so tokens stream in and bubbles grow here
/// exactly as they do in the normal chat.
///
/// This is a plain transcript: text-only message bubbles, a small peel bar,
/// any peeled block cards, and a compact activity indicator under the live
/// turn. Each turn's activity renders in exactly ONE place here: thinking and
/// tools are *peelable cards* (see `PeeledBlockKind`), not inline blocks. So
/// the bubble is stripped of its reasoning (`bubbleMessage`) — otherwise
/// thinking would show both inline and in its peeled card — and the streaming
/// status line does NOT re-list the active tool calls, since those are the
/// tools card. Canvas lens TILES (flamechart / tools / thinking, added from
/// the palette) remain available for anyone who wants the plotted view.
///
/// Timer-free: it re-renders on `ChatViewModel` publishes (new / grown messages,
/// streaming toggles), never on a clock.
/// A per-turn block that can be peeled out of its bubble and mirrored as a card
/// layered into the scroll beneath the turn that produced it. Here the card is
/// the block's *only* render site — the bubble no longer keeps an inline copy.
internal enum PeeledBlockKind: String, CaseIterable, Hashable {
    case thinking
    case tools

    internal var label: String {
        switch self {
        case .thinking: return "Thinking"
        case .tools: return "Tools"
        }
    }

    internal var icon: String {
        switch self {
        case .thinking: return "brain"
        case .tools: return "wrench.and.screwdriver"
        }
    }
}

internal struct ConversationPanel: View {
    @ObservedObject internal var chatViewModel: ChatViewModel
    /// The identity the chat presents (harness persona for Centaur, else the
    /// user's Hermes persona) — passed in so this panel doesn't re-derive it.
    internal let persona: Persona
    /// The active skin, resolved by the host so bubbles match the rest of chat.
    internal let skinProvider: ChatSkinProviding
    /// When set (Turns mode), render ONLY this turn's message(s) — the assistant
    /// message with this id and the user prompt that opened it — instead of the
    /// whole transcript. Nil (Scroll mode) shows the full ever-growing thread.
    internal var focusedTurnID: UUID?

    /// Which blocks a turn has *collapsed* (returned), keyed by the assistant
    /// message id. Ephemeral per-session UI state — a viewing choice, not
    /// persisted content. Peeling is the DEFAULT: every available block renders
    /// as a card beneath its turn's bubble unless the user collapses it via the
    /// peel bar. So an empty set (the common case) means "show thinking + tools
    /// cards"; adding a kind here hides that card.
    @State private var collapsed: [UUID: Set<PeeledBlockKind>] = [:]

    /// Coalesce token-by-token auto-scroll: bucket the streaming tail so a full
    /// scroll pass fires per ~256 chars, not per delta (mirrors ChatView).
    private var streamTailKey: String {
        guard let last = chatViewModel.messages.last else { return "none" }
        return "\(last.id):\(last.content.count / 256):\(last.isStreaming)"
    }

    /// The messages to render: the whole transcript in Scroll mode, or just the
    /// focused turn's user+assistant pair in Turns mode. The turn is keyed by its
    /// assistant message id (see SessionTurnBuilder); the immediately preceding
    /// user message is its prompt.
    private var visibleMessages: [ChatMessage] {
        let all = chatViewModel.messages
        guard let focusedTurnID,
              let assistantIdx = all.firstIndex(where: { $0.id == focusedTurnID }) else {
            return all
        }
        var start = assistantIdx
        if assistantIdx > 0, all[assistantIdx - 1].role == .user { start = assistantIdx - 1 }
        return Array(all[start...assistantIdx])
    }

    /// Only follow the streaming tail / show the typing indicator when the
    /// conversation is actually showing the live turn — a pinned past turn is
    /// static, so it neither auto-scrolls nor sprouts a "typing" row.
    private var showsLiveTail: Bool {
        focusedTurnID == nil || focusedTurnID == chatViewModel.messages.last?.id
    }

    internal var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Turns mode pins a single, bounded turn (its user+assistant
                // pair) and scrolls the prompt to the top — so a diagram lower
                // in a tall reply lands below the fold. A LazyVStack would then
                // never instantiate that row (nor fire its diagram's onAppear),
                // leaving it blank. The focused turn is tiny, so render it
                // eagerly; keep the lazy path for the full Scroll transcript
                // where off-screen deferral actually matters.
                Group {
                    if focusedTurnID == nil {
                        LazyVStack(alignment: .leading, spacing: 2) { messageRows }
                    } else {
                        VStack(alignment: .leading, spacing: 2) { messageRows }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // `maxHeight: .infinity` alone still answers an *ideal*-height query
            // with the full content height, and answering it walks every row of
            // the LazyVStack above (LazyStack.measureEstimates → signalPrefetch →
            // requestUpdate → another pass — the relayout loop documented in
            // DashboardCanvasView). A minHeight of 0 makes the ideal answer 0
            // instead, so an ancestor's measurement is satisfied without
            // enumerating the transcript, while the flexible max still fills the
            // panel exactly as before.
            .frame(minHeight: 0, maxHeight: .infinity)
            .background(Theme.background)
            .onChange(of: streamTailKey) { _, _ in if showsLiveTail { scrollToBottom(proxy) } }
            .onChange(of: chatViewModel.messages.count) { _, _ in if showsLiveTail { scrollToBottom(proxy) } }
            .onChange(of: focusedTurnID) { _, _ in scrollToTop(proxy) }
            .onAppear { if showsLiveTail { scrollToBottom(proxy, animated: false) } }
        }
    }

    /// The turn rows, shared by the lazy (Scroll) and eager (focused Turn)
    /// containers. Each row is a bubble plus its peel affordance, any peeled
    /// cards, and — for the live turn — a streaming-status line.
    @ViewBuilder
    private var messageRows: some View {
        let msgs = visibleMessages
        // Boundaries once for the list, not searched per row: this is a ForEach
        // body, so a per-row scan made rendering quadratic in the message count.
        let lastInGroup = ChatView.lastInGroupIDs(msgs)
        ForEach(msgs) { message in
            VStack(alignment: .leading, spacing: 4) {
                let showTimestamp = lastInGroup.contains(message.id)
                let prepared = bubbleMessage(message, showTimestamp: showTimestamp)
                skinProvider.messageBubble(message: prepared, persona: persona)
                // Peel affordance + any blocks already peeled into the scroll
                // for this turn — layered directly under the bubble so they
                // travel with the turn as you scroll.
                peelBar(for: message)
                peeledCards(for: message)
                // The live turn shows a streaming-status line under its reply;
                // settled turns show nothing extra.
                streamingStatusUnder(message)
            }
            .id(message.id)
        }
        // Bottom anchor for auto-scroll.
        Color.clear.frame(height: 1).id(Self.bottomAnchor)
    }

    /// The bubble copy for this panel: the standard prep, but with the thinking
    /// trace/reasoning stripped so the bubble renders text-only. In this canvas
    /// thinking is a *peelable* card (see `peeledCards`), not an inline block —
    /// leaving it on the bubble too would render it twice. Tools are already
    /// non-inline in both skins, so nothing to strip there. The peel card reads
    /// the original, unstripped `message`, so peeling still shows the reasoning.
    private func bubbleMessage(_ message: ChatMessage, showTimestamp: Bool) -> ChatMessage {
        var m = ChatView.prepareBubbleMessage(message, showTimestamp: showTimestamp)
        m.reasoning = nil
        m.thinkingTrace = nil
        return m
    }

    // MARK: - Peel into scroll

    /// Which peelable blocks this turn actually has content for — only assistant
    /// turns, and only kinds with something to show (a thinking trace/reasoning,
    /// or at least one tool call). Empty for user messages and bare replies, so
    /// the peel bar hides itself entirely there.
    private func availableBlocks(for message: ChatMessage) -> [PeeledBlockKind] {
        guard message.role == .assistant else { return [] }
        var kinds: [PeeledBlockKind] = []
        let hasThinking = (message.thinkingTrace?.blocks.isEmpty == false)
            || (message.reasoning?.isEmpty == false)
        if hasThinking { kinds.append(.thinking) }
        if !message.toolCalls.isEmpty { kinds.append(.tools) }
        return kinds
    }

    /// The block toggles under a turn's bubble — one chip per available block.
    /// Blocks are peeled (shown) by default, so a chip reads "Thinking"/"Tools"
    /// when its card is showing and collapses it on tap; tapping again brings it
    /// back. Hidden when the turn has no peelable blocks.
    @ViewBuilder
    private func peelBar(for message: ChatMessage) -> some View {
        let blocks = availableBlocks(for: message)
        if !blocks.isEmpty {
            HStack(spacing: 6) {
                ForEach(blocks, id: \.self) { kind in
                    let isShown = !isCollapsed(kind, for: message.id)
                    Button {
                        toggleCollapse(kind, for: message.id)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isShown ? kind.icon : "arrow.uturn.down")
                                .font(.system(size: 9, weight: .semibold))
                            Text(kind.label)
                                .font(.system(size: 10, weight: .medium))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            isShown ? Theme.accent.opacity(0.15) : Theme.surface,
                            in: Capsule()
                        )
                        .foregroundStyle(isShown ? Theme.accent : Theme.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isShown
                          ? "Collapse this \(kind.label.lowercased()) card"
                          : "Show this \(kind.label.lowercased()) card")
                }
            }
            .padding(.leading, 4)
        }
    }

    /// The block cards layered under a turn — every available block that hasn't
    /// been collapsed. These are the block's only render site (the bubble is
    /// text-only); live views of the same `ChatMessage`, anchored to the turn so
    /// they scroll with it.
    @ViewBuilder
    private func peeledCards(for message: ChatMessage) -> some View {
        let shown = availableBlocks(for: message).filter { !isCollapsed($0, for: message.id) }
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                // Stable order (thinking then tools) regardless of anything.
                ForEach(PeeledBlockKind.allCases.filter { shown.contains($0) }, id: \.self) { kind in
                    PeeledBlockCard(kind: kind, message: message) {
                        toggleCollapse(kind, for: message.id)
                    }
                }
            }
            .padding(.leading, 12)
            .padding(.top, 2)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func isCollapsed(_ kind: PeeledBlockKind, for id: UUID) -> Bool {
        collapsed[id]?.contains(kind) == true
    }

    private func toggleCollapse(_ kind: PeeledBlockKind, for id: UUID) {
        withAnimation(.easeInOut(duration: 0.15)) {
            var set = collapsed[id] ?? []
            if set.contains(kind) { set.remove(kind) } else { set.insert(kind) }
            if set.isEmpty { collapsed[id] = nil } else { collapsed[id] = set }
        }
    }

    /// The streaming-status line shown beneath the live (still-streaming) turn's
    /// reply — a compact activity indicator only. It deliberately does NOT list
    /// the active tool calls: in this canvas tools are a peelable card (see
    /// `peeledCards` / `PeeledBlockKind.tools`), so enumerating them here too
    /// would render them twice. Settled turns show nothing.
    @ViewBuilder
    private func streamingStatusUnder(_ message: ChatMessage) -> some View {
        if message.isStreaming {
            HStack(spacing: 6) {
                PortalProgressView()
                Text(streamingStatusLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondary)
            }
            .padding(.leading, 4)
            .padding(.top, 2)
            .id("conversation-streaming-status")
        }
    }

    private var streamingStatusLabel: String {
        switch chatViewModel.avatarState {
        case .thinking: return "Thinking…"
        case .toolUse: return "Running tools…"
        case .speaking: return "Responding…"
        case .error: return "Error"
        case .idle: return "Working…"
        }
    }

    private static let bottomAnchor = "conversation-panel-bottom"

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let action = { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
        if animated {
            withAnimation(.easeOut(duration: 0.15), action)
        } else {
            action()
        }
    }

    /// Page to a newly-focused turn from its top, so a stepped-to turn reads from
    /// the prompt down rather than landing mid-reply. No-op when following the
    /// live tail (that path already pins to the bottom).
    private func scrollToTop(_ proxy: ScrollViewProxy) {
        guard !showsLiveTail, let firstID = visibleMessages.first?.id else { return }
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(firstID, anchor: .top) }
    }
}

// MARK: - Peeled Block Card

/// A block (thinking or tools) mirrored out of its bubble into the scroll,
/// anchored under the turn that produced it. It's a live view of the same
/// `ChatMessage` fields the bubble renders — as the turn streams, the card
/// grows with it — value-driven (no timer), so it costs nothing extra per frame.
private struct PeeledBlockCard: View {
    internal let kind: PeeledBlockKind
    internal let message: ChatMessage
    /// Pull the block back into the bubble only (dismiss this mirror).
    internal let onReturn: () -> Void

    internal var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.accent.opacity(0.18), lineWidth: 1)
        )
        // A leading accent rail so a peeled card reads as "attached to this turn"
        // rather than a free-floating tile.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.accent.opacity(0.5))
                .frame(width: 2)
                .padding(.vertical, 6)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: kind.icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(kind.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Spacer()
            Button(action: onReturn) {
                Image(systemName: "arrow.uturn.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
            }
            .buttonStyle(.plain)
            .help("Return this block into the bubble only")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .thinking:
            thinkingContent
        case .tools:
            ToolTrailView(
                tools: message.toolCalls,
                reasoning: nil,
                reasoningTokens: nil,
                toolTokens: nil,
                isStreaming: message.isStreaming
            )
        }
    }

    /// The turn's reasoning text — the trace's joined blocks when present, else
    /// the plain reasoning string. Selectable, monospaced, matching the bubble's
    /// reasoning rendering so the mirror reads identically.
    @ViewBuilder
    private var thinkingContent: some View {
        let text = message.thinkingTrace?.fullText ?? message.reasoning ?? ""
        if text.isEmpty {
            Text("No reasoning captured for this turn.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
        } else {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .monospaced()
                .foregroundStyle(Theme.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
