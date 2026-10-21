# Architecture: dsb-tf-proj-helpers.sh

Design and architecture reference. For the developer guide, see [CONTRIBUTING.md](CONTRIBUTING.md). For how to run tests, see [TESTING.md](TESTING.md).

## What This Script Is

A collection of bash helper functions for working with DSB Terraform projects and module repos. It is **sourced** into the user's interactive shell (via `source <(curl ...)` or `eval "$(gh api ...)"`), and optionally installed locally. It provides 86 user-facing commands prefixed with `tf-` and `az-`. The script is a single file (~13000 lines, ~300 functions) and requires no installation beyond sourcing (though local install is supported via `tf-install-helpers`).

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

## Lock Files (project repos)

Each environment directory has a committed `.terraform.lock.hcl`, and project repos must have no lock file anywhere else. Main and local sub-modules have none of their own: when `tf-init`, `tf-init-all` or the upgrade commands initialize them, `_dsb_tf_init_dir` copies the environment's lock file in, initializes against the environment's `.terraform/providers`, and removes the copy again. That initialization is there to download their dependencies.

`terraform init` hashes a provider it adds for the local platform only. `terraform providers lock` adds the hashes for every platform in `_dsbTfLockPlatforms`, the one place that list is kept. It runs in environment directories only, after init. Which command runs which:

| Commands | `terraform init` | `providers lock` | Effect on the lock file |
|---|---|---|---|
| `tf-init*` | without `-upgrade` | no | adds missing providers, hashed for the local platform only |
| `tf-lock*` | without `-upgrade` | yes | adds missing providers, hashed for all platforms; locked versions stay |
| `tf-upgrade*`, `tf-bump*` | `-upgrade` | yes | moves providers to the newest allowed version, hashed for all platforms |

The `tf-lock*` commands touch environment directories only. `tf-lock-all` runs what `tf-lock-env` runs in each environment (`_dsb_tf_lock_all_envs`) and never initializes main or local sub-modules, so it creates no lock file outside `envs/`, not even the temporary copy.

`_dsb_tf_init_env_actual` and `_dsb_tf_init_env`, which work on one environment directory, take `doUpgrade` and `doLock` as their first two arguments. An upgrade always locks, whatever `doLock` says: until `providers lock` runs, a newly selected version is hashed for the local platform only.

Module repos are different: their lock files are gitignored, and no command runs `providers lock` there.

---

## Linting

