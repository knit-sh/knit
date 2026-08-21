# Knit agent skills and commands

This tree holds the **skills** and **commands** that let an external AI harness
(Claude Code CLI is the reference) drive Knit: write a machine profile, author an
experiment, plan and run a sweep, and analyze the results.

Knit already ships **in-knit AI** — `knit ai ask` and `knit ai query` — which is
read-only and answers one question about the experiment. The files here are the
other tier: elaborate, multi-step, and able to mutate (write files, submit jobs).
That work runs in the user's own harness, under the user's permissions. Knit's job
is to make itself legible and safe to drive from one.

## Layout

```
agent/
  skills/<name>/
    SKILL.md          # the skill: YAML frontmatter + Markdown body
    <extra files>     # optional bundled scripts or resources
  commands/<name>.md  # a thin slash-command entry point that loads a skill
  AGENTS.md           # project pointer dropped at the project root on install
```

- **Skills** are the durable know-how. A harness loads a skill when its
  `description` matches the task.
- **Commands** are thin. Each one frames intent, gathers a few arguments, and
  loads the matching skill. The reusable knowledge lives in the skill so a typed
  command and an autonomous agent use the same source.

## Format

Skills use the open Agent Skills format: a `SKILL.md` file that starts with YAML
frontmatter and continues with a Markdown body.

```markdown
---
name: using-knit
description: One line that says when to load this skill. The harness reads only
  this until the body is needed (progressive disclosure), so make it specific.
---

# <Title>

<the body — concepts and workflow>
```

- `name` — the skill slug (matches the directory name).
- `description` — one line. It is the only text a harness reads until it decides
  to open the body, so it must state *when* to use the skill.

Keep the body focused on the durable mental model and the workflow. Do **not**
hardcode the command list — an agent reads the live surface at runtime with
`knit describe`, `knit query`, and per-command `--help`. This keeps the skills
correct as an experiment grows and as Knit itself changes.

## Two conventions every skill follows

1. **Discovery over hardcoding.** State concepts, not inventories. Point the agent
   at `knit describe` / `--help` / `knit query` for the exact, current surface.
2. **Autonomy posture.** Each skill declares how it treats an absent user:
   - **Ask-first** — for authoring and onboarding, where a wrong guess is costly
     and hard to detect. The skill tells the agent to *ask the user* rather than
     guess a missing fact (a module name, an account, a node limit, the study's
     real intent).
   - **Autonomous** — for long-running driving where the user has stepped away on
     purpose. The skill makes its own decisions within an agreed envelope and
     reports at the end what it did and what it had to work around or bypass.

## Installing into a harness

`knit skills install` downloads the latest `agent/` folder from the knit GitHub
repo and copies it into a harness layout:

- **default** → `.agents/skills` and `.agents/commands` (the cross-harness
  location);
- **`--harness claude`** → `.claude/skills` and `.claude/commands`.

The `--harness` flag only selects the destination; the content is identical either
way. Install is a layout mapping, not a rewrite. The skills are not embedded in
`knit.sh`, so they track the published repo.

Install also drops `AGENTS.md` at the project root so an agent orients itself even
before a skill is loaded. An existing project `AGENTS.md` is never overwritten.
