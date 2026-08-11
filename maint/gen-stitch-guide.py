#!/usr/bin/env python3
"""Generate the Stitch Guide (cookbook) reStructuredText pages for the Knit docs.

Reads the recipe fragments in docs/source/stitch/recipes/*.rst and the category
registry docs/source/stitch/categories.toml, then emits, per category, an
assembled page docs/source/stitch/_categories/<slug>.rst (each recipe inlined via
``.. include::``) plus the guide landing page docs/source/stitch/index.rst.

A recipe is a heading-less rST fragment whose metadata lives in a leading ``..``
comment block, one ``key: value`` per line:

    ..
       title: Register a setup
       categories: setup, spack
       order: 10
       description: One-line summary of what the recipe teaches.
       apis: knit_register_setup, knit_with_spack_specs

``title``, ``categories``, and ``description`` are required; ``order`` (default
0) and ``apis`` are optional. A recipe may name several categories and is then
inlined on each of their pages.

This script uses only the Python standard library (tomllib is stdlib in Python
3.11+) and is invoked by `make docs`. Its outputs are git-ignored, exactly like
the API pages produced by gen-doc-api.py.
"""
import glob
import os
import sys
import tomllib
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.realpath(__file__))
ROOT = os.path.dirname(HERE)
STITCH_DIR = os.path.join(ROOT, "docs", "source", "stitch")
RECIPES_DIR = os.path.join(STITCH_DIR, "recipes")
CATEGORIES_TOML = os.path.join(STITCH_DIR, "categories.toml")
OUT_CATEGORIES_DIR = os.path.join(STITCH_DIR, "_categories")
OUT_INDEX = os.path.join(STITCH_DIR, "index.rst")
# Doxygen XML (the same source gen-doc-api.py reads) is used to sanity-check the
# `apis:` field. In the `make docs` ordering Doxygen runs first, so this exists;
# when the generator is run standalone it may be absent, in which case the check
# is skipped.
XML_DIR = os.path.join(ROOT, "docs", "doxygen", "xml")

REQUIRED_KEYS = ("title", "categories", "description")


def load_categories():
    """Load the category registry: ordered ``[(slug, title, summary)]`` + intro."""
    with open(CATEGORIES_TOML, "rb") as handle:
        data = tomllib.load(handle)
    categories = [(c["slug"], c["title"], c.get("summary", ""))
                  for c in data.get("category", [])]
    return categories, data.get("intro", "").strip()


def load_known_symbols():
    """Return the set of Knit function/variable names from the Doxygen XML, or
    ``None`` if the XML has not been generated (so the ``apis`` check is skipped).
    """
    if not os.path.isdir(XML_DIR):
        return None
    names = set()
    for path in glob.glob(os.path.join(XML_DIR, "*_8sh.xml")):
        root = ET.parse(path).getroot()
        for member in root.iter("memberdef"):
            if member.get("kind") in ("function", "variable"):
                name = member.findtext("name")
                if name:
                    names.add(name)
    return names


def parse_metadata(path):
    """Parse the leading ``..`` comment block of a recipe into a metadata dict.

    Returns the raw ``{key: value}`` mapping (values are strings). Raises
    ``ValueError`` if the file does not open with a ``..`` comment block.
    """
    with open(path) as handle:
        lines = handle.read().splitlines()
    index = 0
    while index < len(lines) and not lines[index].strip():
        index += 1
    if index >= len(lines) or lines[index].strip() != "..":
        raise ValueError("no leading '..' metadata comment")
    meta = {}
    index += 1
    while index < len(lines):
        line = lines[index]
        if not line.strip() or not line[:1].isspace():
            break
        key, sep, value = line.strip().partition(":")
        if sep:
            meta[key.strip()] = value.strip()
        index += 1
    return meta


