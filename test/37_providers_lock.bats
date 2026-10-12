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

# -------------------------------------------------------
# tf-lock-env: init without -upgrade, then lock for all platforms
# -------------------------------------------------------

@test "tf-lock-* commands are defined" {
  assert_function_exists "tf-lock-env"
  assert_function_exists "tf-lock-env-offline"
  assert_function_exists "tf-lock-all"
  assert_function_exists "tf-lock-all-offline"
}

@test "tf-lock-env runs init without -upgrade, then providers lock for all platforms" {
  run tf-lock-env dev
  assert_success

  run terraform_calls_in "envs/dev" "init"
  assert_output --partial "init -reconfigure -lock=false"
  refute_output --partial "-upgrade"

  run terraform_calls_in "envs/dev" "providers lock"
  assert_output "$(expected_lock_call dev)"

  local initLine lockLine
  initLine="$(call_line_number "-chdir=${_dsbTfEnvsDirList[dev]} init")"
  lockLine="$(call_line_number "$(expected_lock_call dev)")"
  [ "${initLine}" -lt "${lockLine}" ]
}

@test "tf-lock-env locks with the same platforms as tf-upgrade-env" {
  run tf-upgrade-env dev
  local upgradeLock
  upgradeLock="$(terraform_calls_in "envs/dev" "providers lock")"

  : >"${MOCK_TERRAFORM_CALLS_FILE}"
  run tf-lock-env dev
  local lockLock
  lockLock="$(terraform_calls_in "envs/dev" "providers lock")"

  [ -n "${lockLock}" ]
  [ "${lockLock}" == "${upgradeLock}" ]
}

@test "tf-lock-env uses the backend and sets ARM_SUBSCRIPTION_ID" {
  tf-lock-env dev >/dev/null 2>&1
  [ "${ARM_SUBSCRIPTION_ID}" == "00000000-0000-0000-0000-000000000001" ]

  run terraform_calls_in "envs/dev" "init"
  refute_output --partial "-backend=false"
}

@test "tf-lock-env works on the environment directory only" {
  run tf-lock-env dev
  assert_success

  run command grep -c -- "^-chdir=" "${MOCK_TERRAFORM_CALLS_FILE}"
  assert_output "2"
  run terraform_calls_in "main" "init"
  assert_output ""
  run terraform_calls_in "envs/prod" "init"
  assert_output ""
}

@test "tf-lock-env leaves the environment selected" {
  tf-lock-env dev >/dev/null 2>&1
  [ "${_dsbTfSelectedEnv}" == "dev" ]
}

@test "tf-lock-env without argument uses the selected environment" {
  tf-set-env prod >/dev/null 2>&1
  : >"${MOCK_TERRAFORM_CALLS_FILE}"

  run tf-lock-env
  assert_success
  run terraform_calls_in "envs/prod" "providers lock"
  assert_output "$(expected_lock_call prod)"
}

@test "tf-lock-env without argument and no selected environment fails without running terraform" {
  export _dsbTfLogErrors=1
  run tf-lock-env
  assert_failure
  assert_output --partial "No environment selected"

  run command grep -c -- "^-chdir=" "${MOCK_TERRAFORM_CALLS_FILE}"
  assert_output "0"
}

@test "tf-lock-env with an unknown environment fails without running terraform" {
  run tf-lock-env does-not-exist
  assert_failure

  run command grep -c -- "^-chdir=" "${MOCK_TERRAFORM_CALLS_FILE}"
  assert_output "0"
}

@test "tf-lock-env fails and says so when providers lock fails" {
  export MOCK_TERRAFORM_FAIL_LOCK='*'
  export _dsbTfLogErrors=1
  run tf-lock-env dev
  assert_failure
  assert_output --partial "Could not retrieve providers for locking"
  assert_output --partial "terraform providers lock failed in"
  assert_output --partial "init of environment 'dev' failed"
}

@test "tf-lock-env fails and does not lock when init fails" {
  export MOCK_TERRAFORM_FAIL_INIT='*'
  run tf-lock-env dev
  assert_failure
  assert_no_providers_lock_calls
}

