import UIKit

// MARK: - Colors (light / dark)

enum KBColor {
    static func dyn(_ light: UIColor, _ dark: UIColor) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }

    static let background = dyn(UIColor(red: 0.82, green: 0.835, blue: 0.86, alpha: 1), UIColor(white: 0.11, alpha: 1))
    static let charKey = dyn(.white, UIColor(white: 0.36, alpha: 1))
    static let charKeyHighlighted = dyn(UIColor(red: 0.69, green: 0.71, blue: 0.75, alpha: 1), UIColor(white: 0.22, alpha: 1))
    static let functionKey = dyn(UIColor(red: 0.67, green: 0.70, blue: 0.74, alpha: 1), UIColor(white: 0.23, alpha: 1))
    static let functionKeyHighlighted = dyn(.white, UIColor(white: 0.40, alpha: 1))
    static let accent = UIColor.systemBlue
    static let accentHighlighted = dyn(UIColor(red: 0.0, green: 0.33, blue: 0.75, alpha: 1), UIColor(red: 0.05, green: 0.38, blue: 0.85, alpha: 1))
    static let plainHighlighted = dyn(UIColor(white: 0, alpha: 0.08), UIColor(white: 1, alpha: 0.12))
    static let separator = dyn(UIColor(white: 0, alpha: 0.12), UIColor(white: 1, alpha: 0.14))
    static let popup = dyn(.white, UIColor(white: 0.42, alpha: 1))
}

// MARK: - Key metrics

@MainActor
struct KeyMetrics {
    let inset: CGFloat = 4
    let gap: CGFloat = 6
    let width: CGFloat
    let rowH: CGFloat
    let side: CGFloat
    let key: CGFloat

    init(_ bounds: CGRect) {
        width = bounds.width
        rowH = max(20, floor((bounds.height - gap * 3 - 4) / 4))
        let avail = bounds.width - inset * 2 - gap * 4
        side = floor(avail * 0.18)
        key = floor((avail - side * 2) / 3)
    }

    func y(_ row: Int) -> CGFloat { CGFloat(row) * (rowH + gap) }
    func centerX(_ col: Int) -> CGFloat { inset + side + gap + CGFloat(col) * (key + gap) }
    var rightX: CGFloat { centerX(3) }
    var rightW: CGFloat { width - inset - rightX }
    var centerSpan: CGFloat { key * 3 + gap * 2 }
    var threeRows: CGFloat { rowH * 3 + gap * 2 }

    /// Lays views out left to right. A width of 0 means "share the remaining space".
    func distribute(_ items: [(UIView, CGFloat)], x: CGFloat, width total: CGFloat, y: CGFloat, height: CGFloat? = nil) {
        let visible = items.filter { !$0.0.isHidden }
        guard !visible.isEmpty else { return }
        let fixed = visible.reduce(CGFloat(0)) { $0 + $1.1 }
        let flexCount = CGFloat(visible.filter { $0.1 == 0 }.count)
        let flex = flexCount > 0 ? max(10, (total - fixed - gap * CGFloat(visible.count - 1)) / flexCount) : 0
        var cx = x
        for (v, w) in visible {
            let width = w == 0 ? flex : w
            v.frame = CGRect(x: cx, y: y, width: width, height: height ?? rowH)
            cx += width + gap
        }
    }
}

// MARK: - Key button

final class KeyButton: UIControl {
    enum Style { case char, function, accent, plain }

    /// Called on every touch-down (haptics).
    static var onPress: (() -> Void)?

    let titleLabel = UILabel()
    let subLabel = UILabel()
    let iconView = UIImageView()
    var style: Style { didSet { refreshColors() } }
    var isSelectedState = false { didSet { refreshColors() } }
    /// Keep the colors given in `titleLabel.attributedText`.
    var keepsTitleColors = false
    var titleInset: CGFloat = 3
    var onTrack: ((UITouch) -> Void)?
    var hitInset: CGFloat = 3

