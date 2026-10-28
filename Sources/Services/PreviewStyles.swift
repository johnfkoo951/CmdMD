import Foundation

// MARK: - Preview stylesheet
//
// One shared, token-driven base stylesheet + a small token block per theme.
// Every component (callouts, code, tables, tags, mermaid) reads the theme's
// tokens instead of its own `@media (prefers-color-scheme)` branch, so a
// theme that is always dark (Dark Pro) gets dark components even when macOS
// is in Light mode, and each theme's typography is actually visible.
//
// Token names keep the old `--bg-primary`/`--text-primary`/… spellings so
// users' custom CSS keeps working, and `PreviewTheme.backgroundColor(forDark:)`
// must still mirror each theme's `--bg-primary`.

enum PreviewStyles {

    /// Drops comments, indentation and blank lines once per process, so the
    /// per-render page carries only the declarations.
    static func compact(_ css: String) -> String {
        var out = css.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\s*\n\s*"#, with: "\n", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\s*([{};,])\s*"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"([a-z-]):\s+"#, with: "$1:", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Semantic colors shared by the light variant of every theme: callout
    /// hues, highlight, and a GitHub-light syntax palette (themes override).
    static let semanticLight = """
        --scheme: light;
        --c-blue: #0969da; --c-cyan: #0a8f8c; --c-green: #1a7f37; --c-orange: #bc4c00;
        --c-red: #cf222e; --c-purple: #8250df; --c-grey: #6e7781;
        --mark-bg: rgba(255, 212, 0, 0.38);
        --hl-comment: #59636e; --hl-keyword: #cf222e; --hl-string: #0a3069; --hl-number: #0550ae;
        --hl-title: #8250df; --hl-type: #953800; --hl-attr: #0550ae; --hl-meta: #6e7781;
        --hl-addition: #116329; --hl-deletion: #82071e;
        """

    static let semanticDark = """
        --scheme: dark;
        --c-blue: #4493f8; --c-cyan: #39c5cf; --c-green: #3fb950; --c-orange: #e3863b;
        --c-red: #f85149; --c-purple: #ab7df8; --c-grey: #8b949e;
        --mark-bg: rgba(255, 212, 0, 0.26);
        --hl-comment: #8b949e; --hl-keyword: #ff7b72; --hl-string: #a5d6ff; --hl-number: #79c0ff;
        --hl-title: #d2a8ff; --hl-type: #ffa657; --hl-attr: #79c0ff; --hl-meta: #8b949e;
        --hl-addition: #aff5b4; --hl-deletion: #ffdcd7;
        """

    /// Light + dark token blocks for a theme. `alwaysDark` themes get their
    /// dark tokens unconditionally and `color-scheme: dark` (native controls,
    /// scrollbars) regardless of the system appearance.
    static func tokens(light: String, dark: String, alwaysDark: Bool = false) -> String {
        if alwaysDark {
            return ":root { color-scheme: dark; \(semanticDark) \(dark) }"
        }
        return """
        :root { \(semanticLight) \(light) }
        @media (prefers-color-scheme: dark) { :root { \(semanticDark) \(dark) } }
        """
    }

    /// Layout, typography and every component, driven by tokens. Structural
    /// values (`--fs`, `--lh`, `--measure`, `--h1`…) have defaults here and are
    /// overridden per theme, then per user (Settings → Preview).
    static let base = compact(baseSource)
    private static let baseSource = """
        :root {
            --font-body: -apple-system, BlinkMacSystemFont, 'Apple SD Gothic Neo', sans-serif;
            --font-heading: var(--font-body);
            --font-mono: ui-monospace, 'SF Mono', SFMono-Regular, Menlo, monospace;
            --fs: 16px; --lh: 1.7; --measure: 720px; --pad: clamp(16px, 5vw, 44px);
            --h1: 2; --h2: 1.5; --h3: 1.25; --h4: 1.1; --h5: 1; --h6: 0.9; --hs: 1;
            --heading-weight: 700; --heading-lh: 1.3; --heading-tracking: -0.012em;
            --heading-mt: calc(var(--fs) * 2); --heading-mb: calc(var(--fs) * 0.7);
            --radius: 8px; --space: 1em;
            --row-alt: transparent; --th-bg: var(--bg-secondary); --th-fg: var(--text-primary);
            --marker: var(--text-secondary); --quote-bar: var(--border-color);
            --tag-bg: var(--bg-secondary); --tag-color: var(--text-secondary);
            --accent: var(--link-color); --accent-soft: var(--bg-secondary);
            --check-light: url("data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 12 12'><path d='M2.5 6.2 5 8.6l4.6-5.2' fill='none' stroke='white' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'/></svg>");
            --check-dark: url("data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 12 12'><path d='M2.5 6.2 5 8.6l4.6-5.2' fill='none' stroke='black' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'/></svg>");
            --check-mark: var(--check-light);
        }
        html { -webkit-text-size-adjust: 100%; }
        body {
            margin: 0 auto; max-width: var(--measure); padding: var(--pad);
            font-family: var(--font-body); font-size: var(--fs); line-height: var(--lh);
            color: var(--text-primary); background: var(--bg-primary);
            font-kerning: normal; text-rendering: optimizeLegibility;
        }
        /* Hangul sets taller than Latin at the same size (no descender gap
           to borrow), so Korean pages get a slightly looser leading — unless
           the user set one (Settings writes --lh-ko too). */
        html:lang(ko) body { line-height: var(--lh-ko, calc(var(--lh) + 0.06)); }
        ::selection { background: color-mix(in srgb, var(--accent) 24%, transparent); }
        .markdown-body > :first-child { margin-top: 0; }
        .markdown-body > :last-child { margin-bottom: 0; }

        p, ul, ol, dl, blockquote, pre, table, .table-scroll, .callout, .cmdmd-diagram, figure, details, video, iframe { margin: 0 0 var(--space); }

        h1, h2, h3, h4, h5, h6 {
            font-family: var(--font-heading); font-weight: var(--heading-weight);
            line-height: var(--heading-lh); letter-spacing: var(--heading-tracking);
            color: var(--heading-color, var(--text-primary));
            margin: var(--heading-mt) 0 var(--heading-mb);
            text-wrap: balance; scroll-margin-top: 1em;
        }
        h1 { font-size: calc(var(--h1) * var(--hs) * 1em); }
        h2 { font-size: calc(var(--h2) * var(--hs) * 1em); }
        h3 { font-size: calc(var(--h3) * var(--hs) * 1em); }
        h4 { font-size: calc(var(--h4) * var(--hs) * 1em); }
        h5 { font-size: calc(var(--h5) * var(--hs) * 1em); }
        h6 { font-size: calc(var(--h6) * var(--hs) * 1em); color: var(--text-secondary); }
        h1 + h2, h2 + h3, h3 + h4 { margin-top: calc(var(--heading-mt) * 0.6); }

        a { color: var(--link-color); text-decoration: none; text-underline-offset: 0.2em; text-decoration-thickness: 1px; }
        a:hover { text-decoration: underline; }
        a:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; border-radius: 3px; }
        strong { font-weight: 650; }

        ul, ol { padding-left: 1.6em; }
        /* Item text is always in a <p>: tight lists sit flush, `.loose` ones
           (blank lines between items) breathe; blocks inside one item
           (a second paragraph, code, a quote) keep a half-line gap. */
        li > p { margin: 0; }
        li + li { margin-top: 0.25em; }
        .loose > li + li { margin-top: 0.75em; }
        li > * + * { margin-top: 0.5em; }
        li > ul, li > ol { margin: 0.25em 0 0; }
        li > :last-child { margin-bottom: 0; }
        li::marker { color: var(--marker); }
        ol > li::marker { font-variant-numeric: tabular-nums; }
        ul ul { list-style-type: circle; }
        ul ul ul { list-style-type: square; }
        /* Task items: the box hangs in the bullet's gutter on the text's first
           line, so task text lines up with plain items; done items recede. */
        .task-list-item { list-style: none; }
        .task-list-item > p > input[type="checkbox"]:first-child { margin: 0 0.45em 0 calc(-14px - 0.45em); }
        .task-list-item > p:first-child:has(> input:checked) { color: var(--text-secondary); }
        /* Drawn, not native: the same rounded box in every theme and OS
           release, filled with the theme accent when done. */
        input[type="checkbox"] {
            -webkit-appearance: none; appearance: none; font: inherit; margin: 0 0.4em 0 0; width: 14px; height: 14px;
            vertical-align: -2px; border: 1.5px solid var(--text-secondary);
            border-radius: 4px; background: var(--bg-primary) center / 10px no-repeat; cursor: pointer;
        }
        input[type="checkbox"]:checked { background-color: var(--accent); border-color: var(--accent); background-image: var(--check-mark); }
        input[type="checkbox"]:disabled { cursor: default; }
        input[type="checkbox"]:focus-visible { outline: 2px solid color-mix(in srgb, var(--accent) 55%, transparent); outline-offset: 1px; }

        blockquote { padding: 0.1em 0 0.1em 1em; border-left: 3px solid var(--quote-bar); color: var(--text-secondary); }
        blockquote > :last-child { margin-bottom: 0; }
        /* Hangul has no italic: themes' decorative italic quotes would be a synthetic slant. */
        html:lang(ko) :is(blockquote, h3, .hljs-comment, .hljs-quote, .embedded-note) { font-style: normal; }

        code, kbd, samp, pre { font-family: var(--font-mono); }
        code { font-size: 0.875em; padding: 0.15em 0.4em; border-radius: 5px; background: var(--code-bg); color: var(--code-fg, inherit); }
        pre {
            padding: 14px 16px; background: var(--code-bg); border: 1px solid var(--code-border, var(--border-color));
            border-radius: var(--radius); overflow-x: auto; font-size: 0.85em; line-height: 1.6; tab-size: 4;
        }
        pre code {
            display: block; padding: 0; margin: 0; background: none; border: 0; border-radius: 0;
            font-size: inherit; color: var(--code-block-fg, var(--text-primary)); white-space: pre; overflow: visible;
        }
        kbd {
            font-size: 0.8em; line-height: 1; padding: 0.2em 0.45em; white-space: nowrap;
            border: 1px solid var(--border-color); border-bottom-width: 2px; border-radius: 5px;
            background: var(--bg-secondary); color: var(--text-primary);
        }

        table { border-collapse: collapse; font-variant-numeric: tabular-nums; }
        th, td { padding: 0.55em 0.9em; border: 1px solid var(--border-color); text-align: start; vertical-align: top; }
        th { background: var(--th-bg); color: var(--th-fg); font-weight: 600; overflow-wrap: normal; }
        /* A long URL or identifier wraps inside its cell; the frame scrolls
           sideways when the columns still don't fit. */
        td { overflow-wrap: anywhere; min-width: 6em; }
        th[align="left"], td[align="left"] { text-align: left; }
        th[align="center"], td[align="center"] { text-align: center; }
        th[align="right"], td[align="right"] { text-align: right; }
        .table-scroll { overflow-x: auto; border: 1px solid var(--border-color); border-radius: var(--radius); }
        .table-scroll > table { margin: 0; width: 100%; }
        .table-scroll th, .table-scroll td { border-width: 1px 0 0 1px; }
        .table-scroll thead th { border-top: 0; }
        .table-scroll th:first-child, .table-scroll td:first-child { border-left: 0; }
        .table-scroll tbody tr:nth-child(even) { background: var(--row-alt); }

        img { max-width: 100%; height: auto; border-radius: var(--img-radius, 6px); }
        hr { height: 0; border: 0; border-top: 1px solid var(--border-color); margin: 2em 0; }

        mark { background: var(--mark-bg); color: inherit; padding: 0 0.15em; border-radius: 3px; }
        .tag { background: var(--tag-bg); color: var(--tag-color); padding: 0.1em 0.55em; border-radius: 999px; font-size: 0.85em; font-weight: 500; white-space: nowrap; }
        .wiki-link { color: var(--link-color); text-decoration: underline dotted; text-decoration-color: color-mix(in srgb, currentColor 55%, transparent); text-underline-offset: 0.22em; }
        .wiki-link:hover { text-decoration-style: solid; }
        .embedded-image { max-width: 100%; border-radius: var(--radius); }
        .embedded-note { background: var(--bg-secondary); padding: 2px 6px; border-radius: 4px; font-style: italic; }


        @media print {
            body { max-width: none; padding: 0; }
            pre, .markdown-body pre code { white-space: pre-wrap; overflow-wrap: anywhere; overflow: visible; }
            .table-scroll { overflow: visible; }
            h1, h2, h3, h4, h5, h6 { break-after: avoid; }
            pre, blockquote, .callout, img, .cmdmd-diagram, tr { break-inside: avoid; }
        }
        """

    /// Syntax colors from the theme's `--hl-*` tokens — replaces the CDN
    /// highlight.js stylesheet for the default ("github"/auto) choice.
    static let syntaxPalette = compact(syntaxPaletteSource)
    private static let syntaxPaletteSource = """
        .hljs-comment, .hljs-quote { color: var(--hl-comment); font-style: italic; }
        .hljs-keyword, .hljs-selector-tag, .hljs-doctag, .hljs-template-tag, .hljs-meta .hljs-keyword { color: var(--hl-keyword); }
        .hljs-string, .hljs-regexp, .hljs-meta .hljs-string, .hljs-char.escape_ { color: var(--hl-string); }
        .hljs-number, .hljs-literal, .hljs-symbol, .hljs-bullet, .hljs-variable.constant_ { color: var(--hl-number); }
        .hljs-title, .hljs-title.function_, .hljs-section { color: var(--hl-title); }
        .hljs-type, .hljs-built_in, .hljs-title.class_, .hljs-title.class_.inherited__ { color: var(--hl-type); }
        .hljs-attr, .hljs-attribute, .hljs-property, .hljs-name, .hljs-tag, .hljs-selector-id, .hljs-selector-class, .hljs-selector-attr, .hljs-variable, .hljs-template-variable, .hljs-link { color: var(--hl-attr); }
        .hljs-meta { color: var(--hl-meta); }
        .hljs-addition { color: var(--hl-addition); background: color-mix(in srgb, var(--hl-addition) 12%, transparent); }
        .hljs-deletion { color: var(--hl-deletion); background: color-mix(in srgb, var(--hl-deletion) 12%, transparent); }
        .hljs-emphasis { font-style: italic; }
        .hljs-strong { font-weight: 700; }
        .hljs-section { font-weight: 700; }
        """

    /// KaTeX's 1.21em default reads large beside 16px body text; long
    /// display math scrolls instead of widening the page. Math pages only.
    static let math = compact("""
        .markdown-body .katex { font-size: 1.1em; }
        .markdown-body .katex-display { overflow-x: auto; overflow-y: hidden; padding: 0.2em 0; }
        @media print { .katex-display { break-inside: avoid; } }
        """)

    /// Pele's --cp-* contract (cmds-pele "테마 계약"), set on the diagram's
    /// container so the mounted `.cmds-pele` inherits it. Every theme draws
    /// diagrams the way the main vault does. The page fills the roles
    /// Obsidian's app.css gives the vault theme: nodes on the secondary
    /// background with the border color, lines and labels in the text color,
    /// and the theme's fonts. The palette (accent, series, critical, key and
    /// aux nodes) is left to cmds-pele, the same tokens.json the vault's
    /// cmds-pele-vault plugin is built from, so pele-sync keeps the two equal.
    static let diagramTokens = "--cp-bg: var(--bg-primary); --cp-fg: var(--text-primary); --cp-muted: var(--text-secondary); --cp-line: var(--text-primary); --cp-surface: var(--bg-secondary); --cp-surface-alt: var(--bg-secondary); --cp-border: var(--border-color); --cp-font: var(--font-body); --cp-font-mono: var(--font-mono); --cp-caption: var(--text-secondary);"

    /// Diagrams sit in the text, unframed like the vault's. Until Pele
    /// settles the source keeps its space but isn't shown; a diagram wider
    /// than the column (Pele doesn't always keep maxWidth) scrolls in place.
    /// Diagram pages only.
    static let diagram = compact("""
        .cmdmd-diagram { overflow-x: auto; text-align: center; \(diagramTokens) }
        .cmdmd-diagram .cmds-figure { margin: 0; }
        .cmdmd-diagram > pre { text-align: left; }
        .cmdmd-diagrams-pending .cmdmd-diagram:not(.cmdmd-diagram-failed) > pre { visibility: hidden; min-height: 8em; }
        .cmdmd-diagram-error { margin: -0.4em 0 var(--space); font-size: 0.85em; color: var(--text-secondary); text-align: left; }
        .cmdmd-diagram-caption { margin: calc(0.1em - var(--space)) 0 calc(var(--space) * 1.4); font-size: 0.875em; line-height: 1.5; text-align: center; color: var(--text-secondary); break-before: avoid; }
        .cmdmd-diagram-caption em { font-style: normal; }
        """)

    /// cmds-pele's `data-cp-theme`: which half of its palette (the vault's
    /// light green or dark pink) to use. Dark Pro is dark in either appearance.
    static func diagramScheme(for theme: PreviewTheme) -> String {
        theme == .darkPro ? "dark" : "auto"
    }

    /// A named highlight.js theme paints `.hljs` with its own background:
    /// that block becomes the one box, edge to edge (no box in a box).
    static let namedCodeThemeBox = compact("""
        .markdown-body pre:has(> code.hljs) { padding: 0; border: 0; background: none; }
        .markdown-body pre > code.hljs { padding: 14px 16px; border-radius: var(--radius); }
        """)

    // MARK: Callouts

    private static func icon(_ shapes: String) -> String {
        "url(\"data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='black' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'>\(shapes)</svg>\")"
    }

    /// (types, hue token, icon) — Obsidian's type families and colors.
    private static let calloutFamilies: [(types: [String], hue: String, icon: String)] = [
        (["note"], "blue", icon("<path d='M17 3a2.85 2.85 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5Z'/><path d='m15 5 4 4'/>")),
        (["abstract", "summary", "tldr"], "cyan", icon("<rect x='8' y='2' width='8' height='4' rx='1'/><path d='M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2M12 11h4M12 16h4M8 11h.01M8 16h.01'/>")),
        (["info"], "blue", icon("<circle cx='12' cy='12' r='10'/><path d='M12 16v-4M12 8h.01'/>")),
        (["todo"], "blue", icon("<circle cx='12' cy='12' r='10'/><path d='m9 12 2 2 4-4'/>")),
        (["tip", "hint", "important"], "cyan", icon("<path d='M8.5 14.5A2.5 2.5 0 0 0 11 12c0-1.38-.5-2-1-3-1.07-2.14-.22-4.05 2-6 .5 2.5 2 4.9 4 6.5 2 1.6 3 3.5 3 5.5a7 7 0 1 1-14 0c0-1.15.43-2.29 1-3a2.5 2.5 0 0 0 2.5 2.5z'/>")),
        (["success", "check", "done"], "green", icon("<path d='M20 6 9 17l-5-5'/>")),
        (["question", "help", "faq"], "orange", icon("<circle cx='12' cy='12' r='10'/><path d='M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3M12 17h.01'/>")),
        (["warning", "caution", "attention"], "orange", icon("<path d='m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3Z'/><path d='M12 9v4M12 17h.01'/>")),
        (["failure", "fail", "missing"], "red", icon("<path d='M18 6 6 18M6 6l12 12'/>")),
        (["danger", "error"], "red", icon("<path d='M13 2 3 14h9l-1 8 10-12h-9l1-8z'/>")),
        (["bug"], "red", icon("<rect x='8' y='6' width='8' height='14' rx='4'/><path d='m19 7-3 2M5 7l3 2M19 19l-3-2M5 19l3-2M20 13h-4M4 13h4M10 4l1 2M14 4l-1 2'/>")),
        (["example"], "purple", icon("<path d='M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01'/>")),
        (["quote", "cite"], "grey", icon("<path d='M3 21c3 0 7-1 7-8V5c0-1.25-.76-2-2-2H4c-1.25 0-2 .75-2 2v6c0 1.25.75 2 2 2 1 0 1 0 1 1v1c0 1-1 2-2 2s-1 0-1 1v3c0 1 0 1 1 1z'/><path d='M15 21c3 0 7-1 7-8V5c0-1.25-.76-2-2-2h-4c-1.25 0-2 .75-2 2v6c0 1.25.75 2 2 2h.75c0 2.25.25 4-2.75 4v3c0 1 0 1 1 1z'/>"))
    ]

    private static let calloutBase = compact(calloutBaseSource)
    private static let calloutBaseSource = """
        .callout {
            --c: var(--c-blue);
            padding: 0.7em 1em; border-left: 3px solid var(--c); border-radius: 3px var(--radius) var(--radius) 3px;
            background: color-mix(in srgb, var(--c) 8%, var(--bg-primary));
        }
        .callout-header, details.callout > summary {
            display: flex; align-items: center; gap: 0.5em; font-weight: 600;
            color: color-mix(in srgb, var(--c) 65%, var(--text-primary));
        }
        .callout-icon { flex: none; width: 1.05em; height: 1.05em; overflow: hidden; text-indent: 3em; white-space: nowrap; background: color-mix(in srgb, var(--c) 85%, var(--text-primary)); -webkit-mask: var(--icon) center / contain no-repeat; mask: var(--icon) center / contain no-repeat; }
        .callout-content { margin-top: 0.35em; }
        .callout-content > :first-child { margin-top: 0; }
        .callout-content > :last-child { margin-bottom: 0; }
        details.callout > summary { cursor: pointer; list-style: none; }
        details.callout > summary::-webkit-details-marker { display: none; }
        details.callout > summary::after {
            content: ""; width: 0.45em; height: 0.45em; margin-left: 0.15em;
            border-right: 2px solid currentColor; border-bottom: 2px solid currentColor;
            transform: rotate(-45deg); transition: transform 0.15s ease; opacity: 0.7;
        }
        details.callout[open] > summary::after { transform: rotate(45deg); }
        """

    /// The callout types on a rendered page, from one memmem pass over its
    /// UTF-8 (Foundation `contains` per type cost ~1 ms each on a 500 KB note).
    static func calloutTypes(in body: String) -> Set<String> {
        var body = body
        var needle = "class=\"callout callout-"
        var types: Set<String> = []
        body.withUTF8 { h in
            needle.withUTF8 { n in
                guard let base = h.baseAddress, let nb = n.baseAddress else { return }
                var offset = 0
                while offset < h.count, let hit = memmem(base + offset, h.count - offset, nb, n.count) {
                    var end = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(hit)) + n.count
                    let start = end
                    while end < h.count, h[end] != UInt8(ascii: "\""), end - start < 40 { end += 1 }
                    types.insert(String(decoding: h[start..<end], as: UTF8.self))
                    offset = end
                }
            }
        }
        return types
    }

