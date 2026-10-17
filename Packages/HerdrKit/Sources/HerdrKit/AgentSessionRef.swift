import Foundation

/// Exact provider identity reported by the origin daemon; never inferred from pane paths.
public struct AgentSessionRef: Codable, Sendable, Equatable {
    public let source: String
    public let agent: String
    public let kind: String
    public let value: String
    public init(source: String, agent: String, kind: String, value: String) {
        self.source = source; self.agent = agent; self.kind = kind; self.value = value
    }
    public var isClaudeID: Bool { source == "herdr:claude" && agent == "claude" && kind == "id" && !value.isEmpty }
    public var sessionID: String? { isClaudeID ? value : nil }
}
