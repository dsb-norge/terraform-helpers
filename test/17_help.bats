#!/usr/bin/env bats
load 'helpers/test_helper'

setup() {
  export BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-${BATS_FILE_TMPDIR}}"
  source_script_in_project
  default_test_setup
  # Re-enable logging so we can capture help output
  export _dsbTfLogInfo=1
  export _dsbTfLogWarnings=1
  export _dsbTfLogErrors=1
}

teardown() {
  default_test_teardown
}

# ---------------------------------------------------------------------------
# tf-help (no args / default)
# ---------------------------------------------------------------------------
@test "tf-help shows overview with DSB Terraform Project Helpers" {
  output="$(tf-help 2>&1)"
  status=$?
  assert_success
  assert_clean_output_contains "DSB Terraform Project Helpers"
}

@test "tf-help shows common commands" {
  output="$(tf-help 2>&1)"
  status=$?
  assert_success
  assert_clean_output_contains "Common Commands"
  assert_clean_output_contains "tf-status"
}

# ---------------------------------------------------------------------------
# tf-help groups
# ---------------------------------------------------------------------------
@test "tf-help groups lists all groups" {
  output="$(tf-help groups 2>&1)"
  status=$?
  assert_success
  assert_clean_output_contains "Help Groups"
  assert_clean_output_contains "environments"
  assert_clean_output_contains "terraform"
  assert_clean_output_contains "upgrading"
  assert_clean_output_contains "checks"
  assert_clean_output_contains "general"
  assert_clean_output_contains "azure"
  assert_clean_output_contains "offline"
}

# ---------------------------------------------------------------------------
# tf-help commands
# ---------------------------------------------------------------------------
@test "tf-help commands lists all commands" {
  output="$(tf-help commands 2>&1)"
  status=$?
  assert_success
  assert_clean_output_contains "All available commands"
  assert_clean_output_contains "tf-init"
  assert_clean_output_contains "tf-plan"
  assert_clean_output_contains "tf-apply"
  assert_clean_output_contains "az-login"
}

# ---------------------------------------------------------------------------
# tf-help for a specific command
# ---------------------------------------------------------------------------
@test "tf-help tf-init shows specific command help" {
  output="$(tf-help tf-init 2>&1)"
  status=$?
  assert_success
  assert_clean_output_contains "tf-init"
}

@test "tf-help tf-status shows specific command help" {
  output="$(tf-help tf-status 2>&1)"
  status=$?
  assert_success
  assert_clean_output_contains "tf-status"
}

@test "tf-help az-login shows specific command help" {
  output="$(tf-help az-login 2>&1)"
  status=$?
  assert_success
  assert_clean_output_contains "az-login"
}

# ---------------------------------------------------------------------------
# tf-help unknown topic
# ---------------------------------------------------------------------------
@test "tf-help unknown warns about unknown topic" {
  output="$(tf-help not-a-real-topic 2>&1)"
  status=$?
  assert_success
  assert_clean_output_contains "Unknown help topic"
}

# ---------------------------------------------------------------------------
# tf-help all
# ---------------------------------------------------------------------------
@test "tf-help all shows everything" {
  output="$(tf-help all 2>&1)"
  status=$?
  assert_success
  assert_clean_output_contains "DSB Terraform Project Helpers"
  assert_clean_output_contains "Detailed Help For All Commands"
  # Spot-check a few commands in the detailed output
  assert_clean_output_contains "tf-init"
  assert_clean_output_contains "tf-plan"
  assert_clean_output_contains "az-login"
}

# ---------------------------------------------------------------------------
# tf-help for each group
# ---------------------------------------------------------------------------
@test "tf-help environments shows environment commands" {
  output="$(tf-help environments 2>&1)"
  status=$?
  assert_success
  assert_clean_output_contains "Environment Commands"
  assert_clean_output_contains "tf-list-envs"
  assert_clean_output_contains "tf-set-env"
}

@test "tf-help terraform shows terraform commands" {
  output="$(tf-help terraform 2>&1)"
  status=$?
  assert_success
  assert_clean_output_contains "Terraform Commands"
  assert_clean_output_contains "tf-init"
  assert_clean_output_contains "tf-validate"
}

@test "tf-help azure shows azure commands" {
  output="$(tf-help azure 2>&1)"
  status=$?
  assert_success
  assert_clean_output_contains "Azure Commands"
  assert_clean_output_contains "az-login"
  assert_clean_output_contains "az-logout"
}

@test "tf-help checks shows check commands" {
  output="$(tf-help checks 2>&1)"
  status=$?
  assert_success
  assert_clean_output_contains "Check Commands"
  assert_clean_output_contains "tf-check-dir"
  assert_clean_output_contains "tf-check-tools"
}

@test "tf-help general shows general commands" {
  output="$(tf-help general 2>&1)"
  status=$?
  assert_success
  assert_clean_output_contains "General Commands"
  assert_clean_output_contains "tf-status"
  assert_clean_output_contains "tf-lint"
}

@test "tf-help upgrading shows upgrade commands" {
  output="$(tf-help upgrading 2>&1)"
  status=$?
  assert_success
  assert_clean_output_contains "Upgrade Commands"
  assert_clean_output_contains "tf-bump"
  assert_clean_output_contains "tf-upgrade"
}

@test "tf-help offline shows offline commands" {
  output="$(tf-help offline 2>&1)"
  status=$?
  assert_success
  assert_clean_output_contains "Offline Commands"
  assert_clean_output_contains "tf-init-offline"
  assert_clean_output_contains "tf-upgrade-offline"
}

# ---------------------------------------------------------------------------
# Every command in help has a help entry (loop test)
# ---------------------------------------------------------------------------
@test "every command listed by _dsb_tf_help_get_commands_supported_by_help has a help entry" {
  local commands
  commands=$(_dsb_tf_help_get_commands_supported_by_help)
  local -a commandList
  # shellcheck disable=SC2162
  read -a commandList <<<"${commands}"

  local failed_commands=()
  for cmd in "${commandList[@]}"; do
    local out
    out="$(tf-help "${cmd}" 2>&1)" || true
    local clean
    clean="$(strip_ansi "${out}")"
    if [[ "${clean}" != *"${cmd}"* ]]; then
      failed_commands+=("${cmd}")
    fi
  done

  if [[ ${#failed_commands[@]} -gt 0 ]]; then
    echo "Commands without proper help entry: ${failed_commands[*]}" >&2
    return 1
  fi
}
