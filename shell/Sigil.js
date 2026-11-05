.pragma library

// The About sigil's geometry: every fact about the machine is one ring of
// round dots. Adapted from github.com/erikrjohansson/omarchy-machine-mark
// (Sigil.js, MIT) — its (u, w) mark model, bead dots and seeded shape are
// kept; the strip and the knead between the two are dropped (Ahaan wanted the
// concentric rings only), and the Omarchy rings (theme, themes, plugins) are
// replaced by this desktop's own (palette, wallpapers), plus three
// this laptop has that upstream has no ring for: the P/E core split, both
// GPUs with the dGPU's power state, and the battery's wear.
//
// A mark lives in (u, w): u runs round the ring 0..1 from 12 o'clock, w across
// it from -1 (inner edge) to 1 (outer). About.qml paints each ring once into
// its own canvas and turns the canvas, so nothing here runs per frame.

var TAU = Math.PI * 2

function clamp(v, a, b) { return Math.max(a, Math.min(b, v)) }
function lerp(a, b, k) { return a + (b - a) * k }

function hashStr(s) {
    var h = 2166136261 >>> 0
    for (var i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619) >>> 0 }
    return h
}
function rng(seed) {
    var a = seed >>> 0
    return function() {
        a = (a + 0x6D2B79F5) >>> 0
        var t = a
        t = Math.imul(t ^ (t >>> 15), t | 1)
        t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296
    }
}
function rgbOf(hex) {
    var n = parseInt(String(hex).slice(1, 7), 16)
    return [n >> 16 & 255, n >> 8 & 255, n & 255]
}
function alpha(hex, a) { var c = rgbOf(hex); return "rgba(" + c[0] + "," + c[1] + "," + c[2] + "," + a + ")" }
function mix(h1, h2, k) {
    var a = rgbOf(h1), b = rgbOf(h2)
    return "#" + a.map(function(v, i) { return ("0" + Math.round(lerp(v, b[i], k)).toString(16)).slice(-2) }).join("")
}
function lum(hex) { var c = rgbOf(hex); return (0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]) / 255 }

// The section colours, from pywal's slots by their palette.sh meaning
// (color4 blue, color3 yellow, color5 magenta, color9 the accent). Under a
// wallpaper-derived palette those slots are arbitrary image colours and two of
// them can land on top of each other or on the card, so any that is too close
// to the background is lifted toward the foreground until it reads.
function palette(w) {
    var fg = String(w.color15 || w.foreground || "#dddddd"), bg = String(w.background || "#101010")
    var lift = function(c) {
        c = String(c || fg)
        for (var k = 0.2; Math.abs(lum(c) - lum(bg)) < 0.28 && k <= 1; k += 0.2) c = mix(String(c), fg, k)
        return c
    }
    return { fg: fg, bg: bg, dim: mix(fg, bg, 0.45), accent: lift(w.color9),
             cat: { hw: lift(w.color4), sw: lift(w.color3), age: lift(w.color5) },
             light: lum(bg) > 0.5 }
}

// ---------------------------------------------------------------- the rings

var CATS = ["hw", "sw", "age"]
var DIM_RING = 0.28
var CAT_NAME = { hw: "Hardware", sw: "Software", age: "Age / Uptime" }
// Radii are fractions of the sigil's radius. Fourteen rings, as upstream has,
// but one more in hardware (the battery) and one fewer in software (one
// Palette ring, not upstream's Theme + Themes: Ahaan, 2026-10-21, "merge
// palettes into one thing"), so the hardware band is tighter than theirs.
var RINGS = [
    { k: "cores",    cat: "hw",  name: "CPU",       r: [0.03, 0.12] },
    { k: "threads",  cat: "hw",  name: "Threads",   r: [0.13, 0.24] },
    { k: "gpu",      cat: "hw",  name: "GPU",       r: [0.25, 0.29] },
    { k: "mem",      cat: "hw",  name: "Memory",    r: [0.295, 0.33] },
    { k: "disk",     cat: "hw",  name: "Disk",      r: [0.335, 0.37] },
    { k: "hz",       cat: "hw",  name: "Display",   r: [0.375, 0.425] },
    { k: "bat",      cat: "hw",  name: "Battery",   r: [0.43, 0.465] },
    { k: "pkgs",     cat: "sw",  name: "Packages",  r: [0.515, 0.585] },
    { k: "upd",      cat: "sw",  name: "Upgrades",  r: [0.595, 0.645] },
    { k: "palettes", cat: "sw",  name: "Palette",   r: [0.655, 0.71] },
    { k: "walls",    cat: "sw",  name: "Wallpapers", r: [0.72, 0.775] },
    { k: "age",      cat: "age", name: "OS age",    r: [0.825, 0.86] },
    { k: "since",    cat: "age", name: "Updated",   r: [0.87, 0.905], fixed: true },
    { k: "up",       cat: "age", name: "Uptime",    r: [0.915, 0.995], fixed: true }
]
var RK = {}
RINGS.forEach(function(r, i) { RK[r.k] = i })
// Thin dotted dividers between the sections.
var SEPS = [["hw", 0.49], ["sw", 0.80]]

