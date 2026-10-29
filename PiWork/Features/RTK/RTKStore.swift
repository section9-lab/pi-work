import Combine
import Foundation

@MainActor
final class RTKStore: ObservableObject {
    @Published private(set) var snapshot: RTKSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var operation: String?
    @Published private(set) var runtimeSupported = true
    @Published private(set) var errorMessage: String?
    private let service: any RTKServicing
    private var failedAction: String?

    init(service: any RTKServicing) { self.service = service }

    var isBusy: Bool { isLoading || operation != nil }
    var enabled: Bool { snapshot?.enabled == true }

    func load(checkLatest: Bool = false) async {
        guard !isBusy else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let hello = try await service.start()
            runtimeSupported = hello.supportsPiWorkCapability(.rtkGet) && hello.supportsPiWorkCapability(.rtkAction)
            guard runtimeSupported else { snapshot = nil; return }
            let value = try await service.rtkSnapshot(checkLatest: checkLatest)
            snapshot = value
            if failedAction == nil { errorMessage = value.updateError }
        } catch { if failedAction == nil { errorMessage = error.localizedDescription } }
    }

    func action(_ action: String) async {
        guard runtimeSupported, !isBusy else { return }
        operation = action
        errorMessage = nil
        failedAction = nil
        defer { operation = nil }
        do {
            snapshot = try await service.rtkAction(action)
        } catch {
            failedAction = action
            errorMessage = error.localizedDescription
        }
    }

    func retry() async {
        if let failedAction { await action(failedAction) }
        else { await load(checkLatest: true) }
    }
}

enum RTKTimeRange: String, CaseIterable, Identifiable {
    case month, quarter, all
    var id: String { rawValue }
    var titleKey: String {
        switch self {
        case .month: return "rtk.range.month"
        case .quarter: return "rtk.range.quarter"
        case .all: return "rtk.range.all"
        }
    }

    func startDate(now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .month: return calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now))
        case .quarter: return calendar.date(byAdding: .day, value: -89, to: calendar.startOfDay(for: now))
        case .all: return nil
        }
    }
}

struct RTKStatistics {
    let days: [RTKDay]
    let gain: RTKGain
    let start: Date
    let end: Date

    init(snapshot: RTKSnapshot, range: RTKTimeRange, now: Date = Date(), calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let start = range.startDate(now: now, calendar: calendar)
            ?? snapshot.days.compactMap(\.calendarDate).min() ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        days = snapshot.days.filter { day in
            guard let date = day.calendarDate else { return false }
            return date >= start && date < end
        }
        let input = days.reduce(0) { $0 + $1.input }
        let saved = days.reduce(0) { $0 + $1.saved }
        gain = range == .all ? snapshot.gain ?? RTKGain(commands: 0, input: 0, saved: 0, pct: 0)
            : RTKGain(commands: days.reduce(0) { $0 + $1.commands }, input: input, saved: saved,
                      pct: input > 0 ? saved / input * 100 : 0)
        self.start = min(start, today)
        self.end = end
    }
}
