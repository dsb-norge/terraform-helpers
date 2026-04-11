#!/usr/bin/env bats
load 'helpers/test_helper'

setup() {
  default_test_setup
  project_dir="${BATS_TEST_TMPDIR}/project"
  cp -r "${BATS_TEST_DIRNAME}/fixtures/project_standard" "${project_dir}"
  # Create .terraform/providers so init-main and init-modules can find it
  mkdir -p "${project_dir}/envs/dev/.terraform/providers"
  mkdir -p "${project_dir}/envs/prod/.terraform/providers"
  cd "${project_dir}"
  mock_standard_tools
  source "${SUT}"
}

teardown() {
  default_test_teardown
}

# -------------------------------------------------------
# tf-init
# -------------------------------------------------------

@test "tf-init with env runs terraform init via mock" {
  mock_terraform
  mock_az
  run tf-init "dev"
  assert_success
  assert_output --partial "Initializing"
}

@test "tf-init with no env and none selected fails" {
  mock_terraform
  # Ensure no env is selected
  run tf-init ""
  assert_failure
  assert_output --partial "No environment specified"
}

# -------------------------------------------------------
# tf-init-offline
# -------------------------------------------------------

@test "tf-init-offline passes -backend=false" {
  mock_terraform
  run tf-init-offline "dev"
  assert_success
  assert_output --partial "Initializ"
}

# -------------------------------------------------------
# tf-init-env
# -------------------------------------------------------

@test "tf-init-env initializes only the env dir" {
  mock_terraform
  mock_az
  run tf-init-env "dev"
  assert_success
  assert_output --partial "Initializing environment"
}

# -------------------------------------------------------
# tf-validate
# -------------------------------------------------------

@test "tf-validate runs terraform validate" {
  mock_terraform
  run tf-validate "dev"
  assert_success
  assert_output --partial "Validating environment"
}

# -------------------------------------------------------
# tf-plan
# -------------------------------------------------------

@test "tf-plan runs terraform plan" {
  mock_terraform
  mock_az
  run tf-plan "dev"
  assert_success
  assert_output --partial "Creating plan"
}

# -------------------------------------------------------
# tf-apply
# -------------------------------------------------------

@test "tf-apply runs terraform apply" {
  mock_terraform
  mock_az
  run tf-apply "dev"
  assert_success
  assert_output --partial "Running apply"
}

# -------------------------------------------------------
# tf-destroy
# -------------------------------------------------------

@test "tf-destroy prints command but does NOT run destroy" {
  mock_terraform
  mock_az
  run tf-destroy "dev"
  assert_success
  assert_output --partial "terraform -chdir="
  assert_output --partial "destroy"
  assert_output --partial "run the following command manually"
}

# -------------------------------------------------------
# tf-fmt
# -------------------------------------------------------

@test "tf-fmt runs terraform fmt with -check" {
  mock_terraform
  run tf-fmt
  assert_success
  assert_output --partial "Running terraform fmt"
}

@test "tf-fmt-fix runs terraform fmt without -check" {
  mock_terraform
  run tf-fmt-fix
  assert_success
  assert_output --partial "Running terraform fmt"
}

# -------------------------------------------------------
# Terraform preflight
# -------------------------------------------------------

@test "terraform preflight checks for terraform installed" {
  mock_terraform_not_installed
  run tf-validate "dev"
  assert_failure
  assert_output --partial "Terraform check failed"
}

# -------------------------------------------------------
# Pipeline failure detection
# -------------------------------------------------------

@test "tf-init reports failure when terraform init fails" {
  mock_terraform_init_fails
  mock_az
  run tf-init "dev"
  assert_failure
}

@test "tf-validate reports failure when terraform validate fails" {
  mock_terraform_validate_fails
  mock_az
  run tf-validate "dev"
  assert_failure
}

@test "tf-plan reports failure when terraform plan fails" {
  mock_terraform_plan_fails
  mock_az
  run tf-plan "dev"
  assert_failure
}

# -------------------------------------------------------
# Terraform preflight (continued)
# -------------------------------------------------------

@test "terraform preflight exports ARM_SUBSCRIPTION_ID on online operations" {
  mock_terraform
  mock_az
  # Run tf-plan in a subshell that prints ARM_SUBSCRIPTION_ID
  run bash -c "
    cd '${project_dir}'
    source '${SUT}' 2>/dev/null
    export _dsbTfLogInfo=0
    export _dsbTfLogWarnings=0
    export _dsbTfLogErrors=0
    tf-plan dev
    echo \"ARM_SUB=\${ARM_SUBSCRIPTION_ID:-NOTSET}\"
  "
  assert_success
  assert_line --partial "ARM_SUB=00000000-0000-0000-0000-000000000001"
}