    init(_ title: String = "", sub: String? = nil, icon: String? = nil, style: Style = .char, fontSize: CGFloat = 18, iconSize: CGFloat = 17) {
        self.style = style
        super.init(frame: .zero)
        isExclusiveTouch = false
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: fontSize)
        titleLabel.textAlignment = .center
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.5
        subLabel.text = sub
        subLabel.font = .systemFont(ofSize: 10)
        subLabel.textAlignment = .center
        iconView.contentMode = .center
        if let icon {
            iconView.image = UIImage(systemName: icon, withConfiguration: UIImage.SymbolConfiguration(pointSize: iconSize, weight: .regular))
        }
        for v in [titleLabel, subLabel, iconView] as [UIView] {
            v.isUserInteractionEnabled = false
            addSubview(v)
        }
        layer.cornerRadius = 5
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowRadius = 0
        refreshColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setTitle(_ title: String) {
        titleLabel.text = title
        setNeedsLayout()
    }

    func setIcon(_ name: String?, size: CGFloat = 17) {
        iconView.image = name.flatMap {
            UIImage(systemName: $0, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .regular))
        }
        setNeedsLayout()
    }

    override var isHighlighted: Bool { didSet { refreshColors() } }

    func refreshColors() {
        let hl = isHighlighted
        switch style {
        case .char: backgroundColor = hl ? KBColor.charKeyHighlighted : KBColor.charKey
        case .function: backgroundColor = (hl || isSelectedState) ? KBColor.functionKeyHighlighted : KBColor.functionKey
        case .accent: backgroundColor = hl ? KBColor.accentHighlighted : KBColor.accent
        case .plain: backgroundColor = hl ? KBColor.plainHighlighted : .clear
        }
        let fg: UIColor
        switch style {
        case .accent: fg = .white
        case .plain: fg = isSelectedState ? .systemBlue : .label
        default: fg = .label
        }
        if !keepsTitleColors { titleLabel.textColor = fg }
        iconView.tintColor = fg
        subLabel.textColor = style == .accent ? UIColor.white.withAlphaComponent(0.8) : .secondaryLabel
        layer.shadowOpacity = style == .plain ? 0 : (traitCollection.userInterfaceStyle == .dark ? 0.5 : 0.28)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        refreshColors()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let b = bounds
        let hasTitle = !(titleLabel.text ?? "").isEmpty || (titleLabel.attributedText?.length ?? 0) > 0
        let hasIcon = iconView.image != nil
        let hasSub = !(subLabel.text ?? "").isEmpty
        if hasIcon && hasTitle {
            let iw: CGFloat = 18
            let tw = min(titleLabel.intrinsicContentSize.width, max(0, b.width - iw - 10))
            let x0 = (b.width - iw - 3 - tw) / 2
            iconView.frame = CGRect(x: x0, y: 0, width: iw, height: b.height)
            titleLabel.frame = CGRect(x: x0 + iw + 3, y: 0, width: tw, height: b.height)
        } else {
            iconView.frame = b
            titleLabel.frame = b.insetBy(dx: titleInset, dy: 0)
        }
        if hasSub {
            subLabel.frame = CGRect(x: 0, y: 3, width: b.width, height: 12)
            titleLabel.frame = CGRect(x: titleInset, y: 7, width: b.width - titleInset * 2, height: b.height - 7)
        } else {
            subLabel.frame = .zero
        }
        if style != .plain {
            layer.shadowPath = UIBezierPath(roundedRect: b, cornerRadius: layer.cornerRadius).cgPath
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -hitInset, dy: -hitInset).contains(point)
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        KeyButton.onPress?()
        return super.beginTracking(touch, with: event)
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        onTrack?(touch)
        return super.continueTracking(touch, with: event)
    }
}

// MARK: - Containers

/// Scroll view whose buttons highlight immediately and still let the user scroll.
final class TouchScrollView: UIScrollView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        delaysContentTouches = false
        canCancelContentTouches = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        alwaysBounceVertical = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func touchesShouldCancel(in view: UIView) -> Bool { !(view is UISlider) }
}

/// A view that lays out its children with a closure.
final class PageView: UIView {
    var layout: ((PageView) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layout?(self)
    }
}

