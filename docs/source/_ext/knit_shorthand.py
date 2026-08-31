"""Convert Knit ``@`` shorthand source to the canonical long form.

This is a build-time port of the runtime logic in ``src/shorthand.sh``. The
documentation shows each Knit code sample in two forms: the authored shorthand
(``@command`` ...) and the canonical long form (``knit_register`` ...). Rather
than keep two hand-written copies, the long form is generated from the shorthand
by this module.

The conversion runs in the total direction only (shorthand to long form). The
shorthand's own rule guarantees the one thing the long form needs: a
name-extracting decorator (``@command``/``@app``/``@job``/``@setup``/
``@wrapper``) always sits directly above the function it decorates, so the
function name is always present in the source and is injected at argument
position 2.

The two token maps (``_KNIT_SHORTHAND_PASSTHROUGH`` and
``_KNIT_SHORTHAND_EXTRACTOR``) are parsed straight out of ``src/shorthand.sh``,
so the token to function mapping can never drift from the runtime.
"""

import os
import re


class ConversionError(Exception):
    """Raised when a shorthand source cannot be converted to long form."""


# A shorthand token at the start of a line: leading indent, "@", the token, and
# whatever follows on the line.
_TOKEN_LINE = re.compile(r"^(\s*)@([A-Za-z_][A-Za-z0-9_]*)(.*)$")

# Forward-scan patterns, ported from _knit_shorthand_find_function in
# src/shorthand.sh. Bash "[[:space:]]" becomes Python "\s"; "[^[:space:](){}]"
# becomes "[^\s(){}]".
_SCAN_EMPTY = re.compile(r"^\s*@empty(\s|$)")
_SCAN_FUNCTION_KW = re.compile(r"^\s*function\s+([^\s(){}]+)")
_SCAN_NAME_PAREN = re.compile(r"^\s*([^\s(){}]+)\s*\(\)")
_SCAN_DONE = re.compile(r"^\s*(@done|knit_done)(\s|;|$)")


def default_shorthand_source():
    """Return the path to ``src/shorthand.sh`` relative to this module."""
    here = os.path.dirname(os.path.abspath(__file__))
    # docs/source/_ext -> repository root -> src/shorthand.sh
    return os.path.normpath(os.path.join(here, "..", "..", "..", "src", "shorthand.sh"))


def _parse_map(text, name):
    """Parse a ``NAME=( [token]=target ... )`` bash associative-array literal.

    Returns a dict from token to target function name.
    """
    match = re.search(
        r"^" + re.escape(name) + r"=\((.*?)^\)",
        text,
        re.MULTILINE | re.DOTALL,
    )
    if not match:
        raise ConversionError(
            "could not find the {} map in the shorthand source".format(name)
        )
    result = {}
    for token, target in re.findall(r"\[([^\]]+)\]=(\S+)", match.group(1)):
        result[token] = target
    if not result:
        raise ConversionError("the {} map is empty".format(name))
    return result


def load_maps(source_path=None):
    """Load the pass-through and extractor token maps from ``src/shorthand.sh``.

    Returns ``(passthrough, extractor)``.
    """
    if source_path is None:
        source_path = default_shorthand_source()
    with open(source_path, "r") as handle:
        text = handle.read()
    passthrough = _parse_map(text, "_KNIT_SHORTHAND_PASSTHROUGH")
    extractor = _parse_map(text, "_KNIT_SHORTHAND_EXTRACTOR")
    return passthrough, extractor


