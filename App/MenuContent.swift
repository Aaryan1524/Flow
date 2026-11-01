import AppKit
import SwiftUI

struct MenuContent: View {
    let controller: DictationController
    @AppStorage("saveHistory") private var saveHistory = true

    var body: some View {
        Text(controller.statusText)

        Divider()

        permissionRow("Microphone", granted: controller.permissions.microphone, pane: "Privacy_Microphone") {
            Task { await controller.requestMicrophone() }
        }
        permissionRow("Input Monitoring (Fn key)", granted: controller.permissions.inputMonitoring, pane: "Privacy_ListenEvent") {
            controller.requestInputMonitoring()
        }
        permissionRow("Accessibility (paste)", granted: controller.permissions.accessibility, pane: "Privacy_Accessibility") {
            controller.requestAccessibility()
        }

        Divider()

        Button("Paste last transcript") { controller.pasteLastTranscript() }
            .disabled(controller.lastTranscript.isEmpty)
        Toggle("Save dictation history", isOn: $saveHistory)
        Button("Show history in Finder") { controller.revealHistory() }

        Divider()

        Text("Set System Settings > Keyboard > \"Press 🌐 key to\" to Do Nothing")
        Button("Quit Flow") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder
    private func permissionRow(_ name: String, granted: Bool, pane: String, request: @escaping () -> Void) -> some View {
        if granted {
            Text("✓ \(name)")
        } else {
            Button("Allow \(name)…") {
                request()
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
