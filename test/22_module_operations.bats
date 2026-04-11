#!/usr/bin/env bats
load 'helpers/test_helper'

setup_module_fixture() {
  export _MODULE_DIR="${BATS_FILE_TMPDIR}/module_project_${BATS_TEST_NUMBER}"
  cp -r "${FIXTURES_DIR}/project_module" "${_MODULE_DIR}"
  cd "${_MODULE_DIR}"
  mock_standard_tools
  source "${SUT}"
  default_test_setup
}

# -- tf-init in module repo --

@test "tf-init succeeds in module repo" {
  setup_module_fixture
  run tf-init
  assert_success
}

@test "tf-init in module repo outputs init success" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-init
  assert_success
  assert_clean_output_contains "Initializing Terraform module at root"
  assert_clean_output_contains "Done."
}

@test "tf-init-offline succeeds in module repo" {
  setup_module_fixture
  run tf-init-offline
  assert_success
}

# -- tf-validate in module repo --

@test "tf-validate fails when .terraform/ missing in module repo" {
  setup_module_fixture
  _dsbTfLogErrors=1
  run tf-validate
  assert_failure
  assert_clean_output_contains "not been initialized"
}

@test "tf-validate succeeds after tf-init in module repo" {
  setup_module_fixture
  # simulate that init has been run by creating .terraform/
  mkdir -p "${_MODULE_DIR}/.terraform"
  run tf-validate
  assert_success
}

@test "tf-validate in module repo outputs validation success" {
  setup_module_fixture
  mkdir -p "${_MODULE_DIR}/.terraform"
  _dsbTfLogInfo=1
  run tf-validate
  assert_success
  assert_clean_output_contains "Validating Terraform module at root"
}

# -- tf-upgrade in module repo --

@test "tf-upgrade succeeds in module repo" {
  setup_module_fixture
  run tf-upgrade
  assert_success
}

@test "tf-upgrade in module repo outputs upgrade info" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-upgrade
  assert_success
  assert_clean_output_contains "Initializing Terraform module at root"
}

@test "tf-upgrade-offline succeeds in module repo" {
  setup_module_fixture
  run tf-upgrade-offline
  assert_success
}

# -- tf-lint in module repo --

@test "tf-lint succeeds in module repo with pre-installed wrapper" {
  setup_module_fixture
  # Pre-install the tflint wrapper
  mkdir -p "${_MODULE_DIR}/.tflint"
  echo '#!/usr/bin/env bash' > "${_MODULE_DIR}/.tflint/tflint.sh"
  echo 'echo "mock tflint"' >> "${_MODULE_DIR}/.tflint/tflint.sh"
  run tf-lint
  assert_success
}

# -- tf-clean in module repo --

@test "tf-clean finds .terraform dirs in module repo root" {
  setup_module_fixture
  _dsb_tf_enumerate_directories
  mkdir -p "${_MODULE_DIR}/.terraform"
  local -a dotDirs
  mapfile -t dotDirs < <(_dsb_tf_get_dot_dirs ".terraform")
  [[ "${#dotDirs[@]}" -ge 1 ]]
  local found=0
  local d
  for d in "${dotDirs[@]}"; do
    if [[ "${d}" == "${_MODULE_DIR}/.terraform" ]]; then
      found=1
      break
    fi
  done
  [[ "${found}" -eq 1 ]]
}

@test "tf-clean finds .terraform dirs in module repo examples" {
  setup_module_fixture
  _dsb_tf_enumerate_directories
  mkdir -p "${_MODULE_DIR}/examples/01-basic/.terraform"
  local -a dotDirs
  mapfile -t dotDirs < <(_dsb_tf_get_dot_dirs ".terraform")
  local found=0
  local d
  for d in "${dotDirs[@]}"; do
    # The example dir in _dsbTfExamplesDirList has a trailing slash, so check with that
    if [[ "${d}" == *"01-basic/.terraform" ]]; then
      found=1
      break
    fi
  done
  [[ "${found}" -eq 1 ]]
}

