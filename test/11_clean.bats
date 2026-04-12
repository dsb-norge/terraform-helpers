#!/usr/bin/env bats
# shellcheck disable=SC2164,SC1090,SC1091,SC2030,SC2031,SC2034,SC2154,SC2317
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
# tf-clean
# -------------------------------------------------------

@test "tf-clean finds .terraform directories" {
  # Create .terraform dirs
  mkdir -p "${project_dir}/envs/dev/.terraform"
  mkdir -p "${project_dir}/envs/prod/.terraform"

  # Run tf-clean and answer "n" to cancel
  run bash -c "
    cd '${project_dir}'
    source '${SUT}' 2>/dev/null
    export _dsbTfLogInfo=1
    export _dsbTfLogWarnings=0
    export _dsbTfLogErrors=0
    echo 'n' | tf-clean
  "
  assert_success
  assert_output --partial ".terraform"
  assert_output --partial "Ready to delete"
}

@test "tf-clean deletes on y confirmation" {
  mkdir -p "${project_dir}/envs/dev/.terraform"

  # pipe "y" to tf-clean via a subshell
  run bash -c "
    cd '${project_dir}'
    source '${SUT}' 2>/dev/null
    export _dsbTfLogInfo=0
    export _dsbTfLogWarnings=0
    export _dsbTfLogErrors=0
    echo 'y' | tf-clean
  "
  assert_success
  # The .terraform dir should be gone
  [[ ! -d "${project_dir}/envs/dev/.terraform" ]]
}

@test "tf-clean cancels on n" {
  mkdir -p "${project_dir}/envs/dev/.terraform"

  run bash -c "
    cd '${project_dir}'
    source '${SUT}' 2>/dev/null
    export _dsbTfLogInfo=0
    export _dsbTfLogWarnings=0
    export _dsbTfLogErrors=0
    echo 'n' | tf-clean
  "
  assert_success
  # The .terraform dir should still exist
  [[ -d "${project_dir}/envs/dev/.terraform" ]]
}

# -------------------------------------------------------
# tf-clean-tflint
# -------------------------------------------------------

@test "tf-clean-tflint targets .tflint dirs" {
  mkdir -p "${project_dir}/.tflint"

  run bash -c "
    cd '${project_dir}'
    source '${SUT}' 2>/dev/null
    export _dsbTfLogInfo=0
    export _dsbTfLogWarnings=0
    export _dsbTfLogErrors=0
    echo 'y' | tf-clean-tflint
  "
  assert_success
  [[ ! -d "${project_dir}/.tflint" ]]
}

# -------------------------------------------------------
# tf-clean-all
# -------------------------------------------------------

@test "tf-clean-all targets both terraform and tflint dirs" {
  mkdir -p "${project_dir}/envs/dev/.terraform"
  mkdir -p "${project_dir}/.tflint"

  run bash -c "
    cd '${project_dir}'
    source '${SUT}' 2>/dev/null
    export _dsbTfLogInfo=0
    export _dsbTfLogWarnings=0
    export _dsbTfLogErrors=0
    echo 'y' | tf-clean-all
  "
  assert_success
  [[ ! -d "${project_dir}/envs/dev/.terraform" ]]
  [[ ! -d "${project_dir}/.tflint" ]]
}

# -------------------------------------------------------
# No dirs found
# -------------------------------------------------------

@test "tf-clean reports nothing to clean when no dirs found" {
  # Ensure no .terraform dirs exist
  rm -rf "${project_dir}"/envs/dev/.terraform
  rm -rf "${project_dir}"/envs/prod/.terraform
  rm -rf "${project_dir}"/main/.terraform
  rm -rf "${project_dir}"/modules/networking/.terraform
  rm -rf "${project_dir}"/.terraform

  run tf-clean
  assert_success
  assert_output --partial "nothing to clean"
}
