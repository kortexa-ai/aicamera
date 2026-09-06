import SwiftUI

@main
struct AICameraApp: App {
    @NSApplicationDelegateAdaptor(AICameraApplicationDelegate.self) private var applicationDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("AI Camera", image: "MenuBarIcon") {
            ControlCenterView(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("AI Camera Preview", id: "preview") {
            PreviewView(model: model)
        }
        .defaultSize(width: 900, height: 620)
        .windowResizability(.contentMinSize)

        Window("About AI Camera", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)

        Window("AI Camera Notes", id: "notes") {
            AgentNotesView(controller: model.agentNotes)
        }
        .defaultSize(width: 460, height: 560)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(model: model)
        }
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Close Window") {
                    AppLifecycleCoordinator.shared.handleWindowQuitCommand()
                }
                .keyboardShortcut("q")
            }
        }
    }
}
