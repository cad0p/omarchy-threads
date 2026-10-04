// Node tests for ThreadLogic.js. No QML, no network, no wall clock: every
// call that needs "now" gets it through opts/arguments.
"use strict"

const assert = require("assert")
const T = require("../ThreadLogic.js")

let passed = 0
function test(name, fn) {
  try {
    fn()
    passed++
  } catch (error) {
    console.error("FAIL: " + name)
    console.error(String(error && error.stack ? error.stack : error))
    process.exitCode = 1
  }
}

test("hintValue unwraps busctl {type,data} hints", () => {
  assert.strictEqual(T.hintValue({ type: "s", data: "groupA" }), "groupA")
  assert.strictEqual(T.hintValue("plain"), "plain")
  assert.strictEqual(T.hintValue(undefined), undefined)
})

test("baseName returns the executable name", () => {
  assert.strictEqual(T.baseName("/usr/lib/helium/helium"), "helium")
  assert.strictEqual(T.baseName(""), "")
})

test("dismissSummaries dedupes and trims summaries for the dismiss IPC", () => {
  assert.deepStrictEqual(
    T.dismissSummaries([
      { summary: "Family Chat" },
      { summary: "  Family Chat  " },
      { summary: "" },
      { summary: "Standup" },
      null
    ]),
    ["Family Chat", "Standup"])
  assert.deepStrictEqual(T.dismissSummaries(undefined), [])
})

test("threadFor prefers x-dunst-stack-tag and records its source", () => {
  const thread = T.threadFor({
    app: "WhatsApp",
    hints: { "x-dunst-stack-tag": "Group Chat", "x-kde-eventId": "ignored" }
  })
  assert.strictEqual(thread.key, "WhatsApp|h|Group Chat")
  assert.strictEqual(thread.source, "hint:x-dunst-stack-tag")
  assert.strictEqual(thread.label, "WhatsApp")
})

test("threadFor falls through to x-kde-eventId", () => {
  const thread = T.threadFor({ app: "Signal", hints: { "x-kde-eventId": "chat-42" }, summary: "Alice" })
  assert.strictEqual(thread.key, "Signal|h|chat-42")
  assert.strictEqual(thread.source, "hint:x-kde-eventId")
})

test("threadFor falls back to app+summary, then to app", () => {
  const withSummary = T.threadFor({ app: "Slack", summary: "#general" })
  assert.strictEqual(withSummary.key, "Slack|s|#general")
  assert.strictEqual(withSummary.source, "summary")
  assert.strictEqual(withSummary.label, "#general")

  const noSummary = T.threadFor({ app: "Slack" })
  assert.strictEqual(noSummary.key, "Slack|a|")
  assert.strictEqual(noSummary.source, "app")
})

test("threadFor app fallback honors fallbackGrouping: app", () => {
  const thread = T.threadFor({ app: "Slack", summary: "#general" }, { fallbackGrouping: "app" })
  assert.strictEqual(thread.key, "Slack|a|")
  assert.strictEqual(thread.source, "app")
})

test("appId priority: desktop-entry > x-ayatana-app-id > senderExe > app", () => {
  assert.strictEqual(T.appIdFor({ app: "x", hints: { "desktop-entry": "org.kde.dolphin" } }), "org.kde.dolphin")
  assert.strictEqual(T.appIdFor({ app: "x", hints: { "x-ayatana-app-id": "telegram-desktop" } }), "telegram-desktop")
  assert.strictEqual(T.appIdFor({ app: "x", senderExe: "/usr/bin/slack" }), "slack")
  assert.strictEqual(T.appIdFor({ app: "x" }), "x")
})

test("entryKey combines timestamp and cookie", () => {
  assert.strictEqual(T.entryKey({ timestamp: 1000, cookie: 7 }), "1000-7")
  assert.strictEqual(T.entryKey({ timestamp: 1000, id: 9 }), "1000-9")
})

