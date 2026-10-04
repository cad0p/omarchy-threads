#!/usr/bin/env bash
# End-to-end tests for bin/thread-store against a throwaway XDG_STATE_HOME.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
store=$here/../bin/thread-store
[[ -x $store ]] || { echo "thread-store not executable: $store" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export XDG_STATE_HOME=$tmp/state

checks=0
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
check() { # check <description> <expected> <actual>
  checks=$((checks + 1))
  [[ $2 == "$3" ]] || fail "$1: expected [$2], got [$3]"
}

# The entry always travels on stdin, never in argv.
upsert() { printf '%s' "$1" | $store upsert; }

now=$(date +%s%3N)

# --- upsert + count + newest-first -----------------------------------------
upsert "{\"timestamp\":$now,\"cookie\":1,\"id\":0,\"app\":\"Helium\",\"summary\":\"New email\",\"threadKey\":\"helium|s|New email\",\"threadLabel\":\"New email\",\"threadSource\":\"summary\"}"
upsert "{\"timestamp\":$((now + 1)),\"cookie\":2,\"id\":0,\"sender\":\":1.5\",\"app\":\"Slack\",\"summary\":\"#general\",\"threadKey\":\"slack|s|#general\",\"threadLabel\":\"#general\",\"threadSource\":\"summary\"}"
check "two entries stored" "2" "$($store count)"
check "newest first" "slack|s|#general" "$($store load | jq -r '.[0].threadKey')"
check "key derived from timestamp-cookie" "$((now + 1))-2" "$($store load | jq -r '.[0].key')"

# --- upsert is idempotent by key --------------------------------------------
# Two watchers can observe the same Notify during a shell rescan; the same
# (timestamp, cookie) must not stack a duplicate.
upsert "{\"timestamp\":$((now + 1)),\"cookie\":2,\"id\":0,\"sender\":\":1.5\",\"app\":\"Slack\",\"summary\":\"#general\",\"threadKey\":\"slack|s|#general\",\"threadLabel\":\"#general\",\"threadSource\":\"summary\"}"
check "re-upsert of the same key is a no-op" "2" "$($store count)"

# --- set-id backfill: cookies are per-connection, so the sender must match ---
$store set-id :1.5 2 43
check "id backfilled by (sender, cookie)" "43" "$($store load | jq -r '.[0].id')"
check "older entry untouched" "0" "$($store load | jq -r '.[1].id')"
$store set-id :9.9 2 99
check "same cookie from another sender is ignored" "43" "$($store load | jq -r '.[0].id')"

# --- replacesId removes the rewritten notification --------------------------
upsert "{\"timestamp\":$((now + 2)),\"cookie\":3,\"id\":0,\"sender\":\":1.6\",\"replacesId\":43,\"app\":\"Slack\",\"summary\":\"#general edited\",\"threadKey\":\"slack|s|#general\",\"threadLabel\":\"#general\",\"threadSource\":\"summary\"}"
check "replacement did not grow the archive" "2" "$($store count)"
check "replacement replaced the old text" "#general edited" "$($store load | jq -r '.[0].summary')"

# --- same-id supersede ------------------------------------------------------
# In real traffic the daemon backfills the replacement's own id first; only a
# later Notify that reuses that id should supersede it.
$store set-id :1.6 3 44
upsert "{\"timestamp\":$((now + 3)),\"cookie\":4,\"id\":44,\"app\":\"Slack\",\"summary\":\"same id again\",\"threadKey\":\"slack|s|#general\",\"threadLabel\":\"#general\",\"threadSource\":\"summary\"}"
check "same-id update replaced, not stacked" "2" "$($store count)"
check "same-id update won" "same id again" "$($store load | jq -r '.[0].summary')"

# --- remove one entry -------------------------------------------------------
$store remove "$((now + 3))-4"
check "remove dropped exactly one" "1" "$($store count)"
check "the right one stayed" "helium|s|New email" "$($store load | jq -r '.[0].threadKey')"

# --- remove-thread drops every entry of the conversation --------------------
upsert "{\"timestamp\":$((now + 4)),\"cookie\":5,\"id\":0,\"app\":\"Slack\",\"summary\":\"#general\",\"threadKey\":\"slack|s|#general\",\"threadLabel\":\"#general\",\"threadSource\":\"summary\"}"
$store remove-thread "slack|s|#general"
check "remove-thread cleared the conversation" "1" "$($store count)"

# --- retention --------------------------------------------------------------
old=$((now - 40 * 86400000))
upsert "{\"timestamp\":$old,\"cookie\":6,\"id\":0,\"app\":\"Old\",\"summary\":\"stale\",\"threadKey\":\"old|a|\",\"threadLabel\":\"Old\",\"threadSource\":\"app\"}"
check "stale entry pruned on write" "1" "$($store count)"

# --- mark-read / meta -------------------------------------------------------
$store mark-read 12345
check "readMark persisted" "12345" "$($store meta | jq -r '.readMark')"

# --- clear ------------------------------------------------------------------
$store clear
check "clear emptied the archive" "0" "$($store count)"
check "clear stored a clearedAt" "true" "$($store meta | jq '.clearedAt != null')"

# --- invalid input refused --------------------------------------------------
if printf '%s' 'this is not json' | $store upsert >/dev/null 2>&1; then
  fail "invalid JSON must not be accepted"
fi
check "archive survived the rejected write" "0" "$($store count)"
# /proc/<pid>/cmdline is readable by other local users, so an entry must never
# be accepted as an argument.
if $store upsert '{"timestamp":1}' </dev/null >/dev/null 2>&1; then
  fail "an argv-only entry must not be accepted"
fi
if $store set-id :1.5 abc 1 >/dev/null 2>&1; then
  fail "non-numeric cookie must be rejected"
fi

echo "OK: $checks store checks passed"
