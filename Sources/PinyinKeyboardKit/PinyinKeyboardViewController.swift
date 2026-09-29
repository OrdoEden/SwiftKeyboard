#if canImport(UIKit)
import UIKit

/// 外观与交互对齐 iOS 系统中文键盘的全拼输入法：常驻候选条 + 26 键键盘。
///
/// 用法：键盘扩展的主控制器继承本类，按需覆写
/// - `suggestions()`：没有拼写时候选条上显示的建议（对应系统英文键盘的三条预测）；
/// - `didSelectSuggestion(_:)`：点击建议后的处理，默认直接插入文字；
/// - `configuration`：候选条高度等几何参数。
///
/// 建议来源变化时调用 `reloadSuggestions()`；需要在候选条上提示一句话时调用 `showMessage(_:)`。
///
/// 拼写中的拼音显示在候选条左上角的小字行里，**不**写进宿主输入框的标记文本：
/// `setMarkedText`/`unmarkText` 在不同宿主里的行为不一致（App Store 搜索框实测会丢掉已选的字、
/// 把拼音原文和候选拼接上屏），每次按键还会让宿主刷新联想，拖慢整个键盘。
/// 输入框只在选词/上屏时收到一次 `insertText`。
open class PinyinKeyboardViewController: UIInputViewController {
    /// 键盘顶部几何。宿主若另有代码依赖候选条高度（例如按键盘区域裁切截图），
    /// 应从同一处常量构造这个值，避免两边漂移。
    public struct Configuration: Equatable, Sendable {
        /// 候选条区域高度（点），常驻，空态也占位。
        public var candidateBarHeight: CGFloat
        /// 候选条与第一排按键之间的间距（点）。
        public var candidateBarGap: CGFloat

        public init(candidateBarHeight: CGFloat = 44, candidateBarGap: CGFloat = 8) {
            self.candidateBarHeight = candidateBarHeight
            self.candidateBarGap = candidateBarGap
        }
    }

    private enum Layout { case letters, numbers, symbols }
    /// 系统 shift 的三态：单击大写一次，双击锁定大写。
    private enum Shift { case off, once, locked }

    // MARK: 几何（按系统键盘截图实测，单位 pt）

    private enum Metrics {
        static let sideInset: CGFloat = 4
        static let keyGap: CGFloat = 6
        static let keyHeight: CGFloat = 42.5
        static let rowGap: CGFloat = 11.5
        static let compactKeyHeight: CGFloat = 32
        static let compactRowGap: CGFloat = 6
        static let bottomInset: CGFloat = 5
        static let cornerRadius: CGFloat = 7
        /// ⇧ / ⌫ 宽度，以字母键宽为单位。
        static let shiftUnits: CGFloat = 1.34
        /// 123 / 🌐 宽度。
        static let modeUnits: CGFloat = 1.3
        /// 换行键宽度。
        static let returnUnits: CGFloat = 2.8
        static let doubleTapInterval: TimeInterval = 0.35
        /// 拼写中候选条让出上方拼音行后的高度。
        static let composingBarHeight: CGFloat = 30
    }

    // MARK: 子类扩展点

    /// 键盘顶部几何。子类覆写；在 `viewDidLoad` 时读取一次。
    open var configuration: Configuration { Configuration() }

    /// 没有拼写时候选条上显示的建议。返回空数组时候选条留空。
    open func suggestions() -> [KeyboardSuggestion] { [] }

    /// 用户点了某条建议。默认直接插入文字。
    open func didSelectSuggestion(_ suggestion: KeyboardSuggestion) {
        textDocumentProxy.insertText(suggestion.text)
    }

    /// 建议来源变了：重新取 `suggestions()`，内容没变时不重建按钮。
    public final func reloadSuggestions() {
        renderCandidateBar()
    }

