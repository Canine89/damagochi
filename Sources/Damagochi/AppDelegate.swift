import AppKit
import ApplicationServices
import Combine
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let monitor = AgentMonitor()
    private var pet: PetController!
    private var statusItem: NSStatusItem!
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        pet = PetController(monitor: monitor)
        pet.menuProvider = { [weak self] in self?.buildMenu() ?? NSMenu() }

        // 펫을 숨겨도 다시 불러올 수 있게 메뉴 막대에도 아이콘을 둔다
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusIcon()
        Settings.shared.$animal.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.updateStatusIcon()
        }.store(in: &bag)

        monitor.start()

        if CommandLine.arguments.contains("--test-panel") {
            // 검증용: 패널을 자동으로 열고 동물을 바꿨다가 되돌린다 (패널 위치가 유지되는지 확인)
            let original = Settings.shared.animal
            let other: Animal = original == .fox ? .rabbit : .fox
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.pet.togglePanel() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { Settings.shared.animal = other }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { Settings.shared.animal = original }
        }
    }

    private func updateStatusIcon() {
        statusItem.button?.image = pet.icon(points: 22)
        statusItem.button?.toolTip = "다마고치"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in buildMenu().items {
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let settings = Settings.shared

        if !pet.isHidden {
            menu.addItem(item("세션 · 사용량 보기") { [weak self] in self?.pet.togglePanel() })
            menu.addItem(.separator())
        }

        let animals = NSMenuItem(title: "동물", action: nil, keyEquivalent: "")
        animals.submenu = NSMenu()
        for a in Animal.allCases {
            let i = item(a.label) { settings.animal = a }
            i.state = settings.animal == a ? .on : .off
            animals.submenu?.addItem(i)
        }
        menu.addItem(animals)

        let sizes = NSMenuItem(title: "크기", action: nil, keyEquivalent: "")
        sizes.submenu = NSMenu()
        for s in Settings.sizes {
            let i = item("\(s)pt") { settings.size = s }
            i.state = settings.size == s ? .on : .off
            sizes.submenu?.addItem(i)
        }
        menu.addItem(sizes)

        menu.addItem(item(pet.isHidden ? "펫 보이기" : "펫 숨기기") { [weak self] in
            guard let pet = self?.pet else { return }
            pet.setHidden(!pet.isHidden)
        })

        let login = item("로그인 시 자동 실행") {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
            } catch {
                NSSound.beep()
            }
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        if WorldScanner.dockIsAtBottom, !AXIsProcessTrusted() {
            menu.addItem(item("Dock 위치 정확히 인식 (손쉬운 사용 권한)…") {
                let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            })
        }

        menu.addItem(.separator())
        menu.addItem(item("다마고치 종료") { NSApp.terminate(nil) })
        return menu
    }

    private func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let i = ClosureMenuItem(title: title, action: #selector(ClosureMenuItem.fire), keyEquivalent: "")
        i.target = i
        i.handler = action
        return i
    }
}

private final class ClosureMenuItem: NSMenuItem {
    var handler: (() -> Void)?

    @objc func fire() { handler?() }
}
