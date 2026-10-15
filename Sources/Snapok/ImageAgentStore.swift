import AppKit

struct AgentMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable { case user, assistant }
    let id: UUID
    let role: Role
    var text: String
    /// Image file names inside the chat's folder, in display order.
    var images: [String]
    /// An assistant turn that ended with an error; `text` holds the message.
    var failed = false
    /// A cloud generation the turn planned but could not run yet (signed out, out of credits); the local edits are done.
    var pendingGeneration: String? = nil
    /// Seconds from sending the message to this reply, shown under it.
    var duration: TimeInterval? = nil
}

struct AgentChat: Codable, Identifiable, Equatable {
    /// Also the cloud conversation ID, so follow-ups reach the same agent session.
    let id: String
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var messages: [AgentMessage]
    /// Saved while a turn runs, so a turn cut short by quitting Snapok is reported on the next launch rather than
    /// left looking unfinished. `generation` is set once the cloud generation starts.
    var inFlight: InFlight? = nil

    struct InFlight: Codable, Equatable {
        var generation: String?
        /// When the cloud generation was sent, to find its result on the server.
        var startedAt: Date?
    }
}

/// Image agent conversations, kept on this Mac: `<support>/Agent/<chat id>/chat.json` plus its images.
/// A turn is planned by a model (the user's own, or Snapok Cloud's), drawn with Snapok's own tools on this Mac,
/// and only sent to the cloud image agent for what those tools can't do.
@MainActor
final class ImageAgentStore {
    static let shared = ImageAgentStore()
    static let didChange = Notification.Name("ImageAgentStore.didChange")

    private(set) var chats: [AgentChat] = []
    /// Chats with a turn in flight.
    private(set) var running: Set<String> = []
    /// Chats whose turn is waiting on the cloud image agent, which takes minutes rather than seconds.
    private(set) var generating: Set<String> = []
    /// What the cloud agent has written so far in the running turn, streamed as it works.
    private(set) var liveText: [String: String] = [:]
    /// The tools the cloud agent has run so far in the running turn, in order.
    private(set) var liveSteps: [String: [SnapokCloud.AgentStep]] = [:]
    /// When the running turn, or its cloud generation, started; the progress timer counts from it.
    private(set) var startedAt: [String: Date] = [:]
    private var notifyScheduled = false
    private let images = NSCache<NSString, NSImage>()
    private let root = AppChannel.supportDirectory.appendingPathComponent("Agent", isDirectory: true)

    private init() { load() }

    func chat(_ id: String) -> AgentChat? { chats.first { $0.id == id } }

    /// The PNG behind `image(_:in:)`, for Quick Look.
    func imageURL(_ name: String, in chatID: String) -> URL { folder(chatID).appendingPathComponent(name) }

