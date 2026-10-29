# RTK

Open **Settings → RTK** to reuse an existing RTK installation (0.23 or newer), or
choose **Install and enable RTK**. Installation uses RTK's official installer,
including its release checksum verification. New binaries are staged, checked and
atomically moved into PiWork's isolated agent directory at `bin/rtk`. Updates use
the same process; an existing Homebrew or Cargo installation is left in place.

The enable setting is stored in `rtk.json` in that same directory and defaults to
off. It applies to subsequent Bash calls in new and already-open Work sessions.
Chat and read-only sessions retain their existing tool restrictions. PiWork
authorizes the original command before handing it to RTK's `rewrite` command,
then executes it through Pi's standard shell backend with its normal streaming,
cancellation and timeout behavior. Unsupported commands and unavailable RTK
rewrites run unchanged. Command execution errors are never automatically retried.
Explicit RTK pipeline denials stop execution and display RTK's message.
No terminal-agent hooks or global instruction files are installed or removed.

The chart reads `rtk gain --daily --format json`. It shows estimated saved tokens
and tokens sent to the model, with 30-day, 90-day and all-time ranges. Statistics
belong to RTK's local history for the current user, including other agents and
terminals; they are not attributed exclusively to PiWork. Database errors are
shown separately from an empty history. Statistics refresh while this settings
page is open and when the application becomes active.

Older independently updated agent runtimes display an unsupported message until
updated in **Settings → General**. The integration follows
[magpie's RTK lifecycle and statistics approach](https://github.com/yetone/magpie/blob/main/internal/library/rtk.go)
and delegates rewrite rules to [RTK itself](https://github.com/rtk-ai/rtk/blob/master/hooks/pi/rtk.ts).
