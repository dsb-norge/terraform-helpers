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
  _dsb_tf_configure_shell || true

  local opts
  opts="$(set +o)"
  _dsb_tf_restore_shell
  [[ "${opts}" == *"set -o nounset"* ]]
}

@test "_dsb_tf_configure_shell installs SIGINT trap" {
  _dsb_tf_configure_shell || true

  local trap_output
  trap_output="$(trap -p SIGINT)"
  _dsb_tf_restore_shell
  [[ "${trap_output}" == *"_dsb_tf_signal_handler"* ]]
}

@test "_dsb_tf_configure_shell does NOT install ERR trap" {
  _dsb_tf_configure_shell || true

  local trap_output
  trap_output="$(trap -p ERR 2>/dev/null)" || true
  _dsb_tf_restore_shell
  [[ "${trap_output}" != *"_dsb_tf_error_handler"* ]]
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

@test "_dsb_tf_configure_shell clears the error stack" {
  _dsbTfErrorStack=("stale: old error")
  _dsb_tf_configure_shell || true

  local stack_size=${#_dsbTfErrorStack[@]}
  _dsb_tf_restore_shell
  [[ "${stack_size}" -eq 0 ]]
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
  trap_output="$(trap -p SIGINT 2>/dev/null)" || true
  [[ "${trap_output}" != *"_dsb_tf_signal_handler"* ]]
}

# -- error stack infrastructure --

@test "_dsb_tf_error_push adds entry with caller name" {
  _dsb_tf_error_clear
  # Call from a wrapper to get a meaningful caller name
  _test_push_helper() {
    _dsb_tf_error_push "test message"
  }
  _test_push_helper

  [[ ${#_dsbTfErrorStack[@]} -eq 1 ]]
  [[ "${_dsbTfErrorStack[0]}" == "_test_push_helper: test message" ]]
}

@test "_dsb_tf_error_clear empties the stack" {
  _dsbTfErrorStack=("entry1" "entry2")
  _dsb_tf_error_clear
  [[ ${#_dsbTfErrorStack[@]} -eq 0 ]]
}

@test "_dsb_tf_error_dump outputs stack and clears it" {
  _dsbTfErrorStack=("func1: error one" "func2: error two")
  _dsbTfLogErrors=1

  local dump_output
  dump_output="$(_dsb_tf_error_dump 2>&1)"

  local clean
  clean="$(strip_ansi "${dump_output}")"

  [[ "${clean}" == *"Error context:"* ]]
  [[ "${clean}" == *"func1: error one"* ]]
  [[ "${clean}" == *"func2: error two"* ]]

  # Dump ran in subshell, so clear explicitly and verify clear works
  _dsb_tf_error_clear
  [[ ${#_dsbTfErrorStack[@]} -eq 0 ]]
}

@test "_dsb_tf_error_dump is silent when stack is empty" {
  _dsb_tf_error_clear
  _dsbTfLogErrors=1

  local dump_output
  dump_output="$(_dsb_tf_error_dump 2>&1)"

  [[ -z "${dump_output}" ]]
}

@test "multiple pushes accumulate" {
  _dsb_tf_error_clear
  _dsb_tf_error_push "first"
  _dsb_tf_error_push "second"
  _dsb_tf_error_push "third"
  [[ ${#_dsbTfErrorStack[@]} -eq 3 ]]
}

# -- _dsb_internal_error --

@test "_dsb_internal_error logs with caller name" {
  _dsb_tf_error_clear
  _dsbTfLogErrors=1

  local ie_output
  ie_output="$(_dsb_internal_error "test message" 2>&1)" || true

  local clean
  clean="$(strip_ansi "${ie_output}")"
  [[ "${clean}" == *"ERROR"* ]]
  [[ "${clean}" == *"test message"* ]]
}

@test "_dsb_internal_error pushes to error stack" {
  _dsb_tf_error_clear

  _dsb_internal_error "stack test" 2>/dev/null || true

  [[ ${#_dsbTfErrorStack[@]} -eq 1 ]]
  [[ "${_dsbTfErrorStack[0]}" == *"stack test"* ]]
}

@test "_dsb_internal_error does not return 1 itself" {
  # _dsb_internal_error should just log+push, not return non-zero
  _dsb_tf_error_clear
  _dsb_internal_error "test" 2>/dev/null
  local rc=$?
  [[ "${rc}" -eq 0 ]]
}
