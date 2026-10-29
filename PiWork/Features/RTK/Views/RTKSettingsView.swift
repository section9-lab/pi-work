import AppKit
import Charts
import SwiftUI

struct RTKSettingsView: View {
    @ObservedObject var store: RTKStore
    @State private var range: RTKTimeRange = .month

    var body: some View {
        Form {
            Section {
                HStack(spacing: MCPMetrics.fieldSpacing) {
                    MCPGlyph(name: "Terminal")
                    Text("RTK").font(.headline)
                    Spacer()
                    if store.isBusy { ProgressView().controlSize(.small) }
                    if let version = store.snapshot?.version {
                        Text("v" + version).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(L10n.string("rtk.description")).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !store.runtimeSupported {
                    Text(L10n.string("rtk.runtime_unsupported")).foregroundStyle(.secondary)
                } else if let snapshot = store.snapshot {
                    installation(snapshot)
                } else if store.isLoading {
                    Text(L10n.string("rtk.checking")).foregroundStyle(.secondary)
                }
            } footer: {
                Text(L10n.string("rtk.install_note"))
            }

            if let snapshot = store.snapshot, snapshot.path != nil {
                Section {
                    if let gain = snapshot.gain {
                        Text(summary(gain)).font(.callout).monospacedDigit()
                    }
                    if let error = snapshot.statsError {
                        Text(L10n.string("rtk.stats_error")).font(.callout)
                        Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Button(L10n.string("common.retry")) { Task { await store.load() } }
                            .disabled(store.isBusy)
                    } else {
                        statistics(snapshot)
                    }
                } header: {
                    Text(L10n.string("rtk.savings"))
                } footer: {
                    Text(L10n.string("rtk.stats_note"))
                }
            }

            if let error = store.errorMessage {
                Section {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                    Button(L10n.string("common.retry")) { Task { await store.retry() } }
                        .disabled(store.isBusy)
                }
            }
            Section {
                Link(L10n.string("rtk.learn_more"), destination: URL(string: "https://www.rtk-ai.app")!)
            }
        }
        .formStyle(.grouped)
        .task {
            await store.load()
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { break }
                await store.load()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await store.load() }
        }
    }

    @ViewBuilder
    private func installation(_ snapshot: RTKSnapshot) -> some View {
        if snapshot.path != nil {
            Toggle(L10n.string("rtk.enable"), isOn: Binding(get: { store.enabled }, set: { enabled in
                Task { await store.action(enabled ? "enable" : "disable") }
            }))
            .toggleStyle(.switch)
            .disabled(store.isBusy)
            .accessibilityIdentifier("rtk-enable")
            if let path = snapshot.path {
                Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(L10n.string(snapshot.updateAvailable ? "rtk.update" : "rtk.check_updates")) {
                    Task {
                        if snapshot.updateAvailable { await store.action("update") }
                        else { await store.load(checkLatest: true) }
                    }
                }
                .disabled(store.isBusy || (!snapshot.supported && snapshot.updateAvailable))
                if let latest = snapshot.latestVersion {
                    Text(snapshot.updateAvailable ? "v" + latest : L10n.string("rtk.up_to_date"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button { Task { await store.load() } } label: {
                    MCPGlyph(name: "RefreshCw")
                }
                .help(L10n.string("rtk.refresh"))
                .accessibilityLabel(L10n.string("rtk.refresh"))
                .disabled(store.isBusy)
            }
        } else {
            Text(L10n.string(snapshot.supported ? "rtk.not_installed" : "rtk.unsupported"))
                .font(.callout).foregroundStyle(.secondary)
            Button(L10n.string(store.operation == "install" ? "rtk.installing" : "rtk.install")) {
                Task { await store.action("install") }
            }
            .disabled(store.isBusy || !snapshot.supported)
            .accessibilityIdentifier("rtk-install")
            if snapshot.enabled {
                Button(L10n.string("rtk.disable")) { Task { await store.action("disable") } }
                    .disabled(store.isBusy)
            }
        }
        if store.operation == "update" {
            Text(L10n.string("rtk.updating")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func statistics(_ snapshot: RTKSnapshot) -> some View {
        let statistics = RTKStatistics(snapshot: snapshot, range: range)
        return VStack(alignment: .leading, spacing: MCPMetrics.spacing) {
            Picker(L10n.string("rtk.range"), selection: $range) {
                ForEach(RTKTimeRange.allCases) { range in Text(L10n.string(range.titleKey)).tag(range) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(L10n.string("rtk.range"))

            if statistics.days.isEmpty || statistics.gain.commands == 0 {
                VStack(spacing: MCPMetrics.fieldSpacing) {
                    Text(L10n.string("rtk.empty")).font(.callout)
                    Text(L10n.string("rtk.empty_note")).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                RTKSavingsChart(statistics: statistics)
                Text(summary(statistics.gain)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func summary(_ gain: RTKGain) -> String {
        L10n.format("rtk.summary", gain.commands.formatted(.number.locale(L10n.currentLanguage.locale)), compact(gain.saved),
                    gain.pct.formatted(.number.precision(.fractionLength(0)).locale(L10n.currentLanguage.locale)))
    }
}

private struct RTKSavingsChart: View {
    let statistics: RTKStatistics
    @State private var hoveredDay: RTKDay?

    var body: some View {
        VStack(alignment: .leading, spacing: MCPMetrics.fieldSpacing) {
            Chart(statistics.days) { day in
                if let date = day.calendarDate {
                    BarMark(x: .value(L10n.string("rtk.date"), date, unit: .day),
                            y: .value(L10n.string("rtk.tokens"), max(0, day.input - day.saved)))
                        .foregroundStyle(Color.accentColor.opacity(0.3))
                        .accessibilityLabel(day.date + ", " + L10n.string("rtk.sent"))
                        .accessibilityValue(compact(max(0, day.input - day.saved)))
                    BarMark(x: .value(L10n.string("rtk.date"), date, unit: .day),
                            y: .value(L10n.string("rtk.tokens"), day.saved))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel(day.date + ", " + L10n.string("rtk.saved"))
                        .accessibilityValue(compact(day.saved))
                }
            }
            .chartXScale(domain: statistics.start...statistics.end)
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.month().day().locale(L10n.currentLanguage.locale))
            } }
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine()
                AxisValueLabel(format: FloatingPointFormatStyle<Double>.number.notation(.compactName).locale(L10n.currentLanguage.locale))
            } }
            .frame(height: 180)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    let frame = plotFrame(proxy, geometry: geometry)
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point):
                                let x = point.x - frame.origin.x
                                guard x >= 0, x <= frame.width,
                                      let date: Date = proxy.value(atX: x) else { hoveredDay = nil; return }
                                hoveredDay = statistics.days.first { day in
                                    day.calendarDate.map { Calendar.current.isDate($0, inSameDayAs: date) } ?? false
                                }
                            case .ended: hoveredDay = nil
                            }
                        }
                        .accessibilityHidden(true)
                }
            }
            HStack(spacing: MCPMetrics.spacing) {
                legend("rtk.saved", color: .accentColor)
                legend("rtk.sent", color: .accentColor.opacity(0.3))
            }
            Text(hoveredDay.map { $0.date + " · " + compact($0.saved) + " " + L10n.string("rtk.saved") } ?? " ")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func legend(_ key: String, color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(L10n.string(key)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func plotFrame(_ proxy: ChartProxy, geometry: GeometryProxy) -> CGRect {
        if #available(macOS 14.0, *) {
            return proxy.plotFrame.map { geometry[$0] } ?? .zero
        } else {
            return geometry[proxy.plotAreaFrame]
        }
    }
}

private func compact(_ value: Double) -> String {
    value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(L10n.currentLanguage.locale))
}
