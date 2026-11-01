import ASR
import AppKit
import Audio
import FlowKit
import Foundation
import History
import Hotkey
import Insertion
import Observation
import OSLog

/// Ties the pieces together: hold Fn, record, transcribe, paste, log.
///
/// Phase 1 inserts the raw speech-to-text output. Cleanup and number conversion come later.
@MainActor
@Observable
final class DictationController {
    enum Status: Equatable {
        case starting, loadingModel, ready, recording, transcribing
        case failed(String)
    }

    struct Permissions: Equatable {
        var microphone = false
        var inputMonitoring = false
        var accessibility = false

        var allGranted: Bool { microphone && inputMonitoring && accessibility }
    }

    private(set) var status = Status.starting
    private(set) var permissions = Permissions()
    private(set) var lastTranscript = ""

    @ObservationIgnored private let monitor = FnKeyMonitor()
    @ObservationIgnored private let recorder = MicrophoneRecorder()
    @ObservationIgnored private let transcriber = FluidAudioTranscriber(model: .v2)
    @ObservationIgnored private let paster = ClipboardPaster()
    @ObservationIgnored private let history = HistoryLog()
    @ObservationIgnored private let log = Logger(subsystem: "com.aaryan.flow", category: "dictation")

    /// App that was in front when the key went down. The text goes there, or nowhere.
    @ObservationIgnored private var targetApp: String?
    @ObservationIgnored private var maxRecordingTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    /// A forgotten hands-free recording shouldn't run forever.
    private let maximumRecording = Duration.seconds(300)
    /// People let go of the key slightly before the last syllable ends.
    private let tail = Duration.milliseconds(200)

    // MARK: - Display

    var statusText: String {
        switch status {
        case .starting: return "Starting…"
        case .loadingModel: return "Loading the speech model (the first launch downloads it)…"
        case .ready: return permissions.inputMonitoring ? "Ready: hold Fn and talk" : "Allow Input Monitoring to use the Fn key"
        case .recording: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .failed(let message): return "Problem: \(message)"
        }
    }

    var iconName: String {
        switch status {
        case .recording: return "mic.fill"
        case .transcribing: return "waveform"
        case .failed: return "exclamationmark.triangle"
        default: return permissions.allGranted ? "mic" : "exclamationmark.triangle"
        }
    }

    // MARK: - Lifecycle

    func start() {
        monitor.onEvent = { [weak self] event in self?.handle(event) }
        refreshPermissions()

        Task {
            _ = await MicrophoneRecorder.requestMicrophoneAccess()
            if !FnKeyMonitor.hasPermission { FnKeyMonitor.requestPermission() }
            if !ClipboardPaster.hasAccessibilityPermission { ClipboardPaster.requestAccessibilityPermission() }
            refreshPermissions()

            status = .loadingModel
            do {
                try await transcriber.prepare()
                status = .ready
            } catch {
                log.error("model load failed: \(error.localizedDescription, privacy: .public)")
                status = .failed("could not load the speech model")
            }
            try? await history.prune()
        }

        // Permissions can be granted at any time, so keep checking and attach the key listener once allowed.
        pollTask = Task {
            while !Task.isCancelled {
                refreshPermissions()
                if !monitor.isRunning, FnKeyMonitor.hasPermission { monitor.start() }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: - Permissions

    func requestMicrophone() async {
        _ = await MicrophoneRecorder.requestMicrophoneAccess()
        refreshPermissions()
    }

    func requestInputMonitoring() {
        FnKeyMonitor.requestPermission()
        refreshPermissions()
    }

    func requestAccessibility() {
        ClipboardPaster.requestAccessibilityPermission()
        refreshPermissions()
    }

    private func refreshPermissions() {
        let current = Permissions(
            microphone: MicrophoneRecorder.microphoneAuthorized, inputMonitoring: FnKeyMonitor.hasPermission,
            accessibility: ClipboardPaster.hasAccessibilityPermission)
        if current != permissions { permissions = current }
    }

    // MARK: - Dictation

    private func handle(_ event: HotkeyEvent) {
        switch event {
        case .started:
            guard status == .ready else { return }
            targetApp = ClipboardPaster.frontmostBundleID()
            do { try recorder.start() } catch {
                log.error("could not start recording: \(error.localizedDescription, privacy: .public)")
                status = .failed("could not use the microphone")
                return
            }
            status = .recording
            maxRecordingTask = Task { [weak self, maximumRecording] in
                try? await Task.sleep(for: maximumRecording)
                guard !Task.isCancelled else { return }
                await self?.finishRecording()
            }
        case .cancelled:
            guard status == .recording else { return }
            maxRecordingTask?.cancel()
            recorder.discard()
            status = .ready
        case .finished:
            Task { await finishRecording() }
        }
    }

    private func finishRecording() async {
        guard status == .recording else { return }
        maxRecordingTask?.cancel()
        let released = ContinuousClock.now
        status = .transcribing

        try? await Task.sleep(for: tail)
        let samples = recorder.stop()
        let firstAudioMs = recorder.firstBufferDelay.map { $0 * 1000 }
        let audioSeconds = AudioLevel.duration(samples)

        guard audioSeconds >= 0.3, !AudioLevel.isSilent(samples) else {
            log.info("ignored a silent or very short recording (\(audioSeconds, privacy: .public) s)")
            status = .ready
            return
        }

        do {
            let transcript = try await transcriber.transcribe(samples: samples)
            let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                status = .ready
                return
            }

            let insertStart = ContinuousClock.now
            let result = await paster.insert(text, into: targetApp)
            let done = ContinuousClock.now
            lastTranscript = text

            let releaseToText = released.duration(to: done).milliseconds
            log.info(
                "release to text \(releaseToText, privacy: .public) ms (transcribe \(transcript.seconds * 1000, privacy: .public) ms, insert \(insertStart.duration(to: done).milliseconds, privacy: .public) ms)"
            )

            if UserDefaults.standard.object(forKey: "saveHistory") as? Bool ?? true {
                let entry = HistoryEntry(
                    app: targetApp, engine: transcriber.name, rawText: text, finalText: text, outcome: "\(result)",
                    audioSeconds: audioSeconds, firstAudioMs: firstAudioMs, transcribeMs: transcript.seconds * 1000,
                    insertMs: insertStart.duration(to: done).milliseconds, releaseToTextMs: releaseToText)
                try? await history.append(entry)
            }
            status = .ready
        } catch {
            log.error("transcription failed: \(error.localizedDescription, privacy: .public)")
            status = .failed("transcription failed")
            // Recover on the next press instead of staying stuck.
            try? await Task.sleep(for: .seconds(3))
            if case .failed = status { status = .ready }
        }
    }

    func pasteLastTranscript() {
        let text = lastTranscript
        Task { _ = await paster.insert(text, into: nil) }
    }

    func revealHistory() {
        let url = HistoryLog.defaultURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}

extension Duration {
    fileprivate var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}
