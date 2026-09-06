import AICameraCore
import AppKit

/// Confined to the video render queue. Rasterize each bounded card once, then reuse its pixels.
final class AgentCardRenderer {
    private var cachedID: UUID?
    private var cachedSize = CGSize.zero
    private var cachedImage: CGImage?

    func draw(_ card: AgentCard, width: CGFloat, height: CGFloat, hasAgentCaption: Bool = false, context: CGContext) {
        let scale = max(0.65, min(1.5, width / 1_280))
        let top = max(56, height * 0.1) + (hasAgentCaption ? 182 : 78)
        let bottomMargin = max(108, height * 0.15)
        let maximumSize = CGSize(width: min(width * 0.36, 440 * scale).rounded(),
                                 height: min(height * 0.29, 208 * scale, height - top - bottomMargin).rounded())
        guard maximumSize.width >= 100, maximumSize.height >= 80 else { return }
        if cachedID != card.id || cachedSize != maximumSize {
            cachedImage = rasterize(card.content, maximumSize: maximumSize, scale: scale)
            cachedID = card.id; cachedSize = maximumSize
        }
        guard let image = cachedImage else { return }
        let size = CGSize(width: image.width, height: image.height)
        let margin = max(14, width * 0.02)
        let bottom = max(top, height - bottomMargin - size.height)
        let position = card.content.position
        let right = position == .upperRight || position == .lowerRight
        let lower = position == .lowerLeft || position == .lowerRight
        let x = right ? width - margin - size.width : margin
        let y = lower ? bottom : top
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 3), blur: 12, color: NSColor.black.withAlphaComponent(0.22).cgColor)
        context.translateBy(x: x, y: y + size.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: size))
        context.restoreGState()
    }

    private func rasterize(_ card: AgentCardRequest, maximumSize: CGSize, scale: CGFloat) -> CGImage? {
        let inset = max(10, 17 * scale)
        let textWidth = maximumSize.width - inset * 2
        let titleFont = NSFont.systemFont(ofSize: 17 * scale, weight: .semibold)
        let metric = card.style == .metric && card.body.count <= 30
        let bodyFont: NSFont = metric ? .monospacedDigitSystemFont(ofSize: 29 * scale, weight: .semibold)
            : .systemFont(ofSize: 18 * scale, weight: .regular)
        let titleHeight = min(30 * scale, measuredHeight(card.title, font: titleFont, width: textWidth))
        let sourceHeight: CGFloat = card.source == nil ? 0 : 29 * scale
        let bodyTop = inset + titleHeight + 6 * scale
        let bodyHeight = min(max(18, maximumSize.height - bodyTop - inset - sourceHeight),
                             measuredHeight(card.body, font: bodyFont, width: textWidth))
        let size = CGSize(width: maximumSize.width,
                          height: min(maximumSize.height, bodyTop + bodyHeight + inset + sourceHeight).rounded(.up))
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        let sticky = card.style == .sticky
        let foreground: NSColor = sticky ? NSColor(calibratedWhite: 0.13, alpha: 1) : .white
        let background = sticky ? NSColor(red: 1, green: 0.94, blue: 0.69, alpha: 0.97)
            : NSColor(red: 0.08, green: 0.11, blue: 0.17, alpha: 0.94)
        let bounds = CGRect(origin: .zero, size: size)
        context.setFillColor(background.cgColor)
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: 14 * scale, cornerHeight: 14 * scale, transform: nil))
        context.fillPath()
        text(card.title, rect: CGRect(x: inset, y: inset, width: textWidth, height: titleHeight),
             font: titleFont, color: foreground, context: context)
        text(card.body, rect: CGRect(x: inset, y: bodyTop, width: textWidth, height: bodyHeight),
             font: bodyFont, color: foreground, context: context)
        if let source = card.source {
            text(source, rect: CGRect(x: inset, y: size.height - inset - sourceHeight + 6 * scale,
                                      width: textWidth, height: sourceHeight),
                 font: .systemFont(ofSize: 11 * scale), color: foreground.withAlphaComponent(0.65), context: context)
        }
        return context.makeImage()
    }

    private func measuredHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: font]).boundingRect(
            with: CGSize(width: width, height: 240), options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height.rounded(.up)
    }

    private func text(_ value: String, rect: CGRect, font: NSFont, color: NSColor, context: CGContext) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(string: value, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph
        ])
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        attributed.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
        NSGraphicsContext.restoreGraphicsState()
    }
}
