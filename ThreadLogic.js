// Pure logic for the Threads notification center.
//
// No QML imports anywhere: this file is loaded by Panel.qml as a JS module
// (import "ThreadLogic.js" as ThreadLogic) and by node in tests via the
// module.exports guard at the bottom. Every function is deterministic and
// takes its clock/limits through `opts`, so tests never depend on wall time.

function hintValue(value) {
  // busctl --json wraps a{sv} values as {type, data}; archive entries carry
  // the unwrapped scalar. Accept both so callers never have to care.
  if (value && typeof value === "object" && !Array.isArray(value) && "data" in value) return value.data
  return value
}

function baseName(path) {
  var s = String(path || "")
  if (!s) return ""
  var slash = s.lastIndexOf("/")
  return slash >= 0 ? s.slice(slash + 1) : s
}

// App identity used to scope thread keys. The result is never trusted for
// privileged actions; it only decides which conversation a notification
// belongs to, so a spoofed desktop-entry can at worst merge two threads.
function appIdFor(event, opts) {
  opts = opts || {}
  var hints = (event && event.hints) || {}
  var hintApp = hintValue(hints["desktop-entry"]) || hintValue(hints["x-ayatana-app-id"])
  return String(hintApp || baseName(event && event.senderExe) || (event && event.app) || "")
}

// The conversation key. Priority:
//   1. chat-app stack hints (dunst tag / KDE event id) — a WhatsApp group per
//      conversation, a Slack channel per conversation;
//   2. app + summary — chat apps put the conversation name in the summary;
//   3. app only.
function threadFor(event, opts) {
  opts = opts || {}
  var fallback = opts.fallbackGrouping || "summary"
  var hints = (event && event.hints) || {}
  var appId = appIdFor(event, opts)
  var dunst = hintValue(hints["x-dunst-stack-tag"])
  var kde = hintValue(hints["x-kde-eventId"])
  var hintKey = dunst || kde || ""
  var summary = String((event && event.summary) || "")

  var key, source
  if (hintKey) {
    key = appId + "|h|" + hintKey
    source = dunst ? "hint:x-dunst-stack-tag" : "hint:x-kde-eventId"
  } else if (fallback !== "app" && summary) {
    key = appId + "|s|" + summary
    source = "summary"
  } else {
    key = appId + "|a|"
    source = "app"
  }

  return {
    key: key,
    label: summary || String((event && event.app) || "") || appId,
    source: source,
    appId: appId
  }
}

// Stable archive identity. The cookie is the bus message cookie; id is the
// daemon-assigned notification id, which only arrives a moment later.
function entryKey(event) {
  var ts = Number((event && event.timestamp) || 0)
  var disambiguator = Number((event && (event.cookie || event.id)) || 0)
  return ts + "-" + disambiguator
}

// Apply one watcher event (already enriched with thread fields by the panel,
// or plain — threadFor is recomputed here so tests can feed raw events).
// `replacesId` means the daemon rewrote an existing notification: the old
// entry leaves the archive. A fresh entry with an id we already hold wins
// the same way.
function applyEvent(entries, event, opts) {
  var list = Array.isArray(entries) ? entries.slice() : []
  var thread = threadFor(event, opts)

  var entry = {}
  for (var k in event) entry[k] = event[k]
  entry.key = entry.key || entryKey(event)
  entry.threadKey = thread.key
  entry.threadLabel = thread.label
  entry.threadSource = thread.source
  if (!entry.appId) entry.appId = thread.appId
  if (!entry.link) entry.link = firstLink(entry)

  var replacesId = Number(entry.replacesId || 0)
  var id = Number(entry.id || 0)
  if (replacesId > 0) {
    list = list.filter(function(e) { return Number(e.id || 0) !== replacesId })
  }
  if (id > 0) {
    list = list.filter(function(e) {
      return e.key === entry.key || Number(e.id || 0) !== id
    })
  }

  list.unshift(entry)
  return prune(list, opts)
}

// Backfill the daemon id once the paired method_return lands. Pairing is by
// (sender, cookie): cookies are per-connection counters, so every chatty app
// that reconnects each time can send cookie 9 without collision.
function applyId(entries, sender, cookie, id) {
  var who = String(sender || "")
  var target = Number(cookie || 0)
  var value = Number(id || 0)
  if (!who || target <= 0 || value <= 0) return entries
  return (Array.isArray(entries) ? entries : []).map(function(e) {
    if (String(e.sender || "") === who && Number(e.cookie || -1) === target) {
      var next = {}
      for (var k in e) next[k] = e[k]
      next.id = value
      return next
    }
    return e
  })
}

