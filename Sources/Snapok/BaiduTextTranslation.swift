import Foundation
import CryptoKit
import Security

enum TextTranslationProvider: String, CaseIterable {
    case baidu, system
    var title: String {
        switch self {
        case .baidu: return L("Baidu Translate (online)", "百度翻译（联网）")
        case .system: return L("System Translate (on-device)", "系统翻译（本机）")
        }
    }
}

struct BaiduTranslationCredentials: Codable, Sendable {
    let appID: String
    let secret: String
    var isValid: Bool { !appID.isEmpty && appID.allSatisfy { $0.isASCII && $0.isNumber } && !secret.isEmpty }
}

enum BaiduTranslationError: LocalizedError {
    case missingAppID, missingSecret, notConfigured, tooLong, unsupportedLanguage, invalidResponse, http(Int), api(String), credentialStore
    var errorDescription: String? {
        switch self {
        case .missingAppID: return L("Enter the numeric APP ID for General Text Translation, not an API Key.", "请填写「通用文本翻译」的数字 APP ID，不是其他服务的 API Key。")
        case .missingSecret: return L("Enter the matching secret. A saved secret can only be reused for the same APP ID.", "请填写配套密钥；仅可复用同一 APP ID 已保存的密钥。")
        case .notConfigured: return L("Configure your Baidu APP ID and secret in Settings → OCR & Translation first. Clipboard unchanged.", "请先在设置 → 文字识别与翻译中保存百度 APP ID 和密钥。剪贴板未改动。")
        case .tooLong: return L("Select at most 6,000 characters for Baidu translation. Short passages under 2,000 characters are recommended.", "百度单次翻译最多处理 6000 个字符，建议每次不超过 2000 字，请分段选择。")
        case .unsupportedLanguage: return L("This target language is not supported by the Baidu adapter.", "当前目标语言尚未接入百度翻译。")
        case .invalidResponse: return L("Baidu returned no valid translation. Clipboard unchanged.", "百度未返回有效译文，剪贴板未改动。")
        case .http(let status): return L("Baidu request failed (HTTP \(status)). Please retry later.", "百度请求失败（HTTP \(status)），请稍后重试。")
        case .credentialStore: return L("Could not save credentials to Keychain. Existing credentials have not been removed.", "无法将配置保存到钥匙串，原有配置未删除。")
        case .api(let code):
            switch code {
            case "52001": return L("Baidu translation timed out. Please retry.", "百度翻译超时，请重试。")
            case "52003", "58002", "90107": return L("Check your Baidu APP ID and enable General Text Translation on your Baidu account.", "请检查百度 APP ID，并在百度翻译开放平台完成认证、开通「通用文本翻译」服务。")
            case "54001": return L("Baidu authentication failed. Check your APP ID and secret.", "百度鉴权失败，请检查 APP ID 和密钥是否匹配。")
            case "54003", "54005", "59004": return L("Baidu rate limit reached. Please wait before trying again.", "百度调用频率受限，请稍后再试。")
            case "54004": return L("Baidu account balance or quota is insufficient. Check your Baidu account.", "百度账户余额或额度不足，请检查百度翻译开放平台账户。")
            case "58001": return L("Your Baidu service does not support this language pair.", "当前百度服务不支持这组翻译语言。")
            case "58000", "58003": return L("Baidu rejected this IP. Check your Baidu service restrictions.", "百度拒绝了当前 IP，请检查百度服务的访问限制。")
            default:
                let safeCode = code.count <= 12 && code.allSatisfy({ $0.isASCII && $0.isNumber }) ? code : "unknown"
                return L("Baidu translation failed (code \(safeCode)). Clipboard unchanged.", "百度翻译失败（错误码 \(safeCode)），剪贴板未改动。")
            }
        }
    }
}