/// Vertical scrollable list (Baidu's left column: punctuation or pinyin choices).
final class SideListView: UIView {
    private let scroll = TouchScrollView()
    private var buttons: [KeyButton] = []
    var onSelect: ((Int) -> Void)?
    var visibleRows: CGFloat = 4

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = KBColor.functionKey
        layer.cornerRadius = 5
        clipsToBounds = true
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setItems(_ items: [String], selected: Int? = nil) {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = items.enumerated().map { i, s in
            let b = KeyButton(s, style: .plain, fontSize: s.count > 3 ? 14 : 17)
            b.layer.cornerRadius = 0
            b.hitInset = 0
            b.isSelectedState = i == selected
            b.addAction(UIAction { [weak self] _ in self?.onSelect?(i) }, for: .touchUpInside)
            scroll.addSubview(b)
            return b
        }
        scroll.contentOffset = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
        let h = floor(bounds.height / visibleRows)
        for (i, b) in buttons.enumerated() {
            b.frame = CGRect(x: 0, y: CGFloat(i) * h, width: bounds.width, height: h)
        }
        scroll.contentSize = CGSize(width: bounds.width, height: CGFloat(buttons.count) * h)
    }
}

// MARK: - Candidates

private func textWidth(_ s: String, size: CGFloat) -> CGFloat {
    ceil((s as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: size)]).width)
}

/// Top bar while composing: pinyin composition above a horizontal candidate strip and a ⌄ button.
final class CandidateBarView: UIView {
    let compositionLabel = UILabel()
    let scroll = TouchScrollView()
    let expandButton = KeyButton("", icon: "chevron.down", style: .plain, iconSize: 16)
    private let divider = UIView()
    private var buttons: [KeyButton] = []
    var onSelect: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        compositionLabel.font = .systemFont(ofSize: 13)
        compositionLabel.textColor = .secondaryLabel
        divider.backgroundColor = KBColor.separator
        scroll.alwaysBounceHorizontal = true
        for v in [compositionLabel, scroll, divider, expandButton] as [UIView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setCandidates(_ items: [String]) {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = items.enumerated().map { i, s in
            let b = KeyButton(s, style: .plain, fontSize: 19)
            b.titleLabel.adjustsFontSizeToFitWidth = false
            b.isSelectedState = i == 0
            b.addAction(UIAction { [weak self] _ in self?.onSelect?(i) }, for: .touchUpInside)
            scroll.addSubview(b)
            return b
        }
        scroll.contentOffset = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width, h = bounds.height
        compositionLabel.frame = CGRect(x: 10, y: 1, width: w - 60, height: 15)
        expandButton.frame = CGRect(x: w - 44, y: 14, width: 44, height: h - 14)
        divider.frame = CGRect(x: w - 44, y: 20, width: 0.5, height: h - 26)
        scroll.frame = CGRect(x: 0, y: 14, width: w - 44, height: h - 14)
        var x: CGFloat = 4
        for b in buttons {
            let bw = max(36, textWidth(b.titleLabel.text ?? "", size: 19) + 20)
            b.frame = CGRect(x: x, y: 0, width: bw, height: scroll.bounds.height)
            x += bw
        }
        scroll.contentSize = CGSize(width: x + 4, height: scroll.bounds.height)
    }
}

/// Expanded candidate grid (Baidu's ⌄ panel).
final class CandidateGridView: UIView {
    private let scroll = TouchScrollView()
    private var buttons: [KeyButton] = []
    var onSelect: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.alwaysBounceVertical = true
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setItems(_ items: [String]) {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = items.enumerated().map { i, s in
            let b = KeyButton(s, style: .plain, fontSize: 19)
            b.titleLabel.adjustsFontSizeToFitWidth = false
            b.layer.cornerRadius = 0
            b.hitInset = 0
            b.isSelectedState = i == 0
            b.addAction(UIAction { [weak self] _ in self?.onSelect?(i) }, for: .touchUpInside)
            scroll.addSubview(b)
            return b
        }
        scroll.contentOffset = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
        let width = bounds.width
        let unit = max(48, floor(width / 5))
        let rowH: CGFloat = 46
        var x: CGFloat = 0, y: CGFloat = 0
        let line = KBColor.separator.resolvedColor(with: traitCollection).cgColor
        for b in buttons {
            let tw = textWidth(b.titleLabel.text ?? "", size: 19) + 20
            let w = min(width, max(unit, ceil(tw / unit) * unit))
            if x + w > width + 0.5 { x = 0; y += rowH }
            b.frame = CGRect(x: x, y: y, width: w, height: rowH)
            b.layer.borderWidth = 0.5
            b.layer.borderColor = line
            x += w
        }
        scroll.contentSize = CGSize(width: width, height: y + rowH)
    }
}

// MARK: - Voice wave bar

/// Replaces the toolbar / candidate bar while dictating: 3 layered sine waves flowing across the
/// full width, amplitude driven by the live microphone level.
final class WaveBarView: UIView {
    private let waves: [CAShapeLayer] = (0..<3).map { _ in CAShapeLayer() }
    private var link: CADisplayLink?
    private var phase: CGFloat = 0
    private var target: CGFloat = 0
    private var level: CGFloat = 0
    private var tint: UIColor = .systemBlue
    /// Small 完成 pill shown in tap-to-talk mode.
    let doneButton = KeyButton("完成", style: .accent, fontSize: 14)
    var onTap: (() -> Void)?

