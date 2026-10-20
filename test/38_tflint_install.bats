#!/usr/bin/env bats
# shellcheck disable=SC2164,SC1090,SC1091,SC2030,SC2031,SC2034,SC2154,SC2317
#
# Which tflint version the lint commands use, and how they install it:
# the tflint-version of the workflow that calls the shared workflow, installed
# into a per-user cache keyed by version and verified against the release's
# checksums.txt.
load 'helpers/test_helper'

setup() {
  default_test_setup
  project_dir="${BATS_TEST_TMPDIR}/project"
  cp -r "${BATS_TEST_DIRNAME}/fixtures/project_standard" "${project_dir}"
  cd "${project_dir}"
  mock_standard_tools
  source "${SUT}"
  cache_root="${XDG_CACHE_HOME}/dsb-tf-proj-helpers/tflint"
}

teardown() {
  default_test_teardown
}

# write a workflow that calls a shared workflow of github-actions-terraform
#   $1: file name, $2: tflint-version, $3: shared workflow file (default: the project one)
write_caller_workflow() {
  local fileName="${1}"
  local tflintVersion="${2}"
  local sharedWorkflow="${3:-terraform-ci-cd-default.yml}"
  mkdir -p .github/workflows
  cat >".github/workflows/${fileName}" <<EOF
name: CI/CD
on:
  pull_request:
jobs:
  terraform:
    uses: dsb-norge/github-actions-terraform/.github/workflows/${sharedWorkflow}@v1
    secrets: inherit
    with:
      terraform-version: "1.14.0"
      tflint-version: "${tflintVersion}" # full version string ex. 'v0.48.0' or 'latest'
EOF
}

# -------------------------------------------------------
# version (D14)
# -------------------------------------------------------

@test "tflint version is the latest release when no workflow calls the shared workflow" {
  # the fixture's ci.yml sets tflint-version, but does not call the shared workflow
  _dsb_tf_tflint_resolve_version
  [[ "${_dsbTfTflintVersion}" == "v0.55.0" ]]
}

@test "tflint version is the tflint-version of the workflow that calls the shared workflow" {
  write_caller_workflow "terraform-ci-cd.yml" "v0.61.0"
  _dsb_tf_tflint_resolve_version
  [[ "${_dsbTfTflintVersion}" == "v0.61.0" ]]
  [[ "${_dsbTfTflintVersionSource}" == *".github/workflows/terraform-ci-cd.yml"* ]]
}

@test "tflint version is the highest when several workflows call the shared workflow" {
  write_caller_workflow "a.yml" "v0.61.0"
  write_caller_workflow "b.yaml" "v0.63.1"
  write_caller_workflow "c.yml" "v0.9.9"
  _dsb_tf_tflint_resolve_version
  [[ "${_dsbTfTflintVersion}" == "v0.63.1" ]]
}

@test "tflint version 'latest' in the workflow is the latest release" {
  write_caller_workflow "terraform-ci-cd.yml" "latest"
  _dsb_tf_tflint_resolve_version
  [[ "${_dsbTfTflintVersion}" == "v0.55.0" ]]
}

@test "tflint version in the workflow without the v prefix gets one" {
  write_caller_workflow "terraform-ci-cd.yml" "0.61.0"
  _dsb_tf_tflint_resolve_version
  [[ "${_dsbTfTflintVersion}" == "v0.61.0" ]]
}

@test "tflint version given with --use-version overrides the workflow" {
  write_caller_workflow "terraform-ci-cd.yml" "v0.61.0"
  _dsb_tf_tflint_resolve_version "v0.50.0"
  [[ "${_dsbTfTflintVersion}" == "v0.50.0" ]]
}

@test "tflint version given with --use-version can be 'latest'" {
  write_caller_workflow "terraform-ci-cd.yml" "v0.61.0"
  _dsb_tf_tflint_resolve_version "latest"
  [[ "${_dsbTfTflintVersion}" == "v0.55.0" ]]
}

@test "tflint version given with --use-version must be a version" {
  run _dsb_tf_tflint_resolve_version "not-a-version"
  assert_failure
  assert_output --partial "not-a-version"
}

