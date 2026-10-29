import SwiftUI

@main
struct NetPilotApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(model)
                .environmentObject(model.dns)
                .onAppear { model.start() }
        } label: {
            Image(systemName: model.menuSymbol)
                .onAppear { model.start() }
        }
        .menuBarExtraStyle(.window)
    }
}
