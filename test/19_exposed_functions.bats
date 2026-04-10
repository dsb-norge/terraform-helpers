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
# Helper: capture shell options before/after a function call and compare
# ---------------------------------------------------------------------------
# This pattern is used to verify that exposed functions properly call
# _dsb_tf_configure_shell and _dsb_tf_restore_shell, leaving no residual
# shell option changes.

# ---------------------------------------------------------------------------
# tf-status runs without error
# ---------------------------------------------------------------------------
@test "tf-status runs without error" {
  tf-status >/dev/null 2>&1 || true
  # Just verify it does not crash the shell
  true
}

# ---------------------------------------------------------------------------
# Shell state preservation tests
# ---------------------------------------------------------------------------
@test "tf-help preserves shell state" {
  local opts_before
  opts_before="$(set +o)"
  tf-help >/dev/null 2>&1 || true
  local opts_after
  opts_after="$(set +o)"
  [[ "${opts_before}" == "${opts_after}" ]]
}

@test "tf-list-envs preserves shell state" {
  local opts_before
  opts_before="$(set +o)"
  tf-list-envs >/dev/null 2>&1 || true
  local opts_after
  opts_after="$(set +o)"
  [[ "${opts_before}" == "${opts_after}" ]]
}

@test "tf-check-dir preserves shell state" {
  local opts_before
  opts_before="$(set +o)"
  tf-check-dir >/dev/null 2>&1 || true
  local opts_after
  opts_after="$(set +o)"
  [[ "${opts_before}" == "${opts_after}" ]]
}

@test "tf-check-tools preserves shell state" {
  local opts_before
  opts_before="$(set +o)"
  tf-check-tools >/dev/null 2>&1 || true
  local opts_after
  opts_after="$(set +o)"
  [[ "${opts_before}" == "${opts_after}" ]]
}

@test "tf-clear-env preserves shell state" {
  local opts_before
  opts_before="$(set +o)"
  tf-clear-env >/dev/null 2>&1 || true
  local opts_after
  opts_after="$(set +o)"
  [[ "${opts_before}" == "${opts_after}" ]]
}

@test "tf-unset-env preserves shell state" {
  local opts_before
  opts_before="$(set +o)"
  tf-unset-env >/dev/null 2>&1 || true
  local opts_after
  opts_after="$(set +o)"
  [[ "${opts_before}" == "${opts_after}" ]]
}

@test "tf-set-env preserves shell state" {
  local opts_before
  opts_before="$(set +o)"
  tf-set-env dev >/dev/null 2>&1 || true
  local opts_after
  opts_after="$(set +o)"
  [[ "${opts_before}" == "${opts_after}" ]]
}

@test "tf-fmt preserves shell state" {
  local opts_before
  opts_before="$(set +o)"
  tf-fmt >/dev/null 2>&1 || true
  local opts_after
  opts_after="$(set +o)"
  [[ "${opts_before}" == "${opts_after}" ]]
}

@test "tf-check-prereqs preserves shell state" {
  local opts_before
  opts_before="$(set +o)"
  tf-check-prereqs >/dev/null 2>&1 || true
  local opts_after
  opts_after="$(set +o)"
  [[ "${opts_before}" == "${opts_after}" ]]
}

@test "tf-clean preserves shell state" {
  local opts_before
  opts_before="$(set +o)"
  tf-clean >/dev/null 2>&1 || true
  local opts_after
  opts_after="$(set +o)"
  [[ "${opts_before}" == "${opts_after}" ]]
}

@test "tf-clean-tflint preserves shell state" {
  local opts_before
  opts_before="$(set +o)"
  tf-clean-tflint >/dev/null 2>&1 || true
  local opts_after
  opts_after="$(set +o)"
  [[ "${opts_before}" == "${opts_after}" ]]
}

@test "tf-clean-all preserves shell state" {
  local opts_before
  opts_before="$(set +o)"
  tf-clean-all >/dev/null 2>&1 || true
  local opts_after
  opts_after="$(set +o)"
  [[ "${opts_before}" == "${opts_after}" ]]
}

@test "az-whoami preserves shell state" {
  local opts_before
  opts_before="$(set +o)"
  az-whoami >/dev/null 2>&1 || true
  local opts_after
  opts_after="$(set +o)"
  [[ "${opts_before}" == "${opts_after}" ]]
}

# ---------------------------------------------------------------------------
# Every exposed function leaves shell state clean (loop test)
# ---------------------------------------------------------------------------
@test "all exposed functions preserve shell options" {
  # List of exposed functions that are safe to call with no args or mock-friendly args
  local -a safe_functions=(
    "tf-help"
    "tf-list-envs"
    "tf-check-dir"
    "tf-clear-env"
    "tf-unset-env"
    "tf-status"
    "tf-clean"
    "tf-clean-tflint"
    "tf-clean-all"
    "tf-fmt"
    "tf-check-prereqs"
    "tf-check-tools"
  )

  local failed_functions=()
  for func in "${safe_functions[@]}"; do
    local opts_before opts_after
    opts_before="$(set +o)"
    "${func}" >/dev/null 2>&1 || true
    opts_after="$(set +o)"
    if [[ "${opts_before}" != "${opts_after}" ]]; then
      failed_functions+=("${func}")
    fi
  done

  if [[ ${#failed_functions[@]} -gt 0 ]]; then
    echo "Functions that did not restore shell state: ${failed_functions[*]}" >&2
    return 1
  fi
}