    func image(_ name: String, in chatID: String) -> NSImage? {
        let key = "\(chatID)/\(name)" as NSString
        if let cached = images.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: folder(chatID).appendingPathComponent(name)) else { return nil }
        images.setObject(image, forKey: key)
        return image
    }

    /// Every image of a chat in conversation order, uploads and results alike.
    func allImages(in chat: AgentChat) -> [String] {
        chat.messages.flatMap(\.images)
    }

    /// The turn in flight per chat. Stopping cancels it, and whatever it would still add is dropped.
    private struct Run {
        let id: UUID
        /// When the turn started; replies record how long it took from here.
        let started = Date()
        var task: Task<Void, Never>?
        /// Set while the cloud generation runs, so a stopped turn can pick it up again with "Try Again".
        var generation: String?
    }
    private var runs: [String: Run] = [:]

    /// Sends a message, creating the chat when `chatID` is nil. Returns the chat's ID.
    /// Callers check `AgentPlanner.source` first; without one the turn fails with the reason.
    @discardableResult
    func send(_ text: String, attachments: [NSImage], to chatID: String?) -> String? {
        let id = chatID ?? UUID().uuidString.lowercased()
        guard !running.contains(id) else { return nil }
        if chat(id) == nil {
            let now = Date()
            chats.insert(AgentChat(id: id, title: Self.title(for: text), createdAt: now, updatedAt: now, messages: []), at: 0)
        }
        let history = chat(id)?.messages ?? []
        let names = attachments.compactMap { save($0, in: id) }
        // Without new attachments, work on the latest image so follow-ups build on the last result.
        let latest = chat(id).flatMap { allImages(in: $0).last }.flatMap { image($0, in: id) }
        let outgoing = attachments.isEmpty ? (latest.map { [$0] } ?? []) : attachments
        append(AgentMessage(id: UUID(), role: .user, text: text, images: names), to: id)
        // "Continue" after a reply that is waiting on a generation runs that generation, without asking the planner.
        if attachments.isEmpty, Self.isContinue(text), var chat = chat(id),
           let index = chat.messages.lastIndex(where: { $0.role == .assistant }), let pending = chat.messages[index].pendingGeneration {
            chat.messages[index].pendingGeneration = nil
            replace(chat)
            start(id) { store, run in
                await store.generate(pending, images: outgoing, chatID: id, run: run)
            }
            return id
        }
        start(id) { store, run in
            await store.turn(text, images: outgoing, history: history, chatID: id, run: run)
        }
        return id
    }

    /// Short replies that mean "go on", in the languages Snapok speaks.
    static func isContinue(_ text: String) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return ["continue", "go on", "go", "generate", "继续", "继续生成", "继续吧", "生成", "开始生成", "好", "好的", "可以"].contains(normalized)
    }

    /// Stops the chat's turn. Local edits already shown stay; "Try Again" reruns the turn or the cloud generation.
    func stop(_ chatID: String) {
        guard let run = runs[chatID] else { return }
        run.task?.cancel()
        finish(chatID)
        append(AgentMessage(id: UUID(), role: .assistant, text: L("Stopped.", "已停止。"), images: [], failed: true,
                            pendingGeneration: run.generation, duration: Date().timeIntervalSince(run.started)), to: chatID)
        notify()
    }

    private func start(_ chatID: String, _ work: @escaping @MainActor (ImageAgentStore, UUID) async -> AgentMessage) {
        let id = UUID()
        runs[chatID] = Run(id: id)
        running.insert(chatID)
        startedAt[chatID] = Date()
        markInFlight(chatID, generation: nil, startedAt: nil)
        notify()
        runs[chatID]?.task = Task { [weak self] in
            guard let self else { return }
            var reply = await work(self, id)
            guard isCurrent(id, chatID) else { return }
            reply.duration = runs[chatID].map { Date().timeIntervalSince($0.started) }
            finish(chatID)
            append(reply, to: chatID)
            AgentNotifier.shared.taskFinished(chatID: chatID, title: chat(chatID)?.title ?? "", reply: reply)
            notify()
        }
    }

    /// Stops a generation that ran past `generationTimeout`, keeping its instruction so "Try Again" runs it again.
    private func timeOut(_ chatID: String, run: UUID, instruction: String) {
        guard let current = runs[chatID], current.id == run else { return }
        log("image agent generation timed out")
        current.task?.cancel()
        finish(chatID)
        let minutes = Int(Self.generationTimeout / 60)
        let reply = AgentMessage(id: UUID(), role: .assistant,
                                 text: L("This generation took over \(minutes) minutes, so it was stopped. Try again.",
                                         "生成超过 \(minutes) 分钟还没完成，已自动停止，可以重试。"),
                                 images: [], failed: true, pendingGeneration: instruction,
                                 duration: Date().timeIntervalSince(current.started))
        append(reply, to: chatID)
        notify()
        AgentNotifier.shared.taskFinished(chatID: chatID, title: chat(chatID)?.title ?? "", reply: reply)
    }

    private func isCurrent(_ run: UUID, _ chatID: String) -> Bool {
        runs[chatID]?.id == run && !Task.isCancelled
    }

    private func finish(_ chatID: String) {
        if var chat = chat(chatID), chat.inFlight != nil {
            chat.inFlight = nil
            replace(chat)
        }
        runs[chatID] = nil
        running.remove(chatID)
        generating.remove(chatID)
        liveText[chatID] = nil
        liveSteps[chatID] = nil
        startedAt[chatID] = nil
    }

    /// Plans with a model, applies the local ops, then runs the cloud generation when there is one and it can be paid for.
    private func turn(_ text: String, images: [NSImage], history: [AgentMessage], chatID: String, run: UUID) async -> AgentMessage {
        do {
            guard let source = AgentPlanner.source else { throw CloudError.signedOut }
            let base = images.first?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            var targets: [AgentTarget] = []
            if let base { targets = await AgentPlanner.targets(in: base) }
            try Task.checkCancellation()
            let input = AgentPlanner.input(instruction: text, history: history, targets: targets, hasImage: base != nil)
            let plan = try await AgentPlanner.plan(source, image: base, input: input)
            try Task.checkCancellation()
            // Translation redraws the text first; the drawing ops then go on top, at the same positions.
            var working = base
            var translated: NSImage?
            if let target = plan.translation, let image = base {
                let result = try await AgentTranslator.translate(image, to: target)
                try Task.checkCancellation()
                working = result
                translated = NSImage(cgImage: result, size: images.first?.size ?? CGSize(width: result.width, height: result.height))
            }
            let edited = working.flatMap { AgentToolRunner.apply(plan.localOps, to: $0, targets: targets) } ?? translated
            var reply = AgentMessage(id: UUID(), role: .assistant, text: plan.reply, images: edited.flatMap { save($0, in: chatID) }.map { [$0] } ?? [])
            guard let generation = plan.generation(fallback: text) else {
                if reply.text.isEmpty && reply.images.isEmpty { throw AIError.emptyResponse }
                return reply
            }
            // Generation needs Snapok Cloud; the local edits stay either way. The reason it is blocked is shown
            // live under the reply (it changes once the user signs in or buys credits), so it is not saved in the text.
            if SnapokCloud.isSignedIn { await SnapokCloud.refreshAccount() }
            if Self.generationBlocked() != nil {
                reply.pendingGeneration = generation
                return reply
            }
            // Show the local result now rather than after the minutes the generation takes.
            if !reply.text.isEmpty || !reply.images.isEmpty, isCurrent(run, chatID) {
                reply.duration = runs[chatID].map { Date().timeIntervalSince($0.started) }
                append(reply, to: chatID)
            }
            return await generate(generation, images: edited.map { [$0] } ?? images, chatID: chatID, run: run)
        } catch {
            log("image agent turn failed", error: error)
            return AgentMessage(id: UUID(), role: .assistant, text: error.localizedDescription, images: [], failed: true)
        }
    }

    /// Longest a cloud generation may take, streaming plus picking up a lost result, before it is stopped.
    /// They usually finish in 1–3 minutes; past this the server or the agent is stuck.
    static let generationTimeout: TimeInterval = 10 * 60

    /// Runs a cloud generation; a failure keeps the instruction so "Try Again" runs it again.
    private func generate(_ instruction: String, images: [NSImage], chatID: String, run: UUID) async -> AgentMessage {
        guard isCurrent(run, chatID) else { return AgentMessage(id: UUID(), role: .assistant, text: "", images: []) }
        let sent = Date()
        // Independent of the network: a stream that stalls without closing, or a result that stays "pending", still ends.
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.generationTimeout))
            guard !Task.isCancelled else { return }
            self?.timeOut(chatID, run: run, instruction: instruction)
        }
        defer { watchdog.cancel() }
        generating.insert(chatID)
        startedAt[chatID] = sent
        runs[chatID]?.generation = instruction
        markInFlight(chatID, generation: instruction, startedAt: sent)
        notify()
        do {
            let edit = try await SnapokCloud.editImage(images, instruction: instruction, conversationID: chatID, onText: { [weak self] text in
                guard let self, isCurrent(run, chatID) else { return }
                liveText[chatID, default: ""] += text
                notifySoon()
            }, onStep: { [weak self] step in
                guard let self, isCurrent(run, chatID) else { return }
                var steps = liveSteps[chatID] ?? []
                if let index = steps.firstIndex(where: { $0.id == step.id }) { steps[index] = step } else { steps.append(step) }
                liveSteps[chatID] = steps
                notifySoon()
            })
            return resultMessage(edit, instruction: instruction, chatID: chatID)
        } catch {
            log("image agent generation failed", error: error)
            // The server finishes the generation even when the connection drops, so pick its result up there.
            if let cloud = error as? CloudError, case .interrupted = cloud {
                return await awaitResult(instruction, since: sent, chatID: chatID, run: run)
            }
            if let cloud = error as? CloudError, case .unreachable = cloud {
                return await awaitResult(instruction, since: sent, chatID: chatID, run: run)
            }
            return AgentMessage(id: UUID(), role: .assistant, text: error.localizedDescription, images: [], failed: true, pendingGeneration: instruction)
        }
    }

    /// Generation was asked for, so a reply without an image failed (the server refunds it); keep what the agent
    /// said, and let "Try Again" run the generation again.
    private func resultMessage(_ edit: SnapokCloud.ImageEdit, instruction: String, chatID: String) -> AgentMessage {
        guard let name = edit.image.flatMap({ save($0, in: chatID) }) else {
            let note = L("No image came back, and no credits were charged. Try again.", "没有生成图片，本次未扣积分，可以重试。")
            return AgentMessage(id: UUID(), role: .assistant, text: [edit.reply, note].filter { !$0.isEmpty }.joined(separator: "\n\n"),
                                images: [], failed: true, pendingGeneration: instruction)
        }
        return AgentMessage(id: UUID(), role: .assistant, text: edit.reply, images: [name])
    }

    /// Waits for a generation this app lost track of (it quit, or the connection dropped) by asking the server,
    /// which keeps running it. Gives up after 20 minutes, or when the server never got it or it failed.
    private func awaitResult(_ instruction: String, since: Date, chatID: String, run: UUID) async -> AgentMessage {
        let lost = AgentMessage(id: UUID(), role: .assistant,
                                text: L("The result of this generation didn't come back. Try again to generate it.",
                                        "这次生成没有拿到结果，可以重试，重新生成。"),
                                images: [], failed: true, pendingGeneration: instruction)
        var errors = 0
        while Date().timeIntervalSince(since) < Self.generationTimeout {
            guard isCurrent(run, chatID) else { return lost }
            do {
                switch try await SnapokCloud.generationResult(conversationID: chatID, since: since) {
                case .done(let edit): return resultMessage(edit, instruction: instruction, chatID: chatID)
                case .failed, .missing: return lost
                case .pending: errors = 0
                }
            } catch {
                if let cloud = error as? CloudError, case .signedOut = cloud { return lost }
                errors += 1
                log("checking an agent result failed", error: error)
                if errors >= 6 { return lost }
            }
            do { try await Task.sleep(for: .seconds(5)) } catch { return lost }
        }
        return lost
    }

    /// Picks up a generation that was running when Snapok quit: shows it as generating and waits for the server's result.
    private func resumeGeneration(_ chatID: String, instruction: String, since: Date) {
        start(chatID) { store, run in
            store.generating.insert(chatID)
            store.startedAt[chatID] = since
            store.runs[chatID]?.generation = instruction
            store.markInFlight(chatID, generation: instruction, startedAt: since)
            store.notify()
            return await store.awaitResult(instruction, since: since, chatID: chatID, run: run)
        }
    }

    /// Why a cloud generation can't run right now, or nil when it can. The server checks credits again.
    static func generationBlocked() -> String? {
        guard SnapokCloud.isSignedIn else {
            return SnapokCloud.isAvailable
                ? L("Generating this needs Snapok Cloud. Sign in to continue.", "这一步需要 Snapok 云端生成，登录后即可继续。")
                : L("Generating this needs Snapok Cloud, which builds from source don't include.", "这一步需要 Snapok 云端生成，源码构建的版本不包含云端功能。")
        }
        if let account = SnapokCloud.account, !account.canAffordTurn {
            return L("Generating this needs \(account.cost) credits; you have \(account.balance).",
                     "这一步需要云端生成，需要 \(account.cost) 积分，当前剩余 \(account.balance)。")
        }
        return nil
    }

    /// Runs the generation the last reply left pending, on the chat's latest image.
    func resumeGeneration(_ chatID: String) {
        guard !running.contains(chatID), var chat = chat(chatID), let last = chat.messages.last,
              last.role == .assistant, let instruction = last.pendingGeneration else { return }
        // A stopped or failed attempt is replaced by the new one; a reply with local edits stays.
        if last.failed {
            chat.messages.removeLast()
        } else {
            chat.messages[chat.messages.count - 1].pendingGeneration = nil
        }
        replace(chat)
        let input = allImages(in: chat).last.flatMap { image($0, in: chatID) }.map { [$0] } ?? []
        start(chatID) { store, run in
            await store.generate(instruction, images: input, chatID: chatID, run: run)
        }
    }

    /// Sends the user message before a failed reply again.
    func retry(_ chatID: String) {
        if chat(chatID)?.messages.last?.pendingGeneration != nil { return resumeGeneration(chatID) }
        guard var chat = chat(chatID), chat.messages.last?.failed == true,
              let index = chat.messages.lastIndex(where: { $0.role == .user }) else { return }
        let message = chat.messages[index]
        let attachments = message.images.compactMap { image($0, in: chatID) }
        chat.messages.removeSubrange(index...)
        replace(chat)
        send(message.text, attachments: attachments, to: chatID)
    }

    func rename(_ chatID: String, to title: String) {
        guard var chat = chat(chatID) else { return }
        chat.title = title
        replace(chat)
        notify()
    }

    func delete(_ chatID: String) {
        chats.removeAll { $0.id == chatID }
        try? FileManager.default.removeItem(at: folder(chatID))
        notify()
    }

    // MARK: Storage

    private func folder(_ chatID: String) -> URL { root.appendingPathComponent(chatID, isDirectory: true) }

    private static func title(for text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > 40 ? String(line.prefix(40)) + "…" : line
    }

    private func save(_ image: NSImage, in chatID: String) -> String? {
        guard let png = image.pngData else { return nil }
        let name = "\(UUID().uuidString.lowercased()).png"
        do {
            try FileManager.default.createDirectory(at: folder(chatID), withIntermediateDirectories: true)
            try png.write(to: folder(chatID).appendingPathComponent(name), options: .atomic)
        } catch {
            log("saving agent image failed", error: error)
            return nil
        }
        images.setObject(image, forKey: "\(chatID)/\(name)" as NSString)
        return name
    }

    private func append(_ message: AgentMessage, to chatID: String) {
        guard var chat = chat(chatID) else { return }
        chat.messages.append(message)
        chat.updatedAt = Date()
        replace(chat)
        chats.sort { $0.updatedAt > $1.updatedAt }
    }

    private func replace(_ chat: AgentChat) {
        guard let index = chats.firstIndex(where: { $0.id == chat.id }) else { return }
        chats[index] = chat
        write(chat)
    }

    private func write(_ chat: AgentChat) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: folder(chat.id), withIntermediateDirectories: true)
            try encoder.encode(chat).write(to: folder(chat.id).appendingPathComponent("chat.json"), options: .atomic)
        } catch {
            log("saving agent chat failed", error: error)
        }
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        chats = folders.compactMap { folder in
            (try? Data(contentsOf: folder.appendingPathComponent("chat.json"))).flatMap { try? decoder.decode(AgentChat.self, from: $0) }
        }.sorted { $0.updatedAt > $1.updatedAt }
        for chat in chats {
            guard let inFlight = chat.inFlight else { continue }
            // A cloud generation keeps running on the server, so wait for its result there; anything else is lost.
            if let generation = inFlight.generation, let since = inFlight.startedAt, SnapokCloud.isSignedIn {
                Task { @MainActor in self.resumeGeneration(chat.id, instruction: generation, since: since) }
            } else {
                reportInterrupted(chat)
            }
        }
    }

    private func markInFlight(_ chatID: String, generation: String?, startedAt: Date?) {
        guard var chat = chat(chatID) else { return }
        chat.inFlight = AgentChat.InFlight(generation: generation, startedAt: startedAt)
        replace(chat)
    }

    /// Nothing runs at launch, so a saved in-flight turn was cut short when Snapok quit. Say so (the planner reads it
    /// too, instead of guessing the work is still going) and let "Try Again" run it again.
    private func reportInterrupted(_ chat: AgentChat) {
        var chat = chat
        let generation = chat.inFlight?.generation
        chat.inFlight = nil
        chat.messages.append(AgentMessage(
            id: UUID(), role: .assistant,
            text: generation == nil
                ? L("This reply was interrupted because Snapok quit. Try again.", "Snapok 退出了，这次回复被中断，可以重试。")
                : L("Snapok quit while the image was generating, so the result never arrived. Try again to generate it.",
                    "生成图片时 Snapok 退出了，结果没有返回。可以重试，重新生成。"),
            images: [], failed: true, pendingGeneration: generation))
        replace(chat)
    }

    /// Coalesces streamed updates so the transcript redraws a few times a second, not per token.
    private func notifySoon() {
        guard !notifyScheduled else { return }
        notifyScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                self?.notifyScheduled = false
                self?.notify()
            }
        }
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