// The rings a machine has. No battery on a desktop: the ring is left out
// rather than drawn empty, and the list loses its row.
function present(m) {
    return RINGS.map(function(r) { return r.k !== "bat" || !!m.battery })
}

// ------------------------------------------------------------- machine facts

var GIB = 1073741824
function num(n) { return Math.round(n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",") }
function size(bytes) { var g = bytes / GIB; return g >= 1000 ? (g / 1024).toFixed(2) + " TiB" : g.toFixed(1) + " GiB" }
var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
var DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
function day(epoch) { var d = new Date(epoch * 1000); return d.getDate() + " " + MONTHS[d.getMonth()] + " " + d.getFullYear() }
function stamp(epoch) {
    var d = new Date(epoch * 1000)
    return DAYS[d.getDay()] + " " + d.getDate() + " " + MONTHS[d.getMonth()] + ", " + ("0" + d.getHours()).slice(-2) + ":" + ("0" + d.getMinutes()).slice(-2)
}
function ago(hours) {
    if (hours < 1) return Math.max(1, Math.round(hours * 60)) + " min ago"
    if (hours < 48) return Math.floor(hours) + " h ago"
    return Math.floor(hours / 24) + " days ago"
}
function count(n, word) { return num(n) + " " + word + (n === 1 ? "" : "s") }
function plural(n, one, many) { return n === 1 ? one : n + " " + many }
function title(s) { return String(s || "").split(/[-_ ]/).map(function(w) { return w.charAt(0).toUpperCase() + w.slice(1) }).join(" ") }
function upText(sec) {
    var d = Math.floor(sec / 86400), h = Math.floor(sec % 86400 / 3600), mi = Math.floor(sec % 3600 / 60)
    var u = function(n, w) { return n + " " + w + (n === 1 ? "" : "s") }
    return d ? u(d, "day") + ", " + u(h, "hour") : u(h, "hour") + ", " + u(mi, "min")
}

// A GPU's core count is a different unit per driver (NVIDIA CUDA cores, AMD
// compute units, Intel execution units), so a dot is one block of roughly the
// same size: an SM's 128 cores, one CU, 8 EUs.
var GPU_UNITS = {
    nvidia: { per: 128, long: "CUDA cores" },
    amdgpu: { per: 1,   long: "compute units" },
    i915:   { per: 8,   long: "execution units" },
    xe:     { per: 8,   long: "execution units" }
}
function gpuDots(g) {
    var u = GPU_UNITS[g.driver]
    return u && g.cores ? clamp(Math.round(g.cores / u.per), 1, 96) : 0
}

// A counted ring gets coarser once its count would crowd it.
var COARSER = {
    threads: { per: [1, 2, 4, 8], max: 48 },
    pkgs:    { per: [10, 20, 40, 100, 200], max: 160 },
    upd:     { per: [40, 80, 200, 400, 1000, 2000], max: 160 },
    age:     { per: [1, 2, 4, 13, 52], max: 140 }   // weeks
}
function perMark(k, n) {
    var st = COARSER[k]
    for (var i = 0; i < st.per.length; i++) if ((n || 0) / st.per[i] <= st.max) return st.per[i]
    return st.per[st.per.length - 1]
}
function lines(n, per) { return n > 0 ? Math.max(1, Math.round(n / per)) : 0 }

