import CoreGraphics
import Foundation

/// 펫이 올라설 수 있는 턱. 화면 바닥을 0으로 본 높이.
struct Ledge: Equatable {
    var minX: CGFloat
    var maxX: CGFloat
    var height: CGFloat
}

/// 펫이 돌아다니는 세계. x는 전역 화면 좌표, 높이는 바닥(groundY) 기준.
struct World: Equatable {
    var minX: CGFloat
    var maxX: CGFloat
    var groundY: CGFloat
    var ledges: [Ledge]

    func surface(at x: CGFloat) -> CGFloat {
        var h: CGFloat = 0
        for l in ledges where x >= l.minX && x <= l.maxX { h = max(h, l.height) }
        return h
    }
}

/// 스프라이트 시트의 프레임 순서. art/animals.py 의 FRAMES 와 일치해야 한다.
enum Frame: Int, CaseIterable {
    case idle0, idle1, blink, run0, run1, run2, run3, crouch, rise, fall, happy, sleep
}

/// 펫의 행동·물리. AppKit 에 의존하지 않아서 `--simulate` 로 화면 없이 검증할 수 있다.
final class PetBrain {
    enum Mode: String { case idle, run, crouch, air, land, sleep, held, greet }

    var world: World
    /// 96pt 를 1로 본 크기 배율. 속도·중력이 몸 크기에 비례하도록 한다.
    var scale: CGFloat
    /// 에이전트가 일하는 중이면 true: 덜 쉬고 더 뛰어다닌다.
    var energetic = false

    private(set) var mode: Mode = .idle
    private(set) var x: CGFloat
    private(set) var y: CGFloat = 0
    private(set) var facing: CGFloat = -1          // -1 왼쪽, +1 오른쪽
    private(set) var wallHits = 0                  // 턱 옆면에 부딪힌 횟수 (검증용)

    private var vx: CGFloat = 0
    private var vy: CGFloat = 0
    private var targetX: CGFloat
    private var speed: CGFloat = 0
    private var modeTime: TimeInterval = 0
    private var modeDuration: TimeInterval = 0
    private var pendingVx: CGFloat = 0
    private var pendingVy: CGFloat = 0
    private var clock: TimeInterval = 0
    private var nextBlink: TimeInterval = 2
    private var zoomies = 0

    private var gravity: CGFloat { 1700 * scale }
    private var bodyHalf: CGFloat { 40 * scale }

    init(world: World, scale: CGFloat) {
        self.world = world
        self.scale = scale
        let lo = world.minX + 40 * scale, hi = max(world.maxX - 40 * scale, world.minX + 41 * scale)
        x = CGFloat.random(in: lo...hi)
        targetX = x
        y = world.surface(at: x)
        enterIdle()
    }

    // MARK: - 매 프레임

    func tick(_ rawDt: TimeInterval) {
        let dt = min(max(rawDt, 0), 0.05)
        clock += dt
        modeTime += dt

        switch mode {
        case .idle, .sleep:
            settle()
            if mode == .idle || mode == .sleep, modeTime >= modeDuration {
                if mode == .sleep { enterIdle() } else { chooseNext() }
            }

        case .run:
            let s = world.surface(at: x)
            if y < s { y = s }
            if y > s + 1 { vx = 0; vy = 0; enter(.air); break }      // 딛고 있던 턱이 사라짐
            let dir: CGFloat = targetX >= x ? 1 : -1
            facing = dir
            if let jump = ledgeJump(dir: dir) {                        // 앞에 턱 → 웅크렸다가 점프
                pendingVx = jump.vx
                pendingVy = jump.vy
                enter(.crouch)
                break
            }
            x += dir * speed * CGFloat(dt)
            clampX()
            if world.surface(at: x) < y - 1 {                         // 턱 끝 → 폴짝 뛰어내림
                vx = dir * speed
                vy = 200 * scale
                enter(.air)
                break
            }
            if (targetX - x) * dir <= 0 {
                enterIdle()
            } else if !ledgeAhead(dir: dir, within: 260 * scale), Double.random(in: 0..<1) < 0.3 * dt {   // 달리다가 장난 점프
                vx = dir * speed
                vy = 380 * scale
                enter(.air)
            }

        case .crouch:
            settle()
            if modeTime >= 0.08 {
                vx = pendingVx
                vy = pendingVy
                enter(.air)
            }

        case .air:
            let prevX = x, prevY = y
            vy -= gravity * CGFloat(dt)
            x += vx * CGFloat(dt)
            y += vy * CGFloat(dt)
            if clampX() { vx = 0 }
            guard vy <= 0 else { break }
            let s = world.surface(at: x)
            if y <= s {
                if prevY >= s - 2 || s == world.surface(at: prevX) {
                    y = s
                    land()
                } else {
                    // 턱 윗면보다 낮은 높이에서 옆으로 들어옴 → 옆면에 막힌 것으로 처리
                    wallHits += 1
                    x = prevX
                    vx = 0
                    let s0 = world.surface(at: x)
                    if y <= s0 { y = s0; land() }
                }
            }

        case .land:
            if modeTime >= 0.09 {
                if abs(targetX - x) > 8 * scale { enter(.run) } else { enterIdle() }
            }

        case .held, .greet:
            break
        }
    }

