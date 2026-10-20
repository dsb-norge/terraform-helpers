# Testing `dsb-tf-proj-helpers.sh`

## Quick Start

```bash
# Install test dependencies
npm install

# Run the full suite (with parallel execution)
npm test

# Run sequentially (no GNU parallel needed)
npx bats test/*.bats

# Run a single test file
npx bats test/04_version_parsing.bats

# Run tests matching a name pattern
npx bats --filter "tf-set-env" test/*.bats

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

**Current state**: 801 tests across 36 files. All external tools are mocked -- tests run without any dependencies installed.

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
    project_module/           # Terraform module repo (root .tf files, examples, tests).
    lint/                     # Module manifests (.terraform/modules/modules.json) for the lint tests.
  01_source_init.bats         # Script sourcing, function definitions, arch detection.
  02_logging.bats             # _dsb_e, _dsb_i, _dsb_w, _dsb_d, mute flags.
  03_error_handling.bats      # Error context stack, configure/restore lifecycle.
  04_version_parsing.bats     # Semver validation, parsing, bump resolution.
  05_tool_checks.bats         # All _dsb_tf_check_* functions, tf-check-tools, tf-check-prereqs.
  06_directory_enumeration.bats  # Directory discovery, env/module/file finding.
  07_environment_management.bats # tf-list-envs, tf-set-env, tf-select-env, tf-clear-env, tf-check-env.
  08_azure_cli.bats           # az-whoami, az-logout, az-set-sub, enumerate_account, is_logged_in.
  09_terraform_operations.bats   # tf-init, tf-validate, tf-plan, tf-apply, tf-destroy, tf-fmt.
  10_linting.bats             # The lint contract: directories, derived manifests, config, var files, examples, _terraform-state.
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
  21_module_detection.bats    # Repo type detection, project-only gating, module enumeration.
  22_module_operations.bats   # tf-init, tf-validate, tf-lint, tf-upgrade, tf-clean, tf-bump in module repos.
  23_module_examples.bats     # tf-init-examples, tf-validate-examples, tf-lint-examples.
  24_module_testing.bats      # tf-test, tf-test-unit, tf-test-integration, tf-test-all-integrations, subscription safety.
  25_module_docs.bats         # tf-docs, tf-docs-examples, tf-docs-all.
  26_module_status_checks.bats # Module-specific tf-status and tf-check-dir.
  32_tf_unload.bats             # tf-unload-helpers: complete removal of helpers from shell.
  33_passthrough_and_log.bats   # Terraform arg passthrough, --log output capture, PIPESTATUS discipline.
  34_setup_commands.bats        # tf-install-helpers, tf-uninstall-helpers, tf-update-helpers, tf-reload-helpers.
  37_providers_lock.bats        # Lock file maintenance: init with/without -upgrade, providers lock platforms.
  38_tflint_install.bats        # tflint version (workflow tflint-version, --use-version) and install into the per-user cache.
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

Module repo tests use `create_module_project` instead of `create_standard_project`.

### The script under test (SUT)

`${SUT}` points to `dsb-tf-proj-helpers.sh` at the project root. When sourced, the script runs its initialization code: clears old state, detects architecture, detects repo type, enumerates directories, registers tab completions, and prints its startup message.

### Test isolation

Each `@test` block runs in a **forked subprocess** of the file-level process. Global variables set in `setup()` are inherited by each test, but changes within one test **do not leak** to other tests.

---

## The Two Patterns: `run` vs. Direct Call

### Use `run` for testing output and exit codes

```bash
@test "tf-help shows overview" {
  run tf-help
  assert_success
  assert_output --partial "DSB Terraform Project Helpers"
}
```

### Call directly (without `run`) for testing global variable mutations

```bash
@test "tf-set-env dev sets _dsbTfSelectedEnv" {
  call_exposed tf-set-env dev
  [[ "${_dsbTfSelectedEnv}" == "dev" ]]
}
```

`run` executes in a subshell -- global changes are lost. The `call_exposed` helper disables `set -e` around the call.

---

## Mocking

External tools are mocked via function overrides. Bash resolves functions before PATH lookups, so mock functions shadow real commands. Available mocks are defined in `test/helpers/mock_helper.bash`.

Each tool has `mock_<tool>` (available and working) and `mock_<tool>_not_installed` (returns error). Some have additional variants (e.g., `mock_az_not_logged_in`, `mock_terraform_init_fails`).

`mock_standard_tools` installs all "available" mocks at once. `unmock_all` removes all overrides.

### Asserting on terraform arguments

`mock_terraform` appends each call to `_MOCK_TERRAFORM_CALLS`, but `run` executes in a subshell, so that array is empty again when the test reads it. To assert on the exact arguments or the order of terraform calls, use `mock_terraform_recording`. It writes one line per call (`"$*"`) to `${MOCK_TERRAFORM_CALLS_FILE}`, and the file survives `run`:

```bash
setup() {
  # ...
  mock_standard_tools
  mock_terraform_recording   # after mock_standard_tools, so it wins
  source "${SUT}"
}