    /// Callout CSS for just the types this page uses (unknown types read as
    /// a note, as in Obsidian).
    static func callouts(in body: String) -> String {
        let used = calloutTypes(in: body)
        guard !used.isEmpty else { return "" }
        var rules = [calloutBase]
        var known: Set<String> = []
        for family in calloutFamilies {
            known.formUnion(family.types)
            let present = family.types.filter(used.contains)
            guard !present.isEmpty else { continue }
            let selectors = present.map { ".callout-\($0)" }.joined(separator: ",")
            rules.append("\(selectors){--c:var(--c-\(family.hue));--icon:\(family.icon)}")
        }
        if !used.isSubset(of: known) {
            rules.append(".callout{--icon:\(calloutFamilies[0].icon)}")
        }
        return rules.joined(separator: "\n")
    }

    // MARK: Themes

    static func css(for theme: PreviewTheme) -> String {
        switch theme {
        case .cmds: return cmds
        case .github: return github
        case .obsidian: return obsidian
        case .minimal: return minimal
        case .sepia: return sepia
        case .newsprint: return newsprint
        case .darkPro: return darkPro
        }
    }

    /// CMDSPACE brand — Dark Green #134538 (light) / Pink #E985A2 (dark).
    private static let cmds = compact(themeSource_cmds)
    private static let themeSource_cmds = tokens(
        light: """
            --bg-primary: #fbfbfa; --bg-secondary: #f1f6f3; --text-primary: #1a1f1c; --text-secondary: #56605b;
            --link-color: #134538; --accent: #134538; --accent-soft: #e2eee8; --border-color: #dfe4e1;
            --code-bg: #f0f3f1; --code-fg: #0d3529; --tag-bg: #dcebe3; --tag-color: #0d3529;
            --th-bg: #134538; --th-fg: #ffffff; --row-alt: #f6f9f7; --marker: #134538; --quote-bar: #134538;
            --hl-keyword: #a3204f; --hl-string: #17694f; --hl-number: #9a4f00; --hl-title: #134538;
            --hl-type: #6a3fb0; --hl-attr: #1d5f8a; --hl-comment: #5f6a64;
            """,
        dark: """
            --bg-primary: #06080a; --bg-secondary: #0f1513; --text-primary: #e6eae8; --text-secondary: #9aa39d;
            --link-color: #E985A2; --accent: #E985A2; --accent-soft: #2a1820; --border-color: #232c28;
            --code-bg: #10161a; --code-fg: #8fe3c4; --tag-bg: #2b1922; --tag-color: #F4A4B8;
            --check-mark: var(--check-dark); --th-bg: #24141a; --th-fg: #F4A4B8; --row-alt: #0b100e; --marker: #E985A2; --quote-bar: #E985A2;
            --hl-keyword: #f28bab; --hl-string: #8fe3c4; --hl-number: #f6c177; --hl-title: #9ccfff;
            --hl-type: #c9a7ff; --hl-attr: #8cc8ff; --hl-comment: #7f8c86;
            """
    ) + """
        h1 { padding-bottom: 0.3em; border-bottom: 2px solid var(--accent); }
        h2 { padding-bottom: 0.2em; border-bottom: 1px solid var(--border-color); }
        a { font-weight: 500; text-decoration: underline; text-decoration-color: color-mix(in srgb, var(--link-color) 30%, transparent); }
        a:hover { text-decoration-color: currentColor; }
        code { border: 1px solid var(--border-color); }
        pre code { border: 0; }
        blockquote { background: var(--bg-secondary); padding: 0.6em 1em; border-left-width: 3px; border-radius: 3px var(--radius) var(--radius) 3px; }
        th code { background: rgba(0, 0, 0, 0.28); color: inherit; border-color: transparent; }
        """

