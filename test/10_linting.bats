#!/usr/bin/env bats
# shellcheck disable=SC2164,SC1090,SC1091,SC2030,SC2031,SC2034,SC2154,SC2317
#
# The lint contract, https://github.com/dsb-norge/github-actions-terraform/blob/main/docs/Linting.md:
# which directories tflint lints, how each is prepared, which config and which
# var files it gets, and how the results add up.
load 'helpers/test_helper'

setup() {
  default_test_setup
  project_dir="${BATS_TEST_TMPDIR}/project"
  cp -r "${BATS_TEST_DIRNAME}/fixtures/project_standard" "${project_dir}"
  cd "${project_dir}"
  mock_standard_tools
  source "${SUT}"
  install_fake_tflint
}

teardown() {
  default_test_teardown
}

# initialize a root the way terraform init leaves it: a .terraform directory,
# and the module manifest from test/fixtures/lint when one is named
#   $1: root directory, $2: manifest fixture (optional)
init_root() {
  mkdir -p "${1}/.terraform/modules"
  if [[ -n "${2:-}" ]]; then
    cp "${BATS_TEST_DIRNAME}/fixtures/lint/${2}" "${1}/.terraform/modules/modules.json"
  fi
}

# the --chdir of each recorded lint run, in order
lint_chdirs() {
  tflint_lint_calls | sed -E 's/.*--chdir=([^ ]*).*/\1/'
}

# the recorded lint runs in the given directory
lint_calls_in() {
  tflint_lint_calls | command grep -E -- "--chdir=${1}( |$)" || true
}

# -------------------------------------------------------
# directories
# -------------------------------------------------------

@test "tf-lint lints the environment, then every local module directory in its manifest" {
  init_root envs/dev project_env.json
  run tf-lint dev
  assert_success
  run lint_chdirs
  assert_output "$(printf '%s\n' "${project_dir}/envs/dev" "${project_dir}/main" "${project_dir}/modules/networking")"
}

@test "tf-lint lints only the environment when it has no module manifest" {
  init_root envs/dev
  run tf-lint dev
  assert_success
  run lint_chdirs
  assert_output "${project_dir}/envs/dev"
}

@test "tf-lint does not lint remote modules, nor local directories inside them" {
  init_root envs/dev project_env.json
  run tf-lint dev
  assert_success
  run cat "${MOCK_TFLINT_CALLS_FILE}"
  assert_output --partial "--chdir=${project_dir}/main"
  refute_output --partial "--chdir=${project_dir}/envs/dev/.terraform"
}

@test "tf-lint runs tflint from the repository root, so paths in its output are relative to it" {
  init_root envs/dev project_env.json
  run tf-lint dev
  assert_success
  run tflint_lint_calls
  assert_equal "${#lines[@]}" 3
  local line
  for line in "${lines[@]}"; do
    [[ "${line}" == *"|pwd=${project_dir}|"* ]]
  done
}

# -------------------------------------------------------
# preparation of module directories
# -------------------------------------------------------

@test "tf-lint lints the environment against its own manifest, without TF_DATA_DIR" {
  init_root envs/dev project_env.json
  run tf-lint dev
  assert_success
  run lint_calls_in "${project_dir}/envs/dev"
  assert_output --partial "|tf_data_dir=|"
}

@test "tf-lint lints a module directory with a TF_DATA_DIR holding the manifest derived from the environment's" {
  init_root envs/dev project_env.json
  run tf-lint dev
  assert_success
  run lint_calls_in "${project_dir}/main"
  refute_output --partial "|tf_data_dir=|"
  local root="${project_dir}/envs/dev"
  run jq -c '.Modules | map({Key, Dir})' "$(fake_tflint_manifest_for "${project_dir}/main")"
  assert_output "$(jq -nc --arg r "${root}" '[
    {Key: "", Dir: ($r + "/../../main")},
    {Key: "naming", Dir: ($r + "/.terraform/modules/main.naming")},
    {Key: "networking", Dir: ($r + "/../../modules/networking")},
    {Key: "networking.subnets", Dir: ($r + "/.terraform/modules/main.networking.subnets")}
  ]')"
}