// Retention: newest-first list, floor of keepDays and hard cap on entries.
function prune(entries, opts) {
  opts = opts || {}
  var now = Number(opts.now || Date.now())
  var keepDays = Number(opts.keepDays || 30)
  var maxEntries = Number(opts.maxEntries || 2000)
  var cutoff = now - keepDays * 86400000
  var out = []
  var list = Array.isArray(entries) ? entries : []
  for (var i = 0; i < list.length && out.length < maxEntries; i++) {
    if (Number(list[i].timestamp || 0) >= cutoff) out.push(list[i])
  }
  return out
}

// Group entries into conversation threads for display, newest thread first.
// `query` filters on thread label/app and on any entry summary/body. `readMark`
// drives the unread count per thread.
function groupRows(entries, opts) {
  opts = opts || {}
  var query = String(opts.query || "").trim().toLowerCase()
  var readMark = Number(opts.readMark || 0)
  var byKey = {}
  var order = []
  var list = Array.isArray(entries) ? entries : []

  for (var i = 0; i < list.length; i++) {
    var e = list[i]
    var tk = e.threadKey || threadFor(e).key
    var t = byKey[tk]
    if (!t) {
      t = byKey[tk] = {
        threadKey: tk,
        label: e.threadLabel || e.summary || e.app || "",
        app: e.app || "",
        appId: e.appId || "",
        appIcon: e.appIcon || "",
        icon: e.icon || "",
        entries: [],
        latest: 0,
        unread: 0
      }
      order.push(t)
    }
    t.entries.push(e)
    var ts = Number(e.timestamp || 0)
    if (ts > t.latest) {
      t.latest = ts
      t.label = e.threadLabel || e.summary || t.label
      t.app = e.app || t.app
      t.appIcon = e.appIcon || t.appIcon
      t.icon = e.icon || t.icon
      t.appId = e.appId || t.appId
    }
    if (ts > readMark) t.unread += 1
  }

  var rows = order.map(function(t) {
    t.entries.sort(function(a, b) { return Number(b.timestamp || 0) - Number(a.timestamp || 0) })
    t.count = t.entries.length
    t.preview = previewLine(t.entries[0])
    return t
  })
  rows.sort(function(a, b) { return b.latest - a.latest })

  if (!query) return rows
  return rows.filter(function(t) {
    if (String(t.label).toLowerCase().indexOf(query) >= 0) return true
    if (String(t.app).toLowerCase().indexOf(query) >= 0) return true
    for (var j = 0; j < t.entries.length; j++) {
      var entry = t.entries[j]
      if (String(entry.summary || "").toLowerCase().indexOf(query) >= 0) return true
      if (String(entry.body || "").toLowerCase().indexOf(query) >= 0) return true
    }
    return false
  })
}

// Flatten visible threads into the keyboard cursor's row list, expanding the
// threads the user opened.
function flattenRows(threads, expanded) {
  var out = []
  var list = Array.isArray(threads) ? threads : []
  for (var i = 0; i < list.length; i++) {
    var t = list[i]
    out.push({ kind: "thread", threadKey: t.threadKey })
    if (expanded && expanded[t.threadKey]) {
      for (var j = 0; j < t.entries.length; j++) {
        out.push({ kind: "entry", threadKey: t.threadKey, entryKey: t.entries[j].key })
      }
    }
  }
  return out
}

function unreadCount(entries, readMark) {
  var mark = Number(readMark || 0)
  var list = Array.isArray(entries) ? entries : []
  var n = 0
  for (var i = 0; i < list.length; i++) {
    if (Number(list[i].timestamp || 0) > mark) n += 1
  }
  return n
}

function relativeTime(ts, now) {
  var t = Number(ts || 0)
  if (!t) return ""
  var ref = Number(now || Date.now())
  var diff = Math.max(0, ref - t)
  var mins = Math.floor(diff / 60000)
  if (mins < 1) return "now"
  if (mins < 60) return mins + "m"
  var hours = Math.floor(mins / 60)
  if (hours < 24) return hours + "h"
  var days = Math.floor(hours / 24)
  if (days < 7) return days + "d"
  var d = new Date(t)
  return d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0") + "-" + String(d.getDate()).padStart(2, "0")
}

