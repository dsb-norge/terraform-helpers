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
# tf-validate-all
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
# tf-lint-all
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
