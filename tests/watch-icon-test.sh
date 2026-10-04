#!/usr/bin/env bash
# End-to-end tests for bin/thread-watch icon resolution against a throwaway
# HOME/XDG_STATE_HOME. Synthetic busctl --json=short Notify lines go through
# --parse; no bus and no daemon are involved.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
watch=$here/../bin/thread-watch
[[ -x $watch ]] || { echo "thread-watch not executable: $watch" >&2; exit 1; }

tmp=$(mktemp -d)
badge_dir=/tmp/org.chromium.thread-center-test-$$
trap 'rm -rf "$tmp" "$badge_dir"' EXIT

export HOME=$tmp/home
mkdir -p "$HOME/.local/share/applications" "$tmp/bin"

# The real shell is not the subject here; pin DND off so parse_line is quiet.
cat > "$tmp/bin/omarchy-shell" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == notifications && ${2:-} == isDnd ]] && echo off
exit 0
EOF
chmod +x "$tmp/bin/omarchy-shell"
export PATH=$tmp/bin:$PATH

# A real 1x1 PNG; the watcher only checks the copy is non-empty, but a valid
# image keeps the fixture honest.
png=$tmp/icon.png
base64 -d > "$png" <<'EOF'
iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=
EOF
[[ -s $png ]] || { echo "failed to build the test PNG" >&2; exit 1; }

# Helium writes absolute Icon= paths for installed PWAs; a theme name must be
# ignored. WhatsApp is the brand resolved from web.whatsapp.com.
cat > "$HOME/.local/share/applications/foo.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=WhatsApp
Exec=/opt/helium-browser-bin/helium-wrapper --profile-directory=Default --app-id=hnpfjngllnobngcgfapefoaidbinmjnm
Icon=$png
EOF

checks=0
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
check() { # check <description> <expected> <actual>
  checks=$((checks + 1))
  [[ $2 == "$3" ]] || fail "$1: expected [$2], got [$3]"
}

notify_line() { # <body> <summary> <image-path-or-empty> [app-icon-or-empty]
  local body=$1 summary=$2 image_path=$3 app_icon=${4:-}
  local hints='{}'
  if [[ -n $image_path ]]; then
    hints=$(printf '{"image-path":{"type":"s","data":"%s"}}' "$image_path")
  fi
  printf '{"type":"method_call","member":"Notify","cookie":42,"sender":":1.99","payload":{"type":"susssasa{sv}i","data":["Helium",0,"%s","%s","%s",[],%s,-1]}}' \
    "$app_icon" "$summary" "$body" "$hints"
}

emit() { # <state-dir> <line>
  XDG_STATE_HOME=$1 "$watch" --parse <<<"$2"
}

# --- image-path hint: host from the URL, cached under the slug ---------------
state1=$tmp/state1
line=$(notify_line "New message https://user:pass@web.whatsapp.com:8443/chats/42" "WhatsApp" "$png")
out=$(emit "$state1" "$line")
check "notify event emitted" "notify" "$(jq -r '.event' <<<"$out")"
check "source host exported for the URL (userinfo and port stripped)" \
  "web.whatsapp.com" "$(jq -r '.source' <<<"$out")"
icon=$(jq -r '.icon' <<<"$out")
check "image-path hint cached under the URL host" \
  "$state1/omarchy/thread-center/icons/web.whatsapp.com.png" "$icon"
[[ -f $icon ]] || fail "cache file missing: $icon"
cmp -s "$png" "$icon" || fail "cache content differs from the image-path source"

# --- the cache wins over a newer source (idempotent per host) ----------------
other=$tmp/other.png
printf 'different bytes' > "$other"
line=$(notify_line "Another https://web.whatsapp.com/chats/43" "WhatsApp" "$other")
out=$(emit "$state1" "$line")
check "existing cache wins over a new source" \
  "$state1/omarchy/thread-center/icons/web.whatsapp.com.png" "$(jq -r '.icon' <<<"$out")"
cmp -s "$png" "$icon" || fail "cache was rewritten for an already-cached host"
# The focus classes are cached beside the icon, so a cache hit still exports
# the derived wmClass (and omits StartupWMClass when the entry declares none).
check "cached icon still exports the derived wmClass" \
  "chrome-hnpfjngllnobngcgfapefoaidbinmjnm-Default" "$(jq -r '.wmClass' <<<"$out")"
