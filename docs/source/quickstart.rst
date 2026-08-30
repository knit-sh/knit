Quickstart
==========

This page takes you from zero to a recorded command in a few minutes. You will
grow a small experiment one command at a time, run each command, and end with a
run stored in a database --- the foundation everything else in Knit builds on.

An experiment is a script
-------------------------

A Knit experiment is an ordinary Bash script (we will call it ``exp.sh``
hereafter). It sources ``knit.sh`` (kept next to the script), describes itself,
registers one or more commands, and ends with the single line ``knit "$@"`` that
hands the command line to Knit:

.. literalinclude:: _code/quickstart.sh
   :language: bash
   :start-after: # START run
   :end-before: # END run

``@set_program_description`` sets the blurb shown at the top of ``--help``.
Everything between the ``source`` line and the final ``knit "$@"`` registers the
commands your experiment offers.

.. note::

   ``@set_program_description`` --- and ``@command``, ``@done``, and the
   ``@with_*`` decorators you meet below --- are Knit's **shorthand** for its
   declaration API. Every ``knit_x`` declaration function has an ``@x`` twin
   (``knit_register`` is written ``@command`` and ``knit_register_<x>`` is written
   ``@<x>``). The shorthand is enabled by default and is what this documentation
   uses; the canonical ``knit_*`` functions remain available and unchanged. See
   the project ``README`` for the full mapping and how to opt out.

Running ``./exp.sh --help`` already works and shows a handful of built-in
commands, along with your experiment's description as set above. The commands you
register below will appear in that same listing.

Your first command
------------------

A command is declared with ``@command <name> <description>`` and closed with
``@done``; in between go its parameters (none yet) and the Bash function Knit runs
for the command. The ``<name>`` is the command as typed on the command line, and
Knit calls the function it finds defined just below the declaration --- so you
never repeat the function's name. Here is a command that just prints a greeting:

.. literalinclude:: _code/quickstart.sh
   :language: bash
   :start-after: # START hello
   :end-before: # END hello

Before running any command, bootstrap the experiment once. This creates a
``.knit/`` directory holding a small SQLite database (and, if they are not
already on your system, installs the tools Knit relies on):

.. code-block:: console

   $ ./exp.sh bootstrap

Now run the command:

.. code-block:: console

   $ ./exp.sh hello
   Hello World

Taking a parameter
------------------

Parameters are declared between ``@command`` and ``@done``.
``@with_required "name:type" <description>`` adds a required one.
Inside the body, we can read it back with ``knit_get_parameter``:

.. literalinclude:: _code/quickstart.sh
   :language: bash
   :start-after: # START say
   :end-before: # END say

The parameter ``message`` becomes ``--message`` on the command line:

.. code-block:: console

   $ ./exp.sh say --message "good morning"
   User said 'good morning'

Try ``./exp.sh say --help`` to see the parameter, its type, and description laid
out for you.

Parameter names accept hyphens and underscores interchangeably, (so ``my-param``
and ``my_param`` represent the same parameter) and the type
vocabulary includes ``integer``, ``real``, ``string``, ``boolean`` and ``uuid``.

Optional parameters and flags
-----------------------------

Beyond required parameters, a command can take optional parameters (with a
default) and boolean flags. ``@with_optional "name:type" <default>
<description>`` supplies a default used when the parameter is omitted;
``@with_flag <name> <description>`` adds a switch that reads back as
``true`` or ``false``:

.. literalinclude:: _code/quickstart.sh
   :language: bash
   :start-after: # START greet
   :end-before: # END greet

``--name`` is required, ``--title`` defaults to empty, and ``--capitalize`` is
off unless given:

.. code-block:: console

   $ ./exp.sh greet --name Alice
   Hello, Alice!
   $ ./exp.sh greet --name Curie --title Prof.
   Hello, Prof. Curie!
   $ ./exp.sh greet --name Curie --title Prof. --capitalize
   HELLO, PROF. CURIE!

Emitting an output
------------------

A command can declare one or more **outputs**: a named, typed result it computes.
``@with_output "name:type" <default> <description>`` declares it (the default
is used if the command exits before setting it), and ``knit_output <name>
<value>`` emits it from the body:

.. literalinclude:: _code/quickstart.sh
   :language: bash
   :start-after: # START scale
   :end-before: # END scale

.. code-block:: console

   $ ./exp.sh scale --value 21
   result=42
   $ ./exp.sh scale --value 10 --factor 5
   result=50

Recording runs in a table
-------------------------

Declaring an output gives a run a result, but as written above, this result is not
stored anywhere. Adding ``@with_table`` tells Knit to **record** every invocation
--- its parameters and outputs, plus some informations --- as a row in a
per-command table. Here is a command with two required parameters, an output, and
a table:

.. literalinclude:: _code/quickstart.sh
   :language: bash
   :start-after: # START add
   :end-before: # END add

Each time ``add`` runs, Knit writes one row into an ``add`` table:

.. code-block:: console

   $ ./exp.sh add --x 2 --y 3
   total=5

Read the recorded rows straight back out with SQL, or list every table and its
columns with the catalog:

.. code-block:: console

   $ ./exp.sh query sql --format column --header \
       --exec 'SELECT x, y, total FROM "add"'
   $ ./exp.sh query catalog

.. note::

   Recording is the first step of Knit's full model
   (*bootstrap → setup → submit → run → analyze*). The **Basic Usage** guide
   picks up here and shows how to build environments, submit jobs, launch
   parallel apps, and aggregate their recorded results.
