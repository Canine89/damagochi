import CoreGraphics
import Foundation

/// 펫이 올라설 수 있는 턱. 화면 바닥을 0으로 본 높이.
struct Ledge: Equatable {
    var minX: CGFloat
    var maxX: CGFloat
    var height: CGFloat
}

/// 펫이 돌아다니는 세계. x는 전역 화면 좌표, 높이는 바닥(groundY) 기준.
/// minX...maxX 는 화면 범위이거나, 울타리를 쳤다면 울타리 안쪽이다.
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
    case walk0, walk1, walk2, walk3
}

/// 펫의 성격: 얼마나 걷고, 뛰고, 점프하고, 자는지를 정한다. 속도는 96pt 크기 기준 pt/s.
struct Personality: Equatable {
    enum Kind: String, CaseIterable {
        case playful, stroller, sprinter, jumper, sleepy

        var label: String {
            switch self {
            case .playful: return "장난꾸러기"
            case .stroller: return "산책가"
            case .sprinter: return "달리기 선수"
            case .jumper: return "점프쟁이"
            case .sleepy: return "잠꾸러기"
            }
        }

        var summary: String {
            switch self {
            case .playful: return "걷다 뛰다 골고루"
            case .stroller: return "느긋하게 걸어 다님"
            case .sprinter: return "쉬지 않고 전력 질주"
            case .jumper: return "틈만 나면 폴짝"
            case .sleepy: return "조금 걷고 오래 잠"
            }
        }
    }

    var walkChance: Double                 // 이동할 때 뛰지 않고 걸을 확률
    var walkSpeed: ClosedRange<CGFloat>
    var runSpeed: ClosedRange<CGFloat>
    var rest: ClosedRange<Double>          // 이동 사이에 쉬는 시간(초)
    var napChance: Double                  // 쉬다가 잠들 확률
    var nap: ClosedRange<Double>
    var hopChance: Double                  // 쉬다가 제자리 점프할 확률
    var runHopRate: Double                 // 달리는 중 초당 장난 점프 확률
    var zoomiesChance: Double              // 쉬지 않고 연달아 달릴 확률

    static func of(_ kind: Kind) -> Personality {
        switch kind {
        case .playful:
            return Personality(walkChance: 0.35, walkSpeed: 55...85, runSpeed: 240...340, rest: 0.6...2.6,
                               napChance: 0.08, nap: 5...12, hopChance: 0.12, runHopRate: 0.3, zoomiesChance: 0.2)
        case .stroller:
            return Personality(walkChance: 0.9, walkSpeed: 40...70, runSpeed: 200...260, rest: 1.5...4.5,
                               napChance: 0.10, nap: 5...12, hopChance: 0.04, runHopRate: 0.05, zoomiesChance: 0)
        case .sprinter:
            return Personality(walkChance: 0.08, walkSpeed: 70...90, runSpeed: 330...440, rest: 0.3...1.4,
                               napChance: 0.03, nap: 4...8, hopChance: 0.06, runHopRate: 0.15, zoomiesChance: 0.5)
        case .jumper:
            return Personality(walkChance: 0.3, walkSpeed: 55...80, runSpeed: 230...320, rest: 0.5...2.0,
                               napChance: 0.05, nap: 5...10, hopChance: 0.45, runHopRate: 1.1, zoomiesChance: 0.15)
        case .sleepy:
            return Personality(walkChance: 0.75, walkSpeed: 35...60, runSpeed: 200...260, rest: 1.5...4.0,
                               napChance: 0.4, nap: 8...20, hopChance: 0.03, runHopRate: 0.03, zoomiesChance: 0)
        }
    }
}

/// 펫의 행동·물리. AppKit 에 의존하지 않아서 `--simulate` 로 화면 없이 검증할 수 있다.
final class PetBrain {
    enum Mode: String { case idle, walk, run, crouch, air, land, sleep, held, greet }

    var world: World
    /// 96pt 를 1로 본 크기 배율. 속도·중력이 몸 크기에 비례하도록 한다.
    var scale: CGFloat
    var personality: Personality
    /// 에이전트가 일하는 중이면 true: 덜 쉬고 덜 잔다.
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
    private var gait: Mode = .run                  // 지금 이동이 걷기인지 달리기인지
    private var modeTime: TimeInterval = 0
    private var modeDuration: TimeInterval = 0
    private var pendingVx: CGFloat = 0
    private var pendingVy: CGFloat = 0
    private var clock: TimeInterval = 0
    private var nextBlink: TimeInterval = 2
    private var zoomies = 0

