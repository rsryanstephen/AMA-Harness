#!/usr/bin/env python3
"""
generate_pdf.py  —  AMA Release Notes PDF generator
Part of the ama-release-notes skill.

Usage (Windows: `python`, not `python3` -- `python3` on this machine resolves to the
Microsoft Store stub and errors out; `python` is the real Python 3.10 install):
    python generate_pdf.py \
        --version "125.0.0" \
        --date "June 4, 2026" \
        --tickets '{"highlights": [...], "bug_fixes": [...], ...}' \
        --output "C:/Users/<you>/AppData/Local/Temp/HO-Release Note_ Release 125.0.0.pdf"

Tickets JSON shape:
{
  "highlights":       ["Free-text highlight 1", "Free-text highlight 2"],
  "support_requests": [["PROJ-XXXXX", "Summary"], ...],
  "new_features":     [["PROJ-XXXXX", "Summary"], ...],
  "improvements":     [["PROJ-XXXXX", "Summary"], ...],
  "support_alerts":   [["PROJ-XXXXX", "Summary"], ...],
  "tasks":            [["PROJ-XXXXX", "Summary"], ...],
  "bug_fixes":        [["PROJ-XXXXX", "Summary"], ...]
}
Any key may be omitted or set to [] to skip that section.
"""

import argparse
import json
import sys

try:
    from reportlab.lib.pagesizes import A4
    from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
    from reportlab.lib.units import mm
    from reportlab.lib import colors
    from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, HRFlowable, KeepTogether
    from reportlab.lib.enums import TA_CENTER
except ImportError:
    print("reportlab is not installed. Run: pip install reportlab --break-system-packages", file=sys.stderr)
    sys.exit(1)


# ── Colour palette ─────────────────────────────────────────────────────────────
BRAND_BLUE = colors.HexColor("#0052CC")
RULE_COLOR = colors.HexColor("#DFE1E6")
BODY_GRAY  = colors.HexColor("#172B4D")
META_GRAY  = colors.HexColor("#6B778C")


# ── Style factory ──────────────────────────────────────────────────────────────
def make_styles():
    return {
        "title": ParagraphStyle(
            "ReleaseTitle", fontName="Helvetica-Bold", fontSize=22,
            textColor=BRAND_BLUE, spaceAfter=2*mm, leading=28,
        ),
        "meta": ParagraphStyle(
            "Meta", fontName="Helvetica", fontSize=10,
            textColor=META_GRAY, spaceAfter=6*mm, leading=14,
        ),
        "heading": ParagraphStyle(
            "SectionHeading", fontName="Helvetica-Bold", fontSize=13,
            textColor=BRAND_BLUE, spaceBefore=6*mm, spaceAfter=2*mm, leading=18,
        ),
        "bullet": ParagraphStyle(
            "BulletItem", fontName="Helvetica", fontSize=10,
            textColor=BODY_GRAY, leftIndent=8*mm, spaceAfter=1.5*mm, leading=14,
        ),
        "ticket": ParagraphStyle(
            "TicketItem", fontName="Helvetica", fontSize=9,
            textColor=BODY_GRAY, leftIndent=8*mm, spaceAfter=1.5*mm, leading=13,
        ),
        "footer": ParagraphStyle(
            "Footer", fontName="Helvetica", fontSize=8,
            textColor=META_GRAY, alignment=TA_CENTER, spaceBefore=3*mm,
        ),
    }


# ── Flowable helpers ───────────────────────────────────────────────────────────
def section_header(title, styles):
    return [
        HRFlowable(width="100%", thickness=1, color=RULE_COLOR,
                   spaceAfter=2*mm, spaceBefore=3*mm),
        Paragraph(title, styles["heading"]),
    ]

def bullet_item(text, styles):
    return Paragraph(f"<bullet>\u2022</bullet> {text}", styles["bullet"])

