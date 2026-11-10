import AppKit
import ApplicationServices

/// 실제 화면에서 펫이 다닐 범위와 턱(Dock)을 찾아낸다.
enum WorldScanner {
    static func scan() -> World {
        // 메뉴 막대가 있는 기본 화면 기준
        guard let screen = NSScreen.screens.first else {
            return World(minX: 0, maxX: 1440, groundY: 0, ledges: [])
        }
        let f = screen.frame, v = screen.visibleFrame
        // Dock 이 좌우에 있으면 visibleFrame 이 그만큼 좁아지므로 그 범위 안에서만 다닌다
        var world = World(minX: v.minX, maxX: v.maxX, groundY: f.minY, ledges: [])

        // Dock 이 아래에 보이는 경우: 그 윗면이 펫이 뛰어오를 턱이 된다
        let inset = v.minY - f.minY
        if inset > 12 {
            let range = dockRangeViaAccessibility(on: f) ?? estimatedDockRange(on: f, thickness: inset)
            world.ledges.append(Ledge(minX: max(range.lowerBound, f.minX),
                                      maxX: min(range.upperBound, f.maxX),
                                      height: inset - 3))
        }
        return world
    }

    static var dockIsAtBottom: Bool {
        guard let s = NSScreen.screens.first else { return false }
        return s.visibleFrame.minY - s.frame.minY > 12
    }

    /// 손쉬운 사용 권한이 있으면 Dock 의 정확한 좌우 범위를 얻는다.
    private static func dockRangeViaAccessibility(on frame: CGRect) -> ClosedRange<CGFloat>? {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children) == .success,
              let list = (children as? [AXUIElement])?.first else { return nil }
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(list, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(list, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size), size.width > 40 else { return nil }
        return pos.x...(pos.x + size.width)
    }

    /// 권한이 없을 때: Dock 설정과 실행 중인 앱 수로 폭을 어림한다 (Dock 은 화면 가운데 정렬).
    private static func estimatedDockRange(on frame: CGRect, thickness: CGFloat) -> ClosedRange<CGFloat> {
        let d = UserDefaults(suiteName: "com.apple.dock")
        var tile = CGFloat(d?.double(forKey: "tilesize") ?? 0)
        if tile < 16 { tile = max(thickness - 22, 32) }
        let apps = d?.array(forKey: "persistent-apps") ?? []
        let others = d?.array(forKey: "persistent-others")?.count ?? 0
        let pinned = Set(apps.compactMap {
            (($0 as? [String: Any])?["tile-data"] as? [String: Any])?["bundle-identifier"] as? String
        })
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != "com.apple.finder"
                && !pinned.contains($0.bundleIdentifier ?? "")
        }.count
        let showRecents = d?.object(forKey: "show-recents") as? Bool ?? true
        let recents = showRecents ? min(d?.array(forKey: "recent-apps")?.count ?? 0, 3) : 0
        let extras = max(running, recents)
        let tiles = 1 + apps.count + extras + others + 1                 // Finder … 휴지통
        let separators = 1 + (extras > 0 ? 1 : 0)
        let width = min(CGFloat(tiles) * (tile + 4.5) + CGFloat(separators) * 13 + 16, frame.width - 20)
        return (frame.midX - width / 2)...(frame.midX + width / 2)
    }
}
