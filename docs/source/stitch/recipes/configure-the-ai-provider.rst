..
   title: Configure the AI provider
   categories: ai
   order: 10
   description: Point knit at an OpenAI-compatible AI provider with bootstrap --ai-* — storing only env-var names, never the key.
   apis: bootstrap

The ``ai`` commands talk to an OpenAI-compatible chat API. Before using them you
tell knit **which env vars** hold your provider's credentials and settings. You
configure this at bootstrap with the ``--ai-*`` options, which write the
``ai.*`` metadata:

.. code-block:: console

   $ ./exp.sh bootstrap --ai-api-key-env OPENAI_API_KEY --ai-model gpt-4o

Only env-var **names** and non-secret defaults are stored --- the API key itself
never reaches the database. At call time knit reads the value of the env var you
named, so the secret lives only in your shell:

.. code-block:: console

   $ export OPENAI_API_KEY=sk-...
   $ ./exp.sh ai ask --question "how many jobs completed?"

``--ai-api-key-env`` is the only required setting. The rest tune where the
request goes and which model answers, each with an env-var form (read at call
time) and a literal fallback (baked into metadata):

- ``--ai-base-url-env`` / ``--ai-base-url`` --- the endpoint. The env var wins if
  set, then the literal, then ``https://api.openai.com/v1``. Point these at any
  OpenAI-compatible gateway (Azure, a local server, a proxy).
- ``--ai-model-env`` / ``--ai-model`` --- the default model. A per-call
  ``--model`` on ``ai ask`` / ``ai query`` overrides both.

Re-running ``bootstrap`` updates only the ``ai.*`` options you type, so one field
(say the model) can change without clearing the rest:

.. code-block:: console

   $ ./exp.sh bootstrap --ai-model gpt-4o-mini

If the named key env var is empty or unset when you run an ``ai`` command, knit
fails with a clear message rather than calling out with no credentials. Like the
rest of the ``ai`` group, configuring the provider needs a bootstrapped
experiment. Once configured, ask a question (*Ask a natural-language question*)
or generate a query (*Answer with generated SQL*).
