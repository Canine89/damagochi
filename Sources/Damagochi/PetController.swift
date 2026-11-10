import AppKit
import Combine
import SwiftUI

/// 스프라이트 한 장을 도트 그대로 보여 주고 마우스 입력을 받는 뷰.
final class PetView: NSView {
    weak var controller: PetController?
    private let sprite = CALayer()
    private var downAt = NSPoint.zero
    private var dragging = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        sprite.magnificationFilter = .nearest
        sprite.minificationFilter = .nearest
        layer?.addSublayer(sprite)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ image: CGImage, facingRight: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.bounds = bounds
        sprite.position = CGPoint(x: bounds.midX, y: bounds.midY)
        sprite.contents = image
        // 원본 그림은 왼쪽을 보고 있다
        sprite.setAffineTransform(facingRight ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
        CATransaction.commit()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        downAt = NSEvent.mouseLocation
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        if !dragging, hypot(p.x - downAt.x, p.y - downAt.y) > 4 {
            dragging = true
        }
        if dragging { controller?.drag(to: p) }
    }

    override func mouseUp(with event: NSEvent) {
        if dragging {
            dragging = false
            controller?.endDrag()
        } else {
            controller?.togglePanel()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = controller?.menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// 펫 창을 띄우고, 매 프레임 PetBrain 을 돌려 창 위치와 그림을 갱신한다.
final class PetController: NSObject {
    let monitor: AgentMonitor
    var menuProvider: (() -> NSMenu)?

    private let window: NSPanel
    private let view: PetView
    private var sheet: SpriteSheet?
    private var brain: PetBrain
    private var timer: Timer?
    private var lastTick = CACurrentMediaTime()
    private var worldAge: TimeInterval = 0
    private var shownFrame: Frame?
    private var shownFacingRight = false
    private var shownOrigin = NSPoint(x: -1, y: -1)
    private var panel: PanelController!
    private let bubble = BubbleController()
    private let fence = FenceController()
    private var screenWorld: World                       // 울타리를 적용하기 전의 화면 범위
    private var bubbleCountdown: TimeInterval = 8        // 실행 직후 한 번 보여 준다
    private var headTop: CGFloat = 0                     // 머리 위 빈 줄 수 (논리 px)
    private var bag = Set<AnyCancellable>()

    private(set) var isHidden = false
    private var size: CGFloat { CGFloat(Settings.shared.size) }

    init(monitor: AgentMonitor) {
        self.monitor = monitor
        let s = CGFloat(Settings.shared.size)
        let rect = NSRect(x: 0, y: 0, width: s, height: s)
        window = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        view = PetView(frame: rect)
        screenWorld = WorldScanner.scan()
        brain = PetBrain(world: screenWorld, scale: s / 96,
                         personality: .of(Settings.shared.personality(for: Settings.shared.animal)))
        sheet = SpriteSheet(animal: Settings.shared.animal)
        super.init()

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar                      // Dock 보다 위
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.hidesOnDeactivate = false
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.controller = self

        panel = PanelController(monitor: monitor, petWindow: window)
        panel.onClose = { [weak self] in
            self?.monitor.fast = false
            self?.brain.endGreet()
        }

        headTop = sheet?.contentBounds([.idle0])?.minY ?? 0
        Settings.shared.$animal.dropFirst().sink { [weak self] animal in
            guard let self else { return }
            self.sheet = SpriteSheet(animal: animal)
            self.headTop = self.sheet?.contentBounds([.idle0])?.minY ?? 0
            self.shownFrame = nil
            self.applyPersonality(Settings.shared.personality(for: animal), announce: true)
        }.store(in: &bag)
        Settings.shared.$personalities.dropFirst().sink { [weak self] all in
            let animal = Settings.shared.animal
            let kind = Personality.Kind(rawValue: all[animal.rawValue] ?? "") ?? .playful
            self?.applyPersonality(kind, announce: true)
        }.store(in: &bag)
        Settings.shared.$fenceEnabled.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.rescanWorld()
        }.store(in: &bag)
        fence.onChange = { [weak self] in self?.applyWorld() }
        Settings.shared.$bubbleMinutes.dropFirst().sink { [weak self] minutes in
            // 주기를 바꾸면 곧바로 한 번 보여 줘서 어떻게 뜨는지 알 수 있게 한다
            if minutes > 0 { self?.bubbleCountdown = 0.6 } else { self?.bubble.hide() }
        }.store(in: &bag)
        Settings.shared.$size.dropFirst().sink { [weak self] newSize in
            self?.resize(to: CGFloat(newSize))
        }.store(in: &bag)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.rescanWorld()
        }

        rescanWorld()
        render()
        window.orderFrontRegardless()
        start()
    }

    // MARK: - 루프

    private func start() {
        timer?.invalidate()
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = now - lastTick
        lastTick = now
        worldAge += dt
        if worldAge > 2 {                 // Dock 크기·위치가 바뀌었을 수 있으니 주기적으로 다시 확인
            worldAge = 0
            rescanWorld()
        }
        brain.energetic = monitor.busyCount > 0
        brain.tick(dt)
        tickBubble(dt)
        render()
    }

    // MARK: - 세계 · 성격

    /// 화면(Dock 포함) 상태를 다시 읽고 울타리를 그에 맞춰 세운다.
    private func rescanWorld() {
        screenWorld = WorldScanner.scan()
        fence.layout(in: screenWorld, petSize: size, around: brain.x, visible: !isHidden)
        applyWorld()
    }

    /// 울타리가 있으면 그 안쪽만 펫의 세계가 된다.
    private func applyWorld() {
        var w = screenWorld
        if let r = fence.range {
            w.minX = max(w.minX, r.lowerBound)
            w.maxX = min(w.maxX, r.upperBound)
        }
        if brain.world != w { brain.world = w }
    }

    func recenterFence() {
        fence.recenter(around: brain.x)
    }

    private func applyPersonality(_ kind: Personality.Kind, announce: Bool) {
        let p = Personality.of(kind)
        guard brain.personality != p else { return }
        brain.personality = p
        if announce { say("나는 \(kind.label)!", for: 4) }
    }

    // MARK: - 말풍선

    /// 설정한 주기마다 주간 잔여량을 말풍선으로 잠깐 보여 준다.
    private func tickBubble(_ dt: TimeInterval) {
        let minutes = Settings.shared.bubbleMinutes
        guard minutes > 0 else { return }
        bubbleCountdown -= dt
        guard bubbleCountdown <= 0 else { return }
        let lines: [BubbleLine] = monitor.usages.compactMap { u in
            guard let w = u.windows.first(where: \.isWeekly) else { return nil }
            return BubbleLine(name: u.service == .claude ? "Claude" : "Codex", remaining: w.remaining)
        }
        if lines.isEmpty || panel.isShown || brain.mode == .held {
            bubbleCountdown = 30                       // 지금은 보여 줄 수 없으니 조금 뒤에 다시
            return
        }
        bubbleCountdown = TimeInterval(minutes * 60)
        bubble.show(BubbleContent(title: "주간 잔여", lines: lines), for: 6)
    }

    /// 펫이 짧은 말을 한다 (업데이트 알림 등).
    func say(_ message: String, for duration: TimeInterval = 8) {
        guard !isHidden, !panel.isShown else { return }
        bubble.show(BubbleContent(message: message), for: duration)
        render()
    }

    private func render() {
        let px = size / CGFloat(SpriteSheet.grid)
        // Retina 픽셀(0.5pt)에 맞춰 반올림
        func snap(_ v: CGFloat) -> CGFloat { (v * 2).rounded() / 2 }
        let origin = NSPoint(x: snap(brain.x - size / 2),
                             y: snap(brain.world.groundY + brain.y - SpriteSheet.footGap * px))
        if origin != shownOrigin {
            window.setFrameOrigin(origin)
            shownOrigin = origin
        }
        if bubble.isShown, let visible = (window.screen ?? NSScreen.screens.first)?.frame {
            bubble.place(centerX: brain.x, bottomY: origin.y + size - headTop * px + 1, within: visible)
        }
        let frame = brain.frame, right = brain.facing > 0
        if frame != shownFrame || right != shownFacingRight, let sheet {
            view.show(sheet[frame], facingRight: right)
            shownFrame = frame
            shownFacingRight = right
        }
    }

    private func resize(to newSize: CGFloat) {
        brain.scale = newSize / 96
        defer { rescanWorld() }
        window.setContentSize(NSSize(width: newSize, height: newSize))
        view.frame = NSRect(x: 0, y: 0, width: newSize, height: newSize)
        shownFrame = nil
        shownOrigin = NSPoint(x: -1, y: -1)
        render()
    }

    // MARK: - 입력

    func togglePanel() {
        if panel.isShown {
            panel.close()
            return
        }
        guard !isHidden else { return }
        bubble.hide(animated: false)
        monitor.refresh()
        monitor.fast = true
        brain.beginGreet()
        render()              // 패널을 펫의 최종 위치 기준으로 띄우기 위해 먼저 반영
        panel.show()
    }

    func drag(to mouse: NSPoint) {
        panel.close()
        bubble.hide(animated: false)
        // 몸통 가운데쯤을 잡고 있는 것처럼 보이게 한다
        brain.hold(x: mouse.x, height: mouse.y - brain.world.groundY - size * 0.3)
        render()
    }

    func endDrag() {
        brain.release()
    }

    func setHidden(_ hidden: Bool) {
        isHidden = hidden
        if hidden {
            panel.close()
            bubble.hide(animated: false)
            timer?.invalidate()
            timer = nil
            window.orderOut(nil)
        } else {
            window.orderFrontRegardless()
            start()
        }
        rescanWorld()               // 울타리도 같이 숨기거나 보인다
    }
}