@test "tf-lint keeps the source and version of each entry in a derived manifest" {
  init_root envs/dev project_env.json
  run tf-lint dev
  assert_success
  run jq -c '.Modules[] | select(.Key == "naming") | {Source, Version}' "$(fake_tflint_manifest_for "${project_dir}/main")"
  assert_output '{"Source":"registry.terraform.io/Azure/naming/azurerm","Version":"0.4.1"}'
}

@test "tf-lint uses the shortest key for a directory reached through several keys" {
  init_root envs/dev project_env.json
  local manifest="envs/dev/.terraform/modules/modules.json"
  jq '.Modules += [{"Key": "networking", "Source": "../../modules/networking", "Dir": "../../modules/networking"}]' "${manifest}" >"${BATS_TEST_TMPDIR}/m.json"
  cp "${BATS_TEST_TMPDIR}/m.json" "${manifest}"
  run tf-lint dev
  assert_success
  run lint_calls_in "${project_dir}/modules/networking"
  assert_equal "${#lines[@]}" 1
  run jq -c '.Modules | map({Key, Dir})' "$(fake_tflint_manifest_for "${project_dir}/modules/networking")"
  assert_output "$(jq -nc --arg r "${project_dir}/envs/dev" '[{Key: "", Dir: ($r + "/../../modules/networking")}]')"
}

@test "tf-lint writes nothing into the repository and removes its temporary TF_DATA_DIRs" {
  init_root envs/dev project_env.json
  local before
  before="$(find . | sort)"
  run tf-lint dev
  assert_success
  [[ "$(find . | sort)" == "${before}" ]]
  local dataDir
  dataDir="$(lint_calls_in "${project_dir}/main" | sed -E 's/.*\|tf_data_dir=([^|]*)\|.*/\1/')"
  [[ -n "${dataDir}" ]]
  [[ ! -e "${dataDir}" ]]
}

# -------------------------------------------------------
# var files
# -------------------------------------------------------

@test "tf-lint lints the environment once per explicit var file, given as an absolute path" {
  init_root envs/dev project_env.json
  touch envs/dev/env.a.tfvars envs/dev/env.b.tfvars
  run tf-lint dev
  assert_success
  run lint_calls_in "${project_dir}/envs/dev"
  assert_equal "${#lines[@]}" 2
  assert_line --partial "--chdir=${project_dir}/envs/dev --var-file=${project_dir}/envs/dev/env.a.tfvars"
  assert_line --partial "--chdir=${project_dir}/envs/dev --var-file=${project_dir}/envs/dev/env.b.tfvars"
}

@test "tf-lint leaves terraform.tfvars and *.auto.tfvars to tflint" {
  init_root envs/dev project_env.json
  touch envs/dev/terraform.tfvars envs/dev/common.auto.tfvars
  run tf-lint dev
  assert_success
  run lint_calls_in "${project_dir}/envs/dev"
  assert_equal "${#lines[@]}" 1
  refute_output --partial "--var-file"
}

@test "tf-lint never gives a module directory the environment's var files" {
  init_root envs/dev project_env.json
  touch envs/dev/env.a.tfvars envs/dev/env.b.tfvars
  run tf-lint dev
  assert_success
  run lint_calls_in "${project_dir}/main"
  assert_equal "${#lines[@]}" 1
  refute_output --partial "--var-file"
  run lint_calls_in "${project_dir}/modules/networking"
  assert_equal "${#lines[@]}" 1
  refute_output --partial "--var-file"
}

# -------------------------------------------------------
# config
# -------------------------------------------------------

@test "tf-lint uses the environment's .tflint.hcl for every directory" {
  init_root envs/dev project_env.json
  printf 'config {}\n' >envs/dev/.tflint.hcl
  run tf-lint dev
  assert_success
  run tflint_lint_calls
  assert_equal "${#lines[@]}" 3
  local line
  for line in "${lines[@]}"; do
    [[ "${line}" == *"--config=${project_dir}/envs/dev/.tflint.hcl "* ]]
  done
}

@test "tf-lint falls back to the repository root's .tflint.hcl" {
  init_root envs/dev project_env.json
  run tf-lint dev
  assert_success
  run tflint_lint_calls
  assert_equal "${#lines[@]}" 3
  local line
  for line in "${lines[@]}"; do
    [[ "${line}" == *"--config=${project_dir}/.tflint.hcl "* ]]
  done
}

