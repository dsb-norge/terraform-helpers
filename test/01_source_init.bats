#!/usr/bin/env bats
# shellcheck disable=SC2164,SC1090,SC1091,SC2030,SC2031,SC2034,SC2154,SC2317
load 'helpers/test_helper'

# Create the project fixture once for the file
setup_file() {
  export _INIT_TEST_PROJECT="${BATS_FILE_TMPDIR}/project"
  cp -r "${FIXTURES_DIR}/project_standard" "${_INIT_TEST_PROJECT}"
}

setup() {
  default_test_setup
  cd "${_INIT_TEST_PROJECT}"
  mock_standard_tools
  source "${SUT}"
}

teardown() {
  default_test_teardown
}

# -- Tests --

@test "sourcing defines tf-* exposed functions" {
  assert_function_exists "tf-help"
  assert_function_exists "tf-status"
  assert_function_exists "tf-check-tools"
  assert_function_exists "tf-check-dir"
  assert_function_exists "tf-check-prereqs"
  assert_function_exists "tf-list-envs"
  assert_function_exists "tf-set-env"
  assert_function_exists "tf-select-env"
  assert_function_exists "tf-clear-env"
  assert_function_exists "tf-check-env"
  assert_function_exists "tf-init"
  assert_function_exists "tf-plan"
  assert_function_exists "tf-apply"
}

@test "sourcing defines az-* exposed functions" {
  assert_function_exists "az-login"
  assert_function_exists "az-logout"
  assert_function_exists "az-whoami"
  assert_function_exists "az-set-sub"
  assert_function_exists "az-select-sub"
  assert_function_exists "az-relog"
}

@test "sourcing defines internal _dsb_* functions" {
  assert_function_exists "_dsb_tf_configure_shell"
  assert_function_exists "_dsb_tf_restore_shell"
  assert_function_exists "_dsb_tf_error_push"
  assert_function_exists "_dsb_tf_error_clear"
  assert_function_exists "_dsb_tf_error_dump"
  assert_function_exists "_dsb_tf_enumerate_directories"
  assert_function_exists "_dsb_e"
  assert_function_exists "_dsb_i"
  assert_function_exists "_dsb_w"
  assert_function_exists "_dsb_d"
}

@test "sourcing on unsupported arch fails" {
  mock_uname_unsupported
  run bash -c "source '${SUT}'"
  assert_failure
  assert_output --partial "unsupported"
}

@test "re-sourcing is idempotent" {
  # Source again -- should succeed and functions still work
  source "${SUT}"
  assert_function_exists "tf-help"
  assert_function_exists "_dsb_tf_configure_shell"
  assert_global_set "_dsbTfRootDir"
}

@test "_dsbTfRootDir is set after sourcing" {
  assert_global_set "_dsbTfRootDir"
}

@test "startup message is printed during sourcing" {
  # Source in a subshell and capture output
  local project_dir
  project_dir="$(create_standard_project)"
  run bash -c "cd '${project_dir}' && source '${SUT}' 2>&1"
  assert_success
  assert_output --partial "DSB Terraform Project Helpers"
}

@test "tab completions are registered for tf-set-env" {
  run complete -p tf-set-env
  assert_success
}

@test "download guard: first non-comment/non-blank line is opening brace" {
  # Skip the shebang and any comment/blank lines, the next line must be '{'
  local first_code_line
  first_code_line=$(grep -v '^\s*$' "${SUT}" | grep -v '^\s*#' | grep -v '^#!/' | head -1)
  [[ "${first_code_line}" == "{ "* ]]
}

@test "download guard: last non-blank line is closing brace" {
  local last_line
  last_line=$(grep -v '^\s*$' "${SUT}" | tail -1)
  [[ "${last_line}" == "} "* ]]
}

@test "bash version guard exists in script" {
  local count
  count=$(command grep -c 'BASH_VERSINFO' "${SUT}")
  # The version guard uses BASH_VERSINFO across at least 2 lines
  [[ "${count}" -ge 2 ]]
}

@test "no unused global variables declared" {
  # Extract all 'declare -g[aA] _dsbTf*' variable names from the script
  local -a declared=()
  mapfile -t declared < <(grep -oP 'declare -g[aA]? \K(_dsbTf\w+)' "${SUT}" | sort -u)

  local unused=()
  for var in "${declared[@]}"; do
    # Count references beyond the declare line itself
    local refs
    refs=$(grep -c "${var}" "${SUT}")
    if [ "${refs}" -le 1 ]; then
      unused+=("${var}")
    fi
  done

  if [ ${#unused[@]} -gt 0 ]; then
    echo "Unused global variables found:" >&2
    for var in "${unused[@]}"; do
      echo "  ${var}" >&2
    done
    return 1
  fi
}

@test "sourcing succeeds even when caller has set -e active" {
  local project_dir
  project_dir="$(create_standard_project)"
  run bash -c '
    set -e
    cd "'"${project_dir}"'"
    source "'"${SUT}"'" >/dev/null 2>&1
    echo "SOURCE_OK"
  '
  assert_success
  assert_output --partial "SOURCE_OK"
}
