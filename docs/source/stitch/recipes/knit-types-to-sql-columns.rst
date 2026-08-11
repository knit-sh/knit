..
   title: How knit types map to SQL columns
   categories: recording, types
   order: 30
   description: A recorded column's SQL affinity follows its knit type --- integer to INTEGER, real to REAL, everything else to TEXT.
   apis: knit_with_table, knit_with_output

When a command declares a table (see *Record invocations in a table*), knit
derives each column's SQL type from the knit type of the parameter, flag, or
output it records. The mapping is:

- ``integer`` (alias ``int``) → ``INTEGER``
- ``real`` (aliases ``float``, ``double``) → ``REAL``
- **everything else** → ``TEXT`` --- including ``string``, ``boolean``,
  ``path``, ``file``, ``filename``, ``date``, ``time``, ``datetime``, ``uuid``,
  and any enum you define.

Only ``integer`` and ``real`` get a numeric affinity, so numeric comparison and
aggregation (``SUM``, ``AVG``, ``ORDER BY``) work as expected on those columns.
Everything else is stored verbatim as text --- a ``boolean`` is the string
``true`` or ``false``, and a ``date``/``datetime`` is its literal string --- so
compare those as text or with SQLite's date functions.

The ``id`` column knit adds first is always ``TEXT`` (a uuid). Because the
mapping is by type, annotating a parameter or output well (see *Type-annotate a
parameter*) is what gives you a well-typed column: the ``add`` command in
*Record invocations in a table* declares ``x``, ``y``, and a ``total`` output
all as ``integer``, so those three columns are ``INTEGER`` and their sums are
numeric.
