import AppKit
import ApplicationServices
import Combine
import ServiceManagement
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let monitor = AgentMonitor()
    private var pet: PetController!
    private var statusItem: NSStatusItem!
    private var bag = Set<AnyCancellable>()

    // 메뉴 막대에서 숨 쉬고 눈을 깜빡이는 작은 펫
    private var barImages: [Frame: NSImage] = [:]
    private var barTimer: Timer?
    private var barTick = 0
    private var barNextBlink = 20
    private var barShown: Frame?

    // 자동 업데이트 (Sparkle). 배포용 번들에서만 켜진다.
    private var updater: SPUStandardUpdaterController?
    private var pendingUpdate: String?          // 알려 줬지만 아직 설치하지 않은 새 버전

    func applicationDidFinishLaunching(_ notification: Notification) {
        pet = PetController(monitor: monitor)
        pet.menuProvider = { [weak self] in self?.buildMenu() ?? NSMenu() }

        // 펫을 숨겨도 다시 불러올 수 있게 메뉴 막대에도 아이콘을 둔다
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.toolTip = "다마고치"
        loadBarImages()
        Settings.shared.$animal.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.loadBarImages()
        }.store(in: &bag)
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in self?.tickBar() }
        RunLoop.main.add(timer, forMode: .common)
        barTimer = timer

        monitor.start()

        // 업데이트 주소가 들어 있는 번들(scripts/build-app.sh 로 만든 앱)에서만 업데이트를 확인한다
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        }

        if CommandLine.arguments.contains("--test-panel") {
            // 검증용: 패널을 자동으로 열고 동물을 바꿨다가 되돌린다 (패널 위치가 유지되는지 확인)
            let original = Settings.shared.animal
            let other: Animal = original == .fox ? .rabbit : .fox
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.pet.togglePanel() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { Settings.shared.animal = other }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { Settings.shared.animal = original }
        }
    }

    private func loadBarImages() {
        let height = NSStatusBar.system.thickness
        barImages = SpriteSheet(animal: Settings.shared.animal)?
            .barImages([.idle0, .idle1, .blink], maxHeight: height) ?? [:]
        barShown = nil
        tickBar()
    }

    /// 0.15초마다: 0.45초 간격으로 숨 쉬듯 오르내리고, 가끔 한 번씩 눈을 깜빡인다.
    private func tickBar() {
        barTick += 1
        var frame: Frame = (barTick / 3) % 2 == 0 ? .idle0 : .idle1
        if barTick >= barNextBlink, frame == .idle1 {       // 깜빡임 그림은 idle1 과 같은 자세
            frame = .blink
            barNextBlink = barTick + Int.random(in: 18...40)
        }
        guard frame != barShown, let image = barImages[frame] else { return }
        statusItem.button?.image = image
        barShown = frame
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

        // 성격: 동물마다 무작위로 정해져 있고, 바꾸거나 다시 뽑을 수 있다
        let current = settings.personality(for: settings.animal)
        let personality = NSMenuItem(title: "성격: \(current.label)", action: nil, keyEquivalent: "")
        personality.submenu = NSMenu()
        for kind in Personality.Kind.allCases {
            let i = item("\(kind.label) — \(kind.summary)") { settings.setPersonality(kind, for: settings.animal) }
            i.state = kind == current ? .on : .off
            personality.submenu?.addItem(i)
        }
        personality.submenu?.addItem(.separator())
        personality.submenu?.addItem(item("무작위로 다시 뽑기") { settings.rollPersonality(for: settings.animal) })
        menu.addItem(personality)

        // 울타리: 켜면 양 끝에 울타리가 서고, 끌어서 범위를 정한다
        let fence = NSMenuItem(title: "울타리", action: nil, keyEquivalent: "")
        fence.submenu = NSMenu()
        let fenceOn = item("울타리 안에서만 놀기") { settings.fenceEnabled.toggle() }
        fenceOn.state = settings.fenceEnabled ? .on : .off
        fence.submenu?.addItem(fenceOn)
        if settings.fenceEnabled {
            fence.submenu?.addItem(item("펫 주변으로 다시 치기") { [weak self] in self?.pet.recenterFence() })
            let hint = NSMenuItem(title: "울타리를 좌우로 끌어서 옮길 수 있어요", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            fence.submenu?.addItem(hint)
        }
        menu.addItem(fence)

        // 사용량 말풍선 주기
        let bubble = NSMenuItem(title: "사용량 말풍선", action: nil, keyEquivalent: "")
        bubble.submenu = NSMenu()
        for minutes in Settings.bubbleIntervals {
            let title = minutes == 0 ? "끄기" : minutes < 60 ? "\(minutes)분마다" : "\(minutes / 60)시간마다"
            let i = item(title) { settings.bubbleMinutes = minutes }
            i.state = settings.bubbleMinutes == minutes ? .on : .off
            bubble.submenu?.addItem(i)
        }
        menu.addItem(bubble)

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

        if let updater {
            let title = pendingUpdate.map { "새 버전 \($0) 설치…" } ?? "업데이트 확인…"
            menu.addItem(item(title) { updater.checkForUpdates(nil) })
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

// MARK: - 업데이트 알림

/// 예약된 확인에서 새 버전을 찾으면, 작업 중인 화면 위로 창을 띄우는 대신 펫이 말풍선으로 알려 준다.
/// 메뉴의 "새 버전 설치…"를 누르면 Sparkle 의 업데이트 창이 열린다.
extension AppDelegate: SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        // 방금 실행해서 바로 보여 줘도 되는 상황이면 Sparkle 창, 아니면 말풍선으로
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        pendingUpdate = update.displayVersionString
        pet.say("새 버전 \(update.displayVersionString)이 나왔어요!\n메뉴에서 설치할 수 있어요", for: 12)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        pendingUpdate = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        pendingUpdate = nil
    }
}

private final class ClosureMenuItem: NSMenuItem {
    var handler: (() -> Void)?

    @objc func fire() { handler?() }
}
