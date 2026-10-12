#!/usr/bin/env bats
# shellcheck disable=SC2164,SC1090,SC1091,SC2030,SC2031,SC2034,SC2154,SC2317
#
# Tests for how the init, upgrade and bump commands maintain the lock file
# (.terraform.lock.hcl): whether they run 'terraform init' with or without
# -upgrade, and whether they follow it with 'terraform providers lock' for
# every platform the helpers support.
#
# All assertions are made on the terraform calls recorded by
# mock_terraform_recording, see test/helpers/mock_helper.bash.
#
load 'helpers/test_helper'

setup() {
  project_dir="${BATS_TEST_TMPDIR}/project"
  cp -r "${FIXTURES_DIR}/project_standard" "${project_dir}"
  # init of main and modules uses the environment's providers directory as plugin dir
  mkdir -p "${project_dir}/envs/dev/.terraform/providers"
  mkdir -p "${project_dir}/envs/prod/.terraform/providers"
  cd "${project_dir}"
  mock_standard_tools
  mock_terraform_recording
  source "${SUT}"
  default_test_setup
}

teardown() {
  default_test_teardown
}

# The exact 'providers lock' call for an environment. The platform list is
# spelled out on purpose: it is the contract with CI and the people using the
# lock file, so changing it should take a deliberate change to this test.
expected_lock_call() {
  local envName="${1}"
  echo "-chdir=${_dsbTfEnvsDirList[${envName}]} providers lock -platform=windows_amd64 -platform=darwin_arm64 -platform=linux_amd64 -platform=linux_arm64"
}

# Line number of the first recorded call that equals or starts with the given string
call_line_number() {
  command grep -n -F -- "${1}" "${MOCK_TERRAFORM_CALLS_FILE}" | head -n 1 | cut -d: -f1
}

assert_no_providers_lock_calls() {
  run command grep -F -- " providers lock" "${MOCK_TERRAFORM_CALLS_FILE}"
  assert_failure
}

# -------------------------------------------------------
# init commands do not touch the lock beyond what init does
# -------------------------------------------------------

@test "tf-init-env runs init without -upgrade and does not run providers lock" {
  run tf-init-env dev
  assert_success

  run terraform_calls_in "envs/dev" "init"
  assert_success
  assert_output --partial "init -reconfigure -lock=false"
  refute_output --partial "-upgrade"
  refute_output --partial "-backend=false"

  assert_no_providers_lock_calls
}

@test "tf-init-env-offline runs init with -backend=false and does not run providers lock" {
  run tf-init-env-offline dev
  assert_success

  run terraform_calls_in "envs/dev" "init"
  assert_output --partial "-backend=false"
  refute_output --partial "-upgrade"

  assert_no_providers_lock_calls
}

@test "tf-init does not run providers lock" {
  run tf-init dev
  assert_success
  assert_no_providers_lock_calls
}

@test "tf-init-offline does not run providers lock" {
  run tf-init-offline dev
  assert_success
  assert_no_providers_lock_calls
}

@test "tf-init-all does not run providers lock" {
  run tf-init-all
  assert_success
  assert_no_providers_lock_calls
}

@test "tf-init-all-offline does not run providers lock" {
  run tf-init-all-offline
  assert_success
  assert_no_providers_lock_calls
}

# -------------------------------------------------------
# upgrade commands lock for all platforms after init -upgrade
# -------------------------------------------------------

@test "tf-upgrade-env runs init -upgrade, then providers lock for all platforms" {
  run tf-upgrade-env dev
  assert_success

  run terraform_calls_in "envs/dev" "init"
  assert_output --partial "-upgrade"
  refute_output --partial "-backend=false"

  run terraform_calls_in "envs/dev" "providers lock"
  assert_output "$(expected_lock_call dev)"

  local initLine lockLine
  initLine="$(call_line_number "-chdir=${_dsbTfEnvsDirList[dev]} init")"
  lockLine="$(call_line_number "$(expected_lock_call dev)")"
  [ "${initLine}" -lt "${lockLine}" ]
}

@test "tf-upgrade-env-offline runs init -upgrade -backend=false, then providers lock for all platforms" {
  run tf-upgrade-env-offline dev
  assert_success

  run terraform_calls_in "envs/dev" "init"
  assert_output --partial "-upgrade"
  assert_output --partial "-backend=false"

  run terraform_calls_in "envs/dev" "providers lock"
  assert_output "$(expected_lock_call dev)"
}