    // MARK: - 바깥에서 거는 동작

    /// 클릭해서 패널을 연 동안: 제자리에서 반긴다.
    func beginGreet() {
        if mode == .air || mode == .held { y = world.surface(at: x) }
        settle()
        vx = 0
        vy = 0
        targetX = x
        enter(.greet)
    }

    func endGreet() {
        if mode == .greet { enterIdle() }
    }

    /// 마우스로 집어 올림. height 는 바닥 기준.
    func hold(x newX: CGFloat, height: CGFloat) {
        if mode != .held { enter(.held) }
        x = newX
        clampX()
        y = max(height, 0)
    }

    func release() {
        guard mode == .held else { return }
        vx = 0
        vy = 0
        targetX = x
        if y < world.surface(at: x) { y = world.surface(at: x) }
        enter(.air)
    }

    // MARK: - 현재 프레임

    var frame: Frame {
        switch mode {
        case .idle:
            if clock >= nextBlink {
                if clock < nextBlink + 0.13 { return .blink }
                nextBlink = clock + .random(in: 2.5...5.5)
            }
            return Int(clock / 0.45) % 2 == 0 ? .idle0 : .idle1
        case .run:
            let fps = 9 + Double(speed / scale) / 36
            let cycle: [Frame] = [.run0, .run1, .run2, .run3]
            return cycle[Int(modeTime * fps) % 4]
        case .crouch, .land:
            return .crouch
        case .air:
            return vy > 30 * scale ? .rise : .fall
        case .held:
            return .fall
        case .sleep:
            return .sleep
        case .greet:
            return Int(modeTime / 0.32) % 2 == 0 ? .happy : .idle0
        }
    }

    // MARK: - 내부

    private func enter(_ m: Mode) {
        mode = m
        modeTime = 0
    }

    private func enterIdle() {
        if zoomies > 0 {            // 연속 질주 중이면 쉬지 않고 바로 다음 목적지로
            zoomies -= 1
            startRun()
            return
        }
        enter(.idle)
        modeDuration = energetic ? .random(in: 0.3...1.3) : .random(in: 0.6...2.6)
    }

    private func land() {
        vy = 0
        enter(.land)
    }

    private func chooseNext() {
        let r = Double.random(in: 0..<1)
        if r < (energetic ? 0.02 : 0.10) {
            enter(.sleep)
            modeDuration = .random(in: 5...12)
        } else if r < 0.22 {
            pendingVx = 0
            pendingVy = 420 * scale
            enter(.crouch)
        } else {
            if r > 0.8 { zoomies = Int.random(in: 1...3) }
            startRun()
        }
    }

    private func startRun() {
        let lo = world.minX + bodyHalf, hi = max(world.maxX - bodyHalf, lo + 1)
        var t = x
        for _ in 0..<8 {
            t = .random(in: lo...hi)
            if abs(t - x) > 140 * scale { break }
        }
        targetX = t
        speed = .random(in: 240...340) * scale
        enter(.run)
    }