    private static let github = compact(themeSource_github)
    private static let themeSource_github = tokens(
        light: """
            --font-body: -apple-system, BlinkMacSystemFont, 'Segoe UI', 'Noto Sans', Helvetica, Arial, 'Apple SD Gothic Neo', sans-serif;
            --lh: 1.6; --measure: 880px; --heading-weight: 600; --heading-tracking: 0; --radius: 6px;
            --heading-mt: 24px; --heading-mb: 16px;
            --bg-primary: #ffffff; --bg-secondary: #f6f8fa; --text-primary: #1f2328; --text-secondary: #59636e;
            --link-color: #0969da; --accent: #0969da; --accent-soft: #ddf4ff; --border-color: #d1d9e0;
            --code-bg: #f6f8fa; --row-alt: #f6f8fa; --quote-bar: #d1d9e0;
            """,
        dark: """
            --bg-primary: #0d1117; --bg-secondary: #151b23; --text-primary: #e6edf3; --text-secondary: #9198a1;
            --link-color: #4493f8; --accent: #4493f8; --accent-soft: #0c2d6b; --border-color: #3d444d;
            --code-bg: #151b23; --row-alt: #151b23; --quote-bar: #3d444d;
            """
    ) + """
        h1, h2 { padding-bottom: 0.3em; border-bottom: 1px solid var(--border-color); }
        """

