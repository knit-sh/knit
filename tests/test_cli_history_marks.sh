#!/usr/bin/env bats

# History eligibility marks (recording M2): assert _knit_history_enabled returns
# the decided Q3 value for representative builtins, after the knit_without_history
# / knit_with_history marks are applied. Pure function over the registration
# tables, so no database is needed; lazily-discovered subtrees are expanded first.

setup() {
    source "${BATS_TEST_DIRNAME}/setup_teardown.sh"
    knit_test_source_knit
}

# Mangle a demangled command name (colons -> __1__) the way the invoke path does.
_m() { local out; _knit_command_mangle out "$1"; printf '%s' "${out}"; }

# Force lazy subcommand discovery for a parent so its children are registered.
_ensure() { _knit_ensure_discovered "$(_m "$1")"; }

# Assert a command is / is not history-eligible.
_eligible()   { _knit_history_enabled "$(_m "$1")"; }
_ineligible() { ! _knit_history_enabled "$(_m "$1")"; }

# ---------- eligible: the data-production spine + mutating actions ----------

@test "spine and mutating commands are history-eligible" {
    _eligible "submit"
    _eligible "run"
    _eligible "setup"
    _eligible "sweep"
    _eligible "fetch"
    _eligible "prepare"
    _eligible "remove"
}

@test "metadata:store is eligible despite the metadata parent being opted out" {
    _ensure "metadata"
    _eligible "metadata:store"
    _ineligible "metadata:load"
    _ineligible "metadata:show"
}

@test "claim:check is eligible despite the claim parent being opted out" {
    _eligible "claim:check"
    _ineligible "claim:list"
    _ineligible "claim"
}

# ---------- ineligible: inspection, repair, bootstrap ----------

@test "inspection and management commands are not history-eligible" {
    _ineligible "describe"
    _ineligible "bootstrap"
    _ineligible "bundle"
}

@test "the job subtree is entirely opted out" {
    _ensure "job"
    _ineligible "job"
    _ineligible "job:list"
    _ineligible "job:status"
    _ineligible "job:resubmit"
    _ineligible "job:wait"
}

@test "the query, ai, profile, plugins, export and history subtrees are opted out" {
    _ensure "query";   _ineligible "query:sql"
    _ensure "ai";      _ineligible "ai:ask"
    _ensure "profile"; _ineligible "profile:list"
    _ensure "plugins"; _ineligible "plugins:lock"
    _ensure "export";  _ineligible "export:ro-crate"
    _ensure "skills";  _ineligible "skills:install"
    _ineligible "history"
    _ineligible "history:show"
}

# ---------- dynamic user families inherit the spine default (ON) ----------

@test "a user command is history-eligible by default" {
    knit_register "myusercmd" knit_empty "User command."
    knit_done
    _eligible "myusercmd"
}

@test "a user job inherits history eligibility from submit" {
    knit_register_job "myjob" _myjob_fn "A user job."
    _myjob_fn() { :; }
    knit_done
    _eligible "submit:myjob"
}

@test "a user claim is history-eligible via the claim:<name> template override" {
    knit_register_claim "myclaim" _myclaim_fn "A finding."
    _myclaim_fn() { :; }
    knit_done
    _eligible "claim:myclaim"
}
