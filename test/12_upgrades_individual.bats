#!/usr/bin/env bats
# shellcheck disable=SC2164,SC1090,SC1091,SC2030,SC2031,SC2034,SC2154,SC2317
load 'helpers/test_helper'

setup() {
  default_test_setup
  project_dir="${BATS_TEST_TMPDIR}/project"
  cp -r "${BATS_TEST_DIRNAME}/fixtures/project_standard" "${project_dir}"
  cd "${project_dir}"
  mock_standard_tools
  source "${SUT}"
}

teardown() {
  default_test_teardown
}

# -------------------------------------------------------
# tf-bump-cicd
# -------------------------------------------------------

@test "tf-bump-cicd runs with all mocks" {
  mock_gh
  mock_yq
  run tf-bump-cicd
  assert_success
  assert_output --partial "Bump versions in GitHub workflow"
}

@test "tf-bump-cicd handles no workflow files" {
  mock_gh
  mock_yq
  # Remove the .github/workflows directory
  rm -rf "${project_dir}/.github"

  run tf-bump-cicd
  assert_success
  assert_output --partial "no github workflow files found"
}

@test "tf-bump-cicd requires gh auth" {
  mock_gh_not_authenticated
  mock_yq
  run tf-bump-cicd
  assert_failure
  assert_output --partial "not authenticated"
}

# -------------------------------------------------------
# tf-bump-modules
# -------------------------------------------------------

@test "tf-bump-modules runs with all mocks" {
  mock_curl
  mock_hcledit
  run tf-bump-modules
  assert_success
  assert_output --partial "Bump versions of registry modules"
}

@test "tf-bump-modules handles no modules" {
  mock_curl
  mock_hcledit
  # Remove module declarations from tf files
  # Replace the dev main.tf so it has no registry module
  cat > "${project_dir}/envs/dev/main.tf" <<'EOF'
module "main" {
  source = "../../main"
}
EOF
  cat > "${project_dir}/envs/prod/main.tf" <<'EOF'
module "main" {
  source = "../../main"
}
EOF

  run tf-bump-modules
  assert_success
  assert_output --partial "No registry modules found"
}

# -------------------------------------------------------
# tf-bump-tflint-plugins
# -------------------------------------------------------

@test "tf-bump-tflint-plugins runs with all mocks" {
  mock_gh
  mock_hcledit
  mock_curl
  run tf-bump-tflint-plugins
  assert_success
  assert_output --partial "Bump versions of plugins"
}

@test "tf-bump-tflint-plugins requires gh auth" {
  mock_gh_not_authenticated
  mock_hcledit
  mock_curl
  run tf-bump-tflint-plugins
  assert_failure
}

# hcledit fake that reports one plugin block in every file and records the
# files it is asked to update
_mock_hcledit_recording_plugin_sets() {
  export MOCK_HCLEDIT_SETS_FILE="${BATS_TEST_TMPDIR}/hcledit_sets.log"
  : >"${MOCK_HCLEDIT_SETS_FILE}"
  hcledit() {
    local file=""
    local -a args=("$@")
    local i
    for ((i = 0; i < ${#args[@]}; i++)); do
      [[ "${args[i]}" == "--file" ]] && file="${args[i + 1]}"
    done
    case "${1:-} ${2:-}" in
      "block list") echo "plugin.azurerm" ;;
      "attribute get")
        if [[ "${3:-}" == *.source ]]; then echo '"github.com/terraform-linters/tflint-ruleset-azurerm"'; else echo '"0.1.0"'; fi
        ;;
      "attribute set") echo "${file}" >>"${MOCK_HCLEDIT_SETS_FILE}" ;;
    esac
    return 0
  }
  export -f hcledit
}

@test "_dsb_tf_bump_tflint_plugin_versions bumps every config file by default" {
  printf 'plugin "azurerm" {}\n' >"${project_dir}/envs/dev/.tflint.hcl"
  _mock_hcledit_recording_plugin_sets
  run _dsb_tf_bump_tflint_plugin_versions
  assert_success
  run sort "${MOCK_HCLEDIT_SETS_FILE}"
  assert_line "${project_dir}/.tflint.hcl"
  assert_line "${project_dir}/envs/dev/.tflint.hcl"
}

@test "_dsb_tf_bump_tflint_plugin_versions bumps only the files in the given list" {
  printf 'plugin "azurerm" {}\n' >"${project_dir}/envs/dev/.tflint.hcl"
  _mock_hcledit_recording_plugin_sets
  declare -ga _testOnlyTheseFiles=("${project_dir}/envs/dev/.tflint.hcl")
  run _dsb_tf_bump_tflint_plugin_versions _testOnlyTheseFiles
  assert_success
  run cat "${MOCK_HCLEDIT_SETS_FILE}"
  assert_output "${project_dir}/envs/dev/.tflint.hcl"
}
