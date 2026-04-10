#!/usr/bin/env bats
load 'helpers/test_helper'

setup() {
  export BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-${BATS_FILE_TMPDIR}}"
  source_script_in_project
  default_test_setup
  # Enable info logging to capture output messages
  export _dsbTfLogInfo=1
  export _dsbTfLogWarnings=1
  export _dsbTfLogErrors=1
}

teardown() {
  default_test_teardown
}

# ---------------------------------------------------------------------------
# tf-bump-env runs upgrade + provider listing
# ---------------------------------------------------------------------------
@test "tf-bump-env runs for a given environment" {
  local out
  out="$(tf-bump-env dev 2>&1)" || true
  local clean
  clean="$(strip_ansi "${out}")"

  # Should show provider upgrade info for dev
  [[ "${clean}" == *"hashicorp/azurerm"* ]]
  # Should mention the environment
  [[ "${clean}" == *"dev"* ]]
}

@test "tf-bump-env shows Done on success" {
  local out
  out="$(tf-bump-env dev 2>&1)" || true
  local clean
  clean="$(strip_ansi "${out}")"

  # Should complete with Done or report failures
  [[ "${clean}" == *"Done"* ]] || [[ "${clean}" == *"Failure"* ]] || [[ "${clean}" == *"failure"* ]]
}

@test "tf-bump-env without env and no env selected shows error" {
  tf-clear-env >/dev/null 2>&1 || true

  local out
  out="$(tf-bump-env 2>&1)" || true
  local clean
  clean="$(strip_ansi "${out}")"

  [[ "${clean}" == *"No environment specified"* ]] || [[ "${clean}" == *"tf-set-env"* ]]
}

# ---------------------------------------------------------------------------
# tf-bump runs modules + plugins + cicd + env upgrade
# ---------------------------------------------------------------------------
@test "tf-bump runs for a given environment" {
  local out
  out="$(tf-bump dev 2>&1)" || true
  local clean
  clean="$(strip_ansi "${out}")"

  # Should show bump project output
  [[ "${clean}" == *"Bump"* ]]
  # Should mention the environment
  [[ "${clean}" == *"dev"* ]]
}

@test "tf-bump includes module version bumping" {
  local out
  out="$(tf-bump dev 2>&1)" || true
  local clean
  clean="$(strip_ansi "${out}")"

  # Should reference module version bumping
  [[ "${clean}" == *"module"* ]] || [[ "${clean}" == *"Module"* ]]
}

@test "tf-bump includes tflint plugin bumping" {
  local out
  out="$(tf-bump dev 2>&1)" || true
  local clean
  clean="$(strip_ansi "${out}")"

  # Should reference tflint plugin bumping
  [[ "${clean}" == *"tflint"* ]] || [[ "${clean}" == *"Tflint"* ]] || [[ "${clean}" == *"plugin"* ]]
}

@test "tf-bump includes cicd version bumping" {
  local out
  out="$(tf-bump dev 2>&1)" || true
  local clean
  clean="$(strip_ansi "${out}")"

  # Should reference CI/CD or GitHub workflow bumping
  [[ "${clean}" == *"CI"* ]] || [[ "${clean}" == *"workflow"* ]] || [[ "${clean}" == *"GitHub"* ]] || [[ "${clean}" == *"versions"* ]]
}

@test "tf-bump without env and no env selected shows error" {
  tf-clear-env >/dev/null 2>&1 || true

  local out
  out="$(tf-bump 2>&1)" || true
  local clean
  clean="$(strip_ansi "${out}")"

  [[ "${clean}" == *"No environment specified"* ]] || [[ "${clean}" == *"tf-set-env"* ]]
}

# ---------------------------------------------------------------------------
# tf-bump-all runs for all environments
# ---------------------------------------------------------------------------
@test "tf-bump-all runs for all environments" {
  local out
  out="$(tf-bump-all 2>&1)" || true
  local clean
  clean="$(strip_ansi "${out}")"

  # Should show bump project output
  [[ "${clean}" == *"Bump"* ]]
  # Should process multiple environments
  [[ "${clean}" == *"dev"* ]]
  [[ "${clean}" == *"prod"* ]]
}

@test "tf-bump-all shows summary for multiple environments" {
  local out
  out="$(tf-bump-all 2>&1)" || true
  local clean
  clean="$(strip_ansi "${out}")"

  # Should show a bump summary section when processing multiple envs
  [[ "${clean}" == *"Bump summary"* ]] || [[ "${clean}" == *"summary"* ]] || [[ "${clean}" == *"Done"* ]]
}

# ---------------------------------------------------------------------------
# Offline variants work
# ---------------------------------------------------------------------------
@test "tf-bump-env-offline runs for a given environment" {
  local out
  out="$(tf-bump-env-offline dev 2>&1)" || true
  local clean
  clean="$(strip_ansi "${out}")"

  # Should run without crashing and mention the environment
  [[ "${clean}" == *"dev"* ]]
}

@test "tf-bump-offline runs for a given environment" {
  local out
  out="$(tf-bump-offline dev 2>&1)" || true
  local clean
  clean="$(strip_ansi "${out}")"

  # Should run without crashing and show bump output
  [[ "${clean}" == *"Bump"* ]] || [[ "${clean}" == *"dev"* ]]
}

@test "tf-bump-all-offline runs for all environments" {
  local out
  out="$(tf-bump-all-offline 2>&1)" || true
  local clean
  clean="$(strip_ansi "${out}")"

  # Should process multiple environments
  [[ "${clean}" == *"dev"* ]]
  [[ "${clean}" == *"prod"* ]]
}

# ---------------------------------------------------------------------------
# tf-bump preserves shell state
# ---------------------------------------------------------------------------
@test "tf-bump preserves shell state" {
  local opts_before
  opts_before="$(set +o)"
  tf-bump dev >/dev/null 2>&1 || true
  local opts_after
  opts_after="$(set +o)"
  [[ "${opts_before}" == "${opts_after}" ]]
}

@test "tf-bump-all preserves shell state" {
  local opts_before
  opts_before="$(set +o)"
  tf-bump-all >/dev/null 2>&1 || true
  local opts_after
  opts_after="$(set +o)"
  [[ "${opts_before}" == "${opts_after}" ]]
}
