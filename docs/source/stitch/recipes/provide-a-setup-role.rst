..
   title: Provide a setup role
   categories: setup
   order: 25
   description: Let one job accept any of several interchangeable setups by naming a shared role.
   apis: knit_register_setup, knit_provides_setup_role, knit_with_setup

A job normally pins one exact setup *type*: ``@with_setup "cnnenv-cuda"`` accepts
only an instance built by the ``cnnenv-cuda`` setup. When several setups are
genuinely interchangeable for the job --- a CUDA environment on one machine, a CPU
environment on another, each putting the same program on ``PATH`` --- make them
equivalent by **role** rather than identical by type.

``knit_provides_setup_role`` declares that a setup's instances satisfy a named
role; the consumer then requires that role with the ordinary ``knit_with_setup``:

.. knit-code:: /_code/setup_roles.sh
   :language: bash
   :start-after: # START roles
   :end-before: # END roles

``@with_setup "cnnenv"`` now accepts any instance whose **type is** ``cnnenv`` *or*
which **provides the** ``cnnenv`` **role**, so the single ``train`` job runs under
either environment above: build the instance that fits each machine and submit the
same job against it. The ``used_by`` provenance edge still records the concrete
instance that was used, not the role, so provenance always names the real
environment.

A setup may call ``@provides_setup_role`` more than once to provide several roles.
Role names share the setup-type namespace and are matched the same way (hyphens
and underscores interchangeable). Existing experiments are unaffected: a setup that
provides no role matches only by type, exactly as before.
