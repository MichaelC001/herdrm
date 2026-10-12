import Foundation

public struct ConversationBinding: Codable, Sendable, Equatable {
    public let provider: String
    public let sessionID: String
    public let generation: String
    public init(provider: String, sessionID: String, generation: String) {
        self.provider = provider
        self.sessionID = sessionID
        self.generation = generation
    }
    enum CodingKeys: String, CodingKey {
        case provider
        case sessionID = "session_id"
        case generation
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(String.self, forKey: .provider)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        generation = try c.decode(String.self, forKey: .generation)
    }
}

public struct ConversationContentBlock: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: String
    public let text: String?
    public let label: String?
    public let name: String?
    public let blockCursor: String?
    public let truncated: Bool
    public init(id: String, kind: String, text: String? = nil, label: String? = nil, name: String? = nil, blockCursor: String? = nil, truncated: Bool = false) {
        self.id = id
        self.kind = kind
        self.text = text
        self.label = label
        self.name = name
        self.blockCursor = blockCursor
        self.truncated = truncated
    }
    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case text
        case label
        case name
        case blockCursor = "block_cursor"
        case truncated
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(String.self, forKey: .kind)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        blockCursor = try c.decodeIfPresent(String.self, forKey: .blockCursor)
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}

public struct ConversationMessage: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let turnID: String
    public let role: String
    public let origin: String
    public let status: String
    public let messageRevision: String
    public let parentID: String?
    public let timestamp: String?
    public let order: Int
    public let blocks: [ConversationContentBlock]
    public init(id: String, turnID: String = "", role: String = "unknown", origin: String = "unknown", status: String = "recorded", messageRevision: String = "", parentID: String? = nil, timestamp: String? = nil, order: Int = 0, blocks: [ConversationContentBlock] = []) {
        self.id = id
        self.turnID = turnID
        self.role = role
        self.origin = origin
        self.status = status
        self.messageRevision = messageRevision
        self.parentID = parentID
        self.timestamp = timestamp
        self.order = order
        self.blocks = blocks
    }
    enum CodingKeys: String, CodingKey {
        case id
        case turnID = "turn_id"
        case role
        case origin
        case status
        case messageRevision = "message_revision"
        case parentID = "parent_id"
        case timestamp
        case order
        case blocks
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        turnID = try c.decodeIfPresent(String.self, forKey: .turnID) ?? ""
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? "unknown"
        origin = try c.decodeIfPresent(String.self, forKey: .origin) ?? "unknown"
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "recorded"
        messageRevision = try c.decodeIfPresent(String.self, forKey: .messageRevision) ?? ""
        parentID = try c.decodeIfPresent(String.self, forKey: .parentID)
        timestamp = try c.decodeIfPresent(String.self, forKey: .timestamp)
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        blocks = try c.decodeIfPresent([ConversationContentBlock].self, forKey: .blocks) ?? []
    }
}

public struct ConversationTurn: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let messageID: String
    public let preview: String
    public let ordinal: Int
    public let timestamp: String?
    public init(id: String, messageID: String, preview: String = "", ordinal: Int = 0, timestamp: String? = nil) {
        self.id = id
        self.messageID = messageID
        self.preview = preview
        self.ordinal = ordinal
        self.timestamp = timestamp
    }
    enum CodingKeys: String, CodingKey {
        case id
        case messageID = "message_id"
        case preview
        case ordinal
        case timestamp
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        messageID = try c.decode(String.self, forKey: .messageID)
        preview = try c.decodeIfPresent(String.self, forKey: .preview) ?? ""
        ordinal = try c.decodeIfPresent(Int.self, forKey: .ordinal) ?? 0
        timestamp = try c.decodeIfPresent(String.self, forKey: .timestamp)
    }
}

