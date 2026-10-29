# Computer Use

PiWork integrates `@injaneity/pi-computer-use` 0.5.1 as a managed desktop
capability. The application and Agent Host still support macOS 13; only this
capability requires macOS 14 or newer. No model provider or second agent loop
is added.

## Setup

Open Settings → Computer Use and turn on the master switch. Enable
Accessibility and Screen Recording for the exact `pi-computer-use.app` shown
on that page. Return to PiWork and choose **Apply Permissions and Recheck**.
This restarts the helper rather than the main application or Agent Host.

The master switch records intent separately from readiness. Missing permission,
a failed live capture probe, or caller-attributed permission cannot make the
service ready. On macOS 13 the switch is disabled and the helper is never
started. Turning the feature off keeps macOS grants but immediately rejects new
calls and cancels queued calls and pending approvals.

The input toolbar has a status/settings shortcut. Computer Use has a dedicated
settings page and one master switch. Keep the feature name **Computer Use** in
every language, while localizing explanations, permission labels, and actions.

## Permission policy and lifecycle

- Work `none`: no desktop access.
- Work `readOnly`: observation only, with upstream strict headless policy.
- Work `ask`: observations and actions use PiWork's existing approval broker.
- Work `full`: desktop calls run within the user's requested scope.
- Chat: observations/actions use the existing approval broker while file and
  shell access remain disabled.

The first release exposes eight upstream desktop tools (`find_roots`,
`observe_ui`, `search_ui`, `expand_ui`, `inspect_ui`, `act_ui`, `read_text`,
`wait_for`). Managed-browser launching, CDP evaluation, and inherited CDP
endpoints are not exposed. A separately installed copy of the package cannot
register a second unwrapped tool surface.

One Host coordinator serializes computer calls across sessions, including
approval and cancellation. State ids are scoped to the issuing session and
service generation; restarting, stopping, or testing requires a fresh
observation before using old action state. Calls that were delivered before
cancellation can still affect the OS and are never automatically replayed.

Rechecking while busy offers either application when idle or cancellation of
computer work followed by restart. Normal Host shutdown stops its helper;
Host recovery reconnects through a stable private socket. The helper does not
control unrelated Pi installations.

## Packaging

`project.yml` stages the universal helper and MIT notice from the exact npm
package. `scripts/stage-computer-use-helper.sh` assigns the independent bundle
id `cc.vibevibe.pi-work.computer-use` and signs it with the app's build identity.
Upstream's npm helper is self-signed; preserve its source/license, but do not
ship that signer as if it were a Developer ID signature. Release notarization
must cover the signed outer application and nested helper.
The final application signing pass preserves nested entitlements, flags, and
runtime metadata so it does not change the helper's staged privacy identity.

The helper is copied into the app's private Agent directory on first enable.
The app supplies its bundled helper path to independently updated Host runtimes.
The helper and pinned package's protocol must remain compatible; changing the
package version requires rebuilding/staging the matching helper in an app
release. Older runtimes without the private capabilities show an unavailable
state instead of receiving unsupported RPC calls.

## Verification

**Test Computer Use** opens a dedicated PiWork window and uses the actual
upstream observation/action executors: find that exact parent-process window,
capture and inspect its input, set a fixed test value, then independently
observe the same window and compare the value. It uses no API keys, sends no
data to a model provider, and never tests against a user's other apps. A
successful action response alone does not pass verification.

Live QA on macOS 26.6 (2026-10-29) passed screenshot-bearing observation,
setting the test field to `PiWork computer use verified`, and independent
read-back. Permission application restarted only the helper; the parent app
kept running. Turning the switch off disabled the test immediately, both
enable/disable intent survived app relaunch, and re-enabling reused the existing
OS grants. This check used the isolated QA app below and no model API.

Automated checks:

```sh
cd AgentHost
bun run typecheck
bun test --timeout 15000
bun run build:arm64
bun run build:x64
cd ..
codesign --force --sign - build/pi-work-agent-host-arm64
codesign --force --sign - build/pi-work-agent-host-x64
bash scripts/test-native.sh
```

With only Apple Command Line Tools, the native script compiles the application
for its macOS 13 deployment target and runs standalone native checks. Full
XCTest requires Xcode. Both arm64 and x64 Host builds should be compiled before
release; a physical macOS 13/14 matrix is still separate from deployment-target
compilation and injected-version tests.

To inspect the actual settings page and perform a local OS permission test
without signing in or using existing conversations:

```sh
bash scripts/build-computer-use-preview.sh
open ~/Library/Caches/pi-work/ComputerUseQA/PiWork-ComputerUse.app
```

This QA app uses `~/Library/Application Support/pi-work-computer-use-qa/Agent`
and its own bundled Host executable. It is staged outside protected Documents
folders to match an installed app's launch behavior. The
OS permissions must be granted by the person at the Mac; CI/mock tests do not
prove a live desktop operation succeeded.
