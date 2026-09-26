import SwiftUI

struct FeatureToolbar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            control("Mute", icon: model.privacyMuted ? "mic.slash.fill" : "mic.fill",
                    active: model.privacyMuted, tint: .red,
                    help: "\(model.privacyMuted ? "Unmute" : "Mute") microphone and captions · ⌃⌥M") {
                model.setPrivacyMuted(!model.privacyMuted)
            }
            control("Transcribe", icon: "captions.bubble", active: model.transcriptionActive,
                    available: model.transcriptionConfigured,
                    help: model.transcriptionConfigured ? "Toggle original-language captions. Translation takes precedence while on." : "Enable transcription in Settings first.") {
                model.toggleTranscription()
            }
            control("Translate", icon: "translate", active: model.translationActive,
                    available: model.translationConfigured,
                    help: model.translationConfigured ? "\(model.translationActive ? "Translating to" : "Translation off · selected language:") \(model.translationTargetName). Toggle translated captions." : "Enable translation and a transcription source in Settings first.") {
                model.toggleTranslation()
            }
            control("Voice", icon: "speaker.wave.2", active: model.voiceTranslationActive,
                    available: model.voiceTranslationActive || model.voiceTranslationUnavailableReason == nil,
                    help: model.voiceTranslationDescription) {
                model.toggleVoiceTranslation()
            }
            control("Agent", icon: "waveform.and.mic", active: model.realtimeConversationActive,
                    available: model.realtimeConversationActive || model.canStartRealtimeConversation,
                    help: "\(model.realtimeConversationState.rawValue) · ⌃⌥A. Hold victory to start; fist to mute.") {
                model.toggleRealtimeConversation()
            }
            control("Gestures", icon: "hand.raised.fingers.spread", active: model.gesturesActive,
                    available: model.gesturesConfigured,
                    help: model.gesturesConfigured ? "Toggle gesture recognition and gesture controls." : "Enable gestures in Settings first.") {
                model.toggleGestures()
            }
        }
        HStack(spacing: 6) {
            control("Layout", icon: model.overlayLayout == .centered4x3 ? "rectangle.ratio.4.to.3" : "rectangle.ratio.16.to.9",
                    active: model.overlayLayout == .centered4x3,
                    help: model.overlayLayout == .centered4x3
                        ? "Captions, cards, and overlays stay inside a centered 4:3 area, so apps that crop the camera (WhatsApp) keep them visible. Click to use the full 16:9 frame."
                        : "Captions, cards, and overlays use the full 16:9 frame. Click to keep them inside a centered 4:3 area for apps that crop the camera (WhatsApp).") {
                model.toggleOverlayLayout()
            }
            control("Mirror", icon: model.mirrorOverlays ? "flip.horizontal.fill" : "flip.horizontal",
                    active: model.mirrorOverlays,
                    help: "Pre-flip everything AI Camera draws so text reads correctly in apps that mirror the camera (WhatsApp). The camera image is not changed; Preview shows the outgoing frame.") {
                model.toggleMirrorOverlays()
            }
        }
        if model.privacyMuted {
            Label("Microphone muted · captions hidden", systemImage: "mic.slash.fill")
                .font(.caption).foregroundStyle(.secondary)
        }
        if model.voiceTranslationActive || model.voiceTranslationError != nil {
            Text(model.voiceTranslationDescription).font(.caption).foregroundStyle(model.voiceTranslationError == nil ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let error = model.shortcutError {
            Text(error).font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func control(_ title: String, icon: String, active: Bool,
                         available: Bool = true, tint: Color = .accentColor,
                         help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 17, weight: .medium))
                    .frame(height: 22)
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .foregroundStyle(active ? tint : .secondary)
            .background(active ? tint.opacity(0.14) : Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(active ? tint.opacity(0.3) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain).disabled(!available)
        .help(help)
        .accessibilityLabel(title == "Mute" ? (active ? "Unmute microphone" : "Mute microphone") : title)
        .accessibilityValue(title == "Layout" ? (active ? "4:3" : "16:9")
                            : active ? (title == "Translate" ? "On · \(model.translationTargetName)" : "On") : "Off")
        .accessibilityIdentifier("quick-\(title.lowercased())")
    }
}
