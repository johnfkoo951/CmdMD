# Preview libraries

The preview loads these from inside the app (`cmdmd-lib://lib/<path>`, served by
`PreviewLibrarySchemeHandler`), never from the network. HTML export and Copy as HTML
link pinned copies on jsDelivr instead (and carry cmds-pele's small bootstrap and theme
inline), so an exported file works outside the app.

| Library | Version | License | Shipped as | Source |
|---|---|---|---|---|
| KaTeX | 0.16.47 | MIT | `katex/` (js, css, `contrib/` mhchem + auto-render, woff2 fonts only) | https://github.com/KaTeX/KaTeX, files from https://cdn.jsdelivr.net/npm/katex@0.16.47/dist/ |
| Pele (cmds-pele) | see `cmds-pele/cmds-pele.version.json` | MIT | `cmds-pele/`: Pele's `pele.global.js` (npm's bytes), the CMDS bootstrap and theme, synced by cmds-pele's `bin/pele-sync.py` | https://github.com/obsidianmd/pele, files from https://www.npmjs.com/package/pele |
| highlight.js | 11.11.1 | BSD-3-Clause | not copied: served from Highlightr's resource bundle (`Highlightr_Highlightr.bundle`) as `highlightr/` | https://github.com/highlightjs/highlight.js, via https://github.com/raspu/Highlightr |
| highlight.js themes Nord, Monokai | 11.11.1 | BSD-3-Clause | `highlight-themes/` (`nord.min.css`, `monokai.min.css`): Highlightr's bundle has only the base16 themes of these names | files from https://cdn.jsdelivr.net/npm/@highlightjs/cdn-assets@11.11.1/styles/ |

Full texts: `katex/LICENSE`, `cmds-pele/LICENSE-pele.txt`, and highlight.js below (the
Highlightr bundle leaves its LICENSE out).

## highlight.js

```
BSD 3-Clause License

Copyright (c) 2006, Ivan Sagalaev.
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this
  list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.

* Neither the name of the copyright holder nor the names of its
  contributors may be used to endorse or promote products derived from
  this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```
