#!/usr/bin/env bats
load 'helpers/test_helper'

setup_file() {
  export _ERR_TEST_PROJECT="${BATS_FILE_TMPDIR}/project"
  cp -r "${FIXTURES_DIR}/project_standard" "${_ERR_TEST_PROJECT}"
}

setup() {
  cd "${_ERR_TEST_PROJECT}"
  mock_standard_tools
  source "${SUT}"
  default_test_setup
}

teardown() {
  default_test_teardown
}

# -- _dsb_tf_configure_shell --

@test "_dsb_tf_configure_shell enables set -u" {
  # shopt -o history returns 1 in non-interactive shells, which trips bats' set -e
  _dsb_tf_configure_shell || true

  local opts
  opts="$(set +o)"
  # Must restore before any assertion (ERR trap interferes with assertion internals)
  _dsb_tf_restore_shell
  [[ "${opts}" == *"set -o nounset"* ]]
}

@test "_dsb_tf_configure_shell installs ERR trap" {
  _dsb_tf_configure_shell || true

  local trap_output
  trap_output="$(trap -p ERR)"
  _dsb_tf_restore_shell
  [[ "${trap_output}" == *"_dsb_tf_error_handler"* ]]
}

@test "_dsb_tf_configure_shell sets logging flags to 1" {
  _dsb_tf_configure_shell || true

  local info_val="${_dsbTfLogInfo}"
  local warn_val="${_dsbTfLogWarnings}"
  local err_val="${_dsbTfLogErrors}"
  _dsb_tf_restore_shell

  [[ "${info_val}" == "1" ]]
  [[ "${warn_val}" == "1" ]]
  [[ "${err_val}" == "1" ]]
}

# -- _dsb_tf_restore_shell --

@test "_dsb_tf_restore_shell restores original shell state" {
  local opts_before
  opts_before="$(set +o)"

  _dsb_tf_configure_shell || true
  _dsb_tf_restore_shell

  local opts_after
  opts_after="$(set +o)"

  [[ "${opts_before}" == "${opts_after}" ]]
}

@test "configure then restore is a no-op on shell state" {
  _dsb_tf_configure_shell || true
  _dsb_tf_restore_shell

  local trap_output
  trap_output="$(trap -p ERR 2>/dev/null)" || true
  [[ "${trap_output}" != *"_dsb_tf_error_handler"* ]]
}

# -- _dsb_tf_error_handler --

@test "_dsb_tf_error_handler logs error details" {
  _dsb_tf_configure_shell || true
  _dsbTfLogErrors=1

  # Capture output in a variable (run would work but let's avoid trap interference)
  local handler_output
  handler_output="$(_dsb_tf_error_handler 42 2>&1)" || true

  # Restore before assertions
  _dsb_tf_restore_shell

  local clean
  clean="$(strip_ansi "${handler_output}")"
  [[ "${clean}" == *"Error occurred"* ]]
  [[ "${clean}" == *"exit code"* ]]
}

@test "_dsb_tf_error_handler sets _dsbTfReturnCode" {
  _dsb_tf_configure_shell || true

  _dsbTfLogErrors=0
  _dsb_tf_error_handler 77 || true

  local saved_code="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell

  [[ "${saved_code}" == "77" ]]
}

# -- _dsb_internal_error --

@test "_dsb_internal_error logs with caller name" {
  _dsb_tf_configure_shell || true
  _dsbTfLogErrors=1

  local ie_output
  ie_output="$(_dsb_internal_error "test message" 2>&1)" || true

  _dsb_tf_restore_shell

  local clean
  clean="$(strip_ansi "${ie_output}")"
  [[ "${clean}" == *"ERROR"* ]]
  [[ "${clean}" == *"test message"* ]]
}

# -- _dsb_ie_raise_error --

@test "_dsb_ie_raise_error returns 1" {
  run _dsb_ie_raise_error
  assert_failure
  [[ "${status}" -eq 1 ]]
}