    private static let obsidian = compact(themeSource_obsidian)
    private static let themeSource_obsidian = tokens(
        light: """
            --lh: 1.75; --measure: 700px; --h1: 1.875; --radius: 6px;
            --bg-primary: #ffffff; --bg-secondary: #f5f6f8; --text-primary: #2e3338; --text-secondary: #6c7489;
            --link-color: #7c3aed; --accent: #7c3aed; --accent-soft: #ede9fe; --border-color: #e3e5e8;
            --code-bg: #f5f6f8; --tag-bg: #ede9fe; --tag-color: #5b21b6; --quote-bar: #7c3aed;
            --hl-keyword: #7c3aed; --hl-string: #0f766e; --hl-number: #c2410c; --hl-title: #2563eb;
            --hl-type: #b45309; --hl-attr: #0369a1; --hl-comment: #636b80;
            """,
        dark: """
            --bg-primary: #1e1e1e; --bg-secondary: #262626; --text-primary: #dcddde; --text-secondary: #999;
            --check-mark: var(--check-dark); --link-color: #a78bfa; --accent: #a78bfa; --accent-soft: #2e2649; --border-color: #363636;
            --code-bg: #262626; --tag-bg: #2e2649; --tag-color: #c4b5fd; --quote-bar: #a78bfa;
            --hl-keyword: #c4b5fd; --hl-string: #5eead4; --hl-number: #fdba74; --hl-title: #93c5fd;
            --hl-type: #fcd34d; --hl-attr: #7dd3fc; --hl-comment: #8b93a2;
            """
    ) + """
        blockquote { font-style: italic; }
        """