/// One Keychain item stores the ID and secret atomically. Never logs source text or credentials.
enum BaiduTranslationCredentialStore {
    private static let account = "translation.baidu.credentials.v1"
    static func load() throws -> BaiduTranslationCredentials {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: AppChannel.keychainService,
                                   kSecAttrAccount as String: account, kSecReturnData as String: true,
                                   kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data,
              let result = try? JSONDecoder().decode(BaiduTranslationCredentials.self, from: data), result.isValid else {
            throw BaiduTranslationError.notConfigured
        }
        return result
    }
    static func save(_ credentials: BaiduTranslationCredentials) throws {
        guard credentials.isValid else { throw BaiduTranslationError.notConfigured }
        let data = try JSONEncoder().encode(credentials)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: AppChannel.keychainService,
                                   kSecAttrAccount as String: account]
        let updates = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw BaiduTranslationError.credentialStore }
        } else if status != errSecSuccess { throw BaiduTranslationError.credentialStore }
    }
}

private final class BaiduNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

enum BaiduTextTranslator {
    static let endpoint = URL(string: "https://fanyi-api.baidu.com/api/trans/vip/translate")!
    static func languageCode(_ language: Locale.Language) throws -> String {
        let codes = ["en": "en", "ja": "jp", "ko": "kor", "fr": "fra", "de": "de", "es": "spa",
                     "pt": "pt", "it": "it", "ar": "ara", "ru": "ru", "hi": "hi"]
        if language.languageCode?.identifier == "zh" { return language.maximalIdentifier.contains("Hant") ? "cht" : "zh" }
        guard let code = codes[language.languageCode?.identifier ?? ""] else { throw BaiduTranslationError.unsupportedLanguage }
        return code
    }
    static func signature(appID: String, text: String, salt: String, secret: String) -> String {
        Insecure.MD5.hash(data: Data((appID + text + salt + secret).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func request(text: String, target: Locale.Language, credentials: BaiduTranslationCredentials,
                        salt: String = UUID().uuidString.replacingOccurrences(of: "-", with: "")) throws -> URLRequest {
        guard credentials.isValid else { throw BaiduTranslationError.notConfigured }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SelectedTextTranslationError.empty }
        guard text.unicodeScalars.count <= 6000 else { throw BaiduTranslationError.tooLong }
        let fields = [("q", text), ("from", "auto"), ("to", try languageCode(target)), ("appid", credentials.appID),
                      ("salt", salt), ("sign", signature(appID: credentials.appID, text: text, salt: salt, secret: credentials.secret))]
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let body = fields.map { key, value in key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }.joined(separator: "&")
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(body.utf8)
        return request
    }
    static func parse(_ data: Data, status: Int) throws -> String {
        guard (200..<300).contains(status) else { throw BaiduTranslationError.http(status) }
        guard data.count <= 1_000_000, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BaiduTranslationError.invalidResponse
        }
        if let value = json["error_code"] {
            let code = (value as? String) ?? (value as? NSNumber)?.stringValue ?? "unknown"
            if code != "52000" { throw BaiduTranslationError.api(code) }
        }
        guard let results = json["trans_result"] as? [[String: Any]], !results.isEmpty else { throw BaiduTranslationError.invalidResponse }
        var translated: [String] = []
        for result in results {
            guard let text = result["dst"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BaiduTranslationError.invalidResponse
            }
            translated.append(text)
        }
        return translated.joined(separator: "\n")
    }
    static func translate(_ text: String, target: Locale.Language, credentials: BaiduTranslationCredentials) async throws -> String {
        let request = try request(text: text, target: target, credentials: credentials)
        try Task.checkCancellation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 25
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: BaiduNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw BaiduTranslationError.invalidResponse }
        return try parse(data, status: response.statusCode)
    }
}

@MainActor
enum SelectedTextTranslationService {
    static func translate(_ text: String, target: Locale.Language) async throws -> String {
        switch TextActionPreferences().translationProvider {
        case .baidu: return try await BaiduTextTranslator.translate(text, target: target, credentials: BaiduTranslationCredentialStore.load())
        case .system: return try await SelectedTextTranslator.translate(text, target: target)
        }
    }
}
