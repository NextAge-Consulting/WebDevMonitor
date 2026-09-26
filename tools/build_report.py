#!/usr/bin/env python3
"""Turn an analysis write-up (markdown) into a standalone HTML report.

Usage:
    python3 tools/build_report.py logs/<name>-analysis.md [-o out.html]

The markdown stays the source you write and edit. This converts it into the data
shape of the report generator (tools/gen-report.mjs) and runs it, so the HTML is
self-contained: inlined CSS, light and dark themes, and readable on a phone. It needs Node.js; the script itself uses only the Python
standard library.

Markdown conventions it understands:
    # Title - subtitle          H1; text after " - " becomes the subtitle
    > note                      first block quote after the H1 becomes the note box
    <!-- stat: 222 | kills -->  a stat tile (value | label), anywhere in the file
    ## Heading                  starts a section
    ### Heading, tables, lists (nested one level), block quotes, ``` code,
    **bold**, *italic*, `code`, [text](url)
"""
import argparse
import html
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
GENERATOR = Path(__file__).resolve().parent / 'gen-report.mjs'

STAT_RE = re.compile(r'<!--\s*stat:\s*(.+?)\s*\|\s*(.+?)\s*-->')
TABLE_SEP_RE = re.compile(r'^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?$')
LIST_RE = re.compile(r'^(\s*)([-*]|\d+\.)\s+(.*)$')


def out(*parts: object) -> None:
    """Write one line to stdout; this is a CLI, its messages are its output."""
    sys.stdout.write(' '.join(str(p) for p in parts) + '\n')


def inline(text: str) -> str:
    """Escape HTML, then apply inline markdown: code, bold, italic, links."""
    codes: list[str] = []

    def stash(m: re.Match[str]) -> str:
        codes.append(f'<code>{html.escape(m.group(1))}</code>')
        return f'\x00{len(codes) - 1}\x00'

    text = re.sub(r'`([^`]+)`', stash, text)
    text = html.escape(text, quote=False)
    text = re.sub(r'\*\*(.+?)\*\*', r'<b>\1</b>', text)
    text = re.sub(r'(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])', r'<i>\1</i>', text)
    text = re.sub(r'\[([^\]]+)\]\(([^)\s]+)\)', r'<a href="\2">\1</a>', text)
    return re.sub(r'\x00(\d+)\x00', lambda m: codes[int(m.group(1))], text)


def split_row(line: str) -> list[str]:
    cells = line.strip().strip('|').split('|')
    return [c.strip() for c in cells]


def render_table(rows: list[str]) -> str:
    head = split_row(rows[0])
    body = [split_row(r) for r in rows[2:]]
    th = ''.join(f'<th>{inline(c)}</th>' for c in head)
    trs = ''.join('<tr>' + ''.join(f'<td>{inline(c)}</td>' for c in r) + '</tr>' for r in body)
    return f'<table><thead><tr>{th}</tr></thead><tbody>{trs}</tbody></table>'


def render_list(items: list[tuple[int, str, str]]) -> str:
    """items: (indent, marker, text). Supports one level of nesting."""
    top_indent = items[0][0]
    tag = 'ol' if items[0][1][0].isdigit() else 'ul'
    parts: list[str] = []
    i = 0
    while i < len(items):
        text = items[i][2]
        li = inline(text)
        j = i + 1
        children: list[tuple[int, str, str]] = []
        while j < len(items) and items[j][0] > top_indent:
            children.append(items[j])
            j += 1
        if children:
            li += render_list(children)
        parts.append(f'<li>{li}</li>')
        i = j
    return f'<{tag}>' + ''.join(parts) + f'</{tag}>'


