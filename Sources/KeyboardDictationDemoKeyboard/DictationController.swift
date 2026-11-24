import AVFoundation
import OSLog
import Speech
import UIKit

private let log = Logger(subsystem: "net.stupidtech.keyboard-dictation-demo.keyboard", category: "dictation")

/// Generation of the latest dictation, touched only on `DictationController.sessionQueue`.
private final class AudioSessionState: @unchecked Sendable { var generation = 0 }
private let audioSessionState = AudioSessionState()

/// Hold-to-talk dictation: microphone through `WebAudioCapture` (no app switch), zh-CN
/// `SFSpeechRecognizer` with streamed partial results.
///
/// Fast start without holding the microphone: when the keyboard appears the recognizer is created,
/// authorization is checked, the audio session category is configured (not activated) and a
/// recognition request/task is created ahead of time ("spare"). On press the request is already
/// waiting, so audio is routed into it from the very first captured chunk.
///
/// Mic release: on release / cancel / keyboard dismiss the capture is stopped, the request ended,
/// the task cancelled and the audio session deactivated with `.notifyOthersOnDeactivation`.
@MainActor
final class DictationController: NSObject {
    let capture = WebAudioCapture()
    private let recognizer: SFSpeechRecognizer? = {
        let r = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        r?.defaultTaskHint = .dictation
        // Deliver results on the main queue directly (no extra async hop before text is shown).
        r?.queue = OperationQueue.main
        return r
    }()
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: WebAudioCapture.sampleRate, channels: 1, interleaved: true
    )!
    /// AVAudioSession activate/deactivate run here so they never block a touch on the main thread.
    private static let sessionQueue = DispatchQueue(label: "dictation.audio-session", qos: .userInteractive)

    private final class Session {
        let id: Int
        let request: SFSpeechAudioBufferRecognitionRequest
        let onDevice: Bool
        var task: SFSpeechRecognitionTask?
        var text = ""
        var ended = false
        var heardAudio = false
        var isFinal = false
        /// Audio kept until the first result, so an on-device failure can be replayed to the server.
        var pending: [AVAudioPCMBuffer] = []
        init(id: Int, request: SFSpeechAudioBufferRecognitionRequest, onDevice: Bool) {
            self.id = id
            self.request = request
            self.onDevice = onDevice
        }
    }

    private var nextID = 0
    private var spare: Session?
    private var active: Session?
    private var preferOnDevice = true
    /// Set when on-device recognition failed in this keyboard session; falls back to the server.
    private var onDeviceBroken = false
    private var visible = false
    private var sessionConfigured = false
    /// Bumped on every begin so a late deactivation never hits a newer dictation.
    private var audioGeneration = 0

    var onPartial: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onListening: (() -> Void)?
    /// Final text; nil when cancelled.
    var onFinish: ((String?) -> Void)?
    var onFailure: ((String) -> Void)?

    var isActive: Bool { active != nil }
    var isMicWarm: Bool { capture.isWarm }

    func attach(to view: UIView) {
        capture.onAudio = { [weak self] data, rms in self?.append(data, rms: rms) }
        capture.onEnded = { [weak self] reason in self?.captureEnded(reason) }
        capture.onReleased = { [weak self] in self?.deactivateAudioSession() }
        capture.attach(to: view)
    }

    func permissionProblem(hasFullAccess: Bool) -> String? {
        guard hasFullAccess else { return "请在 设置→通用→键盘→键盘 中为「语音键盘」开启「允许完全访问」" }
        guard AVAudioSession.sharedInstance().recordPermission == .granted else { return "请先打开「语音键盘」App 授予麦克风权限" }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return "请先打开「语音键盘」App 授予语音识别权限" }
        guard let recognizer, recognizer.isAvailable else { return "语音识别暂时不可用，请检查网络" }
        return nil
    }

    private var useOnDevice: Bool {
        preferOnDevice && !onDeviceBroken && (recognizer?.supportsOnDeviceRecognition ?? false)
    }

    /// Called when the keyboard appears. Never opens the microphone unless `micWarm` is on.
    func prewarm(hasFullAccess: Bool, micWarm: Bool, onDevice: Bool) {
        visible = true
        if preferOnDevice != onDevice {
            preferOnDevice = onDevice
            discardSpare()
        }
        guard permissionProblem(hasFullAccess: hasFullAccess) == nil else { return }
        configureAudioSession()
        if let s = spare, s.onDevice != useOnDevice { discardSpare() }
        if spare == nil, active == nil { spare = makeSession() }
        if micWarm, active == nil { capture.warm() } else if !micWarm, active == nil { capture.cool() }
    }

    /// Called when the keyboard disappears: everything that could hold the microphone is released.
    func cool() {
        visible = false
        if active != nil { cancel() }
        capture.cool()
        discardSpare()
        onDeviceBroken = false
        deactivateAudioSession()
    }

    // MARK: - Audio session

    /// Category only — the session is not activated here, so the microphone stays off.
    private func configureAudioSession() {
        guard !sessionConfigured else { return }
        sessionConfigured = true
        Self.sessionQueue.async {
            do {
                try AVAudioSession.sharedInstance().setCategory(
                    .playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker]
                )
            } catch {
                log.info("setCategory failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func activateAudioSession() {
        let gen = audioGeneration
        Self.sessionQueue.async {
            audioSessionState.generation = gen
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                log.info("setActive(true) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func deactivateAudioSession() {
        guard active == nil else { return }
        let gen = audioGeneration
        Self.sessionQueue.async {
            // Skip if a new dictation started in the meantime.
            guard audioSessionState.generation == gen else { return }
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                log.info("setActive(false) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Recognition sessions

    private func discardSpare() {
        spare?.task?.cancel()
        spare = nil
    }

    private func makeSession(forceServer: Bool = false) -> Session? {
        guard let recognizer, recognizer.isAvailable else { return nil }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if #available(iOS 16.0, *) { request.addsPunctuation = true }
        let onDevice = !forceServer && useOnDevice
        request.requiresOnDeviceRecognition = onDevice
        nextID += 1
        let session = Session(id: nextID, request: request, onDevice: onDevice)
        let id = session.id
        session.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let message = error?.localizedDescription
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.handle(id: id, text: text, isFinal: isFinal, error: message) }
            } else {
                DispatchQueue.main.async { self?.handle(id: id, text: text, isFinal: isFinal, error: message) }
            }
        }
        return session
    }

    /// Starts listening. Returns false when recognition could not start.
    /// Order: the recognition request is already running (spare), then the session is activated
    /// and capture started — so the first captured chunk goes straight into the request.
    func begin() -> Bool {
        if let previous = active { finalize(previous) }
        if let s = spare, s.onDevice != useOnDevice { discardSpare() }
        guard let session = spare ?? makeSession() else {
            onFailure?("语音识别暂时不可用")
            return false
        }
        spare = nil
        active = session
        audioGeneration += 1
        activateAudioSession()
        guard capture.start() else {
            active = nil
            session.task?.cancel()
            deactivateAudioSession()
            onFailure?("语音模块加载中，请稍后再试")
            return false
        }
        return true
    }

    /// Stops listening immediately: audio and recognition stop now and the last partial is
    /// delivered through `onFinish` synchronously. Late recognizer results are ignored.
    func end() {
        guard let session = active else {
            releaseAudio()
            onFinish?("")
            return
        }
        session.ended = true
        finalize(session)
    }

    func cancel() {
        guard let session = active else {
            releaseAudio()
            return
        }
        active = nil
        session.ended = true
        releaseAudio()
        session.request.endAudio()
        session.task?.cancel()
        onFinish?(nil)
        refillSpare()
    }

    /// Stops the capture stream completely; the session is deactivated once WebKit confirms the
    /// microphone is released (and right away as a backstop).
    private func releaseAudio() {
        if capture.isCapturing { capture.stop() } else { capture.cool() }
        deactivateAudioSession()
    }

    private func refillSpare() {
        guard visible, spare == nil, active == nil,
              SFSpeechRecognizer.authorizationStatus() == .authorized else { return }
        spare = makeSession()
    }

    private func finalize(_ session: Session) {
        guard active === session else { return }
        // Detach first so any result that arrives afterwards is dropped by `handle`.
        active = nil
        session.ended = true
        session.pending.removeAll()
        releaseAudio()
        session.request.endAudio()
        if !session.isFinal { session.task?.cancel() }
        onFinish?(session.text)
        refillSpare()
    }

    /// On-device recognition failed before any text: replay the audio so far to the server
    /// recognizer and keep listening, without the user noticing.
    private func fallBackToServer(from session: Session) -> Bool {
        guard session.onDevice, session.text.isEmpty, !session.ended,
              let replacement = makeSession(forceServer: true) else { return false }
        onDeviceBroken = true
        log.info("on-device recognition failed; falling back to server")
        session.task?.cancel()
        replacement.heardAudio = session.heardAudio
        for buffer in session.pending { replacement.request.append(buffer) }
        replacement.pending = session.pending
        session.pending.removeAll()
        active = replacement
        return true
    }

    private func handle(id: Int, text: String?, isFinal: Bool, error: String?) {
        if let s = spare, s.id == id {
            // An idle pre-created task timed out or failed; make a fresh one on demand.
            if error != nil {
                spare = nil
                if s.onDevice { onDeviceBroken = true }
            }
            return
        }
        guard let session = active, session.id == id else { return }
        if let text, !text.isEmpty, text != session.text {
            session.text = text
            session.pending.removeAll()
            onPartial?(text)
        }
        if isFinal {
            session.isFinal = true
            finalize(session)
            return
        }
        if let error {
            log.error("recognition error: \(error, privacy: .public)")
            if fallBackToServer(from: session) { return }
            let hadText = !session.text.isEmpty
            finalize(session)
            if !hadText, !session.ended { onFailure?("识别出错：\(error)") }
        }
    }

    private func captureEnded(_ reason: String) {
        log.info("capture ended: \(reason, privacy: .public)")
        guard reason != "stopped", let session = active, !session.ended else { return }
        let hadText = !session.text.isEmpty
        finalize(session)
        if !hadText {
            onFailure?(reason.contains("NotAllowed") ? "无法使用麦克风：请确认已开启完全访问并授予麦克风权限" : "麦克风已中断（\(reason)）")
        }
    }

    private func append(_ data: Data, rms: Float) {
        guard let session = active, !session.ended else { return }
        let frames = AVAudioFrameCount(data.count / 2)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        data.withUnsafeBytes { raw in
            buffer.int16ChannelData![0].update(from: raw.bindMemory(to: Int16.self).baseAddress!, count: Int(frames))
        }
        session.request.append(buffer)
        if session.onDevice, session.text.isEmpty, session.pending.count < 1500 { session.pending.append(buffer) }
        if !session.heardAudio {
            session.heardAudio = true
            onListening?()
        }
        onLevel?(rms)
    }
}
