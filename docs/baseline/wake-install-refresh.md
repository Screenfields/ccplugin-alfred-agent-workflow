# alfred-wake install and refresh

Baseline record of how the `alfred-wake` a lead launches by name from PATH stays
current (CCW-220). The code is the source of truth: `bin/alfred-wake`
(`cmd_install`, `self_upgrade`) and `hooks/wake-link-check.sh`.

## What exists

- `alfred-wake install` links `bin/alfred-wake` into
  `${ALFRED_WAKE_BIN_DIR:-$HOME/.local/bin}/alfred-wake`: a symlink on Linux, a
  copy on MSYS (Git Bash), where `ln -s` copies. It is not atomic.
- `self_upgrade` runs only for `wait` and `run`. It compares the `VERSION`
  constant, repoints only a symlink, and does not exist before bridge 1.3.0. A
  stale copy, or a bridge that never launches a wait, is not refreshed.

## The hook

`hooks/wake-link-check.sh` runs at SessionStart in its own group (matcher
`startup|resume`, timeout 5). Order of checks, each exiting 0 silently:

1. `ALFRED_WAKE_LINK_CHECK=0` switches it off.
2. Stdin is one JSON document, `source` is `startup` or `resume`, and the project
   has an `.alfred/config.json` agent_id. `clear` and `compact` do nothing.
3. The plugin's `bin/alfred-wake` (derived from `$0`) is readable, executable and
   has a `VERSION="x.y.z"` line.
4. The link target is a file or symlink (a directory, or a symlink to one, and a
   missing link are left alone; the hook never creates a link).
5. Already current (same resolved path, or `cmp` equal): no write.
6. Direction guard: a link or copy with a newer `VERSION` is left alone; an
   unknown `VERSION` counts as older.
7. Clobber guard: a regular file is replaced only with a `VERSION` line and the
   word `alfred-wake`. A symlink is always repointed.
8. Run `timeout 2 "$plugin_bin" install`, never the PATH bridge, and ignore its
   exit status. If the link is still not current, print one `additionalContext`
   line naming both versions (`unknown` without a `VERSION`, `missing` when the
   link is gone) and the command to run.

## Not covered

Other copies of `alfred-wake` on PATH, a `wait` already running (it keeps old
code until its next launch), and `clear` and `compact`.
