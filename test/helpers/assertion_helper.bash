#!/usr/bin/env bash
# assertion_helper.bash -- custom assertions

# Strip ANSI color/escape codes from a string
strip_ansi() {
  local input="${1:-}"
  if [[ -z "${input}" ]]; then
    sed 's/\x1b\[[0-9;]*[mGKHJ]//g'
  else
    echo "${input}" | sed 's/\x1b\[[0-9;]*[mGKHJ]//g'
  fi
}

# Assert a global variable has a specific value
# Usage: assert_global "_dsbTfSelectedEnv" "dev"
assert_global() {
  local var_name="$1"
  local expected="$2"
  local actual="${!var_name:-}"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "assert_global failed: expected ${var_name}='${expected}', got '${actual}'" >&2
    return 1
  fi
}

# Assert a global variable is set and non-empty
# Usage: assert_global_set "_dsbTfRootDir"
assert_global_set() {
  local var_name="$1"
  if [[ -z "${!var_name:-}" ]]; then
    echo "assert_global_set failed: ${var_name} is empty or unset" >&2
    return 1
  fi
}

# Assert a global variable is empty or unset
# Usage: assert_global_empty "_dsbTfSelectedEnv"
assert_global_empty() {
  local var_name="$1"
  if [[ -n "${!var_name:-}" ]]; then
    echo "assert_global_empty failed: expected ${var_name} to be empty, got '${!var_name}'" >&2
    return 1
  fi
}

# Assert that output (stripped of ANSI) contains a string
# Uses $output set by bats 'run'
# Usage: assert_clean_output_contains "ERROR"
assert_clean_output_contains() {
  local expected="$1"
  local clean
  clean="$(strip_ansi "${output}")"
  if [[ "${clean}" != *"${expected}"* ]]; then
    echo "assert_clean_output_contains failed: expected output to contain '${expected}'" >&2
    echo "Actual (first 500 chars): ${clean:0:500}" >&2
    return 1
  fi
}

# Assert that output (stripped of ANSI) does NOT contain a string
assert_clean_output_not_contains() {
  local unexpected="$1"
  local clean
  clean="$(strip_ansi "${output}")"
  if [[ "${clean}" == *"${unexpected}"* ]]; then
    echo "assert_clean_output_not_contains failed: output should not contain '${unexpected}'" >&2
    return 1
  fi
}

# Assert that a bash function is defined
# Usage: assert_function_exists "tf-init"
assert_function_exists() {
  local func_name="$1"
  if ! declare -F "${func_name}" &>/dev/null; then
    echo "assert_function_exists failed: function '${func_name}' is not defined" >&2
    return 1
  fi
}

# Assert that a bash function is NOT defined
assert_function_not_exists() {
  local func_name="$1"
  if declare -F "${func_name}" &>/dev/null; then
    echo "assert_function_not_exists failed: function '${func_name}' should not be defined" >&2
    return 1
  fi
}
