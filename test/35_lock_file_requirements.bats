#!/usr/bin/env bats
# shellcheck disable=SC2164,SC1090,SC1091,SC2030,SC2031,SC2034,SC2154,SC2317
#
# Tests that verify lock file (.terraform.lock.hcl) requirements for all
# relevant exposed commands. Fresh repos from templates have no lock files,
# so commands that create lock files (init, upgrade, bump) must not require them.
#
load 'helpers/test_helper'

# Helper: set up a project with NO lock files (simulates fresh repo from template)
setup_project_no_lock_files() {
  export BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-${BATS_FILE_TMPDIR}}"
  project_dir="${BATS_TEST_TMPDIR}/project_no_lock_${BATS_TEST_NUMBER}"
  cp -r "${BATS_TEST_DIRNAME}/fixtures/project_standard" "${project_dir}"
  # Remove all lock files to simulate a fresh repo
  find "${project_dir}" -name ".terraform.lock.hcl" -delete
  # Create .terraform/providers so init can find them
  mkdir -p "${project_dir}/envs/dev/.terraform/providers"
  mkdir -p "${project_dir}/envs/prod/.terraform/providers"
  cd "${project_dir}"
  mock_standard_tools
  source "${SUT}"
  default_test_setup
}

# Helper: set up a project WITH lock files (normal state)
setup_project_with_lock_files() {
  export BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-${BATS_FILE_TMPDIR}}"
  project_dir="${BATS_TEST_TMPDIR}/project_lock_${BATS_TEST_NUMBER}"
  cp -r "${BATS_TEST_DIRNAME}/fixtures/project_standard" "${project_dir}"
  mkdir -p "${project_dir}/envs/dev/.terraform/providers"
  mkdir -p "${project_dir}/envs/prod/.terraform/providers"
  cd "${project_dir}"
  mock_standard_tools
  source "${SUT}"
  default_test_setup
}

# Helper: mock terraform that also creates a lock file (simulates real behavior)
mock_terraform_creates_lock() {
  terraform() {
    local chdir=""
    for arg in "$@"; do
      case "${arg}" in
        -chdir=*) chdir="${arg#-chdir=}" ;;
      esac
    done
    if [[ -n "${chdir}" ]] && [[ "$*" == *"init"* ]]; then
      cat > "${chdir}/.terraform.lock.hcl" <<'LOCK'
provider "registry.terraform.io/hashicorp/azurerm" {
  version = "3.85.0"
  hashes  = ["h1:mock="]
}
LOCK
      mkdir -p "${chdir}/.terraform/providers" 2>/dev/null
    fi
    echo "Terraform mock: $*"
    return 0
  }
  export -f terraform
}

teardown() {
  default_test_teardown
}

# ===========================================================================
# Commands that CREATE lock files -- must succeed WITHOUT lock files
# ===========================================================================

# -- tf-init family --

@test "tf-init succeeds without lock file (fresh repo)" {
  setup_project_no_lock_files
  mock_terraform_creates_lock
  run tf-init "dev"
  assert_success
}

@test "tf-init-offline succeeds without lock file (fresh repo)" {
  setup_project_no_lock_files
  mock_terraform_creates_lock
  run tf-init-offline "dev"
  assert_success
}

@test "tf-init-env succeeds without lock file (fresh repo)" {
  setup_project_no_lock_files
  mock_terraform_creates_lock
  run tf-init-env "dev"
  assert_success
}

@test "tf-init-env-offline succeeds without lock file (fresh repo)" {
  setup_project_no_lock_files
  mock_terraform_creates_lock
  run tf-init-env-offline "dev"
  assert_success
}

@test "tf-init-all succeeds without lock file (fresh repo)" {
  setup_project_no_lock_files
  mock_terraform_creates_lock
  run tf-init-all
  assert_success
}

@test "tf-init-all-offline succeeds without lock file (fresh repo)" {
  setup_project_no_lock_files
  mock_terraform_creates_lock
  run tf-init-all-offline
  assert_success
}

# -- tf-upgrade family --

