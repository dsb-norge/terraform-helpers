#!/usr/bin/env bats
# shellcheck disable=SC2164,SC1090,SC1091,SC2030,SC2031,SC2034,SC2154,SC2317
load 'helpers/test_helper'

setup_file() {
  export _VER_TEST_PROJECT="${BATS_FILE_TMPDIR}/project"
  cp -r "${FIXTURES_DIR}/project_standard" "${_VER_TEST_PROJECT}"
}

setup() {
  cd "${_VER_TEST_PROJECT}"
  mock_standard_tools
  source "${SUT}"
  default_test_setup
}

teardown() {
  default_test_teardown
}

# -- _dsb_tf_semver_is_semver --

@test "semver_is_semver accepts 1.2.3" {
  run _dsb_tf_semver_is_semver "1.2.3"
  assert_success
}

@test "semver_is_semver accepts 0.0.0" {
  run _dsb_tf_semver_is_semver "0.0.0"
  assert_success
}

@test "semver_is_semver accepts two-part 1.2" {
  run _dsb_tf_semver_is_semver "1.2"
  assert_success
}

@test "semver_is_semver accepts single-part 5" {
  run _dsb_tf_semver_is_semver "5"
  assert_success
}

@test "semver_is_semver rejects empty string" {
  run _dsb_tf_semver_is_semver ""
  assert_failure
}

@test "semver_is_semver rejects alpha" {
  run _dsb_tf_semver_is_semver "abc"
  assert_failure
}

@test "semver_is_semver rejects v prefix by default" {
  run _dsb_tf_semver_is_semver "v1.2.3"
  assert_failure
}

@test "semver_is_semver rejects x wildcard by default" {
  run _dsb_tf_semver_is_semver "1.2.x"
  assert_failure
}

# -- wildcards and v prefix --

@test "semver with x wildcard allowed accepts 1.2.x" {
  run _dsb_tf_semver_is_semver "1.2.x" 1 0
  assert_success
}

@test "semver with x wildcard allowed accepts 1.x" {
  run _dsb_tf_semver_is_semver "1.x" 1 0
  assert_success
}

@test "semver with v prefix allowed accepts v1.2.3" {
  run _dsb_tf_semver_is_semver "v1.2.3" 0 1
  assert_success
}

@test "semver with v prefix allowed accepts v1" {
  run _dsb_tf_semver_is_semver "v1" 0 1
  assert_success
}

@test "semver with both flags accepts v1.2.x" {
  run _dsb_tf_semver_is_semver "v1.2.x" 1 1
  assert_success
}

@test "semver_is_semver_allow_x_as_wildcard_in_last accepts 1.2.x" {
  run _dsb_tf_semver_is_semver_allow_x_as_wildcard_in_last "1.2.x"
  assert_success
}

@test "semver_is_semver_allow_v_as_first_character accepts v1.2.3" {
  run _dsb_tf_semver_is_semver_allow_v_as_first_character "v1.2.3"
  assert_success
}

# -- _dsb_tf_semver_get_major_version --

@test "get_major_version from 1.2.3 returns 1" {
  run _dsb_tf_semver_get_major_version "1.2.3"
  assert_success
  assert_output "1"
}

@test "get_major_version from 10.0.5 returns 10" {
  run _dsb_tf_semver_get_major_version "10.0.5"
  assert_success
  assert_output "10"
}

@test "get_major_version from 5 returns 5" {
  run _dsb_tf_semver_get_major_version "5"
  assert_success
  assert_output "5"
}

@test "get_major_version from 3.7 returns 3" {
  run _dsb_tf_semver_get_major_version "3.7"
  assert_success
  assert_output "3"
}

# -- _dsb_tf_semver_get_minor_version --

@test "get_minor_version from 1.2.3 returns 2" {
  run _dsb_tf_semver_get_minor_version "1.2.3"
  assert_success
  assert_output "2"
}

@test "get_minor_version from 1.2 returns 2" {
  run _dsb_tf_semver_get_minor_version "1.2"
  assert_success
  assert_output "2"
}

@test "get_minor_version from 5 returns empty string" {
  run _dsb_tf_semver_get_minor_version "5"
  assert_success
  assert_output ""
}

# -- _dsb_tf_semver_get_patch_version --

@test "get_patch_version from 1.2.3 returns 3" {
  run _dsb_tf_semver_get_patch_version "1.2.3"
  assert_success
  assert_output "3"
}

@test "get_patch_version from 1.2 returns empty string" {
  run _dsb_tf_semver_get_patch_version "1.2"
  assert_success
  assert_output ""
}

@test "get_patch_version from 5 returns empty string" {
  run _dsb_tf_semver_get_patch_version "5"
  assert_success
  assert_output ""
}

# -- _dsb_tf_resolve_bump_version --

@test "resolve_bump_version: same minor keeps current patch (1.2.3 vs 1.2.5)" {
  # When minor is equal, the function keeps current patch (constraint-based)
  run _dsb_tf_resolve_bump_version "1.2.3" "1.2.5"
  assert_success
  assert_output "1.2.3"
}

@test "resolve_bump_version: current 1.2.3 latest 1.3.0 => 1.3.0" {
  run _dsb_tf_resolve_bump_version "1.2.3" "1.3.0"
  assert_success
  assert_output "1.3.0"
}

@test "resolve_bump_version: current 1.2.3 latest 2.0.0 => 2.0.0" {
  run _dsb_tf_resolve_bump_version "1.2.3" "2.0.0"
  assert_success
  assert_output "2.0.0"
}

@test "resolve_bump_version: current equals latest returns same" {
  run _dsb_tf_resolve_bump_version "1.2.3" "1.2.3"
  assert_success
  assert_output "1.2.3"
}

@test "resolve_bump_version: current ahead of latest keeps current" {
  run _dsb_tf_resolve_bump_version "3.0.0" "2.5.1"
  assert_success
  assert_output "3.0.0"
}

@test "resolve_bump_version: wildcard current 1.2.x latest 1.3.0 => 1.3.x" {
  run _dsb_tf_resolve_bump_version "1.2.x" "1.3.0"
  assert_success
  assert_output "1.3.x"
}

@test "resolve_bump_version: wildcard minor current 1.x latest 2.0.0 => 2.0" {
  # 'x' is non-empty so it enters the latestMinor branch on major bump
  run _dsb_tf_resolve_bump_version "1.x" "2.0.0"
  assert_success
  assert_output "2.0"
}

@test "resolve_bump_version: partial current 1.2 latest 1.3.0 => 1.3" {
  run _dsb_tf_resolve_bump_version "1.2" "1.3.0"
  assert_success
  assert_output "1.3"
}

@test "resolve_bump_version: single-number current 1 latest 2.0.0 => 2" {
  run _dsb_tf_resolve_bump_version "1" "2.0.0"
  assert_success
  assert_output "2"
}