// Everything derived from one reading; `elapsed` seconds since it was taken
// keeps uptime and "updated" ticking between readings.
function facts(m, elapsed) {
    var now = m.now + elapsed, f = {}
    f.days = m.installed > 0 ? Math.max(0, Math.floor((now - m.installed) / 86400)) : 0
    f.upSec = (m.uptime || 0) + elapsed
    f.sinceH = m.lastUpgrade > 0 ? Math.max(0, (now - m.lastUpgrade) / 3600) : -1
    f.mem = m.memory.total > 0 ? m.memory.used / m.memory.total : 0
    f.disk = m.disk.total > 0 ? (m.disk.used || 0) / m.disk.total : 0
    f.pulses = m.display.hz > 0 ? Math.max(1, Math.round(m.display.hz / 10)) : 0
    f.weeks = Math.ceil(f.days / 7)
    f.per = { threads: perMark("threads", m.cpu.threads), pkgs: perMark("pkgs", m.packages.pacman),
              upd: perMark("upd", m.upgrades), age: perMark("age", f.weeks) }
    f.lines = { threads: lines(m.cpu.threads, f.per.threads), pkgs: lines(m.packages.pacman, f.per.pkgs),
                upd: lines(m.upgrades, f.per.upd), age: lines(f.weeks, f.per.age) }
    f.pkgSizes = !!(m.packages.sizes && m.packages.sizes.length)
    f.weekly = !!(m.upgradesByWeek && m.upgradesByWeek.length)
    f.dgpuAsleep = m.dgpu === "suspended" || m.dgpu === "suspending"
    return f
}

var UNKNOWN = "unknown"
// The list's value for each ring. Health is text only (Ahaan, 2026-10-21):
// the ring is the charge, nothing else.
function value(k, m, f) {
    switch (k) {
    case "cores":   return m.cpu.name || UNKNOWN
    case "threads": return m.cpu.threads ? m.cpu.threads + (m.cpu.mhz ? " @ " + (m.cpu.mhz / 1000).toFixed(2) + " GHz" : "") : UNKNOWN
    case "gpu":     return m.gpus.length ? m.gpus.map(function(g) { return g.name.replace(/ \d+GB| Laptop GPU| Graphics/g, "") }).join(" + ") : UNKNOWN
    case "mem":     return m.memory.total ? (m.memory.used / GIB).toFixed(1) + " / " + (m.memory.total / GIB).toFixed(1) + " GiB" : UNKNOWN
    case "disk":    return m.disk.total ? Math.round((m.disk.used || 0) / GIB) + " GiB / " + size(m.disk.total).replace(/\.0 /, " ") : UNKNOWN
    case "hz":      return m.display.width ? m.display.width + "×" + m.display.height + " @ " + Math.round(m.display.hz) + " Hz" : UNKNOWN
    case "bat":     return m.battery ? m.battery.capacity + "% · " + (m.battery.health ? Math.round(m.battery.health * 100) + "% health" : m.battery.status) : UNKNOWN
    case "pkgs":    return m.packages.pacman !== null ? num(m.packages.pacman) + (m.packages.flatpak ? " + " + m.packages.flatpak + " flatpak" : "") : UNKNOWN
    case "upd":     return num(m.upgrades)
    case "palettes": return m.palettes.count ? m.palettes.count + (m.palette ? " · " + title(m.palette) : "") : UNKNOWN
    case "walls":   return m.wallpapers.count ? m.wallpapers.count + (m.wallpapers.name ? " · " + m.wallpapers.name : "") : UNKNOWN
    case "age":     return m.installed > 0 ? f.days + " days" : UNKNOWN
    case "since":   return f.sinceH < 0 ? "never" : stamp(m.lastUpgrade)
    case "up":      return upText(f.upSec)
    }
    return ""
}

