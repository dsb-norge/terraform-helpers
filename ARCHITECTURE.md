# Architecture: dsb-tf-proj-helpers.sh

Comprehensive documentation of the design and architecture of `dsb-tf-proj-helpers.sh`.

## What This Script Is

A collection of bash helper functions for working with DSB Terraform projects. It is **sourced** into the user's interactive shell (via `source <(curl ...)` or `eval "$(gh api ...)"`) and provides 53 user-facing commands prefixed with `tf-` and `az-`. The script is a single file, ~7000 lines, 182 functions, and requires no installation beyond sourcing.

Because the script runs in the user's shell (not as a subprocess), all design decisions are constrained by the requirement that **the script must never corrupt or kill the user's shell session**.

## Expected Project Structure

The script expects to be run from the root of a Terraform project with this directory layout:

```
<project-root>/
  main/                     # The main Terraform module
    *.tf
  envs/                     # One subdirectory per environment
    dev/
      *.tf
      .terraform.lock.hcl   # Provider lock file
      .az-subscription      # Contains the Azure subscription name (hint for az-set-sub)
    prod/
      *.tf
      .terraform.lock.hcl
      .az-subscription
  modules/                  # Optional local sub-modules
    <module-name>/
      *.tf
  .tflint.hcl               # Optional tflint configuration
  .github/
    workflows/
      *.yml                 # GitHub Actions workflows (for version bumping)
```

Directories under `envs/` starting with `_` are excluded from enumeration (e.g., `_template/`).

---

## Script Lifecycle

### Sourcing (load time)

The entire script body is wrapped in `{ ... }` (download guard) to prevent partial-download execution when loaded via `source <(curl ...)`. Bash reads the complete `{ }` compound command before executing any of it; a truncated download produces a syntax error instead of partial execution.

When sourced, the following runs immediately (not inside any function):

1. **Bash version guard** (lines 4-10): Checks for bash 4.3+ (required for associative arrays and namerefs). On older bash, prints a clear error and returns 1 to abort sourcing.

2. **Cleanup of previous state** (lines 85-148): Unsets all `_dsbTf*` global variables, removes all functions with prefixes `_dsb_`, `tf-`, `az-`, and removes all tab completions for `tf-*` and `az-*`. The cleanup functions themselves are then removed. This ensures idempotent re-sourcing.

3. **Global variable declarations** (lines 152-183): Declares all persistent globals with empty defaults using `declare -g`.

4. **Function definitions** (lines 187-7048): All utility, internal, and exposed functions are defined.

5. **Architecture detection** (lines 277-302): Checks `uname -m` and `uname -s` to determine the platform (arm64/macOS, aarch64/Linux, x86_64/Linux). Sets platform-specific command variables (`_dsbTfRealpathCmd`, `_dsbTfCutCmd`, `_dsbTfMvCmd`). On unsupported platforms, logs an error and `return 1` to abort sourcing.

6. **Final initialization** (lines 7051-7061): Scrolls the terminal to hide previous output, enumerates project directories, registers all tab completions, and prints the startup message. The `|| :` ensures these never cause the sourcing to fail.

**Source-time safety**: All init code is defensively written to work even when the caller has `set -e` active. Every command that could fail uses `|| :` or `|| varName=''` as a fallback. This is a load-bearing property -- see `DEVELOPER-ERROR-HANDLING.md` for details.

### User invocation (runtime)

When the user calls an exposed function like `tf-init dev`:

1. **Set -e neutralization guard**: If the caller has `set -e` active, it is temporarily disabled and the function re-invokes itself. This ensures the script works correctly in CI pipelines and other strict-mode environments.
2. **`_dsb_tf_configure_shell`**: Saves the caller's shell options and history state, establishes a known shell state (see below), installs signal traps, initializes logging flags, clears work arrays, cleans up temp files from interrupted operations, and clears the error stack.
3. **Internal logic**: The exposed function delegates to one or more internal functions.
4. **Error dump**: If the return code is non-zero, the error context stack is dumped to the user.
5. **`_dsb_tf_restore_shell`**: Restores the caller's original shell options, history state, and removes traps.
6. **Return**: The exit code is returned to the user.