check "no StartupWMClass declared means the field is absent" \
  "null" "$(jq -r '.startupWmClass' <<<"$out")"

# --- desktop match: no image-path, Name contains the host label --------------
state2=$tmp/state2
line=$(notify_line "Ping https://web.whatsapp.com/chats/44" "WhatsApp" "")
out=$(emit "$state2" "$line")
icon2=$(jq -r '.icon' <<<"$out")
check "desktop entry icon cached for the host label" \
  "$state2/omarchy/thread-center/icons/web.whatsapp.com.png" "$icon2"
[[ -f $icon2 ]] || fail "desktop-match cache file missing: $icon2"
cmp -s "$png" "$icon2" || fail "desktop-match cache content differs from the Icon= source"

# --- a browser entry matching a host label is not an installed web app -------
cat > "$HOME/.local/share/applications/chrome.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Google Chrome
Icon=$png
Exec=/usr/bin/google-chrome-stable
EOF
line=$(notify_line "Ping https://mail.google.com/mail/u/0" "Mail" "")
out=$(emit "$state2" "$line")
check "browser entry does not answer for a host label" "" "$(jq -r '.icon' <<<"$out")"

# --- a generic token in another web app's name is not the brand --------------
# Proton is also the app-id-shaped PWA fixture for the focus-class checks.
cat > "$HOME/.local/share/applications/proton.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Proton Mail
Icon=$png
StartupWMClass=crx_jnpecgipniidlgicjocehkhajgdnjekh
Exec=/opt/helium-browser-bin/helium-wrapper --profile-directory=Default --app-id=jnpecgipniidlgicjocehkhajgdnjekh
EOF
line=$(notify_line "Ping https://mail.google.com/mail/u/0" "Mail" "")
out=$(emit "$state2" "$line")
check "Proton Mail's token does not answer for mail.google.com" "" "$(jq -r '.icon' <<<"$out")"

# --- app-id-shaped window class: derived wmClass + differing StartupWMClass --
# The desktop entry declares crx_<app-id>, but the live window is
# chrome-<app-id>-Default; both are exported and tried in that order.
state6=$tmp/state6
line=$(notify_line "New email https://mail.proton.me/u/0/inbox" "Proton Mail" "")
out=$(emit "$state6" "$line")
check "derived wmClass exported for an app-id-shaped class" \
  "chrome-jnpecgipniidlgicjocehkhajgdnjekh-Default" "$(jq -r '.wmClass' <<<"$out")"
check "StartupWMClass exported when it differs from wmClass" \
  "crx_jnpecgipniidlgicjocehkhajgdnjekh" "$(jq -r '.startupWmClass' <<<"$out")"
check "proton icon resolved from the matched entry" \
  "$state6/omarchy/thread-center/icons/mail.proton.me.png" "$(jq -r '.icon' <<<"$out")"
focus_sidecar=$state6/omarchy/thread-center/icons/mail.proton.me.png.focus
[[ -f $focus_sidecar ]] || fail "focus sidecar missing after the fresh desktop match"

# --- the cached icon answers from the sidecar, without a desktop scan --------
line=$(notify_line "Second https://mail.proton.me/u/0/inbox" "Proton Mail" "$other")
out=$(emit "$state6" "$line")
check "cached icon still exports the derived wmClass" \
  "chrome-jnpecgipniidlgicjocehkhajgdnjekh-Default" "$(jq -r '.wmClass' <<<"$out")"
check "cached icon still exports StartupWMClass" \
  "crx_jnpecgipniidlgicjocehkhajgdnjekh" "$(jq -r '.startupWmClass' <<<"$out")"

# --- an icon cache from before sidecars existed is backfilled once -----------
rm -f "$focus_sidecar"
line=$(notify_line "Third https://mail.proton.me/u/0/inbox" "Proton Mail" "")
out=$(emit "$state6" "$line")
check "pre-sidecar icon cache is backfilled" \
  "chrome-jnpecgipniidlgicjocehkhajgdnjekh-Default" "$(jq -r '.wmClass' <<<"$out")"
