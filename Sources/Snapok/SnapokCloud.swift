import AppKit

/// Snapok Cloud: the user's snapok.app account and the server-side AI features it unlocks.
/// The app only holds the account's session token; model and agent keys stay on the server.
@MainActor
enum SnapokCloud {
    static let didChangeAccount = Notification.Name("SnapokCloud.didChangeAccount")
    private static let tokenAccount = "cloud.sessionToken"

    /// The server CI builds bake in as `SnapokCloudURL` (snapok.app). Builds from source have none: no sign-in,
    /// credits or cloud generation, and Snapok Agent runs on the user's own model.
    /// Point any build at a backend with `defaults write ai.thinkany.snapok.dev cloud.baseURL http://localhost:3001`.
    nonisolated static var baseURL: URL? {
        let custom = UserDefaults.standard.string(forKey: "cloud.baseURL")
        let bundled = Bundle.main.object(forInfoDictionaryKey: "SnapokCloudURL") as? String
        return [custom, bundled].lazy.compactMap { $0.flatMap(URL.init(string:)) }.first { $0.host != nil }
    }

    nonisolated static var isAvailable: Bool { baseURL != nil }

    /// Registered per channel by `scripts/build-app.sh`; the website hands the session token back through it.
    static var urlScheme: String { AppChannel.isRelease ? "snapok" : "snapok-dev" }

    static var isSignedIn: Bool { isAvailable && Keychain.read(account: tokenAccount) != nil }

