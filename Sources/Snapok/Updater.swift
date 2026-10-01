import AppKit
import CryptoKit
import Security

/// Checks https://cdn.snapok.app for a newer build of this channel and installs it in place.
///
/// Only Developer ID builds update (the packages GitHub Actions publishes); local and ad-hoc builds never do.
/// Before replacing the app, the download must match the manifest's SHA-256, carry the same bundle identifier
/// and version, and be validly signed by the same Developer ID team as the running app.
@MainActor
final class Updater {
    static let shared = Updater()
    static let didChange = Notification.Name("Updater.didChange")

    enum Status: Equatable {
        /// Not a Developer ID build, so there is nothing to update from.
        case unsupported
        case idle
        case checking
        case upToDate
        case available(UpdateRelease)
        case downloading(Double)
        case installing
        case failed(String)
    }

    private(set) var status: Status {
        didSet { if status != oldValue { NotificationCenter.default.post(name: Self.didChange, object: self) } }
    }

    private let teamIdentifier: String?
    private var timer: Timer?
    private var progressObservation: NSKeyValueObservation?

    static var feedURL: URL {
        URL(string: AppChannel.isRelease ? "https://cdn.snapok.app/latest.json" : "https://cdn.snapok.app/dev/latest.json")!
    }

    static var automaticChecks: Bool {
        get { UserDefaults.standard.object(forKey: "update.automaticChecks") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "update.automaticChecks") }
    }

    /// The release an automatic check last announced, so each one prompts only once.
    private static var lastOffered: String? {
        get { UserDefaults.standard.string(forKey: "update.lastOffered") }
        set { UserDefaults.standard.set(newValue, forKey: "update.lastOffered") }
    }

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    let currentBuild = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0

    private init() {
        teamIdentifier = Self.developerIDTeam()
        status = teamIdentifier == nil ? .unsupported : .idle
    }

    /// Version text as users see it; development builds share a version, so they also show the build.
    static func displayVersion(_ version: String, build: Int) -> String {
        AppChannel.isRelease ? version : "\(version) (\(build))"
    }

    var currentDisplayVersion: String { Self.displayVersion(currentVersion, build: currentBuild) }

    // MARK: - Checking

    /// Checks shortly after launch, then every six hours, while automatic checks are on.
    func start() {
        guard status != .unsupported else {
            log("updates disabled: not a Developer ID build")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.automaticCheck() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { Updater.shared.automaticCheck() }
        }
    }

    private func automaticCheck() {
        guard Self.automaticChecks else { return }
        switch status {
        case .idle, .upToDate, .failed, .available: Task { await check(userInitiated: false) }
        case .unsupported, .checking, .downloading, .installing: break
        }
    }

    /// A user-initiated check reports every outcome; an automatic one only announces a release it has not offered before.
    func check(userInitiated: Bool) async {
        switch status {
        case .unsupported:
            if userInitiated { alert(L("Updates are not available for this build", "这个版本不支持自动更新"),
                                     L("Only builds downloaded from snapok.app can update themselves.", "只有从 snapok.app 下载的版本才能自动更新。")) }
            return
        case .checking, .downloading, .installing:
            return
        case .idle, .upToDate, .available, .failed:
            break
        }
        status = .checking
        do {
            let request = URLRequest(url: Self.feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let release = UpdateRelease(json: data) else {
                throw UpdateError(L("The update service is unavailable (HTTP \(code)).", "无法访问更新服务（HTTP \(code)）。"))
            }
            guard release.isNewer(thanVersion: currentVersion, build: currentBuild) else {
                status = .upToDate
                if userInitiated {
                    alert(L("You're up to date", "已是最新版本"),
                          L("\(AppChannel.displayName) \(currentDisplayVersion) is the latest version.",
                            "\(AppChannel.displayName) \(currentDisplayVersion) 是最新版本。"))
                }
                return
            }
            status = .available(release)
            let key = "\(release.version)+\(release.build)"
            log("update available: \(key)")
            if userInitiated || Self.lastOffered != key {
                Self.lastOffered = key
                offer(release)
            }
        } catch {
            log("update check failed: \(error.localizedDescription)")
            status = userInitiated ? .failed(error.localizedDescription) : .idle
            if userInitiated { alert(L("Couldn't check for updates", "检查更新失败"), error.localizedDescription) }
        }
    }

    /// Asks whether to install `release` now.
    func offer(_ release: UpdateRelease) {
        let alert = NSAlert()
        alert.messageText = L("\(AppChannel.displayName) \(Self.displayVersion(release.version, build: release.build)) is available",
                              "\(AppChannel.displayName) \(Self.displayVersion(release.version, build: release.build)) 已发布")
        var info = L("You have \(currentDisplayVersion). The app restarts after installing.",
                     "当前版本 \(currentDisplayVersion)，安装后会自动重启。")
        if !release.notes.isEmpty { info += "\n\n" + release.notes }
        alert.informativeText = info
        alert.addButton(withTitle: L("Install and Restart", "安装并重启"))
        alert.addButton(withTitle: L("Later", "稍后"))
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { install(release) }
    }

    /// Opens the offer for an update that has been found, or checks for one.
    func showOrCheck() {
        if case .available(let release) = status { offer(release) } else { Task { await check(userInitiated: true) } }
    }

    // MARK: - Installing

    func install(_ release: UpdateRelease) {
        guard let team = teamIdentifier else { return }
        switch status {
        case .downloading, .installing: return
        default: break
        }
        status = .downloading(0)
        log("downloading update \(release.url.absoluteString)")
        let task = URLSession.shared.downloadTask(with: release.url) { location, response, error in
            // The file is deleted when this handler returns, so move it first.
            let result: Result<URL, Error>
            if let location, (response as? HTTPURLResponse)?.statusCode == 200 {
                let kept = FileManager.default.temporaryDirectory.appendingPathComponent("Snapok-update-\(UUID().uuidString).zip")
                result = Result { try FileManager.default.moveItem(at: location, to: kept); return kept }
            } else {
                result = .failure(error ?? UpdateError(L("The download failed.", "下载失败。")))
            }
            Task { @MainActor in await Updater.shared.finishDownload(result, release: release, team: team) }
        }
        progressObservation = task.progress.observe(\.fractionCompleted) { progress, _ in
            let fraction = (progress.fractionCompleted * 100).rounded() / 100
            Task { @MainActor in
                if case .downloading = Updater.shared.status { Updater.shared.status = .downloading(fraction) }
            }
        }
        task.resume()
    }

    private func finishDownload(_ result: Result<URL, Error>, release: UpdateRelease, team: String) async {
        progressObservation = nil
        status = .installing
        let target = Bundle.main.bundleURL
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
        do {
            let zip = try result.get()
            defer { try? FileManager.default.removeItem(at: zip) }
            let newApp = try await Task.detached {
                try Self.prepare(zip: zip, release: release, team: team, bundleIdentifier: bundleIdentifier, replacing: target)
            }.value
            try FileManager.default.replaceItemAt(target, withItemAt: newApp)
            log("installed update \(release.version)+\(release.build); relaunching")
            relaunch(target)
        } catch {
            log("update failed: \(error.localizedDescription)")
            status = .failed(error.localizedDescription)
            let alert = NSAlert()
            alert.messageText = L("The update couldn't be installed", "更新安装失败")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: L("Download Manually", "手动下载"))
            alert.addButton(withTitle: L("Close", "关闭"))
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.dmg ?? AppLinks.website) }
        }
    }

    /// Checks and unpacks the download next to the installed app, so the swap is a same-volume rename.
    nonisolated private static func prepare(zip: URL, release: UpdateRelease, team: String,
                                            bundleIdentifier: String, replacing target: URL) throws -> URL {
        let data = try Data(contentsOf: zip, options: .mappedIfSafe)
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == release.sha256 else {
            throw UpdateError(L("The download is damaged. Please try again.", "下载的文件已损坏，请重试。"))
        }
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path),
              FileManager.default.isWritableFile(atPath: target.path) else {
            throw UpdateError(L("Snapok can't replace itself where it is installed. Move it to Applications or install the update manually.",
                                "当前位置无法替换 App，请把它移到「应用程序」文件夹，或手动下载安装。"))
        }
        let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                               appropriateFor: target, create: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, work.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0,
              let app = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }),
              let bundle = Bundle(url: app) else {
            throw UpdateError(L("The update package couldn't be opened.", "更新包无法解压。"))
        }
        guard bundle.bundleIdentifier == bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == release.version else {
            throw UpdateError(L("The update package is not the expected app.", "更新包不是预期的 App。"))
        }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(team)\""
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate),
                                         requirement) == errSecSuccess else {
            throw UpdateError(L("The update package's signature is invalid.", "更新包的签名校验失败。"))
        }
        return app
    }

    private func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// The running app's team when it is signed with a Developer ID certificate; nil for local and ad-hoc builds.
    private static func developerIDTeam() -> String? {
        var running: SecCode?
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let developerID = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(developerID as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate()
        alert.runModal()
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The About page's update row: current state on the left, the next action on the right.
@MainActor
final class UpdateStatusRow: NSView {
    private let detail = NSTextField(labelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private let progress = NSProgressIndicator()

    init() {
        super.init(frame: .zero)
        let tile = IconTile(symbol: "arrow.triangle.2.circlepath", tint: .systemGreen)
        let title = NSTextField(labelWithString: L("Software Update", "软件更新"))
        title.font = .systemFont(ofSize: 14, weight: .medium)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(act)
        let row = NSStackView(views: [tile, text, NSView(), progress, button])
        row.spacing = 12
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: Updater.didChange, object: nil)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func refresh() {
        let updater = Updater.shared
        let current = L("Version \(updater.currentDisplayVersion)", "当前版本 \(updater.currentDisplayVersion)")
        var busy = false
        button.isHidden = false
        button.isEnabled = true
        button.title = L("Check for Updates", "检查更新")
        switch updater.status {
        case .unsupported:
            detail.stringValue = L("This build doesn't update itself", "这个版本不支持自动更新")
            button.isHidden = true
        case .idle:
            detail.stringValue = current
        case .checking:
            detail.stringValue = L("Checking for updates…", "正在检查更新…")
            busy = true
            button.isEnabled = false
        case .upToDate:
            detail.stringValue = L("Up to date · \(updater.currentDisplayVersion)", "已是最新版本 · \(updater.currentDisplayVersion)")
        case .available(let release):
            let version = Updater.displayVersion(release.version, build: release.build)
            detail.stringValue = L("Version \(version) is available", "新版本 \(version) 可以安装")
            button.title = L("Install and Restart", "安装并重启")
        case .downloading(let fraction):
            detail.stringValue = L("Downloading… \(Int(fraction * 100))%", "正在下载… \(Int(fraction * 100))%")
            busy = true
            button.isEnabled = false
        case .installing:
            detail.stringValue = L("Installing…", "正在安装…")
            busy = true
            button.isEnabled = false
        case .failed(let message):
            detail.stringValue = message
        }
        busy ? progress.startAnimation(nil) : progress.stopAnimation(nil)
    }

    @objc private func act() {
        if case .available(let release) = Updater.shared.status {
            Updater.shared.install(release)
        } else {
            Task { await Updater.shared.check(userInitiated: true) }
        }
    }
}

/// The About page's "check automatically" switch.
@MainActor
final class UpdateAutomaticRow: NSView {
    private let toggle = NSSwitch()

    init() {
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: L("Check for updates automatically", "自动检查更新"))
        title.font = .systemFont(ofSize: 14)
        toggle.controlSize = .small
        toggle.state = Updater.automaticChecks ? .on : .off
        toggle.target = self
        toggle.action = #selector(changed)
        toggle.isEnabled = Updater.shared.status != .unsupported
        let row = NSStackView(views: [title, NSView(), toggle])
        row.alignment = .centerY
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
        Updater.automaticChecks = toggle.state == .on
    }
}