@test "tf-lint writes the default config into the environment when there is none, never into the repository root" {
  init_root envs/dev project_env.json
  rm .tflint.hcl
  mock_hcledit_not_installed
  _dsbTfLogWarnings=1
  run tf-lint dev
  assert_success
  [[ -f envs/dev/.tflint.hcl ]]
  [[ ! -e .tflint.hcl ]]
  run diff <(_dsb_tf_tflint_default_config) envs/dev/.tflint.hcl
  assert_success
  run tflint_lint_calls
  local line
  for line in "${lines[@]}"; do
    [[ "${line}" == *"--config=${project_dir}/envs/dev/.tflint.hcl "* ]]
  done
}

@test "tf-lint tells the user to commit the default config it wrote" {
  init_root envs/dev
  rm .tflint.hcl
  mock_hcledit_not_installed
  run tf-lint dev
  assert_success
  assert_clean_output_contains "envs/dev/.tflint.hcl"
  assert_clean_output_contains "commit"
}

@test "tf-lint bumps the plugins of the default config it wrote, and only that file" {
  init_root envs/dev
  rm .tflint.hcl
  printf 'plugin "azurerm" {}\n' >envs/prod/.tflint.hcl
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
  run tf-lint dev
  assert_success
  run cat "${MOCK_HCLEDIT_SETS_FILE}"
  assert_output "${project_dir}/envs/dev/.tflint.hcl"
}

@test "tf-lint without hcledit writes the default as it is and names tf-bump-tflint-plugins" {
  init_root envs/dev
  rm .tflint.hcl
  mock_hcledit_not_installed
  run tf-lint dev
  assert_success
  assert_clean_output_contains "tf-bump-tflint-plugins"
}

@test "the default config is the one the wrapper shipped, plugins with signing keys included" {
  run _dsb_tf_tflint_default_config
  assert_success
  assert_line 'config {'
  assert_line '  call_module_type = "all"'
  assert_line 'plugin "azurerm" {'
  assert_line 'plugin "basic-ext" {'
  assert_line 'plugin "azurerm-ext" {'
  assert_line '    -----BEGIN PGP PUBLIC KEY BLOCK-----'
  assert_line 'rule "terraform_locals_order" { enabled = false }            # We use logical ordering of locals, not alphabetic order'
}

# -------------------------------------------------------
# plugins
# -------------------------------------------------------

@test "tf-lint initializes the plugins once, with the config and a GitHub token" {
  init_root envs/dev project_env.json
  run tf-lint dev
  assert_success
  run command grep -E -- "args=--init " "${MOCK_TFLINT_CALLS_FILE}"
  assert_equal "${#lines[@]}" 1
  assert_output --partial "|github_token=gho_mocktoken123|"
  assert_output --partial "--config=${project_dir}/.tflint.hcl"
}

@test "tf-lint fails when the plugins cannot be initialized" {
  init_root envs/dev project_env.json
  export MOCK_TFLINT_INIT_EXIT=1
  run tf-lint dev
  assert_failure
  run tflint_lint_calls
  assert_output ""
}

# -------------------------------------------------------
# result
# -------------------------------------------------------

@test "tf-lint fails when any run fails, and summarizes each run" {
  init_root envs/dev project_env.json
  touch envs/dev/env.a.tfvars
  export MOCK_TFLINT_FAIL_DIR="${project_dir}/modules/networking"
  run tf-lint dev
  assert_failure
  assert_clean_output_contains "success -> envs/dev (var file: envs/dev/env.a.tfvars)"
  assert_clean_output_contains "success -> main"
  assert_clean_output_contains "failure -> modules/networking"
}

@test "tf-lint fails when tflint reports issues in the environment" {
  init_root envs/dev
  export MOCK_TFLINT_FAIL_DIR="${project_dir}/envs/dev"
  run tf-lint dev
  assert_failure
}

# -------------------------------------------------------
# preconditions and arguments
# -------------------------------------------------------

@test "tf-lint names the init command when the environment is not initialized" {
  run tf-lint dev
  assert_failure
  assert_clean_output_contains "tf-init-env-offline dev"
  run tflint_lint_calls
  assert_output ""
}

