// swiftlint:disable file_length type_body_length
// Legacy giant — split tracked as debt; do not add to this file.
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import os

/// Main chat interface — skin-aware layout.
/// Delegates all visual rendering to the active ChatSkinProvider,
/// so switching skins changes everything: bubbles, streaming panel, background.
struct ChatView: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper
    @EnvironmentObject var personaManager: PersonaManager
    @EnvironmentObject var capabilitiesStore: GatewayCapabilitiesStore
    @EnvironmentObject var ttsService: TTSService
    @State private var showSkinPicker = false
    @State private var showGatewayDebug = false
    #if os(macOS)
    /// Content promoted out of the transcript into the side panel.
    @State private var openArtifact: Artifact?
    #else
    @State private var artifactSheet: Artifact?
    #endif
    #if os(iOS)
    @State private var showSettings = false
    #endif
    @State private var avatarY: CGFloat = 0
    @State private var pendingScrollTask: Task<Void, Never>?

    /// How far the transcript's bottom edge sits below the visible viewport,
    /// in points. 0 means the latest turn is on-screen; a large value means the
    /// user has scrolled up in a long session. Drives the jump-to-latest pill.
    @State private var distanceBelowFold: CGFloat = 0

    /// Height of the visible scroll viewport, captured from ChatViewportHeightKey.
    /// The bottom-fold sentinel compares its own Y against this to decide
    /// whether the newest turn is on-screen.
    @State private var chatViewportHeight: CGFloat = 0

    // ── Thought Graph ──
    @State private var showThoughtGraph = false

    /// On macOS the chat IS the canvas: the session always renders as
    /// `SessionChatCanvas` (its default layout is a single full-width
    /// conversation panel, so a fresh session reads exactly like the classic
    /// transcript). There's no per-session toggle anymore — the canvas owns its
    /// own toolbar, composer, and a "Reset to default view" action. iOS keeps the
    /// plain transcript. This computed exists so shared chrome can branch without
    /// `#if` at every use site.
    private var isInCanvasMode: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    // ── Quiz Mode ──
    @State private var showQuizSheet = false
    @State private var showDecksSheet = false
    @State private var quizVM = QuizViewModel()

    /// On macOS, owns the chat input focus state at the ChatView level so that
    /// a click anywhere in the detail pane (messages, padding, input card) can
    /// On macOS, owns the chat input focus state at the ChatView level so that
    /// a click anywhere in the detail pane (messages, padding, input card) can
    /// restore focus to the text field.  This fixes the classic SwiftUI/AppKit
    /// bridging issue where clicking the sidebar steals first-responder and
    /// subsequent clicks on transparent padding regions never return it.
    #if os(macOS)
    @FocusState private var isInputFocused: Bool
    /// Weak reference to the native NSTextField backing the input. Used by
    /// ChatPaneClickMonitor to call window.makeFirstResponder() directly.
    @State private var inputFieldRef: FocusableTextView?
    #endif

    /// The active skin — change this to swap the entire visual personality
    @AppStorage("chatSkin") private var activeSkin: ChatSkin = .tui

    /// Current skin provider (recomputed when skin changes)
    private var skinProvider: ChatSkinProviding {
        activeSkin.makeProvider()
    }

    /// Reserve the avatar rail only for skins that render the floating avatar.
    /// TUI uses the full transcript width.
    private var messageLeadingPadding: CGFloat {
        activeSkin == .darkManga ? 72 : 16
    }

    /// Whether any bot content exists (for floating avatar visibility)
    private var hasBotContent: Bool {
        chatViewModel.messages.contains { $0.role == .assistant } || chatViewModel.isStreaming
    }

    /// The identity all chat chrome presents. An adopted gateway persona wins;
    /// the backend's harness-fixed identity (Centaur) is the fallback while none
    /// has been adopted. See `PersonaManager.chromePersona(harness:)`.
    private var displayPersona: Persona {
        personaManager.chromePersona(harness: chatViewModel.backendCapabilities.harnessPersona)
    }

    // MARK: - Thought Graph Helpers

    /// Whether to show the Session Graph toggle. Available whenever the
    /// session has ANY assistant activity — the graph is rebuilt from the
    /// persisted transcript, so it stays reachable after a turn ends, not just
    /// while streaming.
    private var shouldShowThoughtGraphToggle: Bool {
        chatViewModel.isStreaming
            || !chatViewModel.activeToolCalls.isEmpty
            || chatViewModel.messages.contains { $0.role == .assistant }
    }

    /// Message ID to scroll to once the thought-graph sheet finishes
    /// dismissing (scrollTo during dismissal is dropped by SwiftUI).
    @State private var pendingJumpMessageID: UUID?

    /// Resolve a tool-call ID to the chat message containing it and stage the
    /// jump; dismissing the sheet triggers the actual scroll.
    private func jumpToTool(toolID: String) {
        guard let message = chatViewModel.messages.first(where: { msg in
            msg.toolCalls.contains(where: { $0.id == toolID })
        }) else { return }
        pendingJumpMessageID = message.id
        showThoughtGraph = false
    }

    #if os(macOS)
    /// Saved living-artifacts picker: opens any stored model (the BKK map,
    /// a long-running comparison) in the side panel, from any session.
    @ViewBuilder
    private var savedArtifactsMenu: some View {
        let saved = ArtifactStore.shared.sortedArtifacts
        if !saved.isEmpty {
            Menu {
                ForEach(saved) { artifact in
                    Button {
                        openArtifact = Artifact(
                            kind: .living(kind: artifact.kind, artifactID: artifact.id),
                            title: artifact.displayName,
                            content: artifact.content
                        )
                    } label: {
                        Label(artifact.displayName, systemImage: iconForKind(artifact.kind))
                    }
                }
                Divider()
                Menu("Remove") {
                    ForEach(saved) { artifact in
                        Button(role: .destructive) {
                            ArtifactStore.shared.remove(id: artifact.id)
                        } label: {
                            Text(artifact.displayName)
                        }
                    }
                }
            } label: {
                Image(systemName: "internaldrive")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Saved artifacts — living models the agent maintains across sessions")
        }
    }

    private func iconForKind(_ kind: String) -> String {
        switch kind {
        case "map": return "map"
        case "chart": return "chart.bar"
        case "graph": return "point.3.connected.trianglepath.dotted"
        case "stats": return "gauge.medium"
        case "html": return "safari"
        default: return "doc.richtext"
        }
    }
    #endif

    private var chatBottomContentPadding: CGFloat {
        #if os(macOS)
        if !chatViewModel.isSessionReady { return 260 }
        if chatViewModel.pendingApproval != nil { return 190 }
        // Extra room for multi-line composer (up to 8 lines + attachments/skills)
        return 240
        #else
        8
        #endif
    }

    /// Current avatar expression based on streaming state
    private var currentAvatarExpression: CharacterExpression {
        if chatViewModel.isStreaming {
            switch chatViewModel.avatarState {
            case .thinking: .thinking
            case .speaking: .happy
            case .toolUse:  .thinking
            case .error:    .confused
            default:        .idle
            }
        } else {
            .idle
        }
    }

    var body: some View {
        #if os(macOS)
        // Artifact side panel: promoted blocks (code, diffs, documents)
        // render full-height beside the transcript. HSplitView only when
        // open — wrapping unconditionally costs divider chrome and layout.
        if let artifact = openArtifact {
            HSplitView {
                chatContent
                    .frame(minWidth: 480)
                    .layoutPriority(1)
                ArtifactPanelView(artifact: artifact) {
                    openArtifact = nil
                }
                .frame(minWidth: 320, idealWidth: 460, maxWidth: 720)
            }
            .environment(\.openArtifact) { openArtifact = $0 }
        } else {
            chatContent
                .environment(\.openArtifact) { openArtifact = $0 }
        }
        #else
        // iOS: no side panel — artifacts open as a sheet.
        chatContent
            .environment(\.openArtifact) { artifactSheet = $0 }
            .sheet(item: $artifactSheet) { artifact in
                NavigationStack {
                    ScrollView {
                        artifactSheetContent(artifact)
                            .padding(16)
                    }
                    .background(Theme.background)
                    .navigationTitle(artifact.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { artifactSheet = nil }
                        }
                    }
                }
            }
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private func artifactSheetContent(_ artifact: Artifact) -> some View {
        switch artifact.kind {
        case .code(let language):
            CodeBlockView(language: language, code: artifact.content)
        case .diff:
            DiffBlockView(code: artifact.content)
        case .markdown:
            MarkdownContentView(text: artifact.content, isStreaming: false)
                .equatable()
        case .living(let kind, let artifactID):
            // Live content when the store has it; actions enabled — the
            // sheet hosts the live model, not a transcript snapshot.
            let content = ArtifactStore.shared.artifacts[artifactID]?.content ?? artifact.content
            ArtifactKindRenderer(kind: kind, content: content, actionableArtifactID: artifactID)
        }
    }
    #endif

    private var chatContent: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            chatToolbar
            SessionUsageBadge(chatViewModel: chatViewModel, client: gatewayClientWrapper.client)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            Divider()
            #endif

            // ── Thought Graph (collapsible) ──
            // On macOS the Session Graph opener lives INSIDE the canvas toolbar
            // (SessionChatCanvas reveals it as an in-canvas panel), so this
            // floating section is iOS-only now — `isInCanvasMode` is always true
            // on macOS.
            if shouldShowThoughtGraphToggle && !isInCanvasMode {
                thoughtGraphSection
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            #if os(macOS)
            // macOS chat IS the canvas: it owns the whole toolbar (usage,
            // response style, export, TTS, Session Graph), the message area, AND
            // the docked composer. Its default layout is a single full-width
            // conversation, so a fresh session reads as the classic transcript.
            SessionChatCanvas(
                chatViewModel: chatViewModel,
                subagentGraph: chatViewModel.subagentGraph,
                reasoningGraph: chatViewModel.reasoningGraph,
                persona: displayPersona,
                skinProvider: skinProvider,
                client: gatewayClientWrapper.client,
                isInputFocused: $isInputFocused,
                inputFieldRef: $inputFieldRef
            )
            #else
// Message list
            messageListArea
            #endif

            #if os(iOS)
            Divider()

            // Approval sheet (if pending)
            if chatViewModel.pendingApproval != nil {
                ApprovalBanner()
                    .environmentObject(chatViewModel)
            }

            // Clarify question (if pending)
            if chatViewModel.pendingClarify != nil {
                ClarifyBanner()
                    .environmentObject(chatViewModel)
            }

            // Input bar
            ChatInputBar()
                .environmentObject(chatViewModel)

            // Debug log (always visible while not session-ready)
            if !chatViewModel.isSessionReady {
                DebugLogPanel(wrapper: gatewayClientWrapper)
            }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 400)
        .background(
            ChatPaneClickMonitor(textFieldRef: inputFieldRef)
        )
        #endif
        .eraseToAnyView()
        #if os(iOS)
        .sheet(isPresented: $showSettings) {
            settingsSheet
        }
        .simultaneousGesture(
            TapGesture().onEnded { _ in dismissKeyboard() },
            including: .all
        )
        #endif
        .sheet(isPresented: $showGatewayDebug) {
            GatewayDebugPanelView(client: gatewayClientWrapper.client)
                #if os(iOS)
                .presentationDetents([.large])
                #else
                .frame(minWidth: 560, minHeight: 620)
                #endif
        }
        .eraseToAnyView()
        #if os(iOS)
        .fullScreenCover(isPresented: $showThoughtGraph) {
            thoughtGraphFullScreen
        }
        #else
        .sheet(isPresented: $showThoughtGraph) {
                thoughtGraphFullScreen
                    .frame(width: thoughtGraphWidth, height: thoughtGraphHeight)
        }
        #endif
        .sheet(isPresented: $showQuizSheet) {
            QuizSheet(
                viewModel: quizVM,
                onClose: {
                    showQuizSheet = false
                    quizVM.close(sessionID: chatViewModel.currentSessionID)
                    chatViewModel.clearQuiz()
                },
                onReviewWithAgent: { prompt in
                    let reviewPrompt: String = prompt
                    showQuizSheet = false
                    quizVM.close(sessionID: chatViewModel.currentSessionID)
                    let _ = Task<Void, Never> { await chatViewModel.reviewQuizWithAgent(prompt: reviewPrompt) }
                },
                onOpenLearning: {
                    showDecksSheet = true
                }
            )
        }
        .sheet(isPresented: $showDecksSheet) {
            SRSDashboardView(
                onClose: {
                    showDecksSheet = false
                },
                onStudyDeck: { deck in
                    showDecksSheet = false
                    quizVM.load(deck: deck)
                    showQuizSheet = true
                }
            )
        }
        .onAppear {
            // no-op: persona is read-only from gateway
            #if os(macOS)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isInputFocused = true
            }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: .hermesReviewQuiz)) { notification in
            // "Review with Agent" from an inline Learning-view quiz — send the
            // review prompt to the current chat session.
            if let prompt = notification.userInfo?["reviewPrompt"] as? String {
                showQuizSheet = false
                let _ = Task<Void, Never> { await chatViewModel.reviewQuizWithAgent(prompt: prompt) }
            }
        }
        .onChange(of: chatViewModel.currentSessionID) { _, _ in
            // Close the thought graph when switching sessions
            withAnimation(.easeOut(duration: 0.2)) {
                showThoughtGraph = false
            }
        }
        #if os(macOS)
        .onChange(of: chatViewModel.refocusInput) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isInputFocused = true
            }
        }
        .onChange(of: chatViewModel.quizQuestions) { _, questions in
            if let questions {
                quizVM.load(questions: questions, topic: chatViewModel.quizTopic)
                showQuizSheet = true
            }
        }
        .onChange(of: chatViewModel.flashcardDeckReady) { _, deck in
            if let deck {
                quizVM.load(deck: deck)
                showQuizSheet = true
            }
        }
        .onChange(of: chatViewModel.errorMessageForQuiz) { _, errorMsg in
            if let errorMsg {
                quizVM.errorMessage = errorMsg
                showQuizSheet = true
            }
        }
        .navigationTitle("")
        .background(activeSkin.background)
        #else
        .navigationTitle(chatViewModel.sessionTitle)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private var latestAssistantTurnProbe: some View {
        // Only the darkManga floating avatar consumes this Y — don't run a
        // per-layout-pass GeometryReader (and its preference traffic) for
        // skins that never read it. The value is rounded to whole points so
        // sub-pixel layout jitter cannot mint a "new" preference value every
        // pass; see ChatLayoutMath for why that loops.
        if activeSkin == .darkManga && hasBotContent {
            GeometryReader { geo in
                Color.clear.preference(
                    key: LatestBotTurnYKey.self,
                    value: ChatLayoutMath.avatarY(
                        fromProbeMaxY: geo.frame(in: .named("chatContent")).maxY
                    )
                )
            }
            .frame(height: 0)
        }
    }

    /// Zero-height marker pinned to the bottom of the transcript content. It
    /// reports how far its own bottom edge sits past the visible viewport's
    /// lower edge (measured in the fixed "chatViewport" space): 0 when the
    /// newest turn is on-screen, growing as the user scrolls up. That distance
    /// gates the jump-to-latest pill.
    private var bottomFoldSentinel: some View {
        GeometryReader { geo in
            let maxY = geo.frame(in: .named("chatViewport")).maxY
            let distance = max(0, maxY - chatViewportHeight)
            Color.clear.preference(key: BottomFoldDistanceKey.self, value: distance)
        }
        .frame(height: 0)
    }

    /// Floating pill that appears bottom-right when the transcript is scrolled
    /// up in a long session, so the user can snap back to the newest message
    /// without hand-scrolling. Hidden whenever the latest turn is already
    /// on-screen. The transient status/streaming rows keep the transcript
    /// auto-scrolled while streaming, so this is a read-mode affordance.
    @ViewBuilder
    private func jumpToLatestButton(proxy: ScrollViewProxy) -> some View {
        if distanceBelowFold > 120 {
            HStack {
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.25)) {
                        scrollToBottom(proxy: proxy)
                    }
                } label: {
                    Label("Jump to latest", systemImage: "arrow.down")
                        .font(.caption.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(Theme.accent)
                        )
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.22), radius: 6, x: 0, y: 3)
                }
                .buttonStyle(.plain)
                .help("Scroll to the newest message")
            }
            .padding(.trailing, 20)
            .padding(.bottom, jumpButtonBottomInset)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .allowsHitTesting(true)
        }
    }

    /// Lift the pill above the composer so it never overlaps the input card.
    private var jumpButtonBottomInset: CGFloat {
        #if os(macOS)
        return chatViewModel.isSessionReady ? 96 : 24
        #else
        return 72
        #endif
    }

    /// Toolbar chrome above the transcript. macOS keeps the original
    /// single-row layout; iOS collapses secondary actions into an overflow
    /// menu so the persona, model, and streaming/stop/error state stay
    /// legible at phone widths.
    private var chatToolbar: some View {
        #if os(macOS)
        macChatToolbar
        #else
        iosChatToolbar
        #endif
    }

    #if os(macOS)
    private var macChatToolbar: some View {
        HStack {
            // Persona badge — tap to switch persona
            personaBadge

            // Skin badge — tap to switch skin
            Button {
                showSkinPicker = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: activeSkin.icon)
                        .font(.caption2)
                    Text(activeSkin.displayName)
                        .font(.caption2)
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showSkinPicker) {
                SkinPickerView(activeSkin: $activeSkin)
            }

            // Model picker — tap to switch this session's model
            ModelPickerMenu()

            // TTS toggle
            Button {
                ttsService.toggle()
            } label: {
                Image(systemName: ttsService.isEnabled ? "speaker.wave.3.fill" : "speaker.slash")
                    .font(.caption2)
                    .foregroundStyle(ttsService.isEnabled ? Theme.accent : .secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(ttsService.isEnabled ? "Text-to-speech enabled" : "Text-to-speech disabled")

            // Response style (deep map / balanced / direct)
            if chatViewModel.backendCapabilities.supportsResponseStyles {
                Menu {
                    responseStyleMenuItems
                } label: {
                    Image(systemName: chatViewModel.responseStyle.icon)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Reopen flashcards button
            if quizVM.hasFlashcardDeck {
                Button {
                    quizVM.switchMode(to: .flashcards)
                    showQuizSheet = true
                } label: {
                    Label("Flashcards", systemImage: "rectangle.on.rectangle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .accessibilityLabel("Reopen Flashcards")
            }

            // Saved decks dashboard
            Button {
                showDecksSheet = true
            } label: {
                Label("Decks", systemImage: "tray.full")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .accessibilityLabel("Flashcard Decks Dashboard")

            Button {
                showGatewayDebug = true
            } label: {
                Label("Debug Connection", systemImage: "wave.3.right.circle")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .accessibilityLabel("Debug Connection")

            if chatViewModel.isStreaming {
                if chatViewModel.isRemoteTurn {
                    remoteTurnBadge
                }
                stopButton
            }

            if !chatViewModel.isSessionReady && chatViewModel.error == nil {
                creatingSessionIndicator
            }

            if let error = chatViewModel.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(activeSkin.background)
    }
    #endif

    #if os(iOS)
    private var iosChatToolbar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                personaBadge

                // Model picker outranks the persona badge so the model name
                // truncates last.
                ModelPickerMenu()
                    .layoutPriority(1)

                #if os(macOS)
                savedArtifactsMenu
                #endif

                Spacer(minLength: 8)

                if chatViewModel.isStreaming {
                    if chatViewModel.isRemoteTurn {
                        remoteTurnBadge
                    }
                    stopButton
                }

                if !chatViewModel.isSessionReady && chatViewModel.error == nil {
                    creatingSessionIndicator
                }

                iosOverflowMenu
            }

            // Errors get a full-width row instead of a sliver of the toolbar.
            if let error = chatViewModel.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Secondary actions collapsed behind an ellipsis so the primary row
    /// stays legible on phone widths. Every control from the old flat row
    /// remains reachable here.
    private var iosOverflowMenu: some View {
        Menu {
            Section {
                Menu {
                    ForEach(ChatSkin.allCases) { skin in
                        Button {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                activeSkin = skin
                            }
                        } label: {
                            if skin == activeSkin {
                                Label(skin.displayName, systemImage: "checkmark")
                            } else {
                                Label(skin.displayName, systemImage: skin.icon)
                            }
                        }
                    }
                } label: {
                    Label("Chat Style: \(activeSkin.displayName)", systemImage: activeSkin.icon)
                }

                if chatViewModel.backendCapabilities.supportsResponseStyles {
                    Menu {
                        responseStyleMenuItems
                    } label: {
                        Label("Response Style: \(chatViewModel.responseStyle.label)",
                              systemImage: chatViewModel.responseStyle.icon)
                    }
                }

                Button {
                    ttsService.toggle()
                } label: {
                    Label(ttsService.isEnabled ? "Mute Speech" : "Speak Responses",
                          systemImage: ttsService.isEnabled ? "speaker.slash" : "speaker.wave.3.fill")
                }
            }

            Section {
                if quizVM.hasFlashcardDeck {
                    Button {
                        quizVM.switchMode(to: .flashcards)
                        showQuizSheet = true
                    } label: {
                        Label("Flashcards", systemImage: "rectangle.on.rectangle")
                    }
                }
                Button {
                    showDecksSheet = true
                } label: {
                    Label("Decks", systemImage: "tray.full")
                }
            }

            Section {
                SessionExportMenuItems(assistantName: displayPersona.name)
            }

            Section {
                Button {
                    showGatewayDebug = true
                } label: {
                    Label("Debug Connection", systemImage: "wave.3.right.circle")
                }
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
        }
        .accessibilityLabel("More Actions")
    }
    #endif

    // MARK: - Shared toolbar pieces

    private var personaBadge: some View {
        HStack(spacing: 6) {
            displayPersona.bubbleAvatar(size: 22)
            Text(displayPersona.name)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)

            Circle()
                .fill(chatViewModel.isStreaming ? Color.orange : Color.green)
                .frame(width: 6, height: 6)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }

    @ViewBuilder
    private var responseStyleMenuItems: some View {
        ForEach(ResponseStyle.allCases) { style in
            Button {
                chatViewModel.setResponseStyle(style)
            } label: {
                if style == chatViewModel.responseStyle {
                    Label(style.label, systemImage: "checkmark")
                } else {
                    Text(style.label)
                }
            }
        }
    }

    private var remoteTurnBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.caption2)
            #if os(macOS)
            Text("Live from another device")
                .font(.caption2)
            #else
            // Short label on iOS — the full phrase eats the whole row.
            Text("Live")
                .font(.caption2)
                .lineLimit(1)
            #endif
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Theme.accent.opacity(0.1), in: Capsule())
        .accessibilityLabel("Live from another device")
    }

    private var stopButton: some View {
        Button {
            Task { await chatViewModel.interrupt() }
        } label: {
            Label("Stop", systemImage: "stop.fill")
                .font(.caption)
        }
        .portalButton(tint: .red)
    }

    private var creatingSessionIndicator: some View {
        HStack(spacing: 4) {
            PortalProgressView()
                .scaleEffect(0.7)
            Text("Creating session…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    #if os(iOS)
    private var settingsSheet: some View {
        SettingsView()
            .environmentObject(settings)
            .environmentObject(personaManager)
            .environmentObject(capabilitiesStore)
    }
    #endif

    private var messageListArea: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView(showsIndicators: false) {
                    GeometryReader { viewport in
                        Color.clear.preference(
                            key: ChatViewportHeightKey.self,
                            value: viewport.size.height
                        )
                    }
                    .frame(height: 0)

                    ZStack(alignment: .topLeading) {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            let msgs = chatViewModel.messages
                            ForEach(renderedMessages, id: \.element.id) { index, message in
                                if let noticeLabel = message.delegationBatchNoticeLabel {
                                    // A gateway async-delegation batch marker —
                                    // render as a centered interstitial rule, not
                                    // a prose bubble (the raw marker reads as a
                                    // broken response otherwise).
                                    DelegationBatchNoticeView(label: noticeLabel)
                                        .id(message.id)
                                } else {
                                    // `index` is the message's position in the
                                    // unfiltered `msgs` (renderedMessages
                                    // enumerates before filtering), so the
                                    // boundary is a neighbor read, not a search.
                                    let showTimestamp: Bool = Self.isLastMessageInGroup(
                                        at: index,
                                        in: msgs
                                    )
                                    let preparedMessage: ChatMessage = Self.prepareBubbleMessage(
                                        message, showTimestamp: showTimestamp
                                    )
                                    skinProvider.messageBubble(
                                        message: preparedMessage,
                                        persona: displayPersona
                                    )
                                    .id(message.id)
                                }
                            }

                            if chatViewModel.isStreaming {
                                // Same plane as the running-tools trace: the
                                // status + live timeline occupy the main width;
                                // the skills lens (the "what capability" view)
                                // pins to the far-right, grouped by the skill
                                // taxonomy and updating live as skills attach.
                                HStack(alignment: .top, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        skinProvider.streamingPanel(
                                            state: chatViewModel.avatarState,
                                            activeToolCalls: chatViewModel.activeToolCalls,
                                            personaName: displayPersona.name,
                                            accentColor: displayPersona.accentColor
                                        )
                                        .id("streaming-status")

                                        // Live flamechart strip alongside the
                                        // text tool trace — bars fill in real
                                        // time as tools run and subagents take
                                        // turns. Tap opens the full session graph.
                                        InlineTurnTimelineLive(
                                            chatViewModel: chatViewModel,
                                            subagentGraph: chatViewModel.subagentGraph,
                                            reasoningGraph: chatViewModel.reasoningGraph,
                                            onExpand: { showThoughtGraph = true }
                                        )
                                        .id("inline-timeline")
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                    if !chatViewModel.currentTurnSkills.isEmpty {
                                        TurnSkillsLens(skills: chatViewModel.currentTurnSkills)
                                            .frame(width: 168)
                                            .id("turn-skills-lens")
                                    }
                                }
                                .transition(.opacity)
                            }

                            if let status = chatViewModel.transientStatus {
                                HStack(spacing: 6) {
                                    PortalProgressView()
                                        .scaleEffect(0.6)
                                    Text(status)
                                        .font(.caption)
                                        .foregroundStyle(Theme.tertiary)
                                        .lineLimit(1)
                                }
                                .id("transient-status")
                                .transition(.opacity)
                            }

                            bottomFoldSentinel
                        }
                        .padding(.leading, messageLeadingPadding)
                        .padding(.trailing, 16)
                        .padding(.top, 8)
                        .padding(.bottom, chatBottomContentPadding)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        latestAssistantTurnProbe

                        if activeSkin == .darkManga && hasBotContent {
                            FloatingAvatarView(
                                expression: currentAvatarExpression,
                                persona: displayPersona
                            )
                            .offset(y: avatarY)
                            .padding(.leading, 16)
                        }
                    }
                    .coordinateSpace(name: "chatContent")
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            #if os(macOS)
                VStack(spacing: 8) {
                    if chatViewModel.pendingApproval != nil {
                        ApprovalBanner()
                            .environmentObject(chatViewModel)
                            .padding(.horizontal, 24)
                    }

                    if chatViewModel.pendingClarify != nil {
                        ClarifyBanner()
                            .environmentObject(chatViewModel)
                            .padding(.horizontal, 24)
                    }

                    if !chatViewModel.isSessionReady {
                        DebugLogPanel(wrapper: gatewayClientWrapper)
                            .padding(.horizontal, 24)
                    }

                    ChatInputBar(isFocused: $isInputFocused, inputFieldRef: $inputFieldRef)
                        .environmentObject(chatViewModel)
                        .frame(maxWidth: 840, alignment: .center)
                        .id(chatViewModel.currentSessionID ?? "no-session")
                    if let error = chatViewModel.error {
                        ErrorBannerView(error: error) {
                            chatViewModel.error = nil
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
                .frame(maxWidth: 808, alignment: .bottom)
            #endif

                jumpToLatestButton(proxy: proxy)
            }
            .coordinateSpace(name: "chatViewport")
            .background(activeSkin.background)
            #if os(macOS)
            .scrollIndicators(.hidden, axes: .horizontal)
            #else
            .scrollDismissesKeyboard(.interactively)
            #endif
            .onPreferenceChange(BottomFoldDistanceKey.self) { distance in
                // How far the transcript bottom sits past the viewport's lower
                // edge. Snap tiny values to 0 so sub-pixel jitter near the
                // bottom never flickers the pill in and out.
                let clamped = distance < 24 ? 0 : distance
                if abs(clamped - distanceBelowFold) > 1 {
                    // Animate only the threshold crossings that show/hide the
                    // pill, so its entrance/exit eases instead of popping.
                    let wasVisible = distanceBelowFold > 120
                    let willBeVisible = clamped > 120
                    if wasVisible != willBeVisible {
                        withAnimation(.easeInOut(duration: 0.2)) { distanceBelowFold = clamped }
                    } else {
                        distanceBelowFold = clamped
                    }
                }
            }
            .onPreferenceChange(LatestBotTurnYKey.self) { y in
                if let y = y {
                    Task { @MainActor in
                        // Hysteresis: adopting Y writes @State → body → new
                        // layout pass → probe re-measures. Without a dead
                        // band the measure/adopt pair can ping-pong forever
                        // (the beachball); a sub-4pt move is invisible.
                        guard ChatLayoutMath.shouldMoveAvatar(from: avatarY, to: y) else { return }
                        avatarY = y
                    }
                }
            }
            .onPreferenceChange(ChatViewportHeightKey.self) { height in
                if abs(height - chatViewportHeight) > 1 {
                    chatViewportHeight = height
                }
                if !hasBotContent {
                    Task { @MainActor in
                        await Task.yield()
                        // Same dead band as the sibling handler above, for the
                        // same reason: this writes @State from a measurement of
                        // the view it lays out, so an unguarded write re-measures
                        // and can ping-pong forever. The empty-transcript path is
                        // no less prone to it than the populated one.
                        let target = max(0, height - 72)
                        guard ChatLayoutMath.shouldMoveAvatar(from: avatarY, to: target) else { return }
                        avatarY = target
                    }
                }
            }
            .onChange(of: chatViewModel.messages.count) { _, _ in
                scheduleScrollToBottom(proxy: proxy, reason: "message-count")
            }
            .onChange(of: pendingJumpMessageID) { _, target in
                // Jump staged by the thought graph's "Jump to tool in chat".
                // Delay past the sheet dismissal animation — scrollTo during
                // dismissal is silently dropped.
                guard let target else { return }
                pendingScrollTask?.cancel()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                    pendingJumpMessageID = nil
                }
            }
            .onChange(of: latestMessageRenderKey) { _, _ in
                scheduleScrollToBottom(proxy: proxy, reason: "message-content")
            }
            .onChange(of: activeToolCallRenderKey) { _, _ in
                scheduleScrollToBottom(proxy: proxy, reason: "tool-state")
            }
            .onChange(of: chatViewModel.isStreaming) { _, streaming in
                if streaming { scheduleScrollToBottom(proxy: proxy, reason: "streaming") }
            }
            .onChange(of: chatViewModel.avatarState) { _, _ in
                scheduleScrollToBottom(proxy: proxy, reason: "avatar-state")
            }
            .onDisappear {
                pendingScrollTask?.cancel()
                pendingScrollTask = nil
            }
        }
    }

    private var renderedMessages: [(offset: Int, element: ChatMessage)] {
        let enumerated = Array(chatViewModel.messages.enumerated())
            .filter { !$0.element.isCronInjection }
        guard ProcessInfo.processInfo.arguments.contains("--virtualize-transcript") else {
            return enumerated
        }
        let keepCount = chatViewModel.isStreaming ? 2 : 4
        return Array(enumerated.suffix(keepCount))
    }

    private var latestMessageRenderKey: String {
        guard let last = chatViewModel.messages.last else { return "none" }
        // Bucket text length so token-by-token deltas do not force a full
        // scroll/layout pass for every tiny chunk. Content still renders as it
        // streams; auto-scroll is just coalesced to reduce main-thread pressure
        // on long sessions.
        let contentBucket = last.content.count / 256
        let reasoningBucket = (last.reasoning?.count ?? 0) / 256
        return "\(last.id.uuidString):\(contentBucket):\(reasoningBucket):\(last.isStreaming)"
    }

    private var activeToolCallRenderKey: String {
        chatViewModel.activeToolCalls
            .sorted { $0.key < $1.key }
            .map { key, value in
                let contextBucket = (value.summary ?? value.context ?? "").count / 256
                return "\(key):\(value.isComplete):\(contextBucket)"
            }
            .joined(separator: "|")
    }

    // MARK: - Thought Graph Section

    @ViewBuilder
    private var thoughtGraphSection: some View {
        VStack(spacing: 0) {
            // ── Open button — the live per-turn timeline renders inline in the
            // transcript (InlineTurnTimelineLive); this opens the macro
            // all-turns "Session Graph" you traverse across the conversation. ──
            Button {
                showThoughtGraph = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.caption)
                    Text("Session Graph")
                        .font(.caption)
                    Spacer()
                    if chatViewModel.isStreaming {
                        Circle()
                            .fill(Color.amber)
                            .frame(width: 6, height: 6)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Theme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 6)
        }
    }

    #if os(macOS)
    private var thoughtGraphWidth: CGFloat {
        min((NSScreen.main?.visibleFrame.width ?? 1200) * 0.9, 1600)
    }

    private var thoughtGraphHeight: CGFloat {
        min((NSScreen.main?.visibleFrame.height ?? 800) * 0.9, 1000)
    }
    #endif

    @ViewBuilder
    private var thoughtGraphFullScreen: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Session Graph")
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
                Spacer()
                Button {
                    showThoughtGraph = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 28, height: 28)
                        .background(Theme.surface, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Close (Esc)")
                // Escape collapses the expanded graph. `.cancelAction` binds Esc
                // on macOS; harmless elsewhere.
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            SessionGraphPane(
                chatViewModel: chatViewModel,
                subagentGraph: chatViewModel.subagentGraph,
                reasoningGraph: chatViewModel.reasoningGraph,
                onJumpToTool: { toolID in jumpToTool(toolID: toolID) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
        // Belt-and-suspenders: catch Esc even when focus isn't on the button
        // (e.g. after interacting with the graph canvas).
        #if os(macOS)
        .onExitCommand { showThoughtGraph = false }
        #endif
    }

    private func scheduleScrollToBottom(proxy: ScrollViewProxy, reason: String) {
        _ = reason
        pendingScrollTask?.cancel()
        let delay: UInt64 = chatViewModel.isStreaming ? 500_000_000 : 20_000_000
        pendingScrollTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            scrollToBottom(proxy: proxy)
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        let action = {
            if chatViewModel.isStreaming {
                if chatViewModel.activeToolCalls.isEmpty, let lastMsg = chatViewModel.messages.last {
                    proxy.scrollTo(lastMsg.id, anchor: .bottom)
                } else {
                    proxy.scrollTo("streaming-status", anchor: .bottom)
                }
            } else if let lastMsg = chatViewModel.messages.last {
                proxy.scrollTo(lastMsg.id, anchor: .bottom)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--disable-animations") {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, action)
        } else {
            withAnimation(.easeOut(duration: 0.15), action)
        }
    }
}

// MARK: - Floating Avatar (Singleton)
// Exactly one instance. Y position driven by LatestBotTurnYKey preference.
// Animated with easeInOut 400ms.

private struct FloatingAvatarView: View {
    let expression: CharacterExpression
    let persona: Persona

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.surface.opacity(0.96))
                    .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 4)

                LottieCharacterView(
                    expression: expression,
                    size: CGSize(width: 48, height: 48)
                )
                .frame(width: 48, height: 48)
            }
            .frame(width: 52, height: 52)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(persona.accentColor.opacity(0.55), lineWidth: 1)
            )

            Text(persona.name)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
                .frame(width: 58)
                .foregroundStyle(persona.accentColor.opacity(0.75))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Preference Key
// Tracks Y position of the latest bot turn within the scroll content coordinate space.
// Multiple assistant messages and the streaming panel report their Y;
// reduce takes the last non-nil value (bottom-most in view tree = latest turn).

private struct LatestBotTurnYKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat?
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = next }
    }
}

private struct ChatViewportHeightKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// How far the transcript's bottom edge sits past the visible viewport, in
// points. Reported by the zero-height bottomFoldSentinel; gates the
// jump-to-latest pill. Single producer, so reduce keeps the last value.
private struct BottomFoldDistanceKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Skin Picker

struct SkinPickerView: View {
    @Binding var activeSkin: ChatSkin

    var body: some View {
        VStack(spacing: 12) {
            Text("Chat Style")
                .font(.headline)

            ForEach(ChatSkin.allCases) { skin in
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        activeSkin = skin
                    }
                } label: {
                    HStack {
                        Image(systemName: skin.icon)
                            .frame(width: 20)
                        Text(skin.displayName)
                            .fontWeight(activeSkin == skin ? .bold : .regular)
                        Spacer()
                        if activeSkin == skin {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(activeSkin == skin ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 200)
    }
}

// MARK: - Input Bar

struct ChatInputBar: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    @EnvironmentObject var personaManager: PersonaManager
    @EnvironmentObject var capabilitiesStore: GatewayCapabilitiesStore

    /// Composer container look, toggled from the canvas edit toolbar. Shared
    /// app-wide via the "composerStyle" key.
    @AppStorage("composerStyle") private var composerStyle: ComposerStyle = .card

    /// The identity the composer placeholder names — an adopted gateway persona
    /// wins, else the backend's harness-fixed identity (Centaur).
    private var displayPersona: Persona {
        personaManager.chromePersona(harness: chatViewModel.backendCapabilities.harnessPersona)
    }

    /// On macOS, the focus binding is owned by ChatView so that clicks
    /// anywhere in the detail pane can restore focus. On iOS the binding
    /// is nil and ChatInputBar owns its own @FocusState internally.
    #if os(macOS)
    var isFocused: FocusState<Bool>.Binding
    @Binding var inputFieldRef: FocusableTextView?
    #else
    @FocusState private var isInputFocused: Bool
    #endif

    #if os(iOS)
    @State private var selectedPhotosPickerItems: [PhotosPickerItem] = []
    #endif

    private var isSendDisabled: Bool {
        let textEmpty = chatViewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let noAttachments = chatViewModel.pendingAttachments.isEmpty
        return (textEmpty && noAttachments) || chatViewModel.isStreaming
    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            // Attached skills chips
            if !chatViewModel.activeSkills.isEmpty {
                attachedSkillsChips
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
            }
            // Attachment preview strip above input
            if !chatViewModel.pendingAttachments.isEmpty {
                attachmentPreviewStrip
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
            }
            if composerStyle.showsTopDivider {
                Divider().overlay(Theme.border)
            }
            HStack(alignment: .bottom, spacing: 10) {
                if chatViewModel.backendCapabilities.supportsAttachments {
                    attachButton
                }
                inputField
                    .frame(maxWidth: .infinity, alignment: .leading)
                voiceButton
                sendButton
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .frame(maxWidth: 760)
        .composerContainer(composerStyle)
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
        #else
        VStack(spacing: 0) {
            // Attached skills chips
            if !chatViewModel.activeSkills.isEmpty {
                attachedSkillsChips
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
            }
            // Attachment preview strip above input
            if !chatViewModel.pendingAttachments.isEmpty {
                attachmentPreviewStrip
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
            }
            if composerStyle.showsTopDivider {
                Divider().overlay(Theme.border)
            }
            HStack(alignment: .bottom, spacing: 10) {
                if chatViewModel.backendCapabilities.supportsAttachments {
                    attachButton
                }
                inputField
                voiceButton
                sendButton
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            // Card/pill draw their own fill; minimal falls back to the system
            // bar material so the row stays legible over content.
            .background(composerStyle.fill == nil ? AnyShapeStyle(.bar) : AnyShapeStyle(Color.clear))
            .composerContainer(composerStyle)
        }
        #endif
    }

    // MARK: - Attached Skills Chips

    private var attachedSkillsChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(chatViewModel.activeSkills) { skill in
                    HStack(spacing: 4) {
                        Text(skill.slashCommand)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Theme.accent)
                        Button {
                            chatViewModel.detachSkill(named: skill.name)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(Theme.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.accent.opacity(0.10), in: Capsule())
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Attachment Preview Strip

    private var attachmentPreviewStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chatViewModel.pendingAttachments) { attachment in
                    PendingAttachmentThumbnail(
                        attachment: attachment,
                        onRemove: {
                            chatViewModel.removeAttachment(attachment)
                        }
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Attach Button

    private var attachButton: some View {
        #if os(macOS)
        Button {
            showMacFilePicker()
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .frame(width: 28, height: 28)
                .background(Theme.surfaceHover, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Attach file")
        .accessibilityIdentifier("attachFileButton")
        .help("Attach a file to your message")
        #else
        Menu {
            PhotosPicker(
                "Photo Library",
                selection: $selectedPhotosPickerItems,
                maxSelectionCount: 5,
                matching: .images
            )
            Button("Choose File") {
                showiOSDocumentPicker()
            }
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .frame(width: 28, height: 28)
                .background(Theme.surfaceHover, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Attach file")
        .accessibilityIdentifier("attachFileButton")
        .onChange(of: selectedPhotosPickerItems) { _, newItems in
            handlePhotosPickerItems(newItems)
            selectedPhotosPickerItems = []
        }
        #endif
    }

    // MARK: - Input Field

    private var inputField: some View {
        #if os(macOS)
        ZStack(alignment: .topLeading) {
            MacInputTextField(
                text: $chatViewModel.inputText,
                placeholder: "Message \(displayPersona.name)…",
                isFocused: isFocused,
                fieldRef: $inputFieldRef,
                onSubmit: { Task { await chatViewModel.submitPrompt() } },
                onImagePaste: { providers in handlePaste(providers: providers) },
                onTextChange: { text in
                    chatViewModel.inputText = text
                    chatViewModel.updateSlashSuggestions()
                },
                onNavigateUp: chatViewModel.slashMode ? { chatViewModel.navigateSlashUp() } : nil,
                onNavigateDown: chatViewModel.slashMode ? { chatViewModel.navigateSlashDown() } : nil,
                onConfirm: chatViewModel.slashMode ? { chatViewModel.confirmSlashSelection() } : nil
            )
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)

            if chatViewModel.slashMode {
                slashAutocompleteOverlay
                    .offset(y: -236)
            }
        }
        .onChange(of: chatViewModel.inputText) { _, _ in
            chatViewModel.updateSlashSuggestions()
        }
        #else
        TextField("Message \(displayPersona.name)…", text: $chatViewModel.inputText, axis: .vertical)
            .accessibilityIdentifier("chatInput")
            .textFieldStyle(.plain)
            .font(.body)
            .lineLimit(1...8)
            .focused($isInputFocused)
            .onSubmit {
                Task { await chatViewModel.submitPrompt() }
            }
            .onChange(of: chatViewModel.inputText) { _, newValue in
                chatViewModel.updateSlashSuggestions()
            }
            .overlay(alignment: .bottom) {
                if chatViewModel.slashMode {
                    slashAutocompleteOverlay
                }
            }
        #endif
    }

    // MARK: - Slash Autocomplete Overlay

    private var slashAutocompleteOverlay: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: true) {
                    VStack(spacing: 0) {
                        ForEach(Array(chatViewModel.slashSuggestions.enumerated()), id: \.element.id) { idx, skill in
                            Button {
                                chatViewModel.slashSelectedIndex = idx
                                chatViewModel.confirmSlashSelection()
                            } label: {
                                HStack(spacing: 8) {
                                    Text(skill.slashCommand)
                                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                        .monospaced()
                                        .foregroundStyle(Theme.accent)
                                    Text(skill.name)
                                        .font(.system(size: 13))
                                        .foregroundStyle(Theme.primary)
                                    Spacer()
                                    if !skill.description.isEmpty {
                                        Text(skill.description)
                                            .font(.caption2)
                                            .foregroundStyle(Theme.tertiary)
                                            .lineLimit(1)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .background(idx == chatViewModel.slashSelectedIndex ? Theme.accent.opacity(0.15) : Color.clear)
                            .id(idx)
                            if idx < chatViewModel.slashSuggestions.count - 1 {
                                Divider().background(Theme.border)
                            }
                        }
                    }
                }
                .frame(maxHeight: 300)
                .onChange(of: chatViewModel.slashSelectedIndex) { _, newIdx in
                    withAnimation {
                        proxy.scrollTo(newIdx, anchor: .center)
                    }
                }
            }
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 4)
    }

    // MARK: - Voice Button

    /// Walkie-talkie mic button. Taps toggle VAD recording on/off.
    /// While recording, the gateway captures speech via faster-whisper and
    /// emits `voice.transcript` events, which ChatViewModel auto-submits.
    private var voiceButton: some View {
        guard chatViewModel.backendCapabilities.supportsVoice else {
            return AnyView(EmptyView())
        }
        let isRecording = chatViewModel.isVoiceRecording
        let isIdle = !chatViewModel.isStreaming && !isRecording
        return AnyView(Button {
            Task {
                if isRecording {
                    await chatViewModel.stopVoiceRecording()
                } else {
                    await chatViewModel.startVoiceRecording()
                }
            }
        } label: {
            Image(systemName: isRecording ? "mic.fill" : "mic")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isRecording ? .white : Theme.secondary)
                .frame(width: 30, height: 30)
                .background(
                    isRecording
                        ? Color.red
                        : (isIdle ? Theme.surfaceHover : Color.clear),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRecording ? "Stop recording" : "Voice input")
        .accessibilityIdentifier("voiceButton")
        .help(isRecording ? "Stop voice recording" : "Start voice recording (walkie-talkie)")
        .opacity(chatViewModel.isStreaming ? 0.3 : 1)
        .disabled(chatViewModel.isStreaming)
        .animation(.easeInOut(duration: 0.18), value: isRecording))
    }

    // MARK: - Send / Stop Button

    /// The composer's primary action. While streaming it becomes a Stop button
    /// so the user can interrupt right where they're typing, instead of reaching
    /// for the Stop control at the top of the screen. Otherwise it sends.
    private var sendButton: some View {
        Group {
            if chatViewModel.isStreaming {
                Button {
                    Task { await chatViewModel.interrupt() }
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Color.red, in: Circle())
                }
                .accessibilityLabel("Stop")
                .accessibilityIdentifier("composerStopButton")
                .help("Stop the current response")
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            } else {
                Button {
                    Task { await chatViewModel.submitPrompt() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(isSendDisabled ? Theme.tertiary : Theme.primary)
                        .frame(width: 30, height: 30)
                        .background(isSendDisabled ? Theme.surfaceHover : Theme.accent, in: Circle())
                }
                .accessibilityLabel("Send")
                .accessibilityIdentifier("sendButton")
                .disabled(isSendDisabled)
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: chatViewModel.isStreaming)
    }

    // MARK: - macOS File Picker

    #if os(macOS)
    private func showMacFilePicker() {
        let panel = NSOpenPanel()
        panel.title = "Select Files"
        panel.allowedContentTypes = [.item]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            let cachedPath = Self.copyToCache(url: url)
            guard !cachedPath.isEmpty else { continue }
            chatViewModel.addAttachment(path: cachedPath)
        }
    }
    #endif

    // MARK: - iOS Document Picker

    #if os(iOS)
    @MainActor
    private func showiOSDocumentPicker() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = scene.windows.first?.rootViewController else { return }

        let docPicker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        docPicker.allowsMultipleSelection = true
        docPicker.delegate = DocumentPickerDelegate.shared

        DocumentPickerDelegate.shared.onSelect = { urls in
            for url in urls {
                let cachedPath = Self.copyToCache(url: url)
                guard !cachedPath.isEmpty else { continue }
                chatViewModel.addAttachment(path: cachedPath)
            }
        }

        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        topVC.present(docPicker, animated: true)
    }
    #endif

    // MARK: - iOS Photos Picker Handler

    #if os(iOS)
    private func handlePhotosPickerItems(_ items: [PhotosPickerItem]) {
        for item in items {
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                let cachedPath = Self.saveImageDataToCache(data: data, ext: "png")
                await MainActor.run {
                    chatViewModel.addAttachment(path: cachedPath)
                }
            }
        }
    }
    #endif

    // MARK: - Paste Handler (macOS)

    #if os(macOS)
    private func handlePaste(providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, _ in
                    if let url = item as? URL {
                        let cachedPath = Self.copyToCache(url: url)
                        guard !cachedPath.isEmpty else { return }
                        Task { @MainActor in
                            chatViewModel.addAttachment(path: cachedPath)
                        }
                    } else if let data = item as? Data {
                        let cachedPath = Self.saveImageDataToCache(data: data, ext: "png")
                        guard !cachedPath.isEmpty else { return }
                        Task { @MainActor in
                            chatViewModel.addAttachment(path: cachedPath)
                        }
                    } else if let nsImage = item as? NSImage,
                              let tiffData = nsImage.tiffRepresentation,
                              let bitmapRep = NSBitmapImageRep(data: tiffData),
                              let pngData = bitmapRep.representation(using: .png, properties: [:]) {
                        let cachedPath = Self.saveImageDataToCache(data: pngData, ext: "png")
                        guard !cachedPath.isEmpty else { return }
                        Task { @MainActor in
                            chatViewModel.addAttachment(path: cachedPath)
                        }
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                            if let url = item as? URL {
                                let cachedPath = Self.copyToCache(url: url)
                                guard !cachedPath.isEmpty else { return }
                                Task { @MainActor in
                                    chatViewModel.addAttachment(path: cachedPath)
                                }
                            }
                        }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let url = item as? URL {
                        // Accept any file type — documents are extracted/uploaded
                        // by ChatViewModel.ingestAttachment, not just images.
                        let cachedPath = Self.copyToCache(url: url)
                        guard !cachedPath.isEmpty else { return }
                        Task { @MainActor in
                            chatViewModel.addAttachment(path: cachedPath)
                        }
                    }
                }
            }
        }
    }
    #endif

    // MARK: - Drop Handler

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, _ in
                    if let url = item as? URL {
                        let cachedPath = Self.copyToCache(url: url)
                        guard !cachedPath.isEmpty else { return }
                        Task { @MainActor in
                            chatViewModel.addAttachment(path: cachedPath)
                        }
                    } else if let data = item as? Data {
                        let cachedPath = Self.saveImageDataToCache(data: data, ext: "png")
                        guard !cachedPath.isEmpty else { return }
                        Task { @MainActor in
                            chatViewModel.addAttachment(path: cachedPath)
                        }
                    }
                    #if os(macOS)
                    if let nsImage = item as? NSImage,
                       let tiffData = nsImage.tiffRepresentation,
                       let bitmapRep = NSBitmapImageRep(data: tiffData),
                       let pngData = bitmapRep.representation(using: .png, properties: [:]) {
                        let cachedPath = Self.saveImageDataToCache(data: pngData, ext: "png")
                        guard !cachedPath.isEmpty else { return }
                        Task { @MainActor in
                            chatViewModel.addAttachment(path: cachedPath)
                        }
                    }
                    #endif
                    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                            if let url = item as? URL {
                                let cachedPath = Self.copyToCache(url: url)
                                guard !cachedPath.isEmpty else { return }
                                Task { @MainActor in
                                    chatViewModel.addAttachment(path: cachedPath)
                                }
                            }
                        }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let url = item as? URL {
                        // Accept any dropped file type — documents are handled
                        // downstream, not just images.
                        let cachedPath = Self.copyToCache(url: url)
                        guard !cachedPath.isEmpty else { return }
                        Task { @MainActor in
                            chatViewModel.addAttachment(path: cachedPath)
                        }
                    }
                }
            }
        }
        return handled
    }

    // MARK: - Cache Helpers

    /// Directory for cached user-sent images.
    private static var gatewayImagesDir: String {
        let home = NSHomeDirectory()
        let dir = "\(home)/.hermes/images"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Copy a file URL into the hermes images cache, returning the cached path.
    private static func copyToCache(url: URL) -> String {
        let dir = gatewayImagesDir
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let fileName = "\(UUID().uuidString).\(ext)"
        let dest = "\(dir)/\(fileName)"
        do {
            try FileManager.default.copyItem(atPath: url.path, toPath: dest)
            return dest
        } catch {
            os_log(.error, "Failed to copy file to cache: %{public}@ -> %{public}@: %{public}@",
                   url.path, dest, error.localizedDescription)
            return url.path
        }
    }

    private static func saveImageDataToCache(data: Data, ext: String) -> String {
        let dir = gatewayImagesDir
        let fileName = "\(UUID().uuidString).\(ext)"
        let dest = "\(dir)/\(fileName)"
        do {
            try data.write(to: URL(fileURLWithPath: dest))
            return dest
        } catch {
            os_log(.error, "Failed to save image data to cache %{public}@: %{public}@",
                   dest, error.localizedDescription)
            return ""
        }
    }
}

// MARK: - Pending Attachment Thumbnail

private struct PendingAttachmentThumbnail: View {
    let attachment: MediaAttachment
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Thumbnail
            ThumbnailImageView(data: attachment.thumbnailData, fallbackIcon: attachment.category.icon)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.border, lineWidth: 0.5)
                )

            // Remove button
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.primary)
                    .background(Circle().fill(Theme.surface).opacity(0.8))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
        }
    }
}

