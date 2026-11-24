import AVFoundation
import Speech
import UIKit

/// Baidu-style Chinese keyboard: 九键拼音 / 全键盘拼音 / English QWERTY, number pad, symbols,
/// toolbar (语音 / 剪贴板 / 键盘切换 / 设置 / 收起) and hold-to-talk dictation without app switching.
@objc(DemoKeyboardViewController)
final class DemoKeyboardViewController: UIInputViewController {
    private let engine = T9Engine()
    private let dictation = DictationController()
    private let lightHaptic = UIImpactFeedbackGenerator(style: .light)
    private let startHaptic = UIImpactFeedbackGenerator(style: .medium)

    private enum Lang { case chinese, english }
    private enum Page { case main, number, symbols }
    private enum Shift { case off, once, locked }
    /// `spaceSpeculative`: space is down, the microphone and recognizer are already running but the
    /// hold threshold has not passed yet (no UI, no text). Becomes `spaceHold` or is cancelled.
    private enum VoiceTrigger { case none, spaceSpeculative, spaceHold, micHold, micToggle, finishing }

    private static let topBarHeight = CGFloat(KeyboardSettings.topBarHeight)

    // State
    private var lang: Lang = .chinese
    private var page: Page = .main
    private var layoutKind: ChineseLayout = .t9
    private var compose = ""
    private var pinyinFilter: String?
    private var candidates: [T9Candidate] = []
    private var pinyinOptions: [String] = []
    private var sideShowsPinyin = false
    private var shift: Shift = .off
    private var lastShiftTap = Date.distantPast
    private var lastSpaceTap = Date.distantPast
    private var candidatesExpanded = false
    private var hapticsOn = true
    private var statusToken = 0
    private var statusVisible = false

    // Voice state
    private var voiceTrigger: VoiceTrigger = .none
    private var spaceTimer: Timer?
    private var spaceHoldFired = false
    private var cancelArmed = false
    private var micDownAt = Date.distantPast
    private var ignoreMicUp = false
    /// Latest partial recognized while the space press is still speculative (shown once confirmed).
    private var speculativeText = ""
    private var heightScale = 1.0
    // Live inline dictation: the partial text currently in the document.
    private var inlineText = ""
    private var inlineMarked = false
    private var inlineCompatMode = false

    // Delete repeat
    private var deleteTimer: Timer?
    private var deleteCount = 0
    private var deleteWasComposing = false

    // Views
    private var heightConstraint: NSLayoutConstraint!
    private let topBar = UIView()
    private let toolbar = PageView()
    private var layoutToggleButton: KeyButton!
    private let candidateBar = CandidateBarView()
    private let statusLabel = UILabel()
    private let keyArea = PageView()
    private let t9Page = PageView()
    private let qwertyPage = PageView()
    private let numberPage = PageView()
    private let symbolPage = PageView()
    private let candidatePanel = PageView()
    private let candidateGrid = CandidateGridView()
    private let clipboardPanel = PageView()
    private let settingsPanel = PageView()
    private let waveBar = WaveBarView()
    private let popup = UILabel()

    private var spaceKeys: [KeyButton] = []
    private var returnKeys: [KeyButton] = []
    private var langKeys: [KeyButton] = []
    private var globeKeys: [KeyButton] = []

    private let t9Side = SideListView()
    private var letterKeys: [(Character, KeyButton)] = []
    private var shiftKey: KeyButton!
    private var qwertyPunctKey: KeyButton!
    private let numberSide = SideListView()
    private let symbolSide = SideListView()
    private let symbolScroll = TouchScrollView()
    private var symbolTabKeys: [KeyButton] = []
    private var symbolKeys: [KeyButton] = []
    private var symbolTab = 0
    private var symbolCategory = 0

    private let clipScroll = TouchScrollView()
    private var clipRows: [UIView] = []
    private let hapticSwitch = UISwitch()
    private let prewarmSwitch = UISwitch()
    private let onDeviceSwitch = UISwitch()
    private let inlineCompatSwitch = UISwitch()
    private let layoutSegment = UISegmentedControl(items: ["九键", "全键盘"])
    private let heightSlider = UISlider()
    private let heightValueLabel = UILabel()

    private var isT9: Bool { lang == .chinese && layoutKind == .t9 }
    private var isFullPinyin: Bool { lang == .chinese && layoutKind == .qwerty }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = KBColor.background
        view.isMultipleTouchEnabled = true
        heightConstraint = view.heightAnchor.constraint(equalToConstant: 266)
        heightConstraint.priority = UILayoutPriority(999)
        heightConstraint.isActive = true

        KeyButton.onPress = { [weak self] in self?.tick() }

        buildTopBar()
        buildT9Page()
        buildQwertyPage()
        buildNumberPage()
        buildSymbolPage()
        buildCandidatePanel()
        buildClipboardPanel()
        buildSettingsPanel()

        waveBar.isHidden = true
        waveBar.doneButton.addAction(UIAction { [weak self] _ in self?.stopVoice() }, for: .touchUpInside)
        waveBar.onTap = { [weak self] in
            if self?.voiceTrigger == .micToggle { self?.stopVoice() }
        }
        topBar.addSubview(waveBar)

        popup.isHidden = true
        popup.textAlignment = .center
        popup.font = .systemFont(ofSize: 30)
        popup.textColor = .label
        popup.backgroundColor = KBColor.popup
        popup.layer.cornerRadius = 8
        popup.layer.masksToBounds = true
        view.addSubview(popup)

        dictation.onPartial = { [weak self] text in
            guard let self else { return }
            switch self.voiceTrigger {
            case .none: return
            case .spaceSpeculative: self.speculativeText = text
            default: self.setInline(text)
            }
        }
        dictation.onLevel = { [weak self] rms in
            guard let self, self.voiceTrigger != .none, self.voiceTrigger != .finishing,
                  self.voiceTrigger != .spaceSpeculative else { return }
            self.waveBar.setLevel(rms)
        }
        dictation.onListening = nil
        dictation.onFinish = { [weak self] text in
            guard let self else { return }
            if self.voiceTrigger == .spaceSpeculative {
                // Recognition ended before the hold was confirmed: keep the text for the hold, show nothing.
                if let text, !text.isEmpty { self.speculativeText = text }
                self.voiceTrigger = .none
                return
            }
            self.voiceFinished(text)
        }
        dictation.onFailure = { [weak self] message in
            guard let self, self.voiceTrigger != .spaceSpeculative else { return }
            self.showStatus(message, duration: 3.5)
        }
        dictation.attach(to: view)

