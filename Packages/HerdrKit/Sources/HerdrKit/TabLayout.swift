import CoreGraphics
import Foundation

/// How a herdr split divides its node: `right` puts the children side by side
/// (first on the left), `down` stacks them (first on top). Same wire values as
/// `pane.split --direction`.
public enum SplitDirection: String, Codable, Sendable, Equatable {
    case right
    case down
}

/// One node of a tab's layout tree as `layout.export` describes it. A pane leaf
/// carries the pane id (nil only in templates that have not been applied yet);
/// a split carries the share its first child gets.
public indirect enum LayoutNode: Codable, Sendable, Equatable {
    case pane(paneID: String?)
    case split(direction: SplitDirection, ratio: Double, first: LayoutNode, second: LayoutNode)

    /// Pane ids depth first, first child before second: the reading order of
    /// the herdr TUI (left to right, top to bottom).
    public var paneIDs: [String] {
        switch self {
        case .pane(let paneID):
            return paneID.map { [$0] } ?? []
        case .split(_, _, let first, let second):
            return first.paneIDs + second.paneIDs
        }
    }

    public var paneCount: Int { paneIDs.count }

    private enum CodingKeys: String, CodingKey {
        case type
        case paneID = "pane_id"
        case direction
        case ratio
        case first
        case second
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "pane":
            self = .pane(paneID: try container.decodeIfPresent(String.self, forKey: .paneID))
        case "split":
            self = .split(
                direction: try container.decode(SplitDirection.self, forKey: .direction),
                ratio: try container.decode(Double.self, forKey: .ratio),
                first: try container.decode(LayoutNode.self, forKey: .first),
                second: try container.decode(LayoutNode.self, forKey: .second)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "unknown layout node type \"\(type)\""
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let paneID):
            try container.encode("pane", forKey: .type)
            try container.encodeIfPresent(paneID, forKey: .paneID)
        case .split(let direction, let ratio, let first, let second):
            try container.encode("split", forKey: .type)
            try container.encode(direction, forKey: .direction)
            try container.encode(ratio, forKey: .ratio)
            try container.encode(first, forKey: .first)
            try container.encode(second, forKey: .second)
        }
    }
}

/// A tab's full layout, the `layout` object of `layout.export` and
/// `layout.set_split_ratio` responses.
public struct TabLayoutDescription: Codable, Sendable, Equatable {
    public let workspaceID: String
    public let tabID: String
    public let zoomed: Bool
    public let focusedPaneID: String?
    public let root: LayoutNode

    public init(workspaceID: String, tabID: String, zoomed: Bool, focusedPaneID: String?, root: LayoutNode) {
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.zoomed = zoomed
        self.focusedPaneID = focusedPaneID
        self.root = root
    }

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case zoomed
        case focusedPaneID = "focused_pane_id"
        case root
    }
}

/// Address of one split inside a layout tree: the first/second choices from
/// the root down, `false` = first, `true` = second. Empty is the root split.
/// Same encoding `layout.set_split_ratio` takes as `path`.
public struct SplitPath: Hashable, Sendable {
    public let steps: [Bool]

    public init(_ steps: [Bool]) { self.steps = steps }

    public func appending(_ second: Bool) -> SplitPath { SplitPath(steps + [second]) }
}

/// Where one pane of a tab goes, in the coordinate space `solve` was given.
public struct PaneFrame: Equatable, Sendable {
    public let paneID: String
    public let rect: CGRect

    public init(paneID: String, rect: CGRect) {
        self.paneID = paneID
        self.rect = rect
    }
}

/// The gap between a split's two children, where a divider is drawn and dragged.
/// `containerRect` is the split node's own rect, so a pointer position can be
/// turned back into the ratio the server stores.
public struct DividerFrame: Equatable, Sendable {
    public let path: SplitPath
    public let direction: SplitDirection
    public let rect: CGRect
    public let containerRect: CGRect