// MARK: - iOS Document Picker Delegate

#if os(iOS)
final class DocumentPickerDelegate: NSObject, UIDocumentPickerDelegate {
    static let shared = DocumentPickerDelegate()
    var onSelect: ([URL]) -> Void = { _ in }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        onSelect(urls)
    }
}
#endif

// MARK: - Debug Log Panel

struct DebugLogPanel: View {
    @ObservedObject var wrapper: GatewayClientWrapper

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(wrapper.log) { entry in
                        Text(entry.text)
                            .font(.system(.caption2, design: .monospaced))
                            .monospaced()
                            .foregroundStyle(entry.isError ? .red : .secondary)
                            .id(entry.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .onChange(of: wrapper.log.count) { _, _ in
                if let last = wrapper.log.last {
                    proxy.scrollTo(last.id)
                }
            }
        }
    }
}

/// Banner for a blocking clarify.request: the agent thread is parked on the
/// gateway until clarify.respond arrives (or its 300s timeout lapses), so
/// this must always be answerable — choice chips when the agent offered
/// options, free-text otherwise, and Skip to release the agent immediately.
struct ClarifyBanner: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    @State private var answerText = ""

    var body: some View {
        if let clarify = chatViewModel.pendingClarify {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.bubble.fill")
                        .foregroundStyle(Theme.accent)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Agent Question")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text(clarify.question)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                            .textSelection(.enabled)
                    }

                    Spacer()

                    Button("Skip") {
                        Task { await chatViewModel.respondClarify(answer: "") }
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                    .help("Continue without answering")
                }

                if clarify.choices.isEmpty {
                    HStack(spacing: 6) {
                        TextField("Type your answer…", text: $answerText)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                            .onSubmit { submitText() }

                        Button("Answer") { submitText() }
                            .portalButton(prominent: true, size: .small, tint: Theme.accent)
                            .disabled(answerText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } else {
                    // Choice chips — wraps on narrow widths
                    FlowLayoutCompat(spacing: 6) {
                        ForEach(clarify.choices, id: \.self) { choice in
                            Button(choice) {
                                Task { await chatViewModel.respondClarify(answer: choice) }
                            }
                            .portalButton(size: .small, tint: Theme.accent)
                        }
                    }
                }
            }
            .padding(10)
            .background(Theme.accent.opacity(0.08))
            .onDisappear { answerText = "" }
        }
    }

    private func submitText() {
        let answer = answerText.trimmingCharacters(in: .whitespaces)
        guard !answer.isEmpty else { return }
        answerText = ""
        Task { await chatViewModel.respondClarify(answer: answer) }
    }
}

