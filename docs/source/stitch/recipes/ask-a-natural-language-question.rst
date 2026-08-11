..
   title: Ask a natural-language question
   categories: ai
   order: 20
   description: Ask ai ask a plain-English question; the model answers by calling knit's read-only introspection tools — it can inspect, never mutate.
   apis: ai:ask

Once a provider is configured (*Configure the AI provider*), ``ai ask`` answers a
plain-English question about **this** experiment. The model runs an agentic loop,
answering by calling a fixed set of **read-only knit commands** exposed to it as
tools --- it can ``describe`` the command tree, read a command's ``--help``, run a
read-only SQL query over the recorded run/job tables, read a job's captured output
(``job show``), and show metadata (``metadata show``):

.. code-block:: console

   $ export OPENAI_API_KEY=sk-...
   $ ./exp.sh ai ask --question "which job used the most nodes, and did it finish?"

The tools are real knit commands --- a recordable one records exactly as if you
had run it --- but the set is deliberately limited to **read-only** commands:
there is no arbitrary-command tool, so ``ai ask`` can inspect the experiment but
cannot run a command that mutates state. Its answer is grounded in what those
tools return, not invented --- the system prompt seeds it with a summary of your
commands and tells it to call a tool when unsure.

A few options tune the call:

- ``--model`` overrides the configured default model for this one question.
- ``--max-iterations`` caps the agentic tool-call rounds (default ``8``).
- ``--system`` replaces the built-in system prompt wholesale --- use it to change
  the assistant's persona or house rules.
- ``--verbose`` streams each tool call and result to stderr, so you can watch the
  model's reasoning; ``--raw`` prints the raw final-message JSON instead of just
  the answer text.

``ai ask`` reasons over several tools and replies in prose. When you want tabular
data back from a single query instead, use *Answer with generated SQL*.
