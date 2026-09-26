import AppKit
import SwiftUI

@main
struct SnapcastSourceApp: App {
    @StateObject private var model = AppModel()

    init() {
        // LSUIElement in Info.plist does this for the bundle; this covers running the
        // bare executable from `swift run` during development.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(model)
        } label: {
            Image(systemName: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}
