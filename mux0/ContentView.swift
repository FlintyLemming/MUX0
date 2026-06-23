import SwiftUI
import AppKit

struct ContentView: View {
    @State private var store = WorkspaceStore()
    @State private var statusStore = TerminalStatusStore()
    @State private var pwdStore = TerminalPwdStore()
    @State private var sessionTitleStore = TerminalSessionTitleStore()
    @State private var settingsStore: SettingsConfigStore
    @State private var quickActionsStore: QuickActionsStore
    @State private var sidebarCollapsed: Bool = false
    @State private var showSettings: Bool = false
    /// 当前 ContentView 宿主窗口。用于过滤 NSWindow 全屏通知——
    /// `NotificationCenter.publisher(for:)` 不带 `object:` 时会收到所有窗口的
    /// 通知，多窗口下窗口 A 进全屏会误伤窗口 B 的透明度。
    @State private var hostWindow: NSWindow?
    /// 当前宿主窗口是否全屏（per-window）。ThemeManager 是 app 级单例、多窗口
    /// 共享，无法持有 per-window 状态，故全屏标志下放到这里。全屏时所有 opacity
    /// 在视图层覆盖为 1.0，避免半透明层叠在 macOS 全屏纯黑背景上显灰。
    @State private var isFullScreen: Bool = false
    @State private var hookListener: HookSocketListener?
    @State private var updateStore = UpdateStore(
        currentVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    )
    @State private var pendingSettingsSection: SettingsSection?
    @State private var didScheduleLaunchUpdateCheck: Bool = false
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LanguageStore.self) private var languageStore
    @Environment(\.locale) private var locale

    init() {
        let settings = SettingsConfigStore()
        self._settingsStore = State(initialValue: settings)
        self._quickActionsStore = State(initialValue: QuickActionsStore(settings: settings))
    }

    private let trafficLightInset: CGFloat = 28
    private let cardInset: CGFloat = 8
    private let cardRadius: CGFloat = DT.Radius.card
    /// 顶部一对按钮（toggle 在左、"+"" 在右）容器 leading：
    /// 让"+"按钮中心仍与 sidebar row 状态图标列对齐 = sidebarWidth - 25；
    /// 容器起点 = (sidebarWidth - 25) - 11 - (按钮宽 22 + xs 间距 4) = sidebarWidth - 62。
    /// 这样 toggle 相对原位置向左挪了一格，"+"接管原 toggle 的图标列轴线。
    private let headerControlsLeading: CGFloat = DT.Layout.sidebarWidth - 25 - 11 - (22 + DT.Space.xs)
    /// 内容卡片顶部内距。顶部 28pt 空白带撤掉后，tab 栏上移到这里，与顶部控件同排。
    private let contentTopInset: CGFloat = DT.Space.xs
    /// IconButton 固定边长（见 IconButton）。
    private let iconButtonSize: CGFloat = 22
    /// 折叠态品牌 + 齿轮簇的容器宽度（右对齐用，给定一个够宽的盒子，品牌串变长只向左伸）。
    private let collapsedBrandClusterWidth: CGFloat = 120
    /// 顶部控件（toggle / 品牌 / 齿轮）顶部内距：让 22pt 控件与上移后的 tab 栏 pill 垂直居中。
    /// pill 中心 = contentTopInset + tab 栏内缩(xs) + 高度/2。
    private var headerControlsTop: CGFloat {
        contentTopInset + DT.Space.xs + (TabBarView.height - iconButtonSize) / 2
    }
    /// 折叠态 toggle 的 leading：右缘紧贴 tab 栏左缘（留 xs 间隙）。tab 栏左缘 window-x
    /// = sidebarWidth + xs（见 TabContentView.tabStripLeadingWindowX）。
    private var collapsedToggleLeading: CGFloat {
        DT.Layout.sidebarWidth - iconButtonSize
    }

    /// Master UI gate for the sidebar + tab bar status icons. True iff the user
    /// has enabled at least one agent in Settings → Agents; false collapses the
    /// icon column in the sidebar row and tab bar item layout.
    private var showStatusIndicators: Bool {
        StatusIndicatorGate.anyAgentEnabled(settingsStore)
    }

    /// UUIDs of all terminals currently rendered on-screen: every descendant
    /// of the selected tab's split tree in the selected workspace. Empty when
    /// nothing is selected (app start before a workspace exists).
    private var visibleTerminalIds: [UUID] {
        guard let ws = store.selectedWorkspace,
              let tab = ws.selectedTab else { return [] }
        return tab.layout.allTerminalIds()
    }

    var body: some View {
        let bgOpacity = isFullScreen ? 1.0 : themeManager.backgroundOpacity
        // 中间内容区（卡片 canvas、paneContainer、tab strip、Settings 各层等）都走
        // 这个乘过 contentOpacity 的 effective 值，让用户可以在保持 sidebar 透明度
        // 不变的前提下，单独把中心多层叠加的浓度再降一档。全屏时强制 1.0。
        let contentBg = isFullScreen ? 1.0 : themeManager.contentEffectiveOpacity
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                if !sidebarCollapsed {
                    SidebarView(
                        store: store,
                        statusStore: statusStore,
                        pwdStore: pwdStore,
                        theme: themeManager.theme,
                        backgroundOpacity: bgOpacity,
                        showStatusIndicators: showStatusIndicators,
                        updateStore: updateStore
                    )
                    .padding(.top, trafficLightInset)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }

                ZStack {
                    // TabBridge 常驻挂载：进入设置只是把它 z-order 压到底层并关交互，
                    // 避免 NSViewRepresentable 被 dismantle 导致 ghostty surface 释放。
                    TabBridge(
                        store: store,
                        statusStore: statusStore,
                        pwdStore: pwdStore,
                        sessionTitleStore: sessionTitleStore,
                        settings: settingsStore,
                        quickActionsStore: quickActionsStore,
                        theme: themeManager.theme,
                        backgroundOpacity: contentBg,
                        showStatusIndicators: showStatusIndicators,
                        languageTick: languageStore.tick
                    )
                    .opacity(showSettings ? 0 : 1)
                    .allowsHitTesting(!showSettings)

                    if showSettings {
                        SettingsView(
                            theme: themeManager.theme,
                            settings: settingsStore,
                            updateStore: updateStore,
                            workspaceStore: store,
                            quickActionsStore: quickActionsStore,
                            initialSection: pendingSettingsSection,
                            onClose: { showSettings = false }
                        )
                    }
                }
                .background(Color(themeManager.theme.canvas).opacity(contentBg))
                .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
                .overlay {
                    // 浅边框：颜色取 theme.border，alpha 随 contentShadowIntensity 线性缩放。
                    // 强度 = 0 时彻底不画（避免在透明背景上叠出 0 alpha 描边的 hairline 噪点）。
                    let intensity = themeManager.contentShadowIntensity
                    if intensity > 0 {
                        RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                            .strokeBorder(
                                Color(themeManager.theme.border).opacity(Double(intensity) * 0.6),
                                lineWidth: DT.Stroke.hairline
                            )
                    }
                }
                .shadow(
                    color: .black.opacity(Double(themeManager.contentShadowIntensity) * 0.18),
                    radius: 6 + themeManager.contentShadowIntensity * 6,
                    x: 0,
                    y: 2
                )
                .padding(.top, contentTopInset)
                .padding(.leading, sidebarCollapsed ? cardInset : 0)
                .padding(.trailing, cardInset)
                .padding(.bottom, cardInset)
            }

            // 顶部控件：toggle 常驻，随折叠状态在 leading 之间滑动。展开时其右侧是
            // 「新建 workspace」+；折叠时其左侧渐显品牌名 + 设置齿轮（从 sidebar footer
            // 上移），右对齐到 toggle 左缘，品牌串变长只向左伸、不会顶到 toggle / tab 栏。
            sidebarToggleButton
                .padding(.leading, sidebarCollapsed ? collapsedToggleLeading : headerControlsLeading)
                .padding(.top, headerControlsTop)

            if !sidebarCollapsed {
                addWorkspaceButton
                    .padding(.leading, headerControlsLeading + iconButtonSize + DT.Space.xs)
                    .padding(.top, headerControlsTop)
                    .transition(.opacity)
            }

            if sidebarCollapsed {
                HStack(spacing: DT.Space.xs) {
                    collapsedBrandButton
                    collapsedSettingsButton
                }
                .frame(width: collapsedBrandClusterWidth, alignment: .trailing)
                .padding(.leading, (collapsedToggleLeading - DT.Space.xs) - collapsedBrandClusterWidth)
                .padding(.top, headerControlsTop)
                .transition(.opacity)
            }
        }
        .frame(minWidth: 960, minHeight: 620)
        // 根背景用 sidebar 色作为窗口底色 —— sidebar 区不再额外叠一层，整个
        // 左半部 + 卡片圆角外 + 顶部 traffic light 带都是这单层 sidebar alpha，
        // 浓度一致、无缝；卡片区自己叠一层 canvas alpha，相对根层更浓一点，
        // 圆角因此依然可见。
        .background(Color(themeManager.theme.sidebar).opacity(bgOpacity))
        .ignoresSafeArea()
        .mux0FullSizeContent(
            backgroundOpacity: contentBg,
            blurRadius: themeManager.backgroundBlurRadius
        ) { window in
            // Hand the window pointer to ghostty after every configure so it can
            // (re-)install or tear down the macOS blur layer driven by the current
            // `background-blur-radius` config value.
            GhosttyBridge.shared.applyWindowBackgroundBlur(to: window)
            // 记住宿主窗口，供下方全屏通知回调过滤 object——不过滤的话窗口 A
            // 进全屏会把窗口 B 的 isFullScreen 也带成 true。
            let isFirstCapture = hostWindow == nil
            hostWindow = window
            // 首次拿到 window 时用其真实全屏状态兜底初始化：macOS 状态恢复可能
            // 在启动时直接把窗口还原为全屏，而此时不会发 willEnterFullScreen 通知，
            // 不兜底就会在全屏黑底上叠半透明层显出灰。只首次生效；之后交给
            // willEnter/didExit 通知，以保留刻意设计的进/退场时序（进场 willEnter
            // 在动画前、退场 didExit 在动画后），避免动画中 styleMask 还未更新时
            // 用 styleMask 同步把 isFullScreen 拉回错误值。
            if isFirstCapture {
                isFullScreen = window.styleMask.contains(.fullScreen)
            }
        }
        // 让整窗 NSAppearance 跟随 ghostty 主题亮度。SwiftUI 里的 LabeledContent
        // label、TextField 背景、Slider/Stepper/Picker 默认控件都依赖 NSAppearance
        // 解析颜色；系统外观是浅色但主题是深色时会出现"深灰文字在深蓝底上几乎看不见"
        // 的情况（尤其在 SettingsView 的 Form 里）。锁到 theme.isDark 后这些系统控件
        // 会跟主题一致。不影响 sidebar/tab bar —— 它们本来就读 theme token。
        .preferredColorScheme(themeManager.theme.isDark ? .dark : .light)
        // 把 per-window 的 effective content opacity 注入 environment，供
        // SettingsView / SettingsTabBarView / ThemedTextField / IconButton /
        // ThemePickerView 等直接读 contentEffectiveOpacity 的 SwiftUI 子视图使用。
        // 这些视图不经过 ContentView 的参数传递，只能通过 environment 拿到当前
        // 窗口的全屏覆盖结果——ThemeManager 是全局单例无法 per-window 返回。
        .environment(\.effectiveContentOpacity, contentBg)
        .onAppear {
            themeManager.loadFromGhosttyConfig()
            // ghostty 的 PWD action（OSC 7）回调在 main 上通知 pwdStore，sidebar
            // 的 MetadataRefresher 每 5s tick 从 pwdStore 读最新 cwd 跑 git。
            let pwdStoreRef = pwdStore
            GhosttyBridge.shared.onPwdChanged = { terminalId, pwd in
                pwdStoreRef.setPwd(pwd, for: terminalId)
            }
            applyUnfocusedOpacityFromSettings()
            // applyWindowEffectsFromSettings must run BEFORE reloadConfig so the
            // effective background-opacity it installs on GhosttyBridge is picked
            // up by the next buildConfig.
            applyWindowEffectsFromSettings()
            GhosttyBridge.shared.reloadConfig()
            // Settings edits (debounced 200ms) → push new config to ghostty app
            // + all live surfaces, then re-derive mux0 UI colors from the
            // updated ghostty config so sidebar / tab bar track the new theme.
            settingsStore.onChange = {
                applyWindowEffectsFromSettings()
                GhosttyBridge.shared.reloadConfig()
                themeManager.refresh()
                applyUnfocusedOpacityFromSettings()
            }
            // Inject the session title store into WorkspaceStore so rename-lock
            // cleanup can clear titles when a tab is closed or a terminal is split.
            store.sessionTitleStore = sessionTitleStore
            if hookListener == nil {
                let path = HookSocketListener.defaultPath
                do {
                    let listener = try HookSocketListener(path: path)
                    let store = self.statusStore
                    let settingsStoreRef = self.settingsStore
                    let workspaceStoreRef = self.store
                    let sessionTitleStoreRef = self.sessionTitleStore
                    listener.onMessage = { msg in
                        HookDispatcher.dispatch(msg,
                                                settings: settingsStoreRef,
                                                store: store,
                                                workspaceStore: workspaceStoreRef,
                                                sessionTitleStore: sessionTitleStoreRef)
                    }
                    try listener.start()
                    hookListener = listener
                } catch {
                    print("[mux0] Failed to start hook socket listener: \(error)")
                }
            }
            // Auto-update: wire SparkleBridge and schedule the silent launch check.
            // SparkleBridge.startUpdater is internally idempotent, but the 3 s delayed
            // Task is not — guard the schedule so a re-entry into .onAppear doesn't
            // stack multiple in-flight silent checks.
            SparkleBridge.shared.store = updateStore
            SparkleBridge.shared.start()
            if !didScheduleLaunchUpdateCheck {
                didScheduleLaunchUpdateCheck = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    SparkleBridge.shared.checkForUpdates(silently: true)
                }
            }
        }
        .onChange(of: store.workspaces) { _, workspaces in
            let live = Set(workspaces.flatMap { ws in
                ws.tabs.flatMap { $0.layout.allTerminalIds() }
            })
            for (id, _) in statusStore.statusesSnapshot() where !live.contains(id) {
                statusStore.forget(terminalId: id)
            }
            for (id, _) in pwdStore.pwdsSnapshot() where !live.contains(id) {
                pwdStore.forget(terminalId: id)
            }
        }
        .onChange(of: store.selectedId) { _, _ in
            if showSettings { showSettings = false }
            statusStore.markRead(terminalIds: visibleTerminalIds)
        }
        // Workspace is a struct — selectedTabId changes propagate through the
        // @Observable `workspaces` array mutation in WorkspaceStore.selectTab.
        // If Workspace ever becomes a class, re-verify this observation path.
        .onChange(of: store.selectedWorkspace?.selectedTabId) { _, _ in
            statusStore.markRead(terminalIds: visibleTerminalIds)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { note in
            // 只处理本视图宿主窗口的通知：NSWindow 全屏通知是 per-window 的，
            // 但 publisher(for:) 不带 object: 会收到所有窗口的事件。多窗口下若
            // 不过滤，窗口 A 进全屏会误把窗口 B 的 isFullScreen 置 true，导致 B
            // 被强制不透明。
            guard (note.object as? NSWindow) === hostWindow else { return }
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            guard (note.object as? NSWindow) === hostWindow else { return }
            isFullScreen = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .mux0OpenSettings)) { note in
            if let raw = note.userInfo?["section"] as? String,
               let section = SettingsSection(rawValue: raw) {
                pendingSettingsSection = section
            } else {
                // 无 section 参数（如 sidebar 齿轮点击）→ SettingsView 回落到默认 .appearance。
                pendingSettingsSection = nil
            }
            showSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .mux0EditConfigFile)) { _ in
            settingsStore.openInEditor()
        }
    }

    /// Read `unfocused-split-opacity` from the mux0 override config (default 0.7) and
    /// push it into GhosttyTerminalView so non-focused panes dim correctly.
    /// Called on appear and whenever settings change.
    private func applyUnfocusedOpacityFromSettings() {
        let raw = settingsStore.get("unfocused-split-opacity")
        let value = raw.flatMap { Double($0) } ?? 0.7
        GhosttyTerminalView.setUnfocusedOpacity(CGFloat(value))
    }

    /// Read `background-opacity` and `background-blur-radius` from the mux0 override
    /// and push them into ThemeManager. Blur is applied in the WindowAccessor
    /// configure callback on the next body pass — that's where we have the live
    /// NSWindow pointer. ghostty surface itself renders fully transparent
    /// (forced by GhosttyBridge); the visible "background" is the canvas color
    /// painted behind it, which already picks up these alphas.
    private func applyWindowEffectsFromSettings() {
        let opacityRaw = settingsStore.get("background-opacity")
        let opacity = CGFloat(opacityRaw.flatMap { Double($0) } ?? 1.0)
        let blurRaw = settingsStore.get("background-blur-radius")
        let blur = CGFloat(blurRaw.flatMap { Double($0) } ?? 0)
        let contentRaw = settingsStore.get("mux0-content-opacity")
        let content = CGFloat(contentRaw.flatMap { Double($0) } ?? 1.0)
        let shadowRaw = settingsStore.get("mux0-content-shadow")
        let shadow = CGFloat(shadowRaw.flatMap { Double($0) } ?? 0)
        themeManager.applyWindowEffects(opacity: opacity, blurRadius: blur, contentOpacity: content, contentShadow: shadow)
    }

    private var sidebarToggleButton: some View {
        IconButton(
            theme: themeManager.theme,
            help: String(localized: (sidebarCollapsed ? L10n.Sidebar.showSidebar : L10n.Sidebar.hideSidebar).withLocale(locale))
        ) {
            withAnimation(.easeInOut(duration: 0.2)) {
                sidebarCollapsed.toggle()
            }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(Color(themeManager.theme.textSecondary))
        }
    }

    /// 顶部"+"按钮：触发 SidebarView 监听的 mux0BeginCreateWorkspace 通知，
    /// 由 sidebar 内部计算默认名称并继承当前 pwd。仅在 sidebar 展开时显示——
    /// 收起时 SidebarView 不在视图树里，没人响应该通知。
    private var addWorkspaceButton: some View {
        IconButton(
            theme: themeManager.theme,
            help: String(localized: L10n.Sidebar.newWorkspace.withLocale(locale))
        ) {
            NotificationCenter.default.post(name: .mux0BeginCreateWorkspace, object: nil)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(Color(themeManager.theme.textSecondary))
        }
    }

    /// 折叠态顶部品牌按钮（从 sidebar footer 上移）：点击跳 Settings → Update。
    /// 有更新时右上角叠红点，复刻 footer 的更新提示。
    private var collapsedBrandButton: some View {
        Button {
            NotificationCenter.default.post(
                name: .mux0OpenSettings,
                object: nil,
                userInfo: ["section": "update"]
            )
        } label: {
            HStack(spacing: DT.Space.xs) {
                Text(L10n.Sidebar.title)
                    .font(Font(DT.Font.smallB))
                    .foregroundColor(Color(themeManager.theme.textPrimary))
                Text("v\(updateStore.currentVersion)")
                    .font(Font(DT.Font.small))
                    .foregroundColor(Color(themeManager.theme.textSecondary))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: L10n.Sidebar.checkForUpdates.withLocale(locale)))
        .onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .overlay(alignment: .topTrailing) {
            if updateStore.hasUpdate {
                Circle()
                    .fill(Color(themeManager.theme.danger))
                    .frame(width: 6, height: 6)
                    .offset(x: 5, y: -1)
                    .help(String(localized: L10n.Sidebar.updateAvailable.withLocale(locale)))
            }
        }
    }

    /// 折叠态顶部设置齿轮（从 sidebar footer 上移）。
    private var collapsedSettingsButton: some View {
        IconButton(
            theme: themeManager.theme,
            help: String(localized: L10n.Sidebar.settingsTooltip.withLocale(locale))
        ) {
            NotificationCenter.default.post(name: .mux0OpenSettings, object: nil)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(Color(themeManager.theme.textSecondary))
        }
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let mux0BeginCreateWorkspace = Notification.Name("mux0.beginCreateWorkspace")
    static let mux0NewTab               = Notification.Name("mux0.newTab")
    static let mux0ClosePane            = Notification.Name("mux0.closePane")
    static let mux0SplitVertical        = Notification.Name("mux0.splitVertical")
    static let mux0SplitHorizontal      = Notification.Name("mux0.splitHorizontal")
    static let mux0SelectNextTab        = Notification.Name("mux0.selectNextTab")
    static let mux0SelectPrevTab        = Notification.Name("mux0.selectPrevTab")
    static let mux0SelectTabAtIndex     = Notification.Name("mux0.selectTabAtIndex")
    static let mux0SelectWorkspaceAtIndex = Notification.Name("mux0.selectWorkspaceAtIndex")

    // Pane focus navigation (also bound in the "Terminal" menu).
    static let mux0FocusNextPane        = Notification.Name("mux0.focusNextPane")
    static let mux0FocusPrevPane        = Notification.Name("mux0.focusPrevPane")

    // 注：Edit > Copy / Paste / Select All 不走通知。⌘C/⌘V/⌘A 在 mux0App 的
    // pasteboard CommandGroup 里通过 NSApp.sendAction(_:to:nil) 沿 responder
    // chain 派发，命中 NSText（rename / 设置面板的 TextField）或终端
    // GhosttyTerminalView 的同名 selector。

    // Settings
    static let mux0OpenSettings         = Notification.Name("mux0.openSettings")
    static let mux0EditConfigFile       = Notification.Name("mux0.editConfigFile")

    /// Posted by the Agents → Notifications → Codex toggle when the user
    /// flips it ON, so the section view can present its experimental-flag
    /// alert. Routed via NotificationCenter (instead of an `onTurnOn`
    /// parameter) so every row in the ForEach has an identical view
    /// signature — Form(.grouped) splits a row out into its own card if
    /// any neighbour differs.
    static let mux0CodexHookAlert       = Notification.Name("mux0.codexHookAlert")
}

// MARK: - Per-window effective content opacity

private struct EffectiveContentOpacityKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    /// 当前窗口"中间内容层"实际使用的不透明度，已叠加 per-window 全屏覆盖。
    /// 由 ContentView 根据 `isFullScreen` 计算 `contentBg` 后注入，
    /// 供 SettingsView / IconButton / ThemedTextField / ThemePickerView 等
    /// 直接读 `themeManager.contentEffectiveOpacity` 的视图改读此值——
    /// 避免每个视图各自判断全屏，也避免全局 ThemeManager 单例污染多窗口。
    var effectiveContentOpacity: CGFloat {
        get { self[EffectiveContentOpacityKey.self] }
        set { self[EffectiveContentOpacityKey.self] = newValue }
    }
}