def _split_first_arg(text):
    """Split the first shell word off ``text``, quote-aware.

    Returns ``(first, rest)`` where ``first`` is the verbatim first shell word
    (quotes kept) and ``rest`` is the remainder with its leading whitespace
    removed. Single and double quotes, and a backslash escape inside double
    quotes or when unquoted, are honoured the way the shell would.
    """
    length = len(text)
    i = 0
    while i < length and text[i] in " \t":
        i += 1
    if i >= length:
        return "", ""
    start = i
    quote = None
    while i < length:
        char = text[i]
        if quote is not None:
            if quote == '"' and char == "\\":
                i += 2
                continue
            if char == quote:
                quote = None
            i += 1
            continue
        if char in ("'", '"'):
            quote = char
            i += 1
            continue
        if char == "\\":
            i += 2
            continue
        if char in " \t":
            break
        i += 1
    return text[start:i], text[i:].lstrip(" \t")


def _find_function(lines, start):
    """Discover the function a register decorator decorates.

    Ports the forward scan of ``_knit_shorthand_find_function``: from index
    ``start``, skip blank/comment/decorator lines and return the first function
    name, or ``knit_empty`` for an ``@empty`` marker. The scan stops at a
    ``@done``/``knit_done`` marker or the end of the file.
    """
    for line in lines[start:]:
        if _SCAN_EMPTY.match(line):
            return "knit_empty"
        match = _SCAN_FUNCTION_KW.match(line)
        if match:
            return match.group(1)
        match = _SCAN_NAME_PAREN.match(line)
        if match:
            name = match.group(1)
            # Guard against a "@done"/"knit_done" written with parentheses being
            # mistaken for the body function.
            if name not in ("@done", "knit_done"):
                return name
        if _SCAN_DONE.match(line):
            break
    raise ConversionError(
        "no function definition or @empty marker found before the next "
        "@done or end of file"
    )


def convert_text(text, passthrough=None, extractor=None):
    """Convert shorthand source ``text`` to its long form.

    ``passthrough`` and ``extractor`` are the token maps; when omitted they are
    loaded from ``src/shorthand.sh``.
    """
    if passthrough is None or extractor is None:
        loaded_passthrough, loaded_extractor = load_maps()
        if passthrough is None:
            passthrough = loaded_passthrough
        if extractor is None:
            extractor = loaded_extractor

    lines = text.split("\n")
    out = []
    for index, line in enumerate(lines):
        match = _TOKEN_LINE.match(line)
        if not match:
            # A shebang, comment, region marker, function body, or any other
            # non-shorthand line passes through verbatim.
            out.append(line)
            continue

        indent, token, rest = match.group(1), match.group(2), match.group(3)

        if token == "empty":
            # A standalone @empty marker: the register call above already had
            # knit_empty injected, so the marker line is dropped.
            continue

        if token in extractor:
            name = _find_function(lines, index + 1)
            first, remainder = _split_first_arg(rest)
            pieces = [indent + extractor[token]]
            if first:
                pieces.append(first)
            pieces.append(name)
            if remainder:
                pieces.append(remainder)
            out.append(" ".join(pieces))
            continue

        if token in passthrough:
            out.append(indent + passthrough[token] + rest)
            continue

        # An "@" line whose token is not a known shorthand is not ours; leave it
        # untouched.
        out.append(line)

    return "\n".join(out)


# ----------------------------------------------------------------------------
# Self-test
#
# A fixture-based check that each conversion case is handled. Run with
# "python3 knit_shorthand.py --selftest" (invoked from maint/check-docs.sh).
# ----------------------------------------------------------------------------

_SELFTEST_INPUT = """\
#!/bin/bash

# A comment mentioning @empty must survive unchanged.
source knit.sh

# START register
@command "hello" "Print a greeting."
hello() {
    echo "Hello World"
}
@done

@command "todo" "Planned command, not implemented yet."
@empty
@done
# END register

@command "say:hello" "Say hello."
say_hello() {
    echo "Hello"
}
@done

@job "render" "Render as a job."
@with_setup "renderenv"
@with_optional "width:integer"    "800"    "Image width."
render() {
    echo "rendering"
}
@done

@app "ranks" "Print rank info."
function ranks {
    echo "rank"
}
@done

@setup "renderenv" "Build the renderer."
@empty
@done

@wrapper "spack" "Run spack."
spack_cmd() {
    echo "spack"
}
@done
"""

