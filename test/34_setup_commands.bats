#!/usr/bin/env bats
# shellcheck disable=SC2164,SC1090,SC1091,SC2030,SC2031,SC2034,SC2154,SC2317
load 'helpers/test_helper'

# Helper: set up a fake HOME and source the script
setup_with_fake_home() {
  export BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-${BATS_FILE_TMPDIR}}"

  # Override HOME to a temp dir BEFORE sourcing so init code uses it
  export ORIGINAL_HOME="${HOME}"
  export HOME="${BATS_TEST_TMPDIR}/fakehome_${BATS_TEST_NUMBER}"
  mkdir -p "${HOME}"

  # Set SHELL to bash for consistent profile detection
  export SHELL="/bin/bash"

  # Source script in a project dir context
  source_script_in_project
  default_test_setup
}

setup() {
  setup_with_fake_home
}

teardown() {
  export HOME="${ORIGINAL_HOME}"
  default_test_teardown
}

# ---------------------------------------------------------------------------
# tf-install-helpers: basic installation
# ---------------------------------------------------------------------------

@test "tf-install-helpers creates ~/.local/bin directory" {
  [[ ! -d "${HOME}/.local/bin" ]]
  # Use run with bash -c so we can feed stdin and check the side effect after
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    export HOME="'"${HOME}"'"
    export SHELL="/bin/bash"
    cd "'"$(pwd)"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=0; _dsbTfLogWarnings=0; _dsbTfLogErrors=0; _dsbTfLogDebug=0
    echo "n" | tf-install-helpers
  '
  assert_success
  [[ -d "${HOME}/.local/bin" ]]
}

@test "tf-install-helpers copies script to ~/.local/bin" {
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    export HOME="'"${HOME}"'"
    export SHELL="/bin/bash"
    cd "'"$(pwd)"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=0; _dsbTfLogWarnings=0; _dsbTfLogErrors=0; _dsbTfLogDebug=0
    echo "n" | tf-install-helpers
  '
  assert_success
  [[ -f "${HOME}/.local/bin/dsb-tf-proj-helpers.sh" ]]
}

@test "tf-install-helpers makes script executable" {
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    export HOME="'"${HOME}"'"
    export SHELL="/bin/bash"
    cd "'"$(pwd)"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=0; _dsbTfLogWarnings=0; _dsbTfLogErrors=0; _dsbTfLogDebug=0
    echo "n" | tf-install-helpers
  '
  assert_success
  [[ -x "${HOME}/.local/bin/dsb-tf-proj-helpers.sh" ]]
}

@test "tf-install-helpers prints success message" {
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    export HOME="'"${HOME}"'"
    export SHELL="/bin/bash"
    cd "'"$(pwd)"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=1; _dsbTfLogWarnings=0; _dsbTfLogErrors=0; _dsbTfLogDebug=0
    echo "n" | tf-install-helpers
  '
  assert_success
  assert_clean_output_contains "installed"
  assert_clean_output_contains ".local/bin"
}

@test "tf-install-helpers is idempotent (can run twice)" {
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    export HOME="'"${HOME}"'"
    export SHELL="/bin/bash"
    cd "'"$(pwd)"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=0; _dsbTfLogWarnings=0; _dsbTfLogErrors=0; _dsbTfLogDebug=0
    echo "n" | tf-install-helpers
    echo "n" | tf-install-helpers
  '
  assert_success
  [[ -f "${HOME}/.local/bin/dsb-tf-proj-helpers.sh" ]]
}

# ---------------------------------------------------------------------------
# tf-install-helpers: shell profile alias
# ---------------------------------------------------------------------------

@test "tf-install-helpers asks about shell profile alias" {
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    export HOME="'"${HOME}"'"
    export SHELL="/bin/bash"
    cd "'"$(pwd)"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=1; _dsbTfLogWarnings=0; _dsbTfLogErrors=0; _dsbTfLogDebug=0
    echo "n" | tf-install-helpers
  '
  assert_success
  assert_clean_output_contains "alias"
}

@test "tf-install-helpers adds alias to .bashrc when user says yes" {
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    export HOME="'"${HOME}"'"
    export SHELL="/bin/bash"
    cd "'"$(pwd)"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=0; _dsbTfLogWarnings=0; _dsbTfLogErrors=0; _dsbTfLogDebug=0
    echo "y" | tf-install-helpers
  '
  assert_success
  grep -qF "# dsb-terraform-helpers" "${HOME}/.bashrc"
  grep -qF "tf-load-helpers" "${HOME}/.bashrc"
}

