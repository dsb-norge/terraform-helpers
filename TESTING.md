# Testing `dsb-tf-proj-helpers.sh`

## Quick Start

```bash
# Install test dependencies
npm install

# Run the full suite
npx bats test/*.bats

# Run a single test file
npx bats test/04_version_parsing.bats

# Run tests matching a name pattern
npx bats --filter "tf-set-env" test/*.bats

# Run with parallelism
npx bats --jobs 4 test/*.bats

# Run with per-test timing
npx bats --timing test/*.bats
```

**Requirements**: bash 4.3+, npm (for bats installation), and `jq` (used by mock helpers for JSON parsing -- this is the only real external tool the tests use).

No other external tools (az, gh, terraform, etc.) are needed. Everything is mocked.

---

## Overview

The test suite uses [bats-core](https://github.com/bats-core/bats-core) (Bash Automated Testing System) with three companion libraries:

- **bats-support** -- base helpers
- **bats-assert** -- `assert_success`, `assert_failure`, `assert_output`, `assert_line`
- **bats-file** -- file/directory existence assertions

All dependencies are managed via npm and listed in `package.json`.

**Current state**: 232 tests across 20 files, covering 95% of functions (172/180). The untested 5% are debug utilities requiring external binaries, a signal handler requiring process-level testing, and thin exposed-function wrappers whose internals are already tested.

---

## Project Layout

```
test/
  helpers/
    test_helper.bash          # Loaded by every test file. Sets up library paths and SUT path.
    mock_helper.bash          # Mock definitions for all external tools.
    fixture_helper.bash       # Helpers to create temp project directories from fixtures.
    assertion_helper.bash     # Custom assertions (ANSI stripping, global var checks).
  fixtures/
    project_standard/         # Full valid terraform project (main, envs, modules, workflows).
    project_no_envs/          # Project missing the envs/ directory.
    project_no_main/          # Project missing the main/ directory.
    project_empty/            # Empty directory.
  01_source_init.bats         # Script sourcing, function definitions, arch detection.
  02_logging.bats             # _dsb_e, _dsb_i, _dsb_w, _dsb_d, mute flags.
  03_error_handling.bats      # configure/restore lifecycle, ERR trap, error handler.
  04_version_parsing.bats     # Semver validation, parsing, bump resolution.
  05_tool_checks.bats         # All _dsb_tf_check_* functions, tf-check-tools, tf-check-prereqs.
  06_directory_enumeration.bats  # Directory discovery, env/module/file finding.
  07_environment_management.bats # tf-list-envs, tf-set-env, tf-select-env, tf-clear-env, tf-check-env.
  08_azure_cli.bats           # az-whoami, az-logout, az-set-sub, enumerate_account, is_logged_in.
  09_terraform_operations.bats   # tf-init, tf-validate, tf-plan, tf-apply, tf-destroy, tf-fmt.
  10_linting.bats             # tf-lint, tflint wrapper download and execution.
  11_clean.bats               # tf-clean, tf-clean-tflint, tf-clean-all.
  12_upgrade_github.bats      # tf-bump-cicd (GitHub workflow version bumping).
  13_upgrade_modules.bats     # tf-bump-modules (registry module version bumping).
  14_upgrade_tflint_plugins.bats # tf-bump-tflint-plugins.
  15_upgrade_providers.bats   # tf-show-provider-upgrades, tf-show-all-provider-upgrades.
  16_upgrade_combined.bats    # tf-bump-env, tf-bump, tf-bump-all, offline variants.
  17_help.bats                # tf-help system (groups, commands, topics).
  18_tab_completion.bats      # Tab completion registration and behavior.
  19_exposed_functions.bats   # Shell state preservation across all exposed functions.
  20_debug.bats               # Debug logging enable/disable.
```

Files are numbered so output reads in a logical order, but **tests must not depend on execution order**. Each file is fully self-contained.

---

## How Tests Work

### The lifecycle

Every test file follows this pattern:

```bash
#!/usr/bin/env bats
load 'helpers/test_helper'       # loads bats libraries + our helpers

setup() {
  default_test_setup              # mutes logging
  cd "$(create_standard_project)" # copies fixture to temp dir, cd into it
  mock_standard_tools             # installs function-override mocks for all external tools
  source "${SUT}"                 # sources dsb-tf-proj-helpers.sh (runs init code)
}

teardown() {
  default_test_teardown           # restores shell, removes mocks, cd back to project root
}
```

### The script under test (SUT)

`${SUT}` points to `dsb-tf-proj-helpers.sh` at the project root. When sourced, the script runs its initialization code: clears old state, detects architecture, enumerates directories, registers tab completions, and prints its startup message.

This is intentional -- we test real sourcing behavior.

### Test isolation

Each `@test` block runs in a **forked subprocess** of the file-level process. This means:

- Global variables set in `setup()` are inherited by each test.
- Global variable changes within one test **do not leak** to other tests.
- This is the main reason we chose bats-core -- it solves the global-state isolation problem automatically.

---

## The Two Patterns: `run` vs. Direct Call

This is the single most important thing to understand when writing tests for this script.

### Use `run` for testing output and exit codes

```bash
@test "tf-help shows overview" {
  run tf-help
  assert_success
  assert_output --partial "DSB Terraform Project Helpers"
}
```

`run` executes the function in a **subshell**. It captures `$output` and `$status`. Use this when you care about what a function prints or what exit code it returns.

### Call directly (without `run`) for testing global variable mutations

```bash
@test "tf-set-env dev sets _dsbTfSelectedEnv" {
  call_exposed tf-set-env dev
  [[ "${_dsbTfSelectedEnv}" == "dev" ]]
}
```

`run` executes in a subshell, so global variable changes are **lost**. When testing that a function modifies `_dsbTfSelectedEnv`, `_dsbTfReturnCode`, or any other global, you must call the function directly.

### The `call_exposed` helper

Exposed functions call `_dsb_tf_configure_shell`, which runs `shopt -o history`. In non-interactive shells (like bats), `shopt -o history` returns exit code 1. Since bats runs with `set -e`, this would abort the test.

The `call_exposed` helper disables `set -e` around the call:

```bash
call_exposed() {
  set +eET
  "$@"
  _CALL_RC=$?
  set -eET
  return 0
}
```

After `call_exposed`, check `$_CALL_RC` for the exit code and inspect globals directly.

### When you need both output AND globals

Use `bash -c` with mocks defined inline:

```bash
@test "tf-select-env without arg prompts and accepts input" {
  run bash -c '
    cd "'"${project_dir}"'"
    # define mocks inline (export -f does not cross bash -c boundary)
    az() { ... }
    gh() { ... }
    source "'"${SUT}"'" >/dev/null 2>&1
    tf-select-env <<< "1"
    echo "SELECTED=${_dsbTfSelectedEnv}"
  '
  assert_success
  [[ "${output}" == *"SELECTED=dev"* ]]
}
```

This is the heaviest pattern -- avoid it unless you need both captured output and global inspection.

---

## Mocking

### How it works

The script calls external tools (`az`, `terraform`, `gh`, etc.) by name, not by absolute path. Bash resolves functions before PATH lookups. So a mock function named `az` shadows the real `az` command.

Since the script is sourced into the same shell as the tests, mock functions are immediately visible to all script code.

### Available mocks

Defined in `test/helpers/mock_helper.bash`:

| Function | What it does |
|---|---|
| `mock_az` | Azure CLI is available and logged in |
| `mock_az_not_installed` | Azure CLI not found |
| `mock_az_not_logged_in` | Azure CLI installed but not authenticated |
| `mock_gh` | GitHub CLI is available and authenticated |
| `mock_gh_not_installed` | GitHub CLI not found |
| `mock_gh_not_authenticated` | GitHub CLI installed but not authenticated |
| `mock_terraform` | Terraform is available, init/validate/plan/apply succeed |
| `mock_terraform_not_installed` | Terraform not found |
| `mock_terraform_init_fails` | Terraform is available but init returns error |
| `mock_jq` | Uses real jq if available, otherwise provides a minimal mock |
| `mock_jq_not_installed` | jq not found |
| `mock_yq` / `mock_yq_not_installed` | yq mock |
| `mock_hcledit` / `mock_hcledit_not_installed` | hcledit mock |
| `mock_terraform_config_inspect` / `..._not_installed` | terraform-config-inspect mock |
| `mock_curl` / `mock_curl_not_installed` | curl mock (routes by URL) |
| `mock_go` / `mock_go_not_installed` | go mock |
| `mock_realpath` | realpath mock (uses python3 for relative path math) |
| `mock_standard_tools` | Applies all "available and working" mocks at once |
| `unmock_all` | Removes all mock function overrides |

### Adding a new mock

If the script starts calling a new external tool:

1. Add `mock_<tool>` and `mock_<tool>_not_installed` functions to `mock_helper.bash`.
2. Add the tool to the `mock_standard_tools` function.
3. Add it to the `unmock_all` function's command list.

### What we don't mock

`grep`, `sed`, `awk`, `find`, `basename`, `dirname`, `cat`, `mkdir`, `cp`, `rm`, `chmod` -- standard POSIX utilities. They are always present and have deterministic behavior. Mocking them makes tests fragile without meaningful benefit.

---

## Fixtures

Test fixtures live in `test/fixtures/`. Each is a minimal terraform project directory structure.

| Fixture | Purpose |
|---|---|
| `project_standard/` | Valid project with main, envs (dev + prod), modules, .tflint.hcl, .github/workflows |
| `project_no_envs/` | Missing envs/ directory |
| `project_no_main/` | Missing main/ directory |
| `project_empty/` | Empty directory |

Fixtures are **copied** to `$BATS_TEST_TMPDIR` before each test via the `create_standard_project` helper (or manually with `cp -r`). Tests modify the copy freely without affecting the original fixtures.

### Fixture files

The standard project fixture includes:

- `envs/dev/.az-subscription` containing `mock-sub-dev`
- `envs/dev/.terraform.lock.hcl` with a provider entry
- `.github/workflows/ci.yml` with `terraform-version` and `tflint-version` keys
- `.tflint.hcl` with a plugin block

These are minimal but structurally valid. If you need more complex fixture data, add files to the fixture directories.

---

## Custom Assertions

Defined in `test/helpers/assertion_helper.bash`:

```bash
# Strip ANSI color codes from output before comparing
assert_clean_output_contains "ERROR"

# Assert a global variable has a specific value
assert_global "_dsbTfSelectedEnv" "dev"

# Assert a global variable is set and non-empty
assert_global_set "_dsbTfRootDir"

# Assert a global variable is empty or unset
assert_global_empty "_dsbTfSelectedEnv"

# Assert output does NOT contain text (ANSI-stripped)
assert_clean_output_not_contains "FATAL"

# Assert a function exists / does not exist
assert_function_exists "tf-init"
assert_function_not_exists "tf-nonexistent"
```

The ANSI stripping is important because the script uses colored output (`\e[31m` for errors, `\e[34m` for info, etc.). Always use `assert_clean_output_contains` instead of raw string matching on `$output` when checking log messages.

---

## Writing a New Test

### 1. Pick the right file

Each file covers one functional area. If you're testing a new function, add it to the relevant existing file. Only create a new file if it's a genuinely new functional area.

### 2. Choose `run` vs. direct call

- Testing **output or exit codes** -> use `run`
- Testing **global variable changes** -> call directly (with `call_exposed` for exposed functions)

### 3. Set up the right mocks

Most tests just need `mock_standard_tools` (already called in `setup()`). Override specific mocks within a test to simulate failures:

```bash
@test "tf-init fails when terraform is not installed" {
  mock_terraform_not_installed
  run tf-init "dev"
  assert_failure
}
```

### 4. Example: testing a new exposed function

```bash
@test "tf-new-command does something useful" {
  # Arrange: mocks are already set up via setup()
  # Override specific mock if needed:
  # mock_terraform_init_fails

  # Act + Assert output:
  run tf-new-command "dev"
  assert_success
  assert_output --partial "expected output text"
}

@test "tf-new-command sets the right global" {
  # Act: call directly to preserve globals
  call_exposed tf-new-command "dev"
  [[ "${_CALL_RC}" -eq 0 ]]

  # Assert globals:
  [[ "${_dsbTfSomeGlobal}" == "expected_value" ]]
}
```

### 5. Example: testing a new internal function

```bash
@test "_dsb_tf_new_internal_function returns correct data" {
  # Internal functions often require the shell to be configured
  _dsb_tf_configure_shell || true
  _dsbTfLogInfo=0
  _dsbTfLogErrors=0

  # Call the function
  _dsb_tf_new_internal_function "arg1"

  # Check results -- either _dsbTfReturnCode or direct return, depending on convention
  [[ "${_dsbTfReturnCode}" -eq 0 ]]
  [[ "${_dsbTfSomeResult}" == "expected" ]]

  _dsb_tf_restore_shell
}
```

---

## Known Gotchas

### `shopt -o history` fails in non-interactive shells

`_dsb_tf_configure_shell` calls `shopt -o history`, which returns exit code 1 in non-interactive shells (like bats test processes). Under bats' `set -e`, this aborts the test. The workaround is either `call_exposed` (which disables `set -e`) or `_dsb_tf_configure_shell || true`.

### `export -f` does not cross `bash -c` boundaries

When using `run bash -c '...'`, mock functions defined in the parent shell are not available inside the subshell. You must redefine mocks inline inside the `bash -c` string. This is ugly but necessary for tests that need both output capture and global inspection.

### Associative array iteration order is non-deterministic

Environment names come from a bash associative array (`_dsbTfEnvsDirList`). The iteration order of associative arrays is not guaranteed. Tests should check for presence of both "dev" and "prod" without assuming order:

```bash
# Good:
assert_output --partial "dev"
assert_output --partial "prod"

# Bad:
assert_line --index 0 --partial "dev"
assert_line --index 1 --partial "prod"
```

### Interactive functions need stdin piped

Functions using `read -r -p` (tf-select-env, az-select-sub, tf-clean) need input piped via heredoc or `<<<`:

```bash
run bash -c '... tf-select-env <<< "1" ...'
```

### The script scrolls the terminal on source

`dsb-tf-proj-helpers.sh` prints `\033[2J\033[H` on source to scroll the terminal. This is cosmetic and harmless in tests, but it does appear in `$output` when capturing source output.

---

## Parallelization

```bash
# Run with 4 parallel workers (one file per worker)
npx bats --jobs 4 test/*.bats
```

Bats parallelizes **across files**, not within them. Each file gets its own process. Files must be independent -- no shared state, no ordering dependencies.

All test files are designed to be independent. Each sources the script fresh, creates its own fixture copy in `$BATS_TEST_TMPDIR`, and cleans up in teardown.

---

## Future-Proofing

The test suite is designed to survive a planned rewrite of the error handling internals.

### Tests that will need updating on rewrite

File `03_error_handling.bats` tests the current configure/restore lifecycle, ERR trap, and error handler. These tests are **implementation-specific** and will need rewriting when the error handling changes. They are isolated in a single file to contain the blast radius.

### Tests that should survive a rewrite

All other files test **observable behavior**: exposed function return codes, global variable state, user-visible output. These should continue to work regardless of whether the internals use `_dsbTfReturnCode`, direct returns, ERR traps, or any other mechanism.

### The mock layer is the abstraction boundary

If the script changes how it calls external tools (different argument patterns, different tools), update the mocks in `mock_helper.bash`. Test files reference mock functions by name, not by implementation detail.

### The assertion helpers abstract the checking mechanism

If the script changes how it communicates results (global variable vs. return code), update the assertion helpers in `assertion_helper.bash`. Test files use `assert_global` and `assert_clean_output_contains`, not raw variable access.