@test "tf-lint fails when no environment is given or selected" {
  run tf-lint
  assert_failure
  assert_clean_output_contains "No environment selected"
}

@test "tf-lint uses the selected environment" {
  init_root envs/prod
  _dsbTfSelectedEnv="prod"
  run tf-lint
  assert_success
  run lint_chdirs
  assert_output "${project_dir}/envs/prod"
}

@test "tf-lint --use-version lints with that tflint version" {
  init_root envs/dev
  install_fake_tflint "v0.50.0"
  run tf-lint dev --use-version v0.50.0
  assert_success
  run tflint_lint_calls
  assert_output --partial "bin=${XDG_CACHE_HOME}/dsb-tf-proj-helpers/tflint/v0.50.0/tflint|"
}

@test "tf-lint --use-version=<version> works too, and before the environment" {
  init_root envs/dev
  install_fake_tflint "v0.50.0"
  run tf-lint --use-version=v0.50.0 dev
  assert_success
  run tflint_lint_calls
  assert_output --partial "bin=${XDG_CACHE_HOME}/dsb-tf-proj-helpers/tflint/v0.50.0/tflint|"
}

@test "tf-lint --use-version without a version fails" {
  init_root envs/dev
  run tf-lint dev --use-version
  assert_failure
  assert_clean_output_contains "--use-version"
}

@test "tf-lint warns about and ignores flags it does not know, such as the old wrapper's" {
  init_root envs/dev
  _dsbTfLogWarnings=1
  run tf-lint dev --skip-check
  assert_success
  assert_clean_output_contains "--skip-check"
}

@test "tf-lint succeeds when Azure auth is broken" {
  init_root envs/dev
  mock_az_not_logged_in
  run tf-lint dev
  assert_success
}

@test "tf-lint preserves working directory even on failure" {
  init_root envs/dev
  export MOCK_TFLINT_FAIL_DIR="${project_dir}/envs/dev"
  cd envs
  local original_pwd="${PWD}"
  tf-lint dev || true
  [[ "${PWD}" == "${original_pwd}" ]]
}

@test "tf-lint uses no wrapper script and creates no .tflint directory" {
  init_root envs/dev project_env.json
  run tf-lint dev
  assert_success
  run find "${project_dir}" -name ".tflint" -type d
  assert_output ""
  assert_function_not_exists "_dsb_tf_install_tflint_wrapper"
}

# -------------------------------------------------------
# tf-lint-all (project)
# -------------------------------------------------------

@test "tf-lint-all lints every environment" {
  init_root envs/dev project_env.json
  init_root envs/prod
  run tf-lint-all
  assert_success
  run lint_calls_in "${project_dir}/envs/dev"
  assert_equal "${#lines[@]}" 1
  run lint_calls_in "${project_dir}/envs/prod"
  assert_equal "${#lines[@]}" 1
}

@test "tf-lint-all fails when one environment fails" {
  init_root envs/dev
  init_root envs/prod
  export MOCK_TFLINT_FAIL_DIR="${project_dir}/envs/prod"
  run tf-lint-all
  assert_failure
  run lint_calls_in "${project_dir}/envs/dev"
  assert_equal "${#lines[@]}" 1
}

@test "tf-lint-all --use-version lints with that tflint version" {
  init_root envs/dev
  init_root envs/prod
  install_fake_tflint "v0.50.0"
  run tf-lint-all --use-version v0.50.0
  assert_success
  run tflint_lint_calls
  assert_equal "${#lines[@]}" 2
  refute_output --partial "/v0.55.0/"
}

# -------------------------------------------------------
# module repositories
# -------------------------------------------------------

# a module repository with a submodule, modules/naming
setup_module_repo() {
  module_dir="$(create_module_project)"
  cd "${module_dir}"
  source "${SUT}"
  mkdir -p modules/naming
  printf 'variable "name" {\n  type = string\n}\n' >modules/naming/main.tf
}

@test "tf-lint in a module repo lints the module root and its submodules" {
  setup_module_repo
  init_root . module_root.json
  run tf-lint
  assert_success
  run lint_chdirs
  assert_output "$(printf '%s\n' "${module_dir}" "${module_dir}/modules/naming")"
  run tflint_lint_calls
  local line
  for line in "${lines[@]}"; do
    [[ "${line}" == *"--config=${module_dir}/.tflint.hcl "* ]]
  done
}

