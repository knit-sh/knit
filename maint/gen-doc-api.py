#!/usr/bin/env python3
"""Generate the Public/Private API reStructuredText pages for the Knit docs.

Reads the Doxygen XML (docs/doxygen/xml) and emits two Sphinx pages,
docs/source/api/public.rst and docs/source/api/private.rst, each listing the
functions and variables of that visibility via breathe directives.

Visibility follows the Knit naming convention: a leading underscore (one or
two) marks a private symbol; anything else is public.

This script uses only the Python standard library and is invoked by `make docs`
after Doxygen has produced its XML.
"""
import glob
import os
import sys
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.realpath(__file__))
ROOT = os.path.dirname(HERE)
XML_DIR = os.path.join(ROOT, "docs", "doxygen", "xml")
OUT_DIR = os.path.join(ROOT, "docs", "source", "api")
PROJECT = "knit"


def collect():
    """Collect symbols from the XML, keyed by their source file.

    Returns a dict mapping each source file name (e.g. ``log.sh``) to a
    ``{"function": set(), "variable": set()}`` of the symbols it defines.
    """
    by_file = {}
    for path in sorted(glob.glob(os.path.join(XML_DIR, "*_8sh.xml"))):
        root = ET.parse(path).getroot()
        source = root.findtext("compounddef/compoundname") or \
            os.path.basename(path)
        bucket = by_file.setdefault(source, {"function": set(),
                                             "variable": set()})
        for member in root.iter("memberdef"):
            kind = member.get("kind")
            name = member.findtext("name")
            if not name or kind not in ("function", "variable"):
                continue
            bucket[kind].add(name)
    return by_file


def is_private(name):
    return name.startswith("_")


def directive(kind, name):
    return ".. doxygen%s:: %s\n   :project: %s\n" % (kind, name, PROJECT)


def _members(by_file, kind, keep):
    """Flat sorted list of member names of ``kind`` matching predicate ``keep``."""
    names = set()
    for bucket in by_file.values():
        names.update(n for n in bucket[kind] if keep(n))
    return sorted(names)


def render_flat(title, intro, by_file, keep):
    """Render a page as flat Functions / Variables sections."""
    lines = [title, "=" * len(title), "", intro, ""]
    funcs = _members(by_file, "function", keep)
    variables = _members(by_file, "variable", keep)
    if funcs:
        lines += ["Functions", "---------", ""]
        for name in funcs:
            lines.append(directive("function", name))
    if variables:
        lines += ["Variables", "---------", ""]
        for name in variables:
            lines.append(directive("variable", name))
    return "\n".join(lines).rstrip() + "\n"


def render_by_file(title, intro, by_file, keep):
    """Render a page grouped by source file, each with Functions / Variables."""
    lines = [title, "=" * len(title), "", intro, ""]
    for source in sorted(by_file):
        bucket = by_file[source]
        funcs = sorted(n for n in bucket["function"] if keep(n))
        variables = sorted(n for n in bucket["variable"] if keep(n))
        if not funcs and not variables:
            continue
        lines += [source, "-" * len(source), ""]
        if funcs:
            lines += ["Functions", "~~~~~~~~~", ""]
            for name in funcs:
                lines.append(directive("function", name))
        if variables:
            lines += ["Variables", "~~~~~~~~~", ""]
            for name in variables:
                lines.append(directive("variable", name))
    return "\n".join(lines).rstrip() + "\n"


def main():
    if not os.path.isdir(XML_DIR):
        sys.exit("error: %s not found; run doxygen first" % XML_DIR)

    by_file = collect()
    os.makedirs(OUT_DIR, exist_ok=True)

    public = render_flat(
        "Public API",
        "The public API is the stable interface of Knit. These functions and\n"
        "variables have names without a leading underscore and are intended to\n"
        "remain backwards compatible across releases.",
        by_file, lambda n: not is_private(n))
    private = render_by_file(
        "Private API",
        "The private API consists of names with one or two leading underscores,\n"
        "grouped below by the source file that defines them. It is internal to\n"
        "Knit and may change at any time, without notice and without a\n"
        "compatibility guarantee.",
        by_file, is_private)

    with open(os.path.join(OUT_DIR, "public.rst"), "w") as handle:
        handle.write(public)
    with open(os.path.join(OUT_DIR, "private.rst"), "w") as handle:
        handle.write(private)

    pub_funcs = _members(by_file, "function", lambda n: not is_private(n))
    pub_vars = _members(by_file, "variable", lambda n: not is_private(n))
    prv_funcs = _members(by_file, "function", is_private)
    prv_vars = _members(by_file, "variable", is_private)
    print("Generated public.rst (%d functions, %d variables) and "
          "private.rst (%d functions, %d variables)."
          % (len(pub_funcs), len(pub_vars), len(prv_funcs), len(prv_vars)))


if __name__ == "__main__":
    main()