    /// 在候选条上显示一句提示，到期后恢复原内容。
    public final func showMessage(_ text: String, duration: TimeInterval = 4) {
        message = (text, Date().addingTimeInterval(duration))
        renderCandidateBar()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) { [weak self] in
            self?.renderCandidateBar()
        }
    }

    /// 是否有未上屏的拼音。
    public final var isComposing: Bool { !composition.isEmpty }

    /// 拼音引擎。可在子类里用于别的用途（例如测试）。
    public let pinyinEngine: PinyinInputEngine

    public init(pinyinEngine: PinyinInputEngine = PinyinInputEngine()) {
        self.pinyinEngine = pinyinEngine
        super.init(nibName: nil, bundle: nil)
    }

    public override init(nibName: String?, bundle: Bundle?) {
        pinyinEngine = PinyinInputEngine()
        super.init(nibName: nibName, bundle: bundle)
    }

    public required init?(coder: NSCoder) {
        pinyinEngine = PinyinInputEngine()
        super.init(coder: coder)
    }

    // MARK: 状态

    private let topArea = UIView()
    private let pinyinLabel = UILabel()
    private let candidateBar = UIStackView()
    /// 拼写中候选条下移，让出上方的拼音行。
    private var candidateBarTop: NSLayoutConstraint?
    private let candidateScroll = UIScrollView()
    private let candidateStack = UIStackView()
    private let candidateSeparator = UIView()
    private let expandButton = UIButton(type: .system)
    private let candidateGrid = CandidateGridView()
    private let keyStack = UIStackView()
    private var pinyinCandidates: [PinyinInputEngine.Candidate] = []
    private var layout: Layout = .letters
    private var shift: Shift = .off
    private var lastShiftTap: Date?
    private var expanded = false
    private var composition = ""
    private var compositionDocumentID: UUID?
    /// 候选条上次渲染的内容签名。宿主的 text/selection 回调很频繁，内容没变就不重建按钮。
    private var renderedBarSignature: String?
    private var switchButton: UIButton?
    private var spaceButton: UIButton?
    private var enterButton: UIButton?
    private var heightConstraint: NSLayoutConstraint?
    /// 建议模式下等宽平铺；拼音模式下按词宽横滑。
    private var equalWidthConstraint: NSLayoutConstraint?
    private var appliedSafeAreaInset: CGFloat = -1
    private var deleteTimer: Timer?
    private var message: (text: String, until: Date)?
    private lazy var resolvedConfiguration = configuration

    // MARK: 生命周期

    open override func viewDidLoad() {
        super.viewDidLoad()
        let engine = pinyinEngine
        DispatchQueue.global(qos: .userInitiated).async { engine.prepare() }
        buildLayout()
        rebuildKeys()
        renderComposition()
    }

    open override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        resetCompositionIfDocumentChanged()
        // 高度只在出现前定一次。放进布局回调会让键盘每帧重设高度，呈现时逐帧长高。
        applyHeight()
        enterButton?.setTitle(enterTitle(), for: .normal)
        renderCandidateBar()
    }

    open override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopDeleting()
        // 拼音只在键盘里，收起时直接丢弃，不往输入框里塞拼音原文。
        if !composition.isEmpty { dropComposition() }
    }

    open override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        resetCompositionIfDocumentChanged()
        enterButton?.setTitle(enterTitle(), for: .normal)
        renderCandidateBar()
    }

    open override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        resetCompositionIfDocumentChanged()
        renderCandidateBar()
    }

    open override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        switchButton?.isHidden = !needsInputModeSwitchKey
        // 安全区在首次布局后才确定；只在它变化时补一次高度。
        if view.safeAreaInsets.bottom != appliedSafeAreaInset { applyHeight() }
    }

    open override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.verticalSizeClass != traitCollection.verticalSizeClass {
            keyStack.spacing = rowGap
            applyHeight()
        }
    }

    private var compact: Bool { traitCollection.verticalSizeClass == .compact }
    private var rowGap: CGFloat { compact ? Metrics.compactRowGap : Metrics.rowGap }

    /// 固定高度：候选条常驻 + 四排按键。与系统键盘一样不随输入状态变化。
    private func applyHeight() {
        let keyHeight = compact ? Metrics.compactKeyHeight : Metrics.keyHeight
        let keys = 4 * keyHeight + 3 * rowGap
        let inset = view.safeAreaInsets.bottom
        appliedSafeAreaInset = inset
        let top = resolvedConfiguration.candidateBarHeight + resolvedConfiguration.candidateBarGap
        heightConstraint?.constant = top + keys + Metrics.bottomInset + inset
    }

    // MARK: - 候选条

    /// 候选条内容：提示 > 拼音候选 > 宿主建议。三者共用一行，和系统键盘一样。
    ///
    /// 候选条常驻：没有内容时留空，不收起、不显示占位文字，键盘高度不变。
    private func renderCandidateBar() {
        guard isViewLoaded else { return }
        let composing = !composition.isEmpty
        let showMessage = message.map { $0.until > Date() } ?? false
        let hostSuggestions = composing || showMessage ? [] : suggestions()
        let signature: String
        if showMessage {
            signature = "m|\(message?.text ?? "")"
        } else if composing {
            signature = "p|\(composition)|\(expanded)"
        } else {
            signature = "s|" + hostSuggestions.map { "\($0.id)\u{1F}\($0.text)" }.joined(separator: "\u{1E}")
        }
        guard signature != renderedBarSignature else { return }
        renderedBarSignature = signature
        clear(candidateStack)
        if showMessage, let message {
            setEqualWidth(false)
            candidateStack.addArrangedSubview(makeMessageLabel(message.text))
        } else if composing {
            setEqualWidth(false)
            renderPinyinCandidates()
        } else {
            renderSuggestions(hostSuggestions)
        }
        expandButton.isHidden = !composing
        candidateSeparator.isHidden = !composing
        if !composing, expanded { setExpanded(false) }
        candidateScroll.setContentOffset(.zero, animated: false)
    }

    /// 空输入状态：宿主建议等宽平铺，样式对齐系统英文键盘的预测条。
    private func renderSuggestions(_ items: [KeyboardSuggestion]) {
        setEqualWidth(!items.isEmpty)
        for item in items {
            let button = makeCandidateButton(item.text, highlighted: false) { [weak self] in
                self?.didSelectSuggestion(item)
            }
            button.accessibilityLabel = item.accessibilityLabel ?? item.text
            candidateStack.addArrangedSubview(button)
        }
    }

    /// 输入状态：拼音候选横滑，首项白色托底。
    ///
    /// 拼音本身显示在上方的拼音行里，不在候选条重复；
    /// 只有词库里一个候选都没有时，才把原文放进候选条供直接上屏。
    private func renderPinyinCandidates() {
        for (index, candidate) in pinyinCandidates.prefix(20).enumerated() {
            let button = makeCandidateButton(candidate.text, highlighted: index == 0) { [weak self] in
                self?.choose(candidate)
            }
            button.accessibilityLabel = "拼音候选：\(candidate.text)"
            candidateStack.addArrangedSubview(button)
        }
        if pinyinCandidates.isEmpty {
            let literal = makeCandidateButton(composition, highlighted: true) { [weak self] in
                self?.commitLiteral()
            }
            literal.accessibilityLabel = "直接输入拼音原文：\(composition)"
            candidateStack.addArrangedSubview(literal)
        }
        if expanded { renderGrid() }
    }

    private func setEqualWidth(_ equal: Bool) {
        candidateStack.distribution = equal ? .fillEqually : .fill
        equalWidthConstraint?.isActive = equal
    }

    /// ⌄ 展开：用完整候选网格盖住按键区，和系统一样。
    private func setExpanded(_ value: Bool) {
        expanded = value
        expandButton.setImage(UIImage(systemName: value ? "chevron.up" : "chevron.down"), for: .normal)
        expandButton.accessibilityLabel = value ? "收起候选" : "展开全部候选"
        candidateGrid.isHidden = !value
        keyStack.alpha = value ? 0 : 1
        keyStack.isUserInteractionEnabled = !value
        renderedBarSignature = nil
        if value { renderGrid() } else { candidateGrid.setCells([]) }
    }

    private func renderGrid() {
        let cells: [UIView] = pinyinCandidates.prefix(300).map { candidate in
            let button = makeCandidateButton(candidate.text, highlighted: false) { [weak self] in
                self?.choose(candidate)
            }
            button.accessibilityLabel = "拼音候选：\(candidate.text)"
            return button
        }
        candidateGrid.setCells(cells)
    }

    // MARK: - 拼写

    /// 换了输入框：丢弃键盘侧未上屏的拼音。
    private func resetCompositionIfDocumentChanged() {
        guard let compositionDocumentID,
              compositionDocumentID != textDocumentProxy.documentIdentifier else { return }
        dropComposition()
    }

    /// 丢弃组合。拼音只存在于键盘里，输入框不需要任何清理。
    private func dropComposition() {
        composition = ""
        compositionDocumentID = nil
        renderComposition()
    }

    private func renderComposition() {
        let composing = !composition.isEmpty
        pinyinCandidates = composing ? pinyinEngine.candidates(for: composition) : []
        pinyinLabel.text = composing ? pinyinEngine.displaySpelling(for: composition) : nil
        pinyinLabel.isHidden = !composing
        candidateBarTop?.constant = composing
            ? max(0, resolvedConfiguration.candidateBarHeight - Metrics.composingBarHeight) : 0
        spaceButton?.setTitle(composing ? "选定" : "空格", for: .normal)
        enterButton?.setTitle(enterTitle(), for: .normal)
        renderCandidateBar()
    }

    /// 回车键标题。有未上屏的拼音时显示「确认」，否则跟随输入框的回车类型。
    private func enterTitle() -> String {
        if !composition.isEmpty { return "确认" }
        switch textDocumentProxy.returnKeyType {
        case .send: return "发送"
        case .search, .google, .yahoo: return "搜索"
        case .go: return "前往"
        case .done: return "完成"
        case .next: return "下一项"
        case .join: return "加入"
        case .route: return "路线"
        case .continue: return "继续"
        default: return "换行"
        }
    }

    private func choose(_ candidate: PinyinInputEngine.Candidate) {
        resetCompositionIfDocumentChanged()
        guard !composition.isEmpty, candidate.consumedPinyinCount > 0,
              candidate.consumedPinyinCount <= composition.count,
              pinyinCandidates.contains(candidate) else { return }
        composition = String(composition.dropFirst(candidate.consumedPinyinCount))
        // 分隔符只在拼写中有意义，剩余拼音开头的 ' 一并去掉。
        while composition.first == "'" { composition.removeFirst() }
        if composition.isEmpty { compositionDocumentID = nil }
        // 选中的词上屏；剩余拼音留在键盘里继续选（选「西」后剩 `an`）。
        textDocumentProxy.insertText(candidate.text)
        if expanded { setExpanded(false) }
        renderComposition()
    }

    private func commitLiteral() {
        resetCompositionIfDocumentChanged()
        guard !composition.isEmpty else { return }
        // 上屏的是实际键入的字母，不含显示用的音节空格和分隔符。
        let text = composition.replacingOccurrences(of: "'", with: "")
        composition = ""
        compositionDocumentID = nil
        textDocumentProxy.insertText(text)
        renderComposition()
    }

    /// 上屏当前组合：有覆盖整串拼音的候选就选它，否则上屏拼音原文。
    private func commitComposition() {
        guard !composition.isEmpty else { return }
        if let full = pinyinCandidates.first(where: { $0.consumedPinyinCount == composition.count }) {
            choose(full)
        } else {
            commitLiteral()
        }
    }

    private func type(_ text: String) {
        resetCompositionIfDocumentChanged()
        let isLetter = text.range(of: "^[a-z]$", options: .regularExpression) != nil
        if layout == .letters, isLetter {
            guard shift == .off else {
                // shift 状态下字母直接以大写英文上屏，不进拼音——系统中文键盘就是这样输英文的。
                commitComposition()
                textDocumentProxy.insertText(text.uppercased())
                if shift == .once { setShift(.off) }
                return
            }
            guard composition.count < 64 else { return }
            compositionDocumentID = textDocumentProxy.documentIdentifier
            composition += text
            renderComposition()
            return
        }
        // 拼写中的 ' 是音节分隔符（xi'an = 西安），并回到字母键盘继续拼。
        if text == "'", !composition.isEmpty {
            if composition.last != "'", composition.count < 64 {
                composition += "'"
                renderComposition()
            }
            if layout != .letters {
                layout = .letters
                rebuildKeys()
            }
            return
        }
        commitComposition()
        textDocumentProxy.insertText(text)
    }

    private func tapShift() {
        let now = Date()
        let doubleTap = lastShiftTap.map { now.timeIntervalSince($0) < Metrics.doubleTapInterval } ?? false
        lastShiftTap = now
        switch shift {
        case .off: setShift(.once)
        case .once: setShift(doubleTap ? .locked : .off)
        case .locked: setShift(.off)
        }
    }

    private func setShift(_ value: Shift) {
        shift = value
        rebuildKeys()
    }

    private func space() {
        resetCompositionIfDocumentChanged()
        if !composition.isEmpty {
            if let first = pinyinCandidates.first { choose(first) } else { commitLiteral() }
        } else {
            textDocumentProxy.insertText(" ")
        }
    }

    /// 回车：有未上屏的拼音时按第一个候选确认，否则换行。
    private func enter() {
        resetCompositionIfDocumentChanged()
        guard !composition.isEmpty else {
            textDocumentProxy.insertText("\n")
            return
        }
        if let first = pinyinCandidates.first { choose(first) } else { commitLiteral() }
    }

    private func deleteBackward() {
        resetCompositionIfDocumentChanged()
        if composition.isEmpty {
            textDocumentProxy.deleteBackward()
        } else {
            composition.removeLast()
            if composition.isEmpty { compositionDocumentID = nil }
            renderComposition()
        }
    }

    @objc private func repeatDelete(_ recognizer: UILongPressGestureRecognizer) {
        if recognizer.state == .began {
            deleteBackward()
            deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.deleteBackward() }
            }
        } else if recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed {
            stopDeleting()
        }
    }

    private func stopDeleting() {
        deleteTimer?.invalidate()
        deleteTimer = nil
    }

    @objc private func switchInputMode(_ sender: UIButton, with event: UIEvent) {
        commitComposition()
        handleInputModeList(from: sender, with: event)
    }

    /// 切换字母/数字/符号页。拼写中的组合保留，方便从 123 页取 ' 分隔音节。
    private func changeLayout(_ next: Layout) {
        layout = next
        rebuildKeys()
    }

    // MARK: - 按键布局

    private func rebuildKeys() {
        stopDeleting()
        clear(keyStack)
        switch layout {
        case .letters:
            let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map { row in
                row.map { character -> UIView in
                    let text = String(character)
                    let shown = shift == .off ? text : text.uppercased()
                    let key = makeKey(shown, fontSize: 24)
                    key.accessibilityLabel = shown
                    key.addAction(UIAction { [weak self] _ in self?.type(text) }, for: .touchUpInside)
                    return key
                }
            }
            addRow(rows[0].map { ($0, .units(1)) }, arrangement: .leading)
            addRow(rows[1].map { ($0, .units(1)) }, arrangement: .centered)
            let shiftKey = makeKey("", symbol: shiftSymbol(), accessibility: shiftAccessibility(), modifier: shift == .off)
            shiftKey.addAction(UIAction { [weak self] _ in self?.tapShift() }, for: .touchUpInside)
            addRow([(shiftKey, .units(Metrics.shiftUnits))] + rows[2].map { ($0, .units(1)) }
                   + [(makeDeleteKey(), .units(Metrics.shiftUnits))], arrangement: .pinnedEdges)
        case .numbers, .symbols:
            let rows = layout == .numbers
                ? ["1234567890", "-/：；（）¥@“”", "。，、？！'"]
                : ["[]{}#%^*+=", "_\\|~<>€£$•", ".,?!'"]
            for row in rows.prefix(2) {
                addRow(row.map { (makeCharacterKey(String($0)), .units(1)) }, arrangement: .leading)
            }
            let toggle = makeKey(layout == .numbers ? "#+=" : "123", fontSize: 16, modifier: true)
            toggle.accessibilityLabel = "切换数字符号"
            toggle.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                changeLayout(layout == .numbers ? .symbols : .numbers)
            }, for: .touchUpInside)
            addRow([(toggle, .units(Metrics.shiftUnits))] + rows[2].map { (makeCharacterKey(String($0)), .flex) }
                   + [(makeDeleteKey(), .units(Metrics.shiftUnits))], arrangement: .leading)
        }
        addBottomRow()
    }

    /// 底排：123 / 🌐 / 空格 / 换行，与系统中文键盘一致。
    private func addBottomRow() {
        let mode = makeKey(layout == .letters ? "123" : "拼音", fontSize: 17, modifier: true)
        mode.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            changeLayout(layout == .letters ? .numbers : .letters)
        }, for: .touchUpInside)
        let globe = makeKey("", symbol: "globe", accessibility: "切换输入法", modifier: true)
        globe.addTarget(self, action: #selector(switchInputMode(_:with:)), for: .allTouchEvents)
        globe.isHidden = !needsInputModeSwitchKey
        switchButton = globe
        let space = makeKey(composition.isEmpty ? "空格" : "选定", fontSize: 17)
        space.addAction(UIAction { [weak self] _ in self?.space() }, for: .touchUpInside)
        spaceButton = space
        let enter = makeKey(enterTitle(), fontSize: 17, modifier: true)
        enter.addAction(UIAction { [weak self] _ in self?.enter() }, for: .touchUpInside)
        enterButton = enter
        addRow([(mode, .units(Metrics.modeUnits)), (globe, .units(Metrics.modeUnits)),
                (space, .flex), (enter, .units(Metrics.returnUnits))], arrangement: .leading)
    }

    private func addRow(_ items: [(UIView, KeyRowView.Width)], arrangement: KeyRowView.Arrangement) {
        let row = KeyRowView()
        row.gap = Metrics.keyGap
        row.setItems(items, arrangement: arrangement)
        keyStack.addArrangedSubview(row)
    }

    private func makeCharacterKey(_ text: String) -> UIButton {
        let key = makeKey(text, fontSize: 22)
        key.addAction(UIAction { [weak self] _ in self?.type(text) }, for: .touchUpInside)
        return key
    }

    private func makeDeleteKey() -> UIButton {
        let delete = makeKey("", symbol: "delete.left", accessibility: "删除", modifier: true)
        delete.addAction(UIAction { [weak self] _ in self?.deleteBackward() }, for: .touchUpInside)
        delete.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(repeatDelete(_:))))
        return delete
    }

    private func shiftSymbol() -> String {
        switch shift {
        case .off: return "shift"
        case .once: return "shift.fill"
        case .locked: return "capslock.fill"
        }
    }

    private func shiftAccessibility() -> String {
        switch shift {
        case .off: return "大写"
        case .once: return "大写已开启"
        case .locked: return "大写锁定"
        }
    }

    private func buildLayout() {
        // 透明背景：系统在键盘下方合成毛玻璃，自绘底色会和它叠成一块死灰色。
        view.backgroundColor = .clear

        candidateScroll.showsHorizontalScrollIndicator = false
        candidateScroll.alwaysBounceHorizontal = true
        candidateScroll.addSubview(candidateStack)
        candidateStack.axis = .horizontal
        candidateStack.spacing = 2
        candidateStack.alignment = .center
        candidateStack.translatesAutoresizingMaskIntoConstraints = false
        let contentGuide = candidateScroll.contentLayoutGuide
        let frameGuide = candidateScroll.frameLayoutGuide
        equalWidthConstraint = candidateStack.widthAnchor.constraint(equalTo: frameGuide.widthAnchor, constant: -8)
        NSLayoutConstraint.activate([
            candidateStack.leadingAnchor.constraint(equalTo: contentGuide.leadingAnchor, constant: 4),
            candidateStack.trailingAnchor.constraint(equalTo: contentGuide.trailingAnchor, constant: -4),
            candidateStack.topAnchor.constraint(equalTo: contentGuide.topAnchor),
            candidateStack.bottomAnchor.constraint(equalTo: contentGuide.bottomAnchor),
            candidateStack.heightAnchor.constraint(equalTo: frameGuide.heightAnchor)
        ])

        candidateSeparator.backgroundColor = .separator
        expandButton.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        expandButton.setPreferredSymbolConfiguration(.init(pointSize: 18, weight: .regular), forImageIn: .normal)
        expandButton.tintColor = .label
        expandButton.accessibilityLabel = "展开全部候选"
        expandButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            setExpanded(!expanded)
        }, for: .touchUpInside)

        candidateBar.axis = .horizontal
        candidateBar.alignment = .center
        candidateBar.spacing = 0
        [candidateScroll, candidateSeparator, expandButton].forEach { candidateBar.addArrangedSubview($0) }

        pinyinLabel.font = .systemFont(ofSize: 13)
        pinyinLabel.textColor = .label
        pinyinLabel.lineBreakMode = .byTruncatingHead
        pinyinLabel.isHidden = true
        pinyinLabel.translatesAutoresizingMaskIntoConstraints = false
        candidateBar.translatesAutoresizingMaskIntoConstraints = false
        topArea.addSubview(pinyinLabel)
        topArea.addSubview(candidateBar)
        let barTop = candidateBar.topAnchor.constraint(equalTo: topArea.topAnchor)
        candidateBarTop = barTop
        NSLayoutConstraint.activate([
            pinyinLabel.topAnchor.constraint(equalTo: topArea.topAnchor, constant: 1),
            pinyinLabel.leadingAnchor.constraint(equalTo: topArea.leadingAnchor, constant: 10),
            pinyinLabel.trailingAnchor.constraint(lessThanOrEqualTo: topArea.trailingAnchor, constant: -10),
            barTop,
            candidateBar.leadingAnchor.constraint(equalTo: topArea.leadingAnchor),
            candidateBar.trailingAnchor.constraint(equalTo: topArea.trailingAnchor),
            candidateBar.bottomAnchor.constraint(equalTo: topArea.bottomAnchor)
        ])

        keyStack.axis = .vertical
        keyStack.spacing = rowGap
        keyStack.distribution = .fillEqually

        let root = UIStackView(arrangedSubviews: [topArea, keyStack])
        root.axis = .vertical
        root.spacing = resolvedConfiguration.candidateBarGap
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)

        candidateGrid.isHidden = true
        candidateGrid.showsVerticalScrollIndicator = false
        candidateGrid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(candidateGrid)

        // 初值只给一个下界，真正的值在 viewWillAppear 里按安全区定一次。
        let height = view.heightAnchor.constraint(equalToConstant: 216)
        height.priority = .required
        heightConstraint = height
        NSLayoutConstraint.activate([
            height,
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Metrics.sideInset),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Metrics.sideInset),
            root.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                                         constant: -Metrics.bottomInset),
            topArea.heightAnchor.constraint(equalToConstant: resolvedConfiguration.candidateBarHeight),
            candidateScroll.heightAnchor.constraint(equalTo: candidateBar.heightAnchor),
            candidateSeparator.widthAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            candidateSeparator.heightAnchor.constraint(equalToConstant: 28),
            expandButton.widthAnchor.constraint(equalToConstant: 44),
            expandButton.heightAnchor.constraint(equalTo: candidateBar.heightAnchor),
            candidateGrid.topAnchor.constraint(equalTo: keyStack.topAnchor),
            candidateGrid.leadingAnchor.constraint(equalTo: keyStack.leadingAnchor),
            candidateGrid.trailingAnchor.constraint(equalTo: keyStack.trailingAnchor),
            candidateGrid.bottomAnchor.constraint(equalTo: keyStack.bottomAnchor)
        ])
    }

    /// 系统键帽配色：字母键白、功能键灰；按下时两者互换。
    private enum KeyStyle {
        static let plain = UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(white: 0.42, alpha: 1) : .white }
        static let modifier = UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(white: 0.27, alpha: 1) : UIColor(red: 0.68, green: 0.70, blue: 0.74, alpha: 1) }
        /// 候选条首项托底：比键盘底色更亮的白色块。
        static let chip = UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.16) : UIColor(white: 1, alpha: 0.78) }
    }

    private func makeKey(_ title: String, symbol: String? = nil, accessibility: String? = nil,
                         fontSize: CGFloat = 18, modifier: Bool = false) -> UIButton {
        let button = UIButton(type: .custom)
        if let symbol {
            button.setImage(UIImage(systemName: symbol), for: .normal)
            button.setPreferredSymbolConfiguration(.init(pointSize: 19, weight: .regular), forImageIn: .normal)
        } else {
            button.setTitle(title, for: .normal)
        }
        button.titleLabel?.font = .systemFont(ofSize: fontSize)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.6
        button.tintColor = .label
        button.setTitleColor(.label, for: .normal)
        let normal = modifier ? KeyStyle.modifier : KeyStyle.plain
        let pressed = modifier ? KeyStyle.plain : KeyStyle.modifier
        button.backgroundColor = normal
        button.addAction(UIAction { [weak button] _ in button?.backgroundColor = pressed }, for: .touchDown)
        for event: UIControl.Event in [.touchUpInside, .touchUpOutside, .touchCancel] {
            button.addAction(UIAction { [weak button] _ in button?.backgroundColor = normal }, for: event)
        }
        button.layer.cornerRadius = Metrics.cornerRadius
        button.layer.cornerCurve = .continuous
        button.layer.masksToBounds = false
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.3
        button.layer.shadowRadius = 0
        button.layer.shadowOffset = CGSize(width: 0, height: 1)
        button.accessibilityLabel = accessibility ?? title
        return button
    }

    /// 候选条条目：常规字重、统一 label 色；只有首项带白色托底，对齐系统候选条。
    private func makeCandidateButton(_ title: String, highlighted: Bool,
                                     action: @escaping () -> Void) -> UIButton {
        // 普通 custom 按钮：每次按键都要重建一排候选，UIButton.Configuration 的布局开销明显更大。
        let button = CandidateButton(type: .custom)
        button.setTitle(title, for: .normal)
        button.setTitleColor(.label, for: .normal)
        button.setTitleColor(.secondaryLabel, for: .highlighted)
        button.titleLabel?.font = .systemFont(ofSize: 20)
        button.titleLabel?.lineBreakMode = .byTruncatingTail
        button.backgroundColor = highlighted ? KeyStyle.chip : .clear
        button.layer.cornerRadius = 8
        button.layer.cornerCurve = .continuous
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        button.accessibilityLabel = title
        return button
    }

    private func makeMessageLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 15)
        label.textColor = .secondaryLabel
        label.lineBreakMode = .byTruncatingTail
        label.accessibilityLabel = text
        return label
    }

    private func clear(_ stack: UIStackView) {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
    }
}
#endif
