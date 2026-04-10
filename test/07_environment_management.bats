#!/usr/bin/env bats
load 'helpers/test_helper'

setup_file() {
  export _ENV_TEST_PROJECT="${BATS_FILE_TMPDIR}/project"
  cp -r "${FIXTURES_DIR}/project_standard" "${_ENV_TEST_PROJECT}"
}

setup() {
  cd "${_ENV_TEST_PROJECT}"
  mock_standard_tools
  source "${SUT}"
  default_test_setup
}

teardown() {
  default_test_teardown
}

# Helper to call an exposed function that uses configure_shell/restore_shell
# without bats' set -e interfering with shopt -o history (returns 1 in non-interactive shells).
# Usage: call_exposed tf-set-env dev
# Sets _CALL_RC to the return code.
call_exposed() {
  set +eET
  "$@"
  _CALL_RC=$?
  set -eET
  return 0
}

# -- tf-list-envs --

@test "tf-list-envs lists dev and prod" {
  _dsbTfLogInfo=1
  run tf-list-envs
  assert_success
  assert_clean_output_contains "dev"
  assert_clean_output_contains "prod"
}

# -- tf-set-env --

@test "tf-set-env dev sets _dsbTfSelectedEnv" {
  call_exposed tf-set-env dev
  [[ "${_CALL_RC}" -eq 0 ]]
  [[ "${_dsbTfSelectedEnv}" == "dev" ]]
}

@test "tf-set-env with no arg fails" {
  run tf-set-env
  assert_failure
}

@test "tf-set-env with nonexistent env fails" {
  run tf-set-env "nonexistent"
  assert_failure
}

@test "tf-set-env prod sets _dsbTfSelectedEnv to prod" {
  call_exposed tf-set-env prod
  [[ "${_CALL_RC}" -eq 0 ]]
  [[ "${_dsbTfSelectedEnv}" == "prod" ]]
}

# -- tf-clear-env --

@test "tf-clear-env clears selection" {
  call_exposed tf-set-env dev
  [[ "${_dsbTfSelectedEnv}" == "dev" ]]
  call_exposed tf-clear-env
  [[ -z "${_dsbTfSelectedEnv}" ]]
}

# -- tf-select-env with arg --

@test "tf-select-env with arg acts like tf-set-env" {
  call_exposed tf-select-env dev
  [[ "${_CALL_RC}" -eq 0 ]]
  [[ "${_dsbTfSelectedEnv}" == "dev" ]]
}

# -- tf-select-env without arg (interactive) --

@test "tf-select-env without arg prompts and accepts input" {
  # tf-select-env uses read -r -p which needs stdin.
  # We need mocks available inside the subshell, so we export the mock functions
  # and source the script inside.
  run bash -c '
    cd "'"${_ENV_TEST_PROJECT}"'"

    # Define mocks inline (export -f does not survive bash -c boundary)
    az() { case "$1" in --version) echo "azure-cli 2.55.0";; account) shift; case "$1" in show) echo "{\"id\":\"00000000\",\"name\":\"mock-sub-dev\",\"user\":{\"name\":\"test@example.com\"},\"tenantDisplayName\":\"T\"}";; clear) return 0;; set) return 0;; esac;; esac; return 0; }
    gh() { case "$1" in --version) echo "gh 2.40.0";; auth) shift; case "$1" in status) echo "Logged in to github.com account testuser"; return 0;; token) echo "gho_mock"; return 0;; esac;; esac; return 0; }
    terraform() { case "$1" in -version) echo "Terraform v1.7.0";; esac; return 0; }
    jq() { command jq "$@" 2>/dev/null || cat; }
    yq() { echo "yq mock"; return 0; }
    hcledit() { echo "0.2.10"; return 0; }
    terraform-config-inspect() { echo "{}"; }
    curl() { echo "mock"; return 0; }
    go() { echo "go version go1.21.5"; return 0; }
    realpath() {
      if [[ "$1" == "--relative-to="* ]]; then
        local base="${1#--relative-to=}"
        python3 -c "import os.path; print(os.path.relpath('"'"'$2'"'"', '"'"'${base}'"'"'))" 2>/dev/null || echo "$2"
      else
        echo "$1"
      fi
    }

    source "'"${SUT}"'" >/dev/null 2>&1
    tf-select-env <<< "1"
    echo "SELECTED=${_dsbTfSelectedEnv}"
  '
  assert_success
  # The selected env should be one of dev or prod (order varies with associative array)
  [[ "${output}" == *"SELECTED=dev"* ]] || [[ "${output}" == *"SELECTED=prod"* ]]
}

# -- tf-check-env --

@test "tf-check-env validates existing env" {
  run tf-check-env dev
  assert_success
}

@test "tf-check-env fails for nonexistent env" {
  run tf-check-env "nonexistent"
  assert_failure
}

@test "tf-check-env with no arg and no selected env fails" {
  _dsbTfSelectedEnv=""
  run tf-check-env
  assert_failure
}

@test "tf-check-env with no arg uses selected env" {
  call_exposed tf-set-env dev
  run tf-check-env
  assert_success
}
