..
   title: Declare an executable claim
   categories: claims
   order: 10
   description: State a plain-English finding as a @claim whose checker decides it against the recorded data and returns a three-valued verdict.
   apis: knit_register_claim, knit_with_optional, knit_with_output, knit_output, KNIT_CLAIM_HOLDS, KNIT_CLAIM_REFUTED, KNIT_CLAIM_INSUFFICIENT, claim:check, claim:list

A *claim* is a plain-English finding about your experiment, paired with a checker
that decides whether it holds against the recorded data. Declare one with
``@claim <name> "<statement>"``, then the usual ``@with_*`` declarations, the
checker function, and ``@done``:

.. knit-code:: /_code/claims.sh
   :language: bash
   :start-after: # START claim
   :end-before: # END claim

The statement is a **template**: each ``@token`` interpolates a condition
parameter or a measured output by name (``@{name}`` delimits a name that abuts
other text; ``@@`` is a literal ``@``). Condition parameters
(``@with_required`` / ``@with_optional``, here ``--floor``) bind the claim to one
slice; measured outputs (``@with_output``, here ``mean`` and ``n``) are the
quantities the checker computes with ``knit_output`` and the sentence reports.

The checker queries the database and ``return``\ s a **three-valued verdict**
through the ``KNIT_CLAIM_*`` constants rather than a bare number:

======================================  ==========  ==============
constant                                exit code   verdict
======================================  ==========  ==============
``KNIT_CLAIM_HOLDS``                     ``0``       holds
``KNIT_CLAIM_REFUTED``                   ``1``       refuted
``KNIT_CLAIM_INSUFFICIENT``              ``2``       not enough data
======================================  ==========  ==============

Evaluate a claim with ``claim check``, which runs the checker against the
**current** database, prints the statement with a verdict marker (green ``✓``,
red ``✗``, amber ``?``), and sets its exit code to the verdict:

.. code-block:: console

   $ ./exp.sh claim check -- mean-above --floor 0
   ✓ The mean sample is at least 0 (mean 2.0 over 3 samples).
   $ ./exp.sh claim check -- mean-above --floor 5
   ✗ The mean sample is at least 5 (mean 2.0 over 3 samples).

``claim check`` is **read-only** and stores nothing; add ``--record`` to also
persist the evaluation as one row in the claim's table (the resolved statement and
the verdict among the columns). ``claim list`` then shows the recorded findings,
grouped by claim and newest-first --- the manifest a reviewer re-checks ---
limited to one claim with ``--type``:

.. code-block:: console

   $ ./exp.sh claim check --record -- mean-above --floor 0
   $ ./exp.sh claim list --type mean-above
   mean-above
     ✓ The mean sample is at least 0 (mean 2.0 over 3 samples).  [floor=0]  ...

A claim never launches work: it observes and reports, so it is never a sweep or
optimization objective. A claim is evaluated only through ``claim check`` --- a
direct invocation of the subcommand is refused --- and a checker error (any exit
code other than ``0`` / ``1`` / ``2``) is reported distinctly and never stored as
a verdict.
