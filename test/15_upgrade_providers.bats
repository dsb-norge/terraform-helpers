#!/usr/bin/env bats
# shellcheck disable=SC2164,SC1090,SC1091,SC2030,SC2031,SC2034,SC2154,SC2317
load 'helpers/test_helper'

setup() {
  export BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-${BATS_FILE_TMPDIR}}"
  source_script_in_project
  default_test_setup
  # Enable info logging to capture output messages
  export _dsbTfLogInfo=1
  export _dsbTfLogWarnings=1
  export _dsbTfLogErrors=1
}

teardown() {
  default_test_teardown
}

# ---------------------------------------------------------------------------
# tf-show-provider-upgrades shows providers for an env
# ---------------------------------------------------------------------------
@test "tf-show-provider-upgrades shows providers for dev env" {
  # First set the environment so the function knows which env to check
  tf-set-env dev >/dev/null 2>&1 || true

  local out
  out="$(tf-show-provider-upgrades dev 2>&1)"
  local clean
  clean="$(strip_ansi "${out}")"

  # Should show provider info
  [[ "${clean}" == *"Available Terraform provider upgrades"* ]]
  [[ "${clean}" == *"Environment: dev"* ]]
  [[ "${clean}" == *"hashicorp/azurerm"* ]]
}

@test "tf-show-provider-upgrades shows version info" {
  local out
  out="$(tf-show-provider-upgrades dev 2>&1)"
  local clean
  clean="$(strip_ansi "${out}")"

  # Should show latest version (from mock curl: 3.90.0)
  [[ "${clean}" == *"3.90.0"* ]]
  # Should show constraint info
  [[ "${clean}" == *"constraint"* ]] || [[ "${clean}" == *"Locked version"* ]]
}

# ---------------------------------------------------------------------------
# tf-show-all-provider-upgrades shows for all envs
# ---------------------------------------------------------------------------
@test "tf-show-all-provider-upgrades shows for all envs" {
  local out
  out="$(tf-show-all-provider-upgrades 2>&1)"
  local clean
  clean="$(strip_ansi "${out}")"

  # Should show both environments
  [[ "${clean}" == *"Environment: dev"* ]]
  [[ "${clean}" == *"Environment: prod"* ]]
  [[ "${clean}" == *"hashicorp/azurerm"* ]]
}

# ---------------------------------------------------------------------------
# Provider version cache works
# ---------------------------------------------------------------------------
@test "provider version cache works - second lookup reuses cache" {
  # Call for first env to populate cache (ignoreCache=1 on first call internally)
  _dsb_tf_get_latest_terraform_provider_version "hashicorp/azurerm" 1
  local first_result="${_dsbTfLatestProviderVersion}"

  # Track curl calls by replacing curl with a counter
  local curl_call_count=0
  curl() {
    ((curl_call_count++))
    # Return valid JSON for provider lookup
    echo '{"version":"3.90.0"}'
  }
  export -f curl

  # Second call should use cache (ignoreCache=0)
  _dsb_tf_get_latest_terraform_provider_version "hashicorp/azurerm" 0
  local second_result="${_dsbTfLatestProviderVersion}"

  # Both results should be the same
  [[ "${first_result}" == "${second_result}" ]]
  # curl should NOT have been called because the cache was used
  [[ ${curl_call_count} -eq 0 ]]
}

@test "provider version cache is bypassed when ignoreCache is 1" {
  # First call populates cache
  _dsb_tf_get_latest_terraform_provider_version "hashicorp/azurerm" 1
  local first_version="${_dsbTfLatestProviderVersion}"

  # Replace curl mock to return a different version
  curl() {
    local url="" output_file=""
    local i=1
    while [[ $i -le $# ]]; do
      local arg="${!i}"
      case "${arg}" in
        -o) ((i++)); output_file="${!i}" ;;
        http*) url="${arg}" ;;
      esac
      ((i++))
    done
    local response='{"version":"3.95.0"}'
    if [[ -n "${output_file:-}" ]]; then
      echo "${response}" > "${output_file}"
    else
      echo "${response}"
    fi
    return 0
  }
  export -f curl

  # Second call with ignoreCache=1 should NOT use cache and should pick up new version
  _dsb_tf_get_latest_terraform_provider_version "hashicorp/azurerm" 1
  local second_version="${_dsbTfLatestProviderVersion}"

  # The second version should reflect the new curl response, not the cached one
  [[ "${second_version}" == "3.95.0" ]]
}

# ---------------------------------------------------------------------------
# Handles missing tools gracefully
# ---------------------------------------------------------------------------
@test "tf-show-provider-upgrades handles missing curl" {
  mock_curl_not_installed

  local out
  out="$(tf-show-provider-upgrades dev 2>&1)" || true
  local clean
  clean="$(strip_ansi "${out}")"

  # Should report a tools check failure
  [[ "${clean}" == *"Tools check failed"* ]] || [[ "${clean}" == *"check-tools"* ]]
}

@test "tf-show-provider-upgrades handles missing jq" {
  mock_jq_not_installed

  local out
  out="$(tf-show-provider-upgrades dev 2>&1)" || true
  local clean
  clean="$(strip_ansi "${out}")"

  # Should report a tools check failure
  [[ "${clean}" == *"Tools check failed"* ]] || [[ "${clean}" == *"check-tools"* ]]
}

@test "tf-show-provider-upgrades handles missing terraform-config-inspect" {
  mock_terraform_config_inspect_not_installed

  local out
  out="$(tf-show-provider-upgrades dev 2>&1)" || true
  local clean
  clean="$(strip_ansi "${out}")"

  # Should report a tools check failure
  [[ "${clean}" == *"Tools check failed"* ]] || [[ "${clean}" == *"check-tools"* ]]
}

@test "tf-show-provider-upgrades handles missing hcledit" {
  mock_hcledit_not_installed

  local out
  out="$(tf-show-provider-upgrades dev 2>&1)" || true
  local clean
  clean="$(strip_ansi "${out}")"

  # Should report a tools check failure
  [[ "${clean}" == *"Tools check failed"* ]] || [[ "${clean}" == *"check-tools"* ]]
}

# ---------------------------------------------------------------------------
# tf-show-provider-upgrades without env when no env is selected
# ---------------------------------------------------------------------------
@test "tf-show-provider-upgrades without env when none selected shows error" {
  # Make sure no env is selected
  tf-clear-env >/dev/null 2>&1 || true

  local out
  out="$(tf-show-provider-upgrades 2>&1)"
  local clean
  clean="$(strip_ansi "${out}")"

  [[ "${clean}" == *"No environment specified"* ]]
}
