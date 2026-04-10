#!/usr/bin/env bash
# test_helper.bash -- shared setup loaded by every test file
# Usage: load 'helpers/test_helper' at the top of each .bats file

# Resolve the real test dir (handles symlinks)
HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(cd "${HELPERS_DIR}/.." && pwd)"
PROJECT_DIR="$(cd "${TEST_DIR}/.." && pwd)"

# Load bats libraries
load "${PROJECT_DIR}/node_modules/bats-support/load"
load "${PROJECT_DIR}/node_modules/bats-assert/load"
load "${PROJECT_DIR}/node_modules/bats-file/load"

# Load our helpers
load "${HELPERS_DIR}/mock_helper"
load "${HELPERS_DIR}/fixture_helper"
load "${HELPERS_DIR}/assertion_helper"

# Path to the script under test
export SUT="${PROJECT_DIR}/dsb-tf-proj-helpers.sh"

# Default setup: mute logging so tests aren't noisy
# Individual tests/files can override this
default_test_setup() {
  export _dsbTfLogInfo=0
  export _dsbTfLogWarnings=0
  export _dsbTfLogErrors=0
  export _dsbTfLogDebug=0
}

# Safety teardown: ensure shell is restored even if a test fails
default_test_teardown() {
  # Restore shell if configure_shell was called
  if declare -F _dsb_tf_restore_shell &>/dev/null; then
    # Only restore if we're in configured state (traps are set)
    if [[ "$(trap -p ERR 2>/dev/null)" == *"_dsb_tf_error_handler"* ]]; then
      _dsb_tf_restore_shell 2>/dev/null || true
    fi
  fi

  # Unmock everything
  unmock_all

  # Restore working directory
  cd "${PROJECT_DIR}" 2>/dev/null || true
}

# Source the script under test in a project directory.
# Sets up mocks first so the source-time init code runs against mocks.
# Usage: source_script_in_project [project_dir]
source_script_in_project() {
  local project_dir="${1:-}"

  if [[ -z "${project_dir}" ]]; then
    project_dir="$(create_standard_project)"
  fi

  cd "${project_dir}"
  mock_standard_tools
  # Source the script -- this runs init code (cleanup, arch check, enumerate, completions)
  source "${SUT}"
}