// The seed: same hostname and hardware, same shape.
function geometry(m) {
    var f = facts(m, 0)
    var r = rng(hashStr([m.host, m.cpu.name, m.gpus.map(function(g) { return g.name }).join(","), m.installed].join("|")))
    var arr = function(n) { var a = []; for (var i = 0; i < n; i++) a.push(r()); return a }
    var g = { offC: arr(RINGS.length), spoke: arr(Math.max(1, f.lines.threads)), tick: arr(f.lines.pkgs),
              dot: arr(Math.max(1, f.lines.age)), seg: arr(f.lines.upd) }
    if (f.pkgSizes && g.tick.length) {
        var logs = groups(m.packages.sizes, g.tick.length, 1).map(function(v) { return Math.log(1 + v) })
        var lo = Math.min.apply(null, logs), hi = Math.max.apply(null, logs)
        g.tick = logs.map(function(v) { return hi > lo ? (v - lo) / (hi - lo) : 0.5 })
    }
    if (f.weekly) {
        var ups = groups(m.upgradesByWeek, g.dot.length, f.per.age), most = Math.max.apply(null, ups)
        g.dot = ups.map(function(v) { return most > 0 ? Math.sqrt(v / most) : 0 })
    }
    return g
}
function groups(a, n, size) {
    var out = []
    for (var j = 0; j < n; j++) {
        var i0 = size > 1 ? j * size : Math.floor(j * a.length / n), i1 = size > 1 ? i0 + size : Math.floor((j + 1) * a.length / n), t = 0
        for (var i = i0; i < Math.min(i1, a.length); i++) t += a[i] || 0
        out.push(t)
    }
    return out
}

// Neighbouring rings in a section alternate between its colour and a softer
// shade of it, so they stay apart.
function ringColor(k, pal) {
    if (k === "up") return pal.accent
    var r = RINGS[RK[k]], base = pal.cat[r.cat], nth = 0
    for (var i = 0; i < RK[k]; i++) if (RINGS[i].cat === r.cat) nth++
    return nth % 2 ? mix(base, pal.fg, 0.32) : base
}

// -------------------------------------------------------------------- marks

