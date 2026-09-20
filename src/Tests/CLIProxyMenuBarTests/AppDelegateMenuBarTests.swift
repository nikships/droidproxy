import AppKit
import Sparkle
import XCTest
@testable import CLIProxyMenuBar

final class AppDelegateMenuBarTests: XCTestCase {
    func testStatusIconOwnsMenuAndActionsHaveWorkingTargets() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let updater = SPUStandardUpdaterController(
                startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
            )
            let delegate = MenuActionProbeDelegate(updaterController: updater)
            delegate.setupMenuBar()
            defer { NSStatusBar.system.removeStatusItem(delegate.statusItem) }

            // A local NSMenuItem named `statusItem` previously shadowed the
            // NSStatusItem property, leaving the icon with no dropdown at all.
            let attachedMenu = try XCTUnwrap(
                delegate.statusItem.menu,
                "The menu bar icon must own the dropdown, not just display an image."
            )
            XCTAssertTrue(attachedMenu === delegate.menu)
            XCTAssertNotNil(delegate.statusItem.button)
            let statusRow = try XCTUnwrap(attachedMenu.item(at: 0))
            XCTAssertFalse(statusRow.isEnabled)
            XCTAssertNil(statusRow.action)
            XCTAssertTrue(statusRow.menu === attachedMenu)
            for item in attachedMenu.items {
                XCTAssertTrue(item.menu === attachedMenu)
            }

            let actions: [(String, Selector)] = [
                ("Open Settings", #selector(AppDelegate.openSettings)),
                ("Start Server", #selector(AppDelegate.toggleServer)),
                ("Copy Server URL", #selector(AppDelegate.copyServerURL)),
                ("Open Dashboard", #selector(AppDelegate.openDashboard)),
                ("Quit", #selector(AppDelegate.quit))
            ]
            for (title, action) in actions {
                let item = try XCTUnwrap(attachedMenu.item(withTitle: title))
                XCTAssertTrue(item.target === delegate, "\(title) must have an explicit target.")
                XCTAssertEqual(item.action, action)
                XCTAssertTrue(delegate.responds(to: action))
            }

            let updateItem = try XCTUnwrap(attachedMenu.item(withTitle: "Check for Updates..."))
            XCTAssertTrue(updateItem.target === updater)
            XCTAssertEqual(updateItem.action, #selector(SPUStandardUpdaterController.checkForUpdates(_:)))
            XCTAssertTrue(updater.responds(to: try XCTUnwrap(updateItem.action)))

            // Dispatch through AppKit, without relying on NSApp.delegate or
            // starting proxy processes, opening windows, or quitting XCTest.
            let settingsItem = try XCTUnwrap(attachedMenu.item(withTitle: "Open Settings"))
            XCTAssertTrue(settingsItem.isEnabled)
            attachedMenu.performActionForItem(at: attachedMenu.index(of: settingsItem))
            XCTAssertEqual(delegate.settingsOpenCount, 1)

            let quitItem = try XCTUnwrap(attachedMenu.item(withTitle: "Quit"))
            XCTAssertTrue(quitItem.isEnabled)
            attachedMenu.performActionForItem(at: attachedMenu.index(of: quitItem))
            XCTAssertEqual(delegate.quitCount, 1)
        }
    }
}

private final class MenuActionProbeDelegate: AppDelegate {
    private(set) var settingsOpenCount = 0
    private(set) var quitCount = 0

    override func openSettings() {
        settingsOpenCount += 1
    }

    override func quit() {
        quitCount += 1
    }
}