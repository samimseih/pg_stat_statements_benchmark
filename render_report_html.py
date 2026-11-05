#!/usr/bin/env python3
"""Render a pg_stat_statements benchmark Markdown report as standalone HTML."""

from __future__ import annotations

import html
from pathlib import Path
import re
import sys


def inline(text: str) -> str:
    parts = re.split(r"(`[^`]*`)", text)
    rendered: list[str] = []

    for part in parts:
        if len(part) >= 2 and part[0] == "`" and part[-1] == "`":
            rendered.append("<code>" + html.escape(part[1:-1]) + "</code>")
        else:
            rendered.append(re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>",
                                   html.escape(part)))

    return "".join(rendered)


def split_row(line: str) -> list[str]:
    return [cell.strip() for cell in line.strip().strip("|").split("|")]


def table_align(separator_cells: list[str]) -> list[str]:
    aligns: list[str] = []

    for cell in separator_cells:
        cell = cell.strip()
        if cell.startswith(":") and cell.endswith(":"):
            aligns.append("center")
        elif cell.endswith(":"):
            aligns.append("right")
        elif cell.startswith(":"):
            aligns.append("left")
        else:
            aligns.append("left")

    return aligns


def render_table(lines: list[str], start: int) -> tuple[str, int]:
    header = split_row(lines[start])
    separator = split_row(lines[start + 1])
    aligns = table_align(separator)
    out: list[str] = ['<div class="table-wrap"><table>']

    out.append("<thead><tr>")
    for idx, cell in enumerate(header):
        cls = ' class="num"' if idx < len(aligns) and aligns[idx] == "right" else ""
        out.append(f"<th{cls}>{inline(cell)}</th>")
    out.append("</tr></thead><tbody>")

    i = start + 2
    while i < len(lines) and lines[i].startswith("|"):
        out.append("<tr>")
        for idx, cell in enumerate(split_row(lines[i])):
            classes: list[str] = []

            if idx < len(aligns) and aligns[idx] == "right":
                classes.append("num")
            if cell.startswith("+"):
                classes.append("pos")
            elif cell.startswith("-"):
                classes.append("neg")

            cls = f' class="{" ".join(classes)}"' if classes else ""
            out.append(f"<td{cls}>{inline(cell)}</td>")
        out.append("</tr>")
        i += 1

    out.append("</tbody></table></div>")
    return "\n".join(out), i


def render_markdown(markdown: str) -> str:
    lines = markdown.splitlines()
    body: list[str] = []
    i = 0

    while i < len(lines):
        line = lines[i]

        if not line.strip():
            i += 1
            continue
        if line.startswith("# "):
            body.append(f"<h1>{inline(line[2:].strip())}</h1>")
            i += 1
            continue
        if line.startswith("## "):
            body.append(f"<h2>{inline(line[3:].strip())}</h2>")
            i += 1
            continue
        if line.startswith("### "):
            body.append(f"<h3>{inline(line[4:].strip())}</h3>")
            i += 1
            continue
        if line.startswith("|") and i + 1 < len(lines) and lines[i + 1].startswith("|"):
            table, i = render_table(lines, i)
            body.append(table)
            continue
        if line.startswith(">"):
            # A "How to read this" note: a blockquote, rendered as a box
            # next to its table.
            quoted: list[str] = []
            while i < len(lines) and lines[i].startswith(">"):
                quoted.append(re.sub(r"^> ?", "", lines[i]))
                i += 1
            body.append('<aside class="note">' + render_markdown("\n".join(quoted))
                        + "</aside>")
            continue
        if line.startswith("- "):
            body.append("<ul>")
            while i < len(lines) and lines[i].startswith("- "):
                item = [lines[i][2:].strip()]
                i += 1
                # Continuation lines of the item, indented.
                while i < len(lines) and lines[i].startswith("  ") and lines[i].strip():
                    item.append(lines[i].strip())
                    i += 1
                body.append(f"<li>{inline(' '.join(item))}</li>")
            body.append("</ul>")
            continue

        paragraph = [line.strip()]
        i += 1
        while (
            i < len(lines)
            and lines[i].strip()
            and not lines[i].startswith("#")
            and not lines[i].startswith("|")
            and not lines[i].startswith("- ")
            and not lines[i].startswith(">")
        ):
            paragraph.append(lines[i].strip())
            i += 1
        body.append("<p>" + inline(" ".join(paragraph)) + "</p>")

    return "\n".join(body)


def render_html(markdown: str) -> str:
    body = render_markdown(markdown)

    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>pg_stat_statements benchmark report</title>
<style>
:root {{ color-scheme: light; --text:#17202a; --muted:#5b6773; --border:#d8dee4; --head:#f6f8fa; --stripe:#fbfcfd; --pos:#096b30; --neg:#b42318; }}
body {{ margin: 32px; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; color: var(--text); line-height: 1.45; background: white; }}
main {{ max-width: 1320px; margin: 0 auto; }}
h1 {{ margin: 0 0 18px; font-size: 30px; line-height: 1.2; }}
h2 {{ margin: 34px 0 12px; font-size: 21px; border-bottom: 1px solid var(--border); padding-bottom: 6px; }}
h3 {{ margin: 24px 0 10px; font-size: 16px; }}
p {{ margin: 8px 0; color: var(--muted); }}
ul {{ margin: 8px 0 18px; color: var(--muted); }}
li {{ margin: 4px 0; }}
aside.note {{ margin: 6px 0 24px; padding: 10px 16px; border-left: 4px solid #4c7fd1; background: #f3f6fb; border-radius: 0 6px 6px 0; font-size: 13.5px; }}
aside.note p, aside.note ul {{ margin: 4px 0; color: var(--text); }}
aside.note strong {{ font-weight: 650; }}
code {{ font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 0.92em; background: #f6f8fa; padding: 0.12em 0.32em; border-radius: 4px; }}
.table-wrap {{ overflow-x: auto; margin: 12px 0 22px; border: 1px solid var(--border); border-radius: 8px; }}
table {{ width: 100%; border-collapse: collapse; font-size: 13px; white-space: nowrap; }}
th, td {{ padding: 7px 10px; border-bottom: 1px solid var(--border); text-align: left; }}
th {{ position: sticky; top: 0; background: var(--head); font-weight: 650; z-index: 1; }}
tbody tr:nth-child(even) {{ background: var(--stripe); }}
tbody tr:last-child td {{ border-bottom: 0; }}
.num {{ text-align: right; font-variant-numeric: tabular-nums; }}
.pos {{ color: var(--pos); font-weight: 650; }}
.neg {{ color: var(--neg); font-weight: 650; }}
@media (max-width: 720px) {{ body {{ margin: 18px; }} table {{ font-size: 12px; }} th, td {{ padding: 6px 8px; }} }}
</style>
</head>
<body>
<main>
{body}
</main>
</body>
</html>
"""


def main() -> int:
    if len(sys.argv) not in (2, 3):
        print(f"usage: {Path(sys.argv[0]).name} input.md [output.html]", file=sys.stderr)
        return 2

    input_path = Path(sys.argv[1])
    output_path = Path(sys.argv[2]) if len(sys.argv) == 3 else input_path.with_suffix(".html")

    output_path.write_text(render_html(input_path.read_text()), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