def render_blocks(lines: list[str]) -> str:
    """Convert a run of markdown lines (no H1/H2) into HTML."""
    result: list[str] = []
    para: list[str] = []
    i = 0

    def flush_para() -> None:
        if para:
            result.append('<p>' + inline(' '.join(para)) + '</p>')
            para.clear()

    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if not stripped or STAT_RE.fullmatch(stripped) or stripped == '---':
            flush_para()
            i += 1
        elif stripped.startswith('```'):
            flush_para()
            j = i + 1
            while j < len(lines) and not lines[j].strip().startswith('```'):
                j += 1
            result.append('<pre>' + html.escape('\n'.join(lines[i + 1:j])) + '</pre>')
            i = j + 1
        elif stripped.startswith('### '):
            flush_para()
            result.append(f'<h3>{inline(stripped[4:])}</h3>')
            i += 1
        elif stripped.startswith('|') and i + 1 < len(lines) and TABLE_SEP_RE.match(lines[i + 1].strip()):
            flush_para()
            j = i
            while j < len(lines) and lines[j].strip().startswith('|'):
                j += 1
            result.append(render_table([ln.strip() for ln in lines[i:j]]))
            i = j
        elif stripped.startswith('>'):
            flush_para()
            j = i
            quote: list[str] = []
            while j < len(lines) and lines[j].strip().startswith('>'):
                quote.append(lines[j].strip()[1:].strip())
                j += 1
            result.append('<blockquote>' + render_blocks(quote) + '</blockquote>')
            i = j
        elif LIST_RE.match(line):
            flush_para()
            items: list[tuple[int, str, str]] = []
            j = i
            while j < len(lines):
                m = LIST_RE.match(lines[j])
                if m:
                    items.append((len(m.group(1)), m.group(2), m.group(3)))
                elif lines[j].startswith('  ') and lines[j].strip() and items:
                    ind, mk, tx = items[-1]
                    items[-1] = (ind, mk, tx + ' ' + lines[j].strip())
                else:
                    break
                j += 1
            result.append(render_list(items))
            i = j
        else:
            para.append(stripped)
            i += 1
    flush_para()
    return ''.join(result)


def markdown_to_report(md: str) -> dict[str, Any]:
    lines = md.split('\n')
    stats = [{'value': v, 'label': lb} for v, lb in STAT_RE.findall(md)]
    title, subtitle, note = 'Report', '', ''
    sections: list[dict[str, str]] = []
    preamble: list[str] = []
    current: dict[str, Any] | None = None
    for line in lines:
        if line.startswith('# ') and title == 'Report':
            full = line[2:].strip()
            title, _, subtitle = full.partition(' - ')
        elif line.startswith('## '):
            if current is not None:
                sections.append({'heading': current['heading'], 'html': render_blocks(current['lines'])})
            current = {'heading': line[3:].strip(), 'lines': []}
        elif current is not None:
            current['lines'].append(line)
        else:
            preamble.append(line)
    if current is not None:
        sections.append({'heading': current['heading'], 'html': render_blocks(current['lines'])})

    quote = [ln.strip()[1:].strip() for ln in preamble if ln.strip().startswith('>')]
    rest = [ln for ln in preamble if not ln.strip().startswith('>')]
    if quote:
        note = inline(' '.join(quote))
    intro = render_blocks(rest)
    if intro:
        sections.insert(0, {'html': intro})
    return {
        'title': title.strip(),
        'subtitle': html.escape(subtitle.strip() or 'WebDevMonitor log analysis'),
        'mode': 'report',
        'note': note,
        'stats': stats,
        'sections': sections,
        'footer': 'Generated from the markdown write-up with <code>tools/build_report.py</code> · '
                  '<a href="https://github.com/NextAge-Consulting/WebDevMonitor">WebDevMonitor</a>',
    }


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('markdown', type=Path)
    ap.add_argument('-o', '--output', type=Path, help='HTML output (default: next to the markdown)')
    a = ap.parse_args()
    if not GENERATOR.exists():
        sys.exit(f'report generator not found: {GENERATOR}')
    data = markdown_to_report(a.markdown.read_text(encoding='utf-8'))
    target = (a.output or a.markdown.with_suffix('.html')).resolve()
    with tempfile.TemporaryDirectory() as tmp:
        data_path = Path(tmp) / 'report.json'
        data_path.write_text(json.dumps(data), encoding='utf-8')
        done = subprocess.run(['node', str(GENERATOR), str(REPO_ROOT), str(data_path), str(target)],
                              capture_output=True, text=True)
    if done.returncode != 0:
        sys.exit(done.stderr.strip() or 'report generator failed')
    out(done.stdout.strip())


if __name__ == '__main__':
    main()
