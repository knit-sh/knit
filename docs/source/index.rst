Knit
====

.. image:: _static/knit-title-light.svg
   :class: only-light
   :alt: Knit
   :width: 100%

.. image:: _static/knit-title-dark.svg
   :class: only-dark
   :alt: Knit
   :width: 100%

Knit is a Bash framework for writing reproducible and portable HPC
(High-Performance Computing) experiments. It turns an ordinary shell script into
a self-documenting CLI whose every run is recorded, so results can be traced,
repeated, and moved from a laptop to a supercomputer without changing the code.

Objectives
----------

**Simplicity.** Write experiments as plain Bash: source knit.sh, register a
function as a command, declare its typed parameters, and Knit gives you a complete CLI ---
``--help``, validation, and logging --- for free.

**Reproducibility.** Every invocation is recorded --- its parameters, outputs,
timing, and the environment it ran in --- so an experiment can be replayed and
its results tied back to exactly how they were produced.

**Portability.** The same experiment script runs unchanged on your laptop and on
an HPC cluster; Knit detects the scheduler and MPI launcher, so only the machine
differs, never the code.

**Provenance.** Knit records *how* each result came to be --- which submission
ran which job, which job launched which run, which setup built the software ---
as a queryable graph you can trace after the fact.

The experimental model
----------------------

.. image:: _static/knit-arrow-light.svg
   :class: only-light
   :alt: Knit
   :width: 100%

.. image:: _static/knit-arrow-dark.svg
   :class: only-dark
   :alt: Knit
   :width: 100%

A Knit experiment moves through five stages. Each stage records what it did into
a database, so a later stage --- and a later reader --- can pick up exactly
what an earlier one produced.

* **Bootstrap**: downloads and installs what the Knit framework itself needs (e.g. sqlite3).
* **Setup**: builds a reproducible software environment (e.g., manual build, Spack environment, modules).
* **Submit**: queues a batch job on the scheduler or execute it locally, recording its state and hosts.
* **Run**: launches a parallel (MPI) application across a job's nodes.
* **Aggregate**: reads output from many jobs to produce publishable results.

The model is a *fan-out* from **bootstrap** to **run** (one bootstrap, multiple setups,
each used by multiple jobs, each running multiple applications) and a *fan-in* to **aggregate**.

Getting started
---------------

New to Knit? The :doc:`quickstart` writes and runs a one-command experiment in a
few minutes, and the :doc:`tutorial/index` grows a single real experiment from a
plain command into a Spack-backed, MPI-parallel, recorded workload.

The API is split by visibility, following Knit's underscore naming convention:
names without a leading underscore form the stable :doc:`api/public`, while
names with a leading underscore form the :doc:`api/private`, which may
change at any time.

.. toctree::
   :maxdepth: 1
   :caption: Guides

   quickstart
   tutorial/index
   stitch/index

.. toctree::
   :maxdepth: 1
   :caption: API Reference

   api/public
   api/private