/// Minimal wrapping HStack for clarify choice chips.
struct FlowLayoutCompat: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Message grouping helpers

extension ChatView {
    /// Whether `message` ends a run of consecutive same-role messages — the
    /// boundary that earns a timestamp.
    ///
    /// Takes the position rather than searching for it. The searching version
    /// did `msgs.firstIndex(where:)` per row, and every caller is a `ForEach`
    /// body, so rendering N messages cost N² id comparisons — repeated on every
    /// layout pass, not once per change. On a long transcript that pinned the
    /// main thread at 100% and beachballed the window.
    ///
    /// - Parameter index: `message`'s position in `msgs`. Out-of-range reads as
    ///   a boundary, matching what the old not-found branch did: a stray
    ///   timestamp is a cosmetic slip, a missing one hides when a turn happened.
    internal static func isLastMessageInGroup(at index: Int, in msgs: [ChatMessage]) -> Bool {
        guard msgs.indices.contains(index) else { return true }
        let nextIdx = index + 1
        guard nextIdx < msgs.count else {
            return true // last message overall
        }
        return msgs[nextIdx].role != msgs[index].role
    }

    /// Group boundaries for a whole list, as a set of the ids that end a run.
    ///
    /// For callers rendering every message: one O(N) pass, then O(1) per row.
    /// A set of ids rather than indices so a `ForEach` over the elements can ask
    /// without tracking positions — the shape that made the old helper quadratic.
    internal static func lastInGroupIDs(_ msgs: [ChatMessage]) -> Set<UUID> {
        var ids: Set<UUID> = []
        for (index, message) in msgs.enumerated()
        where index + 1 >= msgs.count || msgs[index + 1].role != message.role {
            ids.insert(message.id)
        }
        return ids
    }

    /// Creates a variant of `message` with avatar hidden and timestamp set for bubble rendering.
    static func prepareBubbleMessage(_ message: ChatMessage, showTimestamp: Bool) -> ChatMessage {
        var m = message
        m.showAvatar = false
        m.showTimestamp = showTimestamp
        return m
    }
}

// MARK: - Keyboard Dismissal (iOS)

#if os(iOS)
private func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}
#endif

// MARK: - Error Banner

private struct ErrorBannerView: View {
    let error: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
            Text(error)
                .font(.caption2)
                .foregroundStyle(.red.opacity(0.9))
                .lineLimit(2)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.red.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 24)
        .padding(.bottom, 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