    /// Opens the website's sign-in page; it returns to `handle(_:)` with a session token.
    static func signIn() {
        guard let baseURL else { return }
        var components = URLComponents(url: baseURL.appendingPathComponent("sign-in"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "redirect", value: "\(urlScheme)://auth/callback")]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    static func signOut() {
        Keychain.write(nil, account: tokenAccount)
        account = nil
        NotificationCenter.default.post(name: didChangeAccount, object: nil)
    }

    /// The signed-in account's credits. Prices are set by the server; the app only displays them.
    struct Account: Equatable {
        let email: String
        /// Snapok Pro member; only members can buy credit packs.
        let isPro: Bool
        var balance: Int
        /// Credits a turn with an image result costs; also what a turn needs available up front.
        let cost: Int
        /// Credits a text-only answer costs.
        let textCost: Int
        let pricingURL: URL?

        var canAffordTurn: Bool { balance >= cost }
        /// Enough for Snapok Cloud to plan a turn (the text price).
        var canAffordPlan: Bool { balance >= textCost }
    }

    /// The last known account, or nil when signed out or not loaded yet.
    private(set) static var account: Account?

    /// Reloads the account from the server and posts `didChangeAccount` when it changed.
    static func refreshAccount() async {
        guard isSignedIn else { return }
        do {
            let data = try await request("api/agent/account", method: "GET", body: nil)
            let credits = data["credits"] as? [String: Any]
            update(Account(email: data["email"] as? String ?? "",
                           isPro: data["plan"] as? String == "pro",
                           balance: credits?["balance"] as? Int ?? 0,
                           cost: credits?["cost"] as? Int ?? 0,
                           textCost: credits?["textCost"] as? Int ?? 0,
                           pricingURL: (data["pricingUrl"] as? String).flatMap(URL.init(string:))))
        } catch {
            log("loading the cloud account failed", error: error)
        }
    }

    /// Opens the website's pricing page: the Pro plan, or the credit packs for members.
    static func openPricing() {
        guard let pricing = account?.pricingURL ?? baseURL?.appendingPathComponent("pricing") else { return }
        guard account?.isPro == true, var components = URLComponents(url: pricing, resolvingAgainstBaseURL: false) else {
            NSWorkspace.shared.open(pricing)
            return
        }
        components.fragment = "credits"
        NSWorkspace.shared.open(components.url ?? pricing)
    }

    private static func update(_ next: Account?) {
        guard next != account else { return }
        account = next
        NotificationCenter.default.post(name: didChangeAccount, object: nil)
    }

    private static func updateBalance(_ balance: Int) {
        guard var current = account else { return }
        current.balance = balance
        update(current)
    }

    /// Handles `snapok://auth/callback?token=…`. Returns false for URLs that are not for Snapok Cloud.
    static func handle(_ url: URL) -> Bool {
        guard url.scheme == urlScheme, url.host == "auth", url.path == "/callback" else { return false }
        let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "token" }?.value
        guard let token, !token.isEmpty else {
            log("cloud sign-in callback without a token")
            return true
        }
        Keychain.write(token, account: tokenAccount)
        log("signed in to Snapok Cloud")
        NotificationCenter.default.post(name: didChangeAccount, object: nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { await refreshAccount() }
        return true
    }

    struct ImageEdit {
        /// Pass back for follow-up edits so the agent keeps the context.
        let conversationID: String
        let reply: String
        /// nil when the service finished without returning an image.
        let image: NSImage?
    }

    /// Sends one turn to the cloud image agent. `images` may be empty for follow-ups;
    /// the agent then continues from the latest result of the conversation.
    /// A tool the cloud agent runs while it works: `name` is its own tool name, `done` once it has finished.
    struct AgentStep: Equatable {
        let id: String
        let name: String
        var done: Bool
    }

    /// `onText` receives the agent's words as it writes them and `onStep` each tool it starts or finishes;
    /// the result still arrives at the end.
    static func editImage(_ images: [NSImage], instruction: String, conversationID: String?,
                          onText: (@MainActor (String) -> Void)? = nil,
                          onStep: (@MainActor (AgentStep) -> Void)? = nil) async throws -> ImageEdit {
        // Generated images rarely exceed this, and it keeps uploads well under the server's limit.
        let encoded = try images.map { image -> String in
            guard let png = image.scaled(maxPixel: 2048)?.pngData else { throw CloudError.invalidImage }
            return "data:image/png;base64,\(png.base64EncodedString())"
        }
        var body: [String: Any] = ["images": encoded, "instruction": instruction]
        if let conversationID { body["conversationId"] = conversationID }
        let payload: [String: Any]
        if let onText {
            body["stream"] = true
            payload = try await stream("api/agent/edit-image", body: body, onText: onText, onStep: onStep ?? { _ in })
        } else {
            payload = try await request("api/agent/edit-image", method: "POST", body: body)
        }
        if let balance = (payload["credits"] as? [String: Any])?["balance"] as? Int {
            updateBalance(balance)
        }
        return ImageEdit(conversationID: payload["conversationId"] as? String ?? conversationID ?? "",
                         reply: payload["text"] as? String ?? "", image: firstImage(in: payload))
    }

    /// The first image among the `files` of an edit-image or result payload.
    private static func firstImage(in payload: [String: Any]) -> NSImage? {
        let files = payload["files"] as? [[String: Any]] ?? []
        return files.lazy.compactMap { file -> NSImage? in
            guard (file["contentType"] as? String)?.hasPrefix("image/") == true,
                  let dataURL = file["dataUrl"] as? String,
                  let comma = dataURL.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { return nil }
            return NSImage(data: data)
        }.first
    }

    enum GenerationResult {
        /// Still running on the server.
        case pending
        /// The server has no turn for it: the request never arrived.
        case missing
        /// It ended without an image (and was refunded).
        case failed
        case done(ImageEdit)
    }

    /// What became of a conversation's latest generation started at or after `since`. The server finishes (and charges)
    /// a generation even when the app quits or loses the connection, so the result can still be picked up here.
    static func generationResult(conversationID: String, since: Date) async throws -> GenerationResult {
        var request = try urlRequest("api/agent/result", method: "GET", body: nil)
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "conversationId", value: conversationID),
                                 URLQueryItem(name: "since", value: String(Int(since.timeIntervalSince1970 * 1000)))]
        request.url = components.url
        request.timeoutInterval = 90
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw transportError(error)
        }
        let payload = try payload(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0, path: "api/agent/result")
        if let balance = (payload["credits"] as? [String: Any])?["balance"] as? Int {
            updateBalance(balance)
        }
        switch payload["status"] as? String {
        case "pending": return .pending
        case "failed": return .failed
        case "success":
            return .done(ImageEdit(conversationID: conversationID, reply: payload["text"] as? String ?? "", image: firstImage(in: payload)))
        default: return .missing
        }
    }

    /// Asks Snapok Cloud's model to plan a turn with Snapok's own tools, for people without a model of their own.
    /// `input` is what `AgentPlanner.input` builds; returns `{ reply, ops }`. Charged at the text price.
    static func planImageEdit(png: Data?, input: [String: Any]) async throws -> [String: Any] {
        var body = input
        if let png { body["image"] = "data:image/png;base64,\(png.base64EncodedString())" }
        let payload = try await request("api/agent/plan", method: "POST", body: body)
        if let balance = (payload["credits"] as? [String: Any])?["balance"] as? Int {
            updateBalance(balance)
        }
        return payload
    }

    /// Translates recognized text with Snapok Cloud's model, for people without a model of their own.
    /// Returns one translation per block id. Charged at the text price.
    static func translateText(_ blocks: [RecognizedImageText], to target: String) async throws -> [Int: String] {
        let body: [String: Any] = [
            "target": target,
            "blocks": blocks.map { ["id": $0.id, "text": $0.text, "box": [$0.box.minX, $0.box.minY, $0.box.width, $0.box.height]] }
        ]
        let payload = try await request("api/agent/translate", method: "POST", body: body)
        if let balance = (payload["credits"] as? [String: Any])?["balance"] as? Int {
            updateBalance(balance)
        }
        return try ImageTranslationResponse.decode(payload, expectedIDs: blocks.map(\.id))
    }

    /// Calls the API and returns the `data` of the `{ code, message, data }` envelope.
    private static func request(_ path: String, method: String, body: [String: Any]?) async throws -> [String: Any] {
        let request = try urlRequest(path, method: method, body: body)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw transportError(error)
        }
        return try payload(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0, path: path)
    }

    /// POSTs and reads server-sent events: `text` pieces go to `onText`, and the `done` event's data is returned.
    /// Errors before the stream starts (signed out, out of credits) come back as the usual JSON envelope.
    private static func stream(_ path: String, body: [String: Any], onText: @MainActor (String) -> Void,
                               onStep: @MainActor (AgentStep) -> Void) async throws -> [String: Any] {
        let request = try urlRequest(path, method: "POST", body: body)
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let http = response as? HTTPURLResponse
            guard http?.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/event-stream") == true else {
                var data = Data()
                for try await byte in bytes { data.append(byte) }
                return try payload(data, status: http?.statusCode ?? 0, path: path)
            }
            for try await line in bytes.lines {
                guard line.hasPrefix("data:"),
                      let event = (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8))) as? [String: Any] else { continue }
                switch event["type"] as? String {
                case "text":
                    if let text = event["text"] as? String { onText(text) }
                case "tool":
                    if let name = event["name"] as? String {
                        onStep(AgentStep(id: event["id"] as? String ?? name, name: name, done: event["status"] as? String == "done"))
                    }
                case "done":
                    return event["data"] as? [String: Any] ?? [:]
                case "error":
                    log("cloud stream \(path) failed, status=\(event["status"] as? Int ?? 0)")
                    throw CloudError.server(event["message"] as? String ?? L("Service error.", "服务出错。"))
                default:
                    continue
                }
            }
            throw CloudError.interrupted
        } catch let error as URLError {
            // The turn keeps running on the server; a timed-out or dropped stream can still pick up its result.
            if error.code == .timedOut || error.code == .networkConnectionLost { throw CloudError.interrupted }
            throw transportError(error)
        }
    }

    /// Calls the API as the signed-in user.
    private static func urlRequest(_ path: String, method: String, body: [String: Any]?) throws -> URLRequest {
        guard let baseURL, let token = Keychain.read(account: tokenAccount) else { throw CloudError.signedOut }
        // Agent runs can take minutes; the default 60-second timeout would cut them off.
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: 300)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // better-auth reads the session from its cookie; HTTPS deployments use the __Secure- name.
        let cookieName = baseURL.scheme == "https" ? "__Secure-better-auth.session_token" : "better-auth.session_token"
        let encoded = token.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? token
        request.setValue("\(cookieName)=\(encoded)", forHTTPHeaderField: "Cookie")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return request
    }

    private static func transportError(_ error: URLError) -> Error {
        switch error.code {
        case .timedOut: return CloudError.server(L("The request timed out. Please try again.", "请求超时，请重试。"))
        case .cancelled: return error
        default:
            log("cloud request failed", error: error)
            return CloudError.unreachable
        }
    }

    /// The `data` of the `{ code, message, data }` envelope, or the error it reports.
    private static func payload(_ data: Data, status: Int, path: String) throws -> [String: Any] {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if status == 401 {
            signOut()
            throw CloudError.signedOut
        }
        if status == 402, let credits = json?["data"] as? [String: Any] {
            let balance = credits["balance"] as? Int ?? 0
            updateBalance(balance)
            throw CloudError.insufficientCredits(balance: balance, cost: credits["cost"] as? Int ?? 0)
        }
        guard status == 200, json?["code"] as? Int == 0, let payload = json?["data"] as? [String: Any] else {
            log("cloud request \(path) failed, status=\(status)")
            throw CloudError.server(json?["message"] as? String ?? L("Service error (\(status)).", "服务出错（\(status)）。"))
        }
        return payload
    }
}

enum CloudError: LocalizedError {
    case signedOut, unreachable, invalidImage
    /// The connection ended before the result arrived; the server may still finish it.
    case interrupted
    case insufficientCredits(balance: Int, cost: Int)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .interrupted: return L("The connection ended before the result arrived. Please try again.", "连接在结果返回前中断了，请重试。")
        case .signedOut: return L("Sign in to your Snapok account first.", "请先登录 Snapok 账号。")
        case .unreachable: return L("Can't reach Snapok Cloud. Check your connection and try again.", "无法连接 Snapok 云服务，请检查网络后重试。")
        case .invalidImage: return L("This image can't be sent.", "这张图片无法发送。")
        case .insufficientCredits(let balance, let cost):
            return L("Not enough credits: each message needs \(cost) available, and you have \(balance) left.",
                     "积分不足：每条消息需要至少 \(cost) 积分，当前剩余 \(balance)。")
        case .server(let message): return message
        }
    }
}
