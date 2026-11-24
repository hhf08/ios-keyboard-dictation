import AVFoundation
import OSLog
import Speech
import UIKit

private let log = Logger(subsystem: "net.stupidtech.keyboard-dictation-demo.keyboard", category: "dictation")

@objc(DemoKeyboardViewController)
final class DemoKeyboardViewController: UIInputViewController {
    private let capture = WebAudioCapture()
    private let dictateButton = UIButton(type: .system)
    private let nextKeyboardButton = UIButton(type: .system)
    private let statusLabel = UILabel()

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let audioFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: WebAudioCapture.sampleRate, channels: 1, interleaved: true
    )!
    /// Text currently inserted for the in-flight partial result, replaced as results refine.
    private var insertedPartial = ""
    private var capturedSamples = 0
    private var speechError: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        capture.onReady = { [weak self] in self?.render() }
        capture.onStarted = { [weak self] in self?.setStatus("正在聆听…") }
        capture.onAudio = { [weak self] data, rms in self?.append(data, rms: rms) }
        capture.onEnded = { [weak self] reason in self?.captureEnded(reason) }
        capture.attach(to: view)
        render()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if capture.isCapturing { stopDictation() }
    }

    deinit {
        MainActor.assumeIsolated { capture.tearDown() }
    }

    // MARK: - Dictation

    @objc private func toggleDictation() {
        capture.isCapturing ? stopDictation() : startDictation()
    }

    private func startDictation() {
        guard hasFullAccess else {
            return setStatus("请在设置中为此键盘打开「允许完全访问」。")
        }
        guard AVAudioSession.sharedInstance().recordPermission == .granted else {
            return setStatus("请打开「语音键盘」App 授予麦克风权限。")
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            return setStatus("请打开「语音键盘」App 授予语音识别权限。")
        }
        guard let recognizer, recognizer.isAvailable else {
            return setStatus("语音识别暂时不可用。")
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        self.request = request
        insertedPartial = ""
        capturedSamples = 0
        speechError = nil
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async { self?.handle(result: result, error: error) }
        }
        capture.start()
        setStatus("正在启动麦克风…")
        render()
    }

    private func stopDictation() {
        capture.stop()
    }

    private func captureEnded(_ reason: String) {
        log.info("capture ended: \(reason, privacy: .public)")
        log.info("captured \(self.capturedSamples) samples")
        request?.endAudio()
        if request == nil {
            finishRecognition(status: speechError.map { String(format: "已录音 %.1f 秒。识别：%@", Double(capturedSamples) / WebAudioCapture.sampleRate, $0) } ?? "完成。")
        }
        if reason != "stopped" { setStatus(reason) }
        render()
    }

    private func append(_ data: Data, rms: Float) {
        let frames = AVAudioFrameCount(data.count / 2)
        guard frames > 0 else { return }
        capturedSamples += Int(frames)
        let seconds = Double(capturedSamples) / WebAudioCapture.sampleRate
        let level = String(repeating: "▮", count: min(Int(rms * 60), 10))
        setStatus(String(format: "录音 %.1f 秒 %@", seconds, level) + (speechError.map { " · 识别：\($0)" } ?? ""))
        dictateButton.alpha = 0.6 + CGFloat(min(rms * 8, 0.4))

        guard let request, let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        data.withUnsafeBytes { raw in
            buffer.int16ChannelData![0].update(from: raw.bindMemory(to: Int16.self).baseAddress!, count: Int(frames))
        }
        request.append(buffer)
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            replacePartial(with: result.bestTranscription.formattedString)
            if result.isFinal {
                if !insertedPartial.isEmpty { textDocumentProxy.insertText(" ") }
                finishRecognition(status: "已输入。")
            }
        } else if let error {
            log.error("recognition error: \(error.localizedDescription, privacy: .public)")
            if capture.isCapturing {
                // Keep capturing so the WebKit audio path stays observable even if Speech fails.
                speechError = error.localizedDescription
                task = nil
                request = nil
            } else {
                finishRecognition(status: speechError.map { "识别：\($0)" } ?? "完成。")
            }
        }
    }

    private func replacePartial(with text: String) {
        guard text != insertedPartial else { return }
        // Only rewrite the suffix that changed to minimise flicker in the host field.
        let common = zip(insertedPartial, text).prefix { $0 == $1 }.count
        for _ in 0..<(insertedPartial.count - common) { textDocumentProxy.deleteBackward() }
        textDocumentProxy.insertText(String(text.dropFirst(common)))
        insertedPartial = text
    }

    private func finishRecognition(status: String) {
        task = nil
        request = nil
        insertedPartial = ""
        setStatus(status)
        render()
    }

    // MARK: - UI

    private func configureView() {
        let height = view.heightAnchor.constraint(equalToConstant: 180)
        height.priority = .defaultHigh
        height.isActive = true

        dictateButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        dictateButton.tintColor = .white
        dictateButton.layer.cornerRadius = 12
        dictateButton.addTarget(self, action: #selector(toggleDictation), for: .touchUpInside)

        nextKeyboardButton.setImage(UIImage(systemName: "globe"), for: .normal)
        nextKeyboardButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2

        for subview in [dictateButton, nextKeyboardButton, statusLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        let margins = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: margins.topAnchor, constant: 4),
            statusLabel.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: margins.trailingAnchor),

            dictateButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
            dictateButton.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            dictateButton.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            dictateButton.heightAnchor.constraint(equalToConstant: 64),

            nextKeyboardButton.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            nextKeyboardButton.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
            nextKeyboardButton.widthAnchor.constraint(equalToConstant: 44),
            nextKeyboardButton.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    private func render() {
        nextKeyboardButton.isHidden = !needsInputModeSwitchKey
        if capture.isCapturing {
            dictateButton.setTitle("停止", for: .normal)
            dictateButton.backgroundColor = .systemRed
        } else {
            dictateButton.alpha = 1
            dictateButton.setTitle(capture.isReady ? "语音输入" : "加载中…", for: .normal)
            dictateButton.backgroundColor = capture.isReady ? .systemBlue : .systemGray
            dictateButton.isEnabled = capture.isReady
            if statusLabel.text == nil { setStatus("点「语音输入」开始说话。") }
        }
    }

    private func setStatus(_ text: String) {
        statusLabel.text = text
    }
}
