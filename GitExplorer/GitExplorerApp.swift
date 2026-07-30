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

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 620, height: 410)
        }
    }
}