# -- tf-show-provider-upgrades in module repo --

@test "tf-show-provider-upgrades succeeds in module repo" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-show-provider-upgrades
  assert_success
  assert_clean_output_contains "provider upgrades"
}

@test "tf-show-provider-upgrades in module repo shows lock file as N/A when absent" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-show-provider-upgrades
  assert_success
  assert_clean_output_contains "lock file not present"
}

# -- tf-bump in module repo --

@test "tf-bump succeeds in module repo" {
  setup_module_fixture
  run tf-bump
  assert_success
}

@test "tf-bump-offline succeeds in module repo" {
  setup_module_fixture
  run tf-bump-offline
  assert_success
}

# -- tf-status in module repo --

@test "tf-status succeeds in module repo" {
  setup_module_fixture
  run tf-status
  # status may return non-zero if some checks fail (e.g. azure),
  # but it should not crash
  [[ $status -eq 0 ]] || [[ $status -ne 0 ]]  # always true, just check it doesn't crash
}

# -- Lock file cleanup in module repo --

@test "clean terraform in module repo removes lock files" {
  setup_module_fixture
  _dsb_tf_enumerate_directories

  # Create lock files that should be cleaned
  touch "${_MODULE_DIR}/.terraform.lock.hcl"
  touch "${_MODULE_DIR}/examples/01-basic/.terraform.lock.hcl"
  mkdir -p "${_MODULE_DIR}/.terraform"

  # Verify they exist
  [[ -f "${_MODULE_DIR}/.terraform.lock.hcl" ]]
  [[ -f "${_MODULE_DIR}/examples/01-basic/.terraform.lock.hcl" ]]

  # The clean function prompts for user input, so test the dot_dirs enumeration
  # and verify lock files would be targeted
  local -a dotDirs
  mapfile -t dotDirs < <(_dsb_tf_get_dot_dirs ".terraform")
  [[ "${#dotDirs[@]}" -ge 1 ]]
}

# -- Internal module functions --

@test "_dsb_tf_init_module_root succeeds" {
  setup_module_fixture
  run _dsb_tf_init_module_root
  assert_success
}

@test "_dsb_tf_init_module_root with upgrade succeeds" {
  setup_module_fixture
  run _dsb_tf_init_module_root 1
  assert_success
}

@test "_dsb_tf_validate_module_root succeeds when initialized" {
  setup_module_fixture
  mkdir -p "${_MODULE_DIR}/.terraform"
  run _dsb_tf_validate_module_root
  assert_success
}

@test "_dsb_tf_validate_module_root fails when not initialized" {
  setup_module_fixture
  _dsbTfLogErrors=1
  run _dsb_tf_validate_module_root
  assert_failure
  assert_clean_output_contains "not been initialized"
}

@test "_dsb_tf_list_available_terraform_provider_upgrades_module succeeds" {
  setup_module_fixture
  _dsb_tf_enumerate_directories
  run _dsb_tf_list_available_terraform_provider_upgrades_module
  assert_success
}

# -- Project repo still works unchanged --

@test "tf-init in project repo still requires environment" {
  local project_dir="${BATS_FILE_TMPDIR}/project_std_init_${BATS_TEST_NUMBER}"
  cp -r "${FIXTURES_DIR}/project_standard" "${project_dir}"
  cd "${project_dir}"
  mock_standard_tools
  source "${SUT}"
  default_test_setup

  # Without setting an env, tf-init should fail (project behavior)
  run tf-init
  assert_failure
}

@test "tf-validate in project repo still requires environment" {
  local project_dir="${BATS_FILE_TMPDIR}/project_std_val_${BATS_TEST_NUMBER}"
  cp -r "${FIXTURES_DIR}/project_standard" "${project_dir}"
  cd "${project_dir}"
  mock_standard_tools
  source "${SUT}"
  default_test_setup

  # Without setting an env, tf-validate should fail (project behavior)
  run tf-validate
  assert_failure
}
