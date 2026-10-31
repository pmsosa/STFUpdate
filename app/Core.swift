// Shared model for the Update or STFU app: paths, state files, config, shell helpers.
// Zero dependencies: Foundation/AppKit only. The shell script remains the source of truth;
// this app reads its state files and shells out to it for every action.
import AppKit
import Foundation

enum Paths {
    static let home = NSHomeDirectory()
    static let stateDir = home + "/.local/state/update-or-stfu"
    static let seen = stateDir + "/seen.tsv"
    static let needsYou = stateDir + "/needs-you.tsv"
    static let events = stateDir + "/events.tsv"
    static let masCount = stateDir + "/mas.count"
    static let log = stateDir + "/update.log"
    static let conf = home + "/.config/update-or-stfu/config"
    static let script = home + "/.local/bin/update-or-stfu"
    static let label = "com.konukoii.update-or-stfu"
    static let plist = home + "/Library/LaunchAgents/\(label).plist"
    static let domain = "gui/\(getuid())"
}

struct Pending: Identifiable, Hashable {
    let kind: String, name: String, version: String
    let first: TimeInterval
    var id: String { kind + "/" + name }
    func ageDays(_ now: TimeInterval = Date().timeIntervalSince1970) -> Int { Int((now - first) / 86400) }
}

// MARK: - Config (same file the script sources)

struct Config: Equatable {
    var thawDays = 7
    var checkEveryHours = 6
    var noThaw = ["docker", "docker-desktop"]
    var skip: [String] = []
    var dockerSkipIfRunning = true
    var greedyCasks = true
    var useMas = true
    var notify = true