---

## Function Categories

### Exposed functions (53 functions, prefixed `tf-` and `az-`)

User-facing commands called from the command line. They form the public API. Every exposed function:

- Includes a `set -e` neutralization guard as the first line.
- Calls `_dsb_tf_configure_shell` to enter the controlled shell state.
- Delegates to one or more internal functions.
- Calls `_dsb_tf_error_dump` on failure.
- Calls `_dsb_tf_restore_shell` to leave the user's shell unchanged.
- Returns its exit code directly.

Exposed functions are organized into groups:

| Group | Functions | Purpose |
|---|---|---|
| Check | `tf-check-dir`, `tf-check-prereqs`, `tf-check-tools`, `tf-check-gh-auth`, `tf-check-env` | Validate project structure, tools, auth, environments |
| Status | `tf-status` | Full status report (tools, auth, environment) |
| Environment | `tf-list-envs`, `tf-set-env`, `tf-select-env`, `tf-clear-env`, `tf-unset-env` | Manage the selected environment |
| Azure | `az-login`, `az-logout`, `az-relog`, `az-whoami`, `az-set-sub`, `az-select-sub` | Azure CLI authentication and subscription management |
| Terraform | `tf-init`, `tf-init-env`, `tf-init-all`, `tf-init-main`, `tf-init-modules`, `tf-fmt`, `tf-fmt-fix`, `tf-validate`, `tf-plan`, `tf-apply`, `tf-destroy` | Core Terraform operations |
| Terraform offline | `tf-init-offline`, `tf-init-env-offline`, `tf-init-all-offline` | Same as above, without backend |
| Linting | `tf-lint` | Run tflint via a wrapper script |
| Clean | `tf-clean`, `tf-clean-tflint`, `tf-clean-all` | Remove `.terraform` and/or `.tflint` directories |
| Upgrade | `tf-upgrade`, `tf-upgrade-env`, `tf-upgrade-all`, `tf-upgrade-offline`, `tf-upgrade-env-offline`, `tf-upgrade-all-offline` | Upgrade Terraform dependencies (within version constraints) |
| Bump | `tf-bump`, `tf-bump-env`, `tf-bump-all`, `tf-bump-offline`, `tf-bump-env-offline`, `tf-bump-all-offline`, `tf-bump-modules`, `tf-bump-cicd`, `tf-bump-tflint-plugins` | Upgrade module/plugin/tool versions to latest |
| Provider info | `tf-show-provider-upgrades`, `tf-show-all-provider-upgrades` | Show available provider version upgrades |
| Help | `tf-help` | Built-in help system |

### Internal functions (~119 functions, prefixed `_dsb_tf_`)

The implementation layer. Not intended to be called by users. They:

- Always return their exit code directly (`return 0` for success, `return 1` for failure).
- Push error context to the error stack (`_dsb_tf_error_push`) at failure points.
- Many populate global variables to persist results between calls.

### Utility functions (~10 functions, prefixed `_dsb_`)

Cross-cutting concerns: logging, error handling, error stack, shell configuration. They generally do not return explicit exit codes.

---

## Error Handling

See `DEVELOPER-ERROR-HANDLING.md` for the developer-facing guide. This section describes the architecture.

### Design

All functions return their exit code directly. There is no ERR trap, no `set -e`, and no global return code variable.

A **global error context stack** (`_dsbTfErrorStack`) accumulates human-readable context as errors propagate up the call chain. When the exposed function detects a non-zero return, it dumps the stack to the user before returning. Example output:

```
ERROR  : Error context:
ERROR  :   _dsb_tf_look_for_env: environment 'staging' not found in /project/envs
ERROR  :   _dsb_tf_check_env: environment check failed for 'staging'
ERROR  :   _dsb_tf_terraform_preflight: preflight failed for environment 'staging'
```

### Shell state guarantee

`_dsb_tf_configure_shell` establishes a known state before any internal code runs:

| Setting | State | Rationale |
|---|---|---|
| `set -e` (errexit) | Off | Errors are handled explicitly with `if !` and `$?` |
| `set -E` (errtrace) | Off | No ERR trap to inherit |
| `set -o pipefail` | Off | Pipe failures are checked explicitly via `PIPESTATUS` |
| ERR trap | Removed | No automatic error catching |
| `set -u` (nounset) | On | Catches unset variable bugs |
| SIGHUP/SIGINT traps | Installed | Restores user's shell on Ctrl+C |

`_dsb_tf_restore_shell` restores the caller's original shell state exactly as saved. The caller's `set -e`, `pipefail`, traps, history settings, and all other options are preserved across every exposed function call.

### Pipeline failure detection

When terraform/tflint output is piped through `_dsb_tf_fixup_paths_from_stdin` for path normalization, `PIPESTATUS[0]` is used to check the left-side (terraform/tflint) exit code. This is necessary because the pipeline exit code is the exit code of the last command (the filter, which always succeeds), not the first.

### Signal handling

SIGHUP and SIGINT are trapped during function execution. The signal handler calls `_dsb_tf_restore_shell` to ensure the user's shell is never left in a modified state. This is necessary because the exposed function's cleanup code may not run after a signal.

### Internal error mechanism

`_dsb_internal_error` is used for programming errors / invariant violations. It logs using `_dsb_ie` (which always prints, ignoring the `_dsbTfLogErrors` mute flag) and pushes context to the error stack. The caller must follow it with `return 1`.

### Error propagation pattern

When an internal function calls another and the callee fails:

```bash
if ! _dsb_tf_inner_function "${arg}"; then
  _dsb_tf_error_push "inner operation failed for '${arg}'"
  return 1
fi
```

The inner function already pushed its own context. The outer function adds its own perspective. The exposed function dumps the accumulated stack.

---

## Logging

Five logging functions with distinct purposes:

| Function | Prefix | Color | Mutable | Purpose |
|---|---|---|---|---|
| `_dsb_e` | `ERROR  :` | Red | `_dsbTfLogErrors=0` | Operational errors |
| `_dsb_ie` | `ERROR  : <caller> :` | Red | **No** (always prints) | Invariant violations |
| `_dsb_w` | `WARNING:` | Yellow | `_dsbTfLogWarnings=0` | Non-fatal issues |
| `_dsb_i` | `INFO   :` | Blue | `_dsbTfLogInfo=0` | Normal operational output |
| `_dsb_d` | `DEBUG  : <caller> :` | Magenta | Off by default (`_dsbTfLogDebug=1` to enable) | Development/debugging |

Additional info variants: `_dsb_i_nonewline` (no trailing newline), `_dsb_i_append` (no prefix).

### Inline log suppression

Callers suppress logging for a specific call using bash's per-command variable assignment:

```bash
_dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
```

The variables are scoped to that single command. This is used pervasively when a caller wants to check a condition silently and present its own summary.

### Debug logging

Controlled from the command line:
- Enable: `_dsb_tf_debug_enable_debug_logging`
- Disable: `_dsb_tf_debug_disable_debug_logging`

When enabled, nearly every function logs its entry state, intermediate decisions, and exit codes.

---

## Global Variables

### Persistent across user invocations

These survive between exposed function calls because they are declared at source time and not cleared by `_dsb_tf_restore_shell`:

