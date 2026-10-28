import Foundation

/// The live preview page's script (one nonce'd inline script, never in an
/// export): it patches the page's blocks in place of a reload, and posts
/// task toggles.
///
/// `cmdmdPreview.patch(edit)` replaces, for each of `edit.runs`, `remove`
/// blocks from `at` with `blocks`, after checking that the page is
/// `edit.page` (its nonce) holding `edit.count` blocks. The HTML arrives as a
/// callAsyncJavaScript argument, never as script text, and is parsed in a
/// `<template>`, whose scripts never run (the renderer also sanitized it).
/// Only the new nodes get what the page's load passes did: highlight.js,
/// KaTeX, Pele. The first element at the top of the window keeps its place
/// when the change is above it.
enum PreviewRuntime {
    /// Before each block of the live page's `#cmdmd-root` (the script
    /// spells it with `\x3c`: a `<!--` in script text changes how the page
    /// parses the rest of the element).
    static let marker = "<!--cmdmd-->"
    static let rootOpening = "<div id=\"cmdmd-root\" style=\"display:contents\">"
    static let rootClosing = "</div>"

    /// `PreviewStyles.base`'s first and last child rules, for the blocks
    /// inside `#cmdmd-root`.
    static let rootCSS = "#cmdmd-root > :first-child { margin-top: 0; } #cmdmd-root > :last-child { margin-bottom: 0; }"

