// Renders the app's own windows to PNG for the README. It draws the views in-process from made-up
// demo data in a throwaway $HOME; it never captures the screen. Run via tools/screenshots.sh.
import AppKit
import SwiftUI

let outDir = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// MARK: demo data (UOS_HOME is a temp dir set by screenshots.sh)
guard let uosHome = ProcessInfo.processInfo.environment["UOS_HOME"], Paths.home == uosHome,
      uosHome.hasPrefix(NSTemporaryDirectory()) || uosHome.hasPrefix("/private/var/") || uosHome.hasPrefix("/var/") else {
    print("refusing to run: UOS_HOME must point at a temp directory (this writes demo state files)")
    exit(1)
}
let now = Int(Date().timeIntervalSince1970)
func ago(_ d: Double) -> Int { now - Int(d * 86400) }
let fm = FileManager.default
try fm.createDirectory(atPath: Paths.stateDir, withIntermediateDirectories: true)
try fm.createDirectory(atPath: (Paths.conf as NSString).deletingLastPathComponent, withIntermediateDirectories: true)

let seen: [(String, String, String, Int)] = [
    ("formula", "ripgrep", "14.2.0", ago(8.2)),
    ("cask", "firefox", "141.0", ago(7.4)),
    ("formula", "node", "24.3.0", ago(5.1)),
    ("formula", "postgresql@17", "17.6", ago(4.3)),
    ("cask", "visual-studio-code", "1.103.0", ago(3.2)),
    ("formula", "ffmpeg", "7.2", ago(2.1)),
    ("cask", "slack", "4.46.2", ago(1.4)),
    ("formula", "python@3.13", "3.13.6", ago(0.6)),
    ("cask", "docker-desktop", "4.44.0", ago(9)),
]
let needs: [(String, String, String, Int)] = [("cask", "docker-desktop", "4.44.0", ago(9))]
func tsv(_ rows: [(String, String, String, Int)]) -> String {
    rows.map { "\($0.0)\t\($0.1)\t\($0.2)\t\($0.3)" }.joined(separator: "\n") + "\n"
}
try tsv(seen).write(toFile: Paths.seen, atomically: true, encoding: .utf8)
try tsv(needs).write(toFile: Paths.needsYou, atomically: true, encoding: .utf8)
try "3\n".write(toFile: Paths.masCount, atomically: true, encoding: .utf8)
try "THAW_DAYS=7\nCHECK_EVERY_HOURS=6\nNO_THAW=(docker)\nSKIP=(postgresql@17)\nDOCKER_SKIP_IF_RUNNING=1\nGREEDY_CASKS=1\nUSE_MAS=1\nNOTIFY=1\n"
    .write(toFile: Paths.conf, atomically: true, encoding: .utf8)

let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss"
func stamp(_ hoursAgo: Double) -> String { df.string(from: Date().addingTimeInterval(-hoursAgo * 3600)) }
let log = """
\(stamp(18)) --- run (thaw 7d) ---
\(stamp(18)) thaw   ffmpeg -> 7.2 (seen 2d, need 7d)
\(stamp(18)) thaw   node -> 24.3.0 (seen 5d, need 7d)
\(stamp(18)) upgrade ripgrep -> 14.2.0
\(stamp(18)) upgrade firefox -> 141.0
\(stamp(18)) done. Updated: ripgrep, firefox. Thawing: 2.
\(stamp(12)) --- run (thaw 7d) ---
\(stamp(12)) thaw   node -> 24.3.0 (seen 5d, need 7d)
\(stamp(12)) skip   postgresql@17 (in SKIP)
\(stamp(12)) upgrade docker-desktop -> 4.44.0
\(stamp(12)) FAILED docker-desktop
\(stamp(12)) done. FAILED: docker-desktop. Thawing: 4.
\(stamp(6)) --- run (thaw 7d) ---
\(stamp(6)) defer  docker-desktop -> 4.44.0 (containers running)
\(stamp(6)) thaw   slack -> 4.46.2 (seen 1d, need 7d)
\(stamp(6)) mas: 3 App Store update(s) pending (needs sudo; install from the App Store)
\(stamp(6)) done. App Store updates pending: 3. Needs you: docker-desktop. Thawing: 5.

"""
try log.write(toFile: Paths.log, atomically: true, encoding: .utf8)

// MARK: render
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let m = Model.shared
m.pending = Model.readTSV(Paths.seen)
m.needsYou = Model.readTSV(Paths.needsYou)
m.masCount = 3
m.config = Config.load()
m.agentLoaded = true
m.lastRun = Model.lastRunSummary()

func render<V: View>(_ name: String, title: String, size: NSSize, dark: Bool, @ViewBuilder _ content: () -> V) {
    let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                     styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    w.title = title
    w.contentView = NSHostingView(rootView: content())
    w.setContentSize(size)
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))   // let SwiftUI lay out and onAppear run
    guard let frame = w.contentView?.superview else { return }
    frame.layoutSubtreeIfNeeded()
    guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
    frame.cacheDisplay(in: frame.bounds, to: rep)
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(name).png")
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
    print("wrote \(url.path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
}

render("status", title: "Update or STFU", size: NSSize(width: 560, height: 640), dark: false) { StatusView() }
render("status-dark", title: "Update or STFU", size: NSSize(width: 560, height: 640), dark: true) { StatusView() }
render("activity", title: "Activity", size: NSSize(width: 760, height: 520), dark: true) { ActivityView() }
render("settings", title: "Settings", size: NSSize(width: 480, height: 560), dark: false) { SettingsView() }
