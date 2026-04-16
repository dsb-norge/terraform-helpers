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

# -- Project-only gating --

@test "project-only gating: _dsb_tf_require_project_repo succeeds in project repo" {
  local project_dir
  project_dir="$(create_standard_project)"
  cd "${project_dir}"
  mock_standard_tools
  source "${SUT}"
  default_test_setup

  _dsb_tf_enumerate_directories
  run _dsb_tf_require_project_repo
  assert_success
}

@test "project-only gating: _dsb_tf_require_project_repo fails in module repo" {
  setup_module_fixture
  _dsb_tf_enumerate_directories
  _dsbTfLogErrors=1
  run _dsb_tf_require_project_repo
  assert_failure
  assert_clean_output_contains "only available in Terraform project repos"
}

@test "project-only gating: tf-list-envs fails in module repo" {
  setup_module_fixture
  run tf-list-envs
  assert_failure
  assert_clean_output_contains "only available in Terraform project repos"
}

@test "project-only gating: tf-set-env fails in module repo" {
  setup_module_fixture
  run tf-set-env "dev"
  assert_failure
  assert_clean_output_contains "only available in Terraform project repos"
}

@test "project-only gating: tf-select-env fails in module repo" {
  setup_module_fixture
  run tf-select-env "dev"
  assert_failure
  assert_clean_output_contains "only available in Terraform project repos"
}

@test "project-only gating: tf-clear-env fails in module repo" {
  setup_module_fixture
  run tf-clear-env
  assert_failure
  assert_clean_output_contains "only available in Terraform project repos"
}

@test "project-only gating: tf-unset-env fails in module repo" {
  setup_module_fixture
  run tf-unset-env
  assert_failure
  assert_clean_output_contains "only available in Terraform project repos"
}

@test "project-only gating: tf-check-env fails in module repo" {
  setup_module_fixture
  run tf-check-env "dev"
  assert_failure
  assert_clean_output_contains "only available in Terraform project repos"
}

@test "project-only gating: tf-init-env fails in module repo" {
  setup_module_fixture
  run tf-init-env "dev"
  assert_failure
  assert_clean_output_contains "only available in Terraform project repos"
}

@test "tf-init-all succeeds in module repo (ungated)" {
  setup_module_fixture
  run tf-init-all
  assert_success
}

@test "project-only gating: tf-init-main fails in module repo" {
  setup_module_fixture
  run tf-init-main
  assert_failure
  assert_clean_output_contains "only available in Terraform project repos"
}

@test "project-only gating: tf-init-modules fails in module repo" {
  setup_module_fixture
  run tf-init-modules
  assert_failure
  assert_clean_output_contains "only available in Terraform project repos"
}

@test "project-only gating: tf-plan fails in module repo" {
  setup_module_fixture
  run tf-plan "dev"
  assert_failure
  assert_clean_output_contains "only available in Terraform project repos"
}

@test "project-only gating: tf-apply fails in module repo" {
  setup_module_fixture
  run tf-apply "dev"
  assert_failure
  assert_clean_output_contains "only available in Terraform project repos"
}

@test "project-only gating: tf-destroy fails in module repo" {
  setup_module_fixture
  run tf-destroy "dev"
  assert_failure
  assert_clean_output_contains "only available in Terraform project repos"
}

@test "project-only gating: tf-upgrade-env fails in module repo" {
  setup_module_fixture
  run tf-upgrade-env "dev"
  assert_failure
  assert_clean_output_contains "only available in Terraform project repos"
}

@test "tf-upgrade-all succeeds in module repo (ungated)" {
  setup_module_fixture
  run tf-upgrade-all
  assert_success
}

@test "project-only gating: tf-bump-env fails in module repo" {
  setup_module_fixture
  run tf-bump-env "dev"
  assert_failure
  assert_clean_output_contains "only available in Terraform project repos"
}

@test "tf-bump-all succeeds in module repo (ungated)" {
  setup_module_fixture
  run tf-bump-all
  assert_success
}

@test "project-only gating: tf-show-all-provider-upgrades fails in module repo" {
  setup_module_fixture
  run tf-show-all-provider-upgrades
  assert_failure
  assert_clean_output_contains "only available in Terraform project repos"
}

# -- az-* commands still work in module repo --

@test "az-* commands still work in module repo: az-whoami" {
  setup_module_fixture
  run az-whoami
  assert_success
}

# -- tf-check-dir in module repo --

@test "tf-check-dir succeeds in module repo" {
  setup_module_fixture
  run tf-check-dir
  assert_success
  assert_clean_output_contains "module repo"
  assert_clean_output_contains "Root .tf files check"
  assert_clean_output_contains "versions.tf check"
}

@test "tf-check-dir succeeds in project repo" {
  local project_dir
  project_dir="$(create_standard_project)"
  cd "${project_dir}"
  mock_standard_tools
  source "${SUT}"
  default_test_setup

  run tf-check-dir
  assert_success
  assert_clean_output_contains "Main directory check"
  assert_clean_output_contains "Environments directory check"
}

# -- tf-status shows repo type --

@test "tf-status shows repo type 'project' in project repo" {
  local project_dir
  project_dir="$(create_standard_project)"
  cd "${project_dir}"
  mock_standard_tools
  source "${SUT}"
  default_test_setup
  _dsbTfLogInfo=1

  run _dsb_tf_report_status
  assert_clean_output_contains "Repo type               : project"
}

@test "tf-status shows repo type 'module' in module repo" {
  setup_module_fixture
  _dsbTfLogInfo=1

  run _dsb_tf_report_status
  assert_clean_output_contains "Repo type               : module"
  assert_clean_output_contains "Examples directory"
  assert_clean_output_contains "Test files"
}

# -- Common commands work in module repo --

@test "tf-fmt works in module repo" {
  setup_module_fixture
  run tf-fmt
  assert_success
}

@test "tf-check-tools works in module repo" {
  setup_module_fixture
  run tf-check-tools
  assert_success
}

@test "tf-check-gh-auth works in module repo" {
  setup_module_fixture
  run tf-check-gh-auth
  assert_success
}

@test "tf-bump-modules works in module repo" {
  setup_module_fixture
  run tf-bump-modules
  assert_success
}

@test "tf-bump-cicd works in module repo" {
  setup_module_fixture
  run tf-bump-cicd
  assert_success
}

@test "tf-bump-tflint-plugins works in module repo" {
  setup_module_fixture
  run tf-bump-tflint-plugins
  assert_success
}
