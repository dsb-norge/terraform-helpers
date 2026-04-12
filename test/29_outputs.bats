#!/usr/bin/env bats
# shellcheck disable=SC2164,SC1090,SC1091,SC2030,SC2031,SC2034,SC2154,SC2317
load 'helpers/test_helper'

setup_module_fixture() {
  export _MODULE_DIR="${BATS_FILE_TMPDIR}/module_project_${BATS_TEST_NUMBER}"
  cp -r "${FIXTURES_DIR}/project_module" "${_MODULE_DIR}"
  cd "${_MODULE_DIR}"
  mock_standard_tools
  source "${SUT}"
  default_test_setup
}

setup_project_fixture() {
  source_script_in_project
  default_test_setup
}

# ===========================================================================
# tf-outputs
# ===========================================================================

@test "tf-outputs function exists" {
  setup_module_fixture
  assert_function_exists "tf-outputs"
}

@test "tf-outputs succeeds in module repo" {
  setup_module_fixture
  run tf-outputs
  assert_success
}

@test "tf-outputs in module repo shows output" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-outputs
  assert_success
  assert_clean_output_contains "Showing outputs for module root"
}

@test "tf-outputs succeeds in project repo with env argument" {
  setup_project_fixture
  run tf-outputs "dev"
  assert_success
}

@test "tf-outputs in project repo shows environment info" {
  setup_project_fixture
  _dsbTfLogInfo=1
  run tf-outputs "dev"
  assert_success
  assert_clean_output_contains "Showing outputs for environment"
}

@test "tf-outputs help entry exists" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-help tf-outputs
  assert_success
  assert_clean_output_contains "tf-outputs"
  assert_clean_output_contains "module repos"
}

@test "tf-outputs has tab completion for envs in project repo" {
  setup_project_fixture
  local comp_output
  comp_output="$(complete -p tf-outputs 2>&1)"
  [[ "${comp_output}" == *"_dsb_tf_completions_for_available_envs"* ]]
}
