#!/usr/bin/env bats
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
# tf-lint
# -------------------------------------------------------

@test "tf-lint with env runs the tflint wrapper" {
  mock_az
  mock_gh
  # tf-lint downloads the wrapper then runs it; mock gh/curl handle the download
  run tf-lint "dev"
  # The wrapper is a mock that just echoes, so it should succeed
  assert_success
}

@test "tflint wrapper is downloaded if missing" {
  mock_az
  mock_gh
  # Ensure the wrapper does not exist
  rm -rf "${project_dir}/.tflint"

  run tf-lint "dev"
  assert_success
  # After the run, the wrapper should have been created
  [[ -f "${project_dir}/.tflint/tflint.sh" ]]
}

@test "tf-lint reports failure when wrapper script fails" {
  mock_az
  mock_gh
  # Pre-create a wrapper that exits with failure
  mkdir -p "${project_dir}/.tflint"
  printf '#!/usr/bin/env bash\necho "tflint error" >&2\nexit 1\n' > "${project_dir}/.tflint/tflint.sh"
  chmod +x "${project_dir}/.tflint/tflint.sh"

  run tf-lint "dev"
  assert_failure
}

@test "tf-lint preserves working directory even on failure" {
  mock_az
  mock_gh
  local original_pwd="${PWD}"
  # Pre-create a wrapper that fails
  mkdir -p "${project_dir}/.tflint"
  printf '#!/usr/bin/env bash\nexit 1\n' > "${project_dir}/.tflint/tflint.sh"
  chmod +x "${project_dir}/.tflint/tflint.sh"

  tf-lint "dev" || true
  [[ "${PWD}" == "${original_pwd}" ]]
}

@test "tflint wrapper is not re-downloaded if present" {
  mock_az
  mock_gh
  # Pre-create the wrapper
  mkdir -p "${project_dir}/.tflint"
  echo '#!/usr/bin/env bash' > "${project_dir}/.tflint/tflint.sh"
  echo 'echo "existing tflint wrapper"' >> "${project_dir}/.tflint/tflint.sh"
  chmod +x "${project_dir}/.tflint/tflint.sh"

  run tf-lint "dev"
  assert_success
  # The existing wrapper content should still be there (not overwritten)
  run cat "${project_dir}/.tflint/tflint.sh"
  assert_output --partial "existing tflint wrapper"
}
