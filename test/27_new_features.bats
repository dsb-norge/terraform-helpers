#!/usr/bin/env bats
# shellcheck disable=SC2164,SC1090,SC1091,SC2030,SC2031,SC2034,SC2154,SC2317
load 'helpers/test_helper'

setup_module_fixture() {
  export _MODULE_DIR="${BATS_FILE_TMPDIR}/module_project_${BATS_TEST_NUMBER}"
  cp -r "${FIXTURES_DIR}/project_module" "${_MODULE_DIR}"
  cd "${_MODULE_DIR}"
  mock_standard_tools
  source "${SUT}"
  default_test_setup
}

setup_project_fixture() {
  source_script_in_project
  default_test_setup
}

# ===========================================================================
# Feature 1: Renames (tf-*-examples -> tf-*-all-examples)
# ===========================================================================

@test "tf-init-all-examples function exists" {
  setup_module_fixture
  assert_function_exists "tf-init-all-examples"
}

@test "tf-validate-all-examples function exists" {
  setup_module_fixture
  assert_function_exists "tf-validate-all-examples"
}

@test "tf-lint-all-examples function exists" {
  setup_module_fixture
  assert_function_exists "tf-lint-all-examples"
}

@test "tf-test-all-examples function exists" {
  setup_module_fixture
  assert_function_exists "tf-test-all-examples"
}

@test "tf-docs-all-examples function exists" {
  setup_module_fixture
  assert_function_exists "tf-docs-all-examples"
}

@test "old tf-init-examples function does NOT exist" {
  setup_module_fixture
  assert_function_not_exists "tf-init-examples"
}

@test "old tf-validate-examples function does NOT exist" {
  setup_module_fixture
  assert_function_not_exists "tf-validate-examples"
}

@test "old tf-lint-examples function does NOT exist" {
  setup_module_fixture
  assert_function_not_exists "tf-lint-examples"
}

@test "old tf-test-examples function does NOT exist" {
  setup_module_fixture
  assert_function_not_exists "tf-test-examples"
}

@test "old tf-docs-examples function does NOT exist" {
  setup_module_fixture
  assert_function_not_exists "tf-docs-examples"
}

@test "singular tf-init-example still exists" {
  setup_module_fixture
  assert_function_exists "tf-init-example"
}

@test "singular tf-validate-example still exists" {
  setup_module_fixture
  assert_function_exists "tf-validate-example"
}

@test "singular tf-lint-example still exists" {
  setup_module_fixture
  assert_function_exists "tf-lint-example"
}

@test "singular tf-test-example still exists" {
  setup_module_fixture
  assert_function_exists "tf-test-example"
}

@test "singular tf-docs-example still exists" {
  setup_module_fixture
  assert_function_exists "tf-docs-example"
}

# ===========================================================================
# Feature 2: tf-validate-all
# ===========================================================================

@test "tf-validate-all function exists" {
  setup_module_fixture
  assert_function_exists "tf-validate-all"
}

@test "tf-validate-all succeeds in module repo (with .terraform dirs)" {
  setup_module_fixture
  mkdir -p "${_MODULE_DIR}/.terraform"
  mkdir -p "${_MODULE_DIR}/examples/01-basic/.terraform"
  mkdir -p "${_MODULE_DIR}/examples/02-advanced/.terraform"
  run tf-validate-all
  assert_success
}

@test "tf-validate-all in module repo validates root and examples" {
  setup_module_fixture
  mkdir -p "${_MODULE_DIR}/.terraform"
  mkdir -p "${_MODULE_DIR}/examples/01-basic/.terraform"
  mkdir -p "${_MODULE_DIR}/examples/02-advanced/.terraform"
  _dsbTfLogInfo=1
  run tf-validate-all
  assert_success
  assert_clean_output_contains "Validating module root"
  assert_clean_output_contains "Validating examples"
}

@test "tf-validate-all succeeds in project repo" {
  setup_project_fixture
  run tf-validate-all
  assert_success
}

@test "tf-validate-all in project repo validates all environments" {
  setup_project_fixture
  _dsbTfLogInfo=1
  run tf-validate-all
  assert_success
  assert_clean_output_contains "Validating all environments"
  assert_clean_output_contains "succeeded"
}

@test "tf-validate-all help entry exists" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-help tf-validate-all
  assert_success
  assert_clean_output_contains "tf-validate-all"
  assert_clean_output_contains "module repos"
}

# ===========================================================================
# Feature 3: tf-lint-all
# ===========================================================================

@test "tf-lint-all function exists" {
  setup_module_fixture
  assert_function_exists "tf-lint-all"
}