test("applyEvent prepends, enriching raw events with thread fields", () => {
  const list = T.applyEvent([], { timestamp: 1000, cookie: 1, app: "Slack", summary: "#general" }, { now: 1000 })
  assert.strictEqual(list.length, 1)
  assert.strictEqual(list[0].key, "1000-1")
  assert.strictEqual(list[0].threadKey, "Slack|s|#general")
  assert.strictEqual(list[0].threadLabel, "#general")
  assert.strictEqual(list[0].threadSource, "summary")

  const more = T.applyEvent(list, { timestamp: 2000, cookie: 2, app: "Slack", summary: "#general" }, { now: 2000 })
  assert.strictEqual(more.length, 2)
  assert.strictEqual(more[0].key, "2000-2")
})

test("applyEvent drops the entry a replacesId rewrites", () => {
  let list = T.applyEvent([], { timestamp: 1000, cookie: 1, id: 42, app: "Slack", summary: "old" }, { now: 1000 })
  list = T.applyEvent(list, { timestamp: 2000, cookie: 2, replacesId: 42, app: "Slack", summary: "new" }, { now: 2000 })
  assert.strictEqual(list.length, 1)
  assert.strictEqual(list[0].summary, "new")
})

test("applyEvent drops a previous entry holding the same daemon id", () => {
  let list = T.applyEvent([], { timestamp: 1000, cookie: 1, id: 7, app: "Slack", summary: "first" }, { now: 1000 })
  list = T.applyEvent(list, { timestamp: 2000, cookie: 2, id: 7, app: "Slack", summary: "second" }, { now: 2000 })
  assert.strictEqual(list.length, 1)
  assert.strictEqual(list[0].summary, "second")
})

test("applyId backfills by (sender, cookie) and leaves others alone", () => {
  const list = T.applyEvent([], { timestamp: 1000, cookie: 5, sender: ":1.5", app: "X" }, { now: 1000 })
  const patched = T.applyId(list, ":1.5", 5, 88)
  assert.strictEqual(patched[0].id, 88)
  assert.strictEqual(patched[0].key, list[0].key)
  // A different connection reusing cookie 5 must not be patched.
  assert.strictEqual(T.applyId(list, ":1.9", 5, 1)[0].id, undefined)
  assert.strictEqual(T.applyId(list, ":1.5", 999, 1)[0].id, undefined)
})

test("prune enforces keepDays and maxEntries on a newest-first list", () => {
  const now = 10 * 86400000
  const entries = [
    { timestamp: now, key: "a" },
    { timestamp: now - 9 * 86400000, key: "b" },
    { timestamp: now - 40 * 86400000, key: "c" }
  ]
  const kept = T.prune(entries, { now: now, keepDays: 30, maxEntries: 10 })
  assert.deepStrictEqual(kept.map(e => e.key), ["a", "b"])
  const capped = T.prune(entries, { now: now, keepDays: 30, maxEntries: 1 })
  assert.deepStrictEqual(capped.map(e => e.key), ["a"])
})

test("applyEvent keeps a derived icon on the entry", () => {
  const list = T.applyEvent([], { timestamp: 1000, cookie: 1, app: "WhatsApp", icon: "/state/wa.png" }, { now: 1000 })
  assert.strictEqual(list[0].icon, "/state/wa.png")
})

test("firstLink picks the first http(s) anchor, else a plain URL", () => {
  assert.strictEqual(T.firstLink({
    body: '<a href="https://web.whatsapp.com/">web.whatsapp.com</a>\nAhhaahhaa'
  }), "https://web.whatsapp.com/")
  // Non-http anchors are skipped; a bare URL in the body is the fallback.
  assert.strictEqual(T.firstLink({
    body: '<a href="mailto:x@example.com">mail</a> see https://example.com/deep/link.'
  }), "https://example.com/deep/link")
  // The summary is searched when the body carries no link.
  assert.strictEqual(T.firstLink({ summary: "https://example.com/from-summary", body: "plain" }),
    "https://example.com/from-summary")
  assert.strictEqual(T.firstLink({ body: "no links here" }), "")
  assert.strictEqual(T.firstLink(null), "")
})

