import SwiftUI

@main
struct AICameraApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("AI Camera", image: "MenuBarIcon") {
            ControlCenterView(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Close Settings") {
                    AppLifecycleCoordinator.shared.handleSettingsQuitCommand()
                }
                .keyboardShortcut("q")
            }
        }
    }
}
