..
   title: Register a shorthand
   categories: plugins
   order: 40
   description: Expose a decorator as an @-shorthand for the user's experiment.
   apis: knit_register_shorthand

``knit_register_shorthand`` defines an ``@``-shorthand that forwards to a
function, so a plugin can offer its decorator in the same ``@`` form as the
built-in decorators. The shorthand generator runs before a plugin loads, so a
plugin registers its own shorthand on demand:

.. knit-code:: /_code/plugin_author.sh
   :language: bash
   :start-after: # START shorthand
   :end-before: # END shorthand

The shorthand is a convenience for the *user's* experiment. Inside your own
``plugin.sh``, call the decorator by its canonical name (``demo_with_banner``),
not ``@with_banner``: a user can disable shorthands with ``KNIT_WITHOUT_SHORTHAND``,
which would leave the shorthand undefined and break your plugin as it loads.
``knit_register_shorthand`` honors that opt-out and rejects a token that a
built-in or another plugin already defines.
