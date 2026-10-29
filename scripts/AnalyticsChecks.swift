import Foundation


@MainActor
struct AnalyticsStateTests {
    func deduplicatesAcrossRestarts() {
        withDefaults { defaults in
            let first = makeState(defaults)
            precondition(first.claimActiveDay(at: date("2026-10-29T08:00:00Z")) == "2026-10-29")
            precondition(first.claimActiveDay(at: date("2026-10-29T23:00:00Z")) == nil)
            let restarted = makeState(defaults)
            precondition(restarted.claimActiveDay(at: date("2026-10-30T06:59:59Z")) == nil)
            precondition(restarted.claimActiveDay(at: date("2026-10-30T07:00:00Z")) == "2026-10-30")
        }
    }

    func respectsReportingTimeZone() {
        withDefaults { defaults in
            let state = makeState(defaults)
            precondition(state.claimActiveDay(at: date("2026-10-29T23:59:59Z")) == "2026-10-29")
            precondition(state.claimActiveDay(at: date("2026-10-30T00:00:00Z")) == nil)
            precondition(state.claimActiveDay(at: date("2026-10-30T07:00:00Z")) == "2026-10-30")
        }
    }

    func handlesDaylightSaving() {
        withDefaults { defaults in
            let state = makeState(defaults)
            precondition(state.claimActiveDay(at: date("2026-11-01T08:30:00Z")) == "2026-11-01")
            precondition(state.claimActiveDay(at: date("2026-11-01T09:30:00Z")) == nil)
            precondition(state.claimActiveDay(at: date("2026-11-02T07:59:59Z")) == nil)
            precondition(state.claimActiveDay(at: date("2026-11-02T08:00:00Z")) == "2026-11-02")
        }
    }

    func respectsOptOut() {
        withDefaults { defaults in
            let state = makeState(defaults)
            state.isEnabled = false
            precondition(state.claimActiveDay(at: date("2026-10-29T12:00:00Z")) == nil)
            let restarted = makeState(defaults)
            precondition(!restarted.isEnabled)
            restarted.isEnabled = true
            precondition(restarted.claimActiveDay(at: date("2026-10-29T12:00:00Z")) == "2026-10-29")
        }
    }

    func isolatesApps() {
        withDefaults { defaults in
            let hud = makeState(defaults)
            let other = makeState(defaults, appID: "another-app")
            precondition(hud.installationID != other.installationID)
            precondition(hud.claimActiveDay(at: date("2026-10-29T12:00:00Z")) != nil)
            precondition(other.claimActiveDay(at: date("2026-10-29T12:00:00Z")) != nil)
            hud.isEnabled = false
            precondition(other.isEnabled)
        }
    }

    func replacesHardwareIdentifier() {
        withDefaults { defaults in
            let oldID = "OLD-HARDWARE-ID"
            defaults.set(oldID, forKey: "mixpanel_distinct_id")
            let state = makeState(defaults)
            let id = state.installationID
            precondition(id != oldID)
            precondition(UUID(uuidString: id) != nil)
            precondition(defaults.object(forKey: "mixpanel_distinct_id") == nil)
            precondition(makeState(defaults).installationID == id)
        }
    }

    private func makeState(_ defaults: UserDefaults, appID: String = "vibe-hud") -> AnalyticsState {
        AnalyticsState(
            defaults: defaults, appID: appID, timeZone: TimeZone(identifier: "America/Los_Angeles")!
        )
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "AnalyticsStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }
}

@main struct AnalyticsChecks {
    @MainActor static func main() {
        let checks = AnalyticsStateTests()
        checks.deduplicatesAcrossRestarts()
        checks.respectsReportingTimeZone()
        checks.handlesDaylightSaving()
        checks.respectsOptOut()
        checks.isolatesApps()
        checks.replacesHardwareIdentifier()
        print("PASS: 6 anonymous analytics scenarios")
    }
}
