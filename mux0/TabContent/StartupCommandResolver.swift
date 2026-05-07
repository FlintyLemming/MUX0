import Foundation

/// Pure resolver for the shell command auto-injected into a freshly created
/// ghostty surface. Mirrors the precedence rules previously inlined in
/// `TabContentView.resolvedStartupCommand(forTerminal:)`.
///
/// Source order:
///   0. Quick action tab's first terminal — return
///      `"<quickActionCommand>\n"` (built-in default or user override).
///   1. Pending agent resume command (`claude --resume <id>` /
///      `codex resume <id>` / `opencode --session <id>`) — only when the
///      matching agent's Resume toggle is on. Default OFF means stale
///      UserDefaults entries are ignored, not replayed.
///   2. Workspace-level `defaultCommand`.
///
/// Inputs are passed explicitly (rather than wiring up real stores) so the
/// resolver can be unit-tested without bringing up an NSView, WorkspaceStore,
/// SettingsConfigStore, or QuickActionsStore.
enum StartupCommandResolver {
    static func resolve(
        terminalId: UUID,
        tab: TerminalTab?,
        workspaceDefaultCommand: String?,
        quickActionCommand: (QuickActionId) -> String?,
        isResumeEnabled: (HookMessage.Agent) -> Bool,
        pendingPrefill: String?
    ) -> String? {
        // (0) Quick action tab's first terminal.
        if let tab,
           let actionId = tab.quickActionId,
           terminalId == tab.layout.allTerminalIds().first,
           let cmd = quickActionCommand(actionId) {
            return "\(cmd)\n"
        }

        // (1) Agent resume.
        if let pending = pendingPrefill,
           let agent = HookMessage.Agent.fromResumeCommand(pending),
           isResumeEnabled(agent) {
            return pending
        }

        // (2) Workspace default command.
        return workspaceDefaultCommand
    }
}
