import Foundation

enum Service: String, CaseIterable {
    case claude = "Claude Code"
    case codex = "Codex"
}

struct AgentSession: Identifiable, Equatable {
    enum Status: Equatable {
        case busy, idle, other(String)

        var label: String {
            switch self {
            case .busy: return "작업 중"
            case .idle: return "대기 중"
            case .other(let s): return s
            }
        }
    }

    let id: String
    let service: Service
    let title: String
    let cwd: String
    let status: Status
    let detail: String
    let startedAt: Date?
    let updatedAt: Date?
}

struct UsageWindow: Identifiable, Equatable {
    let label: String
    let usedPercent: Double
    let resetsAt: Date?

    static let weeklyLabel = "주간"

    var id: String { label }
    var isWeekly: Bool { label == UsageWindow.weeklyLabel }
    var remaining: Double { min(100, max(0, 100 - usedPercent)) }
}

struct ServiceUsage: Identifiable, Equatable {
    let service: Service
    var windows: [UsageWindow] = []
    var plan: String?
    var updatedAt: Date?
    var note: String?

    var id: String { service.rawValue }
}

private let home = FileManager.default.homeDirectoryForCurrentUser

private func json(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func date(fromEpoch v: Any?) -> Date? {
    guard let n = (v as? NSNumber)?.doubleValue, n > 0 else {
        guard let s = v as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
    return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)     // ms 단위도 허용
}

// MARK: - Claude Code

enum ClaudeProvider {
    /// statusline 훅이 남기는 파일 (README 참고)
    static let usageFile = home.appendingPathComponent("Library/Application Support/Damagochi/claude-usage.json")

    /// ~/.claude/sessions/<pid>.json 중 프로세스가 살아 있는 것.
    static func sessions() -> [AgentSession] {
        let dir = home.appendingPathComponent(".claude/sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out: [AgentSession] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f), let o = json(data),
                  let pid = (o["pid"] as? NSNumber)?.int32Value, ProcScan.isAlive(pid) else { continue }
            // pid 재사용 방지: 엉뚱한 프로세스면 건너뜀
            if let path = ProcScan.path(of: pid)?.lowercased(),
               !["claude", "node", "bun"].contains(where: path.contains) { continue }
            let cwd = o["cwd"] as? String ?? ""
            let raw = o["status"] as? String ?? ""
            let status: AgentSession.Status = raw == "busy" ? .busy : raw == "idle" ? .idle : .other(raw.isEmpty ? "실행 중" : raw)
            out.append(AgentSession(
                id: "claude-\(pid)",
                service: .claude,
                title: cwd.isEmpty ? (o["name"] as? String ?? "세션") : (cwd as NSString).lastPathComponent,
                cwd: cwd,
                status: status,
                detail: "pid \(pid)",
                startedAt: date(fromEpoch: o["startedAt"]),
                updatedAt: date(fromEpoch: o["statusUpdatedAt"] ?? o["updatedAt"])))
        }
        return out.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    static func usage() -> ServiceUsage {
        var u = ServiceUsage(service: .claude)
        guard let data = try? Data(contentsOf: usageFile), let o = json(data),
              let limits = o["rate_limits"] as? [String: Any] else {
            u.note = "statusline 연동을 설정하면 표시돼요 (README 참고)"
            return u
        }
        let names: [(String, String)] = [("seven_day", "주간"), ("five_hour", "5시간")]
        var seen = Set<String>()
        for (key, label) in names {
            if let w = window(limits[key], label: label) { u.windows.append(w); seen.insert(key) }
        }
        for key in limits.keys.sorted() where !seen.contains(key) && !names.contains(where: { $0.0 == key }) {
            if let w = window(limits[key], label: key.replacingOccurrences(of: "_", with: " ")) { u.windows.append(w) }
        }
        // 번들된 훅은 statusline 입력 JSON 을 그대로 저장하므로 updated_at 이 없다 → 파일 수정 시각 사용
        u.updatedAt = date(fromEpoch: o["updated_at"])
            ?? (try? FileManager.default.attributesOfItem(atPath: usageFile.path)[.modificationDate]) as? Date
        if u.windows.isEmpty { u.note = "한도 정보가 아직 없어요" }
        return u
    }

    private static func window(_ v: Any?, label: String) -> UsageWindow? {
        guard let o = v as? [String: Any], let used = (o["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
        return UsageWindow(label: label, usedPercent: used, resetsAt: date(fromEpoch: o["resets_at"]))
    }
}

// MARK: - Codex

enum CodexProvider {
    private static let sessionsDir = home.appendingPathComponent(".codex/sessions")

    /// codex 프로세스가 지금 열어 둔 세션 로그(rollout) 파일들.
    static func openRollouts() -> [String] {
        var set = Set<String>()
        for pid in ProcScan.pids(executableNamed: "codex") {
            for p in ProcScan.openFiles(of: pid) where p.hasSuffix(".jsonl") && p.contains("/rollout-") {
                set.insert(p)
            }
        }
        return Array(set)
    }

    private struct Meta {
        let id: String
        let cwd: String
        let isUser: Bool
        let originator: String
        let started: Date?
    }

    private static var metaCache: [String: Meta] = [:]
    private static let metaLock = NSLock()

    /// rollout 첫 줄(session_meta). 한 번 쓰이면 바뀌지 않으므로 캐시한다.
    private static func meta(_ path: String) -> Meta? {
        metaLock.lock()
        defer { metaLock.unlock() }
        if let m = metaCache[path] { return m }
        guard let o = firstLine(path).flatMap(json), let p = o["payload"] as? [String: Any] else { return nil }
        let m = Meta(id: p["id"] as? String ?? path,
                     cwd: p["cwd"] as? String ?? "",
                     isUser: (p["thread_source"] as? String ?? "user") == "user",   // 하위 에이전트 스레드 제외용
                     originator: p["originator"] as? String ?? "",
                     started: date(fromEpoch: p["timestamp"]))
        metaCache[path] = m
        return m
    }

    /// 실행 중인 Codex 세션.
    /// 1) 터미널에서 돌고 있는 codex 프로세스(작업 폴더로 최근 세션 로그와 짝지음)
    /// 2) 그 밖에 codex 가 열어 둔 사용자 스레드(데스크톱 앱 등)
    static func sessions(openRollouts: [String]) -> [AgentSession] {
        let recent = recentRollouts(days: 10, limit: 300)
        var out: [AgentSession] = []
        var claimed = Set<String>()
        let servers: Set<String> = ["app-server", "exec-server", "mcp-server", "daemon"]

        for pid in ProcScan.pids(executableNamed: "codex") {
            let args = ProcScan.arguments(of: pid).dropFirst()
            if args.contains(where: servers.contains) { continue }
            guard ProcScan.hasTTY(pid) || args.contains("exec"), let cwd = ProcScan.cwd(of: pid) else { continue }
            let match = recent.first { r in meta(r.path).map { $0.isUser && $0.cwd == cwd } ?? false }
            claimed.insert(cwd)
            out.append(AgentSession(
                id: "codex-pid-\(pid)",
                service: .codex,
                title: (cwd as NSString).lastPathComponent,
                cwd: cwd,
                status: match.map { status($0.path, mtime: $0.mtime) } ?? .other("실행 중"),
                detail: "pid \(pid)",
                startedAt: nil,
                updatedAt: match?.mtime))
        }

        for path in openRollouts {
            guard let m = meta(path), m.isUser, !claimed.contains(m.cwd) else { continue }
            let mtime = modified(path)
            let kind = m.originator.contains("tui") ? "CLI" : m.originator.lowercased().contains("desktop") ? "데스크톱" : m.originator
            out.append(AgentSession(
                id: "codex-" + m.id,
                service: .codex,
                title: m.cwd.isEmpty ? "세션" : (m.cwd as NSString).lastPathComponent,
                cwd: m.cwd,
                status: status(path, mtime: mtime),
                detail: kind,
                startedAt: m.started,
                updatedAt: mtime))
        }
        return out.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    private static func modified(_ path: String) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date) ?? .distantPast
    }

    private static func status(_ path: String, mtime: Date) -> AgentSession.Status {
        // 오래 전에 멈춘 로그는 마지막 이벤트가 task_started 여도 작업 중으로 보지 않는다
        Date().timeIntervalSince(mtime) < 1800 && isBusy(path) ? .busy : .idle
    }

    /// 가장 최근 token_count 이벤트의 rate_limits.
    static func usage(openRollouts: [String]) -> ServiceUsage {
        var u = ServiceUsage(service: .codex)
        var candidates = Set(openRollouts)
        candidates.formUnion(recentRollouts(days: 3, limit: 6).map(\.path))
        let ordered = candidates.map { ($0, modified($0)) }.sorted { $0.1 > $1.1 }
        for (path, mtime) in ordered.prefix(12) {
            guard let limits = lastRateLimits(path) else { continue }
            for key in ["primary", "secondary"] {
                guard let w = limits[key] as? [String: Any],
                      let used = (w["used_percent"] as? NSNumber)?.doubleValue else { continue }
                let minutes = (w["window_minutes"] as? NSNumber)?.intValue ?? 0
                u.windows.append(UsageWindow(label: windowLabel(minutes), usedPercent: used, resetsAt: date(fromEpoch: w["resets_at"])))
            }
            // 주간 한도를 먼저 보여 준다
            u.windows.sort { ($0.label == "주간" ? 0 : 1) < ($1.label == "주간" ? 0 : 1) }
            u.plan = limits["plan_type"] as? String
            u.updatedAt = mtime
            break
        }
        if u.windows.isEmpty { u.note = "최근 Codex 사용 기록에서 한도 정보를 찾지 못했어요" }
        return u
    }

    private static func windowLabel(_ minutes: Int) -> String {
        switch minutes {
        case 10080: return "주간"
        case 300: return "5시간"
        case 1440: return "일간"
        case 0: return "한도"
        default: return minutes % 60 == 0 ? "\(minutes / 60)시간" : "\(minutes)분"
        }
    }

    /// 최근 날짜 폴더(YYYY/MM/DD)의 rollout 파일들을 수정 시각 최신순으로.
    private static func recentRollouts(days: Int, limit: Int) -> [(path: String, mtime: Date)] {
        let fm = FileManager.default
        func children(_ url: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
        var dirs: [URL] = []
        outer: for y in children(sessionsDir) {
            for m in children(y) {
                for d in children(m) {
                    dirs.append(d)
                    if dirs.count >= days { break outer }
                }
            }
        }
        return dirs.flatMap(children)
            .filter { $0.lastPathComponent.hasPrefix("rollout-") && $0.pathExtension == "jsonl" }
            .map { (path: $0.path, mtime: modified($0.path)) }
            .sorted { $0.mtime > $1.mtime }
            .prefix(limit).map { $0 }
    }

    private static func firstLine(_ path: String) -> Data? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var buf = Data()
        while buf.count < 4_000_000 {
            guard let chunk = try? h.read(upToCount: 65536), !chunk.isEmpty else { break }
            if let nl = chunk.firstIndex(of: 0x0A) {
                buf.append(chunk[chunk.startIndex..<nl])
                return buf
            }
            buf.append(chunk)
        }
        return buf.isEmpty ? nil : buf
    }

    /// 파일 끝부분의 줄들을 최신순으로.
    private static func tailLines(_ path: String, bytes: UInt64) -> [Data] {
        guard let h = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > bytes ? size - bytes : 0
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd() else { return [] }
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
        if start > 0, !lines.isEmpty { lines.removeFirst() }      // 잘린 첫 줄 버림
        return lines.reversed()
    }

    private static func isBusy(_ path: String) -> Bool {
        for line in tailLines(path, bytes: 256_000) {
            guard let o = json(line), o["type"] as? String == "event_msg",
                  let t = (o["payload"] as? [String: Any])?["type"] as? String else { continue }
            if t == "task_started" { return true }
            if t == "task_complete" || t == "turn_aborted" { return false }
        }
        return false
    }

    private static func lastRateLimits(_ path: String) -> [String: Any]? {
        for size in [UInt64(200_000), 3_000_000] {
            for line in tailLines(path, bytes: size) {
                // JSON 파싱 전에 값싼 문자열 검사로 걸러 낸다
                guard line.range(of: Data("\"rate_limits\"".utf8)) != nil,
                      let o = json(line), let p = o["payload"] as? [String: Any],
                      let limits = p["rate_limits"] as? [String: Any] else { continue }
                return limits
            }
        }
        return nil
    }
}

// MARK: - 모니터

final class AgentMonitor: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var usages: [ServiceUsage] = []
    @Published private(set) var refreshedAt: Date?

    /// 패널이 열려 있는 동안에는 더 자주 갱신한다.
    var fast = false { didSet { schedule() } }

    private let queue = DispatchQueue(label: "damagochi.monitor", qos: .utility)
    private var timer: Timer?
    private var inFlight = false

    var busyCount: Int { sessions.filter { $0.status == .busy }.count }

    func start() {
        refresh()
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        let t = Timer(timeInterval: fast ? 4 : 20, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        guard !inFlight else { return }
        inFlight = true
        queue.async {
            let (sessions, usages) = AgentMonitor.snapshot()
            DispatchQueue.main.async {
                self.inFlight = false
                if self.sessions != sessions { self.sessions = sessions }
                if self.usages != usages { self.usages = usages }
                self.refreshedAt = Date()
            }
        }
    }

    static func snapshot() -> ([AgentSession], [ServiceUsage]) {
        let rollouts = CodexProvider.openRollouts()
        let sessions = ClaudeProvider.sessions() + CodexProvider.sessions(openRollouts: rollouts)
        let usages = [ClaudeProvider.usage(), CodexProvider.usage(openRollouts: rollouts)]
        return (sessions, usages)
    }

    /// `--dump`: UI 없이 수집 결과만 출력 (검증용)
    static func dump() {
        let (sessions, usages) = snapshot()
        print("== 세션 \(sessions.count)개 ==")
        for s in sessions {
            print("  [\(s.service.rawValue)] \(s.title) · \(s.status.label) · \(s.detail) · \(Format.path(s.cwd))"
                  + (s.updatedAt.map { " · \(Format.ago($0))" } ?? ""))
        }
        print("== 사용량 ==")
        for u in usages {
            print("  \(u.service.rawValue)" + (u.plan.map { " (\($0))" } ?? "") + (u.note.map { " — \($0)" } ?? ""))
            for w in u.windows {
                print("    \(w.label): \(Int(w.remaining.rounded()))% 남음" + (w.resetsAt.map { " · \(Format.reset($0))" } ?? ""))
            }
        }
    }
}

enum Format {
    static func path(_ p: String) -> String {
        let h = home.path
        return p.hasPrefix(h) ? "~" + p.dropFirst(h.count) : p
    }

    static func ago(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "방금" }
        if s < 3600 { return "\(s / 60)분 전" }
        if s < 86400 { return "\(s / 3600)시간 전" }
        return "\(s / 86400)일 전"
    }

    private static let resetFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M/d(E) HH:mm"
        return f
    }()

    static func reset(_ d: Date) -> String {
        resetFormatter.string(from: d) + " 초기화"
    }
}
