# Architecture: dsb-tf-proj-helpers.sh

Design and architecture reference. For the developer guide, see [CONTRIBUTING.md](CONTRIBUTING.md). For how to run tests, see [TESTING.md](TESTING.md).

## What This Script Is

A collection of bash helper functions for working with DSB Terraform projects and module repos. It is **sourced** into the user's interactive shell (via `source <(curl ...)` or `eval "$(gh api ...)"`), and optionally installed locally. It provides 79 user-facing commands prefixed with `tf-` and `az-`. The script is a single file (~10900 lines, 255 functions) and requires no installation beyond sourcing (though local install is supported via `tf-install-helpers`).

The script automatically detects whether it's running in a **project repo** (has `main/` + `envs/`) or a **module repo** (has root `.tf` files, no `main/` or `envs/`) and adapts its behavior accordingly.

Because the script runs in the user's shell (not as a subprocess), all design decisions are constrained by the requirement that **the script must never corrupt or kill the user's shell session**.

---

## Script Lifecycle

### Sourcing (load time)

The entire script body is wrapped in `{ ... }` (download guard) to prevent partial-download execution.

When sourced:

1. **Bash version guard**: Checks for bash 4.3+ (required for associative arrays and namerefs).
2. **Cleanup of previous state**: Unsets all `_dsbTf*` globals, removes all `_dsb_`/`tf-`/`az-` functions and completions. Ensures idempotent re-sourcing.
3. **Global variable declarations**: Declares all persistent globals with empty defaults.
4. **Function definitions**: All utility, internal, and exposed functions.
5. **Architecture detection**: Sets platform-specific command variables (`_dsbTfRealpathCmd`, `_dsbTfCutCmd`, `_dsbTfMvCmd`).
6. **Final initialization**: Enumerates directories (detects repo type), registers tab completions, prints startup message.

All init code uses `|| :` fallbacks for `set -e` safety.

### User invocation (runtime)

When the user calls an exposed function:

1. **Set -e neutralization**: If the caller has `set -e`, it's disabled and the function re-invokes itself.
2. **`_dsb_tf_configure_shell`**: Saves shell state, establishes known state (only `set -u` enabled, no `set -e`/ERR traps), installs signal traps, clears error stack.
3. **Internal logic**: Branches by repo type where needed.
4. **Error dump**: If non-zero return, the error context stack is dumped.
5. **`_dsb_tf_restore_shell`**: Restores the caller's original shell state.
6. **Return**: Exit code returned to user.

---

## Repo Type Detection

Determined by `_dsb_tf_enumerate_directories`:

| Condition | `_dsbTfRepoType` |
|---|---|
| `main/` exists AND `envs/` exists | `"project"` |
| Root `.tf` files exist AND no `main/` AND no `envs/` | `"module"` |
| Neither | `""` (unknown) |

Module repos additionally enumerate: examples directory, test files (unit/integration split by naming convention).

---

## Function Categories

### Exposed functions (79, prefixed `tf-` and `az-`)

User-facing commands. Every exposed function includes the `set -e` neutralization guard and the configure/restore lifecycle.

**Project commands** (available in project repos only):

| Group | Commands |
|---|---|
| Environment | `tf-list-envs`, `tf-set-env`, `tf-select-env`, `tf-clear-env`, `tf-unset-env`, `tf-check-env` |
| Terraform (env) | `tf-init-env`, `tf-init-env-offline`, `tf-init-all`, `tf-init-all-offline`, `tf-init-main`, `tf-init-modules` |
| Terraform (ops) | `tf-plan`, `tf-apply`, `tf-destroy` |
| Upgrade (env) | `tf-upgrade-env`, `tf-upgrade-env-offline`, `tf-upgrade-all`, `tf-upgrade-all-offline` |
| Bump (env) | `tf-bump-env`, `tf-bump-env-offline`, `tf-bump-all`, `tf-bump-all-offline` |
| Provider (env) | `tf-show-all-provider-upgrades` |

**Module commands** (available in module repos only):

| Group | Commands |
|---|---|
| Examples | `tf-init-all-examples`, `tf-init-example`, `tf-validate-all-examples`, `tf-validate-example`, `tf-lint-all-examples`, `tf-lint-example` |
| Testing | `tf-test`, `tf-test-unit`, `tf-test-integration`, `tf-test-all-integrations`, `tf-test-example`, `tf-test-all-examples` |
| Documentation | `tf-docs`, `tf-docs-all-examples`, `tf-docs-example`, `tf-docs-all` |

**Common commands** (available in both, may branch by repo type):

| Group | Commands |
|---|---|
| Check | `tf-check-dir`, `tf-check-prereqs`, `tf-check-tools`, `tf-check-az-auth`, `tf-check-gh-auth` |
| Status | `tf-status` |
| Terraform | `tf-init`, `tf-init-offline`, `tf-validate`, `tf-validate-all`, `tf-fmt`, `tf-fmt-fix`, `tf-upgrade`, `tf-upgrade-offline`, `tf-outputs`, `tf-versions` |
| Linting | `tf-lint`, `tf-lint-all` |
| Clean | `tf-clean`, `tf-clean-tflint`, `tf-clean-all` |
| Bump | `tf-bump`, `tf-bump-offline`, `tf-bump-modules`, `tf-bump-cicd`, `tf-bump-tflint-plugins` |
| Provider | `tf-show-provider-upgrades` |
| Azure | `az-login`, `az-logout`, `az-relog`, `az-whoami`, `az-set-sub`, `az-select-sub` |
| Setup | `tf-install-helpers`, `tf-uninstall-helpers`, `tf-update-helpers`, `tf-reload-helpers`, `tf-unload-helpers` |
| Help | `tf-help` |

