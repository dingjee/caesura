import Foundation

/// A point in the shared global desktop space: the same coordinate system
/// every display of the machine lives in (on macOS, `NSScreen.frame`).
/// All break windows of one break share ONE origin — the cursor captured
/// once at presentation — so a single wave crosses display boundaries
/// instead of restarting on each screen.
public struct GlobalPoint: Equatable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// The distance from this point to a corner of `rect`.
    public func distance(toCorner corner: GlobalRect.Corner, of rect: GlobalRect) -> Double {
        let corner = rect.corner(corner)
        let dx = corner.x - x
        let dy = corner.y - y
        return (dx * dx + dy * dy).squareRoot()
    }

    /// The distance from this point to the furthest corner of `rect`.
    public func furthestCornerDistance(of rect: GlobalRect) -> Double {
        max(distance(toCorner: .topLeft, of: rect),
            max(distance(toCorner: .topRight, of: rect),
                max(distance(toCorner: .bottomLeft, of: rect),
                    distance(toCorner: .bottomRight, of: rect))))
    }
}

/// A rectangle of one target surface (one break window) in the shared global
/// desktop space. Negative origins and displays that sit far apart are
/// ordinary values here — only the distances matter.
public struct GlobalRect: Equatable {
    public enum Corner {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public func corner(_ corner: Corner) -> GlobalPoint {
        switch corner {
        case .topLeft: return GlobalPoint(x: x, y: y + height)
        case .topRight: return GlobalPoint(x: x + width, y: y + height)
        case .bottomLeft: return GlobalPoint(x: x, y: y)
        case .bottomRight: return GlobalPoint(x: x + width, y: y)
        }
    }
}

/// The plan of one radial break reveal: the shared origin, the radius the
/// reveal reaches at full progress and the width of its soft edge.
///
/// `radius` is the distance from the origin to the furthest corner of every
/// participating window plus the feather margin, so at full progress the
/// soft edge ends exactly past the last corner — every pixel of every window
/// is fully revealed with no dimmed corner left.
public struct RadialRevealPlan: Equatable {
    public let origin: GlobalPoint
    public let radius: Double
    public let feather: Double

    /// The feather margin used when the plan is built.
    public static let defaultFeather: Double = 48

    /// Builds the plan for one break: `targets` are the frames (in the
    /// shared global space) of every window that participates in the wave.
    public init(origin: GlobalPoint, targets: [GlobalRect],
                feather: Double = RadialRevealPlan.defaultFeather) {
        self.origin = origin
        self.feather = feather
        let furthest = targets.map { origin.furthestCornerDistance(of: $0) }.max() ?? 0
        self.radius = furthest + feather
    }
}

/// The radial reveal itself: how the shared eased progress maps onto the
/// mask radius, and how a mask radius maps onto an alpha value.
///
/// The mask alpha falls linearly across the soft edge: fully opaque at and
/// inside `radius - feather`, fading to fully clear at `radius`. That makes
/// both endpoints exact: at progress 0 the radius is 0, so even the origin
/// pixel is clear (the window never flashes an unmasked frame); at progress
/// 1 the radius is `plan.radius`, so the furthest corner — which sits exactly
/// `feather` inside the radius — is fully opaque (no dimmed final corner).
public enum RadialReveal {
    /// The mask radius at the given eased progress.
    public static func radius(at progress: Double, plan: RadialRevealPlan) -> Double {
        plan.radius * min(max(progress, 0), 1)
    }

    /// The mask alpha at `distance` from the origin for a mask of `radius`
    /// with a soft edge of `feather`.
    public static func alpha(distance: Double, radius: Double, feather: Double) -> Double {
        guard radius > 0 else { return 0 }
        if feather <= 0 {
            return distance <= radius ? 1 : 0
        }
        if distance <= radius - feather {
            return 1
        }
        return min(max((radius - distance) / feather, 0), 1)
    }
}
