import AppKit
#if canImport(Sentry)
import Sentry
#endif

/// Anonymous usage events (PostHog) and crash reports (Sentry), on by default and switched off in About → Privacy.
///
/// Only Developer ID builds with keys report. The keys are not in the source: `scripts/build-app.sh` writes
/// `POSTHOG_PROJECT_KEY` and `SENTRY_DSN` from the environment into Info.plist, and only the project's own
/// GitHub Actions builds set them, so builds from source never report to the project. Events carry a random
/// install ID, the app version and channel, and the macOS version, never screenshots, recognized text, file
/// names, prompts, or keys. Events are anonymous in PostHog (no person profiles); Sentry never sends PII,
/// screenshots, or view hierarchies.
@MainActor
enum Telemetry {
    private static let postHogKey = configured("SnapokPostHogKey")
    private static let postHogHost = configured("SnapokPostHogHost") ?? "https://us.i.posthog.com"
    private static let sentryDSN = configured("SnapokSentryDSN")

    private static func configured(_ key: String) -> String? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static var queue: [[String: Any]] = []
    private static var timer: Timer?
    private static var running = false

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "telemetry.enabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "telemetry.enabled")
            newValue ? start() : stop()
        }
    }

    /// Whether this build can report at all: a Developer ID build that was given keys.
    static var isAvailable: Bool { Updater.shared.isOfficialBuild && (postHogKey != nil || sentryDSN != nil) }

    static func start() {
        guard isAvailable, isEnabled, !running else { return }
        running = true
        startCrashReporting()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { flush() }
        }
        capture("app_launched")
    }

    private static func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        queue.removeAll()
        #if canImport(Sentry)
        if SentrySDK.isEnabled { SentrySDK.close() }
        #endif
    }

    /// Records one event; `properties` must never hold user content.
    static func capture(_ event: String, _ properties: [String: Any] = [:]) {
        guard running else { return }
        var all = commonProperties
        all.merge(properties) { _, new in new }
        queue.append(["event": event, "properties": all, "timestamp": ISO8601DateFormatter().string(from: Date())])
        if queue.count >= 20 { flush() }
    }

    /// Sends queued events; also called when the app quits.
    static func flush() {
        guard !queue.isEmpty, let postHogKey, let url = URL(string: postHogHost + "/batch/"),
              let body = try? JSONSerialization.data(withJSONObject: ["api_key": postHogKey, "batch": queue]) else {
            queue.removeAll()
            return
        }
        queue.removeAll()
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        URLSession.shared.dataTask(with: request).resume()
    }

    private static let installID: String = {
        if let id = UserDefaults.standard.string(forKey: "telemetry.installID") { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: "telemetry.installID")
        return id
    }()

    private static let commonProperties: [String: Any] = {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return [
            "distinct_id": installID,
            "$process_person_profile": false,
            "$lib": "snapok-macos",
            "app": "snapok",
            "channel": AppChannel.isRelease ? "release" : "dev",
            "$app_version": Updater.shared.currentVersion,
            "$app_build": String(Updater.shared.currentBuild),
            "$os": "macOS",
            "$os_version": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "arch": arch,
            "language": AppLanguage.current.rawValue
        ]
    }()

    private static func startCrashReporting() {
        #if canImport(Sentry)
        guard let sentryDSN else { return }
        let version = Updater.shared.currentVersion, build = Updater.shared.currentBuild
        let bundleID = Bundle.main.bundleIdentifier ?? "ai.thinkany.snapok"
        SentrySDK.start { options in
            options.dsn = sentryDSN
            options.releaseName = "\(bundleID)@\(version)+\(build)"
            options.dist = String(build)
            options.environment = AppChannel.isRelease ? "release" : "dev"
            options.sendDefaultPii = false
            options.tracesSampleRate = 0
            options.enableAppHangTracking = true
            options.enableUncaughtNSExceptionReporting = true
            options.enableNetworkBreadcrumbs = false
        }
        SentrySDK.configureScope { scope in
            scope.setUser(User(userId: installID))
            scope.setTag(value: AppLanguage.current.rawValue, key: "language")
        }
        #endif
    }
}

/// About → Privacy: the usage data switch.
@MainActor
final class TelemetryRow: NSView {
    private let toggle = NSSwitch()

    init() {
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: L("Share anonymous usage data and crash reports", "发送匿名使用数据和崩溃报告"))
        title.font = .systemFont(ofSize: 14)
        let detail = NSTextField(wrappingLabelWithString: Telemetry.isAvailable
            ? L("Helps improve Snapok. Never includes screenshots, text, file names, or keys.",
                "帮助改进 Snapok。不会包含截图、文字、文件名或密钥。")
            : L("Local builds never send data.", "本地构建的版本不会发送任何数据。"))
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toggle.controlSize = .small
        toggle.state = Telemetry.isEnabled && Telemetry.isAvailable ? .on : .off
        toggle.isEnabled = Telemetry.isAvailable
        toggle.target = self
        toggle.action = #selector(changed)
        let row = NSStackView(views: [text, NSView(), toggle])
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func changed() {
        Telemetry.isEnabled = toggle.state == .on
    }
}