    static func load() -> Config {
        var c = Config()
        guard let text = try? String(contentsOfFile: Paths.conf, encoding: .utf8) else { return c }
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            var val = String(line[line.index(after: eq)...])
            if let hash = val.range(of: " #") { val = String(val[..<hash.lowerBound]) }
            val = val.trimmingCharacters(in: .whitespaces)
            func list() -> [String] {
                val.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                    .split(separator: " ").map(String.init).filter { !$0.isEmpty }
            }
            switch key {
            case "THAW_DAYS": c.thawDays = Int(val) ?? c.thawDays
            case "CHECK_EVERY_HOURS": c.checkEveryHours = Int(val) ?? c.checkEveryHours
            case "NO_THAW": c.noThaw = list()
            case "SKIP": c.skip = list()
            case "DOCKER_SKIP_IF_RUNNING": c.dockerSkipIfRunning = val == "1"
            case "GREEDY_CASKS": c.greedyCasks = val == "1"
            case "USE_MAS": c.useMas = val == "1"
            case "NOTIFY": c.notify = val == "1"
            default: break
            }
        }
        return c
    }

    func save() {
        let text = """
        # update-or-stfu config (sourced by zsh; the app's Settings window rewrites this file)
        THAW_DAYS=\(thawDays)
        CHECK_EVERY_HOURS=\(checkEveryHours)
        NO_THAW=(\(noThaw.joined(separator: " ")))
        SKIP=(\(skip.joined(separator: " ")))
        DOCKER_SKIP_IF_RUNNING=\(dockerSkipIfRunning ? 1 : 0)
        GREEDY_CASKS=\(greedyCasks ? 1 : 0)
        USE_MAS=\(useMas ? 1 : 0)
        NOTIFY=\(notify ? 1 : 0)

        """
        try? FileManager.default.createDirectory(
            atPath: (Paths.conf as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? text.write(toFile: Paths.conf, atomically: true, encoding: .utf8)
    }
}

// MARK: - Shell

enum Shell {
    static let path = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    @discardableResult
    static func run(_ exe: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    static func script(_ args: [String]) -> Int32 { run("/bin/zsh", [Paths.script] + args).status }

    static func agentLoaded() -> Bool {
        run("/bin/launchctl", ["print", "\(Paths.domain)/\(Paths.label)"]).status == 0
    }
}

// MARK: - Model

final class Model: ObservableObject {
    static let shared = Model()

    @Published var pending: [Pending] = []
    @Published var needsYou: [Pending] = []
    @Published var masCount = 0
    @Published var lastRun = "No runs yet"
    @Published var agentLoaded = true
    @Published var busy = false
    @Published var busyLabel = ""
    @Published var config = Config.load()

    /// Pending items waiting out the thaw, oldest (closest to ready) first.
    var thawing: [Pending] {
        let ids = Set(needsYou.map(\.id))
        return pending
            .filter { !ids.contains($0.id) && !isReady($0) }
            .sorted { $0.first < $1.first }
    }
    /// Past the thaw (or exempt) and not failed: will install on the next check.
    var ready: [Pending] {
        let ids = Set(needsYou.map(\.id))
        return pending.filter { !ids.contains($0.id) && isReady($0) }.sorted { $0.first < $1.first }
    }

    func isReady(_ p: Pending) -> Bool {
        config.noThaw.contains(p.name) || p.ageDays() >= config.thawDays
    }

    func refresh() {
        let seen = Model.readTSV(Paths.seen)
        let need = Model.readTSV(Paths.needsYou)
        let mas = Int((try? String(contentsOfFile: Paths.masCount, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0") ?? 0
        let last = Model.lastRunSummary()
        let loaded = Shell.agentLoaded()
        let cfg = Config.load()
        DispatchQueue.main.async {
            if self.pending != seen { self.pending = seen }
            if self.needsYou != need { self.needsYou = need }
            if self.masCount != mas { self.masCount = mas }
            if self.lastRun != last { self.lastRun = last }
            if self.agentLoaded != loaded { self.agentLoaded = loaded }
            if self.config != cfg { self.config = cfg }
        }
    }

    static func readTSV(_ path: String) -> [Pending] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4, let t = TimeInterval(f[3]) else { return nil }
            return Pending(kind: f[0], name: f[1], version: f[2], first: t)
        }
    }

    static func lastRunSummary() -> String {
        guard let text = try? String(contentsOfFile: Paths.log, encoding: .utf8),
              let line = text.split(separator: "\n").last(where: { $0.contains(" done.") })
        else { return "No runs yet" }
        let s = String(line)
        let stamp = String(s.prefix(16))   // yyyy-MM-dd HH:mm
        let result = s.components(separatedBy: " done. ").last ?? ""
        return "Last run \(stamp) · \(result)"
    }

    // MARK: actions

    private func background(_ label: String, _ work: @escaping () -> Bool, done: @escaping (Bool) -> Void = { _ in }) {
        guard !busy else { return }
        busy = true
        busyLabel = label
        DispatchQueue.global().async {
            let ok = work()
            DispatchQueue.main.async {
                self.busy = false
                self.busyLabel = ""
                self.refresh()
                done(ok)
            }
        }
    }

    func checkNow() { background("Checking…") { Shell.script(["run"]) == 0 } }

    /// Early install of one thawing package, skipping the thaw (after the caller confirmed).
    func installNow(_ p: Pending) {
        background("Installing \(p.name)…") { Shell.script(["now", p.kind, p.name]) == 0 }
    }

    func toggleAgent() {
        if agentLoaded { Shell.run("/bin/launchctl", ["bootout", Paths.domain, Paths.plist]) }
        else { Shell.run("/bin/launchctl", ["bootstrap", Paths.domain, Paths.plist]) }
        refresh()
    }

    func saveConfig(_ c: Config) {
        c.save()
        config = c
        DispatchQueue.global().async {
            _ = Shell.script(["apply-config"])
            DispatchQueue.main.async { self.refresh() }
        }
    }

    /// Failed upgrades usually need sudo, so run them where a password prompt works: Terminal.
    func openInTerminal(_ items: [Pending]) {
        guard !items.isEmpty else { return }
        var s = "#!/bin/zsh\nexport PATH=\(Shell.path)\nexport HOMEBREW_NO_AUTO_UPDATE=1\n"
        for p in items {
            s += "echo; echo '==> \(p.name)'\n"
            s += "brew upgrade --\(p.kind) '\(p.name)' && '\(Paths.script)' clear \(p.kind) '\(p.name)'\n"
        }
        s += "echo; echo 'Done. You can close this window.'\n"
        let url = URL(fileURLWithPath: Paths.stateDir + "/install.command")
        try? s.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }
}
