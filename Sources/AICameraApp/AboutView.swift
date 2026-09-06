import AppKit
import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: AppIconArtwork.image)
                .resizable().frame(width: 80, height: 80)
                .accessibilityHidden(true)
            Text("AI Camera").font(.largeTitle.bold())
            Text("A little intelligence in your camera.")
                .font(.callout).foregroundStyle(.secondary)
            Link("by kortexa.ai", destination: URL(string: "https://kortexa.ai")!)
                .font(.callout)
            Text("Version \(version) · Build \(build)")
                .font(.caption).foregroundStyle(.secondary)
            Text("MIT License").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(width: 350)
        .background(AppWindowLifecycle())
    }

    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—" }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—" }

}