function marks(k, s) {
    var m = s.machine, f = s.facts, g = s.geo, pal = s.pal, C = ringColor(k, pal), out = []
    var track = alpha(pal.dim, pal.light ? 0.9 : 0.55), faint = alpha(pal.dim, pal.light ? 1 : 0.8)
    var j, n
    switch (k) {
    case "cores":
        // Performance cores first, long and heavy; efficient ones short, in
        // the softer shade. A non-hybrid CPU is all one kind.
        var sp = m.cpu.split, P = sp && sp.p && sp.e ? sp.p : m.cpu.cores || 0, E = sp && sp.p && sp.e ? sp.e : 0
        n = P + E
        for (j = 0; j < n; j++) {
            var perf = j < P
            out.push({ d: "tick", u: (j + 0.5) / n, w0: perf ? -0.75 : -0.3, w1: perf ? 0.75 : 0.3, lw: perf ? 3 : 2,
                       col: perf ? C : mix(C, pal.fg, 0.4) })
        }
        break
    case "threads":
        n = f.lines.threads
        var vary = clamp((n - 8) / 24, 0, 1)
        for (j = 0; j < n; j++)
            out.push({ d: "tick", u: (j + 0.5) / n, w0: -1, w1: -1 + 2 * lerp(0.8, 0.3 + 0.7 * g.spoke[j % g.spoke.length], vary), lw: f.per.threads > 1 ? 1.7 : 1, col: C })
        break
    case "gpu":
        // One arc per GPU, sized by its dots, a gap between. The dGPU is
        // drawn faint while it sleeps — live, from sysfs, never by asking it.
        var counts = m.gpus.map(function(gp) { return Math.max(1, gpuDots(gp)) }), tot = 0
        counts.forEach(function(c) { tot += c })
        var gap = m.gpus.length > 1 ? 0.06 : 0, span = 1 - gap * m.gpus.length, at = gap / 2
        m.gpus.forEach(function(gp, gi) {
            var c = counts[gi], len = span * c / tot, known = gpuDots(gp) > 0
            var sz = known ? clamp(1.3 * Math.sqrt(48 / Math.max(1, tot)), 1.1, 2.6) : 3.2
            var asleep = gp.type === "Discrete" && f.dgpuAsleep
            for (var q = 0; q < c; q++)
                out.push({ d: "dot", u: at + len * (q + 0.5) / c, w: 0, s: sz, col: gi ? mix(C, pal.fg, 0.3) : C, a: asleep ? 0.3 : undefined })
            at += len + gap
        })
        break
    case "mem": case "disk":
        var fill = k === "mem" ? f.mem : f.disk
        out.push({ d: "seg", u0: 0, u1: 1, w: 0, lw: 1, col: track, dash: true })
        out.push({ d: "seg", u0: 0, u1: Math.max(0.002, fill), w: 0, lw: 5, col: C })
        break
    case "hz":
        if (!f.pulses) { out.push({ d: "seg", u0: 0, u1: 1, w: 0, lw: 1, col: track }); break }
        // A square wave, a pulse per 10 Hz. It travels by turning the ring.
        var K = f.pulses, wv = function(u) { return ((u * K) % 1 + 1) % 1 < 0.5 ? 0.6 : -0.6 }
        var line = [[0, wv(0)]]
        for (var e = 1; e < 2 * K; e++) { var ue = e / (2 * K); line.push([ue, wv(ue - 1e-6)]); line.push([ue, wv(ue + 1e-6)]) }
        line.push([1, wv(1 - 1e-6)]); line.push([1, line[0][1]])
        out.push({ d: "poly", pts: line, lw: 1.3, col: C })
        break
    case "bat":
        // The charge, as memory and disk draw their fill. A charge limit
        // below 100 is a tick.
        var b = m.battery
        out.push({ d: "seg", u0: 0, u1: 1, w: 0, lw: 1, col: track, dash: true })
        out.push({ d: "seg", u0: 0, u1: Math.max(0.002, b.capacity / 100), w: 0, lw: 4, col: C })
        if (b.limit && b.limit < 100) out.push({ d: "tick", u: b.limit / 100, w0: -1, w1: 1, lw: 1, col: pal.fg })
        break
    case "pkgs":
        n = g.tick.length
        for (j = 0; j < n; j++) out.push({ d: "tick", u: (j + 0.5) / n, w0: -1, w1: -1 + 2 * (0.12 + 0.88 * g.tick[j]), lw: 1, col: C, a: 0.85 })
        break
    case "upd":
        n = g.seg.length
        for (j = 0; j < n; j++) { var u0 = j / n; out.push({ d: "seg", u0: u0, u1: u0 + (0.2 + 0.65 * g.seg[j]) / n, w: 0, lw: 2.4, col: C }) }
        break
    case "palettes":
        n = m.palettes.count || 0
        var ts = clamp(1.2 * Math.sqrt(60 / Math.max(1, n)), 0.9, 2.2), mine = -1
        for (j = 0; j < n; j++) {
            if (j === m.palettes.current) { mine = j; continue }
            out.push({ d: "dot", u: (j + 0.5) / n, w: 0, s: ts, col: C })
        }
        if (mine >= 0) out.push({ d: "dot", u: (mine + 0.5) / n, w: 0, s: ts * 1.8, col: pal.accent })
        break
    case "walls":
        n = m.wallpapers.count || 0
        var cur = -1
        for (j = 0; j < n; j++) {
            if (j === m.wallpapers.current) { cur = j; continue }
            out.push({ d: "tick", u: (j + 0.5) / n, w0: -0.4, w1: 0.4, lw: 1.6, col: C })
        }
        if (cur >= 0) out.push({ d: "tick", u: (cur + 0.5) / n, w0: -1, w1: 1, lw: 2.4, col: pal.accent })
        break
    case "age":
        if (!(m.installed > 0)) break
        n = g.dot.length
        for (j = 0; j < n; j++) {
            var last = j === n - 1, quiet = f.weekly && !last && g.dot[j] === 0
            out.push({ d: "dot", u: (j + 0.5) / n, w: 0, s: last ? 3.2 : f.weekly ? 0.7 + 2.3 * g.dot[j] : 0.8 + 1.3 * g.dot[j],
                       col: last ? pal.accent : C, a: quiet ? 0.4 : undefined })
        }
        break
    case "since":
        out.push({ d: "seg", u0: 0, u1: 1, w: 0, lw: 1, col: track, dash: true })
        for (var dd = 0; dd < 7; dd++) out.push({ d: "tick", u: dd / 7, w0: -0.7, w1: 0.7, lw: 1, col: faint })
        if (f.sinceH >= 0) {
            var fs = Math.min(1, f.sinceH / 168)
            out.push({ d: "seg", u0: 0, u1: Math.max(0.002, fs), w: 0, lw: 2.6, col: C })
            out.push({ d: "dot", u: fs, w: 0, s: 2.4, col: pal.fg })
        }
        break
    case "up":
        for (var h = 0; h <= 24; h++) out.push({ d: "tick", u: h / 24, w0: 0.25, w1: h % 6 ? 0.6 : 1, lw: 1, col: faint })
        var fu = (f.upSec / 3600 % 24) / 24
        for (var dn = 0, days = Math.min(31, Math.floor(f.upSec / 86400)); dn < days; dn++)
            out.push({ d: "dot", u: (dn + 0.5) / 31, w: 0.95, s: 1.1, col: pal.fg, a: 0.8 })
        out.push({ d: "seg", u0: 0, u1: Math.max(0.002, fu), w: -0.4, lw: 3, col: pal.accent })
        out.push({ d: "dot", u: fu, w: -0.4, s: 2.8, col: pal.fg })
        break
    }
    if (pal.light)
        for (j = 0; j < out.length; j++) {
            if (out[j].d !== "dot" && out[j].lw < 1.45) out[j].lw = 1.45
            if (out[j].a > 0.8 && out[j].a < 1) out[j].a = 1
        }
    return out
}