test("applyEvent stores the durable link without overwriting one", () => {
  const anchored = T.applyEvent([], {
    timestamp: 1000, cookie: 1, app: "Helium", summary: "Family Chat",
    body: '<a href="https://web.whatsapp.com/">web.whatsapp.com</a>\nhello'
  }, { now: 1000 })
  assert.strictEqual(anchored[0].link, "https://web.whatsapp.com/")
  const explicit = T.applyEvent([], {
    timestamp: 2000, cookie: 2, app: "Helium", summary: "x",
    body: "https://wrong.example/", link: "https://explicit.example/deep"
  }, { now: 2000 })
  assert.strictEqual(explicit[0].link, "https://explicit.example/deep")
  const none = T.applyEvent([], { timestamp: 3000, cookie: 3, app: "Slack", summary: "no link" }, { now: 3000 })
  assert.strictEqual(none[0].link, "")
})

test("canInvokeLive needs a daemon id and a default action", () => {
  assert.strictEqual(T.canInvokeLive({ id: 21, actions: ["default", "Activate"] }), true)
  assert.strictEqual(T.canInvokeLive({ id: 0, actions: ["default"] }), false)
  assert.strictEqual(T.canInvokeLive({ id: 21, actions: ["reply", "Reply"] }), false)
  assert.strictEqual(T.canInvokeLive({ id: 21 }), false)
  assert.strictEqual(T.canInvokeLive(null), false)
})

test("sourceHost normalizes the watcher's web source field", () => {
  assert.strictEqual(T.sourceHost({ source: "web.whatsapp.com" }), "web.whatsapp.com")
  assert.strictEqual(T.sourceHost({ source: "https://User:pa%40ss@Web.WhatsApp.com:8443/chats/42" }), "web.whatsapp.com")
  assert.strictEqual(T.sourceHost({ source: "mail.proton.me" }), "mail.proton.me")
  assert.strictEqual(T.sourceHost({ source: "" }), "")
  assert.strictEqual(T.sourceHost({}), "")
  assert.strictEqual(T.sourceHost(null), "")
})

test("isWebOrigin is true only for a bare origin link", () => {
  const whatsapp = {
    source: "web.whatsapp.com",
    link: "https://web.whatsapp.com/",
    body: '<a href="https://web.whatsapp.com/">web.whatsapp.com</a>\nhello'
  }
  assert.strictEqual(T.isWebOrigin(whatsapp), true)
  // Without a stored link the first link in the body is used.
  assert.strictEqual(T.isWebOrigin({ source: "mail.proton.me", body: "https://mail.proton.me/" }), true)
  // A real per-conversation deep link must keep opening normally.
  assert.strictEqual(T.isWebOrigin({ source: "web.whatsapp.com", link: "https://web.whatsapp.com/chats/42" }), false)
  assert.strictEqual(T.isWebOrigin({ source: "mail.proton.me", link: "https://mail.proton.me/u/0/inbox" }), false)
  // A link on a different host is not this sender's web origin.
  assert.strictEqual(T.isWebOrigin({ source: "web.whatsapp.com", link: "https://example.com/" }), false)
  // Older rows carry no `source`; a bare origin still names the web app.
  assert.strictEqual(T.isWebOrigin({ link: "https://web.whatsapp.com/" }), true)
  assert.strictEqual(T.isWebOrigin({ body: '<a href="https://web.whatsapp.com/">web.whatsapp.com</a>' }), true)
  assert.strictEqual(T.isWebOrigin({ link: "https://mail.proton.me/u/0/inbox" }), false)
  // A web sender whose archived link is missing is still a web sender.
  assert.strictEqual(T.isWebOrigin({ source: "web.whatsapp.com" }), true)
  assert.strictEqual(T.isWebOrigin(null), false)
})