@test "tf-upgrade succeeds without lock file (fresh repo)" {
  setup_project_no_lock_files
  mock_terraform_creates_lock
  run tf-upgrade "dev"
  assert_success
}

@test "tf-upgrade-offline succeeds without lock file (fresh repo)" {
  setup_project_no_lock_files
  mock_terraform_creates_lock
  run tf-upgrade-offline "dev"
  assert_success
}

@test "tf-upgrade-env succeeds without lock file (fresh repo)" {
  setup_project_no_lock_files
  mock_terraform_creates_lock
  run tf-upgrade-env "dev"
  assert_success
}

@test "tf-upgrade-env-offline succeeds without lock file (fresh repo)" {
  setup_project_no_lock_files
  mock_terraform_creates_lock
  run tf-upgrade-env-offline "dev"
  assert_success
}

@test "tf-upgrade-all succeeds without lock file (fresh repo)" {
  setup_project_no_lock_files
  mock_terraform_creates_lock
  run tf-upgrade-all
  assert_success
}

@test "tf-upgrade-all-offline succeeds without lock file (fresh repo)" {
  setup_project_no_lock_files
  mock_terraform_creates_lock
  run tf-upgrade-all-offline
  assert_success
}

# -- tf-bump family --

@test "tf-bump succeeds without lock file (fresh repo)" {
  setup_project_no_lock_files
  mock_terraform_creates_lock
  run tf-bump "dev"
  assert_success
}

@test "tf-bump-offline succeeds without lock file (fresh repo)" {
  setup_project_no_lock_files
  mock_terraform_creates_lock
  run tf-bump-offline "dev"
  assert_success
}

@test "tf-bump-env succeeds without lock file (fresh repo)" {
  setup_project_no_lock_files
  mock_terraform_creates_lock
  run tf-bump-env "dev"
  assert_success
}

@test "tf-bump-env-offline succeeds without lock file (fresh repo)" {
  setup_project_no_lock_files
  mock_terraform_creates_lock
  run tf-bump-env-offline "dev"
  assert_success
}

@test "tf-bump-all succeeds without lock file (fresh repo)" {
  setup_project_no_lock_files
  mock_terraform_creates_lock
  run tf-bump-all
  assert_success
}

@test "tf-bump-all-offline succeeds without lock file (fresh repo)" {
  setup_project_no_lock_files
  mock_terraform_creates_lock
  run tf-bump-all-offline
  assert_success
}

# ===========================================================================
# Commands that READ state -- should require lock files
# ===========================================================================

@test "tf-plan fails without lock file" {
  setup_project_no_lock_files
  _dsbTfLogErrors=1
  run tf-plan "dev"
  assert_failure
}

@test "tf-apply fails without lock file" {
  setup_project_no_lock_files
  _dsbTfLogErrors=1
  run tf-apply "dev"
  assert_failure
}

@test "tf-destroy fails without lock file" {
  setup_project_no_lock_files
  _dsbTfLogErrors=1
  run tf-destroy "dev"
  assert_failure
}

# ===========================================================================
# Commands that are purely local -- should NOT require lock files
# ===========================================================================

@test "tf-lint succeeds without lock file" {
  setup_project_no_lock_files
  run tf-lint "dev"
  assert_success
}

@test "tf-validate succeeds without lock file" {
  setup_project_no_lock_files
  run tf-validate "dev"
  assert_success
}

@test "tf-fmt succeeds without lock file" {
  setup_project_no_lock_files
  run tf-fmt
  assert_success
}

@test "tf-fmt-fix succeeds without lock file" {
  setup_project_no_lock_files
  run tf-fmt-fix
  assert_success
}

# ===========================================================================
# Sanity: commands still work WITH lock files
# ===========================================================================

@test "tf-init succeeds with lock file" {
  setup_project_with_lock_files
  run tf-init "dev"
  assert_success
}

@test "tf-plan succeeds with lock file" {
  setup_project_with_lock_files
  run tf-plan "dev"
  assert_success
}

@test "tf-lint succeeds with lock file" {
  setup_project_with_lock_files
  run tf-lint "dev"
  assert_success
}
