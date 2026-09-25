// What the Minimized widget shows, as data: the parked-window list and the widget's ui state in, a view out.
// Minimized.qml draws the view and turns its actions ("verb|arg") into calls into the service. No Qt, no
// side effects — build() is a pure function and can be exercised with plain node.

// APCA-W3 0.1.9 lightness contrast (Lc) of text on a background. Colors are {r, g, b} in 0..1, as Qt gives them.
// Every text and line color in the panel is picked by the Lc it must reach, so any theme stays readable.
function lum(c) { return 0.2126729 * Math.pow(c.r, 2.4) + 0.7151522 * Math.pow(c.g, 2.4) + 0.072175 * Math.pow(c.b, 2.4) }
function apca(text, bg) {
  var t = lum(text), b = lum(bg)
  if (t < 0.022) t += Math.pow(0.022 - t, 1.414)
  if (b < 0.022) b += Math.pow(0.022 - b, 1.414)
  if (Math.abs(b - t) < 0.0005) return 0
  var s = b > t ? (Math.pow(b, 0.56) - Math.pow(t, 0.57)) * 1.14 : (Math.pow(b, 0.65) - Math.pow(t, 0.62)) * 1.14
  return Math.abs(s) < 0.1 ? 0 : (s > 0 ? s - 0.027 : s + 0.027) * 100
}
function mix(a, b, t) { return { r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t, a: 1 } }
// a translucent color as it lands on an opaque one
function over(c, bg) { var a = c.a === undefined ? 1 : c.a; return mix(bg, c, a) }
// the color closest to `from` on the way to `to` that reaches |Lc| >= target on bg; `to` when nothing does
function reach(from, to, bg, target) {
  if (Math.abs(apca(from, bg)) >= target) return from
  if (Math.abs(apca(to, bg)) < target) return to
  var lo = 0, hi = 1
  for (var i = 0; i < 24; i++) {
    var m = (lo + hi) / 2
    if (Math.abs(apca(mix(from, to, m), bg)) >= target) hi = m
    else lo = m
  }
  return mix(from, to, hi)
}
// The panel's tones, all measured on the card surface (the lighter of its two backgrounds, so the worst case):
// ink is for what matters now, value for what a label names, label for every label, rule for lines that are
// not text, alert for problems.
var LC = { ink: 90, value: 80, label: 60, rule: 15, alert: 60 }
function tones(ink, bg, surface, urgent) {
  var card = over(surface, bg), white = { r: 1, g: 1, b: 1 }, black = { r: 0, g: 0, b: 0 }
  var far = Math.abs(apca(white, card)) > Math.abs(apca(black, card)) ? white : black
  var top = reach(over(ink, bg), far, card, LC.ink)
  return { ink: top, value: reach(card, top, card, LC.value), label: reach(card, top, card, LC.label),
    rule: reach(card, top, card, LC.rule), alert: reach(urgent, top, card, LC.alert), alertRule: reach(urgent, top, card, LC.rule) }
}

function parse(text) { try { return JSON.parse(text) } catch (e) { return null } }

// the bar mark: parked windows light it, none leave it faint
function mark(s) { return (s.windows || []).length > 0 ? "ready" : "" }

function build(s, ui) {
  s = s || {}
  var rows = []
  if (ui.problem) rows.push({ type: "error", label: ui.problem })
  var wins = s.windows || []
  if (wins.length) {
    rows.push({ type: "sec", label: "PARKED" })
    wins.forEach(function(w) {
      rows.push({ type: "win", label: w.title || w["class"] || "Unnamed window",
        value: w.title && w["class"] ? w["class"] : "", action: "restore|" + w.id })
    })
  } else {
    rows.push({ type: "soon", head: "Nothing minimized — SUPER+ALT+M or Alt double-click parks a window here" })
  }
  var n = wins.length
  return { title: "MINIMIZED", version: n ? n + (n === 1 ? " window" : " windows") : "", rows: rows, mark: mark(s) }
}
