import SwiftUI

@MainActor let sharedController = DictationController()

@main
struct FlowApp: App {
    init() {
        sharedController.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: sharedController)
        } label: {
            Image(systemName: sharedController.iconName)
        }
    }
}
