import SwiftUI

/// 펫을 클릭하면 뜨는 패널: 실행 중인 에이전트 세션과 서비스별 사용량.
struct PanelView: View {
    @ObservedObject var monitor: AgentMonitor
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sessionsSection
            usageSection
            Divider()
            settingsRow
        }
        .padding(14)
        .frame(width: 340)
    }

    // MARK: 세션

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("실행 중인 세션").font(.headline)
                Text("\(monitor.sessions.count)").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if monitor.busyCount > 0 {
                    Text("\(monitor.busyCount)개 작업 중").font(.caption).foregroundStyle(.green)
                }
                Button { monitor.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("새로 고침")
            }
            if monitor.sessions.isEmpty {
                Text("실행 중인 에이전트 세션이 없어요")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else if monitor.sessions.count > 6 {
                ScrollView { sessionList }.frame(height: 264)
            } else {
                sessionList
            }
        }
    }

    private var sessionList: some View {
        VStack(spacing: 6) {
            ForEach(monitor.sessions) { SessionRow(session: $0) }
        }
    }

    // MARK: 사용량

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("사용량").font(.headline)
            ForEach(monitor.usages) { UsageCard(usage: $0) }
        }
    }

    // MARK: 설정

    private var settingsRow: some View {
        HStack(spacing: 10) {
            Picker("동물", selection: $settings.animal) {
                ForEach(Animal.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: 96)

            Picker("크기", selection: $settings.size) {
                ForEach(Settings.sizes, id: \.self) { Text("\($0)pt").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 110)

            Spacer()
            Button("종료") { NSApp.terminate(nil) }
        }
        .controlSize(.small)
    }
}

private struct ServiceBadge: View {
    let service: Service

    var body: some View {
        Text(service == .claude ? "Claude" : "Codex")
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(.white)
            .background(service == .claude ? Color(red: 0.80, green: 0.42, blue: 0.29) : Color(white: 0.28),
                        in: Capsule())
    }
}

private struct SessionRow: View {
    let session: AgentSession

    private var dot: Color {
        switch session.status {
        case .busy: return .green
        case .idle: return Color.secondary.opacity(0.5)
        case .other: return .orange
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(dot).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    ServiceBadge(service: session.service)
                    Spacer(minLength: 4)
                    Text(session.status.label)
                        .font(.caption)
                        .foregroundStyle(session.status == .busy ? Color.green : Color.secondary)
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private var subtitle: String {
        var parts = [Format.path(session.cwd)]
        if !session.detail.isEmpty { parts.append(session.detail) }
        if let u = session.updatedAt { parts.append(Format.ago(u)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct UsageCard: View {
    let usage: ServiceUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(usage.service.rawValue).font(.system(size: 13, weight: .medium))
                if let plan = usage.plan {
                    Text(plan).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let at = usage.updatedAt {
                    Text("\(Format.ago(at)) 기준").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            ForEach(usage.windows) { UsageBar(window: $0) }
            if let note = usage.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct UsageBar: View {
    let window: UsageWindow

    private var color: Color {
        window.remaining >= 50 ? .green : window.remaining >= 20 ? .yellow : .red
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(window.remaining.rounded()))% 남음").font(.caption.monospacedDigit().weight(.medium))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(color).frame(width: max(geo.size.width * window.remaining / 100, 4))
                }
            }
            .frame(height: 6)
            if let reset = window.resetsAt {
                Text(Format.reset(reset)).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}
