..
   title: Default a parameter from the environment
   categories: parameters
   order: 30
   description: Fall back to an environment variable when a parameter is omitted.
   apis: knit_with_optional

Write an optional parameter's default as ``ENV[NAME]`` to fall back to the
``NAME`` environment variable when the caller does not pass the parameter (empty
when ``NAME`` is unset):

.. knit-code:: /_code/parameters.sh
   :language: bash
   :start-after: # START env-default
   :end-before: # END env-default

The fallback is resolved when the parameter is filled in, not at registration, so
a job picks up a value exported by its setup's environment. An explicit ``--seed``
on the command line always wins over the environment, so ``./exp.sh roll --seed
42`` and ``SEED=42 ./exp.sh roll`` are equivalent — the flag is just a way to set
the same value inline.
