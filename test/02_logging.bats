#!/usr/bin/env bats
load 'helpers/test_helper'

setup_file() {
  export _LOG_TEST_PROJECT="${BATS_FILE_TMPDIR}/project"
  cp -r "${FIXTURES_DIR}/project_standard" "${_LOG_TEST_PROJECT}"
}

setup() {
  cd "${_LOG_TEST_PROJECT}"
  mock_standard_tools
  source "${SUT}"
  # Mute all logging by default -- tests enable what they need
  export _dsbTfLogInfo=0
  export _dsbTfLogWarnings=0
  export _dsbTfLogErrors=0
  export _dsbTfLogDebug=0
}

teardown() {
  default_test_teardown
}

# -- _dsb_e (error logger) --

@test "_dsb_e produces ERROR in output when enabled" {
  _dsbTfLogErrors=1
  run _dsb_e "something went wrong"
  assert_success
  assert_clean_output_contains "ERROR"
  assert_clean_output_contains "something went wrong"
}

@test "_dsb_e is muted when _dsbTfLogErrors=0" {
  _dsbTfLogErrors=0
  run _dsb_e "hidden error"
  assert_success
  assert_output ""
}

# -- _dsb_ie (internal error logger, always logs) --

@test "_dsb_ie always produces output even when _dsbTfLogErrors=0" {
  _dsbTfLogErrors=0
  run _dsb_ie "my_function" "internal failure"
  assert_success
  assert_clean_output_contains "ERROR"
  assert_clean_output_contains "my_function"
  assert_clean_output_contains "internal failure"
}

# -- _dsb_i (info logger) --

@test "_dsb_i produces INFO in output when enabled" {
  _dsbTfLogInfo=1
  run _dsb_i "some info message"
  assert_success
  assert_clean_output_contains "INFO"
  assert_clean_output_contains "some info message"
}

@test "_dsb_i is muted when _dsbTfLogInfo=0" {
  _dsbTfLogInfo=0
  run _dsb_i "hidden info"
  assert_success
  assert_output ""
}

# -- _dsb_w (warning logger) --

@test "_dsb_w produces WARNING in output when enabled" {
  _dsbTfLogWarnings=1
  run _dsb_w "a warning"
  assert_success
  assert_clean_output_contains "WARNING"
  assert_clean_output_contains "a warning"
}

@test "_dsb_w is muted when _dsbTfLogWarnings=0" {
  _dsbTfLogWarnings=0
  run _dsb_w "hidden warning"
  assert_success
  assert_output ""
}

# -- _dsb_d (debug logger) --

@test "_dsb_d produces DEBUG only when _dsbTfLogDebug=1" {
  _dsbTfLogDebug=1
  run _dsb_d "debug trace"
  assert_success
  assert_clean_output_contains "DEBUG"
  assert_clean_output_contains "debug trace"
}

@test "_dsb_d is silent when debug is off" {
  _dsbTfLogDebug=0
  run _dsb_d "secret debug"
  assert_success
  assert_output ""
}
