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
# tf-bump-cicd
# -------------------------------------------------------

@test "tf-bump-cicd runs with all mocks" {
  mock_gh
  mock_yq
  run tf-bump-cicd
  assert_success
  assert_output --partial "Bump versions in GitHub workflow"
}

@test "tf-bump-cicd handles no workflow files" {
  mock_gh
  mock_yq
  # Remove the .github/workflows directory
  rm -rf "${project_dir}/.github"

  run tf-bump-cicd
  assert_success
  assert_output --partial "no github workflow files found"
}

@test "tf-bump-cicd requires gh auth" {
  mock_gh_not_authenticated
  mock_yq
  run tf-bump-cicd
  assert_failure
  assert_output --partial "not authenticated"
}
