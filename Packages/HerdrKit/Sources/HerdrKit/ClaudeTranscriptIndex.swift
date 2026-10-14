import Foundation

/// Conversation history read straight from a Claude Code transcript
/// (`~/.claude/projects/<project>/<session>.jsonl`), so the timeline needs nothing
/// from herdr beyond the session id it already reports. Bytes arrive in any chunking
/// (`ingest`); pages, block continuations and jump targets are answered from memory.
///
/// Only the active branch is shown: the chain from the newest record back through
/// `parentUuid`, so prompts abandoned by a rewind drop out the way they do in Claude
/// itself. A compaction starts a new chain with no parent; the walk continues from
/// the record that was newest when it was written, the end of the history before it.
/// Tool results, thinking and meta records stay out of view.
public struct ClaudeTranscriptIndex: Sendable {
    public let sessionID: String
    /// Changes whenever the reader restarts, which invalidates every cursor.
    public let generation: String
    /// Bumped by every ingest that changes the visible messages.
    public private(set) var seq = 0
    public private(set) var turns: [ConversationTurn] = []

    /// Longest block text sent inline; the rest is read through `block(cursor:)`.
    static let inlineCharacters = 16_000
    /// Prefix of a prompt's first line that the terminal jump searches for.
    static let jumpKeyCharacters = 60

    private var pending = Data()
    private var lineNumber = 0
    private var malformedLines = 0
    private var chainBroken = false
    private var nodes: [String: Node] = [:]
    /// For each chain start written after earlier records: the newest record before it.
    private var continuations: [String: String] = [:]
    private var leaf: String?
    private var records: [String: Record] = [:]
    private var messages: [Message] = []
    private var positions: [String: Int] = [:]
    private var removals: [(seq: Int, id: String)] = []
    private var turnsSeq = 0

    public init(sessionID: String, generation: String = UUID().uuidString) {
        self.sessionID = sessionID
        self.generation = generation
    }

    public var binding: ConversationBinding {
        ConversationBinding(provider: "claude", sessionID: sessionID, generation: generation)
    }
    public var revision: String { "\(generation):\(seq)" }
    public var messageCount: Int { messages.count }

    public var completeness: String {
        if malformedLines > 0 || chainBroken { return "partial_unsupported_records" }
        if !pending.isEmpty { return "partial_trailing_record" }
        return "source_available"
    }

    // MARK: - Ingest

    /// Appends transcript bytes. Returns true when the visible conversation changed.
    @discardableResult
    public mutating func ingest(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        pending.append(data)
        var consumedAny = false
        var start = pending.startIndex
        while let newline = pending[start...].firstIndex(of: 0x0A) {
            lineNumber += 1
            if consume(pending[start..<newline]) { consumedAny = true }
            start = pending.index(after: newline)
        }
        pending.removeSubrange(pending.startIndex..<start)
        return consumedAny ? rebuild() : false
    }

    private struct Node: Sendable {
        let parent: String?
        let logicalParent: String?
    }

    private struct Block: Sendable, Equatable {
        let kind: String
        let text: String?
        let label: String?
        let name: String?
    }

    private enum Content: Sendable {
        case user(origin: String, blocks: [Block], isTurn: Bool)
        case assistant(key: String, blocks: [Block])
    }

    private struct Record: Sendable {
        let line: Int
        let timestamp: String?
        let content: Content
    }

    private struct Message: Sendable {
        let id: String
        let turnID: String
        let role: String
        let origin: String
        let order: Int
        let timestamp: String?
        var blocks: [Block]
        var revision = ""
        var updatedSeq = 0
        var isTurn: Bool { role == "user" && origin == "human" && turnID == id }
    }

