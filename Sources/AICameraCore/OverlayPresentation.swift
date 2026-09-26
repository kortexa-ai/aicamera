import CoreGraphics
import Foundation

/// Where generated content (captions, status, cards, script overlays) may appear in the outgoing
/// frame. Camera pixels always fill the frame; video-anchored annotations stay on the video.
public enum OverlayLayout: String, CaseIterable, Sendable {
    /// The whole frame.
    case wide
    /// A centered 4:3 area, which survives the center crop that WhatsApp and similar apps apply.
    case centered4x3

    /// Top-left-origin region inside `size`, or `.zero` for an unusable size.
    public func region(in size: CGSize) -> CGRect {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return .zero }
        switch self {
        case .wide:
            return CGRect(origin: .zero, size: size)
        case .centered4x3:
            let width = min(size.width, (size.height * 4 / 3).rounded(.down))
            let height = min(size.height, (width * 3 / 4).rounded(.down))
            return CGRect(
                x: ((size.width - width) / 2).rounded(.down),
                y: ((size.height - height) / 2).rounded(.down),
                width: width,
                height: height
            )
        }
    }
}

/// Quick presentation state for generated content, independent of the saved profile.
public struct OverlayPresentation: Equatable, Sendable {
    public var layout: OverlayLayout
    /// Pre-flip generated content horizontally so it reads correctly in apps that mirror the
    /// camera (WhatsApp's self-view). The camera image and detection boxes are never flipped.
    public var mirrorGenerated: Bool

    public init(layout: OverlayLayout = .wide, mirrorGenerated: Bool = false) {
        self.layout = layout
        self.mirrorGenerated = mirrorGenerated
    }

    public static let standard = OverlayPresentation()
}
