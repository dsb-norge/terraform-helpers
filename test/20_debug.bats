#!/usr/bin/env bats
load 'helpers/test_helper'

setup() {
  export BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-${BATS_FILE_TMPDIR}}"
  source_script_in_project
  default_test_setup
}

teardown() {
  default_test_teardown
}

# ---------------------------------------------------------------------------
# Debug logging is off by default
# ---------------------------------------------------------------------------
@test "debug logging off by default" {
  # _dsbTfLogDebug is set to 0 by default_test_setup but the script default is also 0
  local val="${_dsbTfLogDebug:-0}"
  [[ "${val}" == "0" ]]
}

# ---------------------------------------------------------------------------
# _dsb_tf_debug_enable_debug_logging sets flag
# ---------------------------------------------------------------------------
@test "_dsb_tf_debug_enable_debug_logging sets _dsbTfLogDebug to 1" {
  _dsb_tf_debug_enable_debug_logging
  [[ "${_dsbTfLogDebug}" == "1" ]]
}

# ---------------------------------------------------------------------------
# _dsb_tf_debug_disable_debug_logging unsets flag
# ---------------------------------------------------------------------------
@test "_dsb_tf_debug_disable_debug_logging unsets _dsbTfLogDebug" {
  _dsb_tf_debug_enable_debug_logging
  [[ "${_dsbTfLogDebug}" == "1" ]]

  _dsb_tf_debug_disable_debug_logging
  [[ -z "${_dsbTfLogDebug:-}" ]]
}

# ---------------------------------------------------------------------------
# Debug output appears when enabled
# ---------------------------------------------------------------------------
@test "debug output appears when enabled" {
  _dsb_tf_debug_enable_debug_logging
  local out
  out="$(_dsb_d "test debug message" 2>&1)"
  local clean
  clean="$(strip_ansi "${out}")"
  [[ "${clean}" == *"DEBUG"* ]]
  [[ "${clean}" == *"test debug message"* ]]
}

# ---------------------------------------------------------------------------
# Debug output absent when disabled
# ---------------------------------------------------------------------------
@test "debug output absent when disabled" {
  _dsb_tf_debug_disable_debug_logging
  local out
  out="$(_dsb_d "test debug message" 2>&1)"
  [[ -z "${out}" ]]
}

# ---------------------------------------------------------------------------
# Debug output absent by default (without explicit disable)
# ---------------------------------------------------------------------------
@test "debug output absent by default" {
  # _dsbTfLogDebug=0 from default_test_setup
  local out
  out="$(_dsb_d "should not appear" 2>&1)"
  [[ -z "${out}" ]]
}

# ---------------------------------------------------------------------------
# Enable then disable is idempotent
# ---------------------------------------------------------------------------
@test "enable then disable is idempotent" {
  _dsb_tf_debug_enable_debug_logging
  _dsb_tf_debug_disable_debug_logging
  _dsb_tf_debug_enable_debug_logging
  [[ "${_dsbTfLogDebug}" == "1" ]]
  _dsb_tf_debug_disable_debug_logging
  [[ -z "${_dsbTfLogDebug:-}" ]]
}

# ---------------------------------------------------------------------------
# Debug output includes caller function name
# ---------------------------------------------------------------------------
@test "debug output includes caller function name" {
  _dsb_tf_debug_enable_debug_logging
  # Call _dsb_d from a named function to check caller tracking
  _test_debug_caller() {
    _dsb_d "caller test"
  }
  local out
  out="$(_test_debug_caller 2>&1)"
  local clean
  clean="$(strip_ansi "${out}")"
  [[ "${clean}" == *"_test_debug_caller"* ]]
}
