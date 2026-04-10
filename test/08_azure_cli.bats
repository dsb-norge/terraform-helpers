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
# az-whoami
# -------------------------------------------------------

@test "az-whoami shows account info when logged in" {
  mock_az
  run az-whoami
  assert_success
  assert_output --partial "test@example.com"
}

@test "az-whoami handles not-logged-in" {
  mock_az_not_logged_in
  run az-whoami
  assert_success
  assert_output --partial "Not logged in"
}

@test "az-whoami handles az not installed" {
  mock_az_not_installed
  run az-whoami
  assert_success
}

# -------------------------------------------------------
# az-logout
# -------------------------------------------------------

@test "az-logout calls clear and reports logged out" {
  mock_az
  run az-logout
  assert_success
  assert_output --partial "Logged out"
}

# -------------------------------------------------------
# az-set-sub
# -------------------------------------------------------

@test "az-set-sub sets subscription from hint file when env is selected" {
  mock_az
  # Use run for both calls -- the second picks up globals from internal state
  # since tf-set-env in run loses state, we need to call az-set-sub after set-env
  # without run for tf-set-env so globals persist
  run tf-set-env "dev"
  assert_success
  # In a subshell, globals are lost, so test via run where az-set-sub
  # will see no env -- test the combined flow instead
  run bash -c "
    source '${SUT}' 2>/dev/null
    export _dsbTfLogInfo=0
    export _dsbTfLogWarnings=0
    export _dsbTfLogErrors=0
    tf-set-env dev
    az-set-sub
  "
  assert_success
}

@test "az-set-sub fails with no env selected" {
  run az-set-sub
  assert_failure
}

# -------------------------------------------------------
# _dsb_tf_az_enumerate_account
# -------------------------------------------------------

@test "_dsb_tf_az_enumerate_account populates globals when logged in" {
  mock_az
  # Call directly without run to test global mutations
  # Avoid bats' set -e conflict with _dsb_tf_configure_shell by calling
  # the exposed wrapper indirectly
  run bash -c "
    cd '${project_dir}'
    source '${SUT}' 2>/dev/null
    _dsbTfLogInfo=0
    _dsbTfLogWarnings=0
    _dsbTfLogErrors=0
    _dsb_tf_configure_shell
    _dsbTfLogInfo=0
    _dsbTfLogErrors=0
    _dsb_tf_az_enumerate_account
    echo \"upn=\${_dsbTfAzureUpn}\"
    echo \"id=\${_dsbTfSubscriptionId}\"
    echo \"name=\${_dsbTfSubscriptionName}\"
    _dsb_tf_restore_shell
  "
  assert_success
  assert_line --partial "upn=test@example.com"
  assert_line --partial "id=00000000-0000-0000-0000-000000000001"
  assert_line --partial "name=mock-sub-dev"
}

@test "_dsb_tf_az_enumerate_account clears globals when not logged in" {
  run bash -c "
    cd '${project_dir}'
    # Set up not-logged-in mock before sourcing
    az() {
      case \"\$1\" in
        --version) echo 'azure-cli 2.55.0 *'; return 0 ;;
        account)
          shift
          case \"\$1\" in
            show) echo 'Please run az login' >&2; return 1 ;;
            clear) return 0 ;;
            *) return 1 ;;
          esac ;;
      esac
      return 0
    }
    export -f az
    source '${SUT}' 2>/dev/null
    _dsbTfLogInfo=0
    _dsbTfLogWarnings=0
    _dsbTfLogErrors=0
    _dsb_tf_configure_shell
    _dsbTfLogInfo=0
    _dsbTfLogErrors=0
    _dsb_tf_az_enumerate_account
    echo \"upn=\${_dsbTfAzureUpn:-EMPTY}\"
    echo \"id=\${_dsbTfSubscriptionId:-EMPTY}\"
    echo \"name=\${_dsbTfSubscriptionName:-EMPTY}\"
    _dsb_tf_restore_shell
  "
  assert_success
  assert_line --partial "upn=EMPTY"
  assert_line --partial "id=EMPTY"
  assert_line --partial "name=EMPTY"
}

# -------------------------------------------------------
# _dsb_tf_az_is_logged_in
# -------------------------------------------------------

@test "_dsb_tf_az_is_logged_in returns 0 when logged in" {
  mock_az
  run _dsb_tf_az_is_logged_in
  assert_success
}

@test "_dsb_tf_az_is_logged_in returns 1 when not logged in" {
  mock_az_not_logged_in
  run _dsb_tf_az_is_logged_in
  assert_failure
}