    /// Apple-calm: larger type, narrow measure, Xcode syntax palette.
    private static let minimal = compact(themeSource_minimal)
    private static let themeSource_minimal = tokens(
        light: """
            --fs: 17px; --lh: 1.75; --measure: 640px; --heading-weight: 600; --radius: 12px;
            --bg-primary: #ffffff; --bg-secondary: #f5f5f7; --text-primary: #1d1d1f; --text-secondary: #6e6e73;
            --link-color: #0066cc; --accent: #0066cc; --accent-soft: #e8f1fb; --border-color: #d2d2d7;
            --code-bg: #f5f5f7; --code-border: transparent;
            --hl-keyword: #9b2393; --hl-string: #c41a16; --hl-number: #1c00cf; --hl-title: #326d74;
            --hl-type: #0b4f79; --hl-attr: #0b4f79; --hl-comment: #5d6c79;
            """,
        dark: """
            --bg-primary: #1d1d1f; --bg-secondary: #2c2c2e; --text-primary: #f5f5f7; --text-secondary: #98989d;
            --link-color: #2997ff; --accent: #2997ff; --accent-soft: #1c3350; --border-color: #424245;
            --code-bg: #2c2c2e; --code-border: transparent;
            --hl-keyword: #ff7ab2; --hl-string: #ff8170; --hl-number: #d9c97c; --hl-title: #67b7a4;
            --hl-type: #5dd8ff; --hl-attr: #5dd8ff; --hl-comment: #8e9aa6;
            """
    )

