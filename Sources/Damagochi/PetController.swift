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
    private var bag = Set<AnyCancellable>()

    private(set) var isHidden = false
    private var size: CGFloat { CGFloat(Settings.shared.size) }

    init(monitor: AgentMonitor) {
        self.monitor = monitor
        let s = CGFloat(Settings.shared.size)
        let rect = NSRect(x: 0, y: 0, width: s, height: s)
        window = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        view = PetView(frame: rect)
        brain = PetBrain(world: WorldScanner.scan(), scale: s / 96)
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

        Settings.shared.$animal.dropFirst().sink { [weak self] animal in
            self?.sheet = SpriteSheet(animal: animal)
            self?.shownFrame = nil
        }.store(in: &bag)
        Settings.shared.$size.dropFirst().sink { [weak self] newSize in
            self?.resize(to: CGFloat(newSize))
        }.store(in: &bag)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.brain.world = WorldScanner.scan()
        }

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
            brain.world = WorldScanner.scan()
        }
        brain.energetic = monitor.busyCount > 0
        brain.tick(dt)
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
        let frame = brain.frame, right = brain.facing > 0
        if frame != shownFrame || right != shownFacingRight, let sheet {
            view.show(sheet[frame], facingRight: right)
            shownFrame = frame
            shownFacingRight = right
        }
    }

    private func resize(to newSize: CGFloat) {
        brain.scale = newSize / 96
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
        monitor.refresh()
        monitor.fast = true
        brain.beginGreet()
        render()              // 패널을 펫의 최종 위치 기준으로 띄우기 위해 먼저 반영
        panel.show()
    }

    func drag(to mouse: NSPoint) {
        panel.close()
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
            timer?.invalidate()
            timer = nil
            window.orderOut(nil)
        } else {
            window.orderFrontRegardless()
            start()
        }
    }

    /// 메뉴 막대 아이콘 등에 쓸 현재 동물의 정지 그림
    func icon(points: CGFloat) -> NSImage? {
        sheet?.image(.idle0, points: points)
    }
}