// ------------------------------------------------------------------ drawing

// Every mark is drawn as round dots: a line becomes a string of evenly spaced
// beads, a dashed track spaces them wider. Upstream measured filling each dot
// on its own at ~3.5 ms a frame against ~12 ms as one path, and made the
// tiniest squares and the small ones octagons; kept, since a ring here is
// still a few hundred dots.
var BEAD = { gap: 4.2, dashGap: 1.7, dashAlpha: 0.85, square: 1.1, round: 1.9 }
var OCT = [1, 0, 0.7071, 0.7071, 0, 1, -0.7071, 0.7071, -1, 0, -0.7071, -0.7071, 0, -1, 0.7071, -0.7071]
function beadDot(c, x, y, r) {
    if (r <= BEAD.square) { var h = r * 0.886; c.fillRect(x - h, y - h, 2 * h, 2 * h); return }
    c.beginPath()
    if (r > BEAD.round) c.arc(x, y, r, 0, TAU, false)
    else { c.moveTo(x + r, y); for (var k = 2; k < 16; k += 2) c.lineTo(x + OCT[k] * r, y + OCT[k + 1] * r) }
    c.fill()
}
function beadRun(c, P, u0, w0, u1, w1, step, r, skipFirst, skipLast) {
    var o = P(u0, w0), px = o[0], py = o[1], L = 0, k = Math.abs(u1 - u0) > 1e-6 ? 8 : 1, q
    for (q = 1; q <= k; q++) {
        o = P(u0 + (u1 - u0) * q / k, w0 + (w1 - w0) * q / k)
        L += Math.sqrt((o[0] - px) * (o[0] - px) + (o[1] - py) * (o[1] - py)); px = o[0]; py = o[1]
    }
    if (L < step * 0.6) {
        if (!skipFirst) { o = P((u0 + u1) / 2, (w0 + w1) / 2); beadDot(c, o[0], o[1], r) }
        return
    }
    var n = Math.max(1, Math.round(L / step))
    for (q = skipFirst ? 1 : 0; q <= (skipLast && n > 1 ? n - 1 : n); q++) { o = P(u0 + (u1 - u0) * q / n, w0 + (w1 - w0) * q / n); beadDot(c, o[0], o[1], r) }
}
// A closed ring: its last bead would land on its first, and a see-through
// bead drawn twice shows darker.
function closes(u0, u1) { return Math.abs(u1 - u0 - 1) < 1e-6 }

