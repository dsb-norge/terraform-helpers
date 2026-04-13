#!/usr/bin/env bats
# shellcheck disable=SC2164,SC1090,SC1091,SC2030,SC2031,SC2034,SC2154,SC2317
#
# Tests for terraform arg passthrough and --log output capture
#
load 'helpers/test_helper'

# ============================================================
# Helper: terraform mock that echoes all args for verification
# ============================================================
mock_terraform_echo_args() {
  terraform() {
    echo "TERRAFORM_ARGS: $*"
    case "$1" in
      -version|--version) echo "Terraform v1.7.0 on linux_amd64"; return 0 ;;
      -chdir=*)
        local chdir_dir="${1#-chdir=}"
        shift
        case "$1" in
          init)
            echo ""
            echo "Initializing the backend..."
            echo "Initializing provider plugins..."
            echo ""
            echo "Terraform has been successfully initialized!"
            return 0
            ;;
          validate)
            echo "Success! The configuration is valid."
            return 0
            ;;
          plan)
            echo "No changes. Your infrastructure matches the configuration."
            return 0
            ;;
          apply)
            echo "Apply complete! Resources: 0 added, 0 changed, 0 destroyed."
            return 0
            ;;
          destroy)
            echo "Destroy complete! Resources: 0 destroyed."
            return 0
            ;;
          test)
            echo "1 passed, 0 failed."
            return 0
            ;;
          output)
            echo "mock_output_key = \"mock_output_value\""
            return 0
            ;;
          providers)
            shift
            case "$1" in
              lock) return 0 ;;
            esac
            ;;
        esac
        ;;
      test)
        echo "1 passed, 0 failed."
        return 0
        ;;
      fmt) return 0 ;;
    esac
    return 0
  }
  export -f terraform
}

# ============================================================
# Project repo setup
# ============================================================
setup_project() {
  default_test_setup
  export _PROJECT_DIR="${BATS_FILE_TMPDIR}/project_${BATS_TEST_NUMBER}"
  cp -r "${FIXTURES_DIR}/project_standard" "${_PROJECT_DIR}"
  mkdir -p "${_PROJECT_DIR}/envs/dev/.terraform/providers"
  mkdir -p "${_PROJECT_DIR}/envs/prod/.terraform/providers"
  cd "${_PROJECT_DIR}"
  mock_standard_tools
  mock_terraform_echo_args
  source "${SUT}"
}

# ============================================================
# Module repo setup
# ============================================================
setup_module() {
  export _MODULE_DIR="${BATS_FILE_TMPDIR}/module_${BATS_TEST_NUMBER}"
  cp -r "${FIXTURES_DIR}/project_module" "${_MODULE_DIR}"
  cd "${_MODULE_DIR}"
  mock_standard_tools
  mock_terraform_echo_args
  source "${SUT}"
  default_test_setup
}

# -------------------------------------------------------
# tf-plan: passthrough
# -------------------------------------------------------

@test "tf-plan passes through single-dash terraform flags" {
  setup_project
  run tf-plan dev -target=module.foo -out=plan.tfplan
  assert_success
  assert_output --partial "TERRAFORM_ARGS:"
  assert_output --partial "-target=module.foo"
  assert_output --partial "-out=plan.tfplan"
}

@test "tf-plan ignores double-dash flags (our flags)" {
  setup_project
  run tf-plan dev --some-future-flag
  assert_success
  # Should NOT contain the --some-future-flag in terraform args
  refute_output --partial "--some-future-flag"
}

@test "tf-plan without extra args still works" {
  setup_project
  run tf-plan dev
  assert_success
  assert_output --partial "Creating plan"
}

# -------------------------------------------------------
# tf-apply: passthrough
# -------------------------------------------------------

@test "tf-apply passes through single-dash terraform flags" {
  setup_project
  run tf-apply dev -auto-approve
  assert_success
  assert_output --partial "TERRAFORM_ARGS:"
  assert_output --partial "-auto-approve"
}