@test "tf-lint in a module repo names tf-init when the root is not initialized" {
  setup_module_repo
  run tf-lint
  assert_failure
  assert_clean_output_contains "tf-init"
}

@test "tf-lint in a module repo writes the default config at the module root when it has none" {
  setup_module_repo
  init_root .
  rm .tflint.hcl
  mock_hcledit_not_installed
  run tf-lint
  assert_success
  [[ -f "${module_dir}/.tflint.hcl" ]]
}

@test "tf-lint-example lints the example with the module root's config, never its own" {
  setup_module_repo
  init_root examples/01-basic module_example.json
  mkdir -p examples/01-basic/modules/helper
  printf 'config {}\n' >examples/01-basic/.tflint.hcl
  run tf-lint-example 01-basic
  assert_success
  run tflint_lint_calls
  [[ "${#lines[@]}" -gt 0 ]]
  local line
  for line in "${lines[@]}"; do
    [[ "${line}" == *"--config=${module_dir}/.tflint.hcl "* ]]
  done
}

@test "tf-lint-example lints the example and the local directories inside it only" {
  setup_module_repo
  init_root examples/01-basic module_example.json
  mkdir -p examples/01-basic/modules/helper
  run tf-lint-example 01-basic
  assert_success
  run lint_chdirs
  assert_output "$(printf '%s\n' "${module_dir}/examples/01-basic" "${module_dir}/examples/01-basic/modules/helper")"
}

@test "tf-lint-example writes nothing into the example directory" {
  setup_module_repo
  init_root examples/01-basic module_example.json
  mkdir -p examples/01-basic/modules/helper
  rm .tflint.hcl
  mock_hcledit_not_installed
  local before
  before="$(find examples | sort)"
  run tf-lint-example 01-basic
  assert_success
  [[ "$(find examples | sort)" == "${before}" ]]
  [[ -f "${module_dir}/.tflint.hcl" ]]
}

@test "tf-lint-example names tf-init-example when the example is not initialized" {
  setup_module_repo
  run tf-lint-example 01-basic
  assert_failure
  assert_clean_output_contains "tf-init-example 01-basic"
}

@test "tf-lint-all-examples lints every example" {
  setup_module_repo
  init_root examples/01-basic
  init_root examples/02-advanced
  run tf-lint-all-examples
  assert_success
  run lint_chdirs
  assert_output "$(printf '%s\n' "${module_dir}/examples/01-basic" "${module_dir}/examples/02-advanced")"
}

@test "tf-lint-all in a module repo lints the root and its submodules once, then each example" {
  setup_module_repo
  init_root . module_root.json
  init_root examples/01-basic module_example.json
  init_root examples/02-advanced
  mkdir -p examples/01-basic/modules/helper
  run tf-lint-all
  assert_success
  run lint_chdirs
  assert_output "$(printf '%s\n' \
    "${module_dir}" \
    "${module_dir}/modules/naming" \
    "${module_dir}/examples/01-basic" \
    "${module_dir}/examples/01-basic/modules/helper" \
    "${module_dir}/examples/02-advanced")"
}

@test "tf-lint-all in a module repo fails when an example fails" {
  setup_module_repo
  init_root .
  init_root examples/01-basic
  init_root examples/02-advanced
  export MOCK_TFLINT_FAIL_DIR="${module_dir}/examples/02-advanced"
  run tf-lint-all
  assert_failure
}

# -------------------------------------------------------
# help
# -------------------------------------------------------

@test "tf-help tf-lint links the lint contract and names no wrapper script" {
  run tf-help tf-lint
  assert_success
  assert_clean_output_contains "https://github.com/dsb-norge/github-actions-terraform/blob/main/docs/Linting.md"
  assert_clean_output_contains "--use-version"
  refute_output --partial "wrapper"
  refute_output --partial "terraform-tflint-wrappers"
}

@test "tf-help tf-lint-example says examples lint with the module root's config" {
  run tf-help tf-lint-example
  assert_success
  assert_clean_output_contains "module root's .tflint.hcl"
}
