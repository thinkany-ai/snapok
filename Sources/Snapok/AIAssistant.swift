import AppKit
import Vision

struct TextScan: Sendable {
    /// Recognized lines in reading order.
    let text: String
    /// Normalized (0–1, bottom-left origin) boxes around sensitive values.
    let sensitiveBoxes: [CGRect]
}

/// On-device text recognition and sensitive-value detection with Vision; nothing leaves the Mac.
enum TextScanner {
    static func scan(_ image: CGImage) async -> TextScan {
        return await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.usesLanguageCorrection = true
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            } catch {
                log("text recognition failed: \(error)")
            }

            // Rows top to bottom, then left to right within roughly the same row.
            let observations = (request.results ?? []).sorted { a, b in
                abs(a.boundingBox.midY - b.boundingBox.midY) > min(a.boundingBox.height, b.boundingBox.height) / 2
                    ? a.boundingBox.midY > b.boundingBox.midY
                    : a.boundingBox.minX < b.boundingBox.minX
            }
            var lines: [String] = []
            var boxes: [CGRect] = []
            for observation in observations {
                guard let candidate = observation.topCandidates(1).first else { continue }
                lines.append(candidate.string)
                for range in SensitiveDetector.ranges(in: candidate.string) {
                    if let box = try? candidate.boundingBox(for: range)?.boundingBox {
                        boxes.append(box)
                    }
                }
            }
            return TextScan(text: lines.joined(separator: "\n"), sensitiveBoxes: boxes)
        }.value
    }
}