// z scales a mark with the sigil (device px per unit at R = 200 logical);
// dpr keeps the smallest beads a fixed LOGICAL size. Upstream's floors (0.8,
// 0.9) are logical pixels; applied as device pixels at this panel's scale 2
// they halved, and the Packages ring's thousand-odd beads all but vanished.
function drawMarks(c, ms, P, z, dpr) {
    var ga = c.globalAlpha
    for (var i = 0; i < ms.length; i++) {
        var mk = ms[i]
        c.globalAlpha = ga * (mk.a === undefined ? 1 : mk.a) * (mk.dash ? BEAD.dashAlpha : 1)
        c.fillStyle = mk.col
        if (mk.d === "dot") { var o = P(mk.u, mk.w); beadDot(c, o[0], o[1], Math.max(0.9 * dpr, mk.s * z * 0.8)); continue }
        var r = clamp(mk.lw * z * 0.5, 0.8 * dpr, 2.6 * z), step = Math.max(BEAD.gap * z, r * 2.7) * (mk.dash ? BEAD.dashGap : 1)
        if (mk.d === "tick") beadRun(c, P, mk.u, mk.w0, mk.u, mk.w1, step, r, false, false)
        else if (mk.d === "seg") beadRun(c, P, mk.u0, mk.w, mk.u1, mk.w, step, r, false, closes(mk.u0, mk.u1))
        else if (mk.d === "poly")
            for (var q = 1; q < mk.pts.length; q++)
                beadRun(c, P, mk.pts[q - 1][0], mk.pts[q - 1][1], mk.pts[q][0], mk.pts[q][1], step, r, q > 1, q === mk.pts.length - 1)
    }
    c.globalAlpha = ga
}

// One ring, centred in a square canvas of side `side` px, pointing up; the
// canvas itself is turned. R is the sigil's radius in the same pixels, and
// z the pixel scale (devicePixelRatio times the sigil's size against 200).
function paintRing(c, i, side, R, z, dpr, s) {
    var a = RINGS[i].r[0], b = RINGS[i].r[1], cx = side / 2, cy = side / 2
    var P = function(u, w) {
        var r = R * (a + (b - a) * (w + 1) / 2), th = -Math.PI / 2 + TAU * u
        return [cx + Math.cos(th) * r, cy + Math.sin(th) * r]
    }
    drawMarks(c, marks(RINGS[i].k, s), P, z, dpr)
}

// The centre dot and the two section dividers.
function paintDeco(c, side, R, dpr, pal) {
    var cx = side / 2
    c.fillStyle = pal.fg; c.beginPath(); c.arc(cx, cx, Math.max(2 * dpr, R * 0.014), 0, TAU, false); c.fill()
    SEPS.forEach(function(sp) {
        var r = R * sp[1], n = Math.round(TAU * r / (BEAD.gap * dpr * 1.8))
        c.fillStyle = alpha(pal.cat[sp[0]], pal.light ? 0.7 : 0.45)
        for (var j = 0; j < n; j++) beadDot(c, cx + Math.cos(TAU * j / n) * r, cx + Math.sin(TAU * j / n) * r, 0.8 * dpr)
    })
}

