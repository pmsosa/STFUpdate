// Menu bar controller. Keeps the dropdown short: a few "next up" rows inline, the rest behind a
// submenu (like the Wi-Fi menu), with the full list in the Status window.
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let m = Model.shared
    static let inlineThawing = 3
    static let submenuThawing = 10

    func applicationDidFinishLaunching(_ n: Notification) {
        Bootstrap.run()
        item.menu = NSMenu()
        item.menu?.delegate = self

        let notifier = Notifier.shared
        notifier.openStatus = { Windows.shared.status() }
        notifier.openActivity = { Windows.shared.activity() }
        notifier.installNeedsYou = { [m] in m.openInTerminal(m.needsYou) }
        notifier.start()

        m.refresh()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.m.refresh()
            self?.updateIcon()
        }
        updateIcon()
    }

    /// Windows closing must not quit the app (it lives in the menu bar).
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    func updateIcon() {
        guard let button = item.button else { return }
        let symbol: String
        if !m.agentLoaded { symbol = "pause.circle" }
        else if m.busy { symbol = "arrow.triangle.2.circlepath.circle.fill" }
        else if !m.needsYou.isEmpty { symbol = "exclamationmark.circle.fill" }
        else { symbol = "arrow.triangle.2.circlepath.circle" }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "STFUpdate")
        let count = m.needsYou.isEmpty ? m.pending.count : m.needsYou.count
        button.title = count > 0 ? " \(count)" : ""
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        m.refresh()
        updateIcon()
        menu.removeAllItems()

        info(menu, m.agentLoaded ? "STFUpdate · active · \(m.config.thawDays)d thaw" : "STFUpdate · PAUSED", bold: true)
        info(menu, m.busy ? m.busyLabel : m.lastRun)
        menu.addItem(.separator())

        if !m.needsYou.isEmpty {
            info(menu, "Needs you (\(m.needsYou.count))", bold: true)
            for p in m.needsYou.prefix(5) {
                action(menu, "Install \(p.name)… (opens Terminal)", #selector(installOne(_:)), object: p.id, symbol: "exclamationmark.triangle")
            }
            if m.needsYou.count > 1 {
                action(menu, "Install all in Terminal…", #selector(installAll), symbol: "terminal")
            }
            menu.addItem(.separator())
        }

        let ready = m.ready
        if !ready.isEmpty {
            info(menu, "Installs on next check (\(ready.count))", bold: true)
            for p in ready.prefix(3) { info(menu, "   \(p.name)  \(p.version)") }
            if ready.count > 3 { info(menu, "   + \(ready.count - 3) more") }
            menu.addItem(.separator())
        }

        let thawing = m.thawing
        if thawing.isEmpty {
            if ready.isEmpty && m.needsYou.isEmpty { info(menu, "Nothing waiting") }
        } else {
            info(menu, "Waiting to thaw (\(thawing.count))", bold: true)
            for p in thawing.prefix(Self.inlineThawing) { info(menu, thawLine(p)) }
            if thawing.count > Self.inlineThawing {
                let rest = Array(thawing.dropFirst(Self.inlineThawing))
                let more = NSMenuItem(title: "More (\(rest.count))", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                for p in rest.prefix(Self.submenuThawing) { info(sub, thawLine(p)) }
                if rest.count > Self.submenuThawing {
                    sub.addItem(.separator())
                }
                action(sub, "Show all in window…", #selector(openStatus))
                more.submenu = sub
                menu.addItem(more)
            }
        }

        if m.masCount > 0 {
            menu.addItem(.separator())
            action(menu, "App Store: \(m.masCount) update\(m.masCount == 1 ? "" : "s")…", #selector(openAppStore), symbol: "bag")
        }

        menu.addItem(.separator())
        action(menu, "Open STFUpdate…", #selector(openStatus), key: "o", symbol: "list.bullet.rectangle")
        let check = action(menu, "Check now", #selector(checkNow), key: "r", symbol: "arrow.clockwise")
        check.isEnabled = !m.busy
        action(menu, m.agentLoaded ? "Pause scheduled checks" : "Resume scheduled checks", #selector(toggleAgent),
               symbol: m.agentLoaded ? "pause" : "play")
        menu.addItem(.separator())
        action(menu, "Activity…", #selector(openActivity), key: "l", symbol: "text.alignleft")
        action(menu, "Settings…", #selector(openSettings), key: ",", symbol: "gearshape")
        menu.addItem(.separator())
        action(menu, "Uninstall…", #selector(uninstall))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func thawLine(_ p: Pending) -> String {
        let age = min(p.ageDays(), m.config.thawDays)
        return "   \(p.name)  \(p.version)   \(age)/\(m.config.thawDays)d"
    }

    @discardableResult
    private func info(_ menu: NSMenu, _ title: String, bold: Bool = false) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        if bold {
            mi.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.menuFont(ofSize: 0).withWeight(.semibold),
                .foregroundColor: NSColor.labelColor,
            ])
        }
        menu.addItem(mi)
        return mi
    }

    @discardableResult
    private func action(_ menu: NSMenu, _ title: String, _ sel: Selector, key: String = "",
                        object: Any? = nil, symbol: String? = nil) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        mi.target = self
        mi.representedObject = object
        if let s = symbol { mi.image = NSImage(systemSymbolName: s, accessibilityDescription: nil) }
        menu.addItem(mi)
        return mi
    }

    // MARK: actions

    @objc func installOne(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let p = m.needsYou.first(where: { $0.id == id }) else { return }
        m.openInTerminal([p])
    }
    @objc func installAll() { m.openInTerminal(m.needsYou) }
    @objc func uninstall() { Bootstrap.uninstall() }
    @objc func openStatus() { Windows.shared.status() }
    @objc func openActivity() { Windows.shared.activity() }
    @objc func openSettings() { Windows.shared.settings() }
    @objc func checkNow() { m.checkNow() }
    @objc func toggleAgent() { m.toggleAgent(); updateIcon() }
    @objc func openAppStore() { NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!) }
}

extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: pointSize, weight: weight)
    }
}

@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