@test "tflint version in a project repo ignores the module CI workflow" {
  write_caller_workflow "test.yaml" "v0.64.0" "terraform-module-ci.yaml"
  _dsb_tf_tflint_resolve_version
  [[ "${_dsbTfTflintVersion}" == "v0.55.0" ]]
}

@test "tflint version in a module repo is the tflint-version of the module CI workflow" {
  cd "$(create_module_project)"
  source "${SUT}"
  write_caller_workflow "test.yaml" "v0.64.0" "terraform-module-ci.yaml"
  _dsb_tf_tflint_resolve_version
  [[ "${_dsbTfTflintVersion}" == "v0.64.0" ]]
}

@test "tflint latest release is looked up with curl when gh is not authenticated" {
  mock_gh_not_authenticated
  _dsb_tf_tflint_resolve_version
  [[ "${_dsbTfTflintVersion}" == "v0.55.0" ]]
}

@test "tflint latest release falls back to the newest cached version when it cannot be looked up" {
  mock_gh_not_authenticated
  curl() { return 22; }
  export -f curl
  install_fake_tflint "v0.50.0"
  install_fake_tflint "v0.53.0"
  _dsb_tf_tflint_resolve_version
  [[ "${_dsbTfTflintVersion}" == "v0.53.0" ]]
}

@test "tflint latest release that cannot be looked up, with nothing cached, fails" {
  mock_gh_not_authenticated
  curl() { return 22; }
  export -f curl
  run _dsb_tf_tflint_resolve_version
  assert_failure
}

# -------------------------------------------------------
# install (D15)
# -------------------------------------------------------

@test "tflint is installed into the per-user cache keyed by version, downloaded with gh" {
  mock_tflint_release
  run _dsb_tf_tflint_install "v0.61.0"
  assert_success
  [[ -x "${cache_root}/v0.61.0/tflint" ]]
  run cat "${MOCK_GH_RELEASE_CALLS_FILE}"
  assert_output --partial "download v0.61.0 --repo terraform-linters/tflint"
  assert_output --partial "tflint_$(fake_tflint_platform).zip"
  assert_output --partial "checksums.txt"
}

@test "tflint install sets the binary to run" {
  mock_tflint_release
  _dsb_tf_tflint_install "v0.61.0"
  [[ "${_dsbTfTflintBin}" == "${cache_root}/v0.61.0/tflint" ]]
}

@test "tflint is downloaded with curl when gh is not authenticated" {
  mock_tflint_release
  mock_gh_not_authenticated
  run _dsb_tf_tflint_install "v0.61.0"
  assert_success
  [[ -x "${cache_root}/v0.61.0/tflint" ]]
  run cat "${MOCK_CURL_CALLS_FILE}"
  assert_line "https://github.com/terraform-linters/tflint/releases/download/v0.61.0/tflint_$(fake_tflint_platform).zip"
  assert_line "https://github.com/terraform-linters/tflint/releases/download/v0.61.0/checksums.txt"
}

@test "tflint download falls back to curl when gh fails" {
  mock_tflint_release
  gh() {
    case "$1" in
      auth) return 0 ;;
      release) return 1 ;;
    esac
    return 0
  }
  export -f gh
  run _dsb_tf_tflint_install "v0.61.0"
  assert_success
  [[ -x "${cache_root}/v0.61.0/tflint" ]]
}

@test "tflint install refuses an archive whose checksum does not match checksums.txt" {
  mock_tflint_release
  echo "tampered" >>"${MOCK_TFLINT_RELEASE_DIR}/tflint_$(fake_tflint_platform).zip"
  run _dsb_tf_tflint_install "v0.61.0"
  assert_failure
  assert_output --partial "checksum"
  [[ ! -e "${cache_root}/v0.61.0/tflint" ]]
}

