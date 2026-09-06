import AppKit
import SwiftUI

struct PreviewView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Color.black
                if let image = model.previewImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: model.cameraIsActive ? "camera.fill" : "camera")
                        .font(.largeTitle)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            HStack(spacing: 8) {
                Button(action: model.toggleCameraTest) {
                    Label(
                        model.cameraTestActive ? "Stop testing" : "Test camera",
                        systemImage: model.cameraTestActive ? "stop.fill" : "video.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .disabled(!model.cameraTestActive && !model.canStartCameraTest)
                .tint(model.cameraTestActive ? .red : .accentColor)
                .help("Test the resolved camera while both virtual devices are idle.")
                .accessibilityLabel(
                    model.cameraTestActive ? "Stop camera testing" : "Test camera"
                )

                Button(action: model.toggleMicrophoneTest) {
                    Label(
                        model.microphoneTestActive ? "Stop testing" : "Test microphone",
                        systemImage: model.microphoneTestActive ? "stop.fill" : "mic.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .disabled(!model.microphoneTestActive && !model.canStartMicrophoneTest)
                .tint(model.microphoneTestActive ? .red : .accentColor)
                .help("Test the resolved microphone while both virtual devices are idle.")
                .accessibilityLabel(
                    model.microphoneTestActive ? "Stop microphone testing" : "Test microphone"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .padding(.horizontal, 16)

            #if DEBUG
            if model.cameraTestActive, model.scriptOverlayEnabled {
                GroupBox("Overlay script") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField(
                            "three.js script — try: AICamera.onFrame(dt => { AICamera.scene.rotation.y += dt })",
                            text: $model.overlayScriptDraft,
                            axis: .vertical
                        )
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(3...8)
                        HStack {
                            Button("Render") { model.loadOverlayScript(model.overlayScriptDraft) }
                                .controlSize(.small)
                            Button("Clear") { model.clearOverlayScript() }
                                .controlSize(.small)
                            Spacer()
                        }
                        if let log = model.overlayScriptLog {
                            Text(log)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }

            #endif

            if model.microphoneTestActive {
                InputLevelMeter(level: model.microphoneInputLevel)
                    .padding(.horizontal, 16)
            }

        }
        .padding(.bottom, 16)
        .frame(minWidth: 640, idealWidth: 900, minHeight: 440, idealHeight: 620)
        .background(AppWindowLifecycle(onClose: model.stopLocalTests))
    }

}
