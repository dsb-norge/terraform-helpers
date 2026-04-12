#!/usr/bin/env bats
# shellcheck disable=SC2164,SC1090,SC1091,SC2030,SC2031,SC2034,SC2154,SC2317
load 'helpers/test_helper'

# -- Repo type detection --

@test "repo type detection: standard project fixture -> 'project'" {
  local project_dir
  project_dir="$(create_standard_project)"
  cd "${project_dir}"
  mock_standard_tools
  source "${SUT}"
  default_test_setup

  _dsb_tf_enumerate_directories
  [[ "${_dsbTfRepoType}" == "project" ]]
}

@test "repo type detection: module fixture -> 'module'" {
  local module_dir
  module_dir="$(create_module_project)"
  cd "${module_dir}"
  mock_standard_tools
  source "${SUT}"
  default_test_setup

  _dsb_tf_enumerate_directories
  [[ "${_dsbTfRepoType}" == "module" ]]
}

@test "repo type detection: empty directory -> '' (unknown)" {
  local empty_dir
  empty_dir="$(create_empty_project)"
  cd "${empty_dir}"
  mock_standard_tools
  source "${SUT}"
  default_test_setup

  _dsb_tf_enumerate_directories
  [[ "${_dsbTfRepoType}" == "" ]]
}

# -- Module enumeration --

setup_module_fixture() {
  export _MODULE_DIR="${BATS_FILE_TMPDIR}/module_project_${BATS_TEST_NUMBER}"
  cp -r "${FIXTURES_DIR}/project_module" "${_MODULE_DIR}"
  cd "${_MODULE_DIR}"
  mock_standard_tools
  source "${SUT}"
  default_test_setup
}

@test "module enumeration: _dsbTfExamplesDir is set" {
  setup_module_fixture
  _dsb_tf_enumerate_directories
  [[ "${_dsbTfExamplesDir}" == "${_MODULE_DIR}/examples" ]]
}

@test "module enumeration: finds 01-basic example" {
  setup_module_fixture
  _dsb_tf_enumerate_directories
  [[ -n "${_dsbTfExamplesDirList[01-basic]:-}" ]]
}

@test "module enumeration: _dsbTfTestsDir is set" {
  setup_module_fixture
  _dsb_tf_enumerate_directories
  [[ "${_dsbTfTestsDir}" == "${_MODULE_DIR}/tests" ]]
}

@test "module enumeration: finds test files" {
  setup_module_fixture
  _dsb_tf_enumerate_directories
  [[ "${#_dsbTfTestFilesList[@]}" -eq 2 ]]
}

@test "module enumeration: finds unit test files" {
  setup_module_fixture
  _dsb_tf_enumerate_directories
  [[ "${#_dsbTfUnitTestFilesList[@]}" -eq 1 ]]
  [[ "$(basename "${_dsbTfUnitTestFilesList[0]}")" == "unit-tests.tftest.hcl" ]]
}

@test "module enumeration: finds integration test files" {
  setup_module_fixture
  _dsb_tf_enumerate_directories
  [[ "${#_dsbTfIntegrationTestFilesList[@]}" -eq 1 ]]
  [[ "$(basename "${_dsbTfIntegrationTestFilesList[0]}")" == "integration-test-01-basic.tftest.hcl" ]]
}
