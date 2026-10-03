# Threads — Omarchy notification center with true conversation grouping

Plugin id: `cad0p.thread-center` · kind: `bar-widget` · author: cad0p (Pier)

## Why

Omarchy's stock notification pipeline (`/usr/share/omarchy/shell/plugins/notifications/NotificationLogic.js`)
strips all hints except `omarchy-glyph`/`omarchy-exec` in `snapshotOf()`, so no existing
center can group below app level. The full `Notify` payload (with hints) is, however,
visible on the session bus. This plugin is a passive bus observer: it sees everything
(including DND-silenced and non-stock-daemon notifications), archives it, and groups by
conversation.

## Architecture

```
bin/thread-watch   busctl monitor -> one JSON event per line on stdout
bin/thread-store   bash+jq archive: load | upsert JSON | set-id cookie id | remove key | remove-thread tkey | clear | prune
ThreadLogic.js     pure JS: thread key/label, upsert merge, prune, grouping/rows, search, time fmt (node-testable)
Panel.qml          qs.Ui.Panel root: BarIconButton + KeyboardPanel + thread UI + IPC
```

### Watcher contract (`bin/thread-watch`)

Runs two busctl matches in one process (verified working):

```
busctl --user monitor --json=short \
  --match "type='method_call',interface='org.freedesktop.Notifications',member='Notify'" \
  --match "type='method_return',sender='org.freedesktop.Notifications'"
```

Line types emitted (one JSON object per stdout line):

1. `{"event":"notify", "cookie":N, "id":0, "replacesId":R, "app":..., "appIcon":...,
   "summary":..., "body":..., "urgency":1, "actions":[...], "hints":{...string hints...},
   "silenced":bool, "timestamp":ms}` — on each `method_call` Notify.
   No pairing delay: id starts 0.