@test "tflint install refuses an archive that checksums.txt does not list" {
  mock_tflint_release
  command grep -v "tflint_$(fake_tflint_platform).zip" "${MOCK_TFLINT_RELEASE_DIR}/checksums.txt" >"${BATS_TEST_TMPDIR}/checksums.txt"
  cp "${BATS_TEST_TMPDIR}/checksums.txt" "${MOCK_TFLINT_RELEASE_DIR}/checksums.txt"
  run _dsb_tf_tflint_install "v0.61.0"
  assert_failure
  assert_output --partial "checksum"
  [[ ! -e "${cache_root}/v0.61.0/tflint" ]]
}

@test "tflint install fails when the release cannot be downloaded" {
  run _dsb_tf_tflint_install "v0.61.0"
  assert_failure
  [[ ! -e "${cache_root}/v0.61.0/tflint" ]]
}

@test "tflint already in the cache is used without downloading" {
  mock_tflint_release
  install_fake_tflint "v0.61.0"
  run _dsb_tf_tflint_install "v0.61.0"
  assert_success
  run cat "${MOCK_GH_RELEASE_CALLS_FILE}" "${MOCK_CURL_CALLS_FILE}"
  assert_output ""
}

@test "tflint cache defaults to ~/.cache when XDG_CACHE_HOME is not set" {
  mock_tflint_release
  unset XDG_CACHE_HOME
  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "${HOME}"
  run _dsb_tf_tflint_install "v0.61.0"
  assert_success
  [[ -x "${HOME}/.cache/dsb-tf-proj-helpers/tflint/v0.61.0/tflint" ]]
}

@test "tflint install edits no .gitignore and writes nothing into the repository" {
  mock_tflint_release
  printf '**/.terraform/*\n' >"${project_dir}/.gitignore"
  local before
  before="$(cd "${project_dir}" && find . -type f | sort)"
  run _dsb_tf_tflint_install "v0.61.0"
  assert_success
  run cat "${project_dir}/.gitignore"
  assert_output '**/.terraform/*'
  [[ "$(cd "${project_dir}" && find . -type f | sort)" == "${before}" ]]
}

@test "tflint install needs unzip" {
  mock_tflint_release
  mock_unzip_not_installed
  run _dsb_tf_tflint_install "v0.61.0"
  assert_failure
  assert_output --partial "unzip"
}

@test "tflint install picks the linux arm64 archive on linux aarch64" {
  mock_tflint_release
  uname() { case "$1" in -s) echo "Linux" ;; -m) echo "aarch64" ;; *) command uname "$@" ;; esac; }
  export -f uname
  run _dsb_tf_tflint_install "v0.61.0"
  run cat "${MOCK_GH_RELEASE_CALLS_FILE}"
  assert_output --partial "tflint_linux_arm64.zip"
}

@test "tflint install picks the darwin arm64 archive on macOS arm64" {
  mock_tflint_release
  uname() { case "$1" in -s) echo "Darwin" ;; -m) echo "arm64" ;; *) command uname "$@" ;; esac; }
  export -f uname
  run _dsb_tf_tflint_install "v0.61.0"
  run cat "${MOCK_GH_RELEASE_CALLS_FILE}"
  assert_output --partial "tflint_darwin_arm64.zip"
}

@test "tflint install picks the darwin amd64 archive on macOS x86_64" {
  mock_tflint_release
  uname() { case "$1" in -s) echo "Darwin" ;; -m) echo "x86_64" ;; *) command uname "$@" ;; esac; }
  export -f uname
  run _dsb_tf_tflint_install "v0.61.0"
  run cat "${MOCK_GH_RELEASE_CALLS_FILE}"
  assert_output --partial "tflint_darwin_amd64.zip"
}

@test "tflint install fails on an unsupported platform" {
  mock_tflint_release
  mock_uname_unsupported
  run _dsb_tf_tflint_install "v0.61.0"
  assert_failure
  assert_output --partial "unsupported"
}

@test "_dsb_tf_tflint_prepare resolves the version, installs it and says which it uses" {
  mock_tflint_release
  write_caller_workflow "terraform-ci-cd.yml" "v0.61.0"
  run _dsb_tf_tflint_prepare
  assert_success
  assert_output --partial "v0.61.0"
  [[ -x "${cache_root}/v0.61.0/tflint" ]]
}