    /// Warm paper, book serif. Hangul falls to Apple SD Gothic Neo (the
    /// bundled Myungjo is too thin at body size).
    private static let sepia = compact(themeSource_sepia)
    private static let themeSource_sepia = tokens(
        light: """
            --font-body: 'Iowan Old Style', 'Palatino', Georgia, 'Apple SD Gothic Neo', serif;
            --fs: 18px; --lh: 1.75; --measure: 680px; --heading-tracking: 0; --radius: 6px;
            --bg-primary: #f4ecd8; --bg-secondary: #ece2c8; --text-primary: #3f3020; --text-secondary: #6b5a42;
            --link-color: #87501f; --accent: #87501f; --accent-soft: #ead7bf; --border-color: #d8c9a8;
            --code-bg: #ede3ca; --row-alt: #efe6cf; --quote-bar: #87501f; --mark-bg: rgba(226, 170, 40, 0.38);
            --hl-keyword: #9b2c2c; --hl-string: #4d6b16; --hl-number: #8f4700; --hl-title: #7c2d12;
            --hl-type: #6b4f9a; --hl-attr: #6a4b1f; --hl-comment: #6e5f45;
            """,
        dark: """
            --bg-primary: #2b2114; --bg-secondary: #34291a; --text-primary: #e8dcc4; --text-secondary: #b3a484;
            --check-mark: var(--check-dark); --link-color: #d99a5b; --accent: #d99a5b; --accent-soft: #4a3520; --border-color: #4a3c28;
            --code-bg: #33281a; --row-alt: #2f2517; --quote-bar: #d99a5b;
            --hl-keyword: #f0a070; --hl-string: #b5cf85; --hl-number: #e5b567; --hl-title: #f2c48d;
            --hl-type: #c6a6e0; --hl-attr: #e0c08a; --hl-comment: #a8977a;
            """
    ) + """
        a { text-decoration: underline; text-decoration-color: color-mix(in srgb, var(--link-color) 45%, transparent); }
        blockquote { font-style: italic; }
        """

