import CoreGraphics
import SwiftUI
import CaesuraCore

/// The type scale of the break window. Every role derives from one responsive
/// base (a fraction of the window height) in steps of the golden ratio φ, so
/// the hierarchy stays consistent at every window size; the per-role clamps
/// keep extreme window heights readable instead of scaling blindly.
enum BreakTypography {
    static let ratio: CGFloat = 1.618

    enum Role {
        /// The poem / long-break title. The name of the poem trails the author,
        /// so it stays below the body of the poem.
        case title
        /// The idea body: the poem text of a long break, the mini idea.
        case body
        /// The author line under the poem.
        case attribution
        /// The clock in the break.
        case clock
        /// The countdown, the elapsed time and other secondary lines.
        case secondary
        /// Break action buttons.
        case controls

        /// Distance from the base in powers of φ.
        var steps: CGFloat {
            switch self {
            case .title: return 0
            case .body: return 1
            case .attribution: return -0.5
            case .clock: return -2
            case .secondary: return -1
            case .controls: return -1
            }
        }

        var minimum: CGFloat {
            switch self {
            case .title: return 14
            case .body: return 18
            case .attribution: return 12
            case .clock: return 10
            case .secondary: return 13
            case .controls: return 12
            }
        }

        var maximum: CGFloat {
            switch self {
            case .title: return 30
            case .body: return 42
            case .attribution: return 26
            case .clock: return 18
            case .secondary: return 22
            case .controls: return 18
            }
        }
    }

    /// The base size: 1/22 of the window height, clamped to a readable range.
    static func base(forHeight height: CGFloat) -> CGFloat {
        min(max(height / 22, 17), 30)
    }

    static func size(_ role: Role, forHeight height: CGFloat) -> CGFloat {
        let raw = base(forHeight: height) * pow(ratio, role.steps)
        return min(max(raw, role.minimum), role.maximum)
    }

    /// The serif face of the poem text (the system serif, New York on macOS),
    /// so the verses read differently from the interface.
    static func serif(_ role: Role, height: CGFloat, weight: Font.Weight = .regular,
                      italic: Bool = false) -> Font {
        serif(size: size(role, forHeight: height), weight: weight, italic: italic)
    }

    /// The same face at an explicit size.
    ///
    /// The body of a poem is measured before it is drawn (its size decides how
    /// much of it fits into the window), so the face is needed at a size the
    /// type scale does not know.
    static func serif(size: CGFloat, weight: Font.Weight = .regular,
                      italic: Bool = false) -> Font {
        let font = Font.system(size: size, weight: weight, design: .serif)
        return italic ? font.italic() : font
    }

    /// The same face as `serif(...)`, as an `NSFont`.
    ///
    /// The app measures the poem text with CoreText (the width of a line is
    /// needed to place the soft edge), and the measurement has to use the face
    /// the window draws with — the real italic of the system serif, not a
    /// slanted version of the upright.
    static func serifFont(_ role: Role, height: CGFloat, weight: Font.Weight = .regular,
                          italic: Bool = false) -> NSFont {
        serifFont(size: size(role, forHeight: height), weight: weight, italic: italic)
    }

    /// The same face as `serifFont(size:...)`, as an `NSFont`.
    static func serifFont(size: CGFloat, weight: Font.Weight = .regular,
                          italic: Bool = false) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: nsWeight(weight))
        var descriptor = base.fontDescriptor
        descriptor = descriptor.withDesign(.serif) ?? descriptor
        let serif = NSFont(descriptor: descriptor, size: size) ?? base
        guard italic else { return serif }
        return NSFontManager.shared.convert(serif, toHaveTrait: .italicFontMask) ?? serif
    }

    private static func nsWeight(_ weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .light: return .light
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }

    static func sans(_ role: Role, height: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.system(size: size(role, forHeight: height), weight: weight, design: .default)
    }

    /// The clock is set in Georgia, the classic serif of the system: it is a
    /// quiet line under the poem, not part of the interface. Its size is the
    /// size the user chose, one step (1/φ) below it.
    static func georgia(size: Double) -> Font {
        Font.custom("Georgia", size: size / Utils.goldenRatio)
    }
}