### Internal functions (~150, prefixed `_dsb_tf_`)

Always return exit codes directly. Push error context on failure. Many populate globals.

### Utility functions (~12, prefixed `_dsb_`)

Logging, error stack, shell configuration.

---

## Error Handling

All functions return exit codes directly. No ERR trap, no `set -e`, no global return code variable. A global error context stack accumulates human-readable messages as errors propagate. See [CONTRIBUTING.md](CONTRIBUTING.md) for the full developer guide.

---

## Logging

| Function | Color | Mutable | Purpose |
|---|---|---|---|
| `_dsb_e` | Red | `_dsbTfLogErrors=0` | Operational errors |
| `_dsb_ie` | Red | **No** | Invariant violations |
| `_dsb_w` | Yellow | `_dsbTfLogWarnings=0` | Warnings |
| `_dsb_i` | Blue | `_dsbTfLogInfo=0` | Info output |
| `_dsb_d` | Magenta | Off by default | Debug |

---

## External Tool Dependencies

| Tool | Required | Check function |
|---|---|---|
| `az` | Yes | `_dsb_tf_check_az_cli` |
| `gh` | Yes | `_dsb_tf_check_gh_cli` |
| `terraform` | Yes | `_dsb_tf_check_terraform` |
| `jq` | Yes | `_dsb_tf_check_jq` |
| `yq` | Yes | `_dsb_tf_check_yq` |
| `hcledit` | Yes | `_dsb_tf_check_hcledit` |
| `terraform-config-inspect` | Yes | `_dsb_tf_check_terraform_config_inspect` |
| `curl` | Yes | `_dsb_tf_check_curl` |
| `go` | Yes | `_dsb_tf_check_golang` |
| `realpath` / `grealpath` | Yes | `_dsb_tf_check_realpath` |
| `terraform-docs` | Module repos only | `_dsb_tf_check_terraform_docs` |

---

## Script Sections (file layout)

| Lines | Section |
|---|---|
| 1-10 | Download guard, bash version check |
| 92-158 | Init: cleanup of previous state |
| 159-205 | Init: global variable declarations |
| 207-295 | Utility: logging |
| 297-323 | Init: architecture detection |
| 325-550 | Utility: general (`_dsb_tf_report_status`, etc.) |
| 552-714 | Utility: debug |
| 716-819 | Utility: error handling (error stack, signal handler, configure/restore) |
| 821-870 | Utility: `--log` output capture |
| 872-2208 | Utility: help system |
| 2210-2428 | Utility: tab completion |
| 2430-2611 | Utility: version parsing |
| 2613-3355 | Internal: checks |
| 3357-4052 | Internal: directory enumeration (includes repo type detection) |
| 4054-4301 | Internal: environment management |
| 4303-4776 | Internal: Azure CLI |
| 4778-5522 | Internal: terraform operations |
| 5524-5684 | Internal: linting |
| 5686-5876 | Internal: clean |
| 5878-7700 | Internal: upgrade/bump |
| 7702-8080 | Internal: module repo operations |
| 8082-8346 | Internal: module examples support |
| 8348-8571 | Internal: terraform test support |
| 8573-8692 | Internal: documentation generation |
| 8694-9095 | Internal: version information |
| 9097-9288 | Internal: setup/install management |
| 9290-10919 | Exposed functions |
| 10921-10951 | Init: final setup |

---

## Platform Support

| Platform | `_dsbTfRealpathCmd` | `_dsbTfCutCmd` | `_dsbTfMvCmd` |
|---|---|---|---|
| macOS arm64 | `grealpath` | `gcut` | `gmv` |
| Linux aarch64 | `realpath` | `cut` | `mv` |
| Linux x86_64 | `realpath` | `cut` | `mv` |

Bash 4.3+ required. Unsupported platforms or old bash versions abort sourcing with an error.

---

## Testing

See [TESTING.md](TESTING.md) for the full guide.

- **Framework**: bats-core with bats-support, bats-assert, bats-file
- **Tests**: 570 across 32 files
- **Mocking**: All external tools mocked via function overrides
- **CI**: GitHub Actions on PRs, posts updatable comment with results

---

## File Inventory

| File | Purpose |
|---|---|
| `dsb-tf-proj-helpers.sh` | The script (~10900 lines, 255 functions) |
| [README.md](README.md) | User-facing: how to load and use |
| [ARCHITECTURE.md](ARCHITECTURE.md) | This document |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Developer guide: patterns, conventions, how to add features |
| [TESTING.md](TESTING.md) | Test suite guide: how to run, write, and maintain tests |
| `package.json` | npm manifest for test dependencies |
| `.github/workflows/tests.yml` | CI workflow for running tests on PRs |
| `test/` | Test suite (30 `.bats` files, helpers, fixtures) |
