import SwiftUI

/// Full-screen takeover showing a single artifact. The title/revision chrome and
/// maintenance details collapse independently so document-style renderers can
/// use almost the entire artifact surface.
internal struct ArtifactExpandedOverlay: View {
    internal let artifact: LivingArtifact
    internal let onDismiss: () -> Void

    @EnvironmentObject private var gatewayClientWrapper: GatewayClientWrapper
    @EnvironmentObject private var capabilitiesStore: GatewayCapabilitiesStore
    @ObservedObject private var store = ArtifactStore.shared
    @State private var cronVM = CronListViewModel()
    // Viewing preferences, not per-artifact data. Persist them so an immersive
    // layout stays immersive when another artifact is opened.
    @AppStorage("artifactExpandedShowsTitleBar") private var showsTitleBar = true
    @AppStorage("artifactExpandedShowsMaintenance") private var showsMaintenance = true
    /// True while an interactive HTML canvas holds Pointer Lock. SwiftUI's
    /// key-equivalent handling runs BEFORE the web view sees the key, so a
    /// bare-Escape shortcut here would collapse the whole artifact on the very
    /// press that was meant to release the mouse. While locked, the shortcut
    /// is detached and Escape falls through to WebKit's standard release.
    @State private var pageHoldsPointer = false

    internal init(artifact: LivingArtifact, onDismiss: @escaping () -> Void) {
        self.artifact = artifact
        self.onDismiss = onDismiss
    }

    internal var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                if showsTitleBar {
                    titleBar
                    Divider().overlay(Theme.border)
                }
                expandedContent
            }

            // Never strand the user when the normal title bar is hidden. This
            // cluster floats over the renderer instead of consuming its height.
            if !showsTitleBar {
                collapsedControls
                    .padding(8)
            }
        }
        .background(Theme.background)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await refreshCrons() }
    }

    private var titleBar: some View {
        HStack(spacing: 10) {
            Image(systemName: ArtifactsPane.icon(for: artifact.kind))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(artifact.displayName)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
            if artifact.rev > 0 {
                Text("r\(artifact.rev)")
                    .font(.system(size: 10, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(Theme.tertiary)
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    showsMaintenance.toggle()
                }
            } label: {
                Label(
                    showsMaintenance ? "Hide Maintenance" : "Show Maintenance",
                    systemImage: showsMaintenance ? "wrench.and.screwdriver.fill" : "wrench.and.screwdriver"
                )
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(showsMaintenance ? Theme.accent : Theme.secondary)
            }
            .buttonStyle(.plain)
            .help(showsMaintenance ? "Collapse maintenance" : "Show maintenance")

            if supportsImmersiveFullscreen {
                Button(action: enterImmersiveFullscreen) {
                    Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .help("Open in native full screen with mouse & keyboard capture")
            }

            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    showsTitleBar = false
                }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: titleBarControlSize, height: titleBarControlSize)
                    .background(Theme.surfaceHover, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Hide title and revision bar")

            dismissButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Theme.surface)
    }

    private var collapsedControls: some View {
        HStack(spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    showsTitleBar = true
                }
            } label: {
                Image(systemName: "chevron.down")
                    .frame(width: collapsedControlSize, height: collapsedControlSize)
            }
            .help("Show title and revision bar")

            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    showsMaintenance.toggle()
                }
            } label: {
                Image(systemName: showsMaintenance ? "wrench.and.screwdriver.fill" : "wrench.and.screwdriver")
                    .foregroundStyle(showsMaintenance ? Theme.accent : Theme.secondary)
                    .frame(width: collapsedControlSize, height: collapsedControlSize)
            }
            .help(showsMaintenance ? "Collapse maintenance" : "Show maintenance")

            if supportsImmersiveFullscreen {
                Button(action: enterImmersiveFullscreen) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .foregroundStyle(Theme.accent)
                        .frame(width: collapsedControlSize, height: collapsedControlSize)
                }
                .help("Open in native full screen with mouse & keyboard capture")
            }

            dismissButton
        }
        .font(.system(size: 10, weight: .bold))
        .buttonStyle(.plain)
        .foregroundStyle(Theme.secondary)
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Theme.border.opacity(0.7), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.tertiary)
                .frame(width: titleBarControlSize, height: titleBarControlSize)
                .background(Theme.surfaceHover, in: Circle())
        }
        .buttonStyle(.plain)
        // Two-stage Escape: while the page owns the cursor the first press
        // must reach WebKit (release the lock); only an unlocked Escape
        // collapses the artifact.
        .keyboardShortcut(pageHoldsPointer ? nil : KeyboardShortcut(.escape, modifiers: []))
        .help("Collapse artifact")
    }

    private var titleBarControlSize: CGFloat {
        #if os(iOS)
        44
        #else
        28
        #endif
    }

    private var collapsedControlSize: CGFloat {
        #if os(iOS)
        44
        #else
        26
        #endif
    }

    @ViewBuilder
    private var expandedContent: some View {
        if ArtifactKindRenderer.kindFillsHeight(artifact.kind) {
            VStack(alignment: .leading, spacing: 0) {
                if showsMaintenance {
                    maintenanceSection
                        .padding(20)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                liveRenderer
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if showsMaintenance {
                        maintenanceSection
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    liveRenderer
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var maintenanceSection: some View {
        ArtifactMaintenanceSection(artifact: artifact, jobs: cronVM.jobs)
            .overlay(alignment: .topTrailing) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showsMaintenance = false
                    }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.tertiary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Collapse maintenance")
                .padding(5)
            }
    }

    private var liveRenderer: some View {
        let content = store.artifacts[artifact.id]?.content ?? artifact.content
        return ArtifactKindRenderer(
            kind: artifact.kind,
            content: content,
            actionableArtifactID: artifact.id,
            topLevelActions: artifact.topLevelActions,
            // Capture is the renderer's own call now (derived from the document),
            // so this presentation only has to say where a lock lands: Escape
            // releases the mouse before it collapses the artifact.
            onPointerLockChange: { pageHoldsPointer = $0 }
        )
    }

    /// Web-backed interactive kinds (html, model3d) are the ones that benefit
    /// from native fullscreen + Pointer Lock; document kinds stay in-app.
    private var supportsImmersiveFullscreen: Bool {
        #if os(macOS)
        InteractiveArtifactWeb.supportsImmersiveFullscreen(artifact.kind)
        #else
        false
        #endif
    }

    private func enterImmersiveFullscreen() {
        #if os(macOS)
        let live = store.artifacts[artifact.id] ?? artifact
        let content = live.content
        guard let html = InteractiveArtifactWeb.immersiveHTML(kind: artifact.kind, content: content) else { return }
        ArtifactFullscreenWindowController.shared.present(
            html: html,
            title: artifact.displayName,
            autoCapturesPointer: InteractiveArtifactWeb.autoCapturesPointer(
                kind: artifact.kind, content: content),
            // The live artifact's declared intents follow it into the immersive
            // window, so entering fullscreen no longer kills its bindings.
            intents: ArtifactFullscreenIntentContext.make(
                kind: artifact.kind,
                supportsArtifactActions: capabilitiesStore.capabilities.supportsArtifactActions,
                artifactID: artifact.id,
                actions: live.topLevelActions
            )
        )
        #endif
    }

    private func refreshCrons() async {
        cronVM.setGatewayClient(gatewayClientWrapper.client)
        await cronVM.refreshJobs()
        if capabilitiesStore.capabilities.supportsActionLog {
            store.rehydrateBadges(for: artifact.id)
        }
    }
}
