#!/usr/bin/env bats
# shellcheck disable=SC2164,SC1090,SC1091,SC2030,SC2031,SC2034,SC2154,SC2317
load 'helpers/test_helper'

setup() {
  export BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-${BATS_FILE_TMPDIR}}"
  source_script_in_project
  default_test_setup
}

teardown() {
  default_test_teardown
}

# ---------------------------------------------------------------------------
# tf-unload removes functions
# ---------------------------------------------------------------------------

@test "tf-unload removes tf-help" {
  assert_function_exists "tf-help"
  tf-unload
  assert_function_not_exists "tf-help"
}

@test "tf-unload removes _dsb_tf_configure_shell" {
  assert_function_exists "_dsb_tf_configure_shell"
  tf-unload
  assert_function_not_exists "_dsb_tf_configure_shell"
}

@test "tf-unload removes itself" {
  assert_function_exists "tf-unload"
  tf-unload
  assert_function_not_exists "tf-unload"
}

# ---------------------------------------------------------------------------
# tf-unload removes global variables
# ---------------------------------------------------------------------------

@test "tf-unload unsets _dsbTfRepoType" {
  [[ -n "${_dsbTfRepoType:-}" ]] || _dsbTfRepoType="project"
  tf-unload
  [[ -z "${_dsbTfRepoType:-}" ]]
}

@test "tf-unload unsets _dsbTfRootDir" {
  [[ -n "${_dsbTfRootDir:-}" ]] || _dsbTfRootDir="/tmp/test"
  tf-unload
  [[ -z "${_dsbTfRootDir:-}" ]]
}

# ---------------------------------------------------------------------------
# tf-unload removes tab completions
# ---------------------------------------------------------------------------

@test "tf-unload removes completion for tf-set-env" {
  # Verify completion is registered before unload
  run complete -p tf-set-env
  assert_success

  tf-unload

  run complete -p tf-set-env
  assert_failure
}

@test "tf-unload removes completion for tf-help" {
  run complete -p tf-help
  assert_success

  tf-unload

  run complete -p tf-help
  assert_failure
}

# ---------------------------------------------------------------------------
# tf-unload prints confirmation
# ---------------------------------------------------------------------------

@test "tf-unload prints confirmation message" {
  run tf-unload
  assert_success
  assert_output --partial "DSB Terraform Helpers unloaded."
}