enum SensitiveDetector {
    /// Patterns for values worth hiding; `group` picks the part to mask when only the value after a label is secret.
    private static let patterns: [(pattern: String, group: Int)] = [
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, 0),
        (#"(?<!\d)(?:\+?86[- ]?)?1[3-9]\d[- ]?\d{4}[- ]?\d{4}(?!\d)"#, 0),
        (#"(?<!\d)\d{17}[\dXx](?!\d)"#, 0),
        (#"(?<!\d)(?:\d{4}[ -]?){3}\d{3,7}(?!\d)"#, 0),
        (#"\bsk-(?:ant-)?[A-Za-z0-9_-]{16,}"#, 0),
        (#"\b(?:ghp|gho|ghu|ghs|github_pat)_[A-Za-z0-9_]{20,}"#, 0),
        (#"\bAKIA[0-9A-Z]{16}\b"#, 0),
        (#"\bAIza[0-9A-Za-z_-]{35}"#, 0),
        (#"\bxox[abprs]-[A-Za-z0-9-]{10,}"#, 0),
        (#"(?i)\bBearer\s+([A-Za-z0-9._~+/-]{20,})"#, 1),
        (#"(?i)(?:password|passwd|pwd|secret|token|api[ _-]?key|密码|口令|密钥)\s*[:：=]\s*(\S+)"#, 1),
        (#"(?<![A-Za-z0-9])[A-Za-z0-9_-]{32,}(?![A-Za-z0-9])"#, 0)
    ]

    static func ranges(in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        let nsRange = NSRange(text.startIndex..., in: text)
        for (pattern, group) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: nsRange) {
                guard let range = Range(match.range(at: group), in: text),
                      !found.contains(where: { $0.overlaps(range) }) else { continue }
                found.append(range)
            }
        }
        return found
    }

    /// Mosaic strokes that cover `rect` (image points): one stroke if it fits the widest brush, otherwise a zigzag.
    static func mosaic(covering rect: CGRect) -> Annotation {
        let rect = rect.insetBy(dx: -3, dy: -3)
        let level = (0..<Style.sizeLevels).first { Style.lineWidth(for: .mosaic, level: $0) >= rect.height } ?? Style.sizeLevels - 1
        let width = Style.lineWidth(for: .mosaic, level: level)
        let rows = max(1, Int(ceil((rect.height - width) / (width * 0.75))) + 1)
        let inset = min(width / 2, rect.width / 2)
        var points: [CGPoint] = []
        for row in 0..<rows {
            let y = rows == 1 ? rect.midY : rect.minY + width / 2 + (rect.height - width) * CGFloat(row) / CGFloat(rows - 1)
            let left = CGPoint(x: rect.minX + inset, y: y)
            let right = CGPoint(x: rect.maxX - inset, y: y)
            points += row.isMultiple(of: 2) ? [left, right] : [right, left]
        }
        return Annotation(kind: .mosaic, rect: rect, points: points, color: .black, sizeLevel: level)
    }
}

enum AIError: LocalizedError {
    case missingKey
    case badURL
    case http(Int, String)
    case refused
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingKey: return L("No API key configured. Add one in Settings → AI Settings.", "还没有设置 API Key。请在「设置 → AI」里填写。")
        case .badURL: return L("Invalid base URL. Check Settings → AI Settings.", "接口地址无效，请在「设置 → AI」里检查。")
        case .http(let status, let message): return L("AI service error (\(status)): \(message)", "AI 服务返回错误（\(status)）：\(message)")
        case .refused: return L("The AI service declined to process this screenshot.", "AI 拒绝处理这张截图。")
        case .emptyResponse: return L("The AI service returned no content. Please try again.", "AI 没有返回内容，请稍后重试。")
        }
    }
}

/// Minimal Claude Messages API client over URLSession (Swift has no official Anthropic SDK).
struct ClaudeClient {
    let apiKey: String
    let baseURL: URL
    let model: String

    @MainActor
    static func configured() throws -> ClaudeClient {
        guard let key = AppSettings.apiKey else { throw AIError.missingKey }
        guard let url = URL(string: AppSettings.aiBaseURL.trimmingCharacters(in: .whitespaces)), url.scheme != nil else {
            throw AIError.badURL
        }
        return ClaudeClient(apiKey: key, baseURL: url, model: AppSettings.aiModel)
    }

    /// Sends one user turn and returns the concatenated text blocks.
    func send(system: String, text: String, imagePNG: Data? = nil, effort: String, schema: [String: Any]? = nil) async throws -> String {
        var content: [[String: Any]] = []
        if let imagePNG {
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": imagePNG.base64EncodedString()]])
        }
        content.append(["type": "text", "text": text])

        var outputConfig: [String: Any] = ["effort": effort]
        if let schema {
            outputConfig["format"] = ["type": "json_schema", "schema": schema]
        }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": system,
            "output_config": outputConfig,
            "messages": [["role": "user", "content": content]]
        ]

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // On a safety decline, let the API rerun the request on its recommended fallback model.
        // Only the first-party API accepts this; gateways at other addresses may reject unknown fields.
        if baseURL.host == "api.anthropic.com" {
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = (json["error"] as? [String: Any])?["message"] as? String
                ?? String(data: data, encoding: .utf8) ?? ""
            throw AIError.http(status, message)
        }
        if json["stop_reason"] as? String == "refusal" {
            throw AIError.refused
        }
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.emptyResponse }
        return text
    }
}

@MainActor
enum AIAssistant {
    /// PNG sized for vision input: the longest side capped so large screens stay within the image limits.
    static func visionPNG(_ image: CGImage) -> Data? {
        NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height)).scaled(maxPixel: 1568)?.pngData
    }

    static func translate(_ image: CGImage) async throws -> String {
        let client = try ClaudeClient.configured()
        let target = AppSettings.translateTarget
        let scan = await TextScanner.scan(image)
        let system = "你是截图翻译助手。把用户提供的截图文字翻译成\(target)。保留原文的分行和列表结构，只输出译文，不要解释。"
        if scan.text.isEmpty {
            return try await client.send(system: system, text: "翻译这张截图中的文字。", imagePNG: visionPNG(image), effort: "medium")
        }
        return try await client.send(system: system, text: scan.text, effort: "medium")
    }

    static func ask(_ question: String, about image: CGImage) async throws -> String {
        let client = try ClaudeClient.configured()
        let system = L("You are a screenshot assistant. Answer the user's question concisely in English using the screenshot. Say when the answer cannot be determined from the image.", "你是截图助手。用户会给你一张截图和一个问题，结合截图内容用简洁的中文回答；截图里看不出答案时直接说明。")
        return try await client.send(system: system, text: question, imagePNG: visionPNG(image), effort: "medium")
    }

    static func titleAndTags(for image: CGImage, ocrText: String) async throws -> (String, [String]) {
        let client = try ClaudeClient.configured()
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "title": ["type": "string", "description": L("A short English title of no more than 8 words", "不超过 16 个字的中文标题")],
                "tags": ["type": "array", "items": ["type": "string"], "description": L("1 to 4 short English tags", "1 到 4 个简短的中文标签")]
            ],
            "required": ["title", "tags"],
            "additionalProperties": false
        ]
        var prompt = L("Give this screenshot a short English title and 1 to 4 searchable tags, such as the app name, content type, or topic.", "给这张截图起一个简短的中文标题，并给出 1 到 4 个便于搜索的标签（例如应用名、内容类型、主题）。")
        if !ocrText.isEmpty {
            prompt += "\n\n截图中识别出的文字：\n" + String(ocrText.prefix(2000))
        }
        let text = try await client.send(
            system: "你负责整理用户的截图库。", text: prompt, imagePNG: visionPNG(image), effort: "low", schema: schema
        )
        guard let data = text.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.emptyResponse
        }
        let title = (json["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = (json["tags"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return (title, Array(tags.prefix(4)))
    }

    /// Background work for a new history item: local OCR for search, then optional AI naming.
    static func enrich(_ item: HistoryItem) {
        Task { @MainActor in
            guard let image = HistoryStore.shared.original(for: item)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let scan = await TextScanner.scan(image)
            HistoryStore.shared.update(item.id) { $0.ocrText = scan.text }

            guard AppSettings.autoName, AppSettings.apiKey != nil else { return }
            do {
                let (title, tags) = try await titleAndTags(for: image, ocrText: scan.text)
                HistoryStore.shared.update(item.id) {
                    if !title.isEmpty { $0.title = title }
                    $0.tags = tags
                }
            } catch {
                log("auto naming failed: \(error.localizedDescription)")
            }
        }
    }
}

/// A small window that shows an AI or OCR result with a copy button.
@MainActor
final class AIResultWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [AIResultWindowController] = []