@test "tf-install-helpers does not add alias when user says no" {
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    export HOME="'"${HOME}"'"
    export SHELL="/bin/bash"
    cd "'"$(pwd)"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=0; _dsbTfLogWarnings=0; _dsbTfLogErrors=0; _dsbTfLogDebug=0
    echo "n" | tf-install-helpers
  '
  assert_success
  [[ ! -f "${HOME}/.bashrc" ]] || ! grep -qF "# dsb-terraform-helpers" "${HOME}/.bashrc"
}

@test "tf-install-helpers alias is idempotent (no duplicates)" {
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    export HOME="'"${HOME}"'"
    export SHELL="/bin/bash"
    cd "'"$(pwd)"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=0; _dsbTfLogWarnings=0; _dsbTfLogErrors=0; _dsbTfLogDebug=0
    echo "y" | tf-install-helpers
    echo "y" | tf-install-helpers
  '
  assert_success
  local count
  count=$(grep -cF "# dsb-terraform-helpers" "${HOME}/.bashrc")
  [[ "${count}" -eq 1 ]]
}

@test "tf-install-helpers adds alias to .zshrc for zsh users" {
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    export HOME="'"${HOME}"'"
    export SHELL="/bin/zsh"
    cd "'"$(pwd)"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=0; _dsbTfLogWarnings=0; _dsbTfLogErrors=0; _dsbTfLogDebug=0
    echo "y" | tf-install-helpers
  '
  assert_success
  grep -qF "# dsb-terraform-helpers" "${HOME}/.zshrc"
  grep -qF "tf-load-helpers" "${HOME}/.zshrc"
}

@test "tf-install-helpers alias sources from correct path" {
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    export HOME="'"${HOME}"'"
    export SHELL="/bin/bash"
    cd "'"$(pwd)"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=0; _dsbTfLogWarnings=0; _dsbTfLogErrors=0; _dsbTfLogDebug=0
    echo "y" | tf-install-helpers
  '
  assert_success
  grep -qF 'source "$HOME/.local/bin/dsb-tf-proj-helpers.sh"' "${HOME}/.bashrc"
}

# ---------------------------------------------------------------------------
# tf-install-helpers: process substitution fallback (downloads from GitHub)
# ---------------------------------------------------------------------------

@test "tf-install-helpers downloads when source path not available and gh auth ok" {
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    export HOME="'"${HOME}"'"
    export SHELL="/bin/bash"
    cd "'"$(pwd)"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=1; _dsbTfLogWarnings=0; _dsbTfLogErrors=0; _dsbTfLogDebug=0
    _dsbTfScriptSourcePath=""
    # Override gh mock to return script content via api
    gh() {
      case "$1" in
        --version) echo "gh version 2.40.0"; return 0 ;;
        auth) return 0 ;;
        api) cat "'"${SUT}"'"; return 0 ;;
      esac
      return 1
    }
    export -f gh
    echo "n" | tf-install-helpers
  '
  assert_success
  assert_clean_output_contains "Downloading"
  assert_clean_output_contains "gh cli"
  [[ -f "${HOME}/.local/bin/dsb-tf-proj-helpers.sh" ]]
}

@test "tf-install-helpers downloads via curl when gh not available" {
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    mock_gh_not_installed
    export HOME="'"${HOME}"'"
    export SHELL="/bin/bash"
    cd "'"$(pwd)"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=1; _dsbTfLogWarnings=0; _dsbTfLogErrors=0; _dsbTfLogDebug=0
    _dsbTfScriptSourcePath=""
    # Mock curl to handle -o flag
    curl() {
      local outFile=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          -o) outFile="$2"; shift 2 ;;
          *)  shift ;;
        esac
      done
      if [[ -n "${outFile}" ]]; then
        cat "'"${SUT}"'" > "${outFile}"
      else
        cat "'"${SUT}"'"
      fi
    }
    export -f curl
    echo "n" | tf-install-helpers
  '
  assert_success
  assert_clean_output_contains "Downloading"
  assert_clean_output_contains "curl"
  [[ -f "${HOME}/.local/bin/dsb-tf-proj-helpers.sh" ]]
}

