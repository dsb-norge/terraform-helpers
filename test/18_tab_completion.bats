#!/usr/bin/env bats
# shellcheck disable=SC2164,SC1090,SC1091,SC2030,SC2031,SC2034,SC2154,SC2317
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
# Completions are registered
# ---------------------------------------------------------------------------
@test "completion registered for tf-set-env" {
  local comp_output
  comp_output="$(complete -p tf-set-env 2>&1)"
  [[ "${comp_output}" == *"_dsb_tf_completions_for_available_envs"* ]]
}

@test "completion registered for tf-help" {
  local comp_output
  comp_output="$(complete -p tf-help 2>&1)"
  [[ "${comp_output}" == *"_dsb_tf_completions_for_tf_help"* ]]
}

@test "completion registered for tf-lint" {
  local comp_output
  comp_output="$(complete -p tf-lint 2>&1)"
  [[ "${comp_output}" == *"_dsb_tf_completions_for_tf_lint"* ]]
}

@test "completion registered for tf-plan" {
  local comp_output
  comp_output="$(complete -p tf-plan 2>&1)"
  [[ "${comp_output}" == *"_dsb_tf_completions_for_available_envs"* ]]
}

@test "completion registered for tf-apply" {
  local comp_output
  comp_output="$(complete -p tf-apply 2>&1)"
  [[ "${comp_output}" == *"_dsb_tf_completions_for_available_envs"* ]]
}

# ---------------------------------------------------------------------------
# Environment completion returns env names
# ---------------------------------------------------------------------------
@test "environment completion returns dev and prod" {
  # Simulate bash completion for "tf-set-env " (cursor at word index 1, empty partial)
  COMP_WORDS=("tf-set-env" "")
  COMP_CWORD=1
  COMPREPLY=()

  _dsb_tf_completions_for_available_envs

  # COMPREPLY should contain both environments
  local reply_str="${COMPREPLY[*]}"
  [[ "${reply_str}" == *"dev"* ]]
  [[ "${reply_str}" == *"prod"* ]]
}

@test "environment completion filters by prefix" {
  # Simulate bash completion for "tf-set-env d" (cursor at word index 1, partial "d")
  COMP_WORDS=("tf-set-env" "d")
  COMP_CWORD=1
  COMPREPLY=()

  _dsb_tf_completions_for_available_envs

  local reply_str="${COMPREPLY[*]}"
  [[ "${reply_str}" == *"dev"* ]]
  # "prod" should not match prefix "d"
  [[ "${reply_str}" != *"prod"* ]]
}

@test "environment completion does not complete second argument" {
  # Simulate bash completion for "tf-set-env dev " (cursor at word index 2)
  COMP_WORDS=("tf-set-env" "dev" "")
  COMP_CWORD=2
  COMPREPLY=()

  _dsb_tf_completions_for_available_envs

  # Should not offer completions for second arg
  [[ ${#COMPREPLY[@]} -eq 0 ]]
}

# ---------------------------------------------------------------------------
# tf-help completion returns topics
# ---------------------------------------------------------------------------
@test "tf-help completion returns groups and commands" {
  COMP_WORDS=("tf-help" "")
  COMP_CWORD=1
  COMPREPLY=()

  _dsb_tf_completions_for_tf_help

  local reply_str="${COMPREPLY[*]}"
  # Should include group names
  [[ "${reply_str}" == *"all"* ]]
  [[ "${reply_str}" == *"commands"* ]]
  [[ "${reply_str}" == *"groups"* ]]
  [[ "${reply_str}" == *"environments"* ]]
  # Should also include specific command names
  [[ "${reply_str}" == *"tf-init"* ]]
  [[ "${reply_str}" == *"az-login"* ]]
}

@test "tf-help completion filters by prefix" {
  COMP_WORDS=("tf-help" "az")
  COMP_CWORD=1
  COMPREPLY=()

  _dsb_tf_completions_for_tf_help

  local reply_str="${COMPREPLY[*]}"
  [[ "${reply_str}" == *"az-login"* ]]
  [[ "${reply_str}" == *"azure"* ]]
  # Should not include topics that don't start with "az"
  [[ "${reply_str}" != *"tf-init"* ]]
}

# ---------------------------------------------------------------------------
# tf-lint completion supports env + flags
# ---------------------------------------------------------------------------
@test "tf-lint completion first arg returns env names" {
  COMP_WORDS=("tf-lint" "")
  COMP_CWORD=1
  COMPREPLY=()

  _dsb_tf_completions_for_tf_lint

  local reply_str="${COMPREPLY[*]}"
  [[ "${reply_str}" == *"dev"* ]]
  [[ "${reply_str}" == *"prod"* ]]
}

@test "tf-lint completion second arg returns flags" {
  COMP_WORDS=("tf-lint" "dev" "")
  COMP_CWORD=2
  COMPREPLY=()

  _dsb_tf_completions_for_tf_lint

  local reply_str="${COMPREPLY[*]}"
  [[ "${reply_str}" == *"--force-install"* ]]
  [[ "${reply_str}" == *"--help"* ]]
  [[ "${reply_str}" == *"--use-version"* ]]
}

# -- Example name completion (module repo) --

@test "example name completion returns examples in module repo" {
  local module_dir
  module_dir="$(create_module_project)"
  cd "${module_dir}"
  mock_standard_tools
  source "${SUT}"

  # Simulate completion
  COMP_WORDS=("tf-init-example" "")
  COMP_CWORD=1
  _dsb_tf_completions_for_example_names
  [[ "${#COMPREPLY[@]}" -gt 0 ]]
  # Should contain example names from fixture
  local joined="${COMPREPLY[*]}"
  [[ "${joined}" == *"01-basic"* ]]
}

@test "example name completion filters by prefix" {
  local module_dir
  module_dir="$(create_module_project)"
  cd "${module_dir}"
  mock_standard_tools
  source "${SUT}"

  COMP_WORDS=("tf-init-example" "01")
  COMP_CWORD=1
  _dsb_tf_completions_for_example_names
  [[ "${#COMPREPLY[@]}" -eq 1 ]]
  [[ "${COMPREPLY[0]}" == "01-basic" ]]
}

@test "example name completion returns empty in project repo" {
  # project repo has no examples
  COMP_WORDS=("tf-init-example" "")
  COMP_CWORD=1
  _dsb_tf_completions_for_example_names
  [[ "${#COMPREPLY[@]}" -eq 0 ]]
}