    /// Records the line's place in the chain and, when it is something a person would
    /// read, its content. Returns false for lines that cannot change what is shown.
    private mutating func consume(_ line: Data) -> Bool {
        guard !line.isEmpty else { return false }
        guard let object = try? JSONSerialization.jsonObject(with: line),
              let record = object as? [String: Any] else {
            malformedLines += 1
            return true
        }
        guard let uuid = record["uuid"] as? String else { return false }
        if record["isSidechain"] as? Bool == true { return false }
        let node = Node(parent: record["parentUuid"] as? String,
                        logicalParent: record["logicalParentUuid"] as? String)
        // `logicalParentUuid` is not reliable here: since Claude 2.1.29x a compact
        // boundary's points at a record written after the summary.
        if node.parent == nil, let previous = leaf, previous != uuid { continuations[uuid] = previous }
        nodes[uuid] = node
        leaf = uuid
        if let content = Self.content(of: record) {
            records[uuid] = Record(line: lineNumber, timestamp: Self.displayTime(record["timestamp"] as? String),
                                   content: content)
        }
        return true
    }

    private static func content(of record: [String: Any]) -> Content? {
        guard let type = record["type"] as? String,
              let message = record["message"] as? [String: Any] else { return nil }
        switch type {
        case "user":
            if record["isMeta"] as? Bool == true { return nil }
            return userContent(record: record, message: message)
        case "assistant":
            guard let items = message["content"] as? [[String: Any]] else { return nil }
            let blocks = items.compactMap(assistantBlock)
            guard !blocks.isEmpty else { return nil }
            let key = message["id"] as? String ?? (record["uuid"] as? String ?? UUID().uuidString)
            return .assistant(key: key, blocks: blocks)
        default:
            return nil
        }
    }

