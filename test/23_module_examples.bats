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

# -- Phase 4: tf-init-all-examples --

@test "tf-init-all-examples succeeds in module repo" {
  setup_module_fixture
  run tf-init-all-examples
  assert_success
}

@test "tf-init-all-examples outputs per-example status" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-init-all-examples
  assert_success
  assert_clean_output_contains "Initializing examples"
  assert_clean_output_contains "01-basic"
  assert_clean_output_contains "02-advanced"
  assert_clean_output_contains "succeeded"
}

@test "tf-init-all-examples with specific example initializes only that example" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-init-all-examples "01-basic"
  assert_success
  assert_clean_output_contains "01-basic"
  assert_clean_output_not_contains "02-advanced"
}

@test "tf-init-all-examples with nonexistent example fails" {
  setup_module_fixture
  _dsbTfLogErrors=1
  run tf-init-all-examples "nonexistent"
  assert_failure
  assert_clean_output_contains "not found"
}

@test "tf-init-all-examples fails in project repo" {
  local project_dir
  project_dir="$(create_standard_project)"
  cd "${project_dir}"
  mock_standard_tools
  source "${SUT}"
  default_test_setup

  run tf-init-all-examples
  assert_failure
  assert_clean_output_contains "only available in Terraform module repos"
}

@test "tf-init-all-examples shows summary with count" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-init-all-examples
  assert_success
  assert_clean_output_contains "2 succeeded, 0 failed out of 2"
}

# -- Phase 4: tf-validate-all-examples --

@test "tf-validate-all-examples succeeds after init in module repo" {
  setup_module_fixture
  # Simulate init for both examples
  mkdir -p "${_MODULE_DIR}/examples/01-basic/.terraform"
  mkdir -p "${_MODULE_DIR}/examples/02-advanced/.terraform"
  run tf-validate-all-examples
  assert_success
}

@test "tf-validate-all-examples fails when examples not initialized" {
  setup_module_fixture
  _dsbTfLogErrors=1
  run tf-validate-all-examples
  assert_failure
  assert_clean_output_contains "not been initialized"
}

@test "tf-validate-all-examples with specific example works" {
  setup_module_fixture
  mkdir -p "${_MODULE_DIR}/examples/01-basic/.terraform"
  _dsbTfLogInfo=1
  run tf-validate-all-examples "01-basic"
  assert_success
  assert_clean_output_contains "01-basic"
  assert_clean_output_not_contains "02-advanced"
}

@test "tf-validate-all-examples fails in project repo" {
  local project_dir
  project_dir="$(create_standard_project)"
  cd "${project_dir}"
  mock_standard_tools
  source "${SUT}"
  default_test_setup

  run tf-validate-all-examples
  assert_failure
  assert_clean_output_contains "only available in Terraform module repos"
}

# -- Phase 4: tf-lint-all-examples --

@test "tf-lint-all-examples succeeds with pre-installed wrapper" {
  setup_module_fixture
  # Pre-install the tflint wrapper
  mkdir -p "${_MODULE_DIR}/.tflint"
  echo '#!/usr/bin/env bash' > "${_MODULE_DIR}/.tflint/tflint.sh"
  echo 'echo "mock tflint"' >> "${_MODULE_DIR}/.tflint/tflint.sh"
  run tf-lint-all-examples
  assert_success
}

@test "tf-lint-all-examples with specific example" {
  setup_module_fixture
  mkdir -p "${_MODULE_DIR}/.tflint"
  echo '#!/usr/bin/env bash' > "${_MODULE_DIR}/.tflint/tflint.sh"
  echo 'echo "mock tflint"' >> "${_MODULE_DIR}/.tflint/tflint.sh"
  _dsbTfLogInfo=1
  run tf-lint-all-examples "01-basic"
  assert_success
  assert_clean_output_contains "01-basic"
}

@test "tf-lint-all-examples fails in project repo" {
  local project_dir
  project_dir="$(create_standard_project)"
  cd "${project_dir}"
  mock_standard_tools
  source "${SUT}"
  default_test_setup

  run tf-lint-all-examples
  assert_failure
  assert_clean_output_contains "only available in Terraform module repos"
}

# -- Phase 4: _dsb_tf_require_module_repo --

@test "_dsb_tf_require_module_repo succeeds in module repo" {
  setup_module_fixture
  _dsb_tf_enumerate_directories
  run _dsb_tf_require_module_repo
  assert_success
}

@test "_dsb_tf_require_module_repo fails in project repo" {
  local project_dir
  project_dir="$(create_standard_project)"
  cd "${project_dir}"
  mock_standard_tools
  source "${SUT}"
  default_test_setup
  _dsb_tf_enumerate_directories

  _dsbTfLogErrors=1
  run _dsb_tf_require_module_repo
  assert_failure
  assert_clean_output_contains "only available in Terraform module repos"
}

# -- Module fixture includes 02-advanced example --

@test "module enumeration finds both examples with fixture update" {
  setup_module_fixture
  _dsb_tf_enumerate_directories
  [[ -n "${_dsbTfExamplesDirList[01-basic]:-}" ]]
  [[ -n "${_dsbTfExamplesDirList[02-advanced]:-}" ]]
}

# -- Singular example commands --

@test "tf-init-example requires example name" {
  setup_module_fixture
  run tf-init-example
  assert_failure
  assert_clean_output_contains "No example specified"
}

@test "tf-init-example succeeds with valid example" {
  setup_module_fixture
  run tf-init-example "01-basic"
  assert_success
}

@test "tf-validate-example requires example name" {
  setup_module_fixture
  run tf-validate-example
  assert_failure
  assert_clean_output_contains "No example specified"
}

@test "tf-lint-example requires example name" {
  setup_module_fixture
  run tf-lint-example
  assert_failure
  assert_clean_output_contains "No example specified"
}

@test "tf-init-example fails for nonexistent example" {
  setup_module_fixture
  run tf-init-example "nonexistent"
  assert_failure
  assert_clean_output_contains "not found"
}
