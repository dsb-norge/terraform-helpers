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
