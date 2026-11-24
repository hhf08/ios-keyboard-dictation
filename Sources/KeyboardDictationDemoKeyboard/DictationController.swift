import AVFoundation
import OSLog
import Speech
import UIKit

private let log = Logger(subsystem: "net.stupidtech.keyboard-dictation-demo.keyboard", category: "dictation")

/// Hold-to-talk dictation: microphone through `WebAudioCapture` (no app switch), zh-CN
/// `SFSpeechRecognizer` with streamed partial results.
///
/// Latency work: a recognition request/task is created ahead of time ("spare") when the keyboard
/// appears, and the microphone can be pre-warmed, so `begin()` just routes audio that is already
/// flowing into a recognizer that is already waiting.
@MainActor
final class DictationController: NSObject {
    let capture = WebAudioCapture()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: WebAudioCapture.sampleRate, channels: 1, interleaved: true
    )!

    private final class Session {
        let id: Int
        let request: SFSpeechAudioBufferRecognitionRequest
        var task: SFSpeechRecognitionTask?
        var text = ""
        var ended = false
        var heardAudio = false
        var isFinal = false
        init(id: Int, request: SFSpeechAudioBufferRecognitionRequest) {
            self.id = id
            self.request = request
        }
    }

    private var nextID = 0
    private var spare: Session?
    private var active: Session?
    private var onDevice = false
    private var visible = false

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
        capture.attach(to: view)
    }

    func permissionProblem(hasFullAccess: Bool) -> String? {
        guard hasFullAccess else { return "请在 设置→通用→键盘→键盘 中为「语音键盘」开启「允许完全访问」" }
        guard AVAudioSession.sharedInstance().recordPermission == .granted else { return "请先打开「语音键盘」App 授予麦克风权限" }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return "请先打开「语音键盘」App 授予语音识别权限" }
        guard let recognizer, recognizer.isAvailable else { return "语音识别暂时不可用，请检查网络" }
        return nil
    }

    /// Called when the keyboard appears.
    func prewarm(hasFullAccess: Bool, micWarm: Bool, onDevice: Bool) {
        visible = true
        if self.onDevice != onDevice {
            self.onDevice = onDevice
            discardSpare()
        }
        guard permissionProblem(hasFullAccess: hasFullAccess) == nil else { return }
        if spare == nil, active == nil { spare = makeSession() }
        if micWarm { capture.warm() } else { capture.cool() }
    }

    /// Called when the keyboard disappears.
    func cool() {
        visible = false
        if active != nil { cancel() }
        capture.cool()
        discardSpare()
    }

    private func discardSpare() {
        spare?.task?.cancel()
        spare = nil
    }

    private func makeSession() -> Session? {
        guard let recognizer, recognizer.isAvailable else { return nil }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        if onDevice, recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        nextID += 1
        let session = Session(id: nextID, request: request)
        let id = session.id
        session.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let message = error?.localizedDescription
            DispatchQueue.main.async { self?.handle(id: id, text: text, isFinal: isFinal, error: message) }
        }
        return session
    }

    /// Starts listening. Returns false when recognition could not start.
    func begin() -> Bool {
        if let previous = active { finalize(previous) }
        guard let session = spare ?? makeSession() else {
            onFailure?("语音识别暂时不可用")
            return false
        }
        spare = nil
        active = session
        guard capture.start() else {
            active = nil
            session.task?.cancel()
            onFailure?("语音模块加载中，请稍后再试")
            return false
        }
        return true
    }

    /// Stops listening immediately: audio and recognition stop now and the last partial is
    /// delivered through `onFinish` synchronously. Late recognizer results are ignored.
    func end() {
        guard let session = active else {
            onFinish?("")
            return
        }
        session.ended = true
        finalize(session)
    }

    func cancel() {
        guard let session = active else { return }
        active = nil
        session.ended = true
        if capture.isCapturing { capture.stop() }
        session.request.endAudio()
        session.task?.cancel()
        onFinish?(nil)
        refillSpare()
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
        if capture.isCapturing { capture.stop() }
        session.request.endAudio()
        if !session.isFinal { session.task?.cancel() }
        onFinish?(session.text)
        refillSpare()
    }

    private func handle(id: Int, text: String?, isFinal: Bool, error: String?) {
        if let s = spare, s.id == id {
            // An idle pre-created task timed out or failed; make a fresh one on demand.
            if error != nil { spare = nil }
            return
        }
        guard let session = active, session.id == id else { return }
        if let text, !text.isEmpty, text != session.text {
            session.text = text
            onPartial?(text)
        }
        if isFinal {
            session.isFinal = true
            finalize(session)
            return
        }
        if let error {
            log.error("recognition error: \(error, privacy: .public)")
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
        if !session.heardAudio {
            session.heardAudio = true
            onListening?()
        }
        onLevel?(rms)
    }
}
