import HerdrKit
import SwiftUI

/// Native, inert transcript rendering. Text links and attachment paths never open automatically.
struct ConversationMessageView: View {
    let message: ConversationMessage
    var readFullAction: (() -> Void)? = nil
    let copyAction: () -> Void

    static func speaker(for role: String, origin: String = "unknown") -> String {
        switch role {
        case "user":
            switch origin {
            case "human": return String(localized: "You")
            case "automatic", "auto": return String(localized: "Automatic message")
            case "tool", "tool_result": return String(localized: "Tool result")
            case "system", "system_injected": return String(localized: "System message")
            default: return String(localized: "Message of unknown origin")
            }
        case "assistant": return "Claude"
        case "system": return String(localized: "System")
        case "tool": return String(localized: "Tool activity")
        default: return String(localized: "Other message")
        }
    }

    static func isTool(_ block: ConversationContentBlock) -> Bool {
        ["tool_use", "tool_result", "tool_call", "tool_output"].contains(block.kind)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(Self.speaker(for: message.role, origin: message.origin))
                    .font(.system(size: 12, weight: .semibold))
                    .accessibilityLabel(Self.speaker(for: message.role, origin: message.origin))
                    .accessibilityIdentifier("history.speaker.\(message.id)")
                if let timestamp = message.timestamp {
                    Text(timestamp).font(.system(size: 10)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if ["user", "assistant"].contains(message.role) {
                    Button(action: copyAction) { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.plain)
                        .help("Copy full message")
                        .accessibilityLabel("Copy full message")
                        .accessibilityIdentifier("history.copy.\(message.id)")
                }
            }
            ForEach(message.blocks.filter { !Self.isTool($0) }, id: \.id) { block in
                content(block)
            }
            let tools = message.blocks.filter(Self.isTool)
            if !tools.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(tools, id: \.id) { block in
                            VStack(alignment: .leading, spacing: 4) {
                                if let name = block.name ?? block.label { Text(name).font(.system(size: 11, weight: .medium)) }
                                if let text = block.text { code(text) }
                                continuation(block)
                            }
                        }
                    }.padding(.top, 8)
                } label: {
                    Label("Tool activity (\(tools.count))", systemImage: "wrench.and.screwdriver")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
            }
            if message.status == "pending" {
                Text("Message is still being saved").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
            }
            if message.blocks.contains(where: { $0.truncated && $0.isCopyableText }), let readFullAction {
                Button("Read full message", action: readFullAction)
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .accessibilityIdentifier("history.readFull.\(message.id)")
            }
        }
        .foregroundStyle(Theme.text)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.role == "user" && message.origin == "human" ? Theme.accentWash : Theme.itemWash, in: RoundedRectangle(cornerRadius: 9))
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { _ in .discarded })
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("history.message.\(message.id)")
    }

    @ViewBuilder private func content(_ block: ConversationContentBlock) -> some View {
        switch block.kind {
        case "text", "markdown":
            if let text = block.text { markdown(text) }
        case "code":
            if let text = block.text { code(text) }
        case "attachment", "image", "file":
            let label = block.label ?? block.name ?? String(localized: "Attachment")
            Label(label, systemImage: "paperclip")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "Attachment: \(label)"))
                .accessibilityIdentifier("history.attachment.\(block.id)")
        default:
            if let label = block.label ?? block.name { Text(label).font(.system(size: 11, weight: .medium)) }
            if let text = block.text { Text(verbatim: text).font(.system(size: 13)) }
        }
        continuation(block)
    }

    @ViewBuilder private func continuation(_ block: ConversationContentBlock) -> some View {
        if block.truncated {
            Text("Preview shortened.")
                .font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
        }
    }

    private func code(_ text: String) -> some View {
        ScrollView(.horizontal) {
            Text(verbatim: text).font(.system(size: 12, design: .monospaced))
                .accessibilityLabel(text)
                .fixedSize(horizontal: true, vertical: false).padding(8)
        }.background(Theme.terminalBackground, in: RoundedRectangle(cornerRadius: 5))
    }

    private func markdown(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(ConversationMarkdown.segments(text).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .code(let value): code(value)
                case .text(let value):
                    Text((try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value))
                        .accessibilityLabel(value)
                        .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Fenced code stays literal; prose retains source paragraph breaks and inline Markdown.
enum ConversationMarkdown {
    enum Segment: Equatable { case text(String), code(String) }
    static func segments(_ source: String) -> [Segment] {
        var result: [Segment] = []
        var lines: [String] = []
        var fence: String?
        func flush() {
            guard !lines.isEmpty else { return }
            result.append(fence == nil ? .text(lines.joined(separator: "\n")) : .code(lines.joined(separator: "\n")))
            lines.removeAll(keepingCapacity: true)
        }
        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if fence == nil, trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                fence = String(trimmed.prefix(3))
            } else if let delimiter = fence, trimmed.hasPrefix(delimiter) {
                flush()
                fence = nil
            } else {
                lines.append(line)
            }
        }
        flush()
        return result
    }
}