    private var gravity: CGFloat { 1700 * scale }
    private var bodyHalf: CGFloat { 40 * scale }

    init(world: World, scale: CGFloat, personality: Personality = .of(.playful)) {
        self.world = world
        self.scale = scale
        self.personality = personality
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
        if mode != .held { clampX() }               // 울타리가 좁혀지면 안쪽으로 밀려 들어온다

        switch mode {
        case .idle, .sleep:
            settle()
            if mode == .idle || mode == .sleep, modeTime >= modeDuration {
                if mode == .sleep { enterIdle() } else { chooseNext() }
            }

        case .walk, .run:
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
            // 목적지를 지나치지 않게 딱 맞춰 선다. (지나치면 턱 모서리 근처에서 떨어졌다 올라오기를 반복한다)
            let step = dir * speed * CGFloat(dt)
            let arrived = (targetX - (x + step)) * dir <= 0
            x = arrived ? targetX : x + step
            let blocked = clampX()
            if world.surface(at: x) < y - 1 {                         // 턱 끝 → 폴짝 뛰어내림
                vx = dir * max(speed, 120 * scale)
                vy = 200 * scale
                enter(.air)
                break
            }
            if blocked || arrived {
                targetX = x
                enterIdle()
            } else if mode == .run, !ledgeAhead(dir: dir, within: 260 * scale),
                      Double.random(in: 0..<1) < personality.runHopRate * dt {   // 달리다가 장난 점프
                vx = dir * speed
                vy = 380 * scale
                enter(.air)
            }

        case .crouch:
            settle()
            if mode == .crouch, modeTime >= 0.08 {
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
                if abs(targetX - x) > 8 * scale { enter(gait) } else { enterIdle() }
            }

        case .held, .greet:
            break
        }
    }

    // MARK: - 바깥에서 거는 동작

    /// 클릭해서 패널을 연 동안: 제자리에서 반긴다.
    func beginGreet() {
        if mode == .air || mode == .held { y = world.surface(at: x) }
        clampX()
        let s = world.surface(at: x)
        if y != s { y = s }
        vx = 0
        vy = 0
        targetX = x
        zoomies = 0
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
        zoomies = 0
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
        case .walk:
            let fps = 4 + Double(speed / scale) / 14
            let cycle: [Frame] = [.walk0, .walk1, .walk2, .walk3]
            return cycle[Int(modeTime * fps) % 4]
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
            startMoving(forceRun: true)
            return
        }
        enter(.idle)
        let r = personality.rest
        modeDuration = .random(in: r) * (energetic ? 0.5 : 1)
    }

    private func land() {
        vy = 0
        enter(.land)
    }

    private func chooseNext() {
        let p = personality
        let nap = p.napChance * (energetic ? 0.25 : 1)
        let r = Double.random(in: 0..<1)
        if r < nap {
            enter(.sleep)
            modeDuration = .random(in: p.nap)
        } else if r < nap + p.hopChance {
            pendingVx = 0
            pendingVy = 420 * scale
            enter(.crouch)
        } else {
            if Double.random(in: 0..<1) < p.zoomiesChance { zoomies = Int.random(in: 1...3) }
            startMoving(forceRun: zoomies > 0)
        }
    }

    private func startMoving(forceRun: Bool) {
        let lo = world.minX + bodyHalf, hi = max(world.maxX - bodyHalf, lo + 1)
        let walking = !forceRun && Double.random(in: 0..<1) < personality.walkChance
        // 걸을 때는 가까운 곳, 달릴 때는 먼 곳을 고른다
        let wanted = (walking ? 60 : 140) * scale
        let reach = walking ? 320 * scale : CGFloat.greatestFiniteMagnitude
        var t = x
        for _ in 0..<10 {
            t = .random(in: max(lo, x - reach)...min(hi, x + reach))
            if abs(t - x) > min(wanted, (hi - lo) / 3) { break }
        }
        targetX = t
        gait = walking ? .walk : .run
        speed = .random(in: walking ? personality.walkSpeed : personality.runSpeed) * scale
        enter(gait)
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
    /// 수평 속도는 걷는 중이든 뛰는 중이든, 턱 모서리를 충분한 높이로 넘도록 거리에서 역산한다.
    private func ledgeJump(dir: CGFloat) -> (vx: CGFloat, vy: CGFloat)? {
        for l in world.ledges where l.height > y + 1 {
            let edge = dir > 0 ? l.minX : l.maxX
            let d = (edge - x) * dir
            guard d > 0, (targetX - edge) * dir > 0 else { continue }
            let h = l.height - y
            let v0 = (2 * gravity * (h + 24 * scale)).squareRoot()
            let root = (v0 * v0 - 2 * gravity * h).squareRoot()
            let t1 = (v0 - root) / gravity          // 올라가며 턱 높이에 닿는 시간
            let t2 = (v0 + root) / gravity          // 내려오며 턱 높이에 닿는 시간
            let launch = max(speed, 220 * scale) * t1 + bodyHalf
            guard d <= launch else { continue }
            let cross = t1 + 0.3 * (t2 - t1)        // 이때 모서리를 지나면 여유 있게 넘는다
            return (dir * d / cross, v0)
        }
        return nil
    }
}

