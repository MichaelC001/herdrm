import Foundation

/// Optional additive ping capabilities. Older daemons omit these flags.
public struct ConversationServerCapabilities: Codable, Sendable, Equatable {
    public let agentConversationRead: Bool?
    public let agentConversationBlockRead: Bool?
    public let agentConversationJump: Bool?
    public init(agentConversationRead: Bool? = nil, agentConversationBlockRead: Bool? = nil, agentConversationJump: Bool? = nil) {
        self.agentConversationRead = agentConversationRead
        self.agentConversationBlockRead = agentConversationBlockRead
        self.agentConversationJump = agentConversationJump
    }
    enum CodingKeys: String, CodingKey {
        case agentConversationRead = "agent_conversation_read"
        case agentConversationBlockRead = "agent_conversation_block_read"
        case agentConversationJump = "agent_conversation_jump"
    }
}

#if os(macOS)
/// Uses the already-connected device service for Local, SSH and Tailcat alike.
public struct ClaudeHistoryProvider: ConversationHistoryProviding {
    private let service: HerdrService
    public init(service: HerdrService) { self.service = service }
    public func read(target: String, expectedSessionID: String, window: ConversationWindow, limits: ConversationLimits = .init()) async throws -> ConversationPage {
        try await service.conversation(target: target, expectedSessionID: expectedSessionID, window: window, limits: limits)
    }
    public func readBlock(target: String, expectedSessionID: String, blockCursor: String, maxBytes: Int = 1_048_576) async throws -> BlockPage {
        try await service.conversationBlock(target: target, expectedSessionID: expectedSessionID, blockCursor: blockCursor, maxBytes: maxBytes)
    }
    public func jump(target: String, expectedSessionID: String, expectedGeneration: String, messageID: String, messageRevision: String) async throws -> ConversationJumpResult {
        try await service.conversationJump(target: target, expectedSessionID: expectedSessionID, expectedGeneration: expectedGeneration, messageID: messageID, messageRevision: messageRevision)
    }
}
#endif
