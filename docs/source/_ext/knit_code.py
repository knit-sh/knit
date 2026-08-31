"""Sphinx directive ``knit-code``: a shorthand / long-form snippet toggle.

Knit code samples are authored once, in the ``@`` shorthand, under
``docs/source/_code``. The canonical long form (``knit_*``) is generated from
them into ``docs/source/_code_long`` (see :mod:`knit_shorthand`). This directive
shows both, so a reader can switch between the terse decorator style and the
explicit API with one control.

``knit-code`` subclasses Sphinx's ``literalinclude``, so it reads the same
options (``:language:``, ``:start-after:``, ``:end-before:``, ...) and resolves
paths the same way. For each directive it renders the requested region from the
shorthand file and, with the same options, from the matching long-form file
(the leading ``_code`` path component is swapped to ``_code_long``). When the two
regions are identical --- a snippet with no ``@`` shorthand --- a single plain
block is shown. Otherwise the two blocks are wrapped in a ``sphinx-design``
tab-set whose tabs synchronize across the whole page (``:sync:`` keys), so the
reader picks a form once and every example follows.

The long-form tree is (re)generated at the start of every Sphinx build through a
``config-inited`` handler, so a bare ``sphinx-build`` produces it.
"""

import os

from docutils import nodes
from docutils.statemachine import StringList
from sphinx.directives.code import LiteralInclude

from knit_shorthand import generate_longform_tree

# The path component that marks the shorthand tree, and its long-form twin. A
# directive argument such as ``/_code/quickstart.sh`` is mapped to
# ``/_code_long/quickstart.sh`` by swapping the first of these components.
_SHORT_COMPONENT = "_code"
_LONG_COMPONENT = "_code_long"


class KnitCode(LiteralInclude):
    """A ``literalinclude`` that shows a snippet in shorthand and long form."""

    def run(self):
        short_arg = self.arguments[0]
        long_arg = self._longform_argument(short_arg)

        # Always render the shorthand region with the base machinery; it is the
        # authored source and the fallback if no long form exists.
        short_nodes = self._render(short_arg)

        # The long-form tree is generated at build start, so the twin file
        # normally exists. If it does not, degrade to the shorthand block alone
        # rather than fail the build.
        _, long_abspath = self.env.relfn2path(long_arg)
        if not os.path.isfile(long_abspath):
            return short_nodes

        long_nodes = self._render(long_arg)

        # A snippet with no "@" shorthand converts to identical text; show one
        # plain block instead of a degenerate pair of identical tabs.
        if self._text_of(short_nodes) == self._text_of(long_nodes):
            return short_nodes

        return self._tab_set(short_arg, long_arg)

    # ------------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------------
    def _longform_argument(self, arg):
        """Map a ``_code`` include path to its ``_code_long`` twin.

        Only the first path component equal to ``_code`` is swapped, so a
        leading-slash path (``/_code/x.sh``) and a relative path (``_code/x.sh``)
        both map correctly and a filename that merely contains ``_code`` is left
        alone.
        """
        parts = arg.split("/")
        for index, part in enumerate(parts):
            if part == _SHORT_COMPONENT:
                parts[index] = _LONG_COMPONENT
                break
        return "/".join(parts)

    def _render(self, arg):
        """Run the base ``literalinclude`` for ``arg`` and return its nodes."""
        saved = self.arguments[0]
        self.arguments[0] = arg
        try:
            return super().run()
        finally:
            self.arguments[0] = saved

    def _text_of(self, result):
        """Return the code text of the first literal block in ``result``."""
        for node in result:
            for block in node.findall(nodes.literal_block):
                return block.astext()
        return None

    def _tab_set(self, short_arg, long_arg):
        """Build a synchronized Shorthand / Long form tab-set.

        The tab-set is authored as reStructuredText and parsed, so
        ``sphinx-design`` produces its own markup and synchronization; each tab
        re-runs ``literalinclude`` with this directive's options, so region
        slicing and highlighting stay identical to a plain include.
        """
        lines = [".. tab-set::", ""]
        lines += self._tab_item("Shorthand", "knit-short", short_arg)
        lines += self._tab_item("Long form", "knit-long", long_arg)

        container = nodes.Element()
        content = StringList(lines, source="knit-code")
        self.state.nested_parse(content, self.content_offset, container)
        return container.children

    def _tab_item(self, label, sync, arg):
        """Return the reStructuredText lines for one tab of the tab-set."""
        item = [
            "   .. tab-item:: {}".format(label),
            "      :sync: {}".format(sync),
            "",
        ]
        item.append("      .. literalinclude:: {}".format(arg))
        for key, value in self.options.items():
            if value is None:
                item.append("         :{}:".format(key))
            else:
                item.append("         :{}: {}".format(key, value))
        item.append("")
        return item


def _generate_longform_tree(app, config):
    """Regenerate ``_code_long`` from ``_code`` at the start of the build."""
    source = os.path.join(app.srcdir, _SHORT_COMPONENT)
    output = os.path.join(app.srcdir, _LONG_COMPONENT)
    generate_longform_tree(source, output)


def setup(app):
    # sphinx-design supplies the tab-set / tab-item directives this one emits.
    app.setup_extension("sphinx_design")
    app.add_directive("knit-code", KnitCode)
    app.connect("config-inited", _generate_longform_tree)
    return {
        "version": "1.0",
        "parallel_read_safe": True,
        "parallel_write_safe": True,
    }