    private let specs: [(freq: CGFloat, speed: CGFloat, amp: CGFloat, alpha: CGFloat, width: CGFloat)] = [
        (1.6, 0.11, 1.0, 0.95, 2.2),
        (2.3, -0.08, 0.7, 0.55, 1.6),
        (1.1, 0.06, 0.5, 0.35, 1.2),
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        for w in waves {
            w.fillColor = UIColor.clear.cgColor
            w.lineCap = .round
            w.lineJoin = .round
            layer.addSublayer(w)
        }
        doneButton.isHidden = true
        addSubview(doneButton)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        applyTint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func tapped() { onTap?() }

    func start() {
        level = 0
        target = 0
        setArmed(false)
        if link == nil {
            let l = CADisplayLink(target: self, selector: #selector(step))
            l.add(to: .main, forMode: .common)
            link = l
        }
        isHidden = false
        redraw()
    }

    func stop() {
        link?.invalidate()
        link = nil
        isHidden = true
        doneButton.isHidden = true
    }

    /// rms is ~0...0.1 for speech.
    func setLevel(_ rms: Float) {
        target = min(1, CGFloat(rms) * 14)
    }

    func setQuiet() { target = 0 }

    func setArmed(_ armed: Bool) {
        tint = armed ? .systemRed : .systemBlue
        applyTint()
    }

    private func applyTint() {
        for (i, w) in waves.enumerated() {
            w.strokeColor = tint.withAlphaComponent(specs[i].alpha).cgColor
            w.lineWidth = specs[i].width
        }
    }

    @objc private func step() {
        // Fast attack, slower release.
        level += (target - level) * (target > level ? 0.35 : 0.08)
        target *= 0.97
        phase += 1
        redraw()
    }

    private func redraw() {
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0 else { return }
        let mid = h / 2
        let maxAmp = h / 2 - 3
        let amp = maxAmp * (0.10 + 0.90 * level)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, wave) in waves.enumerated() {
            let spec = specs[i]
            let path = UIBezierPath()
            let steps = max(24, Int(w / 4))
            for s in 0...steps {
                let x = w * CGFloat(s) / CGFloat(steps)
                let t = x / w
                // Taper at both ends so the line flows into the edges.
                let envelope = sin(t * .pi)
                let y = mid + sin(t * .pi * 2 * spec.freq + phase * spec.speed + CGFloat(i)) * amp * spec.amp * envelope
                if s == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            wave.frame = bounds
            wave.path = path.cgPath
        }
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        doneButton.frame = CGRect(x: bounds.width - 66, y: (bounds.height - 30) / 2, width: 58, height: 30)
        doneButton.layer.cornerRadius = 15
        redraw()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyTint()
    }
}