@test "tf-install-helpers fails when no source and no download tools" {
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    mock_gh_not_installed
    mock_curl_not_installed
    export HOME="'"${HOME}"'"
    export SHELL="/bin/bash"
    cd "'"$(pwd)"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=0; _dsbTfLogWarnings=0; _dsbTfLogErrors=1; _dsbTfLogDebug=0
    _dsbTfScriptSourcePath=""
    echo "n" | tf-install-helpers
  '
  assert_failure
}

# ---------------------------------------------------------------------------
# tf-install-helpers: branch override via DSB_TF_HELPERS_BRANCH
# ---------------------------------------------------------------------------

@test "tf-install-helpers uses branch from DSB_TF_HELPERS_BRANCH env var" {
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    export HOME="'"${HOME}"'"
    export SHELL="/bin/bash"
    export DSB_TF_HELPERS_BRANCH="my-feature-branch"
    cd "'"$(pwd)"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=1; _dsbTfLogWarnings=0; _dsbTfLogErrors=0; _dsbTfLogDebug=0
    _dsbTfScriptSourcePath=""
    # Mock gh to verify the branch is passed correctly
    gh() {
      if [[ "$1" == "auth" ]]; then return 0; fi
      if [[ "$1" == "api" ]]; then
        # Check the URL contains the branch ref
        for arg in "$@"; do
          if [[ "${arg}" == *"ref=my-feature-branch"* ]]; then
            cat "'"${SUT}"'"
            return 0
          fi
        done
        echo "ERROR: branch not in URL" >&2
        return 1
      fi
      return 1
    }
    export -f gh
    echo "n" | tf-install-helpers
  '
  assert_success
  assert_clean_output_contains "my-feature-branch"
}

@test "tf-update-helpers uses branch from DSB_TF_HELPERS_BRANCH env var" {
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    export HOME="'"${HOME}"'"
    export SHELL="/bin/bash"
    cd "'"$(pwd)"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=1; _dsbTfLogWarnings=0; _dsbTfLogErrors=0; _dsbTfLogDebug=0
    echo "n" | tf-install-helpers
    # Now set the branch and update
    export DSB_TF_HELPERS_BRANCH="other-branch"
    # Override gh mock to verify branch in URL
    gh() {
      case "$1" in
        --version) echo "gh version 2.40.0"; return 0 ;;
        auth) return 0 ;;
        api)
          for arg in "$@"; do
            if [[ "${arg}" == *"ref=other-branch"* ]]; then
              cat "'"${SUT}"'"
              return 0
            fi
          done
          echo "ERROR: branch not in URL" >&2
          return 1
          ;;
      esac
      return 1
    }
    export -f gh
    tf-update-helpers
  '
  assert_success
  assert_clean_output_contains "other-branch"
}

# ---------------------------------------------------------------------------
# tf-uninstall-helpers: removes installation
# ---------------------------------------------------------------------------

@test "tf-uninstall-helpers removes script from ~/.local/bin" {
  # First install
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    export HOME="'"${HOME}"'"
    export SHELL="/bin/bash"
    cd "'"$(pwd)"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=0; _dsbTfLogWarnings=0; _dsbTfLogErrors=0; _dsbTfLogDebug=0
    echo "n" | tf-install-helpers
    echo "y" | tf-uninstall-helpers
  '
  assert_success
  [[ ! -f "${HOME}/.local/bin/dsb-tf-proj-helpers.sh" ]]
}

@test "tf-uninstall-helpers removes alias from .bashrc" {
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    export HOME="'"${HOME}"'"
    export SHELL="/bin/bash"
    cd "'"$(pwd)"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=0; _dsbTfLogWarnings=0; _dsbTfLogErrors=0; _dsbTfLogDebug=0
    echo "y" | tf-install-helpers
    echo "y" | tf-uninstall-helpers
  '
  assert_success
  ! grep -qF "# dsb-terraform-helpers" "${HOME}/.bashrc"
}

@test "tf-uninstall-helpers removes alias from .zshrc" {
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    export HOME="'"${HOME}"'"
    export SHELL="/bin/zsh"
    cd "'"$(pwd)"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=0; _dsbTfLogWarnings=0; _dsbTfLogErrors=0; _dsbTfLogDebug=0
    echo "y" | tf-install-helpers
    echo "y" | tf-uninstall-helpers
  '
  assert_success
  ! grep -qF "# dsb-terraform-helpers" "${HOME}/.zshrc"
}