@test "tf-apply passes through positional args (plan file)" {
  setup_project
  run tf-apply dev plan.tfplan
  assert_success
  assert_output --partial "plan.tfplan"
}

@test "tf-apply without extra args still works" {
  setup_project
  run tf-apply dev
  assert_success
  assert_output --partial "Running apply"
}

# -------------------------------------------------------
# tf-init: passthrough
# -------------------------------------------------------

@test "tf-init passes through single-dash terraform flags (project)" {
  setup_project
  run tf-init dev -input=false
  assert_success
  assert_output --partial "-input=false"
}

@test "tf-init passes through single-dash terraform flags (module)" {
  setup_module
  run tf-init -input=false
  assert_success
  assert_output --partial "-input=false"
}

@test "tf-init without extra args still works (project)" {
  setup_project
  run tf-init dev
  assert_success
  assert_output --partial "Initializing"
}

@test "tf-init-offline passes through single-dash terraform flags (project)" {
  setup_project
  run tf-init-offline dev -input=false
  assert_success
  assert_output --partial "-input=false"
}

# -------------------------------------------------------
# tf-plan: --log
# -------------------------------------------------------

@test "tf-plan --log saves output to auto-named file" {
  setup_project
  run tf-plan dev --log
  assert_success
  assert_output --partial "Output saved to:"

  # Check that a log file was created
  local logFile
  logFile=$(ls "${_PROJECT_DIR}"/tf-plan-dev-*.log 2>/dev/null | head -1)
  [ -n "${logFile}" ]

  # Check content exists in the file
  local content
  content=$(cat "${logFile}")
  [[ "${content}" == *"Creating plan"* ]] || [[ "${content}" == *"No changes"* ]]

  # Check ANSI codes are stripped
  [[ ! "${content}" == *$'\e['* ]]
}

@test "tf-plan --log=custom.log saves to specified file" {
  setup_project
  local customLog="${_PROJECT_DIR}/custom-plan.log"
  run tf-plan dev --log="${customLog}"
  assert_success
  assert_output --partial "Output saved to:"
  [ -f "${customLog}" ]
}

@test "tf-plan with both terraform flags and --log works" {
  setup_project
  run tf-plan dev -target=module.foo --log
  assert_success
  assert_output --partial "-target=module.foo"
  assert_output --partial "Output saved to:"

  local logFile
  logFile=$(ls "${_PROJECT_DIR}"/tf-plan-dev-*.log 2>/dev/null | head -1)
  [ -n "${logFile}" ]
}

# -------------------------------------------------------
# tf-apply: --log
# -------------------------------------------------------

@test "tf-apply --log saves output to auto-named file" {
  setup_project
  run tf-apply dev --log
  assert_success
  assert_output --partial "Output saved to:"

  local logFile
  logFile=$(ls "${_PROJECT_DIR}"/tf-apply-dev-*.log 2>/dev/null | head -1)
  [ -n "${logFile}" ]
}

@test "tf-apply --log=custom.log saves to specified file" {
  setup_project
  local customLog="${_PROJECT_DIR}/custom-apply.log"
  run tf-apply dev --log="${customLog}"
  assert_success
  assert_output --partial "Output saved to:"
  [ -f "${customLog}" ]
}

# -------------------------------------------------------
# tf-test: --log
# -------------------------------------------------------

@test "tf-test --log saves output to auto-named file" {
  setup_module
  # Remove integration tests so no subscription prompt
  rm -f "${_MODULE_DIR}/tests/integration-"*.tftest.hcl
  run tf-test --log
  assert_success
  assert_output --partial "Output saved to:"

  local logFile
  logFile=$(ls "${_MODULE_DIR}"/tf-test-*.log 2>/dev/null | head -1)
  [ -n "${logFile}" ]
}

@test "tf-test with filter and --log works" {
  setup_module
  run tf-test "unit-tests.tftest.hcl" --log
  assert_success
  assert_output --partial "Output saved to:"
}