def ticket_item(key, summary, styles):
    # Escape any XML-special chars in the summary
    safe = (summary
            .replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;"))
    return Paragraph(
        f'<font name="Helvetica-Bold" color="#0052CC">{key}</font>'
        f'<font name="Helvetica" color="#172B4D">  {safe}</font>',
        styles["ticket"],
    )


# ── Section order and display labels ──────────────────────────────────────────
SECTION_ORDER = [
    ("highlights",       "Highlights",       "bullet"),
    ("support_requests", "Support Requests", "ticket"),
    ("new_features",     "New Features",     "ticket"),
    ("improvements",     "Improvements",     "ticket"),
    ("support_alerts",   "Support Alerts",   "ticket"),
    ("tasks",            "Tasks",            "ticket"),
    ("bug_fixes",        "Bug Fixes",        "ticket"),
]


# ── Build PDF ─────────────────────────────────────────────────────────────────
DEFAULT_FOOTER = "<pdfFooter>"


def build_pdf(version: str, date_str: str, tickets: dict, output_path: str,
              footer: str = DEFAULT_FOOTER) -> None:
    styles = make_styles()

    doc = SimpleDocTemplate(
        output_path, pagesize=A4,
        leftMargin=20*mm, rightMargin=20*mm,
        topMargin=20*mm, bottomMargin=20*mm,
    )

    story = []

    # ── Header ────────────────────────────────────────────────────────────────
    story.append(Paragraph(f"Release Note: Release {version}", styles["title"]))
    story.append(Paragraph(f"Deployed: {date_str}", styles["meta"]))
    story.append(HRFlowable(width="100%", thickness=2, color=BRAND_BLUE, spaceAfter=4*mm))

    # ── Sections ──────────────────────────────────────────────────────────────
    for key, label, item_type in SECTION_ORDER:
        items = tickets.get(key, [])
        if not items:
            continue

        if item_type == "bullet":
            flow = [bullet_item(str(text), styles) for text in items]
        else:
            flow = [ticket_item(str(e[0]), str(e[1]), styles)
                    if isinstance(e, (list, tuple)) and len(e) >= 2
                    else ticket_item("?", str(e), styles) for e in items]

        # Heading + first item move to the next page together -- a heading stranded at the
        # bottom of a page with its items overleaf (release 130 "Support Alerts", 2026-10-14).
        story.append(KeepTogether(section_header(label, styles) + flow[:1]))
        story += flow[1:]

    # ── Footer ────────────────────────────────────────────────────────────────
    story.append(Spacer(1, 6*mm))
    story.append(HRFlowable(width="100%", thickness=1, color=RULE_COLOR))
    story.append(Paragraph(
        footer,
        styles["footer"],
    ))

    doc.build(story)
    print(f"PDF written to: {output_path}")
    check_orphan_headings(output_path, [label for _, label, _ in SECTION_ORDER])


def check_orphan_headings(path: str, headings: list) -> None:
    """Fail loudly if any page ends on a section heading (heading stranded from its items)."""
    try:
        from pypdf import PdfReader
    except ImportError:
        try:
            from PyPDF2 import PdfReader
        except ImportError:
            print("WARNING: pypdf/PyPDF2 not installed -- orphan-heading check skipped", file=sys.stderr)
            return
    for n, page in enumerate(PdfReader(path).pages, 1):
        lines = [l.strip() for l in (page.extract_text() or "").splitlines() if l.strip()]
        # Last content line, ignoring the footer text on the final page.
        tail = [l for l in lines if not l.startswith("Generated by")]
        if tail and tail[-1] in headings:
            sys.exit(f"ERROR: page {n} ends on section heading '{tail[-1]}' -- orphaned heading")
    print("Orphan-heading check: OK")


# ── CLI entry point ────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="Generate AMA Release Notes PDF")
    parser.add_argument("--version",  required=True, help="Release version, e.g. 125.0.0")
    parser.add_argument("--date",     required=True, help="Deployment date, e.g. 'June 4, 2026'")
    parser.add_argument("--tickets",  required=True, help="JSON string of categorised tickets")
    parser.add_argument("--output",   required=True, help="Output PDF file path")
    parser.add_argument("--footer",   default=DEFAULT_FOOTER,
                         help="Footer text (releaseNotes.pdfFooter in harness-config.json)")
    args = parser.parse_args()

    try:
        tickets = json.loads(args.tickets)
    except json.JSONDecodeError as e:
        print(f"Error: --tickets is not valid JSON: {e}", file=sys.stderr)
        sys.exit(1)

    build_pdf(args.version, args.date, tickets, args.output, args.footer)


if __name__ == "__main__":
    main()