_SELFTEST_EXPECTED = """\
#!/bin/bash

# A comment mentioning @empty must survive unchanged.
source knit.sh

# START register
knit_register "hello" hello "Print a greeting."
hello() {
    echo "Hello World"
}
knit_done

knit_register "todo" knit_empty "Planned command, not implemented yet."
knit_done
# END register

knit_register "say:hello" say_hello "Say hello."
say_hello() {
    echo "Hello"
}
knit_done

knit_register_job "render" render "Render as a job."
knit_with_setup "renderenv"
knit_with_optional "width:integer"    "800"    "Image width."
render() {
    echo "rendering"
}
knit_done

knit_register_app "ranks" ranks "Print rank info."
function ranks {
    echo "rank"
}
knit_done

knit_register_setup "renderenv" knit_empty "Build the renderer."
knit_done

knit_register_wrapper "spack" spack_cmd "Run spack."
spack_cmd() {
    echo "spack"
}
knit_done
"""


def _selftest():
    failures = 0

    passthrough, extractor = load_maps()

    # The maps are single-sourced from src/shorthand.sh.
    def expect(condition, message):
        nonlocal failures
        if not condition:
            failures += 1
            print("  FAIL {}".format(message))

    expect(passthrough.get("done") == "knit_done", "passthrough[done] map entry")
    expect(passthrough.get("empty") == "knit_empty", "passthrough[empty] map entry")
    expect(
        passthrough.get("with_required") == "knit_with_required",
        "passthrough[with_required] map entry",
    )
    expect(extractor.get("command") == "knit_register", "extractor[command] map entry")
    expect(
        extractor.get("job") == "knit_register_job", "extractor[job] map entry"
    )
    expect(
        extractor.get("wrapper") == "knit_register_wrapper",
        "extractor[wrapper] map entry",
    )

    # Quote-aware first-argument split.
    expect(_split_first_arg(' "a b" rest') == ('"a b"', "rest"), "double-quoted first arg")
    expect(_split_first_arg(" 'a b' rest") == ("'a b'", "rest"), "single-quoted first arg")
    expect(_split_first_arg(" bare rest") == ("bare", "rest"), "bare first arg")
    expect(_split_first_arg(' "say:hello" "d"') == ('"say:hello"', '"d"'), "colon in first arg")
    expect(_split_first_arg("   ") == ("", ""), "whitespace only")

    # A malformed register (no function, no @empty) is a hard error.
    try:
        convert_text('@command "x" "d"\n@done\n', passthrough, extractor)
        expect(False, "missing body should raise ConversionError")
    except ConversionError:
        pass

    # The full fixture round-trips to the expected long form.
    result = convert_text(_SELFTEST_INPUT, passthrough, extractor)
    if result != _SELFTEST_EXPECTED:
        failures += 1
        print("  FAIL fixture conversion mismatch")
        expected_lines = _SELFTEST_EXPECTED.split("\n")
        result_lines = result.split("\n")
        for line_no, (want, got) in enumerate(zip(expected_lines, result_lines), 1):
            if want != got:
                print("    line {}:".format(line_no))
                print("      expected: {!r}".format(want))
                print("      actual:   {!r}".format(got))
        if len(expected_lines) != len(result_lines):
            print(
                "    line count differs: expected {}, actual {}".format(
                    len(expected_lines), len(result_lines)
                )
            )

    if failures:
        print("knit_shorthand selftest: {} failure(s)".format(failures))
        return 1
    print("knit_shorthand selftest: ok")
    return 0


if __name__ == "__main__":
    import sys

    if len(sys.argv) > 1 and sys.argv[1] == "--selftest":
        raise SystemExit(_selftest())
    sys.stderr.write("usage: {} --selftest\n".format(sys.argv[0]))
    raise SystemExit(2)
