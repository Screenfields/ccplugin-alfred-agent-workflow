Review the change below against its work item. The repo files it touches are quoted as they are on the branch, after the diff.

## Work item (repo Screenfields/ccplugin-alfred-agent-workflow, issue #142)

**Title:** `alfred-config get` takes `--default VALUE`

**Success state:** A skill can read an optional threshold with a fallback in one call, without a shell `||` that would also hide a broken config.

**Acceptance criteria**

1. `alfred-config get <name> --default X` prints the value of `<name>` when it exists, including a value of `false`.
2. When `<name>` does not exist, it prints `X` and exits 0.
3. A missing or malformed thresholds file still exits 2 with a message on stderr, with or without `--default`.
4. Nothing else changes: `names` prints the same output as before, and every other exit code stays the same.
5. The usage text and the README describe `--default`.

**Bounds:** `bin/alfred-config`, `tests/thresholds.bats`, `README.md`. No other files.

## Diff

```diff
diff --git a/bin/alfred-config b/bin/alfred-config
--- a/bin/alfred-config
+++ b/bin/alfred-config
@@ -6,7 +6,7 @@
 # skill text (AP-ADR0031 item 8).
 #
-#   alfred-config get <name> [--file PATH]   print the value; strings raw,
+#   alfred-config get <name> [--default VALUE] [--file PATH]   print the value; strings raw,
 #                                            numbers/booleans/objects/arrays
 #                                            as compact JSON
 #   alfred-config names [--file PATH]        print every name, one per line
@@ -18,7 +18,7 @@ file="${ALFRED_THRESHOLDS:-$(dirname "$SELF")/../config/thresholds.json}"
 usage() {
-  echo "usage: alfred-config get <name> [--file PATH] | names [--file PATH]" >&2
+  echo "usage: alfred-config get <name> [--default VALUE] [--file PATH] | names [--file PATH]" >&2
   exit 2
 }
@@ -26,10 +26,14 @@ usage() {
 cmd="${1:-}"
 [ -n "$cmd" ] || usage
 shift
 name=""
+default=""
+have_default=0
 if [ "$cmd" = "get" ]; then
   [ $# -ge 1 ] || usage
   name="$1"
   shift
 fi
 while [ $# -gt 0 ]; do
   case "$1" in
     --file) [ $# -ge 2 ] || usage; file="$2"; shift 2 ;;
+    --default) [ $# -ge 2 ] || usage; default="$2"; have_default=1; shift 2 ;;
     *) usage ;;
   esac
 done
@@ -37,13 +41,24 @@ done
 command -v jq >/dev/null 2>&1 || { echo "alfred-config: requires jq" >&2; exit 2; }
-jq -e 'type == "object"' "$file" >/dev/null 2>&1 \
-  || { echo "alfred-config: missing or malformed thresholds file: $file" >&2; exit 2; }
+if ! jq -e 'type == "object"' "$file" >/dev/null 2>&1; then
+  if [ "$have_default" -eq 1 ]; then
+    printf '%s\n' "$default"
+    exit 0
+  fi
+  echo "alfred-config: missing or malformed thresholds file: $file" >&2
+  exit 2
+fi

 case "$cmd" in
   get)
-    jq -e --arg n "$name" 'has($n)' "$file" >/dev/null 2>&1 \
-      || { echo "alfred-config: unknown threshold: $name" >&2; exit 2; }
-    jq -r --arg n "$name" '.[$n] | if type == "string" then . else tojson end' "$file"
+    if jq -e --arg n "$name" 'has($n)' "$file" >/dev/null 2>&1; then
+      jq -r --arg n "$name" '.[$n] | if type == "string" then . else tojson end' "$file"
+    elif [ "$have_default" -eq 1 ]; then
+      printf '%s\n' "$default"
+    else
+      echo "alfred-config: unknown threshold: $name" >&2
+      exit 2
+    fi
     ;;
-  names) jq -r 'keys_unsorted[]' "$file" ;;
+  names) jq -r 'to_entries[] | select(.value | type != "object") | .key' "$file" ;;
   *) usage ;;
 esac
diff --git a/tests/thresholds.bats b/tests/thresholds.bats
--- a/tests/thresholds.bats
+++ b/tests/thresholds.bats
@@ -60,3 +60,28 @@ names_in() {
 @test "an unknown name exits 2" {
   run "$CFG" get no-such-threshold
   [ "$status" -eq 2 ]
 }
+
+@test "get --default prints the value when the name exists" {
+  run "$CFG" get wip-limit --default 9
+  [ "$status" -eq 0 ]
+  [ "$output" = "2" ]
+}
+
+@test "get --default prints the default for an unknown name" {
+  run "$CFG" get no-such-threshold --default 9
+  [ "$status" -eq 0 ]
+  [ "$output" = "9" ]
+}
+
+@test "get --default does not replace a false value" {
+  printf '{"flag": false}\n' > "$BATS_TEST_TMPDIR/f.json"
+  run "$CFG" get flag --default 9 --file "$BATS_TEST_TMPDIR/f.json"
+  [ "$status" -eq 0 ]
+  [ "$output" = "false" ]
+}
+
+@test "a missing thresholds file still exits 2 with --default" {
+  run env ALFRED_THRESHOLDS=/nonexistent "$CFG" get wip-limit
+  [ "$status" -eq 2 ]
+}
```

## Repo file: config/thresholds.json (top-level keys, as on the branch)

`overrun-pct`, `wip-limit`, `worker-limit`, `failed-review-max`, `recovery-inform-minutes`, `unread-flag-minutes`, `inactive-flag-days`, `several-leads-min`, `model-setting-per-role` (an object), `waiting-label`, `ready-state`, `workable-states` (an array), `loop-check-enabled`, `loop-check-timeout-seconds`, `loop-check-deadline-seconds`, `chase-interval-minutes`, `chase-max-tries`, `loop-check-max-blocks-per-hour`.

## Repo file: README.md, section "Thresholds" (on the branch, not touched by the diff)

> All thresholds live in one file and are read by name, so no rule or skill text carries a number: `alfred-config get wip-limit`. An unknown name, or a missing or malformed file, exits 2. `alfred-config names` lists the keys.

## Test run reported by the builder

`bats tests/thresholds.bats`: 11 tests, 0 failures.