    /// 지면에 있을 때 턱이 생기거나 사라진 경우 높이를 맞춘다.
    private func settle() {
        let s = world.surface(at: x)
        if y < s {
            y = s
        } else if y > s + 1 {
            vx = 0
            vy = 0
            enter(.air)
        }
    }

    @discardableResult
    private func clampX() -> Bool {
        let lo = world.minX + bodyHalf, hi = max(world.maxX - bodyHalf, lo + 1)
        if x < lo { x = lo; return true }
        if x > hi { x = hi; return true }
        return false
    }

    /// 진행 방향으로 가까운 곳에 지금 높이보다 높은 턱이 있는지 (옆면에 부딪히는 점프를 피하려고).
    private func ledgeAhead(dir: CGFloat, within distance: CGFloat) -> Bool {
        world.ledges.contains { l in
            guard l.height > y + 1 else { return false }
            let d = ((dir > 0 ? l.minX : l.maxX) - x) * dir
            return d > 0 && d < distance
        }
    }

    /// 진행 방향 앞에 올라가야 할 턱이 있고, 지금이 뛸 타이밍이면 점프 속도를 돌려준다.
    private func ledgeJump(dir: CGFloat) -> (vx: CGFloat, vy: CGFloat)? {
        for l in world.ledges where l.height > y + 1 {
            let edge = dir > 0 ? l.minX : l.maxX
            let d = (edge - x) * dir
            guard d > 0, (targetX - edge) * dir > 0 else { continue }
            let h = l.height - y
            let v0 = (2 * gravity * (h + 24 * scale)).squareRoot()
            // 턱 높이 h 에 처음 도달하는 시간
            let t1 = (v0 - (v0 * v0 - 2 * gravity * h).squareRoot()) / gravity
            let launch = speed * t1 + bodyHalf
            guard d <= launch else { continue }
            // 너무 가까이에서 출발하면 수평 속도를 줄여서 옆면에 부딪히지 않게 한다
            return (dir * min(speed, d / (t1 + 0.02)), v0)
        }
        return nil
    }
}

// MARK: - 화면 없이 돌려보는 검증

enum Simulation {
    static func run(seconds: Double = 240) -> Bool {
        let ledge = Ledge(minX: 415, maxX: 1055, height: 67)
        var ok = true
        for scale in [CGFloat(64) / 96, 1] {
            let world = World(minX: 0, maxX: 1470, groundY: 0, ledges: [ledge])
            let brain = PetBrain(world: world, scale: scale)
            brain.energetic = true
            var last = brain.mode
            var upJumps = 0, downHops = 0, landings = 0, maxY: CGFloat = 0, minY: CGFloat = 0
            var wasOnLedge = brain.y > 1
            var t = 0.0
            let dt = 1.0 / 60
            var counts: [PetBrain.Mode: Int] = [:]
            while t < seconds {
                brain.tick(dt)
                t += dt
                maxY = max(maxY, brain.y)
                minY = min(minY, brain.y)
                if brain.mode != last {
                    counts[brain.mode, default: 0] += 1
                    if brain.mode == .land {
                        landings += 1
                        let onLedge = brain.y > 1
                        if onLedge && !wasOnLedge { upJumps += 1 }
                        if !onLedge && wasOnLedge { downHops += 1 }
                        wasOnLedge = onLedge
                    }
                    last = brain.mode
                }
                if brain.x < world.minX || brain.x > world.maxX || brain.y < -0.01 { ok = false }
                // 지면 모드에서는 반드시 표면 위에 있어야 한다
                if [.idle, .run, .land, .sleep].contains(brain.mode),
                   abs(brain.y - world.surface(at: brain.x)) > 1.01 { ok = false }
            }
            let summary = counts.sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: " ")
            print("""
            [scale \(String(format: "%.2f", Double(scale)))] \(Int(seconds))s  턱 오르기 \(upJumps)회 · 내려오기 \(downHops)회 · 착지 \(landings)회 · 옆면 충돌 \(brain.wallHits)회
              최고 높이 \(Int(maxY))pt (턱 \(Int(ledge.height))pt) · 모드 전환: \(summary)
            """)
            if upJumps == 0 || downHops == 0 || brain.wallHits > 0 { ok = false }
        }
        print(ok ? "SIMULATION OK" : "SIMULATION FAILED")
        return ok
    }
}
