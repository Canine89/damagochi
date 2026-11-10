import AppKit

let args = CommandLine.arguments

if args.contains("--simulate") {
    // 펫의 이동·점프 로직을 화면 없이 검증
    exit(Simulation.run() ? 0 : 1)
}

if args.contains("--dump") {
    // 세션·사용량 수집 결과만 출력
    AgentMonitor.dump()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)      // Dock 아이콘 없이 상주
app.run()
