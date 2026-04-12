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

# -- Phase 5: _dsb_tf_require_azure_subscription --

@test "_dsb_tf_require_azure_subscription fails when az not installed" {
  setup_module_fixture
  mock_az_not_installed
  _dsbTfLogErrors=1
  run _dsb_tf_require_azure_subscription
  assert_failure
  assert_clean_output_contains "not installed"
}

@test "_dsb_tf_require_azure_subscription fails when not logged in" {
  setup_module_fixture
  mock_az_not_logged_in
  _dsbTfLogErrors=1
  run _dsb_tf_require_azure_subscription
  assert_failure
  assert_clean_output_contains "Not logged in"
}

@test "_dsb_tf_require_azure_subscription fails when user says no" {
  setup_module_fixture
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    cd "'"${_MODULE_DIR}"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=0
    _dsbTfLogWarnings=1
    _dsbTfLogErrors=0
    _dsbTfLogDebug=0
    echo "wrong-name" | _dsb_tf_require_azure_subscription
  '
  assert_failure
}

@test "_dsb_tf_require_azure_subscription succeeds when user says yes" {
  setup_module_fixture
  # We need to run in a subshell so the mock for az is available
  # Use here-string redirect instead of pipe to avoid subshell issues with export
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    cd "'"${_MODULE_DIR}"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=0
    _dsbTfLogWarnings=0
    _dsbTfLogErrors=0
    _dsbTfLogDebug=0
    _dsb_tf_require_azure_subscription <<< "mock-sub-dev"
    echo "ARM_SUBSCRIPTION_ID=${ARM_SUBSCRIPTION_ID}"
  '
  assert_success
  assert_clean_output_contains "ARM_SUBSCRIPTION_ID=00000000-0000-0000-0000-000000000001"
}

# -- Phase 5: tf-test-unit --

@test "tf-test-unit succeeds in module repo" {
  setup_module_fixture
  run tf-test-unit
  assert_success
}

@test "tf-test-unit outputs test info" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-test-unit
  assert_success
  assert_clean_output_contains "Running terraform test"
  assert_clean_output_contains "unit-tests.tftest.hcl"
}

@test "tf-test-unit fails in project repo" {
  local project_dir
  project_dir="$(create_standard_project)"
  cd "${project_dir}"
  mock_standard_tools
  source "${SUT}"
  default_test_setup

  run tf-test-unit
  assert_failure
  assert_clean_output_contains "only available in Terraform module repos"
}

@test "tf-test-unit with no unit tests reports nothing to do" {
  setup_module_fixture
  # Remove unit test files
  rm -f "${_MODULE_DIR}/tests/unit-"*.tftest.hcl
  _dsbTfLogWarnings=1
  run tf-test-unit
  assert_success
  assert_clean_output_contains "No unit test files found"
}

# -- Phase 5: tf-test-integration --

@test "tf-test-integration fails in project repo" {
  local project_dir
  project_dir="$(create_standard_project)"
  cd "${project_dir}"
  mock_standard_tools
  source "${SUT}"
  default_test_setup

  run tf-test-integration
  assert_failure
  assert_clean_output_contains "only available in Terraform module repos"
}

@test "tf-test-integration with no integration tests reports nothing to do" {
  setup_module_fixture
  rm -f "${_MODULE_DIR}/tests/integration-"*.tftest.hcl
  _dsbTfLogWarnings=1
  run tf-test-integration
  assert_success
  assert_clean_output_contains "No integration test files found"
}

@test "tf-test-integration requires subscription confirmation" {
  setup_module_fixture
  # Pipe 'n' to decline
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    cd "'"${_MODULE_DIR}"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=0
    _dsbTfLogWarnings=0
    _dsbTfLogErrors=0
    _dsbTfLogDebug=0
    echo "wrong-name" | tf-test-integration
  '
  assert_failure
}

@test "tf-test-integration succeeds with subscription confirmation" {
  setup_module_fixture
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    cd "'"${_MODULE_DIR}"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=0
    _dsbTfLogWarnings=0
    _dsbTfLogErrors=0
    _dsbTfLogDebug=0
    echo "mock-sub-dev" | tf-test-integration
  '
  assert_success
}

# -- Phase 5: tf-test --

@test "tf-test fails in project repo" {
  local project_dir
  project_dir="$(create_standard_project)"
  cd "${project_dir}"
  mock_standard_tools
  source "${SUT}"
  default_test_setup

  run tf-test
  assert_failure
  assert_clean_output_contains "only available in Terraform module repos"
}

@test "tf-test with specific filter runs that test" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-test "unit-tests.tftest.hcl"
  assert_success
  assert_clean_output_contains "unit-tests.tftest.hcl"
}

