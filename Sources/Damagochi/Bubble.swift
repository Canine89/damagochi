import AppKit
import SwiftUI

/// 말풍선에 한 줄로 들어가는 서비스별 주간 잔여량.
struct BubbleLine: Equatable {
    let name: String
    let remaining: Double
}

/// 몸통과 꼬리를 한 덩어리로 그리는 말풍선 모양 (도트 그림과 어울리게 굵은 외곽선용).
private struct BubbleShape: Shape {
    var radius: CGFloat = 7
    var tail = CGSize(width: 10, height: 6)

    func path(in rect: CGRect) -> Path {
        let b = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - tail.height)
        var p = Path()
        p.move(to: CGPoint(x: b.minX + radius, y: b.minY))
        p.addLine(to: CGPoint(x: b.maxX - radius, y: b.minY))
        p.addArc(tangent1End: CGPoint(x: b.maxX, y: b.minY), tangent2End: CGPoint(x: b.maxX, y: b.minY + radius), radius: radius)
        p.addLine(to: CGPoint(x: b.maxX, y: b.maxY - radius))
        p.addArc(tangent1End: CGPoint(x: b.maxX, y: b.maxY), tangent2End: CGPoint(x: b.maxX - radius, y: b.maxY), radius: radius)
        p.addLine(to: CGPoint(x: b.midX + tail.width / 2, y: b.maxY))
        p.addLine(to: CGPoint(x: b.midX, y: rect.maxY))                 // 꼬리 끝
        p.addLine(to: CGPoint(x: b.midX - tail.width / 2, y: b.maxY))
        p.addLine(to: CGPoint(x: b.minX + radius, y: b.maxY))
        p.addArc(tangent1End: CGPoint(x: b.minX, y: b.maxY), tangent2End: CGPoint(x: b.minX, y: b.maxY - radius), radius: radius)
        p.addLine(to: CGPoint(x: b.minX, y: b.minY + radius))
        p.addArc(tangent1End: CGPoint(x: b.minX, y: b.minY), tangent2End: CGPoint(x: b.minX + radius, y: b.minY), radius: radius)
        p.closeSubpath()
        return p
    }
}

/// 말풍선 내용: 제목 + 서비스별 잔여량 줄들, 또는 짧은 메시지.
struct BubbleContent: Equatable {
    var title: String?
    var lines: [BubbleLine] = []
    var message: String?

    var isEmpty: Bool { lines.isEmpty && (message ?? "").isEmpty }
}

struct BubbleView: View {
    let content: BubbleContent

    // 말풍선은 항상 흰 바탕이라 다크 모드와 무관하게 고정 색을 쓴다
    private let ink = Color(red: 0.14, green: 0.11, blue: 0.12)
    private let tailHeight: CGFloat = 6

    private func color(_ remaining: Double) -> Color {
        remaining >= 50 ? Color(red: 0.20, green: 0.66, blue: 0.33)
            : remaining >= 20 ? Color(red: 0.90, green: 0.62, blue: 0.10)
            : Color(red: 0.86, green: 0.24, blue: 0.22)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title = content.title {
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(ink.opacity(0.55))
            }
            if let message = content.message {
                Text(message).font(.system(size: 11, weight: .medium)).foregroundColor(ink)
            }
            ForEach(content.lines, id: \.name) { line in
                HStack(spacing: 4) {
                    Circle().fill(color(line.remaining)).frame(width: 6, height: 6)
                    Text(line.name).font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 8)
                    Text("\(Int(line.remaining.rounded()))%").font(.system(size: 11, weight: .bold).monospacedDigit())
                }
                .foregroundColor(ink)
            }
        }
        .padding(.horizontal, 9)
        .padding(.top, 6)
        .padding(.bottom, 6 + tailHeight)
        .background(BubbleShape().fill(Color.white))
        .overlay(BubbleShape().stroke(ink, style: StrokeStyle(lineWidth: 2, lineJoin: .round)))
        .padding(2)                 // 외곽선이 창 가장자리에서 잘리지 않게
        .fixedSize()
    }
}

/// 펫 머리 위에 잠깐 떴다 사라지는 말풍선 창. 클릭은 그대로 통과시킨다.
final class BubbleController {
    private let panel: NSPanel
    private let host: NSHostingView<BubbleView>
    private var hideWork: DispatchWorkItem?

    private(set) var isShown = false

    init() {
        host = NSHostingView(rootView: BubbleView(content: BubbleContent()))
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 50),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.contentView = host
    }

    func show(_ content: BubbleContent, for duration: TimeInterval) {
        guard !content.isEmpty else { return }
        hideWork?.cancel()
        host.rootView = BubbleView(content: content)
        host.layoutSubtreeIfNeeded()
        panel.setContentSize(host.fittingSize)
        if !isShown {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        isShown = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func hide(animated: Bool = true) {
        guard isShown else { return }
        hideWork?.cancel()
        hideWork = nil
        isShown = false
        guard animated else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.isShown else { return }     // 그 사이 다시 떴으면 그대로 둔다
            self.panel.orderOut(nil)
        })
    }

    /// 꼬리 끝이 (centerX, bottomY)를 가리키도록 놓되 화면 밖으로 나가지 않게 한다.
    func place(centerX: CGFloat, bottomY: CGFloat, within visible: NSRect) {
        guard isShown else { return }
        let size = panel.frame.size
        var x = centerX - size.width / 2
        x = min(max(x, visible.minX + 2), visible.maxX - size.width - 2)
        let y = min(bottomY, visible.maxY - size.height - 2)
        let origin = NSPoint(x: (x * 2).rounded() / 2, y: (y * 2).rounded() / 2)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }
}
