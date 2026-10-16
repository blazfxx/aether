import SwiftUI
import AetherCore

struct HealthView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let h = state.health
        let s = h.snap
        VStack(spacing: 0) {
            PageHeader(module: .health, title: "Mac Health", subtitle: "Live. Updates every couple of seconds.")
            ScrollView {
                VStack(spacing: 14) {
                    scoreCard(h)
                    HStack(alignment: .top, spacing: 14) {
                        cpuCard(h, s)
                        memoryCard(s)
                    }
                    HStack(alignment: .top, spacing: 14) {
                        diskCard(s)
                        networkCard(h, s)
                    }
                    if let b = s.battery { batteryCard(b) }
                    processesCard(h)
                }
                .padding(24)
            }
        }
    }

    // MARK: cards

    private func scoreCard(_ h: HealthModel) -> some View {
        Card {
            HStack(spacing: 22) {
                ZStack {
                    RingGauge(value: Double(h.score) / 100, tint: color(for: h.score), lineWidth: 12)
                    VStack(spacing: 0) {
                        Text("\(h.score)").font(.system(size: 34, weight: .light)).monospacedDigit()
                        Text(h.verdict).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 110, height: 110)
                VStack(alignment: .leading, spacing: 10) {
                    if h.issues.isEmpty {
                        Label("Everything looks good", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(.green)
                        Text("Disk, memory, temperature and battery are all in a healthy range.").foregroundStyle(.secondary)
                    } else {
                        ForEach(h.issues) { i in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: i.severity >= 3 ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                                    .foregroundStyle(i.severity >= 3 ? .red : .orange)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(i.title).font(.callout.weight(.semibold))
                                    Text(i.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let fix = i.fix { Button("Open \(fix.title)") { state.selection = fix }.buttonStyle(SoftButtonStyle()) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func cpuCard(_ h: HealthModel, _ s: SystemSnapshot) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                cardTitle("CPU", "cpu", .blue, "\(Int(s.cpuTotal * 100))%")
                Sparkline(values: h.cpuHistory, tint: .blue).frame(height: 54)
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(Array(s.cpuPerCore.enumerated()), id: \.offset) { _, v in
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.12))
                            RoundedRectangle(cornerRadius: 2).fill(Color.blue.gradient).frame(height: max(2, 28 * v))
                        }.frame(height: 28)
                    }
                }
                Text("\(s.cpuPerCore.count) cores").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func memoryCard(_ s: SystemSnapshot) -> some View {
        let m = s.memory
        let total = Double(max(m.total, 1))
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                cardTitle("Memory", "memorychip", .purple, "\(Bytes.string(Int64(m.used))) of \(Bytes.string(Int64(m.total)))")
                GeometryReader { g in
                    HStack(spacing: 1) {
                        seg(Double(m.app) / total, g.size.width, .purple)
                        seg(Double(m.wired) / total, g.size.width, .orange)
                        seg(Double(m.compressed) / total, g.size.width, .pink)
                        seg(Double(m.cached) / total, g.size.width, .gray.opacity(0.45))
                        Spacer(minLength: 0)
                    }
                }
                .frame(height: 14).background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.12))).clipShape(RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 3) {
                    legend("App memory", Int64(m.app), .purple)
                    legend("Wired", Int64(m.wired), .orange)
                    legend("Compressed", Int64(m.compressed), .pink)
                    legend("Cached files", Int64(m.cached), .gray)
                    legend("Swap used", Int64(m.swapUsed), .secondary)
                }
            }
        }
    }

    private func diskCard(_ s: SystemSnapshot) -> some View {
        let d = s.disk
        return Card {
            HStack(spacing: 18) {
                ZStack {
                    RingGauge(value: d.usedFraction, tint: d.usedFraction > 0.9 ? .red : (d.usedFraction > 0.8 ? .orange : .green), lineWidth: 9)
                    Text("\(Int(d.usedFraction * 100))%").font(.system(size: 20, weight: .light)).monospacedDigit()
                }.frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: 4) {
                    cardTitle("Storage", "internaldrive", .green, nil)
                    Text("\(Bytes.string(d.available)) available").font(.title3.weight(.semibold))
                    Text("\(Bytes.string(d.used)) used of \(Bytes.string(d.total))").font(.caption).foregroundStyle(.secondary)
                    Button("Open Space Lens") { state.selection = .spaceLens }.buttonStyle(SoftButtonStyle()).padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func networkCard(_ h: HealthModel, _ s: SystemSnapshot) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                cardTitle("Network", "network", .cyan, nil)
                HStack {
                    Label(rate(s.netDownBps), systemImage: "arrow.down").foregroundStyle(.cyan)
                    Spacer()
                    Label(rate(s.netUpBps), systemImage: "arrow.up").foregroundStyle(.teal)
                }.font(.callout.weight(.medium)).monospacedDigit()
                Sparkline(values: h.downHistory, tint: .cyan, maxValue: nil).frame(height: 30)
                Sparkline(values: h.upHistory, tint: .teal, maxValue: nil).frame(height: 30)
            }
        }
    }

    private func batteryCard(_ b: BatteryStats) -> some View {
        Card {
            HStack(spacing: 24) {
                cardTitle("Battery", b.isCharging ? "battery.100.bolt" : "battery.75", .green, "\(b.percent)%")
                Spacer()
                stat("Condition", b.healthPercent.map { "\($0)%" } ?? "n/a")
                stat("Cycles", b.cycleCount.map(String.init) ?? "n/a")
                stat("Temperature", b.temperatureC.map { String(format: "%.0f°C", $0) } ?? "n/a")
                stat("Power", b.isCharging ? "Charging" : (b.onAC ? "Plugged in" : "On battery"))
            }
        }
    }

    private func processesCard(_ h: HealthModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                cardTitle("Using the most memory", "list.number", .orange, nil)
                ForEach(h.processes) { p in
                    HStack {
                        Text(p.name).lineLimit(1)
                        Spacer()
                        Text(String(format: "%.0f%% CPU", p.cpu)).font(.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 80, alignment: .trailing)
                        Text(Bytes.string(Int64(p.rssBytes))).font(.callout.weight(.medium)).monospacedDigit().frame(width: 80, alignment: .trailing)
                        if NSRunningApplication(processIdentifier: p.pid)?.activationPolicy == .regular {
                            Button("Quit") { h.quitApp(pid: p.pid) }.buttonStyle(SoftButtonStyle())
                        } else {
                            Color.clear.frame(width: 62, height: 1)
                        }
                    }
                    if p.id != h.processes.last?.id { Divider() }
                }
            }
        }
    }

    // MARK: bits

    private func cardTitle(_ t: String, _ symbol: String, _ tint: Color, _ trailing: String?) -> some View {
        HStack {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(t).font(.headline)
            if let trailing { Spacer(); Text(trailing).font(.callout.weight(.medium)).monospacedDigit().foregroundStyle(.secondary) }
        }
    }

    private func seg(_ fraction: Double, _ width: CGFloat, _ c: Color) -> some View {
        Rectangle().fill(c).frame(width: max(0, width * CGFloat(fraction)))
    }

    private func legend(_ name: String, _ bytes: Int64, _ c: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(c).frame(width: 7, height: 7)
            Text(name).font(.caption)
            Spacer()
            Text(Bytes.string(bytes)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func stat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.caption).foregroundStyle(.secondary)
            Text(v).font(.callout.weight(.semibold))
        }
    }

    private func rate(_ bps: Double) -> String {
        let f = ByteCountFormatter(); f.countStyle = .file
        return f.string(fromByteCount: Int64(bps)) + "/s"
    }

    private func color(for score: Int) -> Color { score >= 90 ? .green : (score >= 75 ? .mint : (score >= 55 ? .orange : .red)) }
}
