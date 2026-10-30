# Bundled agent runtime

Pi Coding Agent and PiWork are developed and released together. The agent is not
an independently updatable component.

- Settings → General and About show the bundled agent version.
- There is no agent update check, download, install, pending update, or rollback UI.
- Production startup always uses `AgentHostService.bundled()`. Previously downloaded
  runtimes and pending runtime selections in Application Support are ignored.
- Updating PiWork updates its bundled agent host, SDK, Bun, and runtime resources
  together. See [app updates](app-updates.md) for the application update flow.
- The standalone `runtime-v*` release workflow has been removed. Publish changes to
  the agent through the normal PiWork application release workflow.

Legacy runtime archive/store utilities and their fixtures remain for compatibility
checks and development tests; they are not connected to production startup or the
settings UI. Existing user conversations and configuration are not removed.