    private static func userContent(record: [String: Any], message: [String: Any]) -> Content? {
        var text = ""
        var attachments: [Block] = []
        if let string = message["content"] as? String {
            text = string
        } else if let items = message["content"] as? [[String: Any]] {
            // A tool result is the tool's output, not something a person sent.
            if items.contains(where: { $0["type"] as? String == "tool_result" }) { return nil }
            var parts: [String] = []
            for item in items {
                switch item["type"] as? String {
                case "text": if let value = item["text"] as? String { parts.append(value) }
                case "image": attachments.append(Block(kind: "image", text: nil, label: "Image", name: nil))
                case "document": attachments.append(Block(kind: "attachment", text: nil, label: "Document", name: nil))
                default: break
                }
            }
            text = parts.joined(separator: "\n\n")
        } else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if record["isCompactSummary"] as? Bool == true {
            return .user(origin: "system", blocks: [Block(kind: "text", text: trimmed, label: nil, name: nil)], isTurn: false)
        }
        if trimmed.hasPrefix("[Request interrupted") { return nil }
        for tag in ["bash-stdout", "bash-stderr", "local-command-stdout", "local-command-stderr"] where trimmed.hasPrefix("<\(tag)>") {
            let output = ["bash-stdout", "bash-stderr", "local-command-stdout", "local-command-stderr"]
                .compactMap { tagged($0, in: trimmed) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            guard !output.isEmpty else { return nil }
            return .user(origin: "tool", blocks: [Block(kind: "code", text: output, label: nil, name: nil)], isTurn: false)
        }
        if trimmed.hasPrefix("<local-command-caveat>") { return nil }
        let originKind = (record["origin"] as? [String: Any])?["kind"] as? String
        let turnOrigin = record["turnOrigin"] as? String
        var shown = trimmed
        // Records from before Claude tagged origins are a person's unless they carry
        // the envelope of a message another agent or the harness sent.
        let relayed = ["<teammate-message", "<task-notification", "<channel"].contains { trimmed.contains($0) }
        var human = !relayed && (originKind == "human" || turnOrigin == "human"
            || (originKind == nil && turnOrigin == nil && !trimmed.hasPrefix("<")))
        if let name = tagged("command-name", in: trimmed) {
            let args = tagged("command-args", in: trimmed) ?? ""
            shown = args.isEmpty ? name : "\(name) \(args)"
            human = true
        } else if let command = tagged("bash-input", in: trimmed) {
            shown = "! \(command)"
            human = true
        }
        guard !shown.isEmpty || !attachments.isEmpty else { return nil }
        var blocks = shown.isEmpty ? [] : [Block(kind: "text", text: shown, label: nil, name: nil)]
        blocks += attachments
        return .user(origin: human ? "human" : "automatic", blocks: blocks, isTurn: human)
    }

    private static func tagged(_ tag: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
              let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex) else { return nil }
        return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func assistantBlock(_ item: [String: Any]) -> Block? {
        switch item["type"] as? String {
        case "text":
            guard let text = item["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Block(kind: "text", text: text, label: nil, name: nil)
        case "tool_use", "server_tool_use":
            let name = item["name"] as? String ?? "Tool"
            return Block(kind: "tool_use", text: toolSummary(name: name, input: item["input"] as? [String: Any] ?? [:]),
                         label: nil, name: name)
        default:
            // thinking, redacted_thinking and anything newer stay out of view.
            return nil
        }
    }

    /// One readable line for a tool call: the command, path or query it was given.
    static func toolSummary(name: String, input: [String: Any]) -> String? {
        for key in ["command", "file_path", "notebook_path", "path", "pattern", "url", "query", "description", "prompt", "skill"] {
            if let value = input[key] as? String, !value.isEmpty {
                return value.count > 2_000 ? String(value.prefix(2_000)) + "…" : value
            }
        }
        guard !input.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json.count > 500 ? String(json.prefix(500)) + "…" : json
    }

    private static let isoParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func displayTime(_ raw: String?) -> String? {
        guard let raw else { return nil }
        guard let date = isoParser.date(from: raw) else { return raw }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Active branch

    /// Rebuilds the visible messages from the active branch and stamps what changed.
    private mutating func rebuild() -> Bool {
        var chain: [String] = []
        var visited = Set<String>()
        var broken = false
        var cursor = leaf
        while let id = cursor, visited.insert(id).inserted {
            guard let node = nodes[id] else { broken = true; break }
            chain.append(id)
            cursor = node.parent ?? continuations[id] ?? node.logicalParent
        }
        chainBroken = broken

        var built: [Message] = []
        var assistantSlots: [String: Int] = [:]
        var currentTurn = ""
        for id in chain.reversed() {
            guard let record = records[id] else { continue }
            switch record.content {
            case .user(let origin, let blocks, let isTurn):
                if isTurn { currentTurn = id }
                built.append(Message(id: id, turnID: currentTurn, role: "user", origin: origin,
                                     order: record.line, timestamp: record.timestamp, blocks: blocks))
            case .assistant(let key, let blocks):
                if let slot = assistantSlots[key] {
                    built[slot].blocks += blocks
                } else {
                    assistantSlots[key] = built.count
                    built.append(Message(id: "a-\(key)", turnID: currentTurn, role: "assistant", origin: "assistant",
                                         order: record.line, timestamp: record.timestamp, blocks: blocks))
                }
            }
        }

        built.sort { $0.order < $1.order }
        let nextSeq = seq + 1
        var changed = false
        for index in built.indices {
            built[index].revision = Self.revision(of: built[index])
            if let old = positions[built[index].id], messages[old].revision == built[index].revision {
                built[index].updatedSeq = messages[old].updatedSeq
            } else {
                built[index].updatedSeq = nextSeq
                changed = true
            }
        }
        let keptIDs = Set(built.map(\.id))
        for message in messages where !keptIDs.contains(message.id) {
            removals.append((nextSeq, message.id))
            changed = true
        }
        guard changed || built.count != messages.count else { return false }

        let nextTurns = built.filter(\.isTurn).enumerated().map { ordinal, message in
            ConversationTurn(id: message.id, messageID: message.id, preview: Self.preview(of: message),
                             ordinal: ordinal, timestamp: message.timestamp)
        }
        if nextTurns != turns { turns = nextTurns; turnsSeq = nextSeq }
        messages = built
        positions = Dictionary(uniqueKeysWithValues: built.enumerated().map { ($1.id, $0) })
        seq = nextSeq
        return true
    }

    private static func revision(of message: Message) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for block in message.blocks {
            for part in [block.kind, block.name ?? "", block.label ?? "", block.text ?? ""] {
                for byte in part.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
                hash = (hash ^ 0x1f) &* 0x100000001b3
            }
        }
        return "\(message.blocks.count)-\(String(hash, radix: 16))"
    }

    private static func preview(of message: Message) -> String {
        let text = message.blocks.compactMap(\.text).joined(separator: " ")
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return String(flat.prefix(160))
    }

    // MARK: - Pages

    public func page(_ window: ConversationWindow, limits: ConversationLimits = .init()) throws -> ConversationPage {
        switch window {
        case .latest:
            let range = slice(endingBefore: messages.count, limits: limits)
            return page(range: range, turns: turns, changesCursor: changesCursor)
        case .before(let cursor):
            let order = try orderCursor(cursor)
            let end = messages.firstIndex { $0.order >= order } ?? messages.count
            return page(range: slice(endingBefore: end, limits: limits))
        case .after(let cursor):
            let order = try orderCursor(cursor)
            let start = messages.firstIndex { $0.order > order } ?? messages.count
            return page(range: slice(startingAt: start, limits: limits))
        case .around(let messageID):
            guard let index = positions[messageID] else {
                return page(range: slice(endingBefore: messages.count, limits: limits), turns: turns)
            }
            let half = ConversationLimits(limit: max(1, limits.limit / 2), maxBytes: limits.maxBytes / 2)
            let lower = slice(endingBefore: index, limits: half)
            let upper = slice(startingAt: index, limits: half)
            return page(range: lower.lowerBound..<upper.upperBound)
        case .search(let query, _):
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let ids = needle.isEmpty ? [] : messages.filter { message in
                message.blocks.contains { block in
                    [block.text, block.name, block.label].contains {
                        $0?.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                    }
                }
            }.prefix(1_000).map(\.id)
            return ConversationPage(binding: binding, revision: revision, completeness: completeness,
                                    matchMessageIDs: Array(ids))
        case .turns:
            return ConversationPage(binding: binding, revision: revision, completeness: completeness, turns: turns)
        case .changes(let cursor):
            let since = try changesSeq(cursor)
            let upserts = messages.filter { $0.updatedSeq > since }.map(conversationMessage)
            let removed = removals.filter { $0.seq > since }.map(\.id)
            return ConversationPage(binding: binding, revision: revision, completeness: completeness,
                                    upserts: upserts, turns: turnsSeq > since ? turns : [],
                                    changesCursor: changesCursor, removedMessageIDs: removed)
        }
    }

    private var changesCursor: String { "\(generation)|\(seq)" }

    private func page(range: Range<Int>, turns: [ConversationTurn] = [], changesCursor: String? = nil) -> ConversationPage {
        let shown = messages[range]
        return ConversationPage(
            binding: binding, revision: revision, completeness: completeness,
            messages: shown.map(conversationMessage), turns: turns,
            beforeCursor: range.lowerBound > 0 ? shown.first.map { "\(generation)|\($0.order)" } : nil,
            afterCursor: range.upperBound < messages.count ? shown.last.map { "\(generation)|\($0.order)" } : nil,
            changesCursor: changesCursor
        )
    }

    private func slice(endingBefore end: Int, limits: ConversationLimits) -> Range<Int> {
        var start = end, bytes = 0
        while start > 0, end - start < limits.limit {
            let size = approximateSize(messages[start - 1])
            if start < end, bytes + size > limits.maxBytes { break }
            bytes += size; start -= 1
        }
        return start..<end
    }

    private func slice(startingAt start: Int, limits: ConversationLimits) -> Range<Int> {
        var end = start, bytes = 0
        while end < messages.count, end - start < limits.limit {
            let size = approximateSize(messages[end])
            if end > start, bytes + size > limits.maxBytes { break }
            bytes += size; end += 1
        }
        return start..<end
    }

    private func approximateSize(_ message: Message) -> Int {
        message.blocks.reduce(256) { $0 + min(Self.inlineCharacters, $1.text?.utf8.count ?? 0) + 64 }
    }

    private func conversationMessage(_ message: Message) -> ConversationMessage {
        let blocks = message.blocks.enumerated().map { index, block -> ConversationContentBlock in
            let id = "\(message.id)#\(index)"
            guard let text = block.text, text.count > Self.inlineCharacters else {
                return ConversationContentBlock(id: id, kind: block.kind, text: block.text, label: block.label, name: block.name)
            }
            return ConversationContentBlock(
                id: id, kind: block.kind, text: String(text.prefix(Self.inlineCharacters)),
                label: block.label, name: block.name,
                blockCursor: blockCursor(messageID: message.id, block: index, offset: Self.inlineCharacters, slice: 1),
                truncated: true
            )
        }
        return ConversationMessage(id: message.id, turnID: message.turnID, role: message.role, origin: message.origin,
                                   messageRevision: message.revision, timestamp: message.timestamp,
                                   order: message.order, blocks: blocks)
    }

    // MARK: - Block continuation

    public func block(cursor: String, maxBytes: Int = 1_048_576) throws -> BlockPage {
        let parts = cursor.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5, let blockIndex = Int(parts[2]), let offset = Int(parts[3]), let slice = Int(parts[4]),
              offset >= 0 else { throw ConversationHistoryError.invalidContinuation }
        guard parts[0] == generation else { throw ConversationHistoryError.cursorExpired }
        guard let position = positions[parts[1]], messages[position].blocks.indices.contains(blockIndex),
              let text = messages[position].blocks[blockIndex].text, offset <= text.count else {
            throw ConversationHistoryError.contentChanged
        }
        let message = messages[position]
        var piece = Substring(), bytes = 0
        var index = text.index(text.startIndex, offsetBy: offset)
        let start = index
        while index < text.endIndex, bytes < max(1024, maxBytes) {
            bytes += text[index].utf8.count
            index = text.index(after: index)
        }
        piece = text[start..<index]
        let consumed = offset + piece.count
        return BlockPage(
            binding: binding, revision: revision, messageID: message.id, messageRevision: message.revision,
            blockID: "\(message.id)#\(blockIndex)", kind: message.blocks[blockIndex].kind, text: String(piece),
            sliceIndex: slice,
            nextCursor: index < text.endIndex
                ? blockCursor(messageID: message.id, block: blockIndex, offset: consumed, slice: slice + 1) : nil
        )
    }

    private func blockCursor(messageID: String, block: Int, offset: Int, slice: Int) -> String {
        "\(generation)|\(messageID)|\(block)|\(offset)|\(slice)"
    }

    // MARK: - Jump target

    /// What to search the terminal for to find a prompt: the start of its first line,
    /// plus which of the transcript's prompts sharing that start it is.
    public struct JumpTarget: Sendable, Equatable {
        public let key: String
        public let occurrence: Int
        public let occurrences: Int
    }

    public func jumpTarget(messageID: String, messageRevision: String) throws -> JumpTarget {
        guard let position = positions[messageID] else { throw ConversationJumpNotice.sourceChanged }
        let message = messages[position]
        guard message.revision == messageRevision else { throw ConversationJumpNotice.messageChanged }
        guard message.isTurn, let key = Self.jumpKey(message) else { throw ConversationJumpNotice.unavailable }
        let sharing = messages.filter { $0.isTurn && Self.jumpKey($0) == key }
        guard let occurrence = sharing.firstIndex(where: { $0.id == messageID }) else {
            throw ConversationJumpNotice.unavailable
        }
        return JumpTarget(key: key, occurrence: occurrence, occurrences: sharing.count)
    }

    private static func jumpKey(_ message: Message) -> String? {
        guard let text = message.blocks.first(where: { $0.kind == "text" })?.text,
              let line = text.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces),
              !line.isEmpty else { return nil }
        return String(line.prefix(jumpKeyCharacters)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Cursors

    private func orderCursor(_ cursor: String) throws -> Int {
        let parts = cursor.split(separator: "|").map(String.init)
        guard parts.count == 2, parts[0] == generation, let order = Int(parts[1]) else {
            throw ConversationHistoryError.cursorExpired
        }
        return order
    }

    private func changesSeq(_ cursor: String) throws -> Int {
        let since = try orderCursor(cursor)
        guard since <= seq else { throw ConversationHistoryError.cursorExpired }
        return since
    }
}