@test "tf-test without filter and integration tests needs subscription" {
  setup_module_fixture
  # Integration tests exist in fixture, so this should need subscription
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    cd "'"${_MODULE_DIR}"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=0
    _dsbTfLogWarnings=0
    _dsbTfLogErrors=0
    _dsbTfLogDebug=0
    echo "wrong-name" | tf-test
  '
  assert_failure
}

@test "tf-test without filter and only unit tests skips subscription" {
  setup_module_fixture
  # Remove integration tests so only unit tests remain
  rm -f "${_MODULE_DIR}/tests/integration-"*.tftest.hcl
  run tf-test
  assert_success
}

# -- Phase 5: tf-test-examples --

@test "tf-test-examples fails in project repo" {
  local project_dir
  project_dir="$(create_standard_project)"
  cd "${project_dir}"
  mock_standard_tools
  source "${SUT}"
  default_test_setup

  run tf-test-examples
  assert_failure
  assert_clean_output_contains "only available in Terraform module repos"
}

@test "tf-test-examples requires subscription confirmation" {
  setup_module_fixture
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    cd "'"${_MODULE_DIR}"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=0
    _dsbTfLogWarnings=0
    _dsbTfLogErrors=0
    _dsbTfLogDebug=0
    echo "wrong-name" | tf-test-examples
  '
  assert_failure
}

@test "tf-test-examples with subscription runs init+apply+destroy" {
  setup_module_fixture
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    cd "'"${_MODULE_DIR}"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=1
    _dsbTfLogWarnings=0
    _dsbTfLogErrors=0
    _dsbTfLogDebug=0
    echo "mock-sub-dev" | tf-test-examples
  '
  assert_success
  assert_clean_output_contains "terraform init"
  assert_clean_output_contains "terraform apply"
  assert_clean_output_contains "terraform destroy"
}

@test "tf-test-examples shows per-example summary" {
  setup_module_fixture
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    cd "'"${_MODULE_DIR}"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=1
    _dsbTfLogWarnings=0
    _dsbTfLogErrors=0
    _dsbTfLogDebug=0
    echo "mock-sub-dev" | tf-test-examples
  '
  assert_success
  assert_clean_output_contains "succeeded"
}

# -- Phase 5: Internal _dsb_tf_run_terraform_test --

@test "_dsb_tf_run_terraform_test succeeds in module repo" {
  setup_module_fixture
  run _dsb_tf_run_terraform_test
  assert_success
}

@test "_dsb_tf_run_terraform_test with filter" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run _dsb_tf_run_terraform_test "unit-tests.tftest.hcl"
  assert_success
  assert_clean_output_contains "unit-tests.tftest.hcl"
}

# -- tf-test-example (singular) --

@test "tf-test-example requires example name" {
  setup_module_fixture
  run tf-test-example
  assert_failure
  assert_clean_output_contains "No example specified"
  assert_clean_output_contains "usage"
}

@test "tf-test-example fails for nonexistent example" {
  setup_module_fixture
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    cd "'"${_MODULE_DIR}"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=0
    _dsbTfLogWarnings=0
    _dsbTfLogErrors=1
    _dsbTfLogDebug=0
    echo "mock-sub-dev" | tf-test-example "nonexistent"
  '
  assert_failure
  assert_clean_output_contains "not found"
}

@test "tf-test-example requires subscription confirmation" {
  setup_module_fixture
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    cd "'"${_MODULE_DIR}"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=0
    _dsbTfLogWarnings=0
    _dsbTfLogErrors=0
    _dsbTfLogDebug=0
    echo "wrong-name" | tf-test-example "01-basic"
  '
  assert_failure
}

@test "tf-test-example succeeds with correct subscription name" {
  setup_module_fixture
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    cd "'"${_MODULE_DIR}"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=1
    _dsbTfLogWarnings=0
    _dsbTfLogErrors=0
    _dsbTfLogDebug=0
    echo "mock-sub-dev" | tf-test-example "01-basic"
  '
  assert_success
  assert_clean_output_contains "01-basic"
}

@test "tf-test-example is module-only" {
  # Source in a project repo context, not module
  local project_dir
  project_dir="$(create_standard_project)"
  cd "${project_dir}"
  mock_standard_tools
  source "${SUT}"
  default_test_setup
  run tf-test-example "01-basic"
  assert_failure
  assert_clean_output_contains "only available in Terraform module repos"
}

@test "tf-test-example lists available examples when none specified" {
  setup_module_fixture
  run tf-test-example
  assert_failure
  assert_clean_output_contains "available examples"
}
