..
   title: Store and read experiment metadata
   categories: metadata
   order: 10
   description: Use metadata store/load/show to keep experiment-wide key/value notes in the metadata table.
   apis: metadata:store, metadata:load, metadata:show

The **metadata** table holds experiment-wide key/value pairs --- a single place
for facts about the whole experiment (a dataset version, a paper's figure label,
a git revision) rather than about one invocation. Store, read one back, and dump
them all:

.. code-block:: console

   $ ./exp.sh metadata store --key dataset --value cifar-10
   $ ./exp.sh metadata load --key dataset
   cifar-10
   $ ./exp.sh metadata show
   key      value
   -------  --------
   dataset  cifar-10

Storing an existing key fails on the table's uniqueness constraint; pass
``--force`` to overwrite it:

.. code-block:: console

   $ ./exp.sh metadata store --force --key dataset --value cifar-100

``metadata load`` prints just the value (empty when the key is absent), which
makes it easy to capture in a script: ``rev="$(./exp.sh metadata load --key
dataset)"``. ``metadata show`` also lists knit's own bootstrap metadata --- the
``__project__``, ``__scheduler__``, ``__profile_json__``, and similar
double-underscore keys frozen at bootstrap --- alongside your own. All three
commands need a bootstrapped experiment.