| Variable | Type | Purpose |
|---|---|---|
| `_dsbTfRootDir` | string | Project root directory (PWD at function call time) |
| `_dsbTfEnvsDir` | string | `<root>/envs` path |
| `_dsbTfMainDir` | string | `<root>/main` path |
| `_dsbTfModulesDir` | string | `<root>/modules` path |
| `_dsbTfFilesList` | indexed array | All `.tf` files in the project |
| `_dsbTfLintConfigFilesList` | indexed array | All `.tflint.hcl` files in the project |
| `_dsbTfEnvsDirList` | assoc array | Environment name -> directory path |
| `_dsbTfAvailableEnvs` | indexed array | Environment names |
| `_dsbTfModulesDirList` | assoc array | Module name -> directory path |
| `_dsbTfSelectedEnv` | string | Currently selected environment name |
| `_dsbTfSelectedEnvDir` | string | Path to selected environment directory |
| `_dsbTfSelectedEnvLockFile` | string | Path to `.terraform.lock.hcl` |
| `_dsbTfSelectedEnvSubscriptionHintFile` | string | Path to `.az-subscription` file |
| `_dsbTfSelectedEnvSubscriptionHintContent` | string | Content of `.az-subscription` |
| `_dsbTfAzureUpn` | string | Azure logged-in user principal name |
| `_dsbTfSubscriptionId` | string | Active Azure subscription ID |
| `_dsbTfSubscriptionName` | string | Active Azure subscription name |
| `_dsbTfRealpathCmd` | string | Platform-specific `realpath` command |
| `_dsbTfCutCmd` | string | Platform-specific `cut` command |
| `_dsbTfMvCmd` | string | Platform-specific `mv` command |
| `_dsbTfTflintWrapperDir` | string | `.tflint` directory path |
| `_dsbTfTflintWrapperScript` | string | Full path to tflint wrapper script |
| `ARM_SUBSCRIPTION_ID` | env var | Set by terraform preflight for the azurerm provider |

Note: `_dsbTfFilesList`, `_dsbTfLintConfigFilesList`, `_dsbTfEnvsDirList`, `_dsbTfAvailableEnvs`, and `_dsbTfModulesDirList` are re-cleared and re-populated by `_dsb_tf_configure_shell` / `_dsb_tf_enumerate_directories` on every exposed function call.

### Lifecycle-scoped (set by configure_shell, cleared by restore_shell)

| Variable | Purpose |
|---|---|
| `_dsbTfShellOldOpts` | Saved shell options for restoration |
| `_dsbTfShellHistoryState` | Saved shell history on/off state |
| `_dsbTfLogInfo` | Controls info logging (1=on, 0=muted) |
| `_dsbTfLogWarnings` | Controls warning logging |
| `_dsbTfLogErrors` | Controls error logging |
| `_dsbTfErrorStack` | Error context stack (cleared at start, dumped on failure) |

### Runtime globals (set by various internal functions)

| Variable | Set by | Purpose |
|---|---|---|
| `_dsbTfLogDebug` | `_dsb_tf_debug_enable/disable_debug_logging` | Debug logging toggle |
| `_dsbTfHclMetaAllSources` | `_dsb_tf_enumerate_hcl_blocks_meta` | HCL block source attributes |
| `_dsbTfHclMetaAllVersions` | `_dsb_tf_enumerate_hcl_blocks_meta` | HCL block version attributes |
| `_dsbTfRegistryModulesAllSources` | `_dsb_tf_enumerate_registry_modules_meta` | Registry module sources |
| `_dsbTfRegistryModulesAllVersions` | `_dsb_tf_enumerate_registry_modules_meta` | Registry module versions |
| `_dsbTfLatestRegistryModuleVersion` | `_dsb_tf_get_latest_registry_module_version` | Latest module version from registry |
| `_dsbTfLatestTflintPluginVersion` | `_dsb_tf_get_latest_tflint_plugin_version` | Latest tflint plugin version |
| `_dsbTfLatestProviderVersion` | `_dsb_tf_get_latest_terraform_provider_version` | Latest provider version |
| `_dsbTfLockfileProviderVersion` | `_dsb_tf_get_lockfile_provider_version` | Provider version from lock file |
| `_dsbTfProviderVersionsCache` | `_dsb_tf_get_latest_terraform_provider_version` | Cache for provider version lookups |

---

## External Tool Dependencies