[[ -f $focus_sidecar ]] || fail "sidecar was not rewritten for a pre-sidecar icon cache"

# --- no URL in body or summary: no icon, and no cache dir created ------------
state3=$tmp/state3
line=$(notify_line "just text, no link" "Helium" "$png")
out=$(emit "$state3" "$line")
check "no URL leaves icon empty" "" "$(jq -r '.icon' <<<"$out")"
check "no URL leaves source empty" "" "$(jq -r '.source' <<<"$out")"
[[ ! -e $state3/omarchy/thread-center/icons ]] || fail "icons dir created without a host"

# --- Chromium temp badge as appIcon is never identity ------------------------
mkdir -p "$badge_dir"
cp "$png" "$badge_dir/logo.png"
line=$(notify_line "Ping https://chat.example.com/room" "Helium" "" "$badge_dir/logo.png")
out=$(emit "$state3" "$line")
check "chromium temp badge is refused" "" "$(jq -r '.icon' <<<"$out")"
check "source is exported even when the icon is refused" \
  "chat.example.com" "$(jq -r '.source' <<<"$out")"

# --- a real, non-browser appIcon is a valid fallback -------------------------
state4=$tmp/state4
line=$(notify_line "Ping https://forum.example.com/post" "Forum" "" "$png")
out=$(emit "$state4" "$line")
icon4=$(jq -r '.icon' <<<"$out")
check "regular appIcon is used as a fallback" \
  "$state4/omarchy/thread-center/icons/forum.example.com.png" "$icon4"
[[ -f $icon4 ]] || fail "appIcon-fallback cache file missing: $icon4"

# --- the real-world shape: doomed badge appIcon, site artwork image-path -----
state5=$tmp/state5
cp "$png" "$badge_dir/icon.png"
line=$(notify_line "Ping https://web.whatsapp.com/chats/46" "WhatsApp" "$badge_dir/icon.png" "file://$badge_dir/logo.png")
out=$(emit "$state5" "$line")
icon5=$(jq -r '.icon' <<<"$out")
check "site artwork under /tmp/org.chromium is still cached" \
  "$state5/omarchy/thread-center/icons/web.whatsapp.com.png" "$icon5"
cmp -s "$png" "$icon5" || fail "site artwork was not copied"

# --- an unwritable cache dir must not drop the event -------------------------
blocked=$tmp/blocked
: > "$blocked"
line=$(notify_line "Ping https://example.net/x" "X" "$png")
out=$(emit "$blocked" "$line") || fail "event dropped when the cache dir was unwritable"
check "unwritable cache dir still emits the event" "notify" "$(jq -r '.event' <<<"$out")"
check "unwritable cache dir leaves icon empty" "" "$(jq -r '.icon' <<<"$out")"
# The desktop match is independent of the artwork: focus metadata survives a
# failed icon copy.
line=$(notify_line "Ping https://mail.proton.me/u/0/inbox" "Proton Mail" "$png")
out=$(emit "$blocked" "$line") || fail "event dropped for a host with a desktop match"
check "wmClass survives an unwritable icon cache" \
  "chrome-jnpecgipniidlgicjocehkhajgdnjekh-Default" "$(jq -r '.wmClass' <<<"$out")"

# --- XDG_STATE_HOME unset falls back to HOME/.local/state --------------------
line=$(notify_line "Ping https://status.example.org/incident" "Status" "$png")
out=$(env -u XDG_STATE_HOME "$watch" --parse <<<"$line")
check "XDG_STATE_HOME unset falls back to HOME/.local/state" \
  "$HOME/.local/state/omarchy/thread-center/icons/status.example.org.png" "$(jq -r '.icon' <<<"$out")"

# --- method_return id events still pass through unchanged --------------------
id_line='{"type":"method_return","destination":":1.5","reply_cookie":9,"payload":{"type":"u","data":[30]}}'
out=$("$watch" --parse <<<"$id_line")
check "id backfill event unchanged" '{"event":"id","sender":":1.5","cookie":9,"id":30}' "$out"

echo "OK: $checks watcher icon checks passed"
