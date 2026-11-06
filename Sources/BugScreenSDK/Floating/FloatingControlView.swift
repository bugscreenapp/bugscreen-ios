import SwiftUI
import UIKit

@MainActor
final class FloatingControlView: UIView {
    let motion: FloatingMotion
    var report: (() -> Void)?
    var record: (() -> Void)?
    var stop: (() -> Void)?
    var hide: (() -> Void)?
    private let button = UIButton(type: .system)
    private lazy var dragGesture = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
    private let logo = UIImage(named: "BugScreenMark", in: BugScreenResources.bundle, compatibleWith: nil)?
        .withRenderingMode(.alwaysTemplate)
    private let menu = UIStackView()
    private let menuMotion = FloatingVisibilityMotion()
    private let trashMotion = FloatingVisibilityMotion()
    private let idleMotion = FloatingIdleMotion()
    private let presence = FloatingVisibilityMotion()
    private var dropPosition: CGPoint?
    private var exitToLeft: Bool?
    private var exitCompletion: (() -> Void)?
    private let uptime: () -> TimeInterval
    private var idleTimer: Timer?
    private var idleDeadline: TimeInterval?
    private var touching = false
    private var disposed = false
    private let spokenFeedback: () -> Bool
    private let logoGlyph = UIImageView()
    private let closeGlyph = UIImageView(image: UIImage(systemName: "xmark"))
    private let stopGlyph = UIImageView(image: UIImage(systemName: "stop.fill"))
    private let elapsedLabel = UILabel()
    private let trash = UIImageView(image: UIImage(systemName: "trash", withConfiguration: UIImage.SymbolConfiguration(pointSize: 24)))
    private var startedAt: TimeInterval?
    private var busy = false
    private var dragOrigin = CGPoint.zero
    private var displayLink: CADisplayLink?
    private var clock: Timer?
    private var lastFrame: TimeInterval = 0
    private var keyboardTop: CGFloat?
    private var dragging = false

