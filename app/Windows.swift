// Native SwiftUI windows: Status (what's waiting), Activity (readable log), Settings (config).
import AppKit
import Combine
import SwiftUI

// MARK: - Window management

final class Windows {
    static let shared = Windows()
    private var windows: [String: NSWindow] = [:]

    func show<V: View>(_ id: String, title: String, size: NSSize, @ViewBuilder _ content: () -> V) {
        if let w = windows[id] {
            w.makeKeyAndOrderFront(nil)
        } else {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = title
            w.contentView = NSHostingView(rootView: content())
            w.isReleasedWhenClosed = false
            w.center()
            windows[id] = w
            w.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func status() { show("status", title: "Update or STFU", size: NSSize(width: 560, height: 640)) { StatusView() } }
    func activity() { show("activity", title: "Activity", size: NSSize(width: 760, height: 520)) { ActivityView() } }
    func settings() { show("settings", title: "Settings", size: NSSize(width: 480, height: 560)) { SettingsView() } }
}

// MARK: - Status

struct StatusView: View {
    @ObservedObject var m = Model.shared
    @State private var confirm: Pending?
    @State private var showAllThawing = false
    private let tick = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                if !m.needsYou.isEmpty {
                    Section {
                        ForEach(m.needsYou) { p in
                            HStack {
                                Label("\(p.name) \(p.version)", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Spacer()
                                Button("Install…") { m.openInTerminal([p]) }
                            }
                        }
                        if m.needsYou.count > 1 {
                            Button("Install all in Terminal") { m.openInTerminal(m.needsYou) }
                        }
                    } header: {
                        Text("Needs you")
                    } footer: {
                        Text("Couldn't install unattended (usually needs your password). Install… opens Terminal.")
                    }
                }

                if !m.ready.isEmpty {
                    Section("Installs on the next check") {
                        ForEach(m.ready) { p in
                            HStack {
                                Text(p.name); Text(p.version).foregroundStyle(.secondary)
                                Spacer()
                                Text("thawed").font(.caption).foregroundStyle(.green)
                            }
                        }
                    }
                }

                Section {
                    if m.thawing.isEmpty {
                        Text("Nothing waiting").foregroundStyle(.secondary)
                    }
                    ForEach(showAllThawing ? m.thawing : Array(m.thawing.prefix(8))) { p in
                        ThawRow(p: p, thawDays: m.config.thawDays) { confirm = p }
                    }
                    if m.thawing.count > 8 {
                        Button(showAllThawing ? "Show fewer" : "Show all \(m.thawing.count)") {
                            withAnimation { showAllThawing.toggle() }
                        }
                    }
                } header: {
                    Text("Waiting to thaw (\(m.thawing.count)) · closest to ready first")
                }

                if m.masCount > 0 {
                    Section("App Store") {
                        Button {
                            NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!)
                        } label: {
                            Label("\(m.masCount) update\(m.masCount == 1 ? "" : "s") in the App Store", systemImage: "arrow.up.right.square")
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .frame(minWidth: 460, minHeight: 360)
        .onReceive(tick) { _ in m.refresh() }
        .onAppear { m.refresh() }
        .alert("Install \(confirm?.name ?? "") now?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Install now") { if let p = confirm { m.installNow(p) }; confirm = nil }
            Button("Cancel", role: .cancel) { confirm = nil }
        } message: {
            if let p = confirm {
                Text("\(p.name) \(p.version) is only \(p.ageDays()) of \(m.config.thawDays) days into its thaw period. Installing now skips that protection.")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: m.agentLoaded ? "checkmark.shield.fill" : "pause.circle.fill")
                .font(.title)
                .foregroundStyle(m.agentLoaded ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.agentLoaded ? "Active · \(m.config.thawDays)-day thaw" : "Scheduled checks paused")
                    .font(.headline)
                Text(m.busy ? m.busyLabel : m.lastRun).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if m.busy { ProgressView().controlSize(.small) }
            Button("Check now") { m.checkNow() }.disabled(m.busy)
            Button(m.agentLoaded ? "Pause" : "Resume") { m.toggleAgent() }
        }
        .padding(12)
    }
}

struct ThawRow: View {
    let p: Pending
    let thawDays: Int
    let install: () -> Void

    var body: some View {
        let age = min(p.ageDays(), thawDays)
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(p.name)
                Text(p.version).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            ProgressView(value: Double(age), total: Double(max(thawDays, 1)))
                .frame(width: 90)
            Text("\(age)/\(thawDays)d").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
            Button("Install now…", action: install).controlSize(.small)
        }
    }
}

// MARK: - Activity (readable log)

struct ActivityView: View {
    enum Filter: String, CaseIterable { case activity = "Activity", problems = "Problems", everything = "Everything" }

    @State private var filter: Filter = .activity
    @State private var lines: [String] = []
    private let tick = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
    private let stamp = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} "#)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 320).labelsHidden()
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(shown.joined(separator: "\n"), forType: .string)
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Paths.log)])
                }
            }
            .padding(10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(color(line))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(10)
                }
                .onChange(of: shown.count) { _ in proxy.scrollTo("end") }
                .onAppear { load(); proxy.scrollTo("end") }
            }
        }
        .frame(minWidth: 520, minHeight: 300)
        .onReceive(tick) { _ in load() }
    }

    private var shown: [String] {
        switch filter {
        case .everything: return lines
        case .activity: return lines.filter(isStamped)
        case .problems: return lines.filter { isStamped($0) && (isProblem($0)) }
        }
    }

    private func isStamped(_ s: String) -> Bool {
        stamp.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
    private func isProblem(_ s: String) -> Bool {
        s.contains("FAILED") || s.contains("needs-you") || s.contains("defer") || s.contains("failed")
    }
    private func color(_ s: String) -> Color {
        if s.contains("FAILED") || s.contains("failed") { return .red }
        if s.contains("needs-you") || s.contains("defer") { return .orange }
        if s.contains(" upgrade ") || s.contains("manual upgrade") { return .green }
        if !isStamped(s) { return .secondary }
        return .primary
    }

    private func load() {
        guard let text = try? String(contentsOfFile: Paths.log, encoding: .utf8) else { lines = []; return }
        lines = Array(text.split(separator: "\n", omittingEmptySubsequences: false).suffix(1500)).map(String.init)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var m = Model.shared
    @State private var draft = Config.load()
    @State private var noThawText = ""
    @State private var skipText = ""
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Thaw period") {
                    Stepper(value: $draft.thawDays, in: 0...30) {
                        HStack { Text("Wait before installing"); Spacer(); Text("\(draft.thawDays) day\(draft.thawDays == 1 ? "" : "s")").foregroundStyle(.secondary) }
                    }
                    Text("A version must have been available to you for this long before it installs. Counted from when Homebrew first offered it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Schedule") {
                    Picker("Check every", selection: $draft.checkEveryHours) {
                        ForEach([1, 3, 6, 12, 24], id: \.self) { Text("\($0) hour\($0 == 1 ? "" : "s")").tag($0) }
                    }
                    Toggle("Include self-updating apps (needed for Docker Desktop)", isOn: $draft.greedyCasks)
                    Toggle("Report pending App Store updates", isOn: $draft.useMas)
                    Toggle("Notifications", isOn: $draft.notify)
                }
                Section("Exceptions") {
                    TextField("Install immediately, no thaw", text: $noThawText, prompt: Text("docker, docker-desktop"))
                    TextField("Never auto-upgrade", text: $skipText, prompt: Text("none"))
                    Text("Comma-separated package names.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Postpone Docker updates while containers are running", isOn: $draft.dockerSkipIfRunning)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Open raw config file") { NSWorkspace.shared.open(URL(fileURLWithPath: Paths.conf)) }
                    .buttonStyle(.link)
                Spacer()
                Button("Revert") { loadDraft() }.disabled(!changed)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(!changed)
            }
            .padding(12)
        }
        .frame(minWidth: 440, minHeight: 480)
        .onAppear { if !loaded { loadDraft(); loaded = true } }
    }

    private var composed: Config {
        var c = draft
        c.noThaw = Self.split(noThawText)
        c.skip = Self.split(skipText)
        return c
    }
    private var changed: Bool { composed != m.config }

    private func loadDraft() {
        draft = Config.load()
        noThawText = draft.noThaw.joined(separator: ", ")
        skipText = draft.skip.joined(separator: ", ")
    }
    private func save() {
        m.saveConfig(composed)
        draft = composed
    }
    private static func split(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init).filter { !$0.isEmpty }
    }
}
