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
    """Return (functions, variables) as sorted name lists from the XML."""
    functions = set()
    variables = set()
    for path in sorted(glob.glob(os.path.join(XML_DIR, "*_8sh.xml"))):
        root = ET.parse(path).getroot()
        for member in root.iter("memberdef"):
            kind = member.get("kind")
            name = member.findtext("name")
            if not name:
                continue
            if kind == "function":
                functions.add(name)
            elif kind == "variable":
                variables.add(name)
    return functions, variables


def is_private(name):
    return name.startswith("_")


def directive(kind, name):
    return ".. doxygen%s:: %s\n   :project: %s\n" % (kind, name, PROJECT)


def render(title, intro, funcs, variables):
    lines = [title, "=" * len(title), "", intro, ""]
    if funcs:
        lines += ["Functions", "---------", ""]
        for name in sorted(funcs):
            lines.append(directive("function", name))
    if variables:
        lines += ["Variables", "---------", ""]
        for name in sorted(variables):
            lines.append(directive("variable", name))
    return "\n".join(lines).rstrip() + "\n"


def main():
    if not os.path.isdir(XML_DIR):
        sys.exit("error: %s not found; run doxygen first" % XML_DIR)

    functions, variables = collect()
    os.makedirs(OUT_DIR, exist_ok=True)

    pub_funcs = {n for n in functions if not is_private(n)}
    prv_funcs = {n for n in functions if is_private(n)}
    pub_vars = {n for n in variables if not is_private(n)}
    prv_vars = {n for n in variables if is_private(n)}

    public = render(
        "Public API",
        "The public API is the stable interface of Knit. These functions and\n"
        "variables have names without a leading underscore and are intended to\n"
        "remain backwards compatible across releases.",
        pub_funcs, pub_vars)
    private = render(
        "Private API",
        "The private API consists of names with one or two leading underscores.\n"
        "It is internal to Knit and may change at any time, without notice and\n"
        "without a compatibility guarantee.",
        prv_funcs, prv_vars)

    with open(os.path.join(OUT_DIR, "public.rst"), "w") as handle:
        handle.write(public)
    with open(os.path.join(OUT_DIR, "private.rst"), "w") as handle:
        handle.write(private)

    print("Generated public.rst (%d functions, %d variables) and "
          "private.rst (%d functions, %d variables)."
          % (len(pub_funcs), len(pub_vars), len(prv_funcs), len(prv_vars)))


if __name__ == "__main__":
    main()