| Tool | Used for | Check function |
|---|---|---|
| `az` | Azure CLI authentication, subscription management | `_dsb_tf_check_az_cli` |
| `gh` | GitHub CLI authentication, API calls (version lookups, tflint wrapper download) | `_dsb_tf_check_gh_cli` |
| `terraform` | Init, validate, plan, apply, fmt, providers lock | `_dsb_tf_check_terraform` |
| `jq` | JSON parsing (Azure account info, provider versions, module versions) | `_dsb_tf_check_jq` |
| `yq` | YAML reading/writing (GitHub workflow version bumping) | `_dsb_tf_check_yq` |
| `hcledit` | HCL block enumeration and attribute get/set (module/plugin version bumping, lock file parsing) | `_dsb_tf_check_hcledit` |
| `terraform-config-inspect` | Extracting provider requirements from Terraform config (provider upgrade listing) | `_dsb_tf_check_terraform_config_inspect` |
| `curl` | Terraform registry API calls, tflint wrapper download fallback | `_dsb_tf_check_curl` |
| `go` | Availability check only (needed for installing hcledit/terraform-config-inspect) | `_dsb_tf_check_golang` |
| `realpath` / `grealpath` | Relative path computation | `_dsb_tf_check_realpath` |
| `wl-copy` / `xclip` / `xsel` / `pbcopy` | Optional clipboard support for Azure device code login | (checked inline) |

---

## Script Sections (file layout)

| Lines | Section | Content |
|---|---|---|
| 1-2 | Guards | Download guard (`{`), bash version check |
| 3-81 | Header | cSpell config, developer notes, TODOs |
| 85-148 | Init: cleanup | Removes previous state (variables, functions, completions) |
| 152-183 | Init: global variables | Declares all persistent globals |
| 187-275 | Utility: logging | `_dsb_e`, `_dsb_ie`, `_dsb_i`, `_dsb_i_nonewline`, `_dsb_i_append`, `_dsb_w` |
| 277-302 | Init: architecture check | Platform detection, sets `_dsbTfRealpathCmd` etc. |
| 305-487 | Utility: general | `_dsb_tf_get_github_cli_account`, `_dsb_tf_report_status` |
| 489-651 | Utility: debug | `_dsb_d`, enable/disable debug logging, call graph generation |
| 653-756 | Utility: error handling | Error stack (`push`/`clear`/`dump`), signal handler, `configure_shell`, `restore_shell` |
| 758-1538 | Utility: help | Help dispatcher, group/command help functions, `_dsb_tf_help_specific_command` |
| 1540-1643 | Utility: tab completion | Completion functions and registration for environments, tf-lint, tf-help |
| 1645-1826 | Utility: version parsing | Semver validation, major/minor/patch extraction, bump version resolution |
| 1828-2397 | Internal: checks | Individual tool checks, `_dsb_tf_check_tools`, `_dsb_tf_check_gh_auth`, `_dsb_tf_check_current_dir`, `_dsb_tf_check_prereqs`, `_dsb_tf_check_env` |
| 2399-3030 | Internal: directory enumeration | `_dsb_tf_enumerate_directories`, path utilities, environment/module/file lookups |
| 3032-3279 | Internal: environment | `_dsb_tf_clear_env`, `_dsb_tf_list_envs`, `_dsb_tf_set_env`, `_dsb_tf_select_env` |
| 3281-3754 | Internal: Azure CLI | Login/logout/re-login, account enumeration, subscription set/select |
| 3756-4500 | Internal: terraform operations | Preflight, init (env/dir/modules/main/all), fmt, validate, plan, apply, destroy |
| 4502-4662 | Internal: linting | Tflint wrapper install and execution |
| 4664-4820 | Internal: clean | Dot directory discovery and deletion |
| 4822-6353 | Internal: upgrade | Version lookups (terraform, tflint, modules, plugins, providers), version bumping (GitHub workflows, modules, tflint plugins), combined bump orchestration |
| 6355-7048 | Exposed functions | All 53 `tf-*` and `az-*` functions |
| 7051-7061 | Init: final setup | Terminal scroll, directory enumeration, completion registration, startup message |

---

## Key Internal Workflows

### Environment selection (`tf-set-env <env>`)

1. Validates the current directory is a valid Terraform project (`_dsb_tf_check_current_dir`).
2. Enumerates directories to find available environments.
3. Verifies the requested environment exists.
4. Sets `_dsbTfSelectedEnv` and `_dsbTfSelectedEnvDir`.
5. Looks for the subscription hint file (`.az-subscription`).
6. If found, attempts to set the Azure subscription via `_dsb_tf_az_set_sub`.
7. Checks for the lock file (`.terraform.lock.hcl`).

