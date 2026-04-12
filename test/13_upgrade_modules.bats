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