@test "tf-lint-all succeeds in module repo with pre-installed wrapper" {
  setup_module_fixture
  mkdir -p "${_MODULE_DIR}/.tflint"
  echo '#!/usr/bin/env bash' > "${_MODULE_DIR}/.tflint/tflint.sh"
  echo 'echo "mock tflint"' >> "${_MODULE_DIR}/.tflint/tflint.sh"
  run tf-lint-all
  assert_success
}

@test "tf-lint-all in module repo lints root and examples" {
  setup_module_fixture
  mkdir -p "${_MODULE_DIR}/.tflint"
  echo '#!/usr/bin/env bash' > "${_MODULE_DIR}/.tflint/tflint.sh"
  echo 'echo "mock tflint"' >> "${_MODULE_DIR}/.tflint/tflint.sh"
  _dsbTfLogInfo=1
  run tf-lint-all
  assert_success
  assert_clean_output_contains "Linting module root"
}

@test "tf-lint-all help entry exists" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-help tf-lint-all
  assert_success
  assert_clean_output_contains "tf-lint-all"
  assert_clean_output_contains "module repos"
}

# ===========================================================================
# Feature 4: tf-outputs
# ===========================================================================

@test "tf-outputs function exists" {
  setup_module_fixture
  assert_function_exists "tf-outputs"
}

@test "tf-outputs succeeds in module repo" {
  setup_module_fixture
  run tf-outputs
  assert_success
}

@test "tf-outputs in module repo shows output" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-outputs
  assert_success
  assert_clean_output_contains "Showing outputs for module root"
}

@test "tf-outputs succeeds in project repo with env argument" {
  setup_project_fixture
  run tf-outputs "dev"
  assert_success
}

@test "tf-outputs in project repo shows environment info" {
  setup_project_fixture
  _dsbTfLogInfo=1
  run tf-outputs "dev"
  assert_success
  assert_clean_output_contains "Showing outputs for environment"
}

@test "tf-outputs help entry exists" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-help tf-outputs
  assert_success
  assert_clean_output_contains "tf-outputs"
  assert_clean_output_contains "module repos"
}

@test "tf-outputs has tab completion for envs in project repo" {
  setup_project_fixture
  local comp_output
  comp_output="$(complete -p tf-outputs 2>&1)"
  [[ "${comp_output}" == *"_dsb_tf_completions_for_available_envs"* ]]
}

# ===========================================================================
# Feature 5: tf-init-all for module repos
# ===========================================================================

@test "tf-init-all succeeds in module repo" {
  setup_module_fixture
  run tf-init-all
  assert_success
}

@test "tf-init-all in module repo inits root and examples" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-init-all
  assert_success
  assert_clean_output_contains "Initializing module root and all examples"
  assert_clean_output_contains "Initializing Terraform module at root"
  assert_clean_output_contains "Initializing examples"
}

@test "tf-init-all still runs in project repo (not gated)" {
  setup_project_fixture
  _dsbTfLogErrors=1
  run tf-init-all
  # may fail due to mock limitations but should NOT fail with "only available in module repos"
  assert_clean_output_not_contains "only available in Terraform module repos"
}

@test "tf-init-all-offline succeeds in module repo" {
  setup_module_fixture
  run tf-init-all-offline
  assert_success
}

@test "tf-init-all help mentions module repos" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-help tf-init-all
  assert_success
  assert_clean_output_contains "module repos"
}

# ===========================================================================
# Feature 6: tf-versions
# ===========================================================================

@test "tf-versions function exists" {
  setup_module_fixture
  assert_function_exists "tf-versions"
}

@test "tf-versions succeeds in module repo" {
  setup_module_fixture
  run tf-versions
  assert_success
}

@test "tf-versions shows version information in module repo" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-versions
  assert_success
  assert_clean_output_contains "Version Information"
  assert_clean_output_contains "Tool Versions"
  assert_clean_output_contains "Terraform CLI"
}

@test "tf-versions shows module root versions" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-versions
  assert_success
  assert_clean_output_contains "Module Root Versions"
}

@test "tf-versions succeeds in project repo" {
  setup_project_fixture
  run tf-versions
  assert_success
}

@test "tf-versions shows environment info in project repo" {
  setup_project_fixture
  _dsbTfLogInfo=1
  run tf-versions
  assert_success
  assert_clean_output_contains "Version Information"
  assert_clean_output_contains "Tool Versions"
}

@test "tf-versions help entry exists" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-help tf-versions
  assert_success
  assert_clean_output_contains "tf-versions"
  assert_clean_output_contains "version information"
}

# ===========================================================================
# Feature 7: Ungating offline commands for module repos
# ===========================================================================