    /// Editorial — serif body, tight headlines, hairline rules.
    private static let newsprint = compact(themeSource_newsprint)
    private static let themeSource_newsprint = tokens(
        light: """
            --font-body: Georgia, 'Times New Roman', 'Noto Serif KR', 'Apple SD Gothic Neo', serif;
            --fs: 17px; --lh: 1.7; --measure: 700px; --heading-lh: 1.15; --heading-tracking: -0.015em;
            --h1: 2.4; --h2: 1.6; --radius: 3px;
            --bg-primary: #ffffff; --bg-secondary: #f3f3f1; --text-primary: #1a1a1a; --text-secondary: #555555;
            --link-color: #1a1a1a; --accent: #1a1a1a; --accent-soft: #ececea; --border-color: #cfcfcf;
            --code-bg: #f3f3f1; --quote-bar: #1a1a1a; --c-grey: #555555;
            --hl-keyword: #9b1c1c; --hl-string: #2f5d50; --hl-number: #7a4a00; --hl-title: #1a1a1a;
            --hl-type: #4a3f8a; --hl-attr: #3b3b3b; --hl-comment: #666666;
            """,
        dark: """
            --bg-primary: #121212; --bg-secondary: #1d1d1d; --text-primary: #ededed; --text-secondary: #a0a0a0;
            --check-mark: var(--check-dark); --link-color: #ededed; --accent: #ededed; --accent-soft: #2a2a2a; --border-color: #3a3a3a;
            --code-bg: #1d1d1d; --quote-bar: #ededed;
            --hl-keyword: #ff8a80; --hl-string: #a8d5ba; --hl-number: #f0c674; --hl-title: #ededed;
            --hl-type: #b9a8ff; --hl-attr: #cfcfcf; --hl-comment: #8a8a8a;
            """
    ) + """
        h1 { border-bottom: 3px double var(--border-color); padding-bottom: 0.2em; }
        h3 { font-style: italic; }
        a { text-decoration: underline; text-decoration-thickness: 1px; text-underline-offset: 2px; }
        blockquote { font-style: italic; border-left-width: 4px; }
        th { text-transform: uppercase; font-size: 0.8em; letter-spacing: 0.06em; }
        """