public struct ConversationPage: Codable, Sendable, Equatable {
    public let binding: ConversationBinding?
    public let revision: String
    public let availability: String
    public let completeness: String
    public let messages: [ConversationMessage]
    public let upserts: [ConversationMessage]
    public let turns: [ConversationTurn]
    public let beforeCursor: String?
    public let afterCursor: String?
    public let turnsCursor: String?
    public let searchCursor: String?
    public let changesCursor: String?
    public let removedMessageIDs: [String]
    public let matchMessageIDs: [String]
    public init(binding: ConversationBinding? = nil, revision: String = "", availability: String = "ready", completeness: String = "source_available", messages: [ConversationMessage] = [], upserts: [ConversationMessage] = [], turns: [ConversationTurn] = [], beforeCursor: String? = nil, afterCursor: String? = nil, turnsCursor: String? = nil, searchCursor: String? = nil, changesCursor: String? = nil, removedMessageIDs: [String] = [], matchMessageIDs: [String] = []) {
        self.binding = binding
        self.revision = revision
        self.availability = availability
        self.completeness = completeness
        self.messages = messages
        self.upserts = upserts
        self.turns = turns
        self.beforeCursor = beforeCursor
        self.afterCursor = afterCursor
        self.turnsCursor = turnsCursor
        self.searchCursor = searchCursor
        self.changesCursor = changesCursor
        self.removedMessageIDs = removedMessageIDs
        self.matchMessageIDs = matchMessageIDs
    }
    enum CodingKeys: String, CodingKey {
        case binding
        case revision
        case availability
        case completeness
        case messages
        case upserts
        case turns
        case beforeCursor = "before_cursor"
        case afterCursor = "after_cursor"
        case turnsCursor = "turns_cursor"
        case searchCursor = "search_cursor"
        case changesCursor = "changes_cursor"
        case removedMessageIDs = "removed_message_ids"
        case matchMessageIDs = "match_message_ids"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        binding = try c.decodeIfPresent(ConversationBinding.self, forKey: .binding)
        revision = try c.decodeIfPresent(String.self, forKey: .revision) ?? ""
        availability = try c.decodeIfPresent(String.self, forKey: .availability) ?? "ready"
        completeness = try c.decodeIfPresent(String.self, forKey: .completeness) ?? "source_available"
        messages = try c.decodeIfPresent([ConversationMessage].self, forKey: .messages) ?? []
        upserts = try c.decodeIfPresent([ConversationMessage].self, forKey: .upserts) ?? []
        turns = try c.decodeIfPresent([ConversationTurn].self, forKey: .turns) ?? []
        beforeCursor = try c.decodeIfPresent(String.self, forKey: .beforeCursor)
        afterCursor = try c.decodeIfPresent(String.self, forKey: .afterCursor)
        turnsCursor = try c.decodeIfPresent(String.self, forKey: .turnsCursor)
        searchCursor = try c.decodeIfPresent(String.self, forKey: .searchCursor)
        changesCursor = try c.decodeIfPresent(String.self, forKey: .changesCursor)
        removedMessageIDs = try c.decodeIfPresent([String].self, forKey: .removedMessageIDs) ?? []
        matchMessageIDs = try c.decodeIfPresent([String].self, forKey: .matchMessageIDs) ?? []
    }
}

