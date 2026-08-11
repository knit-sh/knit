..
   title: Type-annotate a parameter
   categories: types
   order: 10
   description: Give a parameter a type so knit validates its value automatically.
   apis: knit_with_required, knit_with_optional, knit_type_check

Every parameter carries a ``name:type`` annotation. The type is not just
documentation: knit validates the value against it before the body runs and
rejects a mismatch with a clear error. The type also chooses the parameter's
database column affinity (``integer`` → ``INTEGER``, ``real`` → ``REAL``,
everything else → ``TEXT``).

.. literalinclude:: /_code/types.sh
   :language: bash
   :start-after: # START annotate
   :end-before: # END annotate

Calling ``resize --width big`` fails with *Parameter --width of "resize" expects
a value of type "integer" (got "big")* — the body never runs. The built-in types
are ``integer``, ``real``, ``boolean``, ``string``, ``path``, ``file``,
``filename``, ``date``, ``time``, ``datetime``, and ``uuid``, plus the aliases
``int`` (→ ``integer``), ``float``/``double`` (→ ``real``), and ``bool``
(→ ``boolean``). A flag declared with ``knit_with_flag`` is implicitly
``boolean`` and takes no annotation.

When a value does *not* come from a declared parameter — a computed value, an
environment variable, or a trailing argument — validate it yourself with
``knit_type_check <type> <value>``, which returns success (0) or failure (1):

.. literalinclude:: /_code/types.sh
   :language: bash
   :start-after: # START type-check
   :end-before: # END type-check