    private let textView = NSTextView()
    private let spinner = NSProgressIndicator()
    private let status = NSTextField(labelWithString: "")

    static func show(title: String, near parent: NSWindow?, work: @escaping @MainActor () async throws -> String) {
        let controller = AIResultWindowController(title: title)
        open.append(controller)
        if let parent {
            let frame = parent.frame
            controller.window?.setFrameOrigin(CGPoint(x: frame.midX - 260, y: frame.midY - 200))
        } else {
            controller.window?.center()
        }
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.run(work)
    }

    private init(title: String) {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.minSize = CGSize(width: 360, height: 240)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        guard let root = window?.contentView else { return }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = CGSize(width: 12, height: 12)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView

        spinner.style = .spinning
        spinner.controlSize = .small
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12)
        let copy = NSButton(title: L("Copy", "复制"), target: self, action: #selector(copyText))
        copy.bezelStyle = .rounded
        let close = NSButton(title: L("Close", "关闭"), target: self, action: #selector(closeWindow))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views: [spinner, status, NSView(), close, copy])
        footer.spacing = 8

        [scroll, footer].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
    }

    private func run(_ work: @escaping @MainActor () async throws -> String) {
        spinner.startAnimation(nil)
        status.stringValue = L("Processing…", "处理中…")
        Task { @MainActor in
            do {
                let text = try await work()
                textView.string = text
                status.stringValue = ""
            } catch {
                textView.string = ""
                status.stringValue = error.localizedDescription
                status.textColor = .systemRed
            }
            spinner.stopAnimation(nil)
            spinner.isHidden = true
        }
    }

    @objc private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
        status.textColor = .secondaryLabelColor
        status.stringValue = L("Copied.", "已复制。")
    }

    @objc private func closeWindow() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }
}
