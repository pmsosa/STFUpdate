// First-run setup for the drag-to-Applications build. The app carries a copy of the shell script in
// Resources; launchd can't run scripts from inside a quarantined bundle reliably, so it is copied to
// ~/.local/bin (where the rest of the app expects it) and the scheduler is loaded from there.
// Builds installed with `stfupdate app-install` have no bundled script and skip all of this.
import AppKit
import ServiceManagement

enum Bootstrap {
    static var bundled: String? { Bundle.main.path(forResource: "stfupdate", ofType: nil) }
    static var installedByScript: Bool {
        FileManager.default.fileExists(atPath: Paths.home + "/Library/LaunchAgents/\(Paths.label).app.plist")
    }

    /// Keeps ~/.local/bin/stfupdate in step with the bundled copy; asks once before setting up.
    static func run() {
        guard let src = bundled, !installedByScript else { return }
        let fm = FileManager.default
        let dst = Paths.script
        let hasConfig = fm.fileExists(atPath: Paths.conf)
        // No scheduler agent under the current label: first run, or an upgrade from the pre-1.0 labels.
        let needsScheduler = !fm.fileExists(atPath: Paths.plist)
        let fresh = !hasConfig && needsScheduler

        if fresh {
            let a = NSAlert()
            a.messageText = "Set up STFUpdate?"
            a.informativeText = """
                It will check Homebrew every 6 hours and install a new version only after it has been \
                available for 7 days (change this in Settings). Docker updates are not delayed. \
                Nothing is installed right now, and you can pause or uninstall from the menu bar.
                """
            a.addButton(withTitle: "Set Up")
            a.addButton(withTitle: "Quit")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() != .alertFirstButtonReturn { NSApp.terminate(nil); return }
        }

        if (try? Data(contentsOf: URL(fileURLWithPath: src))) != (try? Data(contentsOf: URL(fileURLWithPath: dst))) {
            try? fm.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? fm.removeItem(atPath: dst)
            try? fm.copyItem(atPath: src, toPath: dst)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst)
        }
        if needsScheduler {
            _ = Shell.script(["install"])   // also retires the old com.user.* agents
            try? SMAppService.mainApp.register()   // start at login
        }
    }

    static func uninstall() {
        let a = NSAlert()
        a.messageText = "Uninstall STFUpdate?"
        a.informativeText = "Stops the scheduler and removes the login item and installed script. Your settings and logs are kept. Then move the app to the Trash."
        a.addButton(withTitle: "Uninstall")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        _ = Shell.script(["uninstall"])
        try? SMAppService.mainApp.unregister()
        NSApp.terminate(nil)
    }
}