The lint commands follow the lint contract CI follows, written down once in [github-actions-terraform: docs/Linting.md](https://github.com/dsb-norge/github-actions-terraform/blob/main/docs/Linting.md). A local lint gives the result CI gives: the same directories, prepared the same way, with the same config, tflint version and var files. Earlier versions ran an external tflint wrapper script instead; it is retired, and nothing of it is left in the CLI.

### The contract (`_dsb_tf_tflint_lint_root`)

Every lint command lints one or more **roots**: an environment directory, `envs/_terraform-state`, a module repo's root, or a module example.

| Step | What the CLI does |
|---|---|
| Directories | The root first, then every local module directory in the root's `.terraform/modules/modules.json` (a `Dir` not under `.terraform/`), each linted as its own root with `--chdir` (`_dsb_tf_tflint_module_dirs`). No manifest: the root only. |
| Preparation | None for the root, which must be initialized; the message names the init command. A root whose `.tf` files call no modules needs no manifest, and is linted without `.terraform` (`terraform init` creates none where there is nothing to install). Each module directory gets a temporary `TF_DATA_DIR` holding a manifest derived from the root's: the entries at or below the directory's key, that prefix stripped, every `Dir` made absolute (`_dsb_tf_tflint_write_derived_manifest`). A directory reached through several keys uses the shortest: fewest segments, then fewest characters, then sort order. Nothing is written into the repository, and the temporary directories are removed. |
| Config | `<root>/.tflint.hcl`, else the repository root's, for every directory of the root (`_dsb_tf_tflint_resolve_config`). An example always uses the module root's. When there is none, the embedded default config (`_dsb_tf_tflint_default_config`) is written into the root, never into a project repo's root, its plugins are bumped with the `tf-bump-tflint-plugins` code when hcledit and gh authentication are available, and the user is told to commit it. |
| Plugins | `tflint --init --config=<config>` once per root, with `GITHUB_TOKEN` from `gh auth token` when available. |
| Var files | The root once per `*.tfvars` in it other than `terraform.tfvars` and `*.auto.tfvars`, as `--var-file=<absolute path>`; once without when there is none. Module directories never get var files: tflint matches values by variable name, so a module would get the root's value for a variable of the same name that its caller never passed. |
| Result | One exit code per (directory, var file) run, a summary of every run, and failure when any run fails. |

tflint runs from the repository root (`_dsb_tf_tflint_run`, in a subshell), so the paths in its output are relative to the repository root.

Which roots each command lints:

| Repo | Command | Roots |
|---|---|---|
| project | `tf-lint [env]` | the environment |
| project | `tf-lint-tfstate` | `envs/_terraform-state`, initialized offline when it is not initialized |
| project | `tf-lint-all` | every environment, then `envs/_terraform-state` when there is one |
| module | `tf-lint` | the module root, and every local directory its manifest records |
| module | `tf-lint-example`, `tf-lint-all-examples` | each example, with the module root's config, and only the local module directories inside the example; the module root and its submodules are left to the root lint |
| module | `tf-lint-all` | the module root, leaving out the directories under `examples/`, then every example as its own root |

In a module repo, `terraform init` at the root also installs the modules that the `run` blocks of `tests/*.tftest.hcl` call (keys `test.<dir>.<file>.<run>` in the manifest), such as the examples and test fixture directories. `tf-lint` lints them all from the root. `tf-lint-all`, which also lints each example as its own root, leaves the directories under `<root>/examples/` out of the root lint (`_dsb_tf_lint_module_root` with its third argument, the excluded directory of `_dsb_tf_tflint_module_dirs`), so each example is linted once, with the module root's config, as CI does with `examples: true`. The test fixture directories are still linted from the root.

### tflint version and install (`_dsb_tf_tflint_prepare`)

- **Version** (`_dsb_tf_tflint_resolve_version`): `--use-version <version>` when given; else the `tflint-version` input of the job that calls the shared workflow, `terraform-ci-cd-default.yml` in a project repo or `terraform-module-ci.yaml` in a module repo (`_dsb_tf_tflint_workflow_version`), the highest when there are several; else, or for `latest`, the latest release. When the latest release cannot be looked up, the newest version in the cache is used.
- **Install** (`_dsb_tf_tflint_install`): once per user and version, into `${XDG_CACHE_HOME:-~/.cache}/dsb-tf-proj-helpers/tflint/<version>/tflint`. The release archive for the platform (linux or darwin, amd64 or arm64) and the release's `checksums.txt` are downloaded with gh when authenticated, else with curl. The archive is refused when its sha256 does not match. No `.gitignore` is edited.
- `tf-clean-tflint` removes the `.tflint/` directories the wrapper left behind.

### `_terraform-state`

`envs/_terraform-state` bootstraps the state storage of every environment. It is not an environment: one directory serves every environment, its backend is partial and completed per environment, its values per environment are in `env.<env>.tfvars`, and it has no subscription hint. Environment enumeration leaves out directories starting with `_` for that reason, and that stays. Linting and validating it need neither a backend nor a subscription, so `tf-init-tfstate-offline`, `tf-validate-tfstate` and `tf-lint-tfstate` work on it offline (`terraform init -backend=false -input=false`), moving aside the backend state a real init left in `.terraform/terraform.tfstate` and putting it back after. `tf-validate-all` and `tf-lint-all` include it. Plan and apply of it stay the terraform commands in its README.

---

## Function Categories

### Exposed functions (86, prefixed `tf-` and `az-`)

User-facing commands. Every exposed function includes the `set -e` neutralization guard and the configure/restore lifecycle.

**Project commands** (available in project repos only):

| Group | Commands |
|---|---|
| Environment | `tf-list-envs`, `tf-set-env`, `tf-select-env`, `tf-clear-env`, `tf-unset-env`, `tf-check-env` |
| Terraform (env) | `tf-init-env`, `tf-init-env-offline`, `tf-init-all`, `tf-init-all-offline`, `tf-init-main`, `tf-init-modules` |
| Terraform (ops) | `tf-plan`, `tf-apply`, `tf-destroy` |
| Upgrade (env) | `tf-upgrade-env`, `tf-upgrade-env-offline`, `tf-upgrade-all`, `tf-upgrade-all-offline` |
| Lock (env) | `tf-lock-env`, `tf-lock-env-offline`, `tf-lock-all`, `tf-lock-all-offline` |
| Bump (env) | `tf-bump-env`, `tf-bump-env-offline`, `tf-bump-all`, `tf-bump-all-offline` |
| Provider (env) | `tf-show-all-provider-upgrades` |
| `_terraform-state` | `tf-init-tfstate-offline`, `tf-validate-tfstate`, `tf-lint-tfstate` |

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
| Linting | `tf-lint`, `tf-lint-all` (see [Linting](#linting)) |
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
| `unzip` | To install tflint | checked by `_dsb_tf_tflint_install` |
| `sha256sum` / `shasum` | To verify the tflint download | `_dsb_tf_sha256` |
| `realpath` / `grealpath` | Yes | `_dsb_tf_check_realpath` |
| `terraform-docs` | Module repos only | `_dsb_tf_check_terraform_docs` |

tflint is not a prerequisite: the lint commands install the version they need into a per-user cache, see [Linting](#linting).

---

## Script Sections (file layout)

| Lines | Section |
|---|---|
| 1-10 | Download guard, bash version check |
| 91-157 | Init: cleanup of previous state |
| 158-210 | Init: global variable declarations |
| 211-300 | Utility: logging |
| 301-328 | Init: architecture detection |
| 329-560 | Utility: general (`_dsb_tf_report_status`, etc.) |
| 561-724 | Utility: debug |
| 725-829 | Utility: error handling (error stack, signal handler, configure/restore) |
| 830-880 | Utility: `--log` output capture |
| 881-2373 | Utility: help system |
| 2374-2858 | Utility: tab completion |
| 2859-3041 | Utility: version parsing |
| 3042-3756 | Internal: checks |
| 3757-3788 | Internal: repo type gating |
| 3789-4481 | Internal: directory enumeration (includes repo type detection) |
| 4482-4734 | Internal: environment management |
| 4735-5209 | Internal: Azure CLI |
| 5210-6292 | Internal: terraform operations |
| 6293-7492 | Internal: linting (tflint install, default config, lint contract) |
| 7493-7654 | Internal: `_terraform-state` |
| 7655-7850 | Internal: clean |
| 7851-9433 | Internal: upgrade/bump |
| 9434-9783 | Internal: module repo operations |
| 9784-10037 | Internal: module examples support |
| 10038-10419 | Internal: terraform test support |
| 10420-10540 | Internal: documentation generation |
| 10541-10943 | Internal: version information |
| 10944-11178 | Internal: setup/install management |
| 11179-13014 | Exposed functions |
| 13015-13047 | Init: final setup |
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
- **Tests**: 801 across 36 files
- **Mocking**: All external tools mocked via function overrides
- **CI**: GitHub Actions on PRs, posts updatable comment with results

---

## File Inventory

| File | Purpose |
|---|---|
| `dsb-tf-proj-helpers.sh` | The script (~13000 lines, ~300 functions) |
| [README.md](README.md) | User-facing: how to load and use |
| [ARCHITECTURE.md](ARCHITECTURE.md) | This document |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Developer guide: patterns, conventions, how to add features |
| [TESTING.md](TESTING.md) | Test suite guide: how to run, write, and maintain tests |
| `package.json` | npm manifest for test dependencies |
| `.github/workflows/tests.yml` | CI workflow for running tests on PRs |
| `test/` | Test suite (36 `.bats` files, helpers, fixtures) |
