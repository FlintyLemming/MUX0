import XCTest
@testable import mux0

final class StartupCommandResolverTests: XCTestCase {
    // MARK: - Quick Action branch (unchanged after Task 2)

    func testQuickActionGitui_returnsNakedCommand() {
        let term = UUID()
        let tab = TerminalTab(title: "T", terminalId: term, quickActionId: "gitui")
        let result = StartupCommandResolver.resolve(
            terminalId: term,
            tab: tab,
            workspaceDefaultCommand: "should-not-fire",
            quickActionCommand: { _ in "gitui" },
            isResumeEnabled: { _ in true },
            pendingPrefill: "claude --resume abc"  // ignored: gitui isn't an agent
        )
        XCTAssertEqual(result, "gitui\n")
    }

    func testQuickActionClaude_noPrefill_returnsNakedClaude() {
        let term = UUID()
        let tab = TerminalTab(title: "T", terminalId: term, quickActionId: "claude")
        let result = StartupCommandResolver.resolve(
            terminalId: term,
            tab: tab,
            workspaceDefaultCommand: nil,
            quickActionCommand: { _ in "claude" },
            isResumeEnabled: { _ in true },
            pendingPrefill: nil
        )
        XCTAssertEqual(result, "claude\n")
    }

    func testQuickActionClaude_toggleOff_returnsNakedClaude() {
        let term = UUID()
        let tab = TerminalTab(title: "T", terminalId: term, quickActionId: "claude")
        let result = StartupCommandResolver.resolve(
            terminalId: term,
            tab: tab,
            workspaceDefaultCommand: nil,
            quickActionCommand: { _ in "claude" },
            isResumeEnabled: { _ in false },
            pendingPrefill: "claude --resume abc"
        )
        XCTAssertEqual(result, "claude\n")
    }

    // MARK: - Naked terminal Agent resume branch (must not regress)

    func testNakedTerminal_resumeOn_returnsPrefill() {
        let term = UUID()
        let tab = TerminalTab(title: "T", terminalId: term, quickActionId: nil)
        let result = StartupCommandResolver.resolve(
            terminalId: term,
            tab: tab,
            workspaceDefaultCommand: "default-cmd",
            quickActionCommand: { _ in nil },
            isResumeEnabled: { _ in true },
            pendingPrefill: "claude --resume abc"
        )
        XCTAssertEqual(result, "claude --resume abc")
    }

    func testNakedTerminal_resumeOff_returnsDefaultCommand() {
        let term = UUID()
        let tab = TerminalTab(title: "T", terminalId: term, quickActionId: nil)
        let result = StartupCommandResolver.resolve(
            terminalId: term,
            tab: tab,
            workspaceDefaultCommand: "default-cmd",
            quickActionCommand: { _ in nil },
            isResumeEnabled: { _ in false },
            pendingPrefill: "claude --resume abc"
        )
        XCTAssertEqual(result, "default-cmd")
    }

    func testNakedTerminal_noPrefill_returnsDefaultCommand() {
        let term = UUID()
        let tab = TerminalTab(title: "T", terminalId: term, quickActionId: nil)
        let result = StartupCommandResolver.resolve(
            terminalId: term,
            tab: tab,
            workspaceDefaultCommand: "default-cmd",
            quickActionCommand: { _ in nil },
            isResumeEnabled: { _ in true },
            pendingPrefill: nil
        )
        XCTAssertEqual(result, "default-cmd")
    }

    func testNakedTerminal_noPrefill_noDefault_returnsNil() {
        let term = UUID()
        let tab = TerminalTab(title: "T", terminalId: term, quickActionId: nil)
        let result = StartupCommandResolver.resolve(
            terminalId: term,
            tab: tab,
            workspaceDefaultCommand: nil,
            quickActionCommand: { _ in nil },
            isResumeEnabled: { _ in true },
            pendingPrefill: nil
        )
        XCTAssertNil(result)
    }

    // MARK: - Quick Action tab, non-first pane (split sibling)

    func testQuickActionTab_secondPane_fallsThroughToDefault() {
        let firstTerm = UUID()
        let secondTerm = UUID()
        // SplitNode.split is positional: (UUID, SplitDirection, CGFloat,
        // SplitNode, SplitNode).
        let layout: SplitNode = .split(
            UUID(),
            .horizontal,
            0.5,
            .terminal(firstTerm),
            .terminal(secondTerm)
        )
        var tab = TerminalTab(title: "T", terminalId: firstTerm, quickActionId: "claude")
        tab.layout = layout
        // resolve for the SECOND terminal — not the first leaf.
        let result = StartupCommandResolver.resolve(
            terminalId: secondTerm,
            tab: tab,
            workspaceDefaultCommand: "default-cmd",
            quickActionCommand: { _ in "claude" },
            isResumeEnabled: { _ in true },
            pendingPrefill: nil
        )
        XCTAssertEqual(result, "default-cmd")
    }
}
