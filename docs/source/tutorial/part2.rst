Part II --- Refining the experiment
===================================

:doc:`Part I <part1>` built a complete experiment: a Spack-backed setup that
compiles ``julia-fractal``, a ``julia`` job that submits it, a ``render`` app
that launches it across MPI ranks, and the query, provenance, and AI surfaces on
top. It works end to end, on a laptop and on a supercomputer.

This second part returns to that *same* experiment and improves it, piece by
piece. It follows Part I's setup→run order, and each section takes one part of
the experiment you already understand and shows a Knit capability that makes it
cleaner, safer, or more reproducible. Because you already know the experiment as
a whole, each section can say "remember this from Part I? here is the better
way." Nothing here is a new experiment --- it is the *same* one, refined.

You do not need to retype anything: each section shows the change against the
Part I code, and the finished Part II experiment is collected in one file at the
end.

What we refine, in order:

- **The setup** --- fetch the source as a recorded **resource** instead of
  cloning it inline.
- **The job and the app** --- declare their shared parameters once as a
  **parameter set** instead of repeating them.
- **The** ``colormap`` **parameter** --- give it a real, validated **enum** type
  instead of a free-form string.
- **The PNG** --- record it as a checksummed **file output**, a verified
  intermediate that is not a packaged artifact.
- **The** ``aggregate`` **command** --- evolve it to build a CSV with a graph
  query and declare that CSV the experiment's **result and artifact**.
- **The sweep** --- turn Part I's hand-written batch into a reviewable
  **prepare** plan.
- **Cleanup** --- **remove** the runs, jobs, and artifacts you no longer need,
  cascading through everything that depended on them.
