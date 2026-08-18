---
name: company-slides
description: Build standalone HTML slide decks in YourCompany's brand theme — Ubuntu font, blue/yellow palette, hex side panel, keyboard nav. Use for "YourCompany themed slides", "YourCompany deck", "company presentation", "internal deck", or any PROJ/AMA/YourCompany internal presentation request, even a bare "make me some slides". Produces self-contained .html, not .pptx.
---

# YourCompany Slides

Generates HTML slide decks that exactly replicate YourCompany's internal presentation brand — the same theme used in the "From Copilot to Orchestrator" deck. Output is a single self-contained `.html` file: open it in a browser, arrow keys / PageUp / PageDown navigate, `F` toggles fullscreen, and a progress bar tracks position.

**Golden rule: replicate exactly, don't reinterpret.** The brand spec below is a precise CSS system, not a style suggestion. Reuse the exact hex colors, the exact 27% panel width, the exact hex-pattern SVG data-uri, and the exact font stack. Don't substitute similar colors, don't redesign components, don't change spacing "to make it look better." If a new component is needed that isn't covered below, extend the existing visual language (same border-radius, same border color `#ececec`, same panel background `#fafafa`) rather than inventing a new style.

## Workflow

1. **Start from the template, don't build from scratch.** Copy `assets/template.html` as the starting point — it already has the full brand CSS embedded and one example of every slide type. Duplicate the slide `<div>` blocks you need and edit their content.
2. **Consult `assets/reference-deck.html`** if you need to see the theme used at full scale (27 slides) or want to confirm how a specific component looks in context before writing something novel.
3. **Fill in real content** — replace placeholder text, update `sec-label`, `slide-title`, footer section name, and the `N / total` page counters on every slide (including the title and closing slides).
4. **Keep bullets to ~4–5 per slide.** The deck has no scroll (`overflow: hidden` on `.slide`); overflowing content will be clipped, not scrollable.
5. **Save the finished deck** to `/mnt/user-data/outputs/` as a single `.html` file and present it to the user. This is a file-creation task — treat the finished deck as a deliverable artifact, not something to paste inline in chat.

## Brand tokens (must match exactly)

| Token | Value |
|---|---|
| Primary blue | `#226BFF` |
| Accent yellow | `#FEB63B` |
| Teal | `#02CBCE` |
| Purple | `#691FFF` |
| Red | `#EA032F` |
| Light blue | `#2BC2FF` |
| Text (off-black) | `#232323` |
| Background | `#FFFFFF` |
| Muted text | `#6b6b6b` |
| Faint text | `#9a9a9a` |
| Border/line | `#ececec` |
| Panel background | `#fafafa` |
| Font | Ubuntu (400/500/700), body text; **Ubuntu Mono** for code |

These are defined as CSS custom properties (`--si-blue`, `--si-yellow`, etc.) at the top of `assets/theme.css` — always reference the variables, don't hardcode new hex values into new components.

## Structural rules

- **Every slide** is a `.slide` div inside `.deck`, with a `.topbar` (6px colored strip: blue normally, yellow on `.title-card`), and ends in `.slide-footer` (section name + `page / total`).
- **Right brand panel**: every slide gets a colored panel on the right ~27% of the width via `.slide::after`, with the hexagonal pattern overlay. It's **yellow** on normal content slides and **blue** on `.title-card` slides (title/section-opener slides). This is automatic from the CSS — don't manually add a panel div.
- **Two slide archetypes**:
  - `.title-card` — used for the opening slide, section openers, and the closing Q&A slide. Left-aligned hero block (`eyebrow`, `big-title`, `subtitle`, `divider` accent bar, optional `presenter` line), justified to the bottom-left.
  - Standard content slide — `.slide-header` (small `.sec-label` + big `.slide-title`) then `.slide-body` (flex row: `.slide-content` plus an optional right-hand widget — tracker, diagram, or nothing).
- **Content slide body always uses one of these patterns** — pick based on the content, don't mix styles across a deck:
  - Bullets only (`.bullet` / `.dot` / `.bt`)
  - Bullets + progress tracker sidebar (`.tracker` with `.sp` rows, marked `.cur` / `.done`)
  - Two-column comparison (`.split` with `.split-card`, optionally `.indigo` for the "ours"/highlighted side)
  - Bullets + code or diagram panel (`.diagram` containing a `.cb` code block, whose spans use `.cm` comment, `.k` key, `.s` string, `.b` boolean coloring)
  - Overview grid (`.stage-grid` of `.sg` cards, each with a numbered `.sn2` badge)

See `assets/template.html` for a working copy of every one of these patterns — copy the block that matches your content type.

## Files in this skill

- `assets/theme.css` — the extracted, pure CSS brand stylesheet. Reference this if you want to inspect or diff the styling in isolation.
- `assets/template.html` — ready-to-edit starter deck: full CSS already embedded, one example of each slide archetype, and the navigation JS. **Use this as the base for every new deck.**
- `assets/reference-deck.html` — the original 27-slide "From Copilot to Orchestrator" deck, kept as ground truth for exact visual fidelity. Don't ship this file itself to a user as their deck; it's a reference only.

## Non-negotiables

- Don't change the font away from Ubuntu.
- Don't resize the right panel away from 27%, or change its color logic (yellow content / blue title-card).
- Don't drop the hex-pattern watermark, the topbar strip, or the progress bar.
- Don't invent new colors outside the palette above.
- Keep the keyboard-nav script (`ArrowRight/Left`, `PageUp/Down`, `Home/End`, `F` fullscreen) intact and update the slide count logic if slides are added or removed — it derives the count from `document.querySelectorAll('.slide')`, so no manual count needed there.