// A small picture of each ring for its list row: 16 px wide, centred on y.
function icon(c, k, x, y, col, s) {
    var pal = s.pal, f = s.facts, j
    var dot = function(px, py, r) { beadDot(c, px, py, r) }
    var run = function(x1, y1, x2, y2, r, step) {
        var n = Math.max(1, Math.round(Math.sqrt((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1)) / step))
        for (var i = 0; i <= n; i++) dot(x1 + (x2 - x1) * i / n, y1 + (y2 - y1) * i / n, r)
    }
    var faint = function(fn) { var ga = c.globalAlpha; c.globalAlpha = ga * (pal.light ? 0.6 : 0.4); fn(); c.globalAlpha = ga }
    c.fillStyle = col
    switch (k) {
    case "cores": for (j = 0; j < 4; j++) { var big = j < 2; run(x + 2 + j * 4, y - (big ? 4 : 2), x + 2 + j * 4, y + (big ? 4 : 2), 0.85, 2.67) } break
    case "threads": [6, 3, 7, 4, 5].forEach(function(hh, i) { run(x + 1 + i * 3.6, y + 4, x + 1 + i * 3.6, y + 4 - hh, 0.65, 2.2) }); break
    case "gpu":
        for (j = 0; j < 3; j++) dot(x + 1.5 + j * 3, y, 1.1)
        faint(function() { for (j = 0; j < 3; j++) dot(x + 10.5 + j * 3, y, 1.1) })
        break
    case "mem": case "disk":
        var fr = k === "mem" ? f.mem : f.disk
        faint(function() { run(x, y, x + 16, y, 0.5, 2.6) })
        run(x, y, x + Math.max(0, 16 * fr), y, 1.4, 3.4); break
    case "hz":
        var sq = [[x, y + 3], [x, y - 3], [x + 4, y - 3], [x + 4, y + 3], [x + 8, y + 3], [x + 8, y - 3], [x + 12, y - 3], [x + 12, y + 3], [x + 16, y + 3]]
        for (j = 1; j < sq.length; j++) run(sq[j - 1][0], sq[j - 1][1], sq[j][0], sq[j][1], 0.65, 2)
        break
    case "bat":
        var b = s.machine.battery
        faint(function() { run(x, y, x + 16, y, 0.5, 2.6) })
        run(x, y, x + 16 * (b ? b.capacity / 100 : 0), y, 1.2, 3); break
    case "pkgs": [5, 2, 7, 3, 6, 4, 8].forEach(function(hh, i) { run(x + 1 + i * 2.4, y + 4, x + 1 + i * 2.4, y + 4 - hh, 0.65, 2.2) }); break
    case "upd": [[0, 4], [6, 3], [11, 5]].forEach(function(p) { run(x + p[0], y, x + p[0] + p[1], y, 0.9, 2.4) }); break
    case "palettes": for (j = 0; j < 5; j++) dot(x + 1.6 + j * 3.2, y, j === 2 ? 2 : 1.3); break
    case "walls":
        for (j = 0; j < 5; j++) { var t = j === 3; if (t) c.fillStyle = pal.accent; run(x + 1.6 + j * 3.2, y - (t ? 4 : 2), x + 1.6 + j * 3.2, y + (t ? 4 : 2), 0.7, 2); c.fillStyle = col }
        break
    case "age":
        [1, 1.5, 1, 1.4].forEach(function(r, i) { dot(x + 1.5 + i * 3.6, y, r) })
        c.fillStyle = pal.accent; dot(x + 15.5, y, 2.1); break
    case "since":
        var fs = f.sinceH < 0 ? 0 : Math.min(1, f.sinceH / 168)
        faint(function() { for (j = 0; j <= 7; j++) run(x + j * 16 / 7, y - 3, x + j * 16 / 7, y + 3, 0.5, 3) })
        run(x, y, x + 16 * fs, y, 0.9, 2.4)
        c.fillStyle = pal.fg; dot(x + 16 * fs, y, 1.6); break
    case "up":
        var fu = (f.upSec / 3600 % 24) / 24
        faint(function() { [0, 4, 8, 12, 16].forEach(function(dx) { run(x + dx, y - 4, x + dx, y - 1.5, 0.5, 2.5) }) })
        run(x, y + 2, x + 16 * fu, y + 2, 1, 2.6)
        c.fillStyle = pal.fg; dot(x + 16 * fu, y + 2, 1.7); break
    }
}

// Ring rates in degrees per second: alternating directions, outer rings a
// little quicker (upstream's 0.0000065 turns/ms × (1 + i/10)), and the display
// ring's pulses travelling on top of its spin. Updated and Uptime are dials,
// so they stand still with 0 at 12 o'clock.
function degPerSec(i, f) {
    if (RINGS[i].fixed) return 0
    var r = 0.0000065 * (i % 2 ? 1 : -1) * (1 + i * 0.1)
    if (RINGS[i].k === "hz" && f.pulses > 0) r -= 0.00025 / f.pulses
    return r * 1000 * 360
}
