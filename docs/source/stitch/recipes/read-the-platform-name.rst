..
   title: Read the platform name in a script
   categories: profiles
   order: 25
   description: Call knit_platform_name to get the human-facing name of the machine the experiment was bootstrapped for.
   apis: knit_platform_name

Every bootstrapped experiment records a **platform name** --- a short,
human-facing label for the machine it runs on. Read it from a command body with
``knit_platform_name``:

.. literalinclude:: /_code/profiles.sh
   :language: bash
   :start-after: # START platform
   :end-before: # END platform

The name is set at bootstrap. Pass it explicitly with ``--platform``::

   $ ./exp.sh bootstrap --platform mymachine

When you bootstrap with a machine profile (see *Select a machine profile*) and
omit ``--platform``, the name defaults to the profile's own name --- e.g.
``anl/polaris`` for the Polaris profile --- so a profile-based experiment
self-identifies without extra flags. ``knit_platform_name`` prints an empty
string when no platform was recorded.