    /// High-contrast dark for presentations — dark in every appearance.
    private static let darkPro = compact(themeSource_darkPro)
    private static let themeSource_darkPro = tokens(
        light: "",
        dark: """
            --measure: 780px; --radius: 10px; --heading-color: #ffffff; --h1: 2.1; --h2: 1.55;
            --bg-primary: #0d0d0d; --bg-secondary: #1a1a1a; --text-primary: #f2f2f2; --text-secondary: #a3a3a3;
            --check-mark: var(--check-dark); --link-color: #5eead4; --accent: #5eead4; --accent-soft: #11302b; --border-color: #2e2e2e;
            --code-bg: #161616; --code-fg: #e2e8f0; --tag-bg: #1f2937; --tag-color: #93c5fd; --quote-bar: #5eead4;
            --hl-keyword: #f472b6; --hl-string: #86efac; --hl-number: #fdba74; --hl-title: #7dd3fc;
            --hl-type: #c4b5fd; --hl-attr: #5eead4; --hl-comment: #8f8f8f;
            """,
        alwaysDark: true
    ) + """
        h2 { border-bottom: 1px solid var(--border-color); padding-bottom: 0.2em; }
        blockquote { background: var(--bg-secondary); padding: 0.6em 1em; border-radius: 3px var(--radius) var(--radius) 3px; }
        """
}