test("focusTargets tries host, derived wmClass, StartupWMClass, then app id", () => {
  assert.deepStrictEqual(
    T.focusTargets({ source: "web.whatsapp.com", appId: "Helium" }),
    ["web.whatsapp.com", "Helium"])
  assert.deepStrictEqual(T.focusTargets({ source: "web.whatsapp.com", app: "Helium" }),
    ["web.whatsapp.com", "Helium"])
  assert.deepStrictEqual(T.focusTargets({ app: "Slack" }), ["Slack"])
  // Rows without `source` still focus the link's host first.
  assert.deepStrictEqual(T.focusTargets({ link: "https://mail.proton.me/" }), ["mail.proton.me"])
  assert.deepStrictEqual(T.focusTargets({ link: "https://mail.proton.me/u/0/inbox", app: "Helium" }),
    ["mail.proton.me", "Helium"])
  assert.deepStrictEqual(T.focusTargets({ source: "web.whatsapp.com", appId: "web.whatsapp.com" }),
    ["web.whatsapp.com"])
  assert.deepStrictEqual(T.focusTargets({ source: "web.whatsapp.com" }), ["web.whatsapp.com"])
  assert.deepStrictEqual(T.focusTargets({}), [])
  assert.deepStrictEqual(T.focusTargets(null), [])

  // App-id-shaped PWA (Proton Mail): the derived live window class is tried
  // before the declared crx_ StartupWMClass and before the app id.
  assert.deepStrictEqual(T.focusTargets({
    source: "mail.proton.me",
    wmClass: "chrome-jnpecgipniidlgicjocehkhajgdnjekh-Default",
    startupWmClass: "crx_jnpecgipniidlgicjocehkhajgdnjekh",
    appId: "Helium"
  }), [
    "mail.proton.me",
    "chrome-jnpecgipniidlgicjocehkhajgdnjekh-Default",
    "crx_jnpecgipniidlgicjocehkhajgdnjekh",
    "Helium"
  ])

  // Duplicates collapse across fields and empty slots are skipped.
  assert.deepStrictEqual(T.focusTargets({
    source: "mail.proton.me",
    wmClass: "mail.proton.me",
    startupWmClass: "crx_x",
    app: "crx_x"
  }), ["mail.proton.me", "crx_x"])
  assert.deepStrictEqual(T.focusTargets({
    source: "web.whatsapp.com", wmClass: "", startupWmClass: "", appId: ""
  }), ["web.whatsapp.com"])
})

test("borrowFocus fills focus classes from a same-host sibling", () => {
  const old = { key: "a", link: "https://mail.proton.me/", app: "Helium" }
  const fresh = { key: "b", source: "mail.proton.me",
    wmClass: "chrome-jnpecgipniidlgicjocehkhajgdnjekh-Default",
    startupWmClass: "crx_jnpecgipniidlgicjocehkhajgdnjekh" }
  // An old row takes the classes of a same-host sibling...
  assert.deepStrictEqual(T.borrowFocus(old, [fresh]), {
    key: "a", link: "https://mail.proton.me/", app: "Helium",
    wmClass: "chrome-jnpecgipniidlgicjocehkhajgdnjekh-Default",
    startupWmClass: "crx_jnpecgipniidlgicjocehkhajgdnjekh"
  })
  // ...and the borrowed entry focuses the PWA class before the browser app.
  assert.deepStrictEqual(T.focusTargets(T.borrowFocus(old, [fresh])), [
    "mail.proton.me",
    "chrome-jnpecgipniidlgicjocehkhajgdnjekh-Default",
    "crx_jnpecgipniidlgicjocehkhajgdnjekh",
    "Helium"
  ])
  // A row that already has classes is returned untouched.
  assert.strictEqual(T.borrowFocus(fresh, [old]), fresh)
  // A different host never lends its classes.
  const whatsapp = { key: "c", source: "web.whatsapp.com", wmClass: "chrome-hnpf-Default" }
  assert.strictEqual(T.borrowFocus(old, [whatsapp]), old)
  assert.strictEqual(T.borrowFocus(null, [fresh]), null)
  assert.strictEqual(T.borrowFocus(old, null), old)
})