    public init(path: SplitPath, direction: SplitDirection, rect: CGRect, containerRect: CGRect) {
        self.path = path
        self.direction = direction
        self.rect = rect
        self.containerRect = containerRect
    }

    /// The first child's share if the divider sat at `point` (clamped like `solve`).
    public func ratio(at point: CGPoint) -> Double {
        let raw: CGFloat
        switch direction {
        case .right:
            raw = containerRect.width > 0 ? (point.x - containerRect.minX) / containerRect.width : 0.5
        case .down:
            raw = containerRect.height > 0 ? (point.y - containerRect.minY) / containerRect.height : 0.5
        }
        return TabLayoutGeometry.clampRatio(Double(raw))
    }
}

/// Turns a layout tree into pane frames and divider frames for a given area.
/// Pure geometry so it can be unit-tested without a view hierarchy.
public enum TabLayoutGeometry {
    /// herdr itself refuses to shrink a pane below a few cells; the same floor
    /// keeps a dragged divider from hiding a pane entirely.
    public static let ratioBounds = 0.1...0.9

    public static func clampRatio(_ ratio: Double) -> Double {
        Swift.min(Swift.max(ratio, ratioBounds.lowerBound), ratioBounds.upperBound)
    }

    public struct Solved: Equatable, Sendable {
        public var panes: [PaneFrame]
        public var dividers: [DividerFrame]
    }

    /// Lays `root` out inside `bounds`. `gap` points are taken out between a
    /// split's children for its divider. `overrides` replace the tree's ratios
    /// for the given paths (a divider drag in progress). Frames land on whole
    /// points so neighbouring Metal surfaces meet without hairlines.
    public static func solve(
        _ root: LayoutNode,
        in bounds: CGRect,
        gap: CGFloat,
        overrides: [SplitPath: Double] = [:]
    ) -> Solved {
        var solved = Solved(panes: [], dividers: [])
        place(root, in: bounds.integral, path: SplitPath([]), gap: gap, overrides: overrides, into: &solved)
        return solved
    }

    private static func place(
        _ node: LayoutNode,
        in rect: CGRect,
        path: SplitPath,
        gap: CGFloat,
        overrides: [SplitPath: Double],
        into solved: inout Solved
    ) {
        switch node {
        case .pane(let paneID):
            if let paneID {
                solved.panes.append(PaneFrame(paneID: paneID, rect: rect))
            }
        case .split(let direction, let ratio, let first, let second):
            let share = clampRatio(overrides[path] ?? ratio)
            let firstRect: CGRect
            let dividerRect: CGRect
            let secondRect: CGRect
            switch direction {
            case .right:
                let usable = max(rect.width - gap, 0)
                let firstWidth = (usable * CGFloat(share)).rounded()
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: firstWidth, height: rect.height)
                dividerRect = CGRect(x: rect.minX + firstWidth, y: rect.minY, width: min(gap, rect.width), height: rect.height)
                let secondX = rect.minX + firstWidth + dividerRect.width
                secondRect = CGRect(x: secondX, y: rect.minY, width: max(rect.maxX - secondX, 0), height: rect.height)
            case .down:
                let usable = max(rect.height - gap, 0)
                let firstHeight = (usable * CGFloat(share)).rounded()
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstHeight)
                dividerRect = CGRect(x: rect.minX, y: rect.minY + firstHeight, width: rect.width, height: min(gap, rect.height))
                let secondY = rect.minY + firstHeight + dividerRect.height
                secondRect = CGRect(x: rect.minX, y: secondY, width: rect.width, height: max(rect.maxY - secondY, 0))
            }
            place(first, in: firstRect, path: path.appending(false), gap: gap, overrides: overrides, into: &solved)
            solved.dividers.append(DividerFrame(path: path, direction: direction, rect: dividerRect, containerRect: rect))
            place(second, in: secondRect, path: path.appending(true), gap: gap, overrides: overrides, into: &solved)
        }
    }
}
