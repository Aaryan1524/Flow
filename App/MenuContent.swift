import AppKit
import SwiftUI

struct MenuContent: View {
    let controller: DictationController
    @AppStorage("saveHistory") private var saveHistory = true
    @AppStorage("inputDeviceUID") private var inputDeviceUID = ""
    @AppStorage("handsFree") private var handsFree = true
    @AppStorage("cleanupMode") private var cleanupMode = DictationController.defaultCleanupMode.rawValue

    var body: some View {
        Text(controller.statusText)
        if let notice = controller.notice { Text(notice) }
        if !controller.globeKeyIsDisabled {
            Text("Set System Settings > Keyboard > “Press 🌐 key to” to Do Nothing")
        }

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

        Picker("Microphone", selection: $inputDeviceUID) {
            Text("Automatic (avoids Bluetooth)").tag("")
            ForEach(controller.microphones) { device in
                Text(device.isBluetooth ? "\(device.name) (Bluetooth)" : device.name).tag(device.uid)
            }
        }
        Text("Using: \(controller.activeMicrophoneName)")

        Divider()

        Picker("Cleanup", selection: $cleanupMode) {
            Text("Off (raw text)").tag("off")
            Text("Rules only (instant)").tag("rules")
            if DictationController.aiCleanupAvailable { Text("Rules + AI (experimental)").tag("rulesAndAI") }
        }

        Text("Dictionary: \(controller.dictionarySummary)")
        Button("Edit my dictionary…") { controller.editDictionary() }

        Button("Paste last transcript") { controller.pasteLastTranscript() }
            .disabled(controller.lastTranscript.isEmpty)
        Button("Paste raw version of last dictation") { controller.pasteLastRaw() }
            .disabled(!controller.canPasteRaw)
        Toggle("Double-tap Fn for hands-free", isOn: $handsFree)
        Toggle(
            "Start Flow at login",
            isOn: Binding(get: { controller.launchAtLoginEnabled }, set: { controller.setLaunchAtLogin($0) }))
        Toggle("Save dictation history", isOn: $saveHistory)
        Button("Show history in Finder") { controller.revealHistory() }

        Divider()

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