@test "tf-lock-env says which platforms it locks for" {
  export _dsbTfLogInfo=1
  run tf-lock-env dev
  assert_success
  assert_output --partial "windows_amd64 darwin_arm64 linux_amd64 linux_arm64"
}

@test "tf-lock-env preserves the caller's shell options, on success and on failure" {
  set -o pipefail
  local optsBefore optsAfter
  optsBefore="$(set +o)"

  tf-lock-env dev >/dev/null 2>&1 || true
  optsAfter="$(set +o)"
  [ "${optsBefore}" == "${optsAfter}" ]

  export MOCK_TERRAFORM_FAIL_LOCK='*'
  tf-lock-env dev >/dev/null 2>&1 || true
  optsAfter="$(set +o)"
  [ "${optsBefore}" == "${optsAfter}" ]
  set +o pipefail
}

# -------------------------------------------------------
# tf-lock-env-offline
# -------------------------------------------------------

@test "tf-lock-env-offline runs init -backend=false without -upgrade, then providers lock for all platforms" {
  run tf-lock-env-offline dev
  assert_success

  run terraform_calls_in "envs/dev" "init"
  assert_output --partial "-backend=false"
  refute_output --partial "-upgrade"

  run terraform_calls_in "envs/dev" "providers lock"
  assert_output "$(expected_lock_call dev)"
}

@test "tf-lock-env-offline succeeds when Azure auth is broken" {
  mock_az_not_logged_in
  run tf-lock-env-offline dev
  assert_success

  run terraform_calls_in "envs/dev" "providers lock"
  assert_output "$(expected_lock_call dev)"
}

@test "tf-lock-env-offline moves the local state file aside during init and restores it" {
  local envDir="${_dsbTfEnvsDirList[dev]}"
  mkdir -p "${envDir}/.terraform"
  echo '{"backend":"mock"}' >"${envDir}/.terraform/terraform.tfstate"

  # records whether terraform could see the local state file when it ran
  terraform() {
    if [[ "$*" == *" init "* ]] || [[ "$*" == *" providers lock "* ]]; then
      if [ -f "${envDir}/.terraform/terraform.tfstate" ]; then
        echo "state present: $*" >>"${MOCK_TERRAFORM_CALLS_FILE}"
      else
        echo "state absent: $*" >>"${MOCK_TERRAFORM_CALLS_FILE}"
      fi
    fi
    return 0
  }

  run tf-lock-env-offline dev
  assert_success

  run command grep -F -- " init " "${MOCK_TERRAFORM_CALLS_FILE}"
  assert_output --partial "state absent:"
  run command cat "${envDir}/.terraform/terraform.tfstate"
  assert_output '{"backend":"mock"}'
}

@test "tf-lock-env-offline fails when providers lock fails" {
  export MOCK_TERRAFORM_FAIL_LOCK='*'
  run tf-lock-env-offline dev
  assert_failure
}

# -------------------------------------------------------
# tf-lock-all and tf-lock-all-offline
# -------------------------------------------------------

@test "tf-lock-all runs init without -upgrade, then providers lock in every environment" {
  run tf-lock-all
  assert_success

  local envName
  for envName in dev prod; do
    run terraform_calls_in "envs/${envName}" "init"
    assert_output --partial "init -reconfigure -lock=false"
    refute_output --partial "-upgrade"
    refute_output --partial "-backend=false"

    run terraform_calls_in "envs/${envName}" "providers lock"
    assert_output "$(expected_lock_call "${envName}")"
  done
}

@test "tf-lock-all works on the environment directories only, not main or modules" {
  run tf-lock-all
  assert_success

  # one init and one providers lock per environment, nothing else
  run command grep -c -- "^-chdir=" "${MOCK_TERRAFORM_CALLS_FILE}"
  assert_output "4"
  run command grep -E -- "^-chdir=[^ ]*/(main|modules)[/ ]" "${MOCK_TERRAFORM_CALLS_FILE}"
  assert_failure
}