@test "tf-uninstall-helpers prints success message" {
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    export HOME="'"${HOME}"'"
    export SHELL="/bin/bash"
    cd "'"$(pwd)"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=1; _dsbTfLogWarnings=0; _dsbTfLogErrors=0; _dsbTfLogDebug=0
    echo "n" | tf-install-helpers
    echo "y" | tf-uninstall-helpers
  '
  assert_success
  assert_clean_output_contains "uninstalled"
}

@test "tf-uninstall-helpers requires confirmation" {
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    export HOME="'"${HOME}"'"
    export SHELL="/bin/bash"
    cd "'"$(pwd)"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=0; _dsbTfLogWarnings=0; _dsbTfLogErrors=0; _dsbTfLogDebug=0
    echo "n" | tf-install-helpers
    echo "n" | tf-uninstall-helpers
  '
  assert_success
  # Script should still exist since user said no
  [[ -f "${HOME}/.local/bin/dsb-tf-proj-helpers.sh" ]]
}

@test "tf-uninstall-helpers handles not-installed gracefully" {
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    export HOME="'"${HOME}"'"
    export SHELL="/bin/bash"
    cd "'"$(pwd)"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=0; _dsbTfLogWarnings=1; _dsbTfLogErrors=0; _dsbTfLogDebug=0
    tf-uninstall-helpers
  '
  assert_success
  assert_clean_output_contains "not installed"
}

# ---------------------------------------------------------------------------
# tf-reload-helpers: re-source from local copy
# ---------------------------------------------------------------------------

@test "tf-reload-helpers fails when not installed locally" {
  _dsbTfLogErrors=1
  run tf-reload-helpers
  assert_failure
  assert_clean_output_contains "not installed"
}

@test "tf-reload-helpers succeeds when installed locally" {
  # Install first, then reload
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    export HOME="'"${HOME}"'"
    export SHELL="/bin/bash"
    cd "'"$(pwd)"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=0; _dsbTfLogWarnings=0; _dsbTfLogErrors=0; _dsbTfLogDebug=0
    echo "n" | tf-install-helpers
    tf-reload-helpers
  '
  assert_success
}

@test "tf-reload-helpers prints confirmation" {
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    export HOME="'"${HOME}"'"
    export SHELL="/bin/bash"
    cd "'"$(pwd)"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=1; _dsbTfLogWarnings=0; _dsbTfLogErrors=0; _dsbTfLogDebug=0
    echo "n" | tf-install-helpers
    tf-reload-helpers
  '
  assert_success
  assert_clean_output_contains "reloaded"
}

# ---------------------------------------------------------------------------
# tf-update-helpers: download latest and reload
# ---------------------------------------------------------------------------

@test "tf-update-helpers fails when not installed locally" {
  _dsbTfLogErrors=1
  run tf-update-helpers
  assert_failure
  assert_clean_output_contains "not installed"
}

@test "tf-update-helpers downloads and replaces script" {
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    export HOME="'"${HOME}"'"
    export SHELL="/bin/bash"
    cd "'"$(pwd)"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=1; _dsbTfLogWarnings=0; _dsbTfLogErrors=0; _dsbTfLogDebug=0
    echo "n" | tf-install-helpers
    # Mock gh api to return full script content for download
    gh() {
      if [[ "$1" == "auth" ]]; then return 0; fi
      if [[ "$1" == "--version" ]]; then echo "gh version 2.40.0"; return 0; fi
      if [[ "$1" == "api" ]]; then
        cat "'"${SUT}"'"
        return 0
      fi
      return 1
    }
    export -f gh
    tf-update-helpers
  '
  assert_success
  assert_clean_output_contains "updated"
}

# ---------------------------------------------------------------------------
# Commands are available in both repo types
# ---------------------------------------------------------------------------

@test "tf-install-helpers is available in module repos" {
  local module_dir="${BATS_TEST_TMPDIR}/module_project_${BATS_TEST_NUMBER}"
  cp -r "${FIXTURES_DIR}/project_module" "${module_dir}"
  run bash -c '
    source "'"${HELPERS_DIR}/mock_helper.bash"'"
    mock_standard_tools
    export HOME="'"${HOME}"'"
    export SHELL="/bin/bash"
    cd "'"${module_dir}"'"
    source "'"${SUT}"'"
    _dsbTfLogInfo=0; _dsbTfLogWarnings=0; _dsbTfLogErrors=0; _dsbTfLogDebug=0
    echo "n" | tf-install-helpers
  '
  assert_success
  [[ -f "${HOME}/.local/bin/dsb-tf-proj-helpers.sh" ]]
}
