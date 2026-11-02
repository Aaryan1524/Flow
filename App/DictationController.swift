import ASR
import AppKit
import Audio
import Cleanup
import FlowKit
import Foundation
import History
import Hotkey
import Insertion
import Observation
import OSLog

/// Ties the pieces together: hold Fn, record, transcribe, paste, log.
///
/// The transcript goes through the cleanup pipeline (rules, then the AI when needed) before it is pasted.
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
    /// What the speech engine heard before cleanup, so the cleanup can be undone with "Paste raw version".
    private(set) var lastRawTranscript = ""
    /// True once the Fn key listener is actually attached, which is stronger than the permission reading as granted.
    private(set) var listening = false
    /// One line about the last dictation that didn't land, e.g. "not pasted: you switched apps".
    private(set) var notice: String?
    /// The Globe key opens the emoji picker unless it is set to Do Nothing.
    private(set) var globeKeyIsDisabled = true
    /// Microphones to choose from, and the one that will actually be used.
    private(set) var microphones: [AudioInputDevice] = []
    private(set) var activeMicrophoneName = "system default"

    @ObservationIgnored private let monitor = FnKeyMonitor()
    @ObservationIgnored private let recorder = MicrophoneRecorder()
    @ObservationIgnored private let transcriber = FluidAudioTranscriber(model: .v2)
    @ObservationIgnored private let paster = ClipboardPaster()
    @ObservationIgnored private let history = HistoryLog()
    @ObservationIgnored private let aiCleaner = AppleCleaner()
    /// Rules only until the AI model has reported that it is available.
    @ObservationIgnored private var pipeline = CleanupPipeline(ai: nil)
    @ObservationIgnored private var aiReady = false
    @ObservationIgnored private var pollTicks = 0
    @ObservationIgnored private let log = Logger(subsystem: "com.aaryan.flow", category: "dictation")

    /// App that was in front when the key went down. The text goes there, or nowhere.
    @ObservationIgnored private var targetApp: String?
    @ObservationIgnored private var modelLoaded = false
    @ObservationIgnored private var maxRecordingTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var lastPrune = Date.distantPast
    /// Keeps macOS from napping this windowless app, which would add delay to the first dictation after a pause.
    @ObservationIgnored private var activity: NSObjectProtocol?

    /// A forgotten hands-free recording shouldn't run forever.
    private let maximumRecording = Duration.seconds(300)
    /// People let go of the key slightly before the last syllable ends.
    private let tail = Duration.milliseconds(200)

    // MARK: - Display

    var statusText: String {
        switch status {
        case .starting: return "Starting…"
        case .loadingModel: return "Loading the speech model (the first launch downloads it)…"
        case .ready:
            if !permissions.inputMonitoring { return "Allow Input Monitoring to use the Fn key" }
            if !listening { return "Waiting for the Fn key. If you just allowed it, quit and reopen Flow." }
            return "Ready: hold Fn and talk"
        case .recording: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .failed(let message): return "Problem: \(message). Hold Fn to try again."
        }
    }

    var iconName: String {
        switch status {
        case .recording: return "mic.fill"
        case .transcribing: return "waveform"
        case .failed: return "exclamationmark.triangle"
        default: return permissions.allGranted && listening ? "mic" : "exclamationmark.triangle"
        }
    }

    // MARK: - Lifecycle

    func start() {
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Listening for the dictation key")
        monitor.onEvent = { [weak self] event in self?.handle(event) }
        refreshPermissions()
        refreshMicrophones()
        observeSystemEvents()

        Task {
            _ = await MicrophoneRecorder.requestMicrophoneAccess()
            if !FnKeyMonitor.hasPermission { FnKeyMonitor.requestPermission() }
            if !ClipboardPaster.hasAccessibilityPermission { ClipboardPaster.requestAccessibilityPermission() }
            refreshPermissions()
            prewarmRecorder()
            async let aiReady: Void = prepareAICleanup()
            await loadModel()
            await aiReady
        }

        // Permissions can be granted at any time, so keep checking and attach the key listener once allowed.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                refreshPermissions()
                // Trying to create the listener is what makes macOS list Flow under Input Monitoring.
                if !monitor.isRunning { monitor.start() }
                if listening != monitor.isRunning { listening = monitor.isRunning }
                refreshGlobeKeySetting()
                refreshMicrophones()
                prewarmRecorder()
                pollTicks += 1
                if !aiReady, pollTicks % 15 == 0 { await prepareAICleanup() }  // about every 30 s
                await pruneHistoryIfDue()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Warms up Apple's on-device model so the first cleanup isn't slow. If it isn't available, rules still work.
    /// Retried from the poll loop, because the model may still be downloading at launch.
    private func prepareAICleanup() async {
        guard !aiReady else { return }
        do {
            try await aiCleaner.prepare()
            pipeline = CleanupPipeline(ai: aiCleaner)
            aiReady = true
        } catch {
            log.info("AI cleanup unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Not set yet means the default. A stored value this build doesn't know falls back to the safe rules-only mode.
    private var cleanupMode: CleanupMode {
        guard let stored = UserDefaults.standard.string(forKey: "cleanupMode") else { return Self.defaultCleanupMode }
        return CleanupMode(rawValue: stored) ?? .rules
    }

    /// Rules only until the AI safety check has been hardened and verified; then this becomes `.rulesAndAI`.
    static let defaultCleanupMode = CleanupMode.rules

    private func loadModel() async {
        status = .loadingModel
        do {
            try await transcriber.prepare()
            modelLoaded = true
            status = .ready
        } catch {
            log.error("model load failed: \(error.localizedDescription, privacy: .public)")
            status = .failed("could not load the speech model")
        }
    }

    /// A key held down across sleep or a screen lock may never report its release, so drop any recording then.
    private func observeSystemEvents() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.abandonRecording(reason: nil) }
            }
        }
    }

    private func pruneHistoryIfDue() async {
        guard Date().timeIntervalSince(lastPrune) > 86_400 else { return }
        lastPrune = Date()
        _ = try? await history.prune()
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

    /// 0 means "Do Nothing". Anything else (or unset) lets the Globe key pop up the emoji picker or dictation.
    private func refreshGlobeKeySetting() {
        let value = UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int
        let disabled = value == 0
        if disabled != globeKeyIsDisabled { globeKeyIsDisabled = disabled }
    }

    // MARK: - Microphone

    private func resolveDevice() -> AudioInputDevice? {
        AudioInputDevices.resolve(preferredUID: UserDefaults.standard.string(forKey: "inputDeviceUID"))
    }

    private func refreshMicrophones() {
        let devices = AudioInputDevices.all()
        if devices != microphones { microphones = devices }
        let name = resolveDevice()?.name ?? "system default"
        if name != activeMicrophoneName { activeMicrophoneName = name }
    }

    /// Builds the audio engine ahead of time, away from the main thread, so pressing Fn only has to start it.
    private func prewarmRecorder() {
        guard permissions.microphone, !recorder.isRecording else { return }
        let device = resolveDevice()
        guard !recorder.isPrepared || recorder.preparedDeviceID != device?.id else { return }
        let recorder = self.recorder
        Task.detached { try? recorder.prepare(device: device) }
    }

    // MARK: - Dictation

    private func handle(_ event: HotkeyEvent) {
        switch event {
        case .started:
            // A previous error shouldn't leave the app dead: pressing the key is a retry.
            if case .failed = status {
                guard modelLoaded else {
                    Task { await loadModel() }
                    return
                }
                status = .ready
            }
            guard status == .ready else { return }
            notice = nil
            targetApp = ClipboardPaster.frontmostBundleID()
            do { try recorder.start(device: resolveDevice()) } catch {
                log.error("could not start recording: \(error.localizedDescription, privacy: .public)")
                status = .failed("could not use the microphone")
                return
            }
            status = .recording
            maxRecordingTask = Task { [weak self, maximumRecording] in
                try? await Task.sleep(for: maximumRecording)
                guard !Task.isCancelled else { return }
                self?.abandonRecording(reason: "recording stopped after 5 minutes")
            }
        case .cancelled:
            abandonRecording(reason: nil)
        case .finished:
            Task { await finishRecording() }
        }
    }

    /// Throws the current recording away. Used for taps, Esc, sleep, and the length limit. Nothing is pasted.
    private func abandonRecording(reason: String?) {
        monitor.reset()
        guard status == .recording else { return }
        maxRecordingTask?.cancel()
        recorder.discard()
        status = .ready
        if let reason { notice = "Not pasted: \(reason)" }
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
            let raw = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else {
                status = .ready
                return
            }

            let mode = cleanupMode
            let cleanupStart = ContinuousClock.now
            let cleaned = await pipeline.clean(raw, mode: mode)
            let cleanupMs = cleanupStart.duration(to: .now).milliseconds
            let text = cleaned.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Cleanup can legitimately leave nothing, e.g. when the whole dictation was "um".
            guard !text.isEmpty else {
                status = .ready
                return
            }

            let insertStart = ContinuousClock.now
            let result = await paster.insert(text, into: targetApp)
            let done = ContinuousClock.now
            let timing = Timing(
                audioSeconds: audioSeconds, firstAudioMs: firstAudioMs, transcribeMs: transcript.seconds * 1000,
                cleanupMs: cleanupMs, insertMs: insertStart.duration(to: done).milliseconds,
                releaseToTextMs: released.duration(to: done).milliseconds)
            log.info(
                "release to text \(timing.releaseToTextMs, privacy: .public) ms (transcribe \(timing.transcribeMs, privacy: .public) ms, cleanup \(timing.cleanupMs, privacy: .public) ms, insert \(timing.insertMs, privacy: .public) ms, ai \(cleaned.usedAI, privacy: .public))"
            )

            switch result {
            case .skipped(.secureInput):
                // Likely a password. Don't keep it anywhere, not even in the history.
                notice = "Not pasted: a secure field is active"
            case .notPasted(let reason):
                lastTranscript = text
                lastRawTranscript = raw
                notice = Self.describe(reason)
                await record(cleaned, text, result, timing, mode)
            default:
                lastTranscript = text
                lastRawTranscript = raw
                await record(cleaned, text, result, timing, mode)
            }
            status = .ready
        } catch {
            log.error("transcription failed: \(error.localizedDescription, privacy: .public)")
            status = .failed("transcription failed")
        }
    }

    private struct Timing {
        var audioSeconds: Double
        var firstAudioMs: Double?
        var transcribeMs: Double
        var cleanupMs: Double
        var insertMs: Double
        var releaseToTextMs: Double
    }

    private func record(
        _ cleaned: CleanupResult, _ finalText: String, _ result: InsertionResult, _ timing: Timing, _ mode: CleanupMode
    ) async {
        guard UserDefaults.standard.object(forKey: "saveHistory") as? Bool ?? true else { return }
        let entry = HistoryEntry(
            app: targetApp, engine: transcriber.name, rawText: cleaned.raw, finalText: finalText, outcome: result.logValue,
            audioSeconds: timing.audioSeconds, firstAudioMs: timing.firstAudioMs, transcribeMs: timing.transcribeMs,
            insertMs: timing.insertMs, releaseToTextMs: timing.releaseToTextMs, cleanupMode: mode.rawValue,
            cleanupMs: timing.cleanupMs, usedAI: cleaned.usedAI, aiSkippedBecause: cleaned.aiSkippedBecause)
        try? await history.append(entry)
    }

    private static func describe(_ reason: InsertionResult.Reason) -> String {
        switch reason {
        case .appChanged: return "Not pasted: you switched apps. Use “Paste last transcript”."
        case .noAccessibility: return "Not pasted: allow Accessibility. Use “Paste last transcript” afterwards."
        case .pasteNotConfirmed: return "Not pasted: no text field took it. Use “Paste last transcript”."
        case .busy: return "Not pasted: another paste was still running."
        }
    }

    func pasteLastTranscript() {
        let text = lastTranscript
        guard status == .ready, !text.isEmpty else { return }
        Task {
            // Give the menu a moment to close so the keystroke goes to the app underneath it.
            try? await Task.sleep(for: .milliseconds(150))
            let result = await paster.insert(text, into: nil)
            if result != .pasted { notice = Self.describe(result) }
        }
    }

    private static func describe(_ result: InsertionResult) -> String {
        switch result {
        case .notPasted(let reason): return describe(reason)
        case .skipped(.secureInput): return "Not pasted: a secure field is active"
        default: return "Not pasted"
        }
    }

    /// Undo for cleanup: inserts what the speech engine heard, before any cleanup.
    func pasteLastRaw() {
        let text = lastRawTranscript
        guard status == .ready, !text.isEmpty else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            let result = await paster.insert(text, into: nil)
            if result != .pasted { notice = Self.describe(result) }
        }
    }

    var canPasteRaw: Bool { !lastRawTranscript.isEmpty && lastRawTranscript != lastTranscript }

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
