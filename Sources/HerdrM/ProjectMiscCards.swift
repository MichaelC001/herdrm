import HerdrKit
import SwiftUI

// The smaller cards of the Project pane: URL chips, project files and the warnings footnote.

/// Wraps subviews left to right; each line is as tall as its tallest item.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    private func place(_ subviews: Subviews, width: CGFloat) -> (points: [CGPoint], height: CGFloat) {
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return (points, y + lineHeight)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        return CGSize(width: width, height: place(subviews, width: width).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let points = place(subviews, width: bounds.width).points
        for (subview, point) in zip(subviews, points) {
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }
}

/// One URL as a rounded chip; a loopback URL on a remote host is ghost text, never a button.
struct ProjectLinkChip: View {
    let url: ProjectURL
    let isRemote: Bool

    private var label: some View {
        HStack(spacing: 5) {
            Image(systemName: "globe").font(.system(size: 9.5)).accessibilityHidden(true)
            Text(verbatim: url.label)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(Theme.itemWash, in: RoundedRectangle(cornerRadius: 6))
    }

    var body: some View {
        if isRemote && url.loopbackOnHost {
            label.foregroundStyle(Theme.textGhost).help("Only reachable from the host itself")
        } else {
            Button { ProjectURLActions.open(url) } label: { label.foregroundStyle(Theme.text) }
                .buttonStyle(.plain)
                .help("Open this URL")
                .contextMenu { Button("Copy URL") { ProjectURLActions.copy(url) } }
                .accessibilityLabel(Text(verbatim: url.label))
        }
    }
}

struct ProjectLinksCard: View {
    let urls: [ProjectURL]
    let isRemote: Bool

    var body: some View {
        if !urls.isEmpty {
            ProjectCard("Links", count: urls.count, id: .links) {
                FlowLayout {
                    ForEach(urls, id: \.url) { ProjectLinkChip(url: $0, isRemote: isRemote) }
                }
                .padding(.vertical, 6)
            }
        }
    }
}

/// Project files and the variable names (never the values) of their env files.
struct ProjectFilesCard: View {
    let files: [String]
    /// Env variable names by file; values can be secrets and never reach the view.
    let envByFile: [String: [String]]

    private static let keyLimit = 12

    private struct FileItem: Identifiable {
        let name: String
        var id: String { name }
    }

    private func fileRow(_ name: String) -> some View {
        HStack(spacing: 8) {
            ProjectKindTile(kind: .file)
            Text(verbatim: name)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .frame(minHeight: ProjectMetrics.rowHeight)
    }

    private func envRow(_ file: String, keys: [String]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ProjectKindTile(kind: .file)
            Text(verbatim: file)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 3)
            FlowLayout {
                ForEach(keys.prefix(Self.keyLimit), id: \.self) { ProjectVerbatimTag(text: $0, systemImage: "key") }
                if keys.count > Self.keyLimit { ProjectTag("+\(keys.count - Self.keyLimit) more") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .frame(minHeight: ProjectMetrics.rowHeight)
    }

    var body: some View {
        if !files.isEmpty || !envByFile.isEmpty {
            ProjectCard("Project files", count: files.count, id: .files) {
                ProjectCardList(files.map { FileItem(name: $0) }) { fileRow($0.name) }
                ForEach(Array(envByFile.keys.sorted().enumerated()), id: \.element) { index, file in
                    if index > 0 || !files.isEmpty {
                        Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 30)
                    }
                    envRow(file, keys: envByFile[file] ?? [])
                }
            }
        }
    }
}

struct ProjectWarningsFootnote: View {
    let warnings: [String]

    var body: some View {
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                SheetSectionLabel("Warnings")
                ForEach(warnings, id: \.self) { warning in
                    Text(verbatim: warning).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}
