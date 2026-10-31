// Real macOS notifications. The shell script appends events to events.tsv; this tails the
// file and posts them through UNUserNotificationCenter so clicks can open the right window.
import Foundation
import UserNotifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    var openStatus: () -> Void = {}
    var openActivity: () -> Void = {}
    var installNeedsYou: () -> Void = {}

    private let offsetKey = "eventsOffset"
    private var timer: Timer?

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let install = UNNotificationAction(identifier: "install", title: "Install in Terminal", options: [.foreground])
        let view = UNNotificationAction(identifier: "view", title: "View", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "needs_you", actions: [install, view], intentIdentifiers: [], options: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Don't replay history the first time the app runs.
        if UserDefaults.standard.object(forKey: offsetKey) == nil {
            UserDefaults.standard.set(fileSize(), forKey: offsetKey)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    private func fileSize() -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: Paths.events)
        return (attrs?[.size] as? Int) ?? 0
    }

    private func poll() {
        var offset = UserDefaults.standard.integer(forKey: offsetKey)
        let size = fileSize()
        if size < offset { offset = 0 }            // file was truncated
        guard size > offset, let fh = FileHandle(forReadingAtPath: Paths.events) else { return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: UInt64(offset))
        guard let data = try? fh.readToEnd(), let text = String(data: data, encoding: .utf8) else { return }

        // only consume complete lines
        guard let lastNewline = text.lastIndex(of: "\n") else { return }
        let complete = text[..<lastNewline]
        UserDefaults.standard.set(offset + complete.utf8.count + 1, forKey: offsetKey)

        for line in complete.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4 else { continue }
            post(type: f[1], title: f[2], body: f[3])
        }
    }

    private func post(type: String, title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = type == "needs_you" ? .default : nil
        c.userInfo = ["type": type]
        if type == "needs_you" { c.categoryIdentifier = "needs_you" }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        Model.shared.refresh()
    }

    // Show banners even while the app is "active".
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list, .sound])
    }

    // Clicks go to the right place.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let type = r.notification.request.content.userInfo["type"] as? String ?? ""
        DispatchQueue.main.async {
            switch (r.actionIdentifier, type) {
            case ("install", _): self.installNeedsYou()
            case (_, "updated"): self.openActivity()
            default: self.openStatus()
            }
            done()
        }
    }
}
