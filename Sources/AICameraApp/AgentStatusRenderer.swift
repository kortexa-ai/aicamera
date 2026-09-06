import AICameraCore
import AppKit

/// Native adaptation of RaccoonOps' jelly orb. Drawn into the published pixels, independent
/// of the popup and of model-generated web overlays. Geometry and work per frame are bounded.
final class AgentStatusRenderer {
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    func draw(
        status: AgentOverlayStatus, feedback: GestureControlFeedback?,
        width: CGFloat, top: CGFloat, context: CGContext,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        let panel = CGRect(x: max(14, width - 230), y: top, width: min(216, width - 28), height: 66)
        let orb = CGRect(x: panel.maxX - 64, y: panel.minY + 4, width: 58, height: 58)
        let feedback = feedback.flatMap { value -> GestureControlFeedback? in
            guard value.capturedAt.isFinite, now >= value.capturedAt, now - value.capturedAt <= 0.5,
                  value.progress.isFinite,
                  value.action == .mute || status == .off || status == .failed else { return nil }
            return value
        }
        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(0.62).cgColor)
        context.addPath(CGPath(roundedRect: panel, cornerWidth: 16, cornerHeight: 16, transform: nil))
        context.fillPath()

        let speed: Double
        let deformation: Double
        switch status {
        case .off: (speed, deformation) = (0.28, 0.082)
        case .connecting, .thinking: (speed, deformation) = (0.82, 0.12)
        case .listening: (speed, deformation) = (0.48, 0.102)
        case .speaking: (speed, deformation) = (1.28, 0.165)
        case .muted, .failed: (speed, deformation) = (0, 0.068)
        }
        let phase = reduceMotion ? 0 : now * speed
        let path = blob(in: orb, phase: phase, deformation: deformation)
        let colors = palette(status)
        context.saveGState()
        context.setShadow(offset: .zero, blur: 7, color: colors[1].withAlphaComponent(0.7).cgColor)
        context.addPath(path)
        context.setFillColor(colors[1].cgColor)
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(path)
        context.clip()
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors.map(\.cgColor) as CFArray, locations: [0, 0.45, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: orb.minX, y: orb.minY),
                                       end: CGPoint(x: orb.maxX, y: orb.maxY), options: [])
        }
        let shine = CGRect(x: orb.minX + 15, y: orb.minY + 12, width: 16, height: 5)
        context.setFillColor(NSColor.white.withAlphaComponent(0.55).cgColor)
        context.fillEllipse(in: shine)
        context.restoreGState()
        context.addPath(path)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        context.setLineWidth(0.8)
        context.strokePath()

        if let feedback, !feedback.needsClearerPose {
            context.addArc(center: CGPoint(x: orb.midX, y: orb.midY), radius: 27,
                           startAngle: -.pi / 2,
                           endAngle: -.pi / 2 + 2 * .pi * min(1, max(0, feedback.progress)), clockwise: false)
            context.setLineWidth(2.5)
            context.setStrokeColor(NSColor.white.cgColor)
            context.strokePath()
        }
        let title: String
        let hint: String
        if let feedback {
            let sign = feedback.action == .mute ? "✊" : "✌️"
            title = feedback.needsClearerPose ? "Show \(sign) clearly" : "Hold \(sign)…"
            hint = feedback.action == .mute ? "Mute audio & captions" : "Start conversation"
        } else {
            title = status == .off ? "Agent off" : status.label
            switch status {
            case .off: hint = "Hold ✌️ to talk"
            case .muted: hint = "Unmute in AI Camera"
            case .failed: hint = "See AI Camera menu"
            default: hint = "Hold ✊ to mute"
            }
        }
        let textWidth = orb.minX - panel.minX - 16
        drawText(title, in: CGRect(x: panel.minX + 12, y: panel.minY + 14, width: textWidth, height: 22),
                 size: 14, weight: .semibold, opacity: 1, context: context)
        drawText(hint, in: CGRect(x: panel.minX + 12, y: panel.minY + 37, width: textWidth, height: 18),
                 size: 10.5, weight: .medium, opacity: 0.82, context: context)
        context.restoreGState()
    }

    private func palette(_ status: AgentOverlayStatus) -> [NSColor] {
        let values: [(CGFloat, CGFloat, CGFloat)]
        switch status {
        case .off: values = [(0.65, 0.65, 1), (0.63, 0.25, 0.93), (0.18, 0.42, 0.95)]
        case .connecting, .thinking: values = [(0.4, 1, 0.88), (0.16, 0.9, 0.92), (0.14, 0.45, 1)]
        case .listening: values = [(0.6, 1, 0.88), (0.27, 0.96, 0.73), (0.23, 0.38, 0.98)]
        case .speaking: values = [(1, 0.73, 0.36), (1, 0.25, 0.55), (0.62, 0.27, 0.98)]
        case .muted: values = [(0.8, 0.84, 0.9), (0.48, 0.53, 0.62), (0.24, 0.27, 0.35)]
        case .failed: values = [(1, 0.7, 0.4), (1, 0.3, 0.34), (0.88, 0.19, 0.58)]
        }
        return values.map { NSColor(red: $0.0, green: $0.1, blue: $0.2, alpha: 1) }
    }

    private func blob(in rect: CGRect, phase: Double, deformation: Double) -> CGPath {
        let count = 18
        let radius = min(rect.width, rect.height) * 0.385
        let points = (0..<count).map { index -> CGPoint in
            let angle = Double(index) / Double(count) * .pi * 2 - .pi / 2
            let displacement = deformation * (sin(angle * 3 + phase + 0.73) * 0.52
                + sin(angle * 5 - phase * 0.72 + 1.387) * 0.30
                + cos(angle * 2 + phase * 1.16 - 0.584) * 0.18)
            let distance = radius * (1 + displacement)
            return CGPoint(x: rect.midX + cos(angle) * distance, y: rect.midY + sin(angle) * distance)
        }
        func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        let path = CGMutablePath()
        path.move(to: midpoint(points[count - 1], points[0]))
        for index in points.indices {
            path.addQuadCurve(to: midpoint(points[index], points[(index + 1) % count]), control: points[index])
        }
        path.closeSubpath()
        return path
    }

    private func drawText(_ text: String, in rect: CGRect, size: CGFloat, weight: NSFont.Weight,
                          opacity: CGFloat, context: CGContext) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor.white.withAlphaComponent(opacity), .paragraphStyle: style
        ])
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        attributed.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
    }
}