// MARK: - 화면 없이 돌려보는 검증

enum Simulation {
    private struct Case {
        let name: String
        let world: World
        let kind: Personality.Kind
        let scale: CGFloat
        let mustClimb: Bool
    }

    static func run(seconds: Double = 300) -> Bool {
        let ledge = Ledge(minX: 415, maxX: 1055, height: 67)
        let open = World(minX: 0, maxX: 1470, groundY: 0, ledges: [ledge])
        let fenced = World(minX: 250, maxX: 760, groundY: 0, ledges: [ledge])      // 울타리 안에 Dock 일부
        let tight = World(minX: 600, maxX: 760, groundY: 0, ledges: [ledge])       // 아주 좁은 울타리
        var cases: [Case] = Personality.Kind.allCases.map {
            Case(name: $0.label, world: open, kind: $0, scale: 1, mustClimb: $0 != .sleepy && $0 != .stroller)
        }
        cases.append(Case(name: "장난꾸러기 64pt", world: open, kind: .playful, scale: 64.0 / 96, mustClimb: true))
        cases.append(Case(name: "울타리", world: fenced, kind: .playful, scale: 1, mustClimb: true))
        cases.append(Case(name: "좁은 울타리", world: tight, kind: .sprinter, scale: 1, mustClimb: false))

        var ok = true
        for c in cases {
            let brain = PetBrain(world: c.world, scale: c.scale, personality: .of(c.kind))
            var last = brain.mode
            var upJumps = 0, downHops = 0, maxY: CGFloat = 0
            var wasOnLedge = brain.y > 1
            var time: [PetBrain.Mode: Double] = [:]
            var bad = 0
            var t = 0.0
            let dt = 1.0 / 60
            while t < seconds {
                brain.tick(dt)
                t += dt
                time[brain.mode, default: 0] += dt
                maxY = max(maxY, brain.y)
                if brain.mode != last {
                    if brain.mode == .land {
                        let onLedge = brain.y > 1
                        if onLedge && !wasOnLedge { upJumps += 1 }
                        if !onLedge && wasOnLedge { downHops += 1 }
                        wasOnLedge = onLedge
                    }
                    last = brain.mode
                }
                // 항상 범위 안, 바닥 위. 지면 모드에서는 표면에 붙어 있어야 한다.
                var violated = brain.x < c.world.minX || brain.x > c.world.maxX || brain.y < -0.01
                if [.idle, .walk, .run, .land, .sleep].contains(brain.mode),
                   abs(brain.y - c.world.surface(at: brain.x)) > 1.01 { violated = true }
                if violated {
                    bad += 1
                    if bad <= 3 {
                        print("   위반 t=\(String(format: "%.2f", t)) mode=\(brain.mode.rawValue) x=\(Int(brain.x)) y=\(Int(brain.y))"
                              + " surface=\(Int(c.world.surface(at: brain.x)))")
                    }
                }
            }
            func pct(_ m: PetBrain.Mode) -> String { "\(Int((time[m, default: 0] / seconds * 100).rounded()))%" }
            let pass = bad == 0 && brain.wallHits == 0 && (!c.mustClimb || (upJumps > 0 && downHops > 0))
            if !pass { ok = false }
            print("\(pass ? "✓" : "✗") \(c.name): 걷기 \(pct(.walk)) · 달리기 \(pct(.run)) · 쉬기 \(pct(.idle)) · 잠 \(pct(.sleep)) · 공중 \(pct(.air)) · 웅크림 \(pct(.crouch))/\(pct(.land))"
                  + " · 턱 오르내림 \(upJumps)/\(downHops) · 최고 \(Int(maxY))pt · 옆면 충돌 \(brain.wallHits) · 위반 \(bad)")
        }
        print(ok ? "SIMULATION OK" : "SIMULATION FAILED")
        return ok
    }
}