@test "tf-upgrade runs providers lock in the environment only, not in main or modules" {
  run tf-upgrade dev
  assert_success

  run terraform_calls_in "envs/dev" "providers lock"
  assert_output "$(expected_lock_call dev)"

  # main and modules are initialized, but never locked
  run terraform_calls_in "main" "init"
  assert_output --partial "-plugin-dir="
  run command grep -c -F -- " providers lock" "${MOCK_TERRAFORM_CALLS_FILE}"
  assert_output "1"
}

@test "tf-upgrade-all runs providers lock for all platforms in every environment" {
  run tf-upgrade-all
  assert_success

  run terraform_calls_in "envs/dev" "providers lock"
  assert_output "$(expected_lock_call dev)"
  run terraform_calls_in "envs/prod" "providers lock"
  assert_output "$(expected_lock_call prod)"
  run command grep -c -F -- " providers lock" "${MOCK_TERRAFORM_CALLS_FILE}"
  assert_output "2"
}

@test "tf-upgrade-all-offline runs providers lock for all platforms in every environment" {
  run tf-upgrade-all-offline
  assert_success

  run terraform_calls_in "envs/dev" "providers lock"
  assert_output "$(expected_lock_call dev)"
  run terraform_calls_in "envs/prod" "providers lock"
  assert_output "$(expected_lock_call prod)"
}

@test "tf-bump-env-offline upgrades and runs providers lock for all platforms" {
  run tf-bump-env-offline dev

  run terraform_calls_in "envs/dev" "init"
  assert_output --partial "-upgrade"
  run terraform_calls_in "envs/dev" "providers lock"
  assert_output "$(expected_lock_call dev)"
}

# -------------------------------------------------------
# failures
# -------------------------------------------------------

@test "tf-upgrade-env does not run providers lock when init fails" {
  export MOCK_TERRAFORM_FAIL_INIT='*'
  run tf-upgrade-env dev
  assert_failure
  assert_no_providers_lock_calls
}

@test "tf-upgrade-env fails and says so when providers lock fails" {
  export MOCK_TERRAFORM_FAIL_LOCK='*'
  export _dsbTfLogErrors=1
  run tf-upgrade-env dev
  assert_failure
  assert_output --partial "Could not retrieve providers for locking"
  assert_output --partial "terraform providers lock failed in"
}

@test "tf-upgrade-env-offline fails when providers lock fails" {
  export MOCK_TERRAFORM_FAIL_LOCK='*'
  run tf-upgrade-env-offline dev
  assert_failure
}

@test "tf-upgrade fails when providers lock fails" {
  export MOCK_TERRAFORM_FAIL_LOCK='*'
  run tf-upgrade dev
  assert_failure
}

@test "tf-upgrade-all locks the remaining environments when one environment fails to lock" {
  export MOCK_TERRAFORM_FAIL_LOCK='*/envs/dev'
  run tf-upgrade-all
  assert_failure

  run terraform_calls_in "envs/prod" "providers lock"
  assert_output "$(expected_lock_call prod)"
}

# -------------------------------------------------------
# the platform list is kept in one place
# -------------------------------------------------------

@test "_dsbTfLockPlatforms lists the four supported platforms" {
  [ "${_dsbTfLockPlatforms[*]}" == "windows_amd64 darwin_arm64 linux_amd64 linux_arm64" ]
}

@test "the script hard-codes no -platform= flag outside _dsbTfLockPlatforms" {
  run command grep -nE -- '-platform=[a-z]' "${SUT}"
  assert_failure
}

@test "providers lock uses whatever _dsbTfLockPlatforms holds" {
  _dsbTfLockPlatforms=(linux_amd64)
  run tf-upgrade-env dev
  assert_success

  run terraform_calls_in "envs/dev" "providers lock"
  assert_output "-chdir=${_dsbTfEnvsDirList[dev]} providers lock -platform=linux_amd64"
}

@test "_dsbTfLockPlatforms survives an exposed command" {
  tf-init-env dev >/dev/null 2>&1 || true
  [ "${#_dsbTfLockPlatforms[@]}" -eq 4 ]
}

@test "re-sourcing the script restores _dsbTfLockPlatforms" {
  _dsbTfLockPlatforms=(only_this_one)
  source "${SUT}"
  [ "${_dsbTfLockPlatforms[*]}" == "windows_amd64 darwin_arm64 linux_amd64 linux_arm64" ]
}
