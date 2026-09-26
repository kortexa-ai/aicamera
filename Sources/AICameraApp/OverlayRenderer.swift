import AICameraCore
import AppKit
import CoreImage
import CoreVideo
import Foundation

struct EncodedJPEG {
    let data: Data
    let width: Int
    let height: Int
}

final class OverlayRenderer {
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    private let agentRenderer = AgentStatusRenderer()
    private let cardRenderer = AgentCardRenderer()

    func render(
        input: CVPixelBuffer,
        capture: CaptureConfiguration,
        overlay: OverlayConfiguration,
        snapshot: SceneSnapshot,
        scriptOverlay: CVPixelBuffer? = nil,
        cards: [AgentCard] = [],
        cameraLayout: AgentCameraLayout = .camera,
        presentation: OverlayPresentation = .standard
    ) -> CVPixelBuffer? {
        guard let output = outputBuffer(width: capture.width, height: capture.height) else { return nil }
        let target = CGRect(x: 0, y: 0, width: capture.width, height: capture.height)
        // Generated content stays inside this top-left-origin region; the camera always fills the frame.
        let region = presentation.layout.region(in: target.size)
        let mirrored = presentation.mirrorGenerated
        var cameraFrame = target
        var image = CIImage(cvPixelBuffer: input)
        let source = image.extent
        let scale = max(target.width / source.width, target.height / source.height)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let cropX = max(0, (image.extent.width - target.width) / 2)
        let cropY = max(0, (image.extent.height - target.height) / 2)
        image = image.transformed(by: CGAffineTransform(translationX: -cropX, y: -cropY))
        if capture.mirrorVideo {
            image = image.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: target.width, ty: 0))
        }
        // Presentation mode keeps the camera above the scene. Missing/expired graphics immediately
        // restore the full camera; labels are always drawn last and clean inference never uses this layout.
        switch cameraLayout {
        case .camera:
            if let scriptOverlay {
                image = Self.composite(scriptOverlay: scriptOverlay, over: image, into: region, frame: target, mirrored: mirrored)
            }
        case let .inset(request):
            if let scriptOverlay, var frame = request.frame(in: region.size) {
                frame.origin.x += region.minX
                frame.origin.y += region.minY
                // The client's flip moves the inset to the other side; pre-flip its position so it
                // lands where the pre-flipped scene expects it. Camera pixels are never mirrored.
                if mirrored { frame.origin.x = target.width - frame.maxX }
                cameraFrame = frame
                let rectangle = CGRect(x: frame.minX, y: target.height - frame.maxY, width: frame.width, height: frame.height)
                let camera = image.cropped(to: target)
                    .transformed(by: CGAffineTransform(scaleX: rectangle.width / target.width, y: rectangle.height / target.height))
                    .transformed(by: CGAffineTransform(translationX: rectangle.minX, y: rectangle.minY))
                let matte = CIImage(color: CIColor(red: 0.055, green: 0.07, blue: 0.10)).cropped(to: target)
                let scene = Self.composite(scriptOverlay: scriptOverlay, over: matte, into: region, frame: target, mirrored: mirrored)
                let border = CIImage(color: CIColor(red: 0.8, green: 0.83, blue: 0.9, alpha: 0.8))
                    .cropped(to: rectangle.insetBy(dx: -2, dy: -2))
                image = camera.composited(over: border).composited(over: scene)
            }
        case .expired: break
        }
        ciContext.render(image, to: output, bounds: target, colorSpace: CGColorSpaceCreateDeviceRGB())
        if overlay.enabled || !cards.isEmpty {
            draw(snapshot: snapshot, configuration: overlay, cards: cards, cameraFrame: cameraFrame,
                 region: region, mirrored: mirrored, into: output)
        }
        return output
    }

    /// Fits the transparent overlay page inside `region` (a full-frame region is filled exactly),
    /// pre-flips it about the frame's center when requested, and alpha-composites it over the image.
    private static func composite(scriptOverlay: CVPixelBuffer, over image: CIImage, into region: CGRect,
                                  frame: CGRect, mirrored: Bool) -> CIImage {
        var overlayImage = CIImage(cvPixelBuffer: scriptOverlay)
        let extent = overlayImage.extent
        guard extent.width > 0, extent.height > 0, region.width > 0, region.height > 0 else { return image }
        // CIImage coordinates have a bottom-left origin; the region is given top-left.
        let destination = CGRect(x: region.minX, y: frame.height - region.maxY, width: region.width, height: region.height)
        let scale = min(destination.width / extent.width, destination.height / extent.height)
        let size = CGSize(width: extent.width * scale, height: extent.height * scale)
        let origin = CGPoint(x: destination.midX - size.width / 2, y: destination.midY - size.height / 2)
        overlayImage = overlayImage
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: origin.x - extent.minX * scale, y: origin.y - extent.minY * scale))
        if mirrored {
            overlayImage = overlayImage.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: frame.width, ty: 0))
        }
        return overlayImage.cropped(to: frame).composited(over: image)
    }

    func previewImage(from pixelBuffer: CVPixelBuffer) -> NSImage? {
        let bounds = CGRect(
            x: 0,
            y: 0,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        guard let cgImage = ciContext.createCGImage(CIImage(cvPixelBuffer: pixelBuffer), from: bounds) else { return nil }
        return NSImage(cgImage: cgImage, size: bounds.size)
    }

    func jpeg(from pixelBuffer: CVPixelBuffer, quality: CGFloat = 0.72, maximumEdge: CGFloat = 1_024) -> EncodedJPEG? {
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        let edge = max(image.extent.width, image.extent.height)
        if edge > maximumEdge {
            let scale = maximumEdge / edge
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let extent = image.extent.integral
        guard extent.width > 0,
              extent.height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let data = ciContext.jpegRepresentation(
                of: image,
                colorSpace: colorSpace,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
              ) else { return nil }
        return EncodedJPEG(data: data, width: Int(extent.width), height: Int(extent.height))
    }

    private func outputBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let size = CGSize(width: width, height: height)
        if pool == nil || poolSize != size {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:],
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            ]
            var newPool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &newPool) == kCVReturnSuccess else {
                return nil
            }
            pool = newPool
            poolSize = size
        }
        var buffer: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess else {
            return nil
        }
        return buffer
    }

    private func draw(snapshot: SceneSnapshot, configuration: OverlayConfiguration, cards: [AgentCard], cameraFrame: CGRect,
                      region: CGRect, mirrored: Bool, into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CGFloat(CVPixelBufferGetWidth(buffer))
        let height = CGFloat(CVPixelBufferGetHeight(buffer))
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(width),
            height: Int(height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        context.saveGState()
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
        // Generated content is laid out inside the region and, when requested, pre-flipped about
        // the frame's center so a client's mirror shows it the right way round.
        let generated = CGAffineTransform(translationX: region.minX, y: region.minY)
            .concatenating(mirrored ? CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: width, ty: 0) : .identity)
        let regionWidth = region.width
        let regionHeight = region.height
        var cameraInRegion = cameraFrame
        if mirrored { cameraInRegion.origin.x = width - cameraFrame.maxX }
        cameraInRegion.origin.x -= region.minX
        cameraInRegion.origin.y -= region.minY
        let hasAgentCaption = configuration.enabled && configuration.showAgentResponse
            && !(snapshot.agentResponse ?? "").isEmpty
        context.saveGState()
        context.concatenate(generated)
        for card in cards.prefix(1) {
            var visible = card
            if cameraInRegion.width < regionWidth {
                let cameraOnRight = cameraInRegion.midX > regionWidth / 2
                let cardOnRight = card.content.position == .upperRight || card.content.position == .lowerRight
                if cameraOnRight == cardOnRight {
                    let upper = card.content.position == .upperLeft || card.content.position == .upperRight
                    visible = card.positioned(cameraOnRight ? (upper ? .upperLeft : .lowerLeft) : (upper ? .upperRight : .lowerRight))
                }
            }
            cardRenderer.draw(visible, width: regionWidth, height: regionHeight, hasAgentCaption: hasAgentCaption, context: context)
        }
        context.restoreGState()
        guard configuration.enabled else { context.restoreGState(); return }
        let accent = color(hex: configuration.accentHex) ?? NSColor.systemMint
        context.setStrokeColor(accent.cgColor)
        context.setLineWidth(max(2, width / 500))

        context.saveGState()
        context.clip(to: cameraFrame)
        if configuration.showDetectionBoxes {
            for detection in snapshot.detections {
                let box = CGRect(
                    x: cameraFrame.minX + CGFloat(detection.boundingBox.x) * cameraFrame.width,
                    y: cameraFrame.minY + CGFloat(detection.boundingBox.y) * cameraFrame.height,
                    width: CGFloat(detection.boundingBox.width) * cameraFrame.width,
                    height: CGFloat(detection.boundingBox.height) * cameraFrame.height
                )
                context.stroke(box)
                let depth = detection.depthMeters.map { String(format: " · %.1f m", $0) } ?? ""
                drawLabel("\(detection.label) \(Int(detection.confidence * 100))%\(depth)",
                          at: CGPoint(x: box.minX, y: max(cameraFrame.minY + 4, box.minY - 25)),
                          accent: accent, context: context, maximumWidth: min(520, cameraFrame.width))
            }
        }
        if configuration.showGestureLabels, let gesture = snapshot.gestures.first {
            let location = gesture.location.map {
                CGPoint(x: cameraFrame.minX + CGFloat($0.x) * cameraFrame.width, y: cameraFrame.minY + CGFloat($0.y) * cameraFrame.height)
            } ?? CGPoint(x: cameraFrame.minX + 16, y: cameraFrame.minY + 54)
            drawLabel("Gesture: \(gesture.kind.rawValue)", at: location, accent: accent,
                      context: context, maximumWidth: min(520, cameraFrame.width))
        }
        context.restoreGState()
        context.saveGState()
        context.concatenate(generated)
        // Leave room for floating client chrome (including QuickTime's Movie Recording title bar).
        let topInset = max(56, regionHeight * 0.1)
        if configuration.showStatus {
            if let status = snapshot.status, !status.isEmpty {
                drawLabel(status, at: CGPoint(x: 14, y: topInset), accent: accent, context: context)
            }
            if let agentStatus = snapshot.agentStatus {
                agentRenderer.draw(status: agentStatus, feedback: snapshot.gestureControl,
                                   width: regionWidth, top: topInset, context: context)
            }
        }
        if configuration.showAgentResponse, let response = snapshot.agentResponse, !response.isEmpty {
            drawLabel("AI: \(response)", at: CGPoint(x: 14, y: topInset + 80), accent: accent, context: context, maximumWidth: regionWidth - 28)
        }
        if configuration.showTranscript, let transcript = snapshot.transcript?.text, !transcript.isEmpty {
            drawLabel(transcript, at: CGPoint(x: regionWidth / 2, y: regionHeight - 18), accent: accent,
                      context: context, maximumWidth: regionWidth - 28, bottomCentered: true)
        }
        context.restoreGState()
        context.restoreGState()
    }

    private func drawLabel(
        _ text: String,
        at point: CGPoint,
        accent: NSColor,
        context: CGContext,
        maximumWidth: CGFloat = 520,
        bottomCentered: Bool = false
    ) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        if bottomCentered { style.alignment = .center }
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: style,
            ]
        )
        let textSize = attributed.boundingRect(
            with: CGSize(width: maximumWidth - 16, height: 80),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).size
        let labelWidth = min(maximumWidth, textSize.width + 16)
        let labelHeight = textSize.height + 10
        let origin = bottomCentered
            ? CGPoint(x: point.x - labelWidth / 2, y: point.y - labelHeight)
            : point
        let background = CGRect(origin: origin, size: CGSize(width: labelWidth, height: labelHeight))
        context.setFillColor(NSColor.black.withAlphaComponent(0.68).cgColor)
        context.fill(background)
        context.setFillColor(accent.cgColor)
        context.fill(CGRect(x: background.minX, y: background.minY, width: 3, height: background.height))
        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        attributed.draw(in: background.insetBy(dx: 8, dy: 5))
        NSGraphicsContext.restoreGraphicsState()
    }

    private func color(hex: String) -> NSColor? {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else { return nil }
        return NSColor(
            red: CGFloat((rgb >> 16) & 0xff) / 255,
            green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255,
            alpha: 1
        )
    }
}
