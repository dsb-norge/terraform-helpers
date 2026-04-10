#!/usr/bin/env bash
# fixture_helper.bash -- helpers for creating test fixture directories

FIXTURES_DIR="${BATS_TEST_DIRNAME}/fixtures"

# Create a standard project fixture in a temp directory and echo the path
create_standard_project() {
  local dest="${BATS_TEST_TMPDIR}/project"
  cp -r "${FIXTURES_DIR}/project_standard" "${dest}"
  echo "${dest}"
}

create_project_no_envs() {
  local dest="${BATS_TEST_TMPDIR}/project"
  cp -r "${FIXTURES_DIR}/project_no_envs" "${dest}"
  echo "${dest}"
}

create_project_no_main() {
  local dest="${BATS_TEST_TMPDIR}/project"
  cp -r "${FIXTURES_DIR}/project_no_main" "${dest}"
  echo "${dest}"
}

create_empty_project() {
  local dest="${BATS_TEST_TMPDIR}/project"
  mkdir -p "${dest}"
  echo "${dest}"
}

# Create a standard project and source the script in it.
# Returns the project dir path. Sets up mocks.
# After this, all tf-*/az-* functions are available and the script
# has initialized against the project directory.
setup_sourced_project() {
  local project_dir
  project_dir="$(create_standard_project)"
  cd "${project_dir}"
  mock_standard_tools
  source "${SUT}"
  echo "${project_dir}"
}