2. `{"event":"id","sender":":1.1689","cookie":N,"id":X}` — when the daemon's `method_return`
   with `reply_cookie == N` arrives; QML backfills the entry's id. The sender is
   the `destination` of the return (the original caller's unique name). D-Bus
   cookies are per-connection counters — every fresh `notify-send` run starts at
   cookie 9 — so pairing must include the connection name; matching on cookie
   alone backfills the wrong entries.

Verified probe (notify-send with hints) on this machine:
- call has `"cookie":9`, payload `susssasa{sv}i` = `["notify-send",0,"","Probe Title","Probe body",[],{"x-kde-eventId":{"type":"s","data":"groupA"},"x-dunst-stack-tag":{"type":"s","data":"groupA"},"urgency":{"type":"y","data":1}},-1]`
- reply has `"cookie":303,"reply_cookie":9`, payload `{"type":"u","data":[30]}` → id 30.
- match `sender='org.freedesktop.Notifications'` resolves to the owning unique name and
  yields the daemon's replies (including GetCapabilities ones — filter by reply_cookie).
Reference implementation for parsing/limits: attention-required `bin/ar-watch`
(saved at `/tmp/ar-watch.ref`, MIT): clip lengths, hint extraction, size cap 256KB.

### Thread key (`ThreadLogic.js`)

```
appId     = hints["desktop-entry"] || hints["x-ayatana-app-id"] || senderExeBase || app
hintKey   = hints["x-dunst-stack-tag"] || hints["x-kde-eventId"] || ""
if hintKey      -> key = appId + "|h|" + hintKey,   source = "hint:x-dunst-stack-tag"|"hint:x-kde-eventId"
else if summary -> key = appId + "|s|" + summary,   source = "summary"
else            -> key = appId + "|a|",             source = "app"
label = latest entry summary (conversation name for chat apps) || app
```
Config: `fallbackGrouping: "summary" | "app"` (default summary).

### Store contract

Archive `$XDG_STATE_HOME/omarchy/thread-center/archive.json` = JSON array (newest first),
entries carry `key` = `"<timestamp>-<cookie||id>"` plus threadKey/threadLabel/threadSource.
Meta `state.json` = `{readMark, clearedAt}` (optional; readMark may live in archive meta object).
`upsert`: if `replacesId > 0` remove entry with `id == replacesId`; else if `id > 0`
remove same id; prepend; prune (keepDays 30, maxEntries 2000); atomic tmp+mv. Prints nothing on success.
`load`: cat archive (or `[]`).
`set-id sender cookie id`: set id on the entry matching both sender and cookie.
`remove key` / `remove-thread threadKey` / `clear`; `prune`.
All jq string comparisons exact; never `eval` shell with payload.

### Panel UI

- Root `Panel { moduleName/ipcTarget "cad0p.thread-center" }`, `BarIconButton` filled to
  the bar slot, glyph + unread count overlay. `onPressed` toggles.
- `KeyboardPanel { anchorItem: button; owner: root; bar: root.bar; open: root.opened;
  focusTarget: keyCatcher; contentWidth/contentHeight }`.
- Content: header (title, search `Ui.TextField`, clear-all button), `ListView` of rows:
  thread header (icon, label, app, count pill, relative time, dismiss ×) with expandable
  entries (summary, clamped body, time, ×). Threads ordered by newest entry.
- `PanelKeyCatcher` (blocked while search focused): j/k move, enter toggle expand /
  focus app, x dismiss entry, X dismiss thread, / focus search, c clear, esc close.
- Read state: opening sets `readMark = now` (persisted); unread = entries after readMark.
- Colors: `Color.popups.background/text/border`, `Color.foreground/accent`,
  `bar.foreground`, `bar.fontFamily`; spacing via `Style.space`/`Style.font`.
- App icon: if starts `file://`/`image://` use as-is else `image://icon/<value>`
  (stock NotificationCard convention); fallback glyph.

### Boot

`Component.onCompleted`: load archive (`thread-store load`), start watcher `Process`
(`SplitParser` on lines), on `notify` upsert into JS array + store + refresh rows;
on `id` patch. Panel opens -> refresh + mark read. Hot-reload safe (states in files).

## Env facts

- Installed shell: `/usr/share/omarchy/shell` (READ-ONLY source; user plugins in
  `~/.config/omarchy/plugins/<id>/`). Version 4.0.0.alpha.
- `Ui` module (import qs.Ui): `Panel`, `KeyboardPanel`, `PanelKeyCatcher`, `BarIconButton`,
  `TextField`, `PopupCard`, `PanelActionButton`, `PanelSectionHeader`, `WidgetButton`...
- Reference panels: `shell/plugins/panels/network/Panel.qml` (bar button + KeyboardPanel +
  PanelKeyCatcher + vim nav), `shell/plugins/panels/audio/Panel.qml`.
- Manifest for panel-widgets: kinds ["bar-widget"], entryPoints.barWidget -> Panel.qml,
  barWidget {displayName, description, category, defaultSection}.
- Commands: `omarchy plugin validate .`, `omarchy plugin list`, `omarchy restart shell`,
  `omarchy bar move cad0p.thread-center --section right`, `omarchy-shell shell rescanPlugins`.
- Test notifications: `notify-send -h string:x-kde-eventId:groupA "Title" "body"`;
  omit `-h` to test summary fallback. `omarchy-notification-send` for Omarchy-native.
- Dev layout: repo at `~/personal/github/omarchy-thread-center`, symlinked as
  `~/.config/omarchy/plugins/cad0p.thread-center`.

## Test plan

- `tests/store-test.sh`: fixture Notify JSON -> store upsert/replace/prune/remove-thread;
  assert with jq. Pure bash+jq, no network.
- `tests/threadlogic.test.js`: node tests for key priority (hints > summary > app),
  replace-by-id merge, grouping rows, search, prune.
- E2E: start `bin/thread-watch` manually, send notify-send with/without hints, verify
  events + store contents; then enable plugin and screenshot the panel with grim.
