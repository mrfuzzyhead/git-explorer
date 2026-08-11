import SwiftUI

@main
struct GitExplorerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 640)
                .task { await model.start() }
        }
        .windowStyle(.titleBar)
        .commands {
            SettingsCommands()
        }

        Window("Settings", id: "settings") {
            SettingsView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 420)
        }
        .defaultSize(width: 780, height: 500)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
    }
}

private struct SettingsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                openWindow(id: "settings")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}
