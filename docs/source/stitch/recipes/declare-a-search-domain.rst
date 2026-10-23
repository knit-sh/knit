..
   title: Declare a parameter's search domain
   categories: parameters, search
   order: 40
   description: Attach a value set or range to a parameter with --domain for sweeps and optimization.
   apis: knit_with_optional, knit_with_required, knit_parameter_space, knit_parameter_space_json

A tunable parameter can carry a **search domain** --- the set or range of values
a parameter sweep or a Bayesian-optimization run may explore. Declare it with
``--domain <descriptor>`` on ``knit_with_optional`` / ``knit_with_required``,
quoting the descriptor so the shell does not brace-expand it:

.. knit-code:: /_code/search_domain.sh
   :language: bash
   :start-after: # START domain
   :end-before: # END domain

The descriptor grammar is one set of literals: ``{a,b,c}`` is a value list,
``[lo..hi]`` / ``[lo..hi:step]`` a range, ``@glob:<pattern>`` a filesystem glob,
and ``@file:<path>`` one value per line. ``--log`` adds a log-scale hint to a real
range (a Bayesian-optimization proposer reads it; a sweep ignores it). The domain
must match the parameter's type --- a range needs ``integer`` or ``real``, a glob
needs ``string``, a list suits any type --- and it is validated the first time it
is read, not at registration, so a type mismatch surfaces at first use.

Discover the declared domains of a command with ``knit describe --space``, which
annotates each parameter with its domain (and emits a structured ``space`` object
in the JSON and YAML formats). A search proposer reads the same domains
programmatically through ``knit_parameter_space`` (structured, by nameref) and
``knit_parameter_space_json``.
