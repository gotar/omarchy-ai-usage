import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "gotar.ai-usage"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool vertical: bar ? bar.vertical : false

  readonly property string opencodeApiKey: String(setting("opencodeApiKey", "") || "").trim()
  readonly property string opencodeEndpoint: {
    var v = String(setting("opencodeEndpoint", "https://opencode.ai/zen/go/v1/usage") || "").trim()
    return v !== "" ? v : "https://opencode.ai/zen/go/v1/usage"
  }
  readonly property int refreshIntervalSec: Math.max(30, Math.min(3600, Number(setting("refreshIntervalSec", 300)) || 300))
  readonly property bool showValue: {
    var v = setting("showValue", true)
    if (v === true || v === false) return v
    var s = String(v).toLowerCase()
    if (["true","1","yes","on"].indexOf(s) >= 0) return true
    if (["false","0","no","off"].indexOf(s) >= 0) return false
    return true
  }
  readonly property string localUnit: {
    var v = String(setting("localUnit", "llama-cpp-server.service") || "").trim()
    return v !== "" ? v : "llama-cpp-server.service"
  }
  readonly property string localHost: String(setting("localHost", "127.0.0.1:8080") || "").trim() || "127.0.0.1:8080"

  property var opencodeWindows: null
  property string opencodeError: ""
  property string opencodeFetchedAt: ""
  property bool opencodeStale: false
  property bool opencodeUsesCli: false
  property string opencodeStdout: ""
  property string opencodeStderr: ""

  readonly property string opencodeWorkspaceId: {
    var v = String(setting("opencodeWorkspaceId", "") || "").trim()
    return v !== "" ? v : ""
  }
  readonly property int opencodeBalanceTtlSec: Math.max(60, Math.min(86400, Number(setting("opencodeBalanceTtlSec", 600)) || 600))
  property var walletInfo: null
  property string walletError: ""
  property string walletStderr: ""
  property bool walletBusy: false

  property var codexEntry: null
  property string codexError: ""
  property string codexFetchedAt: ""
  property bool codexStale: false

  property var serviceState: null
  property int serviceQueryAttempts: 0
  property string localModelName: "Qwen3.8-27B-UD-Q4_K_M"
  property var qwenStats: null
  property string qwenStatsRaw: ""
  property bool qwenStatsBusy: false

  property string commandStdout: ""
  property string commandStderr: ""
  property int lastExitCode: 0
  property bool loading: true
  property double lastSuccessfulMs: 0
  property double nowMs: Date.now()
  property bool settingsOpen: false
  property bool refreshQueued: false

  property string editApiKey: ""
  property string editEndpoint: ""
  property string editLocalUnit: ""
  property string editLocalHost: ""
  property string editWorkspaceId: ""
  property int editBalanceTtl: 600
  property bool editShowValue: true
  property int editRefresh: 300
  property bool dirtyApiKey: false

  readonly property bool alarming: {
    if (opencodeError !== "" || codexError !== "") return true
    var w = opencodeWindows
    if (w && w.monthly && w.monthly.percent >= 90) return true
    if (w && w.weekly && w.weekly.percent >= 90) return true
    if (codexEntry) {
      var cm = Array.isArray(codexEntry.metrics) ? codexEntry.metrics : []
      if (cm.length === 0 && codexEntry.percent >= 90) return true
      for (var ai = 0; ai < cm.length; ai++) if (cm[ai].percent >= 90) return true
    }
    return false
  }

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function scriptPath(p) { return String(Qt.resolvedUrl(p)).replace("file://", "") }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
  function cleanText(v, maxLen) {
    var t = v === undefined || v === null ? "" : String(v)
    t = t.replace(/[\t\r]/g, " ").replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f]/g, "")
    var lim = Number(maxLen) || 2048
    if (t.length > lim) t = t.slice(0, lim - 1) + "…"
    return t
  }
  function autoSafe(v) { return cleanText(v, 1000).replace(/</g, "‹").replace(/>/g, "›") }
  function formatDuration(ms) {
    if (!(ms > 0)) return "now"
    var mins = Math.floor(ms / 60000)
    var hrs = Math.floor(mins / 60)
    var days = Math.floor(hrs / 24)
    if (days > 0) return days + "d " + (hrs % 24) + "h"
    if (hrs > 0) return hrs + "h " + (mins % 60) + "m"
    return Math.max(1, mins) + "m"
  }
  function formatReset(resetAt, now) {
    if (!resetAt) return ""
    var t = new Date(String(resetAt)).getTime()
    if (!isFinite(t)) return ""
    var d = t - Number(now)
    return d > 0 ? "Resets in " + formatDuration(d) : "Reset due"
  }
  function formatUpdated(fetchedAt, now) {
    if (!fetchedAt) return ""
    var t = new Date(String(fetchedAt)).getTime()
    if (!isFinite(t)) return ""
    var e = Math.max(0, Number(now) - t)
    if (e < 60000) return "Updated just now"
    return "Updated " + formatDuration(e) + " ago"
  }
  function settingsWithOverrides(s, moduleName, overrides) {
    var mid = cleanText(moduleName, 180).trim()
    if (mid === "" || !overrides || typeof overrides !== "object" || Array.isArray(overrides)) return null
    var next = { id: mid }
    var cur = s && typeof s === "object" && !Array.isArray(s) ? s : {}
    for (var k in cur) { if (k === "id" || k === "__proto__") continue; next[k] = cur[k] }
    for (var ok in overrides) { if (ok === "id" || ok === "__proto__") continue; next[ok] = overrides[ok] }
    return next
  }
  function persistWidgetSettings(values) {
    var entry = settingsWithOverrides(root.settings, root.moduleName, values)
    if (!entry) return false
    root.settings = entry
    if (hostWidget && "settings" in hostWidget) hostWidget.settings = entry
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(root.moduleName, entry)
    return true
  }
  function heroMeta() {
    if (loading && !opencodeWindows && !codexEntry) return "Loading providers…"
    var parts = []
    if (opencodeError !== "") parts.push("Go error")
    else if (opencodeWindows) parts.push("Go")
    if (walletInfo) parts.push("Wallet " + walletInfo.balance)
    else if (walletError !== "") parts.push("Wallet !")
    if (codexError !== "") parts.push("Codex error")
    else if (codexEntry) parts.push(codexEntry.plan || "Codex")
    if (serviceState) parts.push(serviceState.active ? "Local running" : "Local stopped")
    return parts.join(" · ") || "AI usage"
  }
  function qwenBarSuffix() {
    if (!serviceState || !serviceState.active) return "Qwen ○"
    if (!qwenStats) return "Qwen ●"
    var t = null
    if (qwenStats.processing) {
      if (qwenStats.live_tps) t = qwenStats.live_tps
      else if (qwenStats.prompt_tps) t = qwenStats.prompt_tps
    } else {
      if (qwenStats.gen_tps) t = qwenStats.gen_tps
      else if (qwenStats.live_tps) t = qwenStats.live_tps
    }
    if (t) return "Qwen " + Number(t).toFixed(1) + " t/s"
    return qwenStats.processing ? "Qwen ●…" : "Qwen ●"
  }
  function barText() {
    if (vertical) return alarming ? "󰅙" : "󰚩"
    if (loading && !opencodeWindows && !codexEntry) return "󰚩  …"
    if (!showValue) return "󰚩"
    var segs = []
    if (opencodeWindows) {
      var top = opencodeWindows.monthly || opencodeWindows.weekly || opencodeWindows.rolling
      if (top) segs.push("Go " + Math.round(top.percent) + "%")
    } else if (opencodeError !== "") segs.push("Go !")
    if (codexEntry) segs.push((codexEntry.has5h ? "Cdx5h" : "Cdx") + " " + Math.round(codexEntry.percent) + "%")
    else if (codexError !== "") segs.push("Cdx !")
    if (serviceState) segs.push(qwenBarSuffix())
    var txt = segs.join(" · ")
    return txt !== "" ? "󰚩  " + txt : "󰚩"
  }
  function tooltipText() {
    var lines = []
    if (opencodeWindows) {
      var w = opencodeWindows
      var p = w.monthly ? Math.round(w.monthly.percent) : w.weekly ? Math.round(w.weekly.percent) : w.rolling ? Math.round(w.rolling.percent) : 0
      lines.push("Go " + p + "% used · " + (100 - p) + "% left")
    }
    if (walletInfo) lines.push("Wallet " + walletInfo.balance + " USD")
    else if (walletError !== "") lines.push("Wallet: " + walletError)
    if (codexEntry) {
      var cmet = Array.isArray(codexEntry.metrics) ? codexEntry.metrics : []
      if (cmet.length > 1) {
        for (var ci = 0; ci < cmet.length; ci++) lines.push(cmet[ci].label + " " + Math.round(cmet[ci].percent) + "% used")
      } else lines.push("Codex " + Math.round(codexEntry.percent) + "% used")
    }
    if (serviceState) {
      var q = qwenStats
      if (q && serviceState.active) {
        var tps = q.processing ? (q.live_tps || q.prompt_tps) : (q.gen_tps || q.live_tps)
        var ctx = q.ctx_used ? (q.ctx_used + "/" + q.ctx_total + " " + q.ctx_pct + "%") : ""
        var extra = []
        if (tps) extra.push(Number(tps).toFixed(1) + " t/s")
        if (ctx) extra.push(ctx)
        if (q.draft_accept) extra.push("draft " + Math.round(q.draft_accept*100) + "%")
        lines.push("Qwen " + (q.processing ? "generating" : "idle") + (extra.length ? " · " + extra.join(" · ") : ""))
      } else lines.push("Local " + (serviceState.active ? "Running" : "Stopped"))
    }
    return autoSafe(lines.join(" · ") || "AI usage")
  }
  function refreshQwenStats() {
    if (qwenStatsProcess.running || !serviceState || !serviceState.active) return
    qwenStatsBusy = true
    qwenStatsProcess.command = ["/bin/bash", scriptPath("scripts/qwen-stats.sh"), localHost]
    qwenStatsProcess.running = true
  }
  function parseQwenStats(text) {
    try { var j = JSON.parse(String(text||"")); if (j && typeof j === "object") qwenStats = j; } catch(e) {}
    qwenStatsBusy = false
  }
  function parseWallet(text) {
    try {
      var v = JSON.parse(String(text || ""))
      if (!v || typeof v !== "object") { if (walletStderr.trim() !== "") walletError = walletStderr.trim().slice(0, 200); return }
      if (v.error) { walletInfo = null; walletError = String(v.error) + (v.hint ? " · " + v.hint : ""); if (walletStderr.trim() !== "" && walletError === String(v.error)) walletError = walletStderr.trim().slice(0, 200); return }
      if (v.amount === undefined) return
      walletInfo = { balance: String(v.balance || ("$" + Number(v.amount).toFixed(2))), amount: Number(v.amount) || 0, fetchedAt: String(v.fetchedAt || ""), cached: v.cached === true }
      walletError = ""; walletStderr = ""
    } catch(e) { if (walletStderr.trim() !== "") walletError = walletStderr.trim().slice(0, 200) }
  }
  function startRefresh() {
    if (usageProcess.running || opencodeDirect.running || walletProcess.running) { refreshQueued = true; return }
    refreshQueued = false
    if (!opencodeWindows && !codexEntry) loading = true
    commandStdout = ""; commandStderr = ""; lastExitCode = 0
    opencodeStdout = ""; opencodeStderr = ""
    if (opencodeApiKey !== "") {
      opencodeUsesCli = false
      opencodeDirect.running = true
    } else {
      opencodeUsesCli = true
    }
    usageProcess.running = true
    // Wallet via dedicated headless Chromium profile; script caches for opencodeBalanceTtlSec
    if (!walletProcess.running && root.opencodeWorkspaceId !== "") { walletBusy = true; walletStderr = ""; walletProcess.running = true }
    serviceRefreshState()
    Qt.callLater(refreshQwenStats)
  }
  function refresh() { startRefresh() }
  function parseOpencodePayload(text) {
    try {
      var v = JSON.parse(String(text || ""))
      if (!v || typeof v !== "object" || !v.usage || typeof v.usage !== "object") return null
      if (v.error) return null
      function win(o) {
        if (!o || typeof o !== "object") return null
        var pct = Number(o.percent)
        if (!isFinite(pct) || pct < 0 || pct > 100) return null
        return { percent: pct, status: String(o.status || "ok"), resetsAt: String(o.resetsAt || o.resets_at || "") }
      }
      var u = v.usage
      var out = { rolling: win(u.rolling), weekly: win(u.weekly), monthly: win(u.monthly) }
      if (!out.rolling && !out.weekly && !out.monthly) return null
      return out
    } catch(e) { return null }
  }
  function finishOpencode() {
    var parsed = parseOpencodePayload(opencodeStdout)
    if (parsed) {
      opencodeWindows = parsed
      opencodeError = ""
      opencodeFetchedAt = new Date().toISOString()
      opencodeStale = false
    } else {
      var detail = opencodeStderr.trim() || "Opencode Go request failed"
      if (!opencodeUsesCli) opencodeError = detail
    }
  }
  function finishUsage() {
    try {
      var parsed = JSON.parse(String(commandStdout || ""))
      if (!parsed || !Array.isArray(parsed.entries)) throw new Error("bad report")
      var foundCodex = null
      var foundGo = null
      for (var i = 0; i < parsed.entries.length; i++) {
        var e = parsed.entries[i]
        if (!e || typeof e !== "object") continue
        if (String(e.id) === "openai" || String(e.id).indexOf("openai") === 0) {
          var secs = Array.isArray(e.sections) ? e.sections : []
          var mlist = []
          var msrc = []
          if (Array.isArray(e.metrics) && e.metrics.length > 0) {
            msrc = e.metrics
          } else {
            for (var f = 0; f < secs.length; f++) if (secs[f] && secs[f].type === "metric") msrc.push(secs[f])
          }
          for (var s = 0; s < msrc.length; s++) {
            var sec = msrc[s]
            if (sec && isFinite(Number(sec.percent))) {
              mlist.push({
                percent: Number(sec.percent) || 0,
                label: String(sec.label || "Codex window"),
                detail: String(sec.detail || ""),
                reset_at: String(sec.reset_at || ""),
                severity: String(sec.severity || "low")
              })
            }
          }
          var best = null
          var five = null
          for (var mm = 0; mm < mlist.length; mm++) {
            if (mlist[mm].label.toLowerCase().indexOf("5h") >= 0) five = mlist[mm]
            if (!best || mlist[mm].percent > best.percent) best = mlist[mm]
          }
          // The 5h session window is the binding intraday limit; surface it as the
          // primary row/bar value when the endpoint reports it.
          var primary = five || best
          if (primary) {
            foundCodex = {
              percent: primary.percent,
              label: primary.label,
              detail: primary.detail,
              reset_at: primary.reset_at,
              plan: String(e.plan || "ChatGPT Plus"),
              metrics: mlist,
              has5h: !!five,
              sections: secs,
              stale: e.stale === true
            }
          } else if (e.error) {
            codexError = cleanText(e.error, 600)
          }
          codexFetchedAt = String(e.fetched_at || new Date().toISOString())
          codexStale = e.stale === true
          if (e.error && e.error !== "") codexError = cleanText(e.error, 600)
          else if (foundCodex) codexError = ""
        }
        if (String(e.id) === "opencode-go") foundGo = e
      }
      if (foundCodex) { codexEntry = foundCodex; codexError = "" }
      else if (!codexEntry && codexError === "") {
        var hasOpenai = false
        for (var j = 0; j < parsed.entries.length; j++) if (String(parsed.entries[j].id).indexOf("openai") === 0) hasOpenai = true
        if (!hasOpenai) codexError = "Codex not configured"
      }
      if (opencodeUsesCli || !opencodeWindows) {
        if (foundGo && !foundGo.error) {
          var gw = { rolling: null, weekly: null, monthly: null }
          var gsecs = Array.isArray(foundGo.sections) ? foundGo.sections : []
          for (var k = 0; k < gsecs.length; k++) {
            var gs = gsecs[k]
            if (gs && gs.type === "metric") {
              var gp = Number(gs.percent)
              var gl = String(gs.label || "").toLowerCase()
              var wobj = { percent: gp, status: "ok", resetsAt: String(gs.reset_at || "") }
              if (gl.indexOf("rolling") >= 0) gw.rolling = wobj
              else if (gl.indexOf("weekly") >= 0) gw.weekly = wobj
              else if (gl.indexOf("monthly") >= 0) gw.monthly = wobj
            }
          }
          if (gw.rolling || gw.weekly || gw.monthly) {
            opencodeWindows = gw
            opencodeError = ""
            opencodeFetchedAt = String(foundGo.fetched_at || new Date().toISOString())
            opencodeStale = foundGo.stale === true
          }
        } else if (foundGo && foundGo.error) {
          if (!opencodeWindows) opencodeError = cleanText(foundGo.error, 600)
        }
      }
      if (lastExitCode !== 0 && !codexEntry && opencodeError === "" && !opencodeWindows) {
        var d = commandStderr.trim()
        if (d !== "") {
          if (lastExitCode === 127) codexError = "ai-usagebar not installed"
          else codexError = cleanText(d, 600)
        }
      }
    } catch(err) {
      var msg = commandStderr.trim()
      if (msg !== "") codexError = lastExitCode === 127 ? "ai-usagebar not installed" : cleanText(msg, 600)
      else codexError = "Usage report invalid"
    }
    loading = false
    lastSuccessfulMs = Date.now()
    if (refreshQueued) Qt.callLater(startRefresh)
  }
  function syncServiceFromRecord() {
    if (!serviceState) serviceState = { active: false, busy: false, stateText: "Stopped" }
    serviceRefreshState()
  }
  function serviceRefreshState() {
    if (!localUnit) return
    serviceQueryAttempts = 1
    serviceQueryProcess.command = ["systemctl", "--user", "is-active", localUnit]
    serviceQueryProcess.running = true
  }
  function serviceSet(targetActive) {
    if (!serviceState) serviceState = { active: false, busy: false, stateText: "Stopped" }
    if (serviceState.busy || serviceState.active === targetActive) return
    serviceState = { active: targetActive, busy: true, stateText: targetActive ? "Starting…" : "Stopping…" }
    serviceProcess.command = ["systemctl", "--user", targetActive ? "start" : "stop", localUnit]
    serviceProcess.running = true
  }
  function localStart() { if (!serviceState) syncServiceFromRecord(); if (serviceState && !serviceState.active) serviceSet(true) }
  function localStop() { if (!serviceState) syncServiceFromRecord(); if (serviceState && serviceState.active) serviceSet(false) }
  function localToggle() { if (!serviceState) syncServiceFromRecord(); if (serviceState) serviceSet(!serviceState.active) }
  function openSettings() {
    editApiKey = ""; dirtyApiKey = false
    editEndpoint = opencodeEndpoint
    editLocalUnit = localUnit
    editLocalHost = localHost
    editWorkspaceId = opencodeWorkspaceId
    editBalanceTtl = opencodeBalanceTtlSec
    editShowValue = showValue
    editRefresh = refreshIntervalSec
    settingsOpen = true
    Qt.callLater(function(){ if (panelFlick) panelFlick.contentY = 0 })
  }
  function closeSettings() { settingsOpen = false; if (panelFlick) panelFlick.contentY = 0 }
  function saveSettings() {
    var patches = {}
    if (dirtyApiKey) patches.opencodeApiKey = editApiKey
    patches.opencodeEndpoint = editEndpoint.trim() !== "" ? editEndpoint.trim() : "https://opencode.ai/zen/go/v1/usage"
    patches.localUnit = editLocalUnit.trim() !== "" ? editLocalUnit.trim() : "llama-cpp-server.service"
    patches.localHost = editLocalHost.trim() !== "" ? editLocalHost.trim() : "127.0.0.1:8080"
    patches.opencodeWorkspaceId = editWorkspaceId.trim() !== "" ? editWorkspaceId.trim() : ""
    patches.opencodeBalanceTtlSec = Math.max(60, Math.min(86400, Number(editBalanceTtl) || 600))
    patches.showValue = editShowValue === true
    patches.refreshIntervalSec = Math.max(30, Math.min(3600, Number(editRefresh) || 300))
    persistWidgetSettings(patches)
    closeSettings()
    Qt.callLater(startRefresh)
  }
  function switchPanel(dir) {
    if (bar && typeof bar.switchPanelFrom === "function") return bar.switchPanelFrom(barIdentity, dir)
    return false
  }

  onOpenedChanged: {
    if (opened) {
      nowMs = Date.now()
      if (panelFlick) panelFlick.contentY = 0
      if (lastSuccessfulMs === 0 || nowMs - lastSuccessfulMs >= refreshIntervalSec * 1000) startRefresh()
      else serviceRefreshState()
    } else settingsOpen = false
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.startRefresh()
  }
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  Process {
    id: usageProcess
    running: false
    command: ["/usr/bin/env", "ai-usagebar", "usage", "--json"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.commandStdout = text }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root.commandStderr = text }
    onExited: function(code){ root.lastExitCode = code; Qt.callLater(root.finishUsage) }
  }
  Process {
    id: opencodeDirect
    running: false
    command: ["/usr/bin/curl", "-sS", "--max-time", "10", "-H", "Accept: application/json", "-H", "Authorization: Bearer " + root.opencodeApiKey, root.opencodeEndpoint]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.opencodeStdout = text }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root.opencodeStderr = text }
    onExited: function(c){ Qt.callLater(root.finishOpencode) }
  }
  Process {
    id: serviceProcess
    running: false
    onExited: function(c){ serviceQueryAttempts = 1; serviceQueryProcess.command = ["systemctl","--user","is-active", localUnit]; serviceQueryProcess.running = true }
  }
  Process {
    id: serviceQueryProcess
    running: false
    stdout: StdioCollector { id: serviceQueryCollector; waitForEnd: true; onStreamFinished: {
      if (!root.serviceState) root.serviceState = { active: false, busy: false, stateText: "Stopped" }
      var state = serviceQueryCollector.text.trim()
      if (state === "active") { root.serviceState = { active: true, busy: false, stateText: "Running" }; Qt.callLater(root.refreshQwenStats) }
      else if (state === "inactive") { root.serviceState = { active: false, busy: false, stateText: "Stopped" }; root.qwenStats = null }
      else if (state === "failed") { root.serviceState = { active: false, busy: false, stateText: "Failed to start" }; root.qwenStats = null }
      else if (root.serviceQueryAttempts < 8) { root.serviceQueryAttempts++; serviceRetry.restart() }
      else root.serviceState = { active: root.serviceState.active, busy: false, stateText: state !== "" ? state : (root.serviceState.active ? "Running" : "Stopped") }
    } }
  }
  Timer { id: serviceRetry; interval: 1200; repeat: false; onTriggered: { serviceQueryProcess.command = ["systemctl","--user","is-active", localUnit]; serviceQueryProcess.running = true } }
  Process {
    id: qwenStatsProcess
    running: false
    stdout: StdioCollector { id: qwenCollector; waitForEnd: true; onStreamFinished: { root.qwenStatsRaw = text; Qt.callLater(function(){ root.parseQwenStats(text) }) } }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(c){ root.qwenStatsBusy = false }
  }
  Process {
    id: walletProcess
    running: false
    command: ["/bin/bash", scriptPath("scripts/opencode-balance.sh"), root.opencodeWorkspaceId]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: Qt.callLater(function(){ root.parseWallet(text) }) }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root.walletStderr = text }
    onExited: function(c){ root.walletBusy = false; if (root.refreshQueued) Qt.callLater(root.startRefresh) }
  }
  Timer {
    id: qwenStatsTimer
    interval: 2200
    running: root.opened && serviceState && serviceState.active === true
    repeat: true
    onTriggered: root.refreshQwenStats()
  }
  Timer {
    id: qwenStatsBarTimer
    interval: 3000
    running: !root.opened && serviceState && serviceState.active === true
    repeat: true
    onTriggered: root.refreshQwenStats()
  }

  IpcHandler {
    id: ipc
    target: "gotar.ai-usage"
    function refresh(): string { root.refresh(); return "ok" }
    function localStart(): string { root.localStart(); return "ok" }
    function localStop(): string { root.localStop(); return "ok" }
    function localToggle(): string { root.localToggle(); return "ok" }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(860))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.settingsOpen
      onMoveRequested: function(dx, dy){
        if (dy !== 0) panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(56), 0, Math.max(0, panelFlick.contentHeight - panelFlick.height))
      }
      onCloseRequested: root.settingsOpen ? root.closeSettings() : root.close()
      onTabRequested: function(dir){ root.switchPanel(dir) }
      onTextKey: function(t){ if (t === "r" || t === "R") root.refresh(); else if (t === "s" || t === "S") root.settingsOpen ? root.closeSettings() : root.openSettings() }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: root.settingsOpen ? "Settings" : "AI Usage"
            meta: root.settingsOpen ? "Opencode Go key, endpoint & local model" : root.heroMeta()
            detail: root.settingsOpen ? "Keys are stored in shell.json (user-readable only)." : ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component { Text { text: root.settingsOpen ? "󰒓" : "󰚩"; color: root.alarming ? root.urgent : root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.display } }
            trailingControl: Component {
              Row { spacing: Style.space(4)
                PanelActionButton { visible: !root.settingsOpen; iconText: "󰑐"; tooltipText: "Refresh"; foreground: root.foreground; fontFamily: root.fontFamily; enabled: !usageProcess.running && !opencodeDirect.running; onClicked: root.refresh() }
                PanelActionButton { iconText: root.settingsOpen ? "󰁍" : "󰒓"; tooltipText: root.settingsOpen ? "Back" : "Settings"; foreground: root.foreground; fontFamily: root.fontFamily; onClicked: root.settingsOpen ? root.closeSettings() : root.openSettings() }
              }
            }
          }

          Column {
            visible: root.settingsOpen
            width: parent.width
            spacing: Style.space(12)
            PanelSectionHeader { text: "OPENCODE GO"; foreground: root.foreground; fontFamily: root.fontFamily }
            Text { width: parent.width; text: "API key is sent as Bearer to the JSON endpoint. Leave blank to fall back to ai-usagebar's opencode-go config (~/.config/ai-usagebar/config.toml). Endpoint is polled with curl every refresh."; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
            Text { width: parent.width; text: "Wallet (Zen credits) is NOT on the Go API; fetched headlessly from the billing page using a DEDICATED Chromium profile (never your default browser profile, so Google cookies are untouched; chromium --headless --dump-dom, no visible tab, cached " + root.opencodeBalanceTtlSec + "s). First time: run `opencode-balance --login` once to sign in. Feature request: github.com/anomalyco/opencode/issues/44189."; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap; font.italic: true }
            Column { width: parent.width; spacing: Style.space(6)
              Text { text: "API key"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true }
              TextField {
                id: apiField
                width: parent.width
                password: true
                placeholderText: root.opencodeApiKey !== "" ? "Leave blank to keep current key" : "Paste Opencode Go API key (sk-…)"
                foreground: root.foreground
                onTextEdited: { root.editApiKey = text; root.dirtyApiKey = true }
                Keys.onEscapePressed: focus = false
                onAccepted: root.saveSettings()
              }
              Text { visible: root.opencodeApiKey !== "" && !root.dirtyApiKey; text: "● key stored (" + root.opencodeApiKey.length + " chars)"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
              Text { visible: root.dirtyApiKey && root.editApiKey !== ""; text: "New key will be saved (" + root.editApiKey.length + " chars)"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
            }
            Column { width: parent.width; spacing: Style.space(6)
              Text { text: "Endpoint (JSON)"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true }
              TextField {
                width: parent.width
                text: root.editEndpoint
                placeholderText: "https://opencode.ai/zen/go/v1/usage"
                foreground: root.foreground
                onTextEdited: root.editEndpoint = text
                Keys.onEscapePressed: focus = false
                onAccepted: root.saveSettings()
              }
            }
            Column { width: parent.width; spacing: Style.space(6)
              Text { text: "Workspace ID (wallet)"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true }
              TextField { width: parent.width; text: root.editWorkspaceId; foreground: root.foreground; placeholderText: "wrk_…"; onTextEdited: root.editWorkspaceId = text; onAccepted: root.saveSettings() }
              Text { width: parent.width; text: "Used for wallet fetch: https://opencode.ai/workspace/<id>/billing"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
            }
            Column { width: parent.width; spacing: Style.space(6)
              Text { text: "Wallet cache TTL (seconds)"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true }
              TextField { width: parent.width; text: String(root.editBalanceTtl); foreground: root.foreground; placeholderText: "600"; validator: IntValidator { bottom: 60; top: 86400 } onTextEdited: root.editBalanceTtl = Number(text) || 600; onAccepted: root.saveSettings() }
            }
            PanelSeparator { width: parent.width; foreground: root.foreground }
            PanelSectionHeader { text: "LOCAL MODEL"; foreground: root.foreground; fontFamily: root.fontFamily }
            Column { width: parent.width; spacing: Style.space(6)
              Text { text: "systemd unit"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true }
              TextField { width: parent.width; text: root.editLocalUnit; foreground: root.foreground; placeholderText: "llama-cpp-server.service"; onTextEdited: root.editLocalUnit = text; onAccepted: root.saveSettings() }
            }
            Column { width: parent.width; spacing: Style.space(6)
              Text { text: "Host (display)"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true }
              TextField { width: parent.width; text: root.editLocalHost; foreground: root.foreground; placeholderText: "127.0.0.1:8080"; onTextEdited: root.editLocalHost = text; onAccepted: root.saveSettings() }
            }
            PanelSeparator { width: parent.width; foreground: root.foreground }
            PanelSectionHeader { text: "DISPLAY"; foreground: root.foreground; fontFamily: root.fontFamily }
            Toggle {
              width: parent.width
              label: "Show usage values in bar"
              description: "Icon only when off. Panel still shows full bars."
              checked: root.editShowValue
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.editShowValue = !root.editShowValue
            }
            Column { width: parent.width; spacing: Style.space(6)
              Text { text: "Refresh interval (seconds)"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true }
              TextField { width: parent.width; text: String(root.editRefresh); foreground: root.foreground; inputMethodHints: Qt.ImhDigitsOnly; onTextEdited: root.editRefresh = Number(text) || 300; onAccepted: root.saveSettings() }
            }
            Button {
              width: parent.width
              text: "Save settings"
              iconText: "󰄬"
              bordered: true
              focusable: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.saveSettings()
            }
            Button {
              width: parent.width
              text: "Open ai-usagebar TUI"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: { if (root.bar) root.bar.run("omarchy-launch-floating-terminal-with-presentation ai-usagebar-tui"); root.close() }
            }
          }

          Column {
            visible: !root.settingsOpen
            width: parent.width
            spacing: Style.space(16)
            BorderSurface {
              readonly property string msg: {
                if (opencodeError !== "" && codexError !== "") return opencodeError + " · " + codexError
                if (opencodeError !== "") return opencodeError
                if (codexError !== "") return codexError
                return ""
              }
              visible: msg !== ""
              width: parent.width
              implicitHeight: statusText.implicitHeight + Style.spacing.xl * 2
              color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.09)
              borderSpec: Border.flat(Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.35), 1)
              radius: Style.cornerRadius
              Text { id: statusText; anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; anchors.leftMargin: Style.space(12); anchors.rightMargin: Style.space(12); text: parent.msg; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
            }
            Text {
              visible: root.loading && !root.opencodeWindows && !root.codexEntry
              width: parent.width
              text: "Collecting providers…"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }
            Column {
              width: parent.width
              spacing: Style.space(8)
              PanelSeparator { width: parent.width; foreground: root.foreground }
              PanelSectionHeader { text: "OPENCODE GO"; foreground: root.foreground; fontFamily: root.fontFamily }
              Text { width: parent.width; text: opencodeError !== "" ? autoSafe(opencodeError) : "Plan: OpenCode Go" + (opencodeStale ? " · cached" : ""); color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
              Text { visible: !opencodeWindows && opencodeError === ""; width: parent.width; text: "No data yet"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
              MetricRow { visible: opencodeWindows && opencodeWindows.rolling; width: parent.width; row: opencodeWindows && opencodeWindows.rolling ? { label: "Rolling", percent: opencodeWindows.rolling.percent, value: Math.round(opencodeWindows.rolling.percent) + "%", detail: "", reset_at: opencodeWindows.rolling.resetsAt, severity: opencodeWindows.rolling.percent >= 90 ? "critical" : opencodeWindows.rolling.percent >= 75 ? "high" : "low" } : null }
              Text { visible: opencodeWindows && opencodeWindows.rolling; width: parent.width; text: formatReset(opencodeWindows && opencodeWindows.rolling ? opencodeWindows.rolling.resetsAt : "", root.nowMs); color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
              Text {
                visible: opencodeWindows && opencodeWindows.rolling
                width: parent.width
                color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
                text: { var p = opencodeWindows && opencodeWindows.rolling ? Math.round(opencodeWindows.rolling.percent) : 0; return p + "% used · " + (100 - p) + "% left" }
              }
              MetricRow { visible: opencodeWindows && opencodeWindows.weekly; width: parent.width; row: opencodeWindows && opencodeWindows.weekly ? { label: "Weekly", percent: opencodeWindows.weekly.percent, value: Math.round(opencodeWindows.weekly.percent) + "%", detail: "", reset_at: opencodeWindows.weekly.resetsAt, severity: opencodeWindows.weekly.percent >= 90 ? "critical" : "low" } : null }
              Text { visible: opencodeWindows && opencodeWindows.weekly; width: parent.width; text: formatReset(opencodeWindows && opencodeWindows.weekly ? opencodeWindows.weekly.resetsAt : "", root.nowMs); color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
              Text {
                visible: opencodeWindows && opencodeWindows.weekly
                width: parent.width
                color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
                text: { var p = opencodeWindows && opencodeWindows.weekly ? Math.round(opencodeWindows.weekly.percent) : 0; return p + "% used · " + (100 - p) + "% left" }
              }
              MetricRow { visible: opencodeWindows && opencodeWindows.monthly; width: parent.width; row: opencodeWindows && opencodeWindows.monthly ? { label: "Monthly", percent: opencodeWindows.monthly.percent, value: Math.round(opencodeWindows.monthly.percent) + "%", detail: "", reset_at: opencodeWindows.monthly.resetsAt, severity: opencodeWindows.monthly.percent >= 90 ? "critical" : "low" } : null }
              Text { visible: opencodeWindows && opencodeWindows.monthly; width: parent.width; text: formatReset(opencodeWindows && opencodeWindows.monthly ? opencodeWindows.monthly.resetsAt : "", root.nowMs); color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
              Text {
                visible: opencodeWindows && opencodeWindows.monthly
                width: parent.width
                color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
                text: { var p = opencodeWindows && opencodeWindows.monthly ? Math.round(opencodeWindows.monthly.percent) : 0; return p + "% used · " + (100 - p) + "% left" }
              }
              // Wallet row — uses opencode-balance.sh via CDP (existing Chromium)
              Text { visible: !!walletInfo; width: parent.width; text: "Wallet"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
              Text {
                visible: !!walletInfo || walletError !== ""
                width: parent.width; wrapMode: Text.WordWrap
                color: walletError !== "" ? root.urgent : root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
                text: {
                  if (walletInfo) return walletInfo.balance + " USD" + (walletInfo.cached ? " · cached" : "") + (walletInfo.fetchedAt ? " · " + formatUpdated(walletInfo.fetchedAt, root.nowMs) : "")
                  return "Wallet: " + autoSafe(walletError)
                }
              }
              Text { visible: walletBusy; width: parent.width; text: "Wallet refreshing…"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.italic: true }
            }
            Column {
              width: parent.width
              spacing: Style.space(8)
              PanelSeparator { width: parent.width; foreground: root.foreground }
              PanelSectionHeader { text: "CODEX · OPENAI"; foreground: root.foreground; fontFamily: root.fontFamily }
              Text { width: parent.width; text: codexEntry ? autoSafe(codexEntry.plan) + (codexStale ? " · cached" : "") : codexError !== "" ? autoSafe(codexError) : "ChatGPT Plus"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
              Repeater {
                model: codexEntry && Array.isArray(codexEntry.metrics) && codexEntry.metrics.length > 0
                       ? codexEntry.metrics
                       : (codexEntry ? [{ label: codexEntry.label, percent: codexEntry.percent, detail: codexEntry.detail, reset_at: codexEntry.reset_at }] : [])
                Column {
                  required property var modelData
                  width: parent.width
                  spacing: Style.space(4)
                  MetricRow { visible: !!modelData; width: parent.width; row: modelData ? { label: modelData.label, percent: modelData.percent, value: Math.round(modelData.percent) + "%", detail: modelData.detail, reset_at: modelData.reset_at, severity: modelData.percent >= 90 ? "critical" : modelData.percent >= 75 ? "high" : "low" } : null }
                  Text { visible: !!modelData; width: parent.width; text: modelData ? formatReset(modelData.reset_at, root.nowMs) : ""; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                  Text { visible: !!modelData; width: parent.width; text: modelData ? Math.round(modelData.percent) + "% used · " + (100 - Math.round(modelData.percent)) + "% left" + (modelData.detail !== "" ? " · " + autoSafe(modelData.detail) : "") : ""; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
                }
              }
              Text {
                visible: codexEntry !== null && Array.isArray(codexEntry.metrics) && codexEntry.metrics.length === 1 && !codexEntry.has5h && /plus|pro/i.test(String(codexEntry.plan))
                width: parent.width
                text: "5h limit restored, but the usage endpoint is not reporting a 5h window yet"
                color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.italic: true
              }
              Repeater {
                visible: codexEntry !== null
                model: codexEntry ? codexEntry.sections : []
                Column {
                  required property var modelData
                  width: parent.width
                  visible: modelData && modelData.type === "block"
                  spacing: Style.space(4)
                  Text { width: parent.width; text: parent.visible && modelData ? autoSafe(modelData.label) : ""; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true }
                  Text { width: parent.width; text: parent.visible && modelData && modelData.body ? modelData.body.map(function(l){return autoSafe(l)}).join("\n") : ""; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
                }
              }
              Text { visible: codexEntry === null && codexError === ""; width: parent.width; text: "No Codex data"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
            }
            Column {
              width: parent.width
              spacing: Style.space(6)
              PanelSeparator { width: parent.width; foreground: root.foreground }
              PanelSectionHeader { text: "LOCAL QWEN 3.8"; foreground: root.foreground; fontFamily: root.fontFamily }
              Row {
                width: parent.width
                spacing: Style.space(8)
                Column {
                  width: parent.width - toggle.width - parent.spacing
                  spacing: 2
                  Text { width: parent.width; text: serviceState ? (serviceState.active ? "Running" : serviceState.busy ? serviceState.stateText : "Stopped") : "Checking…"; color: serviceState && serviceState.active ? root.foreground : root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true }
                  Text { width: parent.width; text: localHost + " · " + localModelName; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; elide: Text.ElideRight }
                }
                ToggleSwitch {
                  id: toggle
                  anchors.verticalCenter: parent.verticalCenter
                  checked: serviceState ? serviceState.active === true : false
                  busy: serviceState ? serviceState.busy === true : false
                  foreground: root.foreground
                  accent: Color.accent
                  onToggled: root.localToggle()
                }
              }
              // — Qwen 3.8 live stats (tokens/sec, ctx, draft) —
              Column {
                visible: serviceState && serviceState.active === true
                width: parent.width
                spacing: Style.space(8)
                topPadding: Style.space(4)
                Rectangle { width: parent.width; height: 1; color: root.alpha(root.foreground, 0.08) }
                // ctx bar
                Column {
                  width: parent.width
                  spacing: 4
                  Row {
                    width: parent.width
                    spacing: 6
                    Text { id: ctxLabel; text: "Context"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true }
                    Text {
                      width: parent.width - ctxLabel.width - parent.spacing
                      horizontalAlignment: Text.AlignRight
                      elide: Text.ElideRight
                      text: qwenStats ? (qwenStats.ctx_used + " / " + qwenStats.ctx_total + "  ·  " + qwenStats.ctx_pct + "%") : "—"
                      color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
                    }
                  }
                  Item {
                    width: parent.width
                    height: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))
                    Rectangle { id: qwenCtxTrack; anchors.fill: parent; radius: height/2; color: root.track }
                    Rectangle {
                      anchors.left: qwenCtxTrack.left; anchors.verticalCenter: qwenCtxTrack.verticalCenter
                      height: qwenCtxTrack.height; radius: qwenCtxTrack.radius
                      width: qwenCtxTrack.width * root.clamp(qwenStats ? qwenStats.ctx_pct/100 : 0, 0, 1)
                      color: qwenStats && qwenStats.ctx_pct >= 85 ? "#ef4444" : qwenStats && qwenStats.ctx_pct >= 65 ? "#d9a214" : "#2ea043"
                      Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                    }
                  }
                }
                Grid {
                  width: parent.width
                  columns: 2
                  columnSpacing: Style.space(10)
                  rowSpacing: Style.space(6)
                  // row 1: gen speed
                  Column { width: (parent.width - parent.columnSpacing)/2; spacing: 2
                    Text { text: qwenStats && qwenStats.processing ? "LIVE" : "GEN TOKENS/SEC"; color: root.dim; font.family: root.fontFamily; font.pixelSize: 10; font.letterSpacing: 0.6; font.bold: true }
                    Row { spacing: 4
                      Text {
                        text: {
                          if (!qwenStats) return "—"
                          var v = qwenStats.processing ? (qwenStats.live_tps || qwenStats.prompt_tps) : (qwenStats.gen_tps || qwenStats.live_tps)
                          return v ? Number(v).toFixed(1) + " t/s" : (qwenStats.processing ? "…" : "—")
                        }
                        color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true
                      }
                      Text {
                        visible: qwenStats && qwenStats.processing && qwenStats.live_tps_3s
                        text: qwenStats ? "(" + Number(qwenStats.live_tps_3s).toFixed(1) + " 3s)" : ""
                        color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter
                      }
                    }
                    Text {
                      text: qwenStats && qwenStats.processing ? (qwenStats.prompt_tps ? "prompt " + Number(qwenStats.prompt_tps).toFixed(0) + " tok/s" : "generating…") : (qwenStats && qwenStats.n_decoded ? qwenStats.n_decoded + " tokens" : "")
                      color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
                      visible: text !== ""
                    }
                  }
                  Column { width: (parent.width - parent.columnSpacing)/2; spacing: 2
                    Text { text: "PROMPT TOKENS/SEC"; color: root.dim; font.family: root.fontFamily; font.pixelSize: 10; font.letterSpacing: 0.6; font.bold: true }
                    Text {
                      text: qwenStats && qwenStats.prompt_tps ? Number(qwenStats.prompt_tps).toFixed(1) + " t/s" : "—"
                      color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true
                    }
                    Text {
                      visible: qwenStats && qwenStats.draft_accept !== null
                      text: qwenStats && qwenStats.draft_accept !== null ? "draft accept " + Math.round(qwenStats.draft_accept*100) + "%" : ""
                      color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
                    }
                  }
                }
                Text {
                  width: parent.width
                  wrapMode: Text.WordWrap
                  text: qwenStats && qwenStats.model ? qwenStats.model + " · " + (qwenStats.processing ? "generating" : "idle") + (qwenStatsBusy ? " · updating…" : "") : localModelName + " · " + (serviceState ? serviceState.stateText : "")
                  color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
                }
              }
            }
            Text {
              width: parent.width
              topPadding: Style.space(2)
              horizontalAlignment: Text.AlignHCenter
              text: {
                var parts = []
                if (opencodeFetchedAt !== "") parts.push("Go " + formatUpdated(opencodeFetchedAt, root.nowMs))
                if (codexFetchedAt !== "") parts.push("Codex " + formatUpdated(codexFetchedAt, root.nowMs))
                var t = parts.join(" · ")
                if (t !== "") return t + ((usageProcess.running || opencodeDirect.running) ? " · refreshing…" : "")
                return (usageProcess.running || opencodeDirect.running) ? "Refreshing…" : ""
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
        }
      }
    }
  }

  component MetricRow: Column {
    id: metricRow
    property var row: null
    readonly property bool critical: row && row.percent >= 85
    readonly property bool mid: row && row.percent >= 45 && row.percent < 85
    readonly property color barColor: {
      if (!row) return root.foreground
      if (row.percent >= 85) return "#ef4444"
      if (row.percent >= 45) return "#d9a214"
      return "#2ea043"
    }
    readonly property color valueColor: {
      if (!row) return root.dim
      if (row.percent >= 85) return "#ef4444"
      if (row.percent >= 45) return "#d9a214"
      return "#2ea043"
    }
    spacing: Style.space(6)
    Item {
      width: parent.width
      implicitHeight: Math.max(metricLabel.implicitHeight, metricValue.implicitHeight)
      Text { id: metricLabel; text: metricRow.row ? metricRow.row.label : ""; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; elide: Text.ElideRight; anchors.left: parent.left; anchors.right: metricValue.left; anchors.rightMargin: Style.spacing.sm; anchors.verticalCenter: parent.verticalCenter }
      Text { id: metricValue; text: metricRow.row && metricRow.row.value !== "" ? metricRow.row.value : (metricRow.row ? metricRow.row.percent + "%" : ""); color: metricRow.valueColor; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter }
    }
    Item {
      width: parent.width
      implicitHeight: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))
      Rectangle { id: meterTrack; anchors.fill: parent; radius: height / 2; color: root.track }
      Rectangle { anchors.left: meterTrack.left; anchors.verticalCenter: meterTrack.verticalCenter; height: meterTrack.height; radius: meterTrack.radius; width: meterTrack.width * root.clamp(metricRow.row ? metricRow.row.percent/100 : 0, 0,1); color: metricRow.barColor; Behavior on width { NumberAnimation{ duration:160; easing.type:Easing.OutCubic } } }
    }
    Text { visible: text !== ""; width: parent.width; text: metricRow.row ? (metricRow.row.detail || "") : ""; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
  }
}
