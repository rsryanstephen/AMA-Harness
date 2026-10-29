# Driving aggregation reports with claude-in-chrome — confirmed traps (2026-10-06, production, PROJ-15446/15472)

Routes: templates `/aggregations/<slug>` (`servicer-rankings`, `servicing-transfer`, ...), saved
reports `/aggregations/view/<guid>`. Template cards on `/aggregations` → `find "VIEW link under the
X template card"`. All below confirmed live on production via the claude-in-chrome tools.

## Login
Form pre-fills from the browser's saved credentials. Never submit it — ask user to click Sign In,
wait for "dn"/ok, then screenshot. One ask, one turn.

## Build via Criteria, not the grid filter
- Grid column filter boxes (ag-grid floating filters) = view-only, NOT saved with the report,
  and IGNORE clicks/typing while the Customize panel is open. Three attempts lost 2026-10-06.
  Keys sent "into" them landed on the page: `ctrl+a` selected the page, `End`/`Home` scrolled it,
  page zoom jumped (user had to ctrl+0). Don't fight it: use Criteria (Customize panel, funnel
  icon top-left of the grid, ~(32,122) full-res) — criteria persist in the saved report.
- Criteria row = toggle + operator + value. `find "X criteria enable toggle and value combobox"`
  → click toggle → click combobox → `find "search text box inside the open X dropdown"` → click
  THAT box → type → `find "checkbox option labelled <value>"` → click → repeat per value →
  Escape. Typing straight after opening the combobox goes nowhere (first search box click
  missed, 2026-10-06). Date criteria: `form_input` on the From/To refs, value `yyyy-mm-dd`.
- An ENABLED criterion with an empty value shows a red box and disables Apply. A stray click
  on a toggle (Channel, 2026-10-06) is the usual cause — check toggles before blaming Apply.
- Group By add-field combobox: type → click option → option is ADDED but the list STAYS OPEN;
  the next click (Apply at ~(459,647)) lands on another option and adds it too ("Servicing
  Seller Entity" got added that way). Escape FIRST, read the Group By summary text, then Apply.
- Refs go stale on every re-render (Apply, dropdown open/close, dialog). Re-`find` before each
  click; a "No element found with reference" error = re-find, not retry.

## Reading the grid
- Virtualised: `get_page_text` returns only RENDERED columns/rows. Mouse-wheel `scroll right`
  does nothing; drag the horizontal scrollbar thumb (`left_click_drag` along y≈640 full-res)
  to bring CPR columns into view, then screenshot. Sort = click column header; 1st click asc,
  2nd desc (header at y≈143).
- `scale: 0.6` screenshots for navigation; full-res + `save_to_disk` only for the capture the
  user will see. "CDP Page.captureScreenshot timed out" after heavy grid work = renderer busy,
  not dead: `wait 5`, retry once; then stop and tell the user.

## Saving
- Save icon top-right (`find "Save Report button"`); dialog = name (pre-filled "<Template> -"),
  Report Description, folder /Home, "Keep fields updated" on, share OFF (leave off).
  `form_input` the name/description refs, then click Save As. Success = HTTP 201 on
  `POST /report` and the URL changes to `/aggregations/view/<guid>` — read the URL, not the
  dialog.
- **A long description (~240 chars, had `:` `(` `)` `%`) → `POST /report` 500 and the dialog
  stays open with NO message** — looks like a dead button. PROJ-15472. Keep the
  description to one short plain sentence; name without punctuation worked. Check
  `read_network_requests` (urlPattern `/report`) before clicking again — three "retries" were
  three 500s.
- Reports include TERMINATED loans by default (no Is Active criterion); a servicer with 0
  active loans still has a row. That is the data, not a filter mistake.
