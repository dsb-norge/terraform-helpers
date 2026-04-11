#!/usr/bin/env bats
load 'helpers/test_helper'

setup_file() {
  # Pre-create fixture copies for the file
  export _DIR_TEST_PROJECT="${BATS_FILE_TMPDIR}/project_std"
  cp -r "${FIXTURES_DIR}/project_standard" "${_DIR_TEST_PROJECT}"
}

setup() {
  cd "${_DIR_TEST_PROJECT}"
  mock_standard_tools
  source "${SUT}"
  default_test_setup
}

teardown() {
  default_test_teardown
}

# -- _dsb_tf_enumerate_directories --

@test "_dsb_tf_enumerate_directories sets _dsbTfRootDir to current directory" {
  _dsb_tf_enumerate_directories
  [[ "${_dsbTfRootDir}" == "${_DIR_TEST_PROJECT}" ]]
}

@test "_dsb_tf_enumerate_directories sets _dsbTfMainDir" {
  _dsb_tf_enumerate_directories
  [[ "${_dsbTfMainDir}" == "${_DIR_TEST_PROJECT}/main" ]]
}

@test "_dsb_tf_enumerate_directories sets _dsbTfEnvsDir" {
  _dsb_tf_enumerate_directories
  [[ "${_dsbTfEnvsDir}" == "${_DIR_TEST_PROJECT}/envs" ]]
}

@test "_dsb_tf_enumerate_directories sets _dsbTfModulesDir" {
  _dsb_tf_enumerate_directories
  [[ "${_dsbTfModulesDir}" == "${_DIR_TEST_PROJECT}/modules" ]]
}

@test "_dsb_tf_enumerate_directories finds environments (dev and prod)" {
  _dsb_tf_enumerate_directories
  local env_count="${#_dsbTfAvailableEnvs[@]}"
  [[ "${env_count}" -eq 2 ]]

  # Check both envs exist in the array
  local found_dev=0 found_prod=0
  local env
  for env in "${_dsbTfAvailableEnvs[@]}"; do
    [[ "${env}" == "dev" ]] && found_dev=1
    [[ "${env}" == "prod" ]] && found_prod=1
  done
  [[ "${found_dev}" -eq 1 ]]
  [[ "${found_prod}" -eq 1 ]]
}

@test "_dsb_tf_enumerate_directories finds modules" {
  _dsb_tf_enumerate_directories
  # The standard project has a modules/networking directory
  [[ -n "${_dsbTfModulesDirList[networking]:-}" ]]
}

@test "_dsb_tf_enumerate_directories finds .tf files" {
  _dsb_tf_enumerate_directories
  local file_count="${#_dsbTfFilesList[@]}"
  [[ "${file_count}" -gt 0 ]]
}

# -- _dsb_tf_look_for_main_dir --

@test "_dsb_tf_look_for_main_dir succeeds in standard project" {
  _dsb_tf_enumerate_directories
  run _dsb_tf_look_for_main_dir
  assert_success
}

@test "_dsb_tf_look_for_main_dir fails when no main dir" {
  local no_main
  no_main="$(create_project_no_main)"
  cd "${no_main}"
  _dsb_tf_enumerate_directories
  _dsbTfLogErrors=1
  run _dsb_tf_look_for_main_dir
  assert_failure
}

# -- _dsb_tf_look_for_envs_dir --

@test "_dsb_tf_look_for_envs_dir succeeds in standard project" {
  _dsb_tf_enumerate_directories
  run _dsb_tf_look_for_envs_dir
  assert_success
}

@test "_dsb_tf_look_for_envs_dir fails when no envs dir" {
  local no_envs
  no_envs="$(create_project_no_envs)"
  cd "${no_envs}"
  _dsb_tf_enumerate_directories
  _dsbTfLogErrors=1
  run _dsb_tf_look_for_envs_dir
  assert_failure
}

# -- _dsb_tf_look_for_env --

@test "_dsb_tf_look_for_env finds dev" {
  _dsb_tf_enumerate_directories
  run _dsb_tf_look_for_env "dev"
  assert_success
}

@test "_dsb_tf_look_for_env finds prod" {
  _dsb_tf_enumerate_directories
  run _dsb_tf_look_for_env "prod"
  assert_success
}

@test "_dsb_tf_look_for_env fails for nonexistent env" {
  _dsb_tf_enumerate_directories
  _dsbTfLogErrors=1
  run _dsb_tf_look_for_env "staging"
  assert_failure
  assert_clean_output_contains "Environment not found"
}

# -- _dsb_tf_look_for_lock_file --

@test "_dsb_tf_look_for_lock_file succeeds for dev" {
  _dsb_tf_enumerate_directories
  _dsbTfSelectedEnv="dev"
  _dsbTfSelectedEnvDir="${_dsbTfEnvsDirList[dev]}"
  run _dsb_tf_look_for_lock_file "dev"
  assert_success
}

# -- _dsb_tf_look_for_subscription_hint_file --

@test "_dsb_tf_look_for_subscription_hint_file succeeds for dev" {
  _dsb_tf_enumerate_directories
  _dsbTfSelectedEnv="dev"
  _dsbTfSelectedEnvDir="${_dsbTfEnvsDirList[dev]}"
  _dsb_tf_look_for_subscription_hint_file "dev"
  [[ -n "${_dsbTfSelectedEnvSubscriptionHintFile}" ]]
  [[ "${_dsbTfSelectedEnvSubscriptionHintContent}" == "mock-sub-dev" ]]
}

# -- _dsb_tf_check_current_dir --

@test "_dsb_tf_check_current_dir passes in standard project" {
  _dsb_tf_configure_shell || true
  _dsbTfLogInfo=0
  _dsbTfLogErrors=0
  _dsb_tf_check_current_dir
  local rc=$?
  _dsb_tf_restore_shell
  [[ "${rc}" -eq 0 ]]
}

@test "_dsb_tf_check_current_dir fails in empty project" {
  local empty_dir
  empty_dir="$(create_empty_project)"
  cd "${empty_dir}"
  _dsb_tf_configure_shell || true
  _dsbTfLogInfo=0
  _dsbTfLogErrors=0
  local rc=0
  _dsb_tf_check_current_dir || rc=$?
  _dsb_tf_restore_shell
  [[ "${rc}" -ne 0 ]]
}

# -- tf-check-dir exposed function --

@test "tf-check-dir passes in standard project" {
  run tf-check-dir
  assert_success
}

@test "tf-check-dir fails in empty project" {
  local empty_dir
  empty_dir="$(create_empty_project)"
  cd "${empty_dir}"
  run tf-check-dir
  assert_failure
}