def collect_recipes(valid_slugs):
    """Parse and validate every recipe. Returns ``[recipe_dict]``.

    Each recipe dict has ``file`` (basename without extension), ``title``,
    ``categories`` (list of slugs), ``description``, ``apis`` (list), and
    ``order`` (int). Any hard error appends to the returned error list; the
    caller aborts if it is non-empty.
    """
    recipes = []
    errors = []
    for path in sorted(glob.glob(os.path.join(RECIPES_DIR, "*.rst"))):
        name = os.path.splitext(os.path.basename(path))[0]
        try:
            meta = parse_metadata(path)
        except ValueError as exc:
            errors.append("%s: %s" % (name, exc))
            continue
        missing = [key for key in REQUIRED_KEYS if not meta.get(key)]
        if missing:
            errors.append("%s: missing required key(s): %s"
                          % (name, ", ".join(missing)))
            continue
        categories = [slug.strip() for slug in meta["categories"].split(",")
                      if slug.strip()]
        unknown = [slug for slug in categories if slug not in valid_slugs]
        if unknown:
            errors.append("%s: unknown category slug(s): %s"
                          % (name, ", ".join(unknown)))
        try:
            order = int(meta.get("order", "0"))
        except ValueError:
            errors.append("%s: order is not an integer: %r"
                          % (name, meta.get("order")))
            order = 0
        apis = [api.strip() for api in meta.get("apis", "").split(",")
                if api.strip()]
        recipes.append({
            "file": name,
            "title": meta["title"],
            "categories": categories,
            "description": meta["description"],
            "apis": apis,
            "order": order,
        })
    return recipes, errors


def underline(text, char):
    return "%s\n%s" % (text, char * len(text))


def render_category(title, summary, recipes):
    """Render one category page: title + summary, then each recipe inlined."""
    lines = [underline(title, "="), ""]
    if summary:
        lines += [summary, ""]
    for recipe in sorted(recipes, key=lambda r: (r["order"], r["title"])):
        lines.append(underline(recipe["title"], "-"))
        lines.append("")
        lines.append("*%s*" % recipe["description"])
        if recipe["apis"]:
            apis = ", ".join("``%s``" % api for api in recipe["apis"])
            lines.append("")
            lines.append("**APIs:** %s" % apis)
        lines.append("")
        lines.append(".. include:: /stitch/recipes/%s.rst" % recipe["file"])
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def render_index(intro, categories):
    """Render the guide landing page: intro + a toctree of category pages."""
    lines = [underline("Stitch Guide", "="), ""]
    if intro:
        lines += [intro, ""]
    lines += [".. toctree::", "   :maxdepth: 1", ""]
    for slug, _title, _summary in categories:
        lines.append("   _categories/%s" % slug)
    return "\n".join(lines).rstrip() + "\n"


def main():
    if not os.path.isfile(CATEGORIES_TOML):
        sys.exit("error: %s not found" % CATEGORIES_TOML)

    categories, intro = load_categories()
    valid_slugs = {slug for slug, _title, _summary in categories}
    recipes, errors = collect_recipes(valid_slugs)
    if errors:
        for message in errors:
            print("error: %s" % message, file=sys.stderr)
        sys.exit(1)

    # Sanity-check the apis field against the known Knit symbol set (soft: a
    # stale/typo'd name warns but does not fail the build). Skipped silently when
    # the Doxygen XML is absent (e.g. a standalone run before `make docs`).
    known = load_known_symbols()
    if known is not None:
        for recipe in recipes:
            for api in recipe["apis"]:
                if api not in known:
                    print("warning: %s: apis entry is not a known Knit symbol: "
                          "%s" % (recipe["file"], api), file=sys.stderr)

    # Group recipes by category (a recipe may appear in several).
    by_slug = {slug: [] for slug in valid_slugs}
    for recipe in recipes:
        for slug in recipe["categories"]:
            by_slug[slug].append(recipe)

    # A declared category with no recipes is a warning, not an error.
    for slug, _title, _summary in categories:
        if not by_slug[slug]:
            print("warning: category %r has no recipes" % slug,
                  file=sys.stderr)

    # Regenerate _categories/ from scratch so a removed category leaves no
    # stale page behind.
    if os.path.isdir(OUT_CATEGORIES_DIR):
        for stale in glob.glob(os.path.join(OUT_CATEGORIES_DIR, "*.rst")):
            os.remove(stale)
    os.makedirs(OUT_CATEGORIES_DIR, exist_ok=True)

    for slug, title, summary in categories:
        page = render_category(title, summary, by_slug[slug])
        with open(os.path.join(OUT_CATEGORIES_DIR, "%s.rst" % slug),
                  "w") as handle:
            handle.write(page)

    with open(OUT_INDEX, "w") as handle:
        handle.write(render_index(intro, categories))

    print("Generated stitch guide: %d recipe(s) across %d categor%s."
          % (len(recipes), len(categories),
             "y" if len(categories) == 1 else "ies"))


if __name__ == "__main__":
    main()