@test "tf-lock-all leaves no lock file outside the environment directories" {
  # like terraform: init writes a lock file in the directory it runs in
  terraform() {
    local arg
    for arg in "$@"; do
      if [[ "${arg}" == -chdir=* ]] && [[ "$*" == *" init "* ]]; then
        echo 'provider "registry.terraform.io/hashicorp/azurerm" {}' >"${arg#-chdir=}/.terraform.lock.hcl"
      fi
    done
    return 0
  }
  find "${project_dir}" -name ".terraform.lock.hcl" -not -path "${project_dir}/envs/*" -delete

  run tf-lock-all
  assert_success

  run find "${project_dir}" -name ".terraform.lock.hcl" -not -path "${project_dir}/envs/*"
  assert_output ""
}

@test "tf-lock-all clears the selected environment afterwards" {
  tf-set-env dev >/dev/null 2>&1
  tf-lock-all >/dev/null 2>&1
  [ -z "${_dsbTfSelectedEnv}" ]
}

@test "tf-lock-all reports success" {
  export _dsbTfLogInfo=1
  run tf-lock-all
  assert_success
  assert_output --partial "Initializing environment: envs/dev"
  assert_output --partial "Initializing environment: envs/prod"
  assert_output --partial "Providers lock complete."
}

@test "tf-lock-all locks the remaining environments when one fails, and fails" {
  export MOCK_TERRAFORM_FAIL_LOCK='*/envs/dev'
  export _dsbTfLogErrors=1
  run tf-lock-all
  assert_failure
  assert_output --partial "Providers lock failed for 1 of 2 environment(s): dev"
  assert_output --partial "providers lock failed for: dev"

  run terraform_calls_in "envs/prod" "providers lock"
  assert_output "$(expected_lock_call prod)"
}

@test "tf-lock-all names every environment that failed" {
  export MOCK_TERRAFORM_FAIL_LOCK='*'
  export _dsbTfLogErrors=1
  run tf-lock-all
  assert_failure
  assert_output --partial "Providers lock failed for 2 of 2 environment(s)"
  assert_output --partial "dev"
  assert_output --partial "prod"
}

@test "tf-lock-all fails when init fails, without locking" {
  export MOCK_TERRAFORM_FAIL_INIT='*'
  run tf-lock-all
  assert_failure
  assert_no_providers_lock_calls
}

@test "tf-lock-all clears the selected environment also when it fails" {
  tf-set-env dev >/dev/null 2>&1
  export MOCK_TERRAFORM_FAIL_LOCK='*'
  tf-lock-all >/dev/null 2>&1 || true
  [ -z "${_dsbTfSelectedEnv}" ]
}

@test "tf-lock-all fails when the project has no environments" {
  rm -rf "${project_dir}/envs/"*
  export _dsbTfLogErrors=1
  run tf-lock-all
  assert_failure
  assert_output --partial "No environments found"

  run command grep -c -- "^-chdir=" "${MOCK_TERRAFORM_CALLS_FILE}"
  assert_output "0"
}

@test "tf-lock-all-offline runs init -backend=false without -upgrade, then providers lock in every environment" {
  run tf-lock-all-offline
  assert_success

  local envName
  for envName in dev prod; do
    run terraform_calls_in "envs/${envName}" "init"
    assert_output --partial "-backend=false"
    refute_output --partial "-upgrade"

    run terraform_calls_in "envs/${envName}" "providers lock"
    assert_output "$(expected_lock_call "${envName}")"
  done

  run command grep -E -- "^-chdir=[^ ]*/(main|modules)[/ ]" "${MOCK_TERRAFORM_CALLS_FILE}"
  assert_failure
}

@test "tf-lock-all-offline succeeds when Azure auth is broken" {
  mock_az_not_logged_in
  run tf-lock-all-offline
  assert_success
}

@test "tf-lock-all preserves the caller's shell options" {
  set -o pipefail
  local optsBefore optsAfter
  optsBefore="$(set +o)"
  tf-lock-all >/dev/null 2>&1 || true
  optsAfter="$(set +o)"
  [ "${optsBefore}" == "${optsAfter}" ]
  set +o pipefail
}
