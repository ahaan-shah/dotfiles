.pragma library

// EveMarkdown.js — Claude's Markdown, as Qt rich text in this shell's colours.
//
// Why not TextEdit.MarkdownText: it draws links and autolinked emails in
// Qt's default #0000ff whatever the palette says (measured offscreen
// 2026-10-20: palette.link had no effect), and it has no idea what a code
// block should look like. Ahaan's screenshot of an email in that blue: "looks
// really bad". An inline style on the <a> itself IS honoured, so the prose is
// converted here, with every colour handed in from Theme.
//
// Code blocks are not converted to HTML inside the prose: `blocks()` splits
// them out, and JarvisCard draws each as its own rounded panel ("make it look
// nice like it looks in an ide. Yet it should seamlessly blend in"), with
// `highlight()` colouring the tokens.
//
// A subset, on purpose — what a chat reply uses: headings, paragraphs, lists
// (nested by indent), quotes, rules, tables, fenced code; inline code, bold,
// italic, strike, links, bare URLs and emails. A fence still open at the end
// is code: that is what a reply looks like while it streams.

function esc(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;")
}

// [{ type: "text", md }, { type: "code", lang, code, open }, { type: "image", alt, url }]
//
// A line that is nothing but images — ![alt](url), one or several — becomes
// image blocks, drawn by JarvisCard as real pictures (Ahaan, 2026-10-20:
// "allow eve to show me images there"). An image in the middle of a sentence
// stays a link; there is no room to draw it in a line of text.
const IMAGE = /!\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)/g
const IMAGE_LINE = /^\s*(?:!\[[^\]]*\]\(\s*<?[^)\s>]+>?(?:\s+"[^"]*")?\s*\)\s*)+$/
function blocks(md) {
    const out = []
    const lines = String(md || "").replace(/\r/g, "").split("\n")
    let text = [], code = null
    for (const ln of lines) {
        if (code) {
            if (/^\s*(```|~~~)\s*$/.test(ln) && ln.trim().slice(0, 3) === code.fence) {
                out.push({ type: "code", lang: code.lang, code: code.lines.join("\n"), open: false })
                code = null
            } else code.lines.push(ln.slice(Math.min(code.indent, ln.length - ln.replace(/^\s+/, "").length)))
            continue
        }
        const m = /^(\s*)(```|~~~)\s*([\w+#.-]*)/.exec(ln)
        if (m) {
            if (text.length) { out.push({ type: "text", md: text.join("\n") }); text = [] }
            code = { fence: m[2], lang: m[3].toLowerCase(), lines: [], indent: m[1].length }
            continue
        }
        if (IMAGE_LINE.test(ln)) {
            if (text.length) { out.push({ type: "text", md: text.join("\n") }); text = [] }
            let im
            IMAGE.lastIndex = 0
            while ((im = IMAGE.exec(ln)) !== null) out.push({ type: "image", alt: im[1], url: im[2] })
            continue
        }
        text.push(ln)
    }
    if (code) out.push({ type: "code", lang: code.lang, code: code.lines.join("\n"), open: true })
    if (text.length && text.join("").trim() !== "") out.push({ type: "text", md: text.join("\n") })
    return out.filter(b => b.type !== "text" || b.md.trim() !== "")
}

// ── inline ───────────────────────────────────────────────────────────────
function inline(s, c) {
    const keep = []
    const hold = h => "\u0000" + (keep.push(h) - 1) + "\u0000"
    // Sealed (the conversation has read something local, chat.py): a web or
    // mail link is shown as text, not as something to click. Its URL was
    // written by a model holding private text, and opening it would send
    // whatever it spells out (2026-11-03). File links stay: they open here.
    const link = (href, label) => c.sealed && !/^(file:|reveal:)/.test(href)
        ? hold('<span style="color:' + c.dim + '">' + label + (label.indexOf(esc(href)) < 0 ? " (" + esc(href) + ")" : "") + "</span>")
        : hold('<a href="' + esc(href) + '" style="color:' + c.link + '; text-decoration:none">' + label + "</a>")

    // Files chat.py found to exist, keyed by how the reply wrote them: the
    // name opens it in its default app, and the folder glyph after it shows
    // it in the file browser — offered every time (Ahaan, 2026-10-20).
    const files = c.files || {}
    const fileLink = (tok, label) => {
        const f = files[tok]
        return hold('<a href="file://' + esc(encodeURI(f.path)) + '" style="color:' + c.link +
                    '; text-decoration:none">' + label + '</a>&nbsp;<a href="reveal:' + esc(encodeURIComponent(f.path)) +
                    '" style="color:' + c.dim + '; text-decoration:none">' + "󰝰" + "</a>&#8201;")
        // ^ a thin space after the glyph: a ":" straight after it touched it
    }

    // Code first, so nothing inside it is read as Markdown.
    s = s.replace(/`([^`]+)`/g, (_, t) => {
        // A code span that names a real file takes the link colour, so it
        // reads as something to click and not just as code.
        const span = '<span style="font-family:monospace; background-color:' + c.codeBg +
                     '; color:' + (files[t] ? c.link : c.codeFg) + '">&nbsp;' + esc(t) + "&nbsp;</span>"
        return files[t] ? fileLink(t, span) : hold(span)
    })
    s = s.replace(IMAGE, (_, t, u) => link(u, "󰋩&nbsp;" + esc(t || "image")))
    s = s.replace(/\[([^\]]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g, (_, t, u) => link(u, esc(t)))
    // Longest first, so ~/a/b.txt is not taken as ~/a plus the rest.
    for (const tok of Object.keys(files).sort((a, b) => b.length - a.length)) {
        const q = tok.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
        s = s.replace(new RegExp("(^|[^\\w/~.@+-])" + q + "(?![\\w/@+-])", "g"), (_, pre) => pre + fileLink(tok, esc(tok)))
    }
    s = s.replace(/<(https?:\/\/[^>\s]+)>/g, (_, u) => link(u, esc(u)))
    s = s.replace(/\bhttps?:\/\/[^\s<>()]+[^\s<>().,;:!?'"]/g, u => link(u, esc(u)))
    s = s.replace(/[\w.+-]+@[\w-]+(\.[\w-]+)+/g, e => link("mailto:" + e, esc(e)))
    s = esc(s)
    s = s.replace(/\*\*(?=\S)(.+?)\*\*/g, '<span style="font-weight:600; color:' + c.strong + '">$1</span>')
    s = s.replace(/(^|[^\w])__(?=\S)(.+?)__(?!\w)/g, '$1<span style="font-weight:600; color:' + c.strong + '">$2</span>')
    s = s.replace(/(^|[^*\w])\*(?=\S)([^*]+?)\*(?!\w)/g, "$1<i>$2</i>")
    s = s.replace(/(^|[^\w])_(?=\S)([^_]+?)_(?!\w)/g, "$1<i>$2</i>")
    s = s.replace(/~~(?=\S)(.+?)~~/g, "<s>$1</s>")
    // Until none are left: a link's label can hold a code span — [the `re`
    // module](…) — whose placeholder is inside the link's own held HTML.
    while (/\u0000\d+\u0000/.test(s)) s = s.replace(/\u0000(\d+)\u0000/g, (_, i) => keep[+i])
    return s
}

// ── blocks of prose ──────────────────────────────────────────────────────
function html(md, c) {
    const lines = String(md).split("\n")
    const out = []
    let para = []
    let lists = []          // open lists: { tag, indent }
    const p = (body, style) => '<p style="margin-top:0; margin-bottom:9px;' + (style || "") + '">' + body + "</p>"
    const flush = () => { if (para.length) { out.push(p(inline(para.join(" "), c))); para = [] } }
    const closeLists = (to) => { while (lists.length > to) out.push("</" + lists.pop().tag + ">") }

    for (let i = 0; i < lines.length; i++) {
        const ln = lines[i]
        if (ln.trim() === "") { flush(); if (!/^\s*([-*+]|\d+[.)])\s/.test(lines[i + 1] || "")) closeLists(0); continue }

        let m = /^(#{1,6})\s+(.*?)\s*#*\s*$/.exec(ln)
        if (m) {
            flush(); closeLists(0)
            const size = [0, 1.3, 1.18, 1.08, 1, 1, 1][m[1].length]
            out.push(p(inline(m[2], c), " margin-top:6px; font-weight:600; font-size:" + Math.round(c.size * size) +
                       "px; color:" + c.strong))
            continue
        }
        if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(ln)) {
            flush(); closeLists(0)
            out.push('<table width="100%" cellspacing="0" cellpadding="0" style="margin-top:4px; margin-bottom:12px">' +
                     '<tr><td style="background-color:' + c.rule + '; font-size:1px">&nbsp;</td></tr></table>')
            continue
        }
        m = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/.exec(ln)
        if (m) {
            flush()
            const indent = m[1].length, tag = /\d/.test(m[2]) ? "ol" : "ul"
            while (lists.length && indent < lists[lists.length - 1].indent) out.push("</" + lists.pop().tag + ">")
            // A numbered list straight after a bulleted one is a new list.
            if (lists.length && indent === lists[lists.length - 1].indent && tag !== lists[lists.length - 1].tag)
                out.push("</" + lists.pop().tag + ">")
            if (!lists.length || indent > lists[lists.length - 1].indent) {
                // Qt nests by -qt-list-indent, not by where the tag sits.
                out.push("<" + tag + ' style="margin-top:0; margin-bottom:6px; -qt-list-indent:' + (lists.length + 1) + '">')
                lists.push({ tag: tag, indent: indent })
            }
            out.push('<li style="margin-bottom:3px">' + inline(m[3], c) + "</li>")
            continue
        }
        if (/^\s*>/.test(ln)) {
            flush(); closeLists(0)
            const q = []
            while (i < lines.length && /^\s*>/.test(lines[i])) q.push(lines[i++].replace(/^\s*>\s?/, ""))
            i--
            out.push('<table cellspacing="0" cellpadding="0" style="margin-bottom:9px"><tr>' +
                     '<td width="3" style="background-color:' + c.rule + '"></td><td width="10"></td>' +
                     '<td style="color:' + c.dim + '">' + inline(q.join(" "), c) + "</td></tr></table>")
            continue
        }
        if (/^\s*\|.*\|\s*$/.test(ln) && /^\s*\|?[\s:|-]+\|?\s*$/.test(lines[i + 1] || "") && /-/.test(lines[i + 1] || "")) {
            flush(); closeLists(0)
            const cells = r => r.trim().replace(/^\||\|$/g, "").split("|").map(x => x.trim())
            const head = cells(ln)
            i += 2
            let t = '<table cellspacing="0" cellpadding="6" style="margin-bottom:10px; border-collapse:collapse">'
            // Qt draws no cell borders from CSS; the header gets a shade instead.
            t += "<tr>" + head.map(h => '<td bgcolor="' + c.codeBg + '" style="font-weight:600; color:' + c.strong + '">' +
                                        inline(h, c) + "</td>").join("") + "</tr>"
            while (i < lines.length && /^\s*\|.*\|\s*$/.test(lines[i]))
                t += "<tr>" + cells(lines[i++]).map(x => "<td>" + inline(x, c) + "</td>").join("") + "</tr>"
            i--
            out.push(t + "</table>")
            continue
        }
        if (lists.length && /^\s+\S/.test(ln) && !para.length) {
            // A wrapped list item's next line: part of the item above.
            const last = out.length - 1
            out[last] = out[last].replace(/<\/li>$/, " " + inline(ln.trim(), c) + "</li>")
            continue
        }
        closeLists(0)
        para.push(ln.trim())
    }
    flush(); closeLists(0)
    // The last block's bottom margin would pad the card for nothing.
    return out.join("").replace(/margin-bottom:9px;([^>]*>)(?![\s\S]*margin-bottom:9px)/, "margin-bottom:0;$1")
}

// ── code ─────────────────────────────────────────────────────────────────
const KEYWORDS = new Set(("if else elif fi then do done while for in case esac function return break continue " +
    "def class import from as with try except finally raise yield lambda pass global nonlocal assert del not and or is " +
    "None True False null undefined true false let const var new this super extends implements interface type enum " +
    "public private protected static final abstract async await switch default throw throws catch typeof instanceof " +
    "void struct union impl fn mut pub use mod match loop where trait crate self Self package func go defer select " +
    "chan map range local end require export readonly property signal pragma echo unset declare source").split(" "))
const HASH_COMMENT = new Set(["", "sh", "bash", "zsh", "shell", "console", "py", "python", "rb", "ruby", "yaml",
                              "yml", "toml", "conf", "ini", "make", "makefile", "dockerfile", "r", "perl", "nix",
                              "fish", "text", "txt", "cmake"])
const DASH_COMMENT = new Set(["lua", "sql", "haskell", "hs"])

function highlight(code, lang, c) {
    lang = String(lang || "").toLowerCase()
    const span = (col, t, extra) => '<span style="color:' + col + (extra || "") + '">' + esc(t) + "</span>"
    const parts = []
    const shell = ["", "sh", "bash", "zsh", "shell", "console", "fish"].indexOf(lang) >= 0
    const hash = HASH_COMMENT.has(lang), dash = DASH_COMMENT.has(lang)
    const cLike = !hash && !dash
    const re = new RegExp([
        cLike ? "(\\/\\*[\\s\\S]*?(?:\\*\\/|$)|\\/\\/[^\\n]*)" : hash ? "(#(?!!)[^\\n]*)" : "(--[^\\n]*)",   // 1 comment
        '("""[\\s\\S]*?(?:"""|$)|\'\'\'[\\s\\S]*?(?:\'\'\'|$)|"(?:\\\\.|[^"\\\\\\n])*"?|\'(?:\\\\.|[^\'\\\\\\n])*\'?|`(?:\\\\.|[^`\\\\])*`?)', // 2 string
        "(\\$\\{[^}\\n]*\\}?|\\$[A-Za-z_][\\w]*|\\$[0-9@#?*!$-])",                                         // 3 variable
        "(\\b(?:0x[\\da-fA-F]+|\\d[\\d_]*(?:\\.\\d+)?(?:[eE][+-]?\\d+)?)\\b)",                             // 4 number
        "([A-Za-z_][\\w]*)(?=\\s*\\()",                                                                       // 5 call
        "([A-Za-z_][\\w-]*)",                                                                                 // 6 word
    ].join("|"), "g")
    let last = 0, m
    while ((m = re.exec(code)) !== null) {
        if (m.index > last) parts.push(span(c.punct, code.slice(last, m.index)))
        const t = m[0]
        if (m[1] !== undefined) parts.push(span(c.comment, t, "; font-style:italic"))
        else if (m[2] !== undefined) parts.push(span(c.string, t))
        else if (m[3] !== undefined) parts.push(span(shell || lang === "php" || lang === "perl" ? c.variable : c.punct, t))
        else if (m[4] !== undefined) parts.push(span(c.number, t))
        else if (m[5] !== undefined) parts.push(span(KEYWORDS.has(m[5]) ? c.keyword : c.func, t))
        else if (KEYWORDS.has(t)) parts.push(span(c.keyword, t))
        else if (/^[A-Z][a-z]/.test(t) && !shell) parts.push(span(c.type, t))
        else parts.push(span(c.plain, t))
        last = re.lastIndex
        if (t.length === 0) re.lastIndex++
    }
    if (last < code.length) parts.push(span(c.punct, code.slice(last)))
    return '<pre style="white-space:pre-wrap; margin:0">' + parts.join("") + "</pre>"
}