### Terraform init (`tf-init <env>`)

1. Preflight: checks Terraform is installed, sets the environment (which also sets the Azure subscription), exports `ARM_SUBSCRIPTION_ID`.
2. Runs `terraform init -reconfigure -lock=false` in the environment directory. Output is piped through `_dsb_tf_fixup_paths_from_stdin` for path normalization; `PIPESTATUS[0]` checks terraform's exit code.
3. If upgrading (`-upgrade`), also runs `terraform providers lock` for multiple platforms.
4. Initializes local sub-modules (copies lock file, uses env providers as plugin cache).
5. Initializes the main directory (same approach as modules).

### Version bumping (`tf-bump <env>`)

1. Bumps registry module versions in all `.tf` files (queries Terraform registry API via curl).
2. Bumps tflint plugin versions in all `.tflint.hcl` files (queries GitHub API via gh).
3. Bumps terraform and tflint versions in GitHub workflow files (queries GitHub API, uses yq to update YAML).
4. Runs `terraform init -upgrade` for the environment.
5. Lists available provider upgrades (compares registry latest vs. lock file versions).

### Provider upgrade listing (`tf-show-provider-upgrades <env>`)

1. Uses `terraform-config-inspect --json` to extract provider requirements.
2. Queries the Terraform registry API for each provider's latest version.
3. Uses `hcledit` to read the locked version from `.terraform.lock.hcl`.
4. Displays a comparison: latest version vs. locked version vs. version constraints.
5. Implements a caching mechanism (`_dsbTfProviderVersionsCache`) for provider version lookups across multiple environments.

---

## Tab Completion

Completions are registered for all environment-accepting commands and for `tf-help` and `tf-lint`.

| Command group | Completion source |
|---|---|
| 20 environment commands (tf-set-env, tf-init, tf-plan, etc.) | `_dsbTfAvailableEnvs` (first argument only) |
| `tf-lint` | Environment names (1st arg) + wrapper script flags (2nd+ args) |
| `tf-help` | Help groups + all command names |

Completions are registered by `_dsb_tf_register_all_completions` which is called at source time. The environment completion function re-enumerates directories on each tab press to ensure freshness.

---

## Platform Support

| Platform | `_dsbTfRealpathCmd` | `_dsbTfCutCmd` | `_dsbTfMvCmd` |
|---|---|---|---|
| macOS arm64 | `grealpath` | `gcut` | `gmv` |
| Linux aarch64 | `realpath` | `cut` | `mv` |
| Linux x86_64 | `realpath` | `cut` | `mv` |

Unsupported platforms cause the script to abort sourcing with an error message. Bash versions below 4.3 are rejected at source time with a version guard.

---

## Testing

See `TESTING.md` for the test suite documentation.

- **Framework**: bats-core with bats-support, bats-assert, bats-file
- **Test count**: 247 tests across 20 files
- **Coverage**: 95% of functions (direct + indirect)
- **Mocking**: All external tools are mocked via function overrides; tests run without any dependencies installed
- **CI**: GitHub Actions workflow runs on PRs, posts a single updatable comment with results

---

## File Inventory

| File | Purpose |
|---|---|
| `dsb-tf-proj-helpers.sh` | The script (7061 lines, 182 functions) |
| `README.md` | User-facing documentation (how to load and use) |
| `TESTING.md` | Test suite documentation |
| `DEVELOPER-ERROR-HANDLING.md` | Developer guide for error handling patterns |
| `ARCHITECTURE.md` | This document |
| `REWRITE-FUNCTIONAL-DIFFS.md` | Documents behavioral differences from the error handling rewrite |
| `package.json` | npm manifest for test dependencies (bats-core) |
| `.github/workflows/tests.yml` | GitHub Actions workflow for running tests on PRs |
| `test/` | Test suite (20 `.bats` files, helpers, fixtures) |
