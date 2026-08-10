#!/usr/bin/env python3
"""Assemble the Knit landing page with build-time snippet highlighting.

The landing-page source (``web/index.html``) carries placeholder elements::

    <code class="snippet" data-snippet="FILE:MARKER">...</code>

This script replaces each one with the Bash region ``FILE:MARKER`` extracted
from the documentation's *tested* code samples (``docs/source/_code/``), so the
code shown on the site can never drift from the code the docs exercise. The
region is highlighted with a Knit-branded Pygments theme whose colors are read
from ``web/styles.css`` --- the site and the code theme therefore share a single
palette. The generated token CSS is emitted once into the page ``<head>``.

Run via the documentation virtualenv (it already has Pygments); see the ``web``
target in the Makefile.
"""

import argparse
import re
import sys
from pathlib import Path

from pygments import highlight
from pygments.formatters import HtmlFormatter
from pygments.lexers.shell import BashLexer
from pygments.style import Style
from pygments.token import (
    Comment,
    Keyword,
    Name,
    Number,
    Operator,
    String,
    Text,
)


# -- Knit-aware Bash lexer -----------------------------------------------------
#
# Mirrors the KnitBashLexer in docs/source/conf.py: the bare word `knit` and any
# `knit_*` function are reclassified to the shell-builtin token so the Knit API
# stands out, while `knit_*` names inside strings and comments are left alone.

_KNIT_RE = re.compile(r"^knit(_[A-Za-z0-9_]+)?$")


def _knit_promote(tokens):
    for index, token, value in tokens:
        if (token in Text or token in Name) and _KNIT_RE.match(value):
            token = Name.Builtin
        yield index, token, value


class KnitBashLexer(BashLexer):
    """BashLexer that renders the Knit API as shell builtins."""

    def get_tokens_unprocessed(self, text):
        yield from _knit_promote(super().get_tokens_unprocessed(text))


# -- Palette (single source of truth: web/styles.css) --------------------------

# `--knit-name: #rrggbb;` custom properties in the :root block. Values that are
# not plain hex (e.g. the rgba() border) are simply not matched, which is fine:
# the code theme only needs the hex ones.
_PALETTE_RE = re.compile(r"--(knit-[a-z-]+):\s*(#[0-9a-fA-F]{3,8})\b")


def read_palette(styles_path):
    """Return the {name: '#rrggbb'} brand palette parsed from styles.css."""
    palette = dict(_PALETTE_RE.findall(styles_path.read_text()))
    required = ("knit-purple", "knit-coral", "knit-magenta", "knit-deep",
                "knit-surface", "knit-fg-muted")
    missing = [name for name in required if name not in palette]
    if missing:
        sys.exit(f"build-landing: {styles_path} is missing palette entries: "
                 f"{', '.join(missing)}")
    return palette


def make_style(palette):
    """Build a Pygments Style mapping Bash tokens to the brand palette."""

    class KnitStyle(Style):
        # The card already paints the surface background; this is only used by
        # get_style_defs for the top-level rule, which we strip when emitting.
        background_color = palette["knit-surface"]
        styles = {
            Comment: f"italic {palette['knit-deep']}",
            Keyword: palette["knit-magenta"],
            Name.Builtin: f"bold {palette['knit-purple']}",
            String: palette["knit-coral"],
            Number: palette["knit-magenta"],
            Operator: palette["knit-fg-muted"],
        }

    return KnitStyle


# -- Snippet extraction --------------------------------------------------------


def extract_region(path, marker):
    """Return the lines of `path` between `# START marker` and `# END marker`."""
    start = f"# START {marker}"
    end = f"# END {marker}"
    inside = False
    collected = []
    for line in path.read_text().splitlines():
        if line.strip() == start:
            inside = True
            continue
        if inside and line.strip() == end:
            return "\n".join(collected)
        if inside:
            collected.append(line)
    if inside:
        sys.exit(f"build-landing: no '# END {marker}' in {path}")
    sys.exit(f"build-landing: no '# START {marker}' in {path}")


# -- HTML assembly -------------------------------------------------------------

_SNIPPET_RE = re.compile(
    r'(<code class="snippet" data-snippet=")([^"]+)(">)(.*?)(</code>)',
    re.DOTALL,
)


def build(source, styles, code_dir, out):
    palette = read_palette(styles)
    style = make_style(palette)
    # nowrap: emit only the class-based token <span>s, keeping the page's own
    # <pre class="card__body"><code class="snippet"> wrapper.
    inline = HtmlFormatter(style=style, nowrap=True)
    lexer = KnitBashLexer()

    def replace(match):
        spec = match.group(2)
        try:
            filename, marker = spec.split(":", 1)
        except ValueError:
            sys.exit(f"build-landing: bad data-snippet '{spec}' "
                     "(expected FILE:MARKER)")
        code = extract_region(code_dir / filename, marker)
        rendered = highlight(code, lexer, inline).rstrip("\n")
        return match.group(1) + spec + match.group(3) + rendered + match.group(5)

    html = source.read_text()
    html, count = _SNIPPET_RE.subn(replace, html)
    if count == 0:
        sys.exit(f"build-landing: no data-snippet placeholders found in {source}")

    # Emit the token CSS once, scoped to `.snippet`, into the page <head>. Keep
    # only the `.snippet .token` rules: get_style_defs also emits a global
    # `pre { line-height }` rule (which would clobber the terminal cards), the
    # linenos rules, and a `.snippet { background }` rule (the card paints its
    # own background) --- none of which we want.
    defs = HtmlFormatter(style=style).get_style_defs(".snippet")
    defs = "\n".join(
        line for line in defs.splitlines() if line.startswith(".snippet .")
    )
    style_block = (
        "  <!-- Generated Knit code theme (maint/build-landing.py); colors\n"
        "       come from styles.css so the site and code share one palette. -->\n"
        "  <style>\n" + defs + "\n  </style>\n"
    )
    if "</head>" not in html:
        sys.exit(f"build-landing: no </head> in {source}")
    html = html.replace("</head>", style_block + "</head>", 1)

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(html)
    print(f"build-landing: wrote {out} ({count} snippets highlighted)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path("web/index.html"),
                        help="landing-page source with data-snippet placeholders")
    parser.add_argument("--styles", type=Path, default=Path("web/styles.css"),
                        help="stylesheet to read the brand palette from")
    parser.add_argument("--code-dir", type=Path,
                        default=Path("docs/source/_code"),
                        help="directory holding the FILE named in data-snippet")
    parser.add_argument("--out", type=Path,
                        default=Path("web/build/site/index.html"),
                        help="assembled index.html to write")
    args = parser.parse_args()
    build(args.source, args.styles, args.code_dir, args.out)


if __name__ == "__main__":
    main()