public struct BlockPage: Codable, Sendable, Equatable {
    public let binding: ConversationBinding
    public let revision: String
    public let messageID: String
    public let messageRevision: String
    public let blockID: String
    public let kind: String
    public let text: String
    public let sliceIndex: Int
    public let nextCursor: String?
    public init(binding: ConversationBinding, revision: String, messageID: String, messageRevision: String, blockID: String, kind: String, text: String, sliceIndex: Int, nextCursor: String? = nil) {
        self.binding = binding
        self.revision = revision
        self.messageID = messageID
        self.messageRevision = messageRevision
        self.blockID = blockID
        self.kind = kind
        self.text = text
        self.sliceIndex = sliceIndex
        self.nextCursor = nextCursor
    }
    enum CodingKeys: String, CodingKey {
        case binding
        case revision
        case messageID = "message_id"
        case messageRevision = "message_revision"
        case blockID = "block_id"
        case kind
        case text
        case sliceIndex = "slice_index"
        case nextCursor = "next_cursor"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        binding = try c.decode(ConversationBinding.self, forKey: .binding)
        revision = try c.decode(String.self, forKey: .revision)
        messageID = try c.decode(String.self, forKey: .messageID)
        messageRevision = try c.decode(String.self, forKey: .messageRevision)
        blockID = try c.decode(String.self, forKey: .blockID)
        kind = try c.decode(String.self, forKey: .kind)
        text = try c.decode(String.self, forKey: .text)
        sliceIndex = try c.decode(Int.self, forKey: .sliceIndex)
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

extension ConversationContentBlock {
    /// Future block kinds remain inert textual data. Attachment bodies are never decoded here.
    public var visibleText: String {
        if kind == "image" || kind == "attachment" { return label ?? name ?? "Attachment" }
        return text ?? label ?? name ?? ""
    }
    public var isCopyableText: Bool { kind != "image" && kind != "attachment" && text != nil }
}
extension ConversationMessage {
    public var visibleText: String { blocks.map(\.visibleText).filter { !$0.isEmpty }.joined(separator: "\n\n") }
    public var preview: String { String(visibleText.prefix(160)) }
}

public enum ConversationWindow: Sendable, Equatable {
    case latest
    case before(cursor: String)
    case after(cursor: String)
    case around(messageID: String)
    case search(query: String, cursor: String? = nil)
    case turns(cursor: String? = nil)
    case changes(cursor: String)

    public var json: JSONValue {
        switch self {
        case .latest: return .object(["kind": .string("latest")])
        case .before(let cursor): return .object(["kind": .string("before"), "cursor": .string(cursor)])
        case .after(let cursor): return .object(["kind": .string("after"), "cursor": .string(cursor)])
        case .around(let id): return .object(["kind": .string("around"), "message_id": .string(id)])
        case .search(let query, let cursor): return .object(["kind": .string("search"), "query": .string(query), "cursor": cursor.map(JSONValue.string) ?? .null])
        case .turns(let cursor): return .object(["kind": .string("turns"), "cursor": cursor.map(JSONValue.string) ?? .null])
        case .changes(let cursor): return .object(["kind": .string("changes"), "cursor": .string(cursor)])
        }
    }
}

public struct ConversationLimits: Sendable, Equatable {
    public let limit: Int
    public let maxBytes: Int
    public init(limit: Int = 100, maxBytes: Int = 1_048_576) {
        self.limit = min(200, max(1, limit))
        self.maxBytes = min(1_048_576, max(1024, maxBytes))
    }
}

public protocol ConversationHistoryProviding: Sendable {
    func read(target: String, expectedSessionID: String, window: ConversationWindow, limits: ConversationLimits) async throws -> ConversationPage
    func readBlock(target: String, expectedSessionID: String, blockCursor: String, maxBytes: Int) async throws -> BlockPage
}

public enum ConversationHistoryError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedServer, disconnected, sessionChanged, cursorExpired, contentChanged, invalidContinuation
    public var errorDescription: String? {
        switch self {
        case .unsupportedServer: return "This herdr server does not support saved conversation history."
        case .disconnected: return "Conversation history is disconnected."
        case .sessionChanged: return "The selected Claude session changed."
        case .cursorExpired: return "Saved conversation history changed; reloading is required."
        case .contentChanged: return "The message changed while copying. Try again."
        case .invalidContinuation: return "The server returned an invalid text continuation."
        }
    }
    public static func map(_ error: Error) -> Error {
        guard let error = error as? HerdrError else { return error }
        switch error {
        case .rpc(let code, _):
            switch code {
            case "session_changed": return Self.sessionChanged
            case "cursor_expired": return Self.cursorExpired
            case "unknown_method", "method_not_found", "unsupported_method": return Self.unsupportedServer
            default: return error
            }
        case .connectionFailed, .socketUnavailable, .remoteHerdrDown, .tunnelFailed, .tailcatBridgeFailed: return Self.disconnected
        default: return error
        }
    }
}
