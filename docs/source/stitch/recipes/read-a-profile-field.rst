..
   title: Read a profile field in a script
   categories: profiles
   order: 20
   description: Call knit_get_profile_field with a jq path to read any field from the bootstrapped machine profile inside a command body.
   apis: knit_get_profile_field, knit_list_profiles

Once a profile is frozen at bootstrap (see *Select a machine profile*), a
command body can read any of its fields with ``knit_get_profile_field`` and a jq
path expression:

.. knit-code:: /_code/profiles.sh
   :language: bash
   :start-after: # START field
   :end-before: # END field

Each call takes a jq path into the profile JSON (``.scheduler.type``,
``.hardware.cores_per_node``, ``.launcher.command``, ...) and prints the value,
with string quotes stripped. When the experiment was bootstrapped **without** a
profile, or the field is absent, it prints nothing --- so default it in the
caller, as above with ``${scheduler:-unknown}``. This lets a command adapt its
placement to the machine it is running on without hard-coding cluster details.

To enumerate the profiles knit knows about from a script (the same list the
``profile list`` command prints), call ``knit_list_profiles``; pass ``true`` to
include hidden ones.