# -------------------------------------------------------
# tf-test-unit: --log
# -------------------------------------------------------

@test "tf-test-unit --log saves output to auto-named file" {
  setup_module
  _dsbTfLogInfo=1
  run tf-test-unit --log
  assert_success
  assert_output --partial "Output saved to:"

  local logFile
  logFile=$(ls "${_MODULE_DIR}"/tf-test-unit-*.log 2>/dev/null | head -1)
  [ -n "${logFile}" ]
}

# -------------------------------------------------------
# _dsb_tf_auto_log_filename
# -------------------------------------------------------

@test "_dsb_tf_auto_log_filename generates correct format with qualifier" {
  setup_project
  local result
  result=$(_dsb_tf_auto_log_filename "tf-plan" "dev")
  [[ "${result}" == tf-plan-dev-*.log ]]
}

@test "_dsb_tf_auto_log_filename generates correct format without qualifier" {
  setup_project
  local result
  result=$(_dsb_tf_auto_log_filename "tf-test" "")
  [[ "${result}" == tf-test-*.log ]]
  # Should NOT have double dash
  [[ "${result}" != *"--"* ]]
}

# -------------------------------------------------------
# _dsb_tf_run_with_log
# -------------------------------------------------------

@test "_dsb_tf_run_with_log without log file passes through normally" {
  setup_project
  my_test_func() {
    echo "hello from test func"
    return 0
  }
  run _dsb_tf_run_with_log "" my_test_func
  assert_success
  assert_output --partial "hello from test func"
  refute_output --partial "Output saved to:"
}

@test "_dsb_tf_run_with_log with log file captures output" {
  setup_project
  my_test_func() {
    echo "hello from test func"
    return 0
  }
  local logPath="${BATS_TEST_TMPDIR}/test-output.log"
  run _dsb_tf_run_with_log "${logPath}" my_test_func
  assert_success
  assert_output --partial "hello from test func"
  assert_output --partial "Output saved to:"
  [ -f "${logPath}" ]
}

@test "_dsb_tf_run_with_log preserves non-zero exit code" {
  setup_project
  my_failing_func() {
    echo "about to fail"
    return 1
  }
  local logPath="${BATS_TEST_TMPDIR}/fail-output.log"
  run _dsb_tf_run_with_log "${logPath}" my_failing_func
  assert_failure
  [ -f "${logPath}" ]
}

@test "_dsb_tf_run_with_log strips ANSI from log file" {
  setup_project
  my_ansi_func() {
    echo -e "\e[31mRED TEXT\e[0m"
    echo -e "\e[34mBLUE TEXT\e[0m"
    return 0
  }
  local logPath="${BATS_TEST_TMPDIR}/ansi-output.log"
  run _dsb_tf_run_with_log "${logPath}" my_ansi_func
  assert_success

  local content
  content=$(cat "${logPath}")
  # File should have the text but NOT the ANSI codes
  [[ "${content}" == *"RED TEXT"* ]]
  [[ "${content}" == *"BLUE TEXT"* ]]
  [[ ! "${content}" == *$'\e['* ]]
}

# -------------------------------------------------------
# Help system updates
# -------------------------------------------------------

@test "tf-help tf-plan mentions terraform flags" {
  setup_project
  _dsbTfLogInfo=1
  run tf-help tf-plan
  assert_success
  assert_clean_output_contains "terraform-flags"
  assert_clean_output_contains "--log"
}

@test "tf-help tf-apply mentions terraform flags" {
  setup_project
  _dsbTfLogInfo=1
  run tf-help tf-apply
  assert_success
  assert_clean_output_contains "terraform-flags"
  assert_clean_output_contains "--log"
}

@test "tf-help tf-init mentions terraform flags" {
  setup_project
  _dsbTfLogInfo=1
  run tf-help tf-init
  assert_success
  assert_clean_output_contains "terraform-flags"
}