test("applyEvent carries source, wmClass and startupWmClass", () => {
  const list = T.applyEvent([], {
    timestamp: 1000, cookie: 1, app: "Helium", source: "mail.proton.me",
    wmClass: "chrome-jnpecgipniidlgicjocehkhajgdnjekh-Default",
    startupWmClass: "crx_jnpecgipniidlgicjocehkhajgdnjekh"
  }, { now: 1000 })
  assert.strictEqual(list[0].source, "mail.proton.me")
  assert.strictEqual(list[0].wmClass, "chrome-jnpecgipniidlgicjocehkhajgdnjekh-Default")
  assert.strictEqual(list[0].startupWmClass, "crx_jnpecgipniidlgicjocehkhajgdnjekh")
  assert.deepStrictEqual(T.focusTargets(list[0]), [
    "mail.proton.me",
    "chrome-jnpecgipniidlgicjocehkhajgdnjekh-Default",
    "crx_jnpecgipniidlgicjocehkhajgdnjekh",
    "Helium"
  ])
})

test("groupRows buckets by thread, newest thread first, counting unread", () => {
  const entries = [
    { key: "1", timestamp: 3000, app: "WhatsApp", threadKey: "wa|h|group-a", threadLabel: "Group A", summary: "hi" },
    { key: "2", timestamp: 2000, app: "WhatsApp", threadKey: "wa|h|group-b", threadLabel: "Group B", summary: "yo" },
    { key: "3", timestamp: 1000, app: "WhatsApp", threadKey: "wa|h|group-a", threadLabel: "Group A", summary: "hello" }
  ]
  const rows = T.groupRows(entries, { readMark: 1500 })
  assert.strictEqual(rows.length, 2)
  assert.strictEqual(rows[0].threadKey, "wa|h|group-a")
  assert.strictEqual(rows[0].count, 2)
  assert.strictEqual(rows[0].unread, 1) // key 1 is newer than the read mark
  assert.strictEqual(rows[0].label, "Group A")
  assert.deepStrictEqual(rows[0].entries.map(e => e.key), ["1", "3"])
  assert.strictEqual(rows[1].threadKey, "wa|h|group-b")
  assert.strictEqual(rows[1].unread, 1)
})

test("groupRows carries the latest entry's icon, empty when absent", () => {
  const entries = [
    { key: "1", timestamp: 3000, app: "WhatsApp", threadKey: "wa|h|g", threadLabel: "G", icon: "/state/web.whatsapp.com.png" },
    { key: "2", timestamp: 2000, app: "WhatsApp", threadKey: "wa|h|g", threadLabel: "G", icon: "/state/old.png" },
    { key: "3", timestamp: 1000, app: "Slack", threadKey: "sl|a|", threadLabel: "Slack" }
  ]
  const rows = T.groupRows(entries)
  assert.strictEqual(rows[0].icon, "/state/web.whatsapp.com.png")
  assert.strictEqual(rows[1].icon, "")
})

test("groupRows search matches thread label, app, summary and body", () => {
  const entries = [
    { key: "1", timestamp: 2000, app: "Slack", threadKey: "s|#general", threadLabel: "#general", summary: "deploy", body: "the build finished" },
    { key: "2", timestamp: 1000, app: "Helium", threadKey: "h|mail", threadLabel: "Inbox", summary: "New email", body: "proton" }
  ]
  assert.strictEqual(T.groupRows(entries, { query: "general" }).length, 1)
  assert.strictEqual(T.groupRows(entries, { query: "HELIUM" }).length, 1)
  assert.strictEqual(T.groupRows(entries, { query: "proton" }).length, 1)
  assert.strictEqual(T.groupRows(entries, { query: "nothing" }).length, 0)
})