// Notification bodies may carry HTML (the FreeDesktop spec allows markup).
// The panel renders plain text, so tags are dropped and the handful of
// entities that actually show up are decoded.
// Chromium-family web notifications prepend their origin as a link paragraph
// ("<a href=\"https://web.whatsapp.com/\">web.whatsapp.com</a>") before the
// real message. The icon already carries the origin, so drop it - but only
// when the label is a bare host matching its own href and real content
// follows, so a message that is nothing but a link survives.
var HOST_LABEL = /^[a-z0-9-]+(?:\.[a-z0-9-]+)+$/i

function stripOriginLead(body) {
  var raw = String(body || "")
  var match = raw.match(/^\s*<a\b[^>]*href=["']([^"']+)["'][^>]*>([^<]*)<\/a>[ \t]*(?:\r?\n)+/i)
  if (match) {
    var label = match[2].trim()
    var host = String(match[1]).replace(/^[a-z][a-z0-9+.-]*:\/\//i, "").split(/[/?#]/)[0].toLowerCase()
    var rest = raw.slice(match[0].length).replace(/^\s+/, "")
    if (rest && HOST_LABEL.test(label) && host === label.toLowerCase()) return rest
  }
  var plain = raw.match(/^\s*([a-z0-9-]+(?:\.[a-z0-9-]+)+)[ \t]*(?:\r?\n)+/i)
  if (plain) {
    var tail = raw.slice(plain[0].length).replace(/^\s+/, "")
    if (tail) return tail
  }
  return raw
}

// The durable deep link a notification carried. The per-chat "default" action
// only exists while the popup is live and belongs to the daemon, so the
// archive keeps the best link the payload itself holds: the first http(s)
// anchor, else the first bare http(s) URL in the body or the summary.
var LINK_HREF = /<a\b[^>]*href=["'](https?:\/\/[^"']+)["']/i
var LINK_PLAIN = /https?:\/\/[^\s<>"']+/i

function firstLink(entry) {
  var body = String((entry && entry.body) || "")
  var summary = String((entry && entry.summary) || "")
  var href = body.match(LINK_HREF) || summary.match(LINK_HREF)
  if (href) return href[1]
  var plain = body.match(LINK_PLAIN) || summary.match(LINK_PLAIN)
  return plain ? plain[0].replace(/[.,;:!?]+$/, "") : ""
}

// Whether the sender's live "default" action can be tried for this entry: the
// daemon id must be known (backfilled from the bus reply) and the payload must
// have offered a default action. The action itself only exists while the
// notification is alive; the caller falls back to the durable link after.
function canInvokeLive(entry) {
  if (!entry || Number(entry.id || 0) <= 0) return false
  var actions = entry.actions
  return Array.isArray(actions) && actions.indexOf("default") !== -1
}

// Lowercase host extracted from a bare host or a full URL, without userinfo
// or port (""). Shared by the web-source helpers below.
function hostOf(value) {
  var raw = String(value || "").trim()
  if (!raw) return ""
  if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(raw)) raw = "https://" + raw
  var authority = raw.replace(/^[a-z][a-z0-9+.-]*:\/\//i, "").split(/[/?#]/)[0]
  var at = authority.lastIndexOf("@")
  if (at >= 0) authority = authority.slice(at + 1)
  return authority.split(":")[0].toLowerCase()
}

// The watcher's `source` field: the bare host of the first URL in the
// notification (empty for non-web senders). Normalized so older archives —
// or a hand-written entry carrying a full URL — still compare equal.
function sourceHost(entry) {
  return hostOf(entry && entry.source)
}

// True when the entry's durable link is nothing but the web origin recorded
// in `source`: Chromium sends the page origin as a lead paragraph, so
// opening that link only reloads the PWA at its root. A link with a path or
// query is a real deep link and must still open normally. Rows archived
// before the watcher recorded `source` still name their web app through a
// bare-origin link, so the host is derived from the link when needed.
function isWebOrigin(entry) {
  var link = String((entry && entry.link) || "") || firstLink(entry)
  var host = sourceHost(entry)
  if (!host && link) host = hostOf(link)
  if (!host) return false
  if (!link) return true
  if (hostOf(link) !== host) return false
  return /^[a-z][a-z0-9+.-]*:\/\/[^/?#]+\/?$/i.test(link)
}

// Ordered focus patterns for the sending window: the web source host first
// (it matches host-shaped PWA window classes, e.g. web.whatsapp.com for
// chrome-web.whatsapp.com__-Default), then the app's derived window class
// (chrome-<appid>-Default for Chromium PWAs, whose desktop StartupWMClass is
// a crx_ name that does not match the live window), then the declared
// StartupWMClass, then the app id as the last resort. Duplicates and empties
// are dropped, so a target is tried at most once.
function focusTargets(entry) {
  var targets = []
  function add(value) {
    var target = String(value || "")
    if (target && targets.indexOf(target) < 0) targets.push(target)
  }
  // Older rows predate `source`; the archived link's host still names the
  // sending web app, so it can focus the PWA window.
  add(sourceHost(entry) || hostOf(String((entry && entry.link) || "") || firstLink(entry)))
  add(entry && entry.wmClass)
  add(entry && entry.startupWmClass)
  add(entry && (entry.appId || entry.app))
  return targets
}

// Rows archived before the watcher recorded focus classes still know their
// web host (from `source` or the archived link). Borrow the focus classes
// from a sibling row for the same host, so clicking an old notification
// focuses the PWA instead of falling back to the browser window. A different
// host never lends its classes, so a WhatsApp row can't focus Proton Mail.
function borrowFocus(entry, entries) {
  if (!entry || entry.wmClass || entry.startupWmClass) return entry
  var host = sourceHost(entry) || hostOf(String(entry.link || "") || firstLink(entry))
  if (!host || !Array.isArray(entries)) return entry
  for (var i = 0; i < entries.length; i++) {
    var peer = entries[i]
    if (!peer || peer === entry || !peer.wmClass) continue
    if (sourceHost(peer) !== host) continue
    return Object.assign({}, entry, {
      wmClass: peer.wmClass,
      startupWmClass: peer.startupWmClass || ""
    })
  }
  return entry
}

function plainBody(body) {
  return stripOriginLead(body)
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<[^>]*>/g, "")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, "\"")
    .replace(/&#39;/g, "'")
    .replace(/&nbsp;/g, " ")
    .trim()
}

// The first non-empty line of a notification's text, for the thread header.
function previewLine(entry) {
  var text = plainBody(entry && entry.body)
  var lines = text.split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line) return line
  }
  return ""
}

