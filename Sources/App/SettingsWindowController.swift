import AppKit
import SwiftUI

/// Owns the settings window. While it is open Dvar shows in the Dock and app
/// switcher; once closed it goes back to being a background app.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: SettingsModel?

    func show() {
        if let model {
            model.reloadIfClean()  // pick up edits made from the CLI meanwhile
        } else {
            createWindow()
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = Self.mainMenu()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createWindow() {
        let model = SettingsModel()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Dvar"
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("DvarSettings")
        window.delegate = self
        self.window = window
        self.model = model
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        model?.reloadIfClean()
        model?.refreshDefaultBrowser()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let model, model.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to your rules?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return model.save()
        case .alertSecondButtonReturn:
            model.reload()
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: Menu

    /// Just enough menu for ⌘C/⌘V/⌘Z/⌘A in text fields and ⌘W/⌘M/⌘Q.
    private static func mainMenu() -> NSMenu {
        let menu = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "Quit Dvar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
            .keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")

        for submenu in [app, edit, window] {
            let item = NSMenuItem()
            item.submenu = submenu
            menu.addItem(item)
        }
        return menu
    }
}