test("flattenRows exposes thread headers and expanded entries in order", () => {
  const rows = T.groupRows([
    { key: "1", timestamp: 2000, app: "A", threadKey: "a", threadLabel: "A" },
    { key: "2", timestamp: 1000, app: "A", threadKey: "a", threadLabel: "A" },
    { key: "3", timestamp: 500, app: "B", threadKey: "b", threadLabel: "B" }
  ])
  assert.deepStrictEqual(T.flattenRows(rows, {}), [
    { kind: "thread", threadKey: "a" },
    { kind: "thread", threadKey: "b" }
  ])
  assert.deepStrictEqual(T.flattenRows(rows, { a: true }), [
    { kind: "thread", threadKey: "a" },
    { kind: "entry", threadKey: "a", entryKey: "1" },
    { kind: "entry", threadKey: "a", entryKey: "2" },
    { kind: "thread", threadKey: "b" }
  ])
})

test("unreadCount counts entries newer than the read mark", () => {
  const entries = [{ timestamp: 1000 }, { timestamp: 2000 }, { timestamp: 3000 }]
  assert.strictEqual(T.unreadCount(entries, 2500), 1)
  assert.strictEqual(T.unreadCount(entries, 0), 3)
  assert.strictEqual(T.unreadCount(entries, 5000), 0)
})

test("relativeTime formats minutes, hours, days and dates", () => {
  const now = 1000 * 86400000 // arbitrary fixed reference
  assert.strictEqual(T.relativeTime(now - 0, now), "now")
  assert.strictEqual(T.relativeTime(now - 5 * 60000, now), "5m")
  assert.strictEqual(T.relativeTime(now - 3 * 3600000, now), "3h")
  assert.strictEqual(T.relativeTime(now - 2 * 86400000, now), "2d")
  assert.match(T.relativeTime(now - 40 * 86400000, now), /^\d{4}-\d{2}-\d{2}$/)
})

test("plainBody strips tags and decodes common entities", () => {
  assert.strictEqual(
    T.plainBody('<a href="https://x">mail</a><br>&amp; more&nbsp;text'),
    "mail\n& more text"
  )
})

test("plainBody drops the Chromium origin link before the message", () => {
  assert.strictEqual(
    T.plainBody('<a href="https://web.whatsapp.com/">web.whatsapp.com</a>\n\nAhhaahhaa'),
    "Ahhaahhaa")
  assert.strictEqual(
    T.plainBody('<a href="https://mail.proton.me/">mail.proton.me</a>\n\nFrom: Backblaze'),
    "From: Backblaze")
})

test("plainBody keeps a message that is only a link", () => {
  assert.strictEqual(T.plainBody('<a href="https://example.com/">example.com</a>'), "example.com")
})

test("groupRows previews the newest message content", () => {
  var entries = [
    { key: "a", timestamp: 1000, threadKey: "t", threadLabel: "Chat", app: "Helium",
      body: '<a href="https://web.whatsapp.com/">web.whatsapp.com</a>\n\nfirst' },
    { key: "b", timestamp: 2000, threadKey: "t", threadLabel: "Chat", app: "Helium",
      body: '<a href="https://web.whatsapp.com/">web.whatsapp.com</a>\n\nsecond' }
  ]
  var rows = T.groupRows(entries, {})
  assert.strictEqual(rows.length, 1)
  assert.strictEqual(rows[0].preview, "second")
})

test("parseArchive and parseState tolerate garbage", () => {
  assert.deepStrictEqual(T.parseArchive('[{"key":"a"}]'), [{ key: "a" }])
  assert.deepStrictEqual(T.parseArchive("not json"), [])
  assert.deepStrictEqual(T.parseArchive('{"not":"array"}'), [])
  assert.deepStrictEqual(T.parseState('{"readMark":5}'), { readMark: 5 })
  assert.deepStrictEqual(T.parseState("garbage"), {})
})

if (process.exitCode) {
  console.error(passed + " passed, failures above")
  process.exit(1)
}
console.log(passed + " threadlogic tests passed")