function parseArchive(raw) {
  try {
    var value = JSON.parse(String(raw || ""))
    return Array.isArray(value) ? value : []
  } catch (e) {
    return []
  }
}

function parseState(raw) {
  try {
    var value = JSON.parse(String(raw || ""))
    return value && typeof value === "object" ? value : {}
  } catch (e) {
    return {}
  }
}

// The summaries a panel dismissal should also clear from the live toast
// stack. A thread's entries carry the same chat-app summary (or mail
// subject), which is what the daemon's dismiss IPC matches on; empties and
// duplicates are dropped so one conversation fires one call per live toast.
function dismissSummaries(entries) {
  var seen = {}
  var out = []
  var list = Array.isArray(entries) ? entries : []
  for (var i = 0; i < list.length; i++) {
    var summary = String((list[i] && list[i].summary) || "").trim()
    if (!summary || seen[summary]) continue
    seen[summary] = true
    out.push(summary)
  }
  return out
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    hintValue: hintValue,
    baseName: baseName,
    appIdFor: appIdFor,
    threadFor: threadFor,
    entryKey: entryKey,
    firstLink: firstLink,
    canInvokeLive: canInvokeLive,
    dismissSummaries: dismissSummaries,
    hostOf: hostOf,
    sourceHost: sourceHost,
    isWebOrigin: isWebOrigin,
    focusTargets: focusTargets,
    borrowFocus: borrowFocus,
    applyEvent: applyEvent,
    applyId: applyId,
    prune: prune,
    groupRows: groupRows,
    flattenRows: flattenRows,
    unreadCount: unreadCount,
    relativeTime: relativeTime,
    plainBody: plainBody,
    previewLine: previewLine,
    parseArchive: parseArchive,
    parseState: parseState
  }
}
