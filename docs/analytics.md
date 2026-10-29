# Anonymous app analytics

pi-work shares the owner's Mixpanel project **minicode** (4078569, US region) with the other apps. The public ingestion token is stored in the application's Info.plist; no API secret is bundled. The official Swift SDK is pinned to revision `3ad0fb82216978c124b04accac6c9f9eaf848187`.

- Every event includes `app_id = pi-work`, app/build versions, platform, OS version and `environment` (`production` or `development`).
- `App Launched` records normal launches. `Daily Active` records the first meaningful use of each reporting day, deduplicated across restarts.
- Reporting days follow the project's **US/Pacific** timezone (`America/Los_Angeles`), including daylight saving time. Update the code if the project timezone changes.
- Anonymous installation IDs are randomly generated and local to each app. Development and production have separate IDs, SDK queues and daily bookkeeping. Metrics describe installations, not people deduplicated across devices.
- Settings include a **Share anonymous usage** switch. Disabling analytics prevents SDK initialization on subsequent launches and opts out the running SDK.
- Analytics never include screenshots, clipboard contents, memories, conversation content, files, commands, agent session IDs, account identifiers or hardware UUIDs. IP-based geolocation, automatic lifecycle tracking, People profiles, feature flags and session replay are disabled.

Meaningful use includes bringing pi-work to the foreground or interacting with its windows. Background agent/scheduled work does not manufacture user activity. Preview and automated test runs do not initialize analytics.

## Shared dashboard

In Mixpanel Insights select **Daily Active**, measure **Unique Users**, choose a daily interval, filter **environment = production**, and break down by **app_id**. All apps share the monthly allowance. Weekly/monthly activity should count unique IDs over the week/month, rather than summing daily counts.

## Checks

Run `bash scripts/test-analytics.sh` for repeated-use, restart, timezone/DST, opt-out and identifier isolation scenarios. These tests use temporary preferences and send no events.