    init(motion: FloatingMotion, spokenFeedback: @escaping () -> Bool = { UIAccessibility.isVoiceOverRunning },
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime })
    {
        self.motion = motion
        self.spokenFeedback = spokenFeedback
        self.uptime = uptime
        super.init(frame: .zero)
        backgroundColor = .clear
        button.backgroundColor = UIColor(Brand.primary)
        button.tintColor = UIColor(Brand.onPrimary)
        button.layer.cornerRadius = 28
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.18
        button.layer.shadowRadius = 8
        button.layer.shadowOffset = CGSize(width: 0, height: 4)
        stopGlyph.contentMode = .scaleAspectFit
        stopGlyph.tintColor = UIColor(Brand.onPrimary)
        stopGlyph.isUserInteractionEnabled = false
        button.addSubview(stopGlyph)
        elapsedLabel.font = UIFontMetrics(forTextStyle: .subheadline)
            .scaledFont(for: .monospacedDigitSystemFont(ofSize: 15, weight: .regular))
        elapsedLabel.adjustsFontForContentSizeCategory = true
        elapsedLabel.textColor = UIColor(Brand.onPrimary)
        elapsedLabel.isAccessibilityElement = false
        button.addSubview(elapsedLabel)
        button.addTarget(self, action: #selector(catchMotion), for: .touchDown)
        button.addTarget(self, action: #selector(tap), for: .touchUpInside)
        button.addTarget(self, action: #selector(cancelPress), for: [.touchUpOutside, .touchCancel])
        button.addGestureRecognizer(dragGesture)
        button.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: SDKStrings.floatingHide, target: self, selector: #selector(hideAction)),
            UIAccessibilityCustomAction(name: SDKStrings.floatingLeft, target: self, selector: #selector(leftAction)),
            UIAccessibilityCustomAction(name: SDKStrings.floatingRight, target: self, selector: #selector(rightAction)),
        ]
        logoGlyph.image = logo
        logoGlyph.contentMode = .scaleAspectFit
        logoGlyph.tintColor = button.tintColor
        logoGlyph.isUserInteractionEnabled = false
        button.addSubview(logoGlyph)
        closeGlyph.contentMode = .scaleAspectFit
        closeGlyph.tintColor = button.tintColor
        closeGlyph.isUserInteractionEnabled = false
        button.addSubview(closeGlyph)
        addSubview(button)
        menu.axis = .vertical
        menu.backgroundColor = UIColor(Brand.paper)
        menu.layer.cornerRadius = 20
        menu.layer.shadowColor = UIColor.black.cgColor
        menu.layer.shadowOpacity = 0.15
        menu.layer.shadowRadius = 12
        menu.addArrangedSubview(action(SDKStrings.floatingReport, symbol: "ladybug", selector: #selector(makeReport)))
        menu.addArrangedSubview(action(SDKStrings.floatingRecord, symbol: "video", selector: #selector(startRecording)))
        menu.addArrangedSubview(action(SDKStrings.floatingHide, symbol: "eye.slash", selector: #selector(hideFromMenu)))
        menu.isHidden = true
        addSubview(menu)
        trash.contentMode = .center
        trash.backgroundColor = UIColor(Brand.paper)
        trash.tintColor = UIColor(Brand.dangerText)
        trash.layer.cornerRadius = 36
        trash.clipsToBounds = true
        trash.isHidden = true
        trash.isAccessibilityElement = false
        addSubview(trash)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboard(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(animationSettingsChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(animationSettingsChanged),
            name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil
        )
        update(preparing: false, startedAt: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func action(_ title: String, symbol: String, selector: Selector) -> UIButton {
        let row = UIButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.image = UIImage(systemName: symbol)
        configuration.imagePadding = 12
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        configuration.baseForegroundColor = UIColor(Brand.ink)
        row.configuration = configuration
        row.contentHorizontalAlignment = .leading
        row.titleLabel?.numberOfLines = 0
        row.titleLabel?.adjustsFontForContentSizeCategory = true
        row.addTarget(self, action: selector, for: .touchUpInside)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        return row
    }

    func update(preparing: Bool, startedAt: TimeInterval?) {
        busy = preparing
        if self.startedAt != startedAt {
            clock?.invalidate()
            clock = nil
            self.startedAt = startedAt
            if startedAt != nil {
                let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateClock() }
                }
                clock = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }
        button.isEnabled = !busy && !isExiting
        button.alpha = busy ? 0.65 : 1
        if busy || startedAt != nil { setMenu(false, animate: false) }
        if busy {
            dragging = false
            touching = false
            setTrashVisible(false, animate: false)
        }
        updateClock()
        applyMenuMotion()
        setNeedsLayout()
    }

    private func updateClock() {
        if let startedAt {
            let seconds = max(0, Int(uptime() - startedAt))
            let label = String(format: "%d:%02d", seconds / 60, seconds % 60)
            elapsedLabel.text = label
            button.accessibilityLabel = SDKStrings.floatingStopElapsed(label)
        } else {
            elapsedLabel.text = nil
            button
                .accessibilityLabel = busy ? SDKStrings.floatingPreparing :
                (menuMotion.visible ? SDKStrings.floatingClose : SDKStrings.floatingOpen)
        }
    }

    private var usable: CGRect {
        let half = buttonWidth / 2
        let top = safeAreaInsets.top + 40
        let bottom = max(top, min(bounds.height - safeAreaInsets.bottom, keyboardTop ?? bounds.height) - 40)
        return CGRect(x: half + 12, y: top, width: max(0, bounds.width - 2 * (half + 12)), height: bottom - top)
    }

    private var buttonWidth: CGFloat {
        startedAt == nil ? 56 : max(112, elapsedWidth + 54)
    }

    private var elapsedWidth: CGFloat {
        ceil(("0:00" as NSString).size(withAttributes: [.font: elapsedLabel.font as UIFont]).width)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let area = usable
        if dropPosition == nil { motion.adaptBounds(area, preserveDock: !dragging) }
        positionChildren()
    }

    var isExiting: Bool {
        exitCompletion != nil
    }

    func enter() {
        if !isExiting {
            exitToLeft = nil
            idleMotion.tuck()
            presence.setVisible(true, animate: false)
        }
        exitCompletion = nil
        if dropPosition != nil {
            dropPosition = nil
            presence.setVisible(false, animate: false)
            setTrashVisible(false, animate: false)
            motion.release(.zero, bounds: usable, animate: animationsEnabled)
        }
        button.isEnabled = !busy
        dragGesture.isEnabled = true
        accessibilityElementsHidden = false
        presence.setVisible(false, animate: animationsEnabled && !spokenFeedback())
        positionChildren()
        scheduleFrames()
    }

    func exit(completion: @escaping () -> Void) {
        guard !isExiting else { return }
        exitCompletion = completion
        exitToLeft = motion.position.x < bounds.midX
        if dropPosition == nil, !motion.settling, bounds.width > 0 {
            motion.release(.zero, bounds: usable, animate: animationsEnabled)
        }
        accessibilityElementsHidden = true
        button.cancelTracking(with: nil)
        button.isEnabled = false
        dragGesture.isEnabled = false
        touching = false
        dragging = false
        setMenu(false, animate: false)
        if dropPosition != nil {
            trashMotion.freeze()
            presence.setVisible(false, animate: false)
        } else {
            setTrashVisible(false, animate: false)
        }
        presence.setVisible(true, animate: bounds.width > 0 && animationsEnabled && !spokenFeedback())
        positionChildren()
        scheduleFrames()
        completeExit()
    }

    private func completeExit() {
        guard !presence.settling, let completion = exitCompletion else { return }
        exitCompletion = nil
        completion()
    }

    private func positionChildren() {
        refreshIdle()
        let idleOffset = idleMotion.offset(anchor: motion.position.x, buttonWidth: buttonWidth, viewportWidth: bounds.width)
        let restingX = motion.position.x + idleOffset - buttonWidth / 2
        let slidesLeft = exitToLeft ?? (motion.position.x < bounds.midX)
        let outsideX = slidesLeft ? -buttonWidth : bounds.width
        let progress = min(1, max(0, presence.progress))
        alpha = dropPosition != nil ? 1 - progress : 1
        let buttonX = dropPosition?.x ?? (restingX + (outsideX - restingX) * progress)
        button.frame = CGRect(
            x: buttonX,
            y: dropPosition?.y ?? (motion.position.y - 28),
            width: buttonWidth,
            height: 56
        )
        for glyph in [logoGlyph, closeGlyph] {
            glyph.bounds = CGRect(x: 0, y: 0, width: 24, height: 24)
            glyph.center = CGPoint(x: button.bounds.midX, y: button.bounds.midY)
        }
        let clockX = (button.bounds.width - elapsedWidth - 26) / 2
        stopGlyph.frame = CGRect(x: clockX, y: button.bounds.midY - 9, width: 18, height: 18)
        elapsedLabel.frame = CGRect(x: clockX + 26, y: 0, width: elapsedWidth, height: button.bounds.height)
        menu.transform = .identity
        var width = min(300, max(0, bounds.width - 24))
        func menuHeight() -> CGFloat {
            menu.systemLayoutSizeFitting(CGSize(width: width, height: 0), withHorizontalFittingPriority: .required,
                                         verticalFittingPriority: .fittingSizeLevel).height
        }
        var height = menuHeight()
        let lowerEdge = min(bounds.height - safeAreaInsets.bottom, keyboardTop ?? bounds.height)
        let above = button.frame.minY - height - 12
        let below = button.frame.maxY + 12
        let right = motion.position.x > bounds.midX
        var x = right ? button.frame.maxX - width : button.frame.minX
        var y = above >= safeAreaInsets.top ? above : below
        if above < safeAreaInsets.top, below + height > lowerEdge {
            width = min(width, max(0, right ? button.frame.minX - 24 : bounds.width - button.frame.maxX - 24))
            height = menuHeight()
            x = right ? button.frame.minX - width - 12 : button.frame.maxX + 12
            y = min(max(safeAreaInsets.top, motion.position.y - height / 2), max(safeAreaInsets.top, lowerEdge - height))
        }
        menu.frame = CGRect(x: max(12, min(bounds.width - width - 12, x)), y: y, width: width, height: height)
        applyMenuMotion()
        applyTrashMotion()
    }

    private func refreshIdle() {
        guard bounds.width > 0, !touching, !isExiting else {
            idleTimer?.invalidate(); idleTimer = nil
            idleDeadline = nil
            return
        }
        let dockAndDismissalsSettled = !motion.settling && !menuMotion.settling && !trashMotion.settling
        let eligible = !disposed && !busy && startedAt == nil && !dragging &&
            !menuMotion.visible && !trashMotion.visible && (idleMotion.tucked || dockAndDismissalsSettled) && !spokenFeedback()
        idleMotion.update(now: uptime(), eligible: eligible, animate: animationsEnabled && !spokenFeedback())
        guard idleDeadline != idleMotion.deadline else { return }
        idleTimer?.invalidate(); idleTimer = nil
        idleDeadline = idleMotion.deadline
        if let idleDeadline {
            let timer = Timer(timeInterval: max(0.001, idleDeadline - uptime()), repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.disposed else { return }
                    self.idleDeadline = nil
                    self.positionChildren()
                    self.scheduleFrames()
                }
            }
            idleTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, !isExiting else { return nil }
        let hit = super.hitTest(point, with: event)
        return hit === self || hit === trash ? nil : hit
    }

    func hostInteraction() {
        guard !disposed, !isExiting, !busy, startedAt == nil, !touching else { return }
        if menuMotion.visible { setMenu(false) }
        guard !spokenFeedback(), !idleMotion.tucked else { return }
        idleMotion.tuck(animate: animationsEnabled)
        positionChildren()
        scheduleFrames()
    }

    @objc private func catchMotion() {
        guard !isExiting else { return }
        touching = true
        idleMotion.hold()
        motion.place(motion.position, bounds: usable)
        positionChildren()
        scheduleFrames()
    }

    @objc private func cancelPress() {
        guard !dragging, !isExiting else { return }
        touching = false
        idleMotion.reveal(animate: animationsEnabled && !spokenFeedback())
        positionChildren()
        scheduleFrames()
    }

    @objc private func tap() {
        guard !busy, !isExiting else { return }
        touching = false
        idleMotion.reveal(animate: animationsEnabled && !spokenFeedback())
        if startedAt != nil { stop?(); return }
        setMenu(!menuMotion.visible)
    }

    private func setMenu(_ open: Bool, animate: Bool = true) {
        let changed = menuMotion.visible != open
        menuMotion.setVisible(open, animate: animate && animationsEnabled && !spokenFeedback())
        menu.isUserInteractionEnabled = open
        menu.accessibilityElementsHidden = !open
        updateClock()
        applyMenuMotion()
        setNeedsLayout()
        scheduleFrames()
        if changed, open { UIAccessibility.post(notification: .layoutChanged, argument: menu.arrangedSubviews.first) }
    }

    private func applyMenuMotion() {
        let progress = menuMotion.progress
        let opacity = min(1, max(0, progress))
        let scale = 0.76 + 0.24 * progress
        let offset = CGPoint(x: button.center.x - menu.center.x, y: button.center.y - menu.center.y)
        menu.isHidden = !menuMotion.visible && !menuMotion.settling
        menu.alpha = opacity
        menu.transform = CGAffineTransform(translationX: offset.x * (1 - scale), y: offset.y * (1 - scale))
            .scaledBy(x: scale, y: scale)
        stopGlyph.isHidden = startedAt == nil
        elapsedLabel.isHidden = startedAt == nil
        logoGlyph.isHidden = startedAt != nil
        closeGlyph.isHidden = startedAt != nil
        logoGlyph.alpha = 1 - opacity
        logoGlyph.transform = CGAffineTransform(rotationAngle: .pi / 2 * progress)
        closeGlyph.alpha = opacity
        closeGlyph.transform = CGAffineTransform(rotationAngle: -.pi / 2 * (1 - progress))
    }

    @objc private func makeReport() {
        guard menuMotion.visible else { return }
        setMenu(false, animate: false)
        setTrashVisible(false, animate: false)
        report?()
    }

    @objc private func startRecording() {
        guard menuMotion.visible else { return }
        setMenu(false, animate: false)
        setTrashVisible(false, animate: false)
        record?()
    }

    @objc private func hideFromMenu() {
        guard menuMotion.visible else { return }
        setMenu(false, animate: false)
        setTrashVisible(false, animate: false)
        hide?()
    }

    @objc private func hideAction() -> Bool {
        setMenu(false, animate: false)
        setTrashVisible(false, animate: false)
        hide?(); return true
    }

    @objc private func leftAction() -> Bool {
        moveEdge(false); return true
    }

    @objc private func rightAction() -> Bool {
        moveEdge(true); return true
    }

    private func moveEdge(_ right: Bool) {
        guard !isExiting else { return }
        idleMotion.reveal(animate: false)
        motion.place(CGPoint(x: right ? usable.maxX : usable.minX, y: motion.position.y), bounds: usable)
        positionChildren()
        setMenu(false, animate: false)
        setTrashVisible(false, animate: false)
    }

    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        guard !isExiting else { return }
        switch gesture.state {
        case .began:
            let wasIdle = idleMotion.progress > 0
            beginDragging()
            if wasIdle { gesture.setTranslation(.zero, in: self) }
        case .changed:
            guard dragging else { return }
            let delta = gesture.translation(in: self)
            motion.place(CGPoint(x: dragOrigin.x + delta.x, y: dragOrigin.y + delta.y), bounds: usable)
            positionChildren()
            updateTrash()
        case .ended, .cancelled, .failed:
            guard dragging else { return }
            let discarded = gesture.state == .ended && dragging && trashMotion.visible && overTrash
            dragging = false
            touching = false
            if discarded {
                dropPosition = button.frame.origin
                hide?()
                if !isExiting {
                    dropPosition = nil
                    setTrashVisible(false, animate: false)
                }
                return
            }
            setTrashVisible(false)
            motion.release(
                gesture.state == .ended ? gesture.velocity(in: self) : .zero,
                bounds: usable,
                animate: animationsEnabled
            )
            positionChildren()
            scheduleFrames()
        default: break
        }
    }

    func beginDragging() {
        touching = true
        idleMotion.reveal(animate: false)
        stopAnimation()
        motion.place(motion.position, bounds: usable)
        dragOrigin = motion.position
        dragging = true
        setMenu(false, animate: false)
        setTrashVisible(true)
        updateTrash()
    }

    private func setTrashVisible(_ visible: Bool, animate: Bool = true) {
        trashMotion.setVisible(visible, animate: animate && animationsEnabled && !spokenFeedback())
        applyTrashMotion()
        scheduleFrames()
    }

    private var trashCenter: CGPoint {
        CGPoint(x: bounds.midX, y: usable.maxY - 16)
    }

    private func applyTrashMotion() {
        let opacity = min(1, max(0, trashMotion.progress))
        trash.isHidden = !trashMotion.visible && !trashMotion.settling
        trash.alpha = opacity
        trash.bounds = CGRect(x: 0, y: 0, width: 72, height: 72)
        trash.center = CGPoint(x: trashCenter.x, y: trashCenter.y + 16 * (1 - opacity))
    }

    private func updateTrash() {
        let hit = overTrash
        trash.backgroundColor = UIColor(hit ? Brand.dangerBg : Brand.paper)
        UIView.animate(withDuration: animationsEnabled && !spokenFeedback() ? 0.15 : 0) {
            self.trash.transform = hit ? CGAffineTransform(scaleX: 1.06, y: 1.06) : .identity
        }
    }

    private var overTrash: Bool {
        hypot(motion.position.x - trashCenter.x, motion.position.y - trashCenter.y) < 65
    }

    private var animationsEnabled: Bool {
        !UIAccessibility.isReduceMotionEnabled && UIView.areAnimationsEnabled
    }

    @objc private func animationSettingsChanged() {
        if !animationsEnabled {
            if motion.settling { motion.place(motion.target, bounds: usable) }
            menuMotion.setVisible(menuMotion.visible, animate: false)
            trashMotion.setVisible(trashMotion.visible, animate: false)
            idleMotion.advance(0, animate: false)
        }
        positionChildren()
        scheduleFrames()
    }

    func advanceAnimations(_ seconds: TimeInterval) {
        if !animationsEnabled {
            if motion.settling { motion.place(motion.target, bounds: usable) }
            menuMotion.setVisible(menuMotion.visible, animate: false)
            trashMotion.setVisible(trashMotion.visible, animate: false)
        }
        motion.advance(seconds, bounds: usable)
        menuMotion.advance(seconds)
        trashMotion.advance(seconds)
        if !motion.settling { idleMotion.advance(seconds, animate: animationsEnabled && !spokenFeedback()) }
        if !animationsEnabled || spokenFeedback() { presence.setVisible(presence.visible, animate: false) }
        presence.advance(seconds)
        positionChildren()
        completeExit()
    }

    @objc private func frame(_ link: CADisplayLink) {
        advanceAnimations(lastFrame == 0 ? link.duration : link.timestamp - lastFrame)
        lastFrame = link.timestamp
        if !animating { stopAnimation() }
    }

    private var animating: Bool {
        motion.settling || menuMotion.settling || trashMotion.settling || idleMotion.settling || presence.settling
    }

    private func scheduleFrames() {
        if animating {
            if displayLink == nil {
                lastFrame = 0
                displayLink = CADisplayLink(target: self, selector: #selector(frame(_:)))
                displayLink?.add(to: .main, forMode: .common)
            }
        } else {
            stopAnimation()
        }
    }

    private func stopAnimation() {
        displayLink?.invalidate(); displayLink = nil
    }

    @objc private func keyboard(_ notification: Notification) {
        guard let rect = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect, let window else { return }
        let local = convert(window.convert(rect, from: nil), from: window)
        keyboardTop = local.intersects(bounds) ? local.minY : nil
        setNeedsLayout()
    }

    func dispose() {
        disposed = true
        exitCompletion = nil
        touching = false
        idleTimer?.invalidate(); idleTimer = nil
        idleDeadline = nil
        idleMotion.reveal(animate: false)
        menuMotion.setVisible(false, animate: false)
        dragging = false
        trashMotion.setVisible(false, animate: false)
        trash.layer.removeAllAnimations()
        trash.transform = .identity
        applyTrashMotion()
        menu.isUserInteractionEnabled = false
        menu.accessibilityElementsHidden = true
        applyMenuMotion()
        stopAnimation()
        clock?.invalidate(); clock = nil
        // swiftlint:disable:next notification_center_detachment
        NotificationCenter.default.removeObserver(self) // The removed overlay must stop responding immediately.
    }
}
