# Project code changes

Expand a project under Work and click **Code Changes**. The sheet lists staged,
unstaged, and untracked files. Select a file to inspect its diff, line numbers,
and addition/deletion counts. Filter the list or refresh the snapshot as needed.
Closing the sheet returns to the conversation with its draft intact.

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
