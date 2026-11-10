import AppKit
import Combine
import SwiftUI

/// 테두리 없는 패널도 키 입력·컨트롤 조작을 받을 수 있게 한다.
private final class KeyPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { onCancel?() }      // Esc
}

/// 펫 위에 뜨는 세션·사용량 패널.
/// NSPopover 대신 직접 만든 창이라 위치를 항상 화면 안으로 맞추고,
/// 바깥을 클릭하거나 다른 앱으로 넘어가면 확실하게 닫는다.
final class PanelController {
    var onClose: (() -> Void)?

    private let panel: KeyPanel
    private let host: NSHostingView<PanelView>
    private weak var petWindow: NSWindow?
    private var eventMonitors: [Any] = []
    private var workspaceObserver: NSObjectProtocol?
    private var bag = Set<AnyCancellable>()

    var isShown: Bool { panel.isVisible }

    init(monitor: AgentMonitor, petWindow: NSWindow) {
        self.petWindow = petWindow
        host = NSHostingView(rootView: PanelView(monitor: monitor))
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 300),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)   // 펫 창 바로 위
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.animationBehavior = .utilityWindow

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = PanelController.roundedMask(radius: 14)
        panel.contentView = effect
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)

        panel.onCancel = { [weak self] in self?.close() }

        // 내용(세션 수 등)이 바뀌면 크기가 달라지므로 다시 배치한다
        Publishers.Merge3(monitor.objectWillChange.map { _ in () },
                          Settings.shared.objectWillChange.map { _ in () },
                          Just(()))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                DispatchQueue.main.async { self?.layoutIfShown() }
            }
            .store(in: &bag)
    }

    func show() {
        guard !isShown else { return }
        layout()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        installDismissHandlers()
    }

    func close() {
        guard isShown else { return }
        removeDismissHandlers()
        panel.orderOut(nil)
        onClose?()
    }

    private func layoutIfShown() {
        if isShown { layout() }
    }

    /// 펫 머리 위 가운데에 두되, 화면 밖으로 나가지 않게 맞춘다.
    private func layout() {
        guard let pet = petWindow else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let visible = (pet.screen ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let margin: CGFloat = 8
        var x = pet.frame.midX - size.width / 2
        x = min(max(x, visible.minX + margin), visible.maxX - size.width - margin)
        var y = pet.frame.maxY - 2
        y = min(y, visible.maxY - size.height - margin)
        y = max(y, visible.minY + margin)
        let frame = NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
    }

    // MARK: - 닫힘 처리

    private func installDismissHandlers() {
        removeDismissHandlers()
        let mouseDown: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // 다른 앱의 창이나 바탕화면을 클릭
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mouseDown, handler: { [weak self] _ in
            self?.close()
        }) {
            eventMonitors.append(m)
        }
        // 우리 앱 안에서 패널 바깥을 클릭 (펫은 자기가 토글하므로 제외, 선택 메뉴 창도 제외)
        if let m = NSEvent.addLocalMonitorForEvents(matching: mouseDown, handler: { [weak self] event in
            guard let self, let w = event.window else { return event }
            if w !== self.panel, w !== self.petWindow, w.level.rawValue < NSWindow.Level.popUpMenu.rawValue {
                self.close()
            }
            return event
        }) {
            eventMonitors.append(m)
        }
        // 키보드(⌘Tab 등)로 다른 앱으로 넘어감
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.processIdentifier != ProcessInfo.processInfo.processIdentifier { self?.close() }
        }
    }

    private func removeDismissHandlers() {
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors.removeAll()
        if let o = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            workspaceObserver = nil
        }
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let d = radius * 2 + 1
        let image = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
