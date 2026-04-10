#!/usr/bin/env bats
load 'helpers/test_helper'

setup() {
  default_test_setup
  project_dir="${BATS_TEST_TMPDIR}/project"
  cp -r "${BATS_TEST_DIRNAME}/fixtures/project_standard" "${project_dir}"
  cd "${project_dir}"
  mock_standard_tools
  source "${SUT}"
}

teardown() {
  default_test_teardown
}

# -------------------------------------------------------
# tf-bump-tflint-plugins
# -------------------------------------------------------

@test "tf-bump-tflint-plugins runs with all mocks" {
  mock_gh
  mock_hcledit
  mock_curl
  run tf-bump-tflint-plugins
  assert_success
  assert_output --partial "Bump versions of plugins"
}

@test "tf-bump-tflint-plugins requires gh auth" {
  mock_gh_not_authenticated
  mock_hcledit
  mock_curl
  run tf-bump-tflint-plugins
  assert_failure
}
