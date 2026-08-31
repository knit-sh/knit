..
   title: Pass opaque trailing arguments
   categories: parameters
   order: 50
   description: Accept arbitrary arguments after -- and read them in the body.
   apis: knit_with_extra, knit_extra_index

To let a command accept arbitrary arguments after ``--`` (for example to forward
them to another program), document them with ``knit_with_extra`` and read them in
the body starting at ``knit_extra_index``:

.. knit-code:: /_code/parameters.sh
   :language: bash
   :start-after: # START extra
   :end-before: # END extra

``knit_extra_index`` returns the index of the first argument after ``--`` (or the
argument count when there is no ``--``), so ``"${args[@]:extra_index}"`` is
exactly the trailing arguments. They are passed through verbatim and are not
validated against the command's declared parameters.

.. warning::

   Use trailing arguments sparingly. Unlike declared parameters, they are not
   broken out into their own database columns — they are recorded as one opaque
   blob — so you cannot cleanly filter or group runs by them afterwards. When a
   value has a known meaning, prefer a named parameter with ``knit_with_required``
   / ``knit_with_optional`` so it lands in its own column.
