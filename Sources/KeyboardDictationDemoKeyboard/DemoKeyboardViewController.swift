import AVFoundation
import OSLog
import Speech
import UIKit

private let log = Logger(subsystem: "net.stupidtech.keyboard-dictation-demo.keyboard", category: "dictation")

@objc(DemoKeyboardViewController)
final class DemoKeyboardViewController: UIInputViewController {
    private let capture = WebAudioCapture()
    private let engine = T9Engine()

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let audioFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: WebAudioCapture.sampleRate, channels: 1, interleaved: true
    )!
    private var insertedPartial = ""
    private var capturedSamples = 0
    private var speechError: String?

    // T9 state
    private enum Mode { case pinyin, number }
    private var mode: Mode = .pinyin
    private var digits = ""
    private var pinyinFilter: String?
    private var candidates: [T9Candidate] = []

    // Views
    private let statusLabel = UILabel()
    private let pinyinScroll = UIScrollView()
    private let pinyinStack = UIStackView()
    private let candidateScroll = UIScrollView()
    private let candidateStack = UIStackView()
    private let gridStack = UIStackView()
    private let micButton = UIButton(type: .system)
    private var modeButton: UIButton!
    private var spaceButton: UIButton!
    private var returnButton: UIButton!
    private var digitKeys: [UIButton] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        capture.onReady = { [weak self] in self?.render() }
        capture.onStarted = { [weak self] in self?.setStatus("正在聆听…") }
        capture.onAudio = { [weak self] data, rms in self?.append(data, rms: rms) }
        capture.onEnded = { [weak self] reason in self?.captureEnded(reason) }
        capture.attach(to: view)
        setStatus("词库加载中…")
        engine.loadAsync { [weak self] in
            self?.setStatus("")
            self?.refreshCandidates()
        }
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
        micButton.alpha = 0.6 + CGFloat(min(rms * 8, 0.4))

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

    // MARK: - T9 input

    private func tapDigit(_ d: Character) {
        if mode == .number {
            textDocumentProxy.insertText(String(d))
            return
        }
        guard digits.count < 24 else { return }
        digits.append(d)
        pinyinFilter = nil
        refreshCandidates()
    }

    private func tapDelete() {
        if !digits.isEmpty {
            digits.removeLast()
            pinyinFilter = nil
            refreshCandidates()
        } else {
            textDocumentProxy.deleteBackward()
        }
    }

    private func clearComposition() {
        digits = ""
        pinyinFilter = nil
        refreshCandidates()
    }

    private func commit(_ candidate: T9Candidate) {
        textDocumentProxy.insertText(candidate.text)
        digits = String(digits.dropFirst(candidate.consumed))
        pinyinFilter = nil
        refreshCandidates()
    }

    private func tapSpace() {
        if !digits.isEmpty {
            if let first = candidates.first { commit(first) } else { clearComposition() }
        } else {
            textDocumentProxy.insertText(" ")
        }
    }

    private func tapReturn() {
        if !digits.isEmpty {
            let letters = pinyinFilter?.replacingOccurrences(of: "'", with: "")
                ?? engine.pinyinOptions(for: digits).first?.replacingOccurrences(of: "'", with: "")
                ?? digits
            textDocumentProxy.insertText(letters)
            clearComposition()
        } else {
            textDocumentProxy.insertText("\n")
        }
    }

    private func insertSymbol(_ s: String) {
        if !digits.isEmpty, let first = candidates.first { commit(first) }
        textDocumentProxy.insertText(s)
    }

    private func toggleMode() {
        if !digits.isEmpty { clearComposition() }
        mode = mode == .pinyin ? .number : .pinyin
        updateKeyLabels()
    }

    private func refreshCandidates() {
        candidates = engine.isLoaded ? engine.candidates(for: digits, pinyinFilter: pinyinFilter) : []
        rebuildPinyinBar()
        rebuildCandidateBar()
        spaceButton?.setTitle(digits.isEmpty ? "空格" : "确定", for: .normal)
        returnButton?.setTitle(digits.isEmpty ? "换行" : "英文", for: .normal)
    }

    private func rebuildPinyinBar() {
        pinyinStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let showPinyin = !digits.isEmpty
        pinyinScroll.isHidden = !showPinyin
        statusLabel.isHidden = showPinyin
        guard showPinyin else { return }
        let options = engine.isLoaded ? engine.pinyinOptions(for: digits) : []
        for option in options {
            let b = UIButton(type: .system)
            b.setTitle(option, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 15, weight: option == pinyinFilter ? .bold : .regular)
            b.setTitleColor(option == pinyinFilter ? .systemBlue : .label, for: .normal)
            b.contentEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
            b.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.pinyinFilter = self.pinyinFilter == option ? nil : option
                self.refreshCandidates()
            }, for: .touchUpInside)
            pinyinStack.addArrangedSubview(b)
        }
    }

    private func rebuildCandidateBar() {
        candidateStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        candidateScroll.setContentOffset(.zero, animated: false)
        for (i, c) in candidates.prefix(80).enumerated() {
            let b = UIButton(type: .system)
            b.setTitle(c.text, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 20, weight: i == 0 ? .semibold : .regular)
            b.setTitleColor(i == 0 ? .systemBlue : .label, for: .normal)
            b.contentEdgeInsets = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
            b.addAction(UIAction { [weak self] _ in self?.commit(c) }, for: .touchUpInside)
            candidateStack.addArrangedSubview(b)
        }
    }

    // MARK: - UI

    private let keyLetters: [(Character, String)] = [
        ("1", "、"), ("2", "ABC"), ("3", "DEF"),
        ("4", "GHI"), ("5", "JKL"), ("6", "MNO"),
        ("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ"),
    ]

    private func makeKey(_ title: String, dark: Bool = false, font: UIFont = .systemFont(ofSize: 18), action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = font
        b.titleLabel?.numberOfLines = 2
        b.titleLabel?.textAlignment = .center
        b.setTitleColor(.label, for: .normal)
        b.backgroundColor = dark ? UIColor.systemGray3 : UIColor.systemBackground
        b.layer.cornerRadius = 6
        b.layer.shadowColor = UIColor.black.cgColor
        b.layer.shadowOpacity = 0.25
        b.layer.shadowOffset = CGSize(width: 0, height: 1)
        b.layer.shadowRadius = 0
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }

    private func column(_ views: [UIView]) -> UIStackView {
        let s = UIStackView(arrangedSubviews: views)
        s.axis = .vertical
        s.distribution = .fillEqually
        s.spacing = 6
        return s
    }

    private func row(_ views: [UIView], equal: Bool = true) -> UIStackView {
        let s = UIStackView(arrangedSubviews: views)
        s.axis = .horizontal
        s.distribution = equal ? .fillEqually : .fill
        s.spacing = 6
        return s
    }

    private func configureView() {
        let height = view.heightAnchor.constraint(equalToConstant: 290)
        height.priority = .defaultHigh
        height.isActive = true

        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 1

        pinyinStack.axis = .horizontal
        pinyinStack.spacing = 2
        pinyinScroll.showsHorizontalScrollIndicator = false
        pinyinScroll.addSubview(pinyinStack)
        candidateStack.axis = .horizontal
        candidateStack.spacing = 2
        candidateScroll.showsHorizontalScrollIndicator = false
        candidateScroll.addSubview(candidateStack)

        // Left: punctuation + mode switch
        modeButton = makeKey("123", dark: true, font: .systemFont(ofSize: 15)) { [weak self] in self?.toggleMode() }
        let left = column(["，", "。", "？"].map { s in
            makeKey(s, dark: true) { [weak self] in self?.insertSymbol(s) }
        } + [modeButton])

        // Middle: 3x3 + 0
        var rows: [UIView] = []
        for r in 0..<3 {
            var keys: [UIView] = []
            for c in 0..<3 {
                let (d, _) = keyLetters[r * 3 + c]
                let b = makeKey("", font: .systemFont(ofSize: 17)) { [weak self] in
                    guard let self else { return }
                    if d == "1" && self.mode == .pinyin { self.insertSymbol("、") } else { self.tapDigit(d) }
                }
                digitKeys.append(b)
                keys.append(b)
            }
            rows.append(row(keys))
        }
        let zeroKey = makeKey("0") { [weak self] in
            guard let self else { return }
            if self.mode == .number { self.textDocumentProxy.insertText("0") } else { self.insertSymbol("…") }
        }
        digitKeys.append(zeroKey)
        spaceButton = makeKey("空格") { [weak self] in self?.tapSpace() }
        let globe = UIButton(type: .system)
        globe.setImage(UIImage(systemName: "globe"), for: .normal)
        globe.tintColor = .label
        globe.backgroundColor = .systemGray3
        globe.layer.cornerRadius = 6
        globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        globe.isHidden = !needsInputModeSwitchKey
        let bottomMiddle = row([globe, zeroKey, spaceButton], equal: false)
        zeroKey.widthAnchor.constraint(equalTo: spaceButton.widthAnchor, multiplier: 0.5).isActive = true
        let globeWidth = globe.widthAnchor.constraint(equalTo: zeroKey.widthAnchor)
        globeWidth.priority = .defaultHigh
        globeWidth.isActive = true
        rows.append(bottomMiddle)
        let middle = column(rows)

        // Right: delete, clear, mic, return
        let deleteKey = makeKey("⌫", dark: true) { [weak self] in self?.tapDelete() }
        let clearKey = makeKey("重输", dark: true, font: .systemFont(ofSize: 15)) { [weak self] in self?.clearComposition() }
        micButton.setTitle("🎤 语音", for: .normal)
        micButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        micButton.setTitleColor(.white, for: .normal)
        micButton.layer.cornerRadius = 6
        micButton.addTarget(self, action: #selector(toggleDictation), for: .touchUpInside)
        returnButton = makeKey("换行", dark: true, font: .systemFont(ofSize: 15)) { [weak self] in self?.tapReturn() }
        let right = column([deleteKey, clearKey, micButton, returnButton])

        let main = row([left, middle, right], equal: false)
        left.widthAnchor.constraint(equalTo: middle.widthAnchor, multiplier: 0.2).isActive = true
        right.widthAnchor.constraint(equalTo: middle.widthAnchor, multiplier: 0.22).isActive = true

        for v in [statusLabel, pinyinScroll, candidateScroll, main] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        pinyinStack.translatesAutoresizingMaskIntoConstraints = false
        candidateStack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            statusLabel.heightAnchor.constraint(equalToConstant: 22),

            pinyinScroll.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            pinyinScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            pinyinScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            pinyinScroll.heightAnchor.constraint(equalToConstant: 22),
            pinyinStack.topAnchor.constraint(equalTo: pinyinScroll.contentLayoutGuide.topAnchor),
            pinyinStack.bottomAnchor.constraint(equalTo: pinyinScroll.contentLayoutGuide.bottomAnchor),
            pinyinStack.leadingAnchor.constraint(equalTo: pinyinScroll.contentLayoutGuide.leadingAnchor),
            pinyinStack.trailingAnchor.constraint(equalTo: pinyinScroll.contentLayoutGuide.trailingAnchor),
            pinyinStack.heightAnchor.constraint(equalTo: pinyinScroll.frameLayoutGuide.heightAnchor),

            candidateScroll.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 2),
            candidateScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            candidateScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            candidateScroll.heightAnchor.constraint(equalToConstant: 40),
            candidateStack.topAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.topAnchor),
            candidateStack.bottomAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.bottomAnchor),
            candidateStack.leadingAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.leadingAnchor),
            candidateStack.trailingAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.trailingAnchor),
            candidateStack.heightAnchor.constraint(equalTo: candidateScroll.frameLayoutGuide.heightAnchor),

            main.topAnchor.constraint(equalTo: candidateScroll.bottomAnchor, constant: 4),
            main.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            main.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),

            main.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
        ])
        updateKeyLabels()
    }

    private func updateKeyLabels() {
        for (i, b) in digitKeys.enumerated() {
            if i < keyLetters.count {
                let (d, letters) = keyLetters[i]
                if mode == .number {
                    b.setTitle(String(d), for: .normal)
                    b.titleLabel?.font = .systemFont(ofSize: 22)
                } else {
                    b.setTitle(d == "1" ? "、" : letters, for: .normal)
                    b.titleLabel?.font = .systemFont(ofSize: 17)
                }
            } else {
                b.setTitle(mode == .number ? "0" : "…", for: .normal)
            }
        }
        modeButton?.setTitle(mode == .number ? "拼音" : "123", for: .normal)
    }

    private func render() {
        if capture.isCapturing {
            micButton.setTitle("■ 停止", for: .normal)
            micButton.backgroundColor = .systemRed
        } else {
            micButton.alpha = 1
            micButton.setTitle(capture.isReady ? "🎤 语音" : "加载中", for: .normal)
            micButton.backgroundColor = capture.isReady ? .systemBlue : .systemGray
            micButton.isEnabled = capture.isReady
        }
    }

    private func setStatus(_ text: String) {
        statusLabel.text = text
    }
}