@test "tf-init-all-offline succeeds in module repo (ungated)" {
  setup_module_fixture
  run tf-init-all-offline
  assert_success
}

@test "tf-upgrade-all succeeds in module repo (ungated)" {
  setup_module_fixture
  run tf-upgrade-all
  assert_success
}

@test "tf-upgrade-all-offline succeeds in module repo (ungated)" {
  setup_module_fixture
  run tf-upgrade-all-offline
  assert_success
}

@test "tf-bump-all succeeds in module repo (ungated)" {
  setup_module_fixture
  run tf-bump-all
  assert_success
}

@test "tf-bump-all-offline succeeds in module repo (ungated)" {
  setup_module_fixture
  run tf-bump-all-offline
  assert_success
}

@test "tf-init-all-offline still runs in project repo (not gated)" {
  setup_project_fixture
  _dsbTfLogErrors=1
  run tf-init-all-offline
  assert_clean_output_not_contains "only available in Terraform module repos"
}

@test "tf-upgrade-all still runs in project repo (not gated)" {
  setup_project_fixture
  _dsbTfLogErrors=1
  run tf-upgrade-all
  assert_clean_output_not_contains "only available in Terraform module repos"
}

@test "tf-upgrade-all-offline still runs in project repo (not gated)" {
  setup_project_fixture
  _dsbTfLogErrors=1
  run tf-upgrade-all-offline
  assert_clean_output_not_contains "only available in Terraform module repos"
}

@test "tf-bump-all still runs in project repo (not gated)" {
  setup_project_fixture
  _dsbTfLogErrors=1
  run tf-bump-all
  assert_clean_output_not_contains "only available in Terraform module repos"
}

@test "tf-bump-all-offline still runs in project repo (not gated)" {
  setup_project_fixture
  _dsbTfLogErrors=1
  run tf-bump-all-offline
  assert_clean_output_not_contains "only available in Terraform module repos"
}

@test "tf-init-env-offline still requires project repo" {
  setup_module_fixture
  _dsbTfLogErrors=1
  run tf-init-env-offline
  assert_failure
  assert_clean_output_contains "only available in Terraform project repos"
}

@test "tf-bump-env-offline still requires project repo" {
  setup_module_fixture
  _dsbTfLogErrors=1
  run tf-bump-env-offline
  assert_failure
  assert_clean_output_contains "only available in Terraform project repos"
}

@test "tf-upgrade-env-offline still requires project repo" {
  setup_module_fixture
  _dsbTfLogErrors=1
  run tf-upgrade-env-offline
  assert_failure
  assert_clean_output_contains "only available in Terraform project repos"
}

# ===========================================================================
# Help system: new commands included in help
# ===========================================================================

@test "tf-help commands lists tf-validate-all" {
  setup_project_fixture
  _dsbTfLogInfo=1
  output="$(tf-help commands 2>&1)"
  status=$?
  assert_success
  assert_clean_output_contains "tf-validate-all"
}

@test "tf-help commands lists tf-lint-all" {
  setup_project_fixture
  _dsbTfLogInfo=1
  output="$(tf-help commands 2>&1)"
  status=$?
  assert_success
  assert_clean_output_contains "tf-lint-all"
}

@test "tf-help commands lists tf-outputs" {
  setup_project_fixture
  _dsbTfLogInfo=1
  output="$(tf-help commands 2>&1)"
  status=$?
  assert_success
  assert_clean_output_contains "tf-outputs"
}

@test "tf-help commands lists tf-versions" {
  setup_project_fixture
  _dsbTfLogInfo=1
  output="$(tf-help commands 2>&1)"
  status=$?
  assert_success
  assert_clean_output_contains "tf-versions"
}

@test "tf-help commands in module repo lists tf-init-all" {
  setup_module_fixture
  _dsbTfLogInfo=1
  output="$(tf-help commands 2>&1)"
  status=$?
  assert_success
  assert_clean_output_contains "tf-init-all"
}

@test "tf-help commands in module repo lists tf-validate-all" {
  setup_module_fixture
  _dsbTfLogInfo=1
  output="$(tf-help commands 2>&1)"
  status=$?
  assert_success
  assert_clean_output_contains "tf-validate-all"
}

@test "tf-help commands in module repo lists tf-outputs" {
  setup_module_fixture
  _dsbTfLogInfo=1
  output="$(tf-help commands 2>&1)"
  status=$?
  assert_success
  assert_clean_output_contains "tf-outputs"
}

@test "tf-help commands in module repo lists tf-versions" {
  setup_module_fixture
  _dsbTfLogInfo=1
  output="$(tf-help commands 2>&1)"
  status=$?
  assert_success
  assert_clean_output_contains "tf-versions"
}