        showStatus("词库加载中…", duration: 10)
        engine.loadAsync { [weak self] in
            guard let self else { return }
            self.statusVisible = false
            self.refresh()
        }
        applySettings()
        showPage(.main)
        refresh()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applySettings()
        applyAppearance()
        lightHaptic.prepare()
        startHaptic.prepare()
        // Pre-warm: recognizer task, and (optionally) the microphone stream, before the first press.
        dictation.prewarm(hasFullAccess: hasFullAccess, micWarm: KeyboardSettings.micPrewarm, onDevice: KeyboardSettings.onDeviceRecognition)
        updateGlobeKeys()
        refresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Bottom-row keys otherwise get their touch-down delayed by the system edge gesture.
        view.window?.gestureRecognizers?.forEach { $0.delaysTouchesBegan = false }
        updateGlobeKeys()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        spaceTimer?.invalidate()
        spaceTimer = nil
        deleteUp()
        if voiceTrigger == .spaceSpeculative {
            voiceTrigger = .none
            speculativeText = ""
        } else if voiceTrigger != .none {
            // Keep whatever was already recognized in the document.
            voiceTrigger = .none
            commitInline(inlineText)
            endWaveBar()
        }
        dictation.cool()
        clearCompose()
        hidePanels()
    }

    deinit {
        MainActor.assumeIsolated { dictation.capture.tearDown() }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        applyHeight()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let b = view.bounds
        let top = Self.topBarHeight
        topBar.frame = CGRect(x: 0, y: 0, width: b.width, height: top)
        toolbar.frame = topBar.bounds
        candidateBar.frame = topBar.bounds
        statusLabel.frame = topBar.bounds.insetBy(dx: 12, dy: 0)
        keyArea.frame = CGRect(x: 0, y: top + 2, width: b.width, height: max(0, b.height - top - 2))
        for v in [t9Page, qwertyPage, numberPage, symbolPage, candidatePanel, clipboardPanel, settingsPanel] {
            v.frame = keyArea.bounds
        }
        waveBar.frame = topBar.bounds
        topBar.bringSubviewToFront(waveBar)
        view.bringSubviewToFront(popup)
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        applyAppearance()
        updateReturnKeys()
    }

    /// Sets the input view height from the height setting; every page lays its rows out from the
    /// key area's bounds, so all of them scale with it.
    private func applyHeight() {
        let screen = UIScreen.main.bounds
        let target = CGFloat(KeyboardSettings.keyboardHeight(landscape: screen.width > screen.height, scale: heightScale))
        if heightConstraint.constant != target { heightConstraint.constant = target }
    }

    private func setHeightScale(_ value: Double, save: Bool) {
        let r = KeyboardSettings.heightScaleRange
        let v = (min(max(value, r.lowerBound), r.upperBound) * 20).rounded() / 20
        heightScale = v
        if save { KeyboardSettings.heightScale = v }
        heightSlider.value = Float(v)
        let pct = Int((v * 100).rounded())
        heightValueLabel.text = pct == 100 ? "默认 100%" : "\(pct)%"
        applyHeight()
        view.setNeedsLayout()
    }

    private func applySettings() {
        hapticsOn = KeyboardSettings.haptics
        setHeightScale(KeyboardSettings.heightScale, save: false)
        let newLayout = KeyboardSettings.layout
        if newLayout != layoutKind {
            layoutKind = newLayout
            clearCompose()
            if page == .main { showPage(.main) }
        }
        hapticSwitch.isOn = hapticsOn
        prewarmSwitch.isOn = KeyboardSettings.micPrewarm
        onDeviceSwitch.isOn = KeyboardSettings.onDeviceRecognition
        inlineCompatSwitch.isOn = KeyboardSettings.inlineCompat
        layoutSegment.selectedSegmentIndex = layoutKind == .t9 ? 0 : 1
        layoutToggleButton?.setIcon(layoutKind == .t9 ? "keyboard" : "square.grid.3x3", size: 18)
    }

    private func applyAppearance() {
        let appearance = textDocumentProxy.keyboardAppearance ?? .default
        view.overrideUserInterfaceStyle = appearance == .dark ? .dark : .unspecified
    }

    private func tick() {
        guard hapticsOn else { return }
        lightHaptic.impactOccurred()
        lightHaptic.prepare()
    }

    // MARK: - Key factories

    private func makeKey(_ title: String, sub: String? = nil, icon: String? = nil, style: KeyButton.Style = .char,
                         size: CGFloat = 18, _ action: @escaping () -> Void) -> KeyButton {
        let b = KeyButton(title, sub: sub, icon: icon, style: style, fontSize: size)
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }

    private func makeDeleteKey() -> KeyButton {
        let b = KeyButton("", icon: "delete.left", style: .function, iconSize: 18)
        b.addAction(UIAction { [weak self] _ in self?.deleteDown() }, for: .touchDown)
        b.addAction(UIAction { [weak self] _ in self?.deleteUp() }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return b
    }

    private func makeSpaceKey() -> KeyButton {
        let b = KeyButton("空格", icon: "mic", style: .char, fontSize: 16, iconSize: 12)
        b.addAction(UIAction { [weak self] _ in self?.spaceDown() }, for: .touchDown)
        b.addAction(UIAction { [weak self] _ in self?.spaceUp(inside: true) }, for: .touchUpInside)
        b.addAction(UIAction { [weak self] _ in self?.spaceUp(inside: false) }, for: [.touchUpOutside, .touchCancel])
        b.onTrack = { [weak self, weak b] touch in
            guard let self, let b else { return }
            self.spaceTracked(touch.location(in: b).y)
        }
        spaceKeys.append(b)
        return b
    }

    private func makeReturnKey() -> KeyButton {
        let b = makeKey("换行", style: .function, size: 16) { [weak self] in self?.tapReturn() }
        returnKeys.append(b)
        return b
    }

    private func makeLangKey() -> KeyButton {
        let b = makeKey("", style: .function, size: 16) { [weak self] in self?.toggleLang() }
        b.keepsTitleColors = true
        langKeys.append(b)
        return b
    }

    private func makeGlobeKey() -> KeyButton {
        let b = KeyButton("", icon: "globe", style: .function, iconSize: 18)
        b.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        globeKeys.append(b)
        return b
    }

    // MARK: - Top bar

    private func buildTopBar() {
        view.addSubview(topBar)
        view.addSubview(keyArea)
        keyArea.isMultipleTouchEnabled = true

        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusLabel.adjustsFontSizeToFitWidth = true
        statusLabel.minimumScaleFactor = 0.7

        let mic = KeyButton("", icon: "mic", style: .plain, iconSize: 19)
        mic.addAction(UIAction { [weak self] _ in self?.micDown() }, for: .touchDown)
        mic.addAction(UIAction { [weak self] _ in self?.micUp() }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        let clip = makeKey("", icon: "doc.on.clipboard", style: .plain) { [weak self] in self?.toggleClipboard() }
        layoutToggleButton = makeKey("", icon: "keyboard", style: .plain) { [weak self] in self?.toggleLayout() }
        let gear = makeKey("", icon: "gearshape", style: .plain) { [weak self] in self?.toggleSettings() }
        let hide = makeKey("", icon: "keyboard.chevron.compact.down", style: .plain) { [weak self] in self?.dismissKeyboard() }
        // 语音 | 九键/全键盘 | 剪贴板 | 设置 | 收起
        let buttons = [mic, layoutToggleButton!, clip, gear, hide]
        buttons.forEach { toolbar.addSubview($0) }
        toolbar.layout = { v in
            let slot = v.bounds.width / CGFloat(buttons.count)
            for (i, b) in buttons.enumerated() {
                b.frame = CGRect(x: slot * CGFloat(i) + (slot - 48) / 2, y: 4, width: 48, height: v.bounds.height - 8)
                b.layer.cornerRadius = 8
            }
        }

        candidateBar.onSelect = { [weak self] i in
            guard let self, i < self.candidates.count else { return }
            self.commit(self.candidates[i])
        }
        candidateBar.expandButton.addAction(UIAction { [weak self] _ in self?.toggleExpanded() }, for: .touchUpInside)

        for v in [toolbar, candidateBar, statusLabel] as [UIView] { topBar.addSubview(v) }
    }

    private func updateTopBar() {
        let voice = voiceTrigger != .none && voiceTrigger != .spaceSpeculative
        let composing = !compose.isEmpty
        waveBar.isHidden = !voice
        candidateBar.isHidden = voice || !composing
        statusLabel.isHidden = voice || composing || !statusVisible
        toolbar.isHidden = voice || composing || statusVisible
    }

    private func showStatus(_ text: String, duration: TimeInterval = 2.5) {
        statusToken += 1
        let token = statusToken
        statusLabel.text = text
        statusVisible = true
        updateTopBar()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.statusToken == token else { return }
            self.statusVisible = false
            self.updateTopBar()
        }
    }

    // MARK: - Pages

    private func buildT9Page() {
        keyArea.addSubview(t9Page)
        t9Side.onSelect = { [weak self] i in self?.sideSelected(i) }
        t9Page.addSubview(t9Side)
        let digitKeys: [KeyButton] = (1...9).map { n in
            let d = Character(String(n))
            if n == 1 {
                return makeKey("分词", sub: "1", size: 16) { [weak self] in self?.tapT9Separator() }
            }
            let letters = (T9Engine.letters[d] ?? "").uppercased()
            return makeKey(letters, sub: String(n), size: 19) { [weak self] in self?.tapT9(d) }
        }
        let del = makeDeleteKey()
        let clear = makeKey("重输", style: .function, size: 16) { [weak self] in self?.clearCompose() }
        let zero = makeKey("0", style: .function, size: 19) { [weak self] in self?.insertPunctuation("0") }
        let sym = makeKey("符号", style: .function, size: 15) { [weak self] in self?.showPage(.symbols) }
        let num = makeKey("123", style: .function, size: 15) { [weak self] in self?.showPage(.number) }
        let globe = makeGlobeKey()
        let langKey = makeLangKey()
        let space = makeSpaceKey()
        let ret = makeReturnKey()
        (digitKeys + [del, clear, zero, sym, num, globe, space, langKey, ret]).forEach { t9Page.addSubview($0) }
        t9Page.layout = { [weak self] v in
            guard let self else { return }
            let m = KeyMetrics(v.bounds)
            self.t9Side.frame = CGRect(x: m.inset, y: 0, width: m.side, height: m.threeRows)
            for (i, k) in digitKeys.enumerated() {
                k.frame = CGRect(x: m.centerX(i % 3), y: m.y(i / 3), width: m.key, height: m.rowH)
            }
            for (r, k) in [del, clear, zero].enumerated() {
                k.frame = CGRect(x: m.rightX, y: m.y(r), width: m.rightW, height: m.rowH)
            }
            sym.frame = CGRect(x: m.inset, y: m.y(3), width: m.side, height: m.rowH)
            ret.frame = CGRect(x: m.rightX, y: m.y(3), width: m.rightW, height: m.rowH)
            // 符号 | 123 [🌐] 空格 中/英 | 换行
            let small = floor(m.key * 0.62)
            m.distribute([(num as UIView, small), (globe as UIView, floor(m.key * 0.5)), (space as UIView, CGFloat(0)),
                          (langKey as UIView, small)], x: m.centerX(0), width: m.centerSpan, y: m.y(3))
        }
    }

    private func buildQwertyPage() {
        keyArea.addSubview(qwertyPage)
        let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
        var rowKeys: [[KeyButton]] = []
        for r in rows {
            var keys: [KeyButton] = []
            for ch in r {
                let b = KeyButton(String(ch), style: .char, fontSize: 22)
                b.titleLabel.adjustsFontSizeToFitWidth = false
                b.addAction(UIAction { [weak self, weak b] _ in
                    if let b { self?.showPopup(for: b) }
                }, for: .touchDown)
                b.addAction(UIAction { [weak self] _ in
                    self?.hidePopup()
                    self?.tapLetter(ch)
                }, for: .touchUpInside)
                b.addAction(UIAction { [weak self] _ in self?.hidePopup() }, for: [.touchUpOutside, .touchCancel, .touchDragExit])
                letterKeys.append((ch, b))
                keys.append(b)
                qwertyPage.addSubview(b)
            }
            rowKeys.append(keys)
        }
        shiftKey = KeyButton("", icon: "shift", style: .function, fontSize: 14, iconSize: 18)
        shiftKey.addAction(UIAction { [weak self] _ in self?.tapShift() }, for: .touchDown)
        let del = makeDeleteKey()
        let num = makeKey("123", style: .function, size: 15) { [weak self] in self?.showPage(.number) }
        let globe = makeGlobeKey()
        let sym = makeKey("符号", style: .function, size: 15) { [weak self] in self?.showPage(.symbols) }
        let langKey = makeLangKey()
        let space = makeSpaceKey()
        qwertyPunctKey = makeKey("，", style: .char, size: 19) { [weak self] in
            guard let self else { return }
            self.insertPunctuation(self.lang == .english ? "," : "，")
        }
        let ret = makeReturnKey()
        let shift = shiftKey!, punct = qwertyPunctKey!
        [shift, del, sym, num, globe, punct, space, langKey, ret].forEach { qwertyPage.addSubview($0) }
        qwertyPage.layout = { v in
            let m = KeyMetrics(v.bounds)
            let usable = v.bounds.width - m.inset * 2
            let kw = floor((usable - m.gap * 9) / 10)
            for (i, k) in rowKeys[0].enumerated() {
                k.frame = CGRect(x: m.inset + CGFloat(i) * (kw + m.gap), y: m.y(0), width: kw, height: m.rowH)
            }
            let x1 = m.inset + (usable - (kw * 9 + m.gap * 8)) / 2
            for (i, k) in rowKeys[1].enumerated() {
                k.frame = CGRect(x: x1 + CGFloat(i) * (kw + m.gap), y: m.y(1), width: kw, height: m.rowH)
            }
            let wide = floor(kw * 1.35)
            shift.frame = CGRect(x: m.inset, y: m.y(2), width: wide, height: m.rowH)
            del.frame = CGRect(x: v.bounds.width - m.inset - wide, y: m.y(2), width: wide, height: m.rowH)
            let x2 = m.inset + (usable - (kw * 7 + m.gap * 6)) / 2
            for (i, k) in rowKeys[2].enumerated() {
                k.frame = CGRect(x: x2 + CGFloat(i) * (kw + m.gap), y: m.y(2), width: kw, height: m.rowH)
            }
            // 符号 123 [🌐] ， 空格 中/英 换行
            m.distribute([(sym as UIView, floor(kw * 1.25)), (num as UIView, floor(kw * 1.25)), (globe as UIView, kw),
                          (punct as UIView, kw), (space as UIView, CGFloat(0)), (langKey as UIView, floor(kw * 1.25)),
                          (ret as UIView, floor(kw * 1.9))],
                         x: m.inset, width: usable, y: m.y(3))
        }
    }

    private func buildNumberPage() {
        keyArea.addSubview(numberPage)
        numberSide.setItems(SymbolData.numberSide)
        numberSide.onSelect = { [weak self] i in self?.insertPunctuation(SymbolData.numberSide[i]) }
        numberPage.addSubview(numberSide)
        let digitKeys: [KeyButton] = (1...9).map { n in
            makeKey(String(n), size: 24) { [weak self] in self?.insertPunctuation(String(n)) }
        }
        let del = makeDeleteKey()
        let at = makeKey("@", style: .function, size: 20) { [weak self] in self?.insertPunctuation("@") }
        let dot = makeKey(".", style: .function, size: 24) { [weak self] in self?.insertPunctuation(".") }
        let back = makeKey("返回", style: .function, size: 15) { [weak self] in self?.showPage(.main) }
        let sym = makeKey("符号", style: .function, size: 15) { [weak self] in self?.showPage(.symbols) }
        let zero = makeKey("0", size: 24) { [weak self] in self?.insertPunctuation("0") }
        let space = makeSpaceKey()
        let ret = makeReturnKey()
        (digitKeys + [del, at, dot, back, sym, zero, space, ret]).forEach { numberPage.addSubview($0) }
        numberPage.layout = { [weak self] v in
            guard let self else { return }
            let m = KeyMetrics(v.bounds)
            self.numberSide.frame = CGRect(x: m.inset, y: 0, width: m.side, height: m.threeRows)
            for (i, k) in digitKeys.enumerated() {
                k.frame = CGRect(x: m.centerX(i % 3), y: m.y(i / 3), width: m.key, height: m.rowH)
            }
            for (r, k) in [del, at, dot].enumerated() {
                k.frame = CGRect(x: m.rightX, y: m.y(r), width: m.rightW, height: m.rowH)
            }
            back.frame = CGRect(x: m.inset, y: m.y(3), width: m.side, height: m.rowH)
            for (c, k) in [sym, zero, space].enumerated() {
                k.frame = CGRect(x: m.centerX(c), y: m.y(3), width: m.key, height: m.rowH)
            }
            ret.frame = CGRect(x: m.rightX, y: m.y(3), width: m.rightW, height: m.rowH)
        }
    }

    private func buildSymbolPage() {
        keyArea.addSubview(symbolPage)
        symbolSide.onSelect = { [weak self] i in self?.selectSymbolCategory(i) }
        symbolScroll.alwaysBounceVertical = true
        symbolPage.addSubview(symbolSide)
        symbolPage.addSubview(symbolScroll)
        let back = makeKey("返回", style: .function, size: 15) { [weak self] in self?.showPage(.main) }
        symbolTabKeys = SymbolData.tabs.enumerated().map { i, tab in
            makeKey(tab.name, style: .function, size: 15) { [weak self] in self?.selectSymbolTab(i) }
        }
        let del = makeDeleteKey()
        let tabs = symbolTabKeys
        ([back, del] + tabs).forEach { symbolPage.addSubview($0) }
        symbolPage.layout = { [weak self] v in
            guard let self else { return }
            let m = KeyMetrics(v.bounds)
            self.symbolSide.frame = CGRect(x: m.inset, y: 0, width: m.side, height: m.threeRows)
            self.symbolScroll.frame = CGRect(x: m.centerX(0), y: 0, width: v.bounds.width - m.inset - m.centerX(0), height: m.threeRows)
            self.layoutSymbolGrid(rowHeight: floor((m.threeRows - m.gap * 2) / 3), gap: m.gap)
            back.frame = CGRect(x: m.inset, y: m.y(3), width: m.side, height: m.rowH)
            m.distribute(tabs.map { ($0 as UIView, CGFloat(0)) }, x: m.centerX(0), width: m.centerSpan, y: m.y(3))
            del.frame = CGRect(x: m.rightX, y: m.y(3), width: m.rightW, height: m.rowH)
        }
        selectSymbolTab(0)
    }

    private func selectSymbolTab(_ index: Int) {
        symbolTab = index
        for (i, k) in symbolTabKeys.enumerated() { k.isSelectedState = i == index }
        selectSymbolCategory(0)
    }

    private func selectSymbolCategory(_ index: Int) {
        let tab = SymbolData.tabs[symbolTab]
        symbolCategory = min(index, tab.categories.count - 1)
        symbolSide.setItems(tab.categories.map(\.name), selected: symbolCategory)
        symbolKeys.forEach { $0.removeFromSuperview() }
        symbolKeys = tab.categories[symbolCategory].items.map { s in
            let b = makeKey(s, size: s.count > 2 ? 14 : 20) { [weak self] in self?.insertSymbolText(s) }
            symbolScroll.addSubview(b)
            return b
        }
        symbolScroll.contentOffset = .zero
        symbolPage.setNeedsLayout()
    }

    private func layoutSymbolGrid(rowHeight: CGFloat, gap: CGFloat) {
        let width = symbolScroll.bounds.width
        let long = symbolKeys.contains { ($0.titleLabel.text ?? "").count > 3 }
        let cols: CGFloat = long ? 3 : 6
        let w = floor((width - gap * (cols - 1)) / cols)
        for (i, k) in symbolKeys.enumerated() {
            let r = CGFloat(i / Int(cols)), c = CGFloat(i % Int(cols))
            k.frame = CGRect(x: c * (w + gap), y: r * (rowHeight + gap), width: w, height: rowHeight)
        }
        let rows = ceil(CGFloat(symbolKeys.count) / cols)
        symbolScroll.contentSize = CGSize(width: width, height: max(0, rows * (rowHeight + gap) - gap))
    }

    private func buildCandidatePanel() {
        keyArea.addSubview(candidatePanel)
        candidatePanel.backgroundColor = KBColor.background
        candidatePanel.isHidden = true
        candidateGrid.onSelect = { [weak self] i in
            guard let self, i < self.candidates.count else { return }
            self.commit(self.candidates[i])
        }
        let back = KeyButton("", icon: "chevron.up", style: .function, iconSize: 18)
        back.addAction(UIAction { [weak self] _ in self?.toggleExpanded() }, for: .touchUpInside)
        let del = makeDeleteKey()
        let clear = makeKey("重输", style: .function, size: 16) { [weak self] in self?.clearCompose() }
        let grid = candidateGrid
        [grid, back, del, clear].forEach { candidatePanel.addSubview($0) }
        candidatePanel.layout = { v in
            let m = KeyMetrics(v.bounds)
            grid.frame = CGRect(x: m.inset, y: 0, width: m.rightX - m.gap - m.inset, height: v.bounds.height - 4)
            let h = floor((v.bounds.height - 4 - m.gap * 2) / 3)
            for (i, k) in [back, del, clear].enumerated() {
                k.frame = CGRect(x: m.rightX, y: CGFloat(i) * (h + m.gap), width: m.rightW, height: h)
            }
        }
    }

    private func buildClipboardPanel() {
        keyArea.addSubview(clipboardPanel)
        clipboardPanel.backgroundColor = KBColor.background
        clipboardPanel.isHidden = true
        let title = UILabel()
        title.text = "剪贴板"
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .label
        let clear = makeKey("清空", style: .function, size: 14) { [weak self] in
            KeyboardSettings.clipboardHistory = []
            self?.reloadClipboardRows()
        }
        let close = makeKey("关闭", style: .function, size: 14) { [weak self] in self?.hidePanels() }
        clipScroll.alwaysBounceVertical = true
        [title, clear, close, clipScroll].forEach { clipboardPanel.addSubview($0) }
        clipboardPanel.layout = { [weak self] v in
            guard let self else { return }
            let w = v.bounds.width
            title.frame = CGRect(x: 12, y: 0, width: 120, height: 32)
            close.frame = CGRect(x: w - 4 - 60, y: 2, width: 60, height: 28)
            clear.frame = CGRect(x: w - 4 - 60 - 8 - 60, y: 2, width: 60, height: 28)
            self.clipScroll.frame = CGRect(x: 4, y: 38, width: w - 8, height: v.bounds.height - 42)
            var y: CGFloat = 0
            for row in self.clipRows {
                let h: CGFloat = row is KeyButton ? 48 : 60
                row.frame = CGRect(x: 0, y: y, width: w - 8, height: h)
                y += h + 6
            }
            self.clipScroll.contentSize = CGSize(width: w - 8, height: y)
        }
    }

    private func buildSettingsPanel() {
        keyArea.addSubview(settingsPanel)
        settingsPanel.backgroundColor = KBColor.background
        settingsPanel.isHidden = true
        let title = UILabel()
        title.text = "键盘设置"
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .label
        let done = makeKey("完成", style: .accent, size: 14) { [weak self] in self?.hidePanels() }
        func label(_ text: String) -> UILabel {
            let l = UILabel()
            l.text = text
            l.font = .systemFont(ofSize: 15)
            l.textColor = .label
            l.adjustsFontSizeToFitWidth = true
            l.minimumScaleFactor = 0.7
            return l
        }
        let layoutLabel = label("中文键盘布局")
        let hapticLabel = label("按键震动")
        let prewarmLabel = label("麦克风预热（会一直占用麦克风）")
        let onDeviceLabel = label("离线识别优先（更快，不可用时自动联网）")
        let inlineLabel = label("语音上屏兼容模式（逐段替换）")
        let heightLabel = label("键盘高度")
        heightSlider.minimumValue = Float(KeyboardSettings.heightScaleRange.lowerBound)
        heightSlider.maximumValue = Float(KeyboardSettings.heightScaleRange.upperBound)
        heightSlider.isContinuous = true
        heightSlider.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            // Live preview: the keyboard resizes while dragging; saved on every change.
            self.setHeightScale(Double(self.heightSlider.value), save: true)
        }, for: .valueChanged)
        heightValueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        heightValueLabel.textColor = .secondaryLabel
        heightValueLabel.textAlignment = .center
        heightValueLabel.adjustsFontSizeToFitWidth = true
        let heightReset = makeKey("默认", style: .function, size: 13) { [weak self] in
            self?.setHeightScale(1.0, save: true)
        }
        let heightControl = UIView()
        [heightSlider, heightValueLabel, heightReset].forEach { heightControl.addSubview($0) }
        let slider = heightSlider, valueLabel = heightValueLabel
        inlineCompatSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            KeyboardSettings.inlineCompat = self.inlineCompatSwitch.isOn
        }, for: .valueChanged)
        layoutSegment.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let kind: ChineseLayout = self.layoutSegment.selectedSegmentIndex == 0 ? .t9 : .qwerty
            KeyboardSettings.layout = kind
            self.applySettings()
        }, for: .valueChanged)
        hapticSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            KeyboardSettings.haptics = self.hapticSwitch.isOn
            self.hapticsOn = self.hapticSwitch.isOn
        }, for: .valueChanged)
        prewarmSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            KeyboardSettings.micPrewarm = self.prewarmSwitch.isOn
            self.dictation.prewarm(hasFullAccess: self.hasFullAccess, micWarm: self.prewarmSwitch.isOn, onDevice: KeyboardSettings.onDeviceRecognition)
        }, for: .valueChanged)
        onDeviceSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            KeyboardSettings.onDeviceRecognition = self.onDeviceSwitch.isOn
            self.dictation.prewarm(hasFullAccess: self.hasFullAccess, micWarm: KeyboardSettings.micPrewarm, onDevice: self.onDeviceSwitch.isOn)
        }, for: .valueChanged)
        let rows: [(UILabel, UIView)] = [
            (heightLabel, heightControl),
            (layoutLabel, layoutSegment), (hapticLabel, hapticSwitch), (prewarmLabel, prewarmSwitch), (onDeviceLabel, onDeviceSwitch),
            (inlineLabel, inlineCompatSwitch),
        ]
        // Rows scroll, so the panel works at every keyboard height.
        let scroll = TouchScrollView()
        scroll.alwaysBounceVertical = true
        ([title, done, scroll] as [UIView]).forEach { settingsPanel.addSubview($0) }
        for (l, c) in rows {
            scroll.addSubview(l)
            scroll.addSubview(c)
        }
        settingsPanel.layout = { v in
            let w = v.bounds.width
            title.frame = CGRect(x: 12, y: 0, width: 160, height: 32)
            done.frame = CGRect(x: w - 4 - 60, y: 2, width: 60, height: 28)
            scroll.frame = CGRect(x: 0, y: 36, width: w, height: max(0, v.bounds.height - 36))
            let rowH = max(40, floor(scroll.bounds.height / CGFloat(rows.count)))
            for (i, (l, c)) in rows.enumerated() {
                let y = CGFloat(i) * rowH
                if c === heightControl {
                    l.frame = CGRect(x: 14, y: y, width: 64, height: rowH)
                    let cx: CGFloat = 80
                    c.frame = CGRect(x: cx, y: y, width: w - 12 - cx, height: rowH)
                    let cw = c.bounds.width
                    heightReset.frame = CGRect(x: cw - 50, y: (rowH - 28) / 2, width: 50, height: 28)
                    valueLabel.frame = CGRect(x: cw - 50 - 6 - 70, y: 0, width: 70, height: rowH)
                    slider.frame = CGRect(x: 0, y: (rowH - 31) / 2, width: max(60, cw - 50 - 6 - 70 - 6), height: 31)
                    continue
                }
                let cw: CGFloat = c is UISegmentedControl ? 150 : 51
                let ch: CGFloat = c is UISegmentedControl ? 30 : 31
                c.frame = CGRect(x: w - 12 - cw, y: y + (rowH - ch) / 2, width: cw, height: ch)
                l.frame = CGRect(x: 14, y: y, width: w - 40 - cw, height: rowH)
            }
            scroll.contentSize = CGSize(width: w, height: rowH * CGFloat(rows.count))
        }
    }

    private func showPage(_ newPage: Page) {
        if newPage != .main { commitAll() }
        hidePanels()
        page = newPage
        t9Page.isHidden = !(page == .main && isT9)
        qwertyPage.isHidden = !(page == .main && !isT9)
        numberPage.isHidden = page != .number
        symbolPage.isHidden = page != .symbols
        if page == .symbols, lang == .english, symbolTab == 0 { selectSymbolTab(1) }
        updateLetterKeys()
        updateLangKeys()
        updateReturnKeys()
        refresh()
    }

    private func hidePanels() {
        clipboardPanel.isHidden = true
        settingsPanel.isHidden = true
        candidatesExpanded = false
        candidatePanel.isHidden = true
        candidateBar.expandButton.setIcon("chevron.down", size: 16)
    }

    private func updateGlobeKeys() {
        let needed = needsInputModeSwitchKey
        for g in globeKeys { g.isHidden = !needed }
        [t9Page, qwertyPage].forEach { $0.setNeedsLayout() }
    }

    // MARK: - Key label updates

    private func updateLetterKeys() {
        let upper = lang == .english && shift != .off
        for (ch, b) in letterKeys {
            b.setTitle(upper ? String(ch).uppercased() : String(ch))
        }
        if lang == .chinese {
            shiftKey.setIcon(nil)
            shiftKey.setTitle("分词")
            shiftKey.isSelectedState = false
        } else {
            shiftKey.setTitle("")
            switch shift {
            case .off: shiftKey.setIcon("shift", size: 18)
            case .once: shiftKey.setIcon("shift.fill", size: 18)
            case .locked: shiftKey.setIcon("capslock.fill", size: 18)
            }
            shiftKey.isSelectedState = shift != .off
        }
        qwertyPunctKey.setTitle(lang == .english ? "," : "，")
    }

    private func updateLangKeys() {
        let zh = lang == .chinese
        let s = NSMutableAttributedString(string: "中", attributes: [
            .font: UIFont.systemFont(ofSize: zh ? 17 : 12, weight: zh ? .semibold : .regular),
            .foregroundColor: zh ? UIColor.label : UIColor.secondaryLabel,
        ])
        s.append(NSAttributedString(string: "/", attributes: [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.secondaryLabel]))
        s.append(NSAttributedString(string: "英", attributes: [
            .font: UIFont.systemFont(ofSize: zh ? 12 : 17, weight: zh ? .regular : .semibold),
            .foregroundColor: zh ? UIColor.secondaryLabel : UIColor.label,
        ]))
        for k in langKeys {
            k.titleLabel.attributedText = s
            k.setNeedsLayout()
        }
    }

    private func returnTitle() -> (String, Bool) {
        if !compose.isEmpty { return ("确认", false) }
        switch textDocumentProxy.returnKeyType ?? .default {
        case .send: return ("发送", true)
        case .search, .google, .yahoo: return ("搜索", true)
        case .go, .route: return ("前往", true)
        case .done: return ("完成", true)
        case .next: return ("下一项", true)
        case .join: return ("加入", true)
        case .emergencyCall: return ("紧急呼叫", true)
        default: return ("换行", false)
        }
    }

    private func updateReturnKeys() {
        let (title, accent) = returnTitle()
        for k in returnKeys {
            k.setTitle(title)
            k.style = accent ? .accent : .function
        }
    }

    // MARK: - Composition

    private func refresh() {
        if compose.isEmpty {
            candidates = []
            pinyinOptions = []
            pinyinFilter = nil
            if candidatesExpanded { hidePanels() }
        } else if engine.isLoaded {
            candidates = engine.candidates(input: compose, fullPinyin: isFullPinyin, pinyinFilter: isT9 ? pinyinFilter : nil)
            pinyinOptions = isT9 ? engine.pinyinOptions(input: compose) : []
        }
        candidateBar.compositionLabel.text = compositionText()
        candidateBar.setCandidates(candidates.prefix(60).map(\.text))
        if candidatesExpanded { candidateGrid.setItems(candidates.map(\.text)) }
        if isT9 {
            if compose.isEmpty {
                if sideShowsPinyin || t9SideNeedsInit {
                    t9SideNeedsInit = false
                    sideShowsPinyin = false
                    t9Side.setItems(SymbolData.quickChinese)
                }
            } else {
                sideShowsPinyin = true
                t9Side.setItems(pinyinOptions, selected: pinyinFilter.flatMap { pinyinOptions.firstIndex(of: $0) })
            }
        }
        updateTopBar()
        updateReturnKeys()
    }

    private var t9SideNeedsInit = true

    private func compositionText() -> String {
        guard !compose.isEmpty else { return "" }
        let keyCount = T9Engine.keyCount(compose)
        if isT9 {
            let base = pinyinFilter ?? pinyinOptions.first ?? ""
            let used = base.filter { $0 != "'" }.count
            let digits = compose.filter { $0 != "'" }
            if used < keyCount {
                let rest = String(digits.dropFirst(used).compactMap { T9Engine.letters[$0]?.first })
                return base.isEmpty ? rest : base + "'" + rest
            }
            return base
        }
        if let c = candidates.first {
            if c.consumed >= keyCount { return c.pinyin }
            return c.pinyin + "'" + T9Engine.drop(keys: c.consumed, from: compose)
        }
        return compose
    }

    private func sideSelected(_ i: Int) {
        if sideShowsPinyin {
            guard i < pinyinOptions.count else { return }
            let option = pinyinOptions[i]
            pinyinFilter = pinyinFilter == option ? nil : option
            refresh()
        } else if i < SymbolData.quickChinese.count {
            insertPunctuation(SymbolData.quickChinese[i])
        }
    }

    private func tapT9(_ digit: Character) {
        guard T9Engine.keyCount(compose) < 30 else { return }
        compose.append(digit)
        pinyinFilter = nil
        refresh()
    }

    private func tapT9Separator() {
        if compose.isEmpty {
            insertPunctuation("、")
        } else if compose.last != "'" {
            compose.append("'")
            refresh()
        }
    }

    private func tapLetter(_ letter: Character) {
        if lang == .english {
            textDocumentProxy.insertText(shift != .off ? String(letter).uppercased() : String(letter))
            if shift == .once {
                shift = .off
                updateLetterKeys()
            }
            return
        }
        guard T9Engine.keyCount(compose) < 40 else { return }
        compose.append(letter)
        refresh()
    }

    private func tapShift() {
        if lang == .chinese {
            if !compose.isEmpty, compose.last != "'" {
                compose.append("'")
                refresh()
            }
            return
        }
        let now = Date()
        switch shift {
        case .off: shift = .once
        case .once: shift = now.timeIntervalSince(lastShiftTap) < 0.35 ? .locked : .off
        case .locked: shift = .off
        }
        lastShiftTap = now
        updateLetterKeys()
    }

    private func deleteOnce() {
        if !compose.isEmpty {
            compose.removeLast()
            pinyinFilter = nil
            refresh()
        } else {
            textDocumentProxy.deleteBackward()
        }
    }

    private func deleteDown() {
        deleteWasComposing = !compose.isEmpty
        deleteCount = 0
        deleteOnce()
        deleteTimer?.invalidate()
        let timer = Timer(timeInterval: 0.45, target: self, selector: #selector(deleteRepeatStart), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        deleteTimer = timer
    }

    @objc private func deleteRepeatStart() {
        let timer = Timer(timeInterval: 0.07, target: self, selector: #selector(deleteRepeatTick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        deleteTimer = timer
        deleteRepeatTick()
    }

    @objc private func deleteRepeatTick() {
        if deleteWasComposing, compose.isEmpty {
            deleteUp()
            return
        }
        deleteCount += 1
        deleteOnce()
        if deleteCount % 3 == 0 { tick() }
    }

    private func deleteUp() {
        deleteTimer?.invalidate()
        deleteTimer = nil
    }

    private func clearCompose() {
        compose = ""
        pinyinFilter = nil
        refresh()
    }

    private func commit(_ candidate: T9Candidate) {
        textDocumentProxy.insertText(candidate.text)
        compose = T9Engine.drop(keys: candidate.consumed, from: compose)
        pinyinFilter = nil
        refresh()
    }

    /// Commits the raw letters of the composition (回车 while composing).
    private func commitRaw() {
        let text: String
        if isT9 {
            let spelled = compositionText()
            text = spelled.replacingOccurrences(of: "'", with: "")
        } else {
            text = compose.replacingOccurrences(of: "'", with: "")
        }
        textDocumentProxy.insertText(text)
        clearCompose()
    }

    /// Commits the best candidates for the whole composition.
    private func commitAll() {
        var guardCount = 0
        while !compose.isEmpty, guardCount < 12 {
            guardCount += 1
            if let first = candidates.first { commit(first) } else { commitRaw() }
        }
    }

    private func insertPunctuation(_ s: String) {
        commitAll()
        textDocumentProxy.insertText(s)
    }

    private func insertSymbolText(_ s: String) {
        textDocumentProxy.insertText(s)
    }

    private func tapSpace() {
        if !compose.isEmpty {
            if let first = candidates.first { commit(first) } else { commitRaw() }
            return
        }
        let now = Date()
        if lang == .english, now.timeIntervalSince(lastSpaceTap) < 0.35,
           let before = textDocumentProxy.documentContextBeforeInput, before.hasSuffix(" "),
           let prev = before.dropLast().last, prev.isLetter || prev.isNumber {
            textDocumentProxy.deleteBackward()
            textDocumentProxy.insertText(". ")
            lastSpaceTap = .distantPast
            return
        }
        lastSpaceTap = now
        textDocumentProxy.insertText(" ")
    }

    private func tapReturn() {
        if !compose.isEmpty {
            commitRaw()
            return
        }
        textDocumentProxy.insertText("\n")
    }

    private func toggleLang() {
        if !compose.isEmpty { commitRaw() }
        lang = lang == .chinese ? .english : .chinese
        shift = .off
        showPage(.main)
    }

    private func toggleLayout() {
        clearCompose()
        KeyboardSettings.layout = layoutKind == .t9 ? .qwerty : .t9
        applySettings()
        lang = .chinese
        showPage(.main)
        showStatus(layoutKind == .t9 ? "已切换到 九键拼音" : "已切换到 全键盘拼音", duration: 1.2)
    }

    private func toggleExpanded() {
        guard !compose.isEmpty || candidatesExpanded else { return }
        candidatesExpanded.toggle()
        candidatePanel.isHidden = !candidatesExpanded
        candidateBar.expandButton.setIcon(candidatesExpanded ? "chevron.up" : "chevron.down", size: 16)
        if candidatesExpanded {
            candidateGrid.setItems(candidates.map(\.text))
            keyArea.bringSubviewToFront(candidatePanel)
        }
    }

    // MARK: - Popups

    private func showPopup(for key: KeyButton) {
        let f = key.convert(key.bounds, to: view)
        let w = f.width + 14
        let h = f.height + 10
        var y = f.minY - h + 4
        if y < 0 { y = 0 }
        popup.text = key.titleLabel.text
        popup.frame = CGRect(x: f.midX - w / 2, y: y, width: w, height: h)
        popup.isHidden = false
        view.bringSubviewToFront(popup)
    }

    private func hidePopup() {
        popup.isHidden = true
    }

    // MARK: - Clipboard & settings panels

    private func toggleClipboard() {
        if !clipboardPanel.isHidden {
            hidePanels()
            return
        }
        hidePanels()
        if hasFullAccess, UIPasteboard.general.hasStrings, let s = UIPasteboard.general.string,
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var history = KeyboardSettings.clipboardHistory
            history.removeAll { $0 == s }
            history.insert(s, at: 0)
            KeyboardSettings.clipboardHistory = history
        }
        reloadClipboardRows()
        clipboardPanel.isHidden = false
        keyArea.bringSubviewToFront(clipboardPanel)
    }

    private func reloadClipboardRows() {
        clipRows.forEach { $0.removeFromSuperview() }
        let history = KeyboardSettings.clipboardHistory
        if history.isEmpty {
            let empty = UILabel()
            empty.numberOfLines = 0
            empty.textAlignment = .center
            empty.font = .systemFont(ofSize: 14)
            empty.textColor = .secondaryLabel
            empty.text = hasFullAccess ? "暂无内容。复制文字后打开这里，点一下即可粘贴。" : "需在系统设置中为本键盘开启「允许完全访问」才能读取剪贴板。"
            clipRows = [empty]
        } else {
            clipRows = history.map { s in
                let preview = s.replacingOccurrences(of: "\n", with: " ")
                let b = makeKey(preview, size: 15) { [weak self] in
                    self?.commitAll()
                    self?.textDocumentProxy.insertText(s)
                    self?.hidePanels()
                }
                b.titleLabel.textAlignment = .left
                b.titleLabel.numberOfLines = 2
                b.titleLabel.adjustsFontSizeToFitWidth = false
                b.titleLabel.lineBreakMode = .byTruncatingTail
                b.titleInset = 12
                return b
            }
        }
        clipRows.forEach { clipScroll.addSubview($0) }
        clipScroll.contentOffset = .zero
        clipboardPanel.setNeedsLayout()
    }

    private func toggleSettings() {
        let wasHidden = settingsPanel.isHidden
        hidePanels()
        guard wasHidden else { return }
        applySettings()
        settingsPanel.isHidden = false
        keyArea.bringSubviewToFront(settingsPanel)
    }

    // MARK: - Voice

    private func spaceDown() {
        spaceHoldFired = false
        cancelArmed = false
        spaceTimer?.invalidate()
        // Microphone + recognizer start right now, before the hold is confirmed, so the first
        // syllable is captured. Nothing is shown or inserted until the hold threshold passes.
        startSpeculativeVoice()
        let timer = Timer(timeInterval: KeyboardSettings.holdDelay, target: self, selector: #selector(spaceHoldFire), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        spaceTimer = timer
    }

    private func startSpeculativeVoice() {
        guard voiceTrigger == .none,
              dictation.permissionProblem(hasFullAccess: hasFullAccess) == nil,
              dictation.capture.isReady else { return }
        inlineText = ""
        inlineMarked = false
        speculativeText = ""
        inlineCompatMode = KeyboardSettings.inlineCompat
        voiceTrigger = .spaceSpeculative
        if !dictation.begin(), voiceTrigger == .spaceSpeculative { voiceTrigger = .none }
    }

    /// Short tap: stop the speculative capture at once (mic freed, no text).
    private func cancelSpeculativeVoice() {
        guard voiceTrigger == .spaceSpeculative else { return }
        voiceTrigger = .none
        speculativeText = ""
        dictation.cancel()
        updateTopBar()
    }

    @objc private func spaceHoldFire() {
        spaceTimer = nil
        if voiceTrigger == .spaceSpeculative, dictation.isActive {
            spaceHoldFired = true
            confirmSpeculativeVoice()
            return
        }
        if voiceTrigger == .spaceSpeculative { voiceTrigger = .none }
        guard voiceTrigger == .none else { return }
        spaceHoldFired = true
        commitAll()
        // Text recognized by a speculative run that ended early is kept.
        if !speculativeText.isEmpty { textDocumentProxy.insertText(speculativeText) }
        speculativeText = ""
        startVoice(.spaceHold)
    }

    /// The hold passed the threshold: the running capture becomes a normal hold-to-talk dictation.
    private func confirmSpeculativeVoice() {
        commitAll()
        hidePopup()
        hidePanels()
        voiceTrigger = .spaceHold
        if hapticsOn {
            startHaptic.impactOccurred()
            startHaptic.prepare()
        }
        waveBar.start()
        updateTopBar()
        if !speculativeText.isEmpty { setInline(speculativeText) }
        speculativeText = ""
    }

    private func spaceUp(inside: Bool) {
        if let timer = spaceTimer {
            timer.invalidate()
            spaceTimer = nil
            // Released before the threshold: free the microphone first, then a normal space.
            cancelSpeculativeVoice()
            if inside { tapSpace() }
            return
        }
        guard spaceHoldFired else { return }
        spaceHoldFired = false
        if voiceTrigger == .spaceHold {
            cancelArmed ? cancelVoice() : stopVoice()
        }
    }

    private func spaceTracked(_ y: CGFloat) {
        guard voiceTrigger == .spaceHold else { return }
        let armed = y < -60
        if armed != cancelArmed {
            cancelArmed = armed
            waveBar.setArmed(armed)
            if armed { tick() }
        }
    }

    private func micDown() {
        if voiceTrigger == .micToggle {
            ignoreMicUp = true
            stopVoice()
            return
        }
        guard voiceTrigger == .none else { return }
        ignoreMicUp = false
        micDownAt = Date()
        cancelArmed = false
        commitAll()
        startVoice(.micHold)
    }

    private func micUp() {
        if ignoreMicUp {
            ignoreMicUp = false
            return
        }
        guard voiceTrigger == .micHold else { return }
        if Date().timeIntervalSince(micDownAt) < 0.35 {
            // Quick tap: keep listening until 完成 / tap.
            voiceTrigger = .micToggle
            waveBar.doneButton.isHidden = false
        } else {
            stopVoice()
        }
    }

    private func startVoice(_ trigger: VoiceTrigger) {
        if let problem = dictation.permissionProblem(hasFullAccess: hasFullAccess) {
            showStatus(problem, duration: 4)
            return
        }
        guard dictation.capture.isReady else {
            showStatus("语音模块加载中，请稍后再试")
            return
        }
        hidePopup()
        hidePanels()
        inlineText = ""
        inlineMarked = false
        inlineCompatMode = KeyboardSettings.inlineCompat
        voiceTrigger = trigger
        if hapticsOn {
            startHaptic.impactOccurred()
            startHaptic.prepare()
        }
        waveBar.start()
        updateTopBar()
        if !dictation.begin() {
            voiceTrigger = .none
            endWaveBar()
        }
    }

    private func endWaveBar() {
        waveBar.stop()
        updateTopBar()
    }

    private func stopVoice() {
        guard voiceTrigger != .none, voiceTrigger != .finishing else { return }
        // Stop at once: commits the current inline partial and restores the bar (no 识别中 wait).
        voiceTrigger = .finishing
        dictation.end()
        if voiceTrigger != .none { voiceFinished(inlineText) }
    }

    private func cancelVoice() {
        guard voiceTrigger != .none else { return }
        voiceTrigger = .none
        removeInline()
        endWaveBar()
        dictation.cancel()
    }

    private func voiceFinished(_ text: String?) {
        let wasActive = voiceTrigger != .none
        voiceTrigger = .none
        cancelArmed = false
        endWaveBar()
        guard let text else {
            removeInline()
            return
        }
        if text.isEmpty {
            removeInline()
            if wasActive { showStatus("没有听清，请再说一次") }
            return
        }
        commitInline(text)
    }

    // MARK: - Live inline dictation text

    /// Shows the in-progress recognition directly in the text field, updating it in place.
    private func setInline(_ text: String) {
        guard text != inlineText else { return }
        if inlineCompatMode {
            replaceInlinePlain(with: text)
        } else {
            textDocumentProxy.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0))
            inlineMarked = true
        }
        inlineText = text
    }

    /// Commits the final text in place of the partial.
    private func commitInline(_ text: String) {
        if inlineCompatMode {
            replaceInlinePlain(with: text)
        } else if inlineMarked {
            if text != inlineText {
                textDocumentProxy.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0))
            }
            textDocumentProxy.unmarkText()
        } else if !text.isEmpty {
            textDocumentProxy.insertText(text)
        }
        inlineText = ""
        inlineMarked = false
    }

    /// Removes the partial text (cancel / nothing recognized).
    private func removeInline() {
        if inlineCompatMode {
            replaceInlinePlain(with: "")
        } else if inlineMarked {
            textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
            textDocumentProxy.unmarkText()
        }
        inlineText = ""
        inlineMarked = false
    }

    /// Fallback: delete only the part of the previous partial that changed, then insert the rest.
    private func replaceInlinePlain(with text: String) {
        let old = Array(inlineText), new = Array(text)
        var common = 0
        while common < old.count, common < new.count, old[common] == new[common] { common += 1 }
        for _ in 0..<(old.count - common) { textDocumentProxy.deleteBackward() }
        if common < new.count { textDocumentProxy.insertText(String(new[common...])) }
        inlineText = text
    }
}
