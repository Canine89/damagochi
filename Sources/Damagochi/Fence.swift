import AppKit

/// 울타리 한쪽 끝. 좌우로 끌어서 옮길 수 있다.
private final class FencePostView: NSView {
    weak var controller: FenceController?
    let isLeft: Bool
    private var grabOffset: CGFloat = 0

    init(frame: NSRect, image: CGImage?, isLeft: Bool) {
        self.isLeft = isLeft
        super.init(frame: frame)
        let l = CALayer()
        l.contents = image
        l.magnificationFilter = .nearest
        l.minificationFilter = .nearest
        l.contentsGravity = .resize
        layer = l
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        grabOffset = NSEvent.mouseLocation.x - (controller?.boundary(left: isLeft) ?? 0)
    }

    override func mouseDragged(with event: NSEvent) {
        controller?.move(left: isLeft, to: NSEvent.mouseLocation.x - grabOffset)
    }

    override func mouseUp(with event: NSEvent) {
        controller?.commit()
    }
}

/// 펫이 돌아다닐 범위를 정하는 울타리. 양 끝에 울타리 토막을 세우고, 펫은 그 사이에서만 움직인다.
final class FenceController {
    /// 울타리 위치가 바뀌었을 때 (끄는 중에도 계속 불린다)
    var onChange: (() -> Void)?

    private static let tile: CGFloat = 16            // 울타리 그림 한 변 (논리 px)
    private let panels: [NSPanel]
    private var world = World(minX: 0, maxX: 0, groundY: 0, ledges: [])
    private var px: CGFloat = 3
    private var minX: CGFloat = 0
    private var maxX: CGFloat = 0
    private var loaded = false
    private var visible = true

    init() {
        let image = SpriteSheet.resourceURL("fence")
            .flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        panels = [true, false].map { isLeft in
            let rect = NSRect(x: 0, y: 0, width: 48, height: 48)
            let p = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            // Dock 보다는 위, 펫보다는 아래
            p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.isMovable = false
            p.contentView = FencePostView(frame: rect, image: image, isLeft: isLeft)
            return p
        }
        for p in panels { (p.contentView as? FencePostView)?.controller = self }
    }

    /// 울타리가 켜져 있으면 펫이 다닐 수 있는 x 범위.
    var range: ClosedRange<CGFloat>? {
        Settings.shared.fenceEnabled && maxX > minX ? minX...maxX : nil
    }

    func boundary(left: Bool) -> CGFloat { left ? minX : maxX }

    /// 화면 상태가 바뀌었거나 켜고 끌 때: 울타리를 화면 안으로 맞추고 다시 세운다.
    func layout(in world: World, petSize: CGFloat, around petX: CGFloat, visible: Bool) {
        self.world = world
        self.visible = visible
        px = petSize / CGFloat(SpriteSheet.grid)
        guard Settings.shared.fenceEnabled else {
            panels.forEach { $0.orderOut(nil) }
            return
        }
        if !loaded {
            loaded = true
            let s = Settings.shared
            if s.fenceMax - s.fenceMin > 1 {
                minX = CGFloat(s.fenceMin)
                maxX = CGFloat(s.fenceMax)
            } else {                                  // 처음 켰을 때: 펫 주변에 친다
                minX = petX - 260
                maxX = petX + 260
            }
        }
        normalize(petSize: petSize)
        place()
        if Settings.shared.fenceMax - Settings.shared.fenceMin <= 1 { commit() }    // 처음 친 위치를 기억
    }

    func move(left: Bool, to x: CGFloat) {
        let gap = minGap
        if left { minX = min(x, maxX - gap) } else { maxX = max(x, minX + gap) }
        normalize(petSize: px * CGFloat(SpriteSheet.grid))
        place()
        onChange?()
    }

    func recenter(around petX: CGFloat) {
        minX = petX - 260
        maxX = petX + 260
        normalize(petSize: px * CGFloat(SpriteSheet.grid))
        place()
        commit()
        onChange?()
    }

    func commit() {
        Settings.shared.fenceMin = Double(minX)
        Settings.shared.fenceMax = Double(maxX)
    }

    /// 펫이 몸을 돌릴 수 있는 최소 폭
    private var minGap: CGFloat { px * CGFloat(SpriteSheet.grid) * 1.6 }

    private func normalize(petSize: CGFloat) {
        let post = FenceController.tile * px
        let lo = world.minX + post, hi = world.maxX - post
        let gap = min(minGap, max(hi - lo, 1))
        minX = max(lo, min(minX, hi - gap))
        maxX = min(hi, max(maxX, minX + gap))
    }

    private func place() {
        let side = FenceController.tile * px
        func snap(_ v: CGFloat) -> CGFloat { (v * 2).rounded() / 2 }
        for (panel, isLeft) in zip(panels, [true, false]) {
            // 울타리 토막은 범위 바깥쪽에 선다: 안쪽 가장자리가 곧 경계
            let x = isLeft ? minX - side : maxX
            let y = world.groundY + world.surface(at: x + side / 2)
            panel.setFrame(NSRect(x: snap(x), y: snap(y), width: side, height: side), display: true)
            if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        }
    }
}