@test "tf-help tf-test mentions --log" {
  setup_module
  _dsbTfLogInfo=1
  run tf-help tf-test
  assert_success
  assert_clean_output_contains "--log"
}

@test "tf-help tf-test-unit mentions --log" {
  setup_module
  _dsbTfLogInfo=1
  run tf-help tf-test-unit
  assert_success
  assert_clean_output_contains "--log"
}

@test "tf-help tf-test-integration mentions --log" {
  setup_module
  _dsbTfLogInfo=1
  run tf-help tf-test-integration
  assert_success
  assert_clean_output_contains "--log"
}

@test "tf-help tf-test-all-integrations mentions --log" {
  setup_module
  _dsbTfLogInfo=1
  run tf-help tf-test-all-integrations
  assert_success
  assert_clean_output_contains "--log"
}

@test "tf-help tf-test-all-examples mentions --log" {
  setup_module
  _dsbTfLogInfo=1
  run tf-help tf-test-all-examples
  assert_success
  assert_clean_output_contains "--log"
}

@test "tf-help tf-test-example mentions --log" {
  setup_module
  _dsbTfLogInfo=1
  run tf-help tf-test-example
  assert_success
  assert_clean_output_contains "--log"
}

# -------------------------------------------------------
# PIPESTATUS discipline: static analysis test
# -------------------------------------------------------

@test "PIPESTATUS discipline: no command between pipeline and PIPESTATUS read" {
  # Scan the script for patterns where a pipeline ending with tee or fixup_paths
  # is followed by something other than PIPESTATUS read, blank line, comment, or
  # a local declaration immediately followed by PIPESTATUS.
  #
  # Excluded: lines inside strings (echo/printf/_dsb_i that mention pipelines as text)
  # Excluded: pipelines inside while/if conditions (e.g., | while IFS=)
  local violations=0
  local prev_was_pipe=0
  local line_num=0
  local pipe_line_num=0
  while IFS= read -r line; do
    line_num=$((line_num + 1))

    # Skip lines that are inside echo/printf/_dsb_i strings (not real pipelines)
    if [[ "${line}" == *'_dsb_i "'*'|'* ]] || [[ "${line}" == *'echo "'*'|'* ]] || [[ "${line}" == *'printf'*'|'* ]]; then
      continue
    fi

    # Skip pipeline lines that feed into a while loop (different pattern)
    if [[ "${line}" == *'| while'* ]]; then
      continue
    fi

    # Detect pipeline lines ending with tee or fixup_paths
    if [[ "${line}" == *'| tee'* ]] || [[ "${line}" == *'| _dsb_tf_fixup_paths_from_stdin'* ]]; then
      prev_was_pipe=1
      pipe_line_num="${line_num}"
      continue
    fi

    if [ "${prev_was_pipe}" -eq 1 ]; then
      if [[ "${line}" == *'PIPESTATUS'* ]]; then
        prev_was_pipe=0  # good: PIPESTATUS read immediately after pipe
      elif [[ "${line}" =~ ^[[:space:]]*$ ]] || [[ "${line}" =~ ^[[:space:]]*# ]]; then
        : # blank lines and comments are OK, keep looking
      elif [[ "${line}" =~ ^[[:space:]]*local[[:space:]] ]]; then
        # local declarations followed by PIPESTATUS on next line are OK
        # (e.g., local returnCode=0 \n if [ "${PIPESTATUS[0]}" ... ])
        # Keep prev_was_pipe=1 to check the NEXT line
        :
      elif [[ "${line}" =~ ^[[:space:]]*if[[:space:]] ]] && [[ "${line}" == *'PIPESTATUS'* ]]; then
        prev_was_pipe=0  # good: if statement using PIPESTATUS
      else
        echo "VIOLATION at line ${line_num} (pipeline at ${pipe_line_num}): command between pipeline and PIPESTATUS: ${line}" >&2
        violations=$((violations + 1))
        prev_was_pipe=0
      fi
    fi
  done < "${SUT}"
  [ "${violations}" -eq 0 ]
}