@test "tf-upgrade-env locks for all platforms" {
  run tf-upgrade-env dev
  run terraform_calls_in "envs/dev" "providers lock"   # matching lines only
  assert_output --partial "-platform=linux_arm64"
}
```

Set `MOCK_TERRAFORM_FAIL_INIT` or `MOCK_TERRAFORM_FAIL_LOCK` to a glob, matched against the `-chdir` directory without its trailing slash, to make `init` or `providers lock` fail there (e.g. `'*'`, or `'*/envs/prod'`).

Environment directories in `_dsbTfEnvsDirList` end with a slash, so a recorded call reads `-chdir=/.../envs/dev/ init ...`. `terraform_calls_in` allows for it.

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to add a new mock.

### Testing the lint commands

The lint commands run tflint from their per-user cache, `${XDG_CACHE_HOME}/dsb-tf-proj-helpers/tflint/<version>/tflint`. `test_helper.bash` points `XDG_CACHE_HOME` at the test's own directory, so no test reads or writes the user's cache. Two helpers in `mock_helper.bash` provide tflint:

- `install_fake_tflint [version]` puts a fake tflint in the cache, as if it were installed (default `v0.55.0`, the latest release `mock_gh` and `mock_curl` report). It records every call in `${MOCK_TFLINT_CALLS_FILE}` (`bin=…|pwd=…|tf_data_dir=…|github_token=…|args=…`), copies the manifest it finds in `TF_DATA_DIR` (read it with `fake_tflint_manifest_for <dir>`), fails a lint run whose `--chdir` matches `${MOCK_TFLINT_FAIL_DIR}`, and fails `--init` with `${MOCK_TFLINT_INIT_EXIT}`. `tflint_lint_calls` prints the lint runs, without `--init`.
- `mock_tflint_release` serves a fake release for `gh release download` and `curl` to download, with a matching `checksums.txt`, and mocks `unzip`. Use it to test the install itself.

`mock_yq` emulates the query for the `tflint-version` of the job that calls the shared workflow with grep, so a test sets the version by writing a workflow file.

A test initializes a root the way `terraform init` leaves it by creating `.terraform/modules/` and copying a manifest from `test/fixtures/lint/` (`init_root` in `10_linting.bats`).

---

## Test Fixtures

| Fixture | Purpose |
|---|---|
| `project_standard/` | Valid terraform project (main, envs with dev+prod, modules, .tflint.hcl, .github/workflows) |
| `project_no_envs/` | Missing envs/ directory |
| `project_no_main/` | Missing main/ directory |
| `project_empty/` | Empty directory |
| `project_module/` | Terraform module repo (root .tf files, examples/, tests/, .tflint.hcl, .github/workflows) |
| `lint/` | Module manifests a lint test copies into a root's `.terraform/modules/modules.json`, as `terraform init` would leave them |

Fixtures are **copied** to `$BATS_TEST_TMPDIR` before each test. Tests modify the copy freely.

---

## Custom Assertions

Defined in `test/helpers/assertion_helper.bash`:

```bash
assert_clean_output_contains "ERROR"       # ANSI-stripped output check
assert_global "_dsbTfSelectedEnv" "dev"    # Global variable value
assert_global_set "_dsbTfRootDir"          # Non-empty check
assert_global_empty "_dsbTfSelectedEnv"    # Empty/unset check
assert_function_exists "tf-init"           # Function defined check
```

---

## Writing a New Test

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full guide on adding commands and tests. Key points:

1. Pick the right file (or create a new one for a new functional area).
2. Choose `run` (output/exit code) vs. direct call (global mutations).
3. Set up the right mocks in `setup()`.
4. Run the full suite after: `npx bats test/*.bats`.

---

## Known Gotchas

- **`shopt -o history` fails in non-interactive shells.** Use `call_exposed` or `|| true` when calling `_dsb_tf_configure_shell` directly.
- **`export -f` does not cross `bash -c` boundaries.** Redefine mocks inline for `bash -c` tests.
- **Associative array iteration order is non-deterministic.** Don't assert on line order for env lists.
- **Interactive functions need stdin piped.** Use `<<< "1"` for `read -r -p` prompts.
- **The script scrolls the terminal on source.** `\033[2J\033[H` appears in captured output -- harmless.
- **Mocks run under the script's `set -u`.** An exposed function enables `set -u`, and a mock it calls inherits it. A mock that reads `$2` when called with one argument (for example `hcledit version` in a tool check, whose output goes to `/dev/null`) ends the test's subshell without a word. Read optional arguments as `${2:-}`.

---

## Parallelization

The test runner script (`test/run.sh`) automatically installs GNU parallel and runs tests in parallel using all available CPU cores:

```bash
# Recommended: uses parallel execution
npm test

# Or run directly with explicit job count
npx bats --jobs 4 test/*.bats
```

Bats parallelizes **across files**, not within them. Each file is independent -- no shared state between files. This is why test files are structured as self-contained units.

---

## CI

A GitHub Actions workflow (`.github/workflows/tests.yml`) runs the suite on PRs and posts a single updatable comment with results. See the workflow file for details.
