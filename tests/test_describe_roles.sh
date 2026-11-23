#!/usr/bin/env bats

# describe surfaces the roles a setup provides (knit_provides_setup_role) in
# every output format. Roles are emitted only for a setup that provides at least
# one; no built-in command has roles, so a tree with only a no-role setup carries
# no "roles" field anywhere.

source "${BATS_TEST_DIRNAME}/setup_teardown.sh"

setup() {
    knit_test_source_knit
    _cnnenv_fn()  { :; }
    _plainenv_fn() { :; }
}

# Register a setup providing two roles.
_register_role_setup() {
    knit_register_setup "cnnenv-xpu" _cnnenv_fn "cifar-cnn on the frameworks module."
    knit_provides_setup_role "cnnenv"
    knit_provides_setup_role "pytorch"
    knit_done
}

@test "json lists a setup's provided roles" {
    _register_role_setup
    run knit describe --format json
    [ "$status" -eq 0 ]
    [[ "${output}" == *'"roles"'* ]]
    [[ "${output}" == *'"cnnenv"'* ]]
    [[ "${output}" == *'"pytorch"'* ]]
}

@test "yaml lists a setup's provided roles" {
    _register_role_setup
    run knit describe --format yaml
    [ "$status" -eq 0 ]
    [[ "${output}" == *'roles:'* ]]
    [[ "${output}" == *'cnnenv'* ]]
    [[ "${output}" == *'pytorch'* ]]
}

@test "default format lists a setup's provided roles" {
    _register_role_setup
    run knit describe --format default --no-color
    [ "$status" -eq 0 ]
    [[ "${output}" == *'Roles'* ]]
    [[ "${output}" == *'cnnenv pytorch'* ]]
}

@test "markdown lists a setup's provided roles" {
    _register_role_setup
    run knit describe --format markdown
    [ "$status" -eq 0 ]
    [[ "${output}" == *'*Roles: cnnenv pytorch*'* ]]
}

@test "a setup with no roles carries no roles field" {
    knit_register_setup "plainenv" _plainenv_fn "no roles."
    knit_done
    run knit describe --format json
    [ "$status" -eq 0 ]
    [[ "${output}" != *'"roles"'* ]]
}
