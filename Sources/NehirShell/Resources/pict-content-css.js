'use strict';

/**
 * Shared CSS for pict-section-content. Registered by BOTH the provider (so any consumer
 * using parseMarkdown gets code-block + content styling, even without instantiating the view)
 * and the view, under one hash so it injects once. This is the lower-layer home for the
 * code-block line-number gutter layout (.pict-content-code-wrap is a flex row) that used to
 * only ship with the view -- fixing the recurring "line numbers render above the code" bug.
 */
module.exports = /*css*/`
		.pict-content {
			padding: 2em 3em;
			max-width: 900px;
			margin: 0 auto;
		}
		.pict-content-loading {
			display: flex;
			align-items: center;
			justify-content: center;
			min-height: 200px;
			color: var(--theme-color-text-muted, #8A7F72);
			font-size: 1em;
		}
		.pict-content h1 {
			font-size: 2em;
			color: var(--theme-color-text-primary, #3D3229);
			border-bottom: 1px solid var(--theme-color-border-default, #DDD6CA);
			padding-bottom: 0.3em;
			margin-top: 0;
		}
		.pict-content h2 {
			font-size: 1.5em;
			color: var(--theme-color-text-primary, #3D3229);
			border-bottom: 1px solid var(--theme-color-border-light, #EAE3D8);
			padding-bottom: 0.25em;
			margin-top: 1.5em;
		}
		.pict-content h3 {
			font-size: 1.25em;
			color: var(--theme-color-text-primary, #3D3229);
			margin-top: 1.25em;
		}
		.pict-content h4, .pict-content h5, .pict-content h6 {
			color: var(--theme-color-text-secondary, #5E5549);
			margin-top: 1em;
		}
		.pict-content p {
			line-height: 1.7;
			color: var(--theme-color-text-primary, #423D37);
			margin: 0.75em 0;
		}
		.pict-content a {
			color: var(--theme-color-brand-primary, #2E7D74);
			text-decoration: none;
		}
		.pict-content a:hover {
			text-decoration: underline;
		}
		/* ─── Code blocks ─────────────────────────────────────
		   Background, text color, line-number gutter, and every
		   syntax token route through pict-provider-theme tokens —
		   the same set pict-section-code (the live editor) uses.
		   This way the rendered-preview code blocks look identical
		   to the live editor and re-skin together when the theme
		   switches.  Previous version used the text-primary token
		   as the code background (a TEXT token used as BACKGROUND),
		   which broke in dark mode and any palette where text and
		   background-tertiary diverge.
		*/
		.pict-content pre {
			background:    var(--theme-color-background-tertiary, #F0ECE4);
			color:         var(--theme-color-text-primary,        #3D3229);
			border:        1px solid var(--theme-color-border-default, #DDD6CA);
			padding: 1.25em;
			border-radius: 6px;
			overflow-x: auto;
			line-height: 1.5;
			font-size: 0.9em;
			font-family: var(--theme-typography-family-mono, 'SFMono-Regular', 'SF Mono', 'Menlo', 'Consolas', 'Liberation Mono', 'Courier New', monospace);
		}
		/* Inline code (single backtick) — slightly differentiated
		   from block code so it doesn't disappear into prose. */
		.pict-content code {
			background:    var(--theme-color-background-secondary, #FAF8F4);
			color:         var(--theme-color-text-primary,         #3D3229);
			padding: 0.15em 0.4em;
			border-radius: 3px;
			font-size: 0.9em;
			font-family: var(--theme-typography-family-mono, 'SFMono-Regular', 'SF Mono', 'Menlo', monospace);
		}
		.pict-content-code-wrap {
			display: flex;
			flex-direction: row;
			font-family: var(--theme-typography-family-mono, 'SFMono-Regular', 'SF Mono', 'Menlo', 'Consolas', 'Liberation Mono', 'Courier New', monospace);
			font-size: 14px;
			line-height: 1.5;
			border: 1px solid var(--theme-color-border-default, #DDD6CA);
			border-radius: 6px;
			overflow: hidden;
			margin: 1em 0;
			background: var(--theme-color-background-tertiary, #F0ECE4);
		}
		.pict-content-code-wrap .pict-content-code-line-numbers {
			width: 40px;
			min-width: 40px;
			padding: 1.25em 0;
			text-align: right;
			background:    var(--theme-color-background-secondary, #FAF8F4);
			border-right:  1px solid var(--theme-color-border-default, #DDD6CA);
			color:         var(--theme-color-text-muted,           #8A7F72);
			font-family: inherit;
			font-size: inherit;
			line-height: inherit;
			user-select: none;
			pointer-events: none;
			box-sizing: border-box;
		}
		.pict-content-code-wrap .pict-content-code-line-numbers span {
			display: block;
			padding: 0 8px 0 0;
		}
		.pict-content-code-wrap pre {
			margin: 0;
			background: var(--theme-color-background-tertiary, #F0ECE4);
			color:      var(--theme-color-text-primary,        #3D3229);
			border: none;
			padding: 1.25em 1.25em 1.25em 8px;
			border-radius: 0 6px 6px 0;
			overflow-x: auto;
			line-height: 1.5;
			font-size: inherit;
			flex: 1;
			min-width: 0;
		}
		.pict-content-code-wrap pre code {
			background: none;
			padding: 0;
			color: inherit;
			font-size: inherit;
			font-family: inherit;
		}
		/* Syntax token colors — every class binds to a --theme-color-syntax-*
		   variable, the same tokens pict-section-code (the live editor) uses.
		   Each var() carries an Atom One Light hex as fallback for hosts
		   without a theme provider; themes that DO ship syntax tokens
		   (pict-default, retold-content-system, etc.) drive everything
		   coherently. */
		.pict-content-code-wrap .keyword       { color: var(--theme-color-syntax-keyword,     #A626A4); }
		.pict-content-code-wrap .string        { color: var(--theme-color-syntax-string,      #50A14F); }
		.pict-content-code-wrap .number        { color: var(--theme-color-syntax-number,      #986801); }
		.pict-content-code-wrap .comment       { color: var(--theme-color-syntax-comment,     #A0A1A7); font-style: italic; }
		.pict-content-code-wrap .operator      { color: var(--theme-color-syntax-operator,    #0184BC); }
		.pict-content-code-wrap .punctuation   { color: var(--theme-color-syntax-punctuation, #383A42); }
		.pict-content-code-wrap .function-name { color: var(--theme-color-syntax-function,    #4078F2); }
		.pict-content-code-wrap .property      { color: var(--theme-color-syntax-property,    #E45649); }
		.pict-content-code-wrap .tag           { color: var(--theme-color-syntax-tag,         #E45649); }
		.pict-content-code-wrap .attr-name     { color: var(--theme-color-syntax-attrname,    #986801); }
		.pict-content-code-wrap .attr-value    { color: var(--theme-color-syntax-attrvalue,   #50A14F); }
		.pict-content-code-wrap .builtin       { color: var(--theme-color-syntax-builtin,     #986801); }
		.pict-content-code-wrap .type          { color: var(--theme-color-syntax-type,        #C18401); }
		.pict-content-code-wrap .variable      { color: var(--theme-color-syntax-variable,    #383A42); }
		.pict-content pre code {
			background: none;
			padding: 0;
			color: inherit;
			font-size: inherit;
		}
		.pict-content blockquote {
			border-left: 4px solid var(--theme-color-brand-primary, #2E7D74);
			margin: 1em 0;
			padding: 0.5em 1em;
			background: var(--theme-color-background-secondary, #F7F5F0);
			color: var(--theme-color-text-secondary, #5E5549);
		}
		.pict-content blockquote p {
			margin: 0.25em 0;
		}
		.pict-content ul, .pict-content ol {
			padding-left: 2em;
			line-height: 1.8;
		}
		.pict-content li {
			margin: 0.25em 0;
			color: var(--theme-color-text-primary, #423D37);
		}
		.pict-content hr {
			border: none;
			border-top: 1px solid var(--theme-color-border-default, #DDD6CA);
			margin: 2em 0;
		}
		.pict-content table {
			width: 100%;
			border-collapse: collapse;
			margin: 1em 0;
		}
		.pict-content table th {
			background: var(--theme-color-background-secondary, #F5F0E8);
			border: 1px solid var(--theme-color-border-default, #DDD6CA);
			padding: 0.6em 0.8em;
			text-align: left;
			font-weight: 600;
			color: var(--theme-color-text-primary, #3D3229);
		}
		.pict-content table td {
			border: 1px solid var(--theme-color-border-default, #DDD6CA);
			padding: 0.5em 0.8em;
			color: var(--theme-color-text-primary, #423D37);
		}
		.pict-content table tr:nth-child(even) {
			background: var(--theme-color-background-secondary, #F7F5F0);
		}
		.pict-content img {
			max-width: 100%;
			height: auto;
		}
		.pict-content pre.mermaid {
			background: var(--theme-color-background-panel, #fff);
			color: var(--theme-color-text-primary, #2A241E);
			text-align: center;
			padding: 1em;
		}
		.pict-content pre.mermaid text,
		.pict-content pre.mermaid .nodeLabel,
		.pict-content pre.mermaid .edgeLabel,
		.pict-content pre.mermaid .label,
		.pict-content pre.mermaid .cluster-label,
		.pict-content pre.mermaid span,
		.pict-content pre.mermaid foreignObject p,
		.pict-content pre.mermaid foreignObject div,
		.pict-content pre.mermaid foreignObject span {
			color: var(--theme-color-text-primary, #2A241E) !important;
			fill: var(--theme-color-text-primary, #2A241E) !important;
		}
		.pict-content pre.mermaid .edgePath .path {
			stroke: var(--theme-color-text-secondary, #5E5549) !important;
		}
		.pict-content pre.mermaid .arrowheadPath {
			fill: var(--theme-color-text-secondary, #5E5549) !important;
		}
		/* Dark-mode override for handcrafted mermaid diagrams that bake
		   per-node inline fill colors via 'style X fill:#...' directives
		   (common in architecture / module docs, where pastel layer
		   colors mark visual hierarchy). Mermaid renders those as inline
		   style="fill:#..." SVG attributes — highest specificity, so
		   neither themeVariables nor unflagged CSS can reach them.
		   In light mode the Material pastels read fine; in dark mode the
		   same light fills become a high-contrast island on the dark
		   page with unreadable text. Force the fills back to a theme
		   background so dark-mode reads; light mode is intentionally
		   unmodified so the per-layer hierarchy is preserved there. */
		.theme-dark .pict-content pre.mermaid .node rect,
		.theme-dark .pict-content pre.mermaid .node polygon,
		.theme-dark .pict-content pre.mermaid .node circle,
		.theme-dark .pict-content pre.mermaid .node ellipse,
		.theme-dark .pict-content pre.mermaid .node path,
		.theme-dark .pict-content pre.mermaid .cluster rect {
			fill:   var(--theme-color-background-tertiary, #2A241E) !important;
			stroke: var(--theme-color-border-default,      #5E5549) !important;
		}
		/* Mirror of the above for theme mode 'system' — when the user
		   hasn't explicitly picked light or dark, the theme provider
		   leaves <html> without .theme-light/.theme-dark and the CSS
		   variables follow prefers-color-scheme. The .theme-dark-prefixed
		   block above doesn't match in that case, so light pastels would
		   win again on dark OSes. Mirror the rule under the media query,
		   gated by :not(.theme-light) so an explicit light override on a
		   dark OS still wins. */
		@media (prefers-color-scheme: dark) {
			html:not(.theme-light) .pict-content pre.mermaid .node rect,
			html:not(.theme-light) .pict-content pre.mermaid .node polygon,
			html:not(.theme-light) .pict-content pre.mermaid .node circle,
			html:not(.theme-light) .pict-content pre.mermaid .node ellipse,
			html:not(.theme-light) .pict-content pre.mermaid .node path,
			html:not(.theme-light) .pict-content pre.mermaid .cluster rect {
				fill:   var(--theme-color-background-tertiary, #2A241E) !important;
				stroke: var(--theme-color-border-default,      #5E5549) !important;
			}
		}
		/* Excalidraw fence placeholders + rendered SVGs */
		.pict-content .pict-excalidraw-fence {
			display: block;
			background: var(--theme-color-background-panel, #fff);
			border: 1px solid var(--theme-color-border-default, #DDD6CA);
			border-radius: 4px;
			padding: 1em;
			margin: 1em 0;
			text-align: center;
		}
		.pict-content .pict-excalidraw-fence svg {
			max-width: 100%;
			height: auto;
		}
		.pict-content .pict-excalidraw-fence-loading {
			color: var(--theme-color-text-secondary, #5E5549);
			font-style: italic;
			font-size: 0.9em;
			padding: 1em;
		}
		.pict-content .pict-excalidraw-fence-error {
			border-color: var(--theme-color-status-error, #D9534F);
			background: var(--theme-color-background-secondary, #FFF5F5);
		}
		.pict-content .pict-excalidraw-fence-error-message {
			color: var(--theme-color-status-error, #D9534F);
			font-family: var(--theme-typography-family-mono, monospace);
			font-size: 0.85em;
			text-align: left;
		}
		.pict-content .pict-content-katex-display {
			text-align: center;
			margin: 1em 0;
			padding: 0.5em;
			overflow-x: auto;
		}
		.pict-content .pict-content-katex-inline {
			display: inline;
		}

		/* Fullscreen viewer for images and mermaid diagrams (click-to-zoom) */
		.pict-content [data-fullscreen-source] {
			cursor: zoom-in;
			outline: 1px solid transparent;
			outline-offset: 3px;
			border-radius: 4px;
			transition: outline-color 0.15s ease;
		}
		.pict-content [data-fullscreen-source]:hover {
			outline-color: var(--theme-color-brand-primary, #2E7D74);
		}
		/* Code block container with hover-revealed action buttons */
		.pict-content-code-container {
			position: relative;
			display: flex;
			align-items: flex-start;
			gap: 8px;
			margin: 1em 0;
		}
		.pict-content-code-container > .pict-content-code-wrap {
			margin: 0;
			flex: 1 1 auto;
			min-width: 0;
		}
		.pict-content-code-actions {
			position: sticky;
			top: 64px;
			align-self: flex-start;
			display: flex;
			flex-direction: column;
			gap: 6px;
			flex: 0 0 auto;
			padding-top: 6px;
			opacity: 0;
			transform: translateX(-4px);
			transition: opacity 0.15s ease, transform 0.15s ease;
			pointer-events: none;
		}
		.pict-content-code-container:hover .pict-content-code-actions,
		.pict-content-code-container:focus-within .pict-content-code-actions {
			opacity: 1;
			transform: translateX(0);
			pointer-events: auto;
		}
		.pict-content-code-action-btn {
			display: inline-flex;
			align-items: center;
			justify-content: center;
			width: 28px;
			height: 28px;
			padding: 0;
			background: var(--theme-color-background-panel, #FFFFFF);
			color: var(--theme-color-text-muted, #5E5549);
			border: 1px solid var(--theme-color-border-default, #DDD6CA);
			border-radius: 6px;
			cursor: pointer;
			box-shadow: 0 1px 3px rgba(0, 0, 0, 0.08);
			transition: background-color 0.15s ease, color 0.15s ease, border-color 0.15s ease, box-shadow 0.15s ease;
		}
		.pict-content-code-action-btn svg {
			display: block;
			width: 14px;
			height: 14px;
			stroke: currentColor;
			fill: none;
			stroke-width: 1.6;
			stroke-linecap: round;
			stroke-linejoin: round;
		}
		.pict-content-code-action-btn:hover {
			background: var(--theme-color-brand-primary, #2E7D74);
			color: var(--theme-color-text-on-brand, #FFFFFF);
			border-color: var(--theme-color-brand-primary, #2E7D74);
			box-shadow: 0 2px 8px rgba(0, 0, 0, 0.18);
		}
		.pict-content-code-action-btn:focus-visible {
			outline: 2px solid var(--theme-color-brand-primary, #2E7D74);
			outline-offset: 2px;
		}
		.pict-content-code-action-btn.is-copied {
			background: var(--theme-color-brand-primary, #2E7D74);
			color: var(--theme-color-text-on-brand, #FFFFFF);
			border-color: var(--theme-color-brand-primary, #2E7D74);
		}
		.pict-content-code-action-btn.is-copy-failed {
			background: var(--theme-color-status-error, #B23A3A);
			color: var(--theme-color-text-on-brand, #FFFFFF);
			border-color: var(--theme-color-status-error, #B23A3A);
		}
		.pict-fullscreen-overlay {
			position: fixed;
			inset: 0;
			z-index: 9999;
			display: flex;
			flex-direction: column;
			background: rgba(0, 0, 0, 0.62);
			backdrop-filter: blur(6px);
			-webkit-backdrop-filter: blur(6px);
			color: var(--theme-color-text-primary, #2A241E);
		}
		.pict-fullscreen-overlay[hidden] {
			display: none;
		}
		.pict-fullscreen-titlebar {
			display: flex;
			align-items: center;
			justify-content: space-between;
			gap: 1em;
			height: 48px;
			padding: 0 1em;
			background: var(--theme-color-background-panel, #FFFFFF);
			color: var(--theme-color-text-primary, #1A1612);
			border-bottom: 1px solid var(--theme-color-border-default, #DDD6CA);
			box-shadow: 0 2px 8px rgba(0, 0, 0, 0.18);
			flex: 0 0 auto;
		}
		.pict-fullscreen-title {
			font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
			font-size: 0.95em;
			font-weight: 600;
			letter-spacing: 0.01em;
			white-space: nowrap;
			overflow: hidden;
			text-overflow: ellipsis;
			color: var(--theme-color-text-primary, #1A1612);
		}
		.pict-fullscreen-controls {
			display: inline-flex;
			align-items: center;
			gap: 4px;
		}
		.pict-fullscreen-btn {
			display: inline-flex;
			align-items: center;
			justify-content: center;
			width: 32px;
			height: 32px;
			padding: 0;
			background: transparent;
			border: 1px solid transparent;
			border-radius: 6px;
			color: var(--theme-color-text-muted, #5E5549);
			cursor: pointer;
			transition: background-color 0.15s ease, color 0.15s ease, border-color 0.15s ease;
		}
		.pict-fullscreen-btn svg {
			display: block;
			width: 16px;
			height: 16px;
			stroke: currentColor;
			fill: none;
			stroke-width: 1.75;
			stroke-linecap: round;
			stroke-linejoin: round;
		}
		.pict-fullscreen-btn:hover {
			background: var(--theme-color-border-light, #EAE3D8);
			color: var(--theme-color-text-primary, #1A1612);
		}
		.pict-fullscreen-btn:focus-visible {
			outline: 2px solid var(--theme-color-brand-primary, #2E7D74);
			outline-offset: 2px;
		}
		.pict-fullscreen-close:hover {
			background: var(--theme-color-brand-primary, #2E7D74);
			color: var(--theme-color-text-on-brand, #FFFFFF);
		}
		.pict-fullscreen-stage {
			flex: 1 1 auto;
			display: flex;
			align-items: center;
			justify-content: center;
			overflow: hidden;
			padding: 1.5em;
			cursor: zoom-in;
			touch-action: none;
		}
		.pict-fullscreen-stage.is-zoomed {
			cursor: grab;
		}
		.pict-fullscreen-stage.is-panning {
			cursor: grabbing;
		}
		.pict-fullscreen-content {
			display: flex;
			align-items: center;
			justify-content: center;
			max-width: 100%;
			max-height: 100%;
			transform-origin: center center;
			transition: transform 0.05s linear;
			will-change: transform;
		}
		.pict-fullscreen-content > * {
			box-shadow: 0 12px 48px rgba(0, 0, 0, 0.45);
		}
		.pict-fullscreen-content .pict-fullscreen-img {
			max-width: 90vw;
			max-height: calc(100vh - 96px);
			width: auto;
			height: auto;
			object-fit: contain;
			background: var(--theme-color-background-panel, #FFFFFF);
			padding: 12px;
			border-radius: 6px;
		}
		.pict-fullscreen-content .pict-fullscreen-mermaid-svg {
			width: min(90vw, 1400px);
			height: auto;
			max-height: calc(100vh - 96px);
			background: var(--theme-color-background-panel, #FFFFFF);
			padding: 16px;
			border-radius: 6px;
		}
		/* Bespoke inline-SVG diagrams (pict-renderer-graph / excalidraw).  Backdrop
		   uses the diagram's own --diagram-paper so the zoomed copy keeps the same
		   theme as the inline one (the host defines --diagram-* on the overlay). */
		.pict-fullscreen-content .pict-fullscreen-diagram-svg {
			width: min(90vw, 1400px);
			height: auto;
			max-height: calc(100vh - 96px);
			background: var(--diagram-paper, var(--theme-color-background-panel, #FFFFFF));
			padding: 16px;
			border-radius: 6px;
		}
		/* Same dark-mode fill/stroke override as for inline diagrams, but
		   scoped to the fullscreen-overlay clone — which lives under
		   <body>, NOT inside .pict-content, so the pre.mermaid-scoped
		   rules above don't reach it. */
		.theme-dark .pict-fullscreen-content .pict-fullscreen-mermaid-svg .node rect,
		.theme-dark .pict-fullscreen-content .pict-fullscreen-mermaid-svg .node polygon,
		.theme-dark .pict-fullscreen-content .pict-fullscreen-mermaid-svg .node circle,
		.theme-dark .pict-fullscreen-content .pict-fullscreen-mermaid-svg .node ellipse,
		.theme-dark .pict-fullscreen-content .pict-fullscreen-mermaid-svg .node path,
		.theme-dark .pict-fullscreen-content .pict-fullscreen-mermaid-svg .cluster rect {
			fill:   var(--theme-color-background-tertiary, #2A241E) !important;
			stroke: var(--theme-color-border-default,      #5E5549) !important;
		}
		@media (prefers-color-scheme: dark) {
			html:not(.theme-light) .pict-fullscreen-content .pict-fullscreen-mermaid-svg .node rect,
			html:not(.theme-light) .pict-fullscreen-content .pict-fullscreen-mermaid-svg .node polygon,
			html:not(.theme-light) .pict-fullscreen-content .pict-fullscreen-mermaid-svg .node circle,
			html:not(.theme-light) .pict-fullscreen-content .pict-fullscreen-mermaid-svg .node ellipse,
			html:not(.theme-light) .pict-fullscreen-content .pict-fullscreen-mermaid-svg .node path,
			html:not(.theme-light) .pict-fullscreen-content .pict-fullscreen-mermaid-svg .cluster rect {
				fill:   var(--theme-color-background-tertiary, #2A241E) !important;
				stroke: var(--theme-color-border-default,      #5E5549) !important;
			}
		}
		.pict-fullscreen-content .pict-fullscreen-codewrap {
			max-width: 90vw;
			max-height: calc(100vh - 96px);
			margin: 0;
			overflow: auto;
			box-shadow: 0 12px 48px rgba(0, 0, 0, 0.45);
		}
	`;
