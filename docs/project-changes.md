# Project code changes

Select a project under Work, then open the project menu in the **session header's
top-right corner**. It shows the project, current Git branch, and **Code Changes**.
Choosing Code Changes opens a resizable review pane to the right of the
conversation, not as a sidebar destination or modal sheet. The control is inside
the detail column, not the native window toolbar, so it does not reposition the
left navigation. Opening it never increases the window's minimum width: wide
detail columns split the available space; narrow columns show an overlaid review
pane without squeezing or clipping the sidebar. Its file list shows staged,
unstaged, and untracked files; select a file to inspect its diff, line numbers,
and addition/deletion counts below. Filter or refresh the snapshot as needed.
Closing or toggling the pane leaves the conversation and draft intact. Switching
projects updates the pane; switching sessions in the same project keeps the review
project-scoped. Chat and non-project destinations do not show the review control.

The baseline is HEAD, so a file edited both in the index and working tree shows
its combined current changes. Renames include the original path. Unborn
repositories use the empty tree, binary changes show Git's binary notice, and
non-repositories or unavailable paths show an error with a refresh action.

All Git commands are read-only. External diff drivers and text conversion are
disabled; filenames are passed as literal argument values with NUL-delimited
status parsing. Displayed output is capped at 2 MiB per command, with a notice
when a diff is truncated, and Git commands have a 20-second timeout.

Run `bash scripts/test-project-changes.sh` for real repository and parser checks.
The release workflow runs these checks for both architectures and includes
`ProjectChangesTests` in the application's XCTest target.
