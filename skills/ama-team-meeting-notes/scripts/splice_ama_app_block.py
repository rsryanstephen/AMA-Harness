#!/usr/bin/env python3
"""Splice a regenerated AMA APP <li> block into a <titleWords> meeting-notes page's HTML,
without touching anything else on the page -- including the AMA ETL block sitting right
next to it.

The AMA Current Tasks section has this confirmed shape (both Last week and This week):
  <ul>
    <li><p><strong>AMA APP</strong></p><ul>...tickets...</ul></li>
    <li><p><strong>AMA ETL</strong></p>...(may be empty, or nest its own content)...</li>
  </ul>
  ...(This week's AMA ETL content sometimes lives in a sibling <ol> after the outer </ul>)...

The AMA APP <li> is fully self-contained, so replacing [start of AMA APP <li>, start of
AMA ETL <li>) is structurally guaranteed not to touch ETL content -- this holds regardless
of whether ETL's own content is nested in its <li> or lives in a following sibling list.

Usage (Windows: `python`, not `python3` -- `python3` on this machine resolves to the
Microsoft Store stub and errors out; `python` is the real Python 3.10 install):
  python splice_ama_app_block.py <full_page_html_file> <last_week_block_html_file> \
      <this_week_block_html_file> <output_html_file>

Exits nonzero with an explanation if the expected marker pair isn't found exactly twice --
never guesses at ambiguous markup.
"""
import sys


APP_MARKER = "<strong>AMA APP</strong>"
ETL_MARKER = "<strong>AMA ETL</strong>"


def find_enclosing_li_start(html, strong_index):
    """Walk backward from a <strong>...</strong> match to the start of its enclosing <li>."""
    li_start = html.rfind("<li", 0, strong_index)
    if li_start == -1:
        raise ValueError(f"No enclosing <li found before position {strong_index}")
    return li_start


def splice_one_block(html, app_strong_index, new_block_html):
    app_li_start = find_enclosing_li_start(html, app_strong_index)

    etl_strong_index = html.find(ETL_MARKER, app_strong_index)
    if etl_strong_index == -1:
        raise ValueError("No AMA ETL marker found after the AMA APP marker at "
                          f"position {app_strong_index} -- refusing to guess an end boundary.")
    etl_li_start = find_enclosing_li_start(html, etl_strong_index)

    if etl_li_start <= app_li_start:
        raise ValueError("AMA ETL <li> start resolved to before/at AMA APP <li> start -- "
                          "markup shape doesn't match what this script expects, refusing.")

    return html[:app_li_start] + new_block_html + html[etl_li_start:]


def main():
    if len(sys.argv) != 5:
        print(__doc__)
        sys.exit(1)

    page_file, last_week_file, this_week_file, output_file = sys.argv[1:5]

    with open(page_file, "r", encoding="utf-8") as f:
        html = f.read()
    with open(last_week_file, "r", encoding="utf-8") as f:
        last_week_block = f.read().strip()
    with open(this_week_file, "r", encoding="utf-8") as f:
        this_week_block = f.read().strip()

    app_positions = []
    idx = html.find(APP_MARKER)
    while idx != -1:
        app_positions.append(idx)
        idx = html.find(APP_MARKER, idx + 1)

    if len(app_positions) != 2:
        print(f"ERROR: expected exactly 2 occurrences of {APP_MARKER!r}, found "
              f"{len(app_positions)}. Refusing to proceed -- page shape may have changed.")
        sys.exit(1)

    last_week_pos, this_week_pos = app_positions
    original_length = len(html)

    # Splice the LATER occurrence (This week) first so the earlier occurrence's offsets
    # stay valid.
    html = splice_one_block(html, this_week_pos, this_week_block)
    html = splice_one_block(html, last_week_pos, last_week_block)

    with open(output_file, "w", encoding="utf-8") as f:
        f.write(html)

    print(f"OK: spliced both AMA APP blocks. Original length {original_length}, "
          f"new length {len(html)}.")
    print(f"Wrote result to {output_file}")


if __name__ == "__main__":
    main()
