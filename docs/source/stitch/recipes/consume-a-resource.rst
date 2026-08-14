..
   title: Consume a resource in a command
   categories: resources
   order: 30
   description: Declare a resource dependency with knit_with_resource and resolve it with knit_resource_path.
   apis: knit_with_resource, knit_resource_path

A command declares the resources it needs with ``knit_with_resource
"<param>:<type>"``. The value the user passes is the instance *name*; knit checks
that the named instance exists and is of the declared type before the body runs,
then records a ``used_by`` provenance edge from the resource to the command.
Inside the body, ``knit_resource_path`` turns the name into an on-disk path.

.. literalinclude:: /_code/resources.sh
   :language: bash
   :start-after: # START consume
   :end-before: # END consume

Any command can depend on a resource --- including a setup, which is the usual
place to *process* a fetched artifact (build fetched source, index a dataset).
The user supplies the instance name on the command line, e.g. ``./exp.sh
summarize --data sample``.
