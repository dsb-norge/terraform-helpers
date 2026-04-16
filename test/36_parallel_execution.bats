#!/usr/bin/env bats
# shellcheck disable=SC2164,SC1090,SC1091,SC2030,SC2031,SC2034,SC2154,SC2317
#
# Tests for parallel test execution (--max-parallel flag)
# Used by tf-test-all-integrations and tf-test-all-examples
#
load 'helpers/test_helper'

setup_module_fixture() {
  export _MODULE_DIR="${BATS_FILE_TMPDIR}/module_project_${BATS_TEST_NUMBER}"
  cp -r "${FIXTURES_DIR}/project_module" "${_MODULE_DIR}"
  cd "${_MODULE_DIR}"
  mock_standard_tools
  source "${SUT}"
  default_test_setup
}

# ---------------------------------------------------------------------------
# --max-parallel flag parsing
# ---------------------------------------------------------------------------

@test "tf-test-all-integrations accepts --max-parallel=N" {
  setup_module_fixture
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    cd "'"${_MODULE_DIR}"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=1; _dsbTfLogWarnings=0; _dsbTfLogErrors=0; _dsbTfLogDebug=0
    echo "mock-sub-dev" | tf-test-all-integrations --max-parallel=2
  '
  assert_success
}

@test "tf-test-all-examples accepts --max-parallel=N" {
  setup_module_fixture
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    cd "'"${_MODULE_DIR}"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=1; _dsbTfLogWarnings=0; _dsbTfLogErrors=0; _dsbTfLogDebug=0
    echo "mock-sub-dev" | tf-test-all-examples --max-parallel=2
  '
  assert_success
}

@test "tf-test-all-integrations defaults to max-parallel=10" {
  setup_module_fixture
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    cd "'"${_MODULE_DIR}"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=1; _dsbTfLogWarnings=0; _dsbTfLogErrors=0; _dsbTfLogDebug=0
    echo "mock-sub-dev" | tf-test-all-integrations
  '
  assert_success
}

@test "--max-parallel=0 is treated as 1" {
  setup_module_fixture
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    cd "'"${_MODULE_DIR}"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=1; _dsbTfLogWarnings=0; _dsbTfLogErrors=0; _dsbTfLogDebug=0
    echo "mock-sub-dev" | tf-test-all-integrations --max-parallel=0
  '
  assert_success
}

# ---------------------------------------------------------------------------
# Parallel runner: progress and summary output
# ---------------------------------------------------------------------------

@test "parallel runner shows per-job results in summary" {
  setup_module_fixture
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    cd "'"${_MODULE_DIR}"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=1; _dsbTfLogWarnings=0; _dsbTfLogErrors=0; _dsbTfLogDebug=0
    echo "mock-sub-dev" | tf-test-all-integrations --max-parallel=2
  '
  assert_success
  # Should show summary with pass/fail counts
  assert_clean_output_contains "passed"
  assert_clean_output_contains "out of"
}

@test "parallel runner shows per-example results for tf-test-all-examples" {
  setup_module_fixture
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    cd "'"${_MODULE_DIR}"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=1; _dsbTfLogWarnings=0; _dsbTfLogErrors=0; _dsbTfLogDebug=0
    echo "mock-sub-dev" | tf-test-all-examples --max-parallel=2
  '
  assert_success
  assert_clean_output_contains "passed"
}

# ---------------------------------------------------------------------------
# Parallel runner: failure handling
# ---------------------------------------------------------------------------

@test "parallel runner reports failed jobs" {
  setup_module_fixture
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    cd "'"${_MODULE_DIR}"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=1; _dsbTfLogWarnings=0; _dsbTfLogErrors=1; _dsbTfLogDebug=0
    # Mock terraform to fail for one specific test
    terraform() {
      for arg in "$@"; do
        if [[ "${arg}" == *"integration-test-02"* ]]; then
          echo "Error: mock failure for test 02" >&2
          return 1
        fi
      done
      echo "Terraform mock: $*"
      return 0
    }
    export -f terraform
    echo "mock-sub-dev" | tf-test-all-integrations --max-parallel=3
  '
  assert_failure
  assert_clean_output_contains "failed"
  assert_clean_output_contains "integration-test-02"
}

@test "parallel runner returns non-zero when any job fails" {
  setup_module_fixture
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    cd "'"${_MODULE_DIR}"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=0; _dsbTfLogWarnings=0; _dsbTfLogErrors=0; _dsbTfLogDebug=0
    # Mock terraform to always fail
    terraform() { return 1; }
    export -f terraform
    echo "mock-sub-dev" | tf-test-all-integrations --max-parallel=2
  '
  assert_failure
}

# ---------------------------------------------------------------------------
# Sequential mode (--max-parallel=1) behaves like before
# ---------------------------------------------------------------------------

@test "sequential mode runs tests one at a time" {
  setup_module_fixture
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    cd "'"${_MODULE_DIR}"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=1; _dsbTfLogWarnings=0; _dsbTfLogErrors=0; _dsbTfLogDebug=0
    echo "mock-sub-dev" | tf-test-all-integrations --max-parallel=1
  '
  assert_success
}

# ---------------------------------------------------------------------------
# Combining with --log
# ---------------------------------------------------------------------------

@test "--max-parallel combines with --log" {
  setup_module_fixture
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    cd "'"${_MODULE_DIR}"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=1; _dsbTfLogWarnings=0; _dsbTfLogErrors=0; _dsbTfLogDebug=0
    echo "mock-sub-dev" | tf-test-all-integrations --max-parallel=2 --log
  '
  assert_success
}