    static let script = """
    (function () {
        var page = document.currentScript.nonce;
        var version = 0;
        var root = null, marks = null;
        // The reader's element after the last patch, and where it is in
        // the document (see keepPlace).
        var place = null;
        // The DOM's own methods, never a note element's property: a <form>
        // in the note answers `form.nextSibling`, `form.matches` and the
        // like with its controls of that name or id.
        var html = document.documentElement;
        var byId = Document.prototype.getElementById, make = Document.prototype.createElement;
        var matches = Element.prototype.matches, all = Element.prototype.querySelectorAll;
        var rect = Element.prototype.getBoundingClientRect;
        var firstChild = Object.getOwnPropertyDescriptor(Node.prototype, 'firstChild').get;
        var nextSibling = Object.getOwnPropertyDescriptor(Node.prototype, 'nextSibling').get;
        function isMark(node) { return node instanceof Comment && node.data === 'cmdmd'; }
        function marksIn(parent) {
            var list = [];
            for (var node = firstChild.call(parent); node; node = nextSibling.call(node)) if (isMark(node)) list.push(node);
            return list;
        }
        function within(node, selector) {
            var list = Array.prototype.slice.call(all.call(node, selector));
            if (matches.call(node, selector)) list.unshift(node);
            return list;
        }
        function diagramsIn(nodes) {
            return nodes.reduce(function (list, node) {
                return node instanceof Element ? list.concat(within(node, '.cmdmd-diagram')) : list;
            }, []);
        }
        function enhance(nodes) {
            nodes.forEach(function (node) {
                if (!(node instanceof Element)) return;
                if (typeof hljs !== 'undefined') within(node, '\(MarkdownRenderer.highlightTargets)').forEach(function (el) {
                    if (!el.classList.contains('language-mermaid')) hljs.highlightElement(el);
                });
                if (typeof renderMathInElement !== 'undefined') within(node, '.cmdmd-math').forEach(function (el) {
                    renderMathInElement(el, \(MarkdownRenderer.katexOptions));
                });
            });
        }
        // The first element at or below the top of the window, unless a run
        // replaces it: where the reader is, kept in place below the changes.
        function anchorOutside(runs) {
            var children = root.children, low = 0, high = children.length;
            while (low < high) {
                var middle = (low + high) >> 1;
                if (rect.call(children[middle]).bottom > 0) high = middle; else low = middle + 1;
            }
            var el = children[low];
            if (!el || runs.some(function (run) { return run.old.indexOf(el) >= 0; })) return null;
            return {el: el, top: rect.call(el).top};
        }
        // An image a patch brings has no size until it loads. Where WebKit
        // has no scroll anchoring of its own (macOS 14's), one loading
        // above the window pushed the reader down: the page scrolls by what
        // the reader's element moved in the document, when the image starts
        // above the window.
        function anchorsNatively() {
            return CSS.supports('overflow-anchor', 'auto') && getComputedStyle(html).overflowAnchor !== 'none'
                && getComputedStyle(document.body).overflowAnchor !== 'none';
        }
        function keepPlace(img) {
            img.addEventListener('load', function () {
                if (!place || !place.el.isConnected || anchorsNatively() || rect.call(img).top >= 0) return;
                var top = rect.call(place.el).top + window.scrollY;
                if (Math.abs(top - place.top) >= 0.5) window.scrollBy(0, top - place.top);
                place.top = top;
            }, {once: true});
        }
        // Each run replaces `remove` blocks from `at` with `blocks`; the
        // runs come in page order, apart. All are parsed and checked
        // before the page changes.
        function patch(edit) {
            root = root || byId.call(document, 'cmdmd-root');
            if (edit.page !== page || !root) return {done: false};
            marks = marks || marksIn(root);
            if (marks.length !== edit.count) return {done: false};
            var runs = [], from = 0;
            for (var i = 0; i < edit.runs.length; i++) {
                var run = edit.runs[i];
                if (run.at < from || run.at + run.remove > marks.length) return {done: false};
                // At least one block apart: a run ends before the next one's first marker.
                from = run.at + run.remove + 1;
                var template = make.call(document, 'template');
                template.innerHTML = run.blocks.map(function (block) { return '\\x3c!--cmdmd--\\x3e' + block; }).join('');
                var fresh = template.content, added = marksIn(fresh);
                if (added.length !== run.blocks.length || (added.length && fresh.firstChild !== added[0])) return {done: false};
                var end = marks[run.at + run.remove] || null, old = [];
                for (var node = marks[run.at] || null; node && node !== end; node = nextSibling.call(node)) old.push(node);
                runs.push({at: run.at, remove: run.remove, fresh: fresh, added: added, end: end, old: old,
                           nodes: Array.prototype.slice.call(fresh.childNodes)});
            }

            var anchor = anchorOutside(runs);
            var removed = [], brought = [];
            // From the last run back, so the earlier runs' markers stay put.
            for (var r = runs.length - 1; r >= 0; r--) {
                var change = runs[r];
                // Children of the root, between two of its markers.
                change.old.forEach(function (node) { root.removeChild(node); });
                root.insertBefore(change.fresh, change.end);
                marks.splice.apply(marks, [change.at, change.remove].concat(change.added));
                removed = change.old.concat(removed);
                brought = change.nodes.concat(brought);
            }
            version += 1;
            if (edit.lang) html.lang = edit.lang; else html.removeAttribute('lang');
            // The diagram loader's (on pages with diagrams): drop the drawings
            // removed, draw the ones brought.
            var diagrams = window.cmdmdPreview.diagrams;
            if (diagrams) diagrams.drop(diagramsIn(removed));
            enhance(brought);
            if (diagrams) diagrams.draw(diagramsIn(brought));
            if (anchor) {
                var shift = rect.call(anchor.el).top - anchor.top;
                if (Math.abs(shift) >= 0.5) window.scrollBy(0, shift);
            }
            place = anchor ? {el: anchor.el, top: rect.call(anchor.el).top + window.scrollY} : null;
            brought.forEach(function (node) {
                if (node instanceof Element) within(node, 'img').forEach(function (img) { if (!img.complete) keepPlace(img); });
            });
            return {done: true, version: version};
        }
        // The renderer's boxes (the sanitizer strips `data-task` from a
        // note's own HTML).
        function isTaskBox(node) {
            return node instanceof HTMLInputElement && node.type === 'checkbox' && node.hasAttribute('data-task');
        }
        // A task flips from a click on its box, or the keyboard or VoiceOver
        // on it, never through a label: a note's <label> wrapped around a
        // list (a whole-window one, even) turned a click anywhere into a
        // click on the box it holds. The label's click is still being
        // handled when it hands the box its own.
        var outerClick = null;
        document.addEventListener('click', function (event) {
            if (!isTaskBox(event.target)) {
                outerClick = event;
                setTimeout(function () { if (outerClick === event) outerClick = null; }, 0);
            } else if (outerClick) {
                event.preventDefault();
            }
        }, true);
        // One listener for every box, patched in or not. A toggle the app
        // refuses (the box's line changed, another page is up) puts the box
        // back: the note didn't change, so a patch wouldn't.
        document.addEventListener('change', function (event) {
            var box = event.target;
            if (!isTaskBox(box)) return;
            var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.cmdmd;
            if (!handler) return;
            var checked = box.checked;
            handler.postMessage({type: 'toggleTask', task: Number(box.getAttribute('data-task')), checked: checked, page: page, version: version})
                .then(function (toggled) {
                    if (!toggled && box.isConnected && box.checked === checked) box.checked = !checked;
                });
        });
        window.cmdmdPreview = {patch: patch};
    })();
    """
}
