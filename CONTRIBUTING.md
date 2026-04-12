# Contributing to dsb-tf-proj-helpers.sh

Developer guide for maintaining and extending the script. Read [ARCHITECTURE.md](ARCHITECTURE.md) first for the big picture.

---

## Getting Started

```bash
# Clone the repo
git clone https://github.com/dsb-norge/terraform-helpers.git
cd terraform-helpers

# Install test dependencies
npm install

# Run the test suite (with parallel execution)
npm test

# Or run directly (sequential)
npx bats test/*.bats

# Run a specific test file
npx bats test/04_version_parsing.bats
```

See [TESTING.md](TESTING.md) for the full testing guide.

---

## Code Organization

The script is a single file (`dsb-tf-proj-helpers.sh`, ~8800 lines, ~215 functions) organized in a strict top-to-bottom dependency order:

1. Download guard and bash version check
2. Cleanup of previous state
3. Global variable declarations
4. Utility functions (logging, debug, error handling, help, completion, version parsing)
5. Internal functions (checks, directory enumeration, environments, Azure CLI, terraform ops, linting, clean, upgrades, module examples, testing, documentation)
6. Exposed functions (all `tf-*` and `az-*` commands)
7. Final initialization

Functions are defined before they're called. The exposed functions section near the end calls internal functions defined earlier. See [ARCHITECTURE.md](ARCHITECTURE.md) for the complete section-by-line map.

---

## Function Types

### Exposed functions (`tf-*`, `az-*`)

User-facing commands. Every exposed function follows this template:

```bash
tf-my-command() {
  if [[ "${-}" == *e* ]]; then set +e; tf-my-command "$@"; local rc=$?; set -e; return "${rc}"; fi

  local myArg="${1:-}"
  _dsb_tf_configure_shell

  _dsb_tf_my_internal_function "${myArg}"
  local returnCode=$?

  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi

  _dsb_tf_restore_shell
  return "${returnCode}"
}
```

Rules:
- **Always include the `set -e` neutralization guard** as the very first line.
- **Capture arguments before `_dsb_tf_configure_shell`** (since `set -u` becomes active after).
- **Call `_dsb_tf_error_dump`** when the return code is non-zero.
- **Return the exit code directly.**

### Internal functions (`_dsb_tf_*`)

The implementation layer. All return exit codes directly (`return 0` / `return 1`). On failure, push context to the error stack:

```bash
_dsb_tf_my_function() {
  if [ -z "${someInput}" ]; then
    _dsb_e "Input is empty."
    _dsb_tf_error_push "input is empty"
    return 1
  fi

  if ! _dsb_tf_other_function "${someInput}"; then
    _dsb_tf_error_push "other function failed for '${someInput}'"
    return 1
  fi

  return 0
}
```

### Utility functions (`_dsb_*`)

Cross-cutting: logging, error stack, shell configuration. Generally don't return explicit exit codes.

---

## Error Handling

### Design

All functions return exit codes directly. There is no ERR trap, no `set -e`, no global return code variable.

A **global error context stack** (`_dsbTfErrorStack`) accumulates messages as errors propagate. Each function pushes its own context before returning non-zero. The exposed function dumps the stack to the user. Example output:

```
ERROR  : Error context:
ERROR  :   _dsb_tf_look_for_env: environment 'staging' not found in /project/envs
ERROR  :   _dsb_tf_check_env: environment check failed for 'staging'
```

### Error context stack

| Function | Purpose |
|---|---|
| `_dsb_tf_error_push "message"` | Push message. Caller name recorded automatically. |
| `_dsb_tf_error_clear` | Clear stack. Called by `_dsb_tf_configure_shell`. |
| `_dsb_tf_error_dump` | Print stack via `_dsb_e`, then clear. Called by exposed functions on failure. |

### `_dsb_internal_error`

For invariant violations (programming errors). Logs via `_dsb_ie` (always visible, cannot be muted) and pushes to the error stack. **Does not return** -- the caller must add `return 1` after:

```bash
if [ -z "${expectedVar:-}" ]; then
  _dsb_internal_error "expected variable was empty"
  return 1  # required!
fi
```

### Shell state guarantee

`_dsb_tf_configure_shell` establishes a known state:

| Setting | State | Why |
|---|---|---|
| `set -e` | Off | Errors handled explicitly |
| `set -E` | Off | No ERR trap |
| `pipefail` | Off | Pipe failures checked via `PIPESTATUS` |
| ERR trap | None | No automatic error catching |
| `set -u` | On | Catches unset variable bugs |
| SIGHUP/SIGINT | Trapped | Restores shell on Ctrl+C |

`_dsb_tf_restore_shell` restores the caller's original state exactly.

---

## Repo Type Detection

The script supports two repo types:
- **Project repos**: Have `main/` and `envs/` directories
- **Module repos**: Have root `.tf` files, no `main/` or `envs/`

Detection runs in `_dsb_tf_enumerate_directories`. The result is stored in `_dsbTfRepoType` (`"project"`, `"module"`, or `""`).

### Gating commands by repo type

```bash
# For project-only commands:
if ! _dsb_tf_require_project_repo; then return 1; fi

# For module-only commands:
if ! _dsb_tf_require_module_repo; then return 1; fi
```

### Branching behavior by repo type

When a command works differently per repo type, branch at the exposed function level:

```bash
tf-init() {
  # ... neutralization, configure_shell ...
  if [ "${_dsbTfRepoType}" == "module" ]; then
    _dsb_tf_init_module_root
  else
    _dsb_tf_init_full_single_env 0 0 "${envName}"
  fi
  # ... error_dump, restore_shell ...
}
```

Keep project and module internal functions separate. Don't interleave `if module then ... else ...` deep in call chains.

---

## Pipeline Safety

When piping command output through a filter, the pipeline exit code is the **last** command's code. Use `PIPESTATUS` to check the left side:

```bash
# WRONG -- terraform failure masked by filter:
if ! terraform ... 2>&1 | _dsb_tf_fixup_paths_from_stdin; then

# CORRECT:
terraform ... 2>&1 | _dsb_tf_fixup_paths_from_stdin
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
```

`PIPESTATUS` must be read **immediately** after the pipeline -- any command in between overwrites it.

---

## Source-Time Safety

The init code at the top and bottom of the script runs before any exposed function's protections are active. If the caller has `set -e`, any failure aborts sourcing silently.

**Every command in init code that could fail must use `|| :` or `|| var=''`.**

This is load-bearing. There is a test for it (`01_source_init.bats`: "sourcing succeeds even when caller has set -e active").

---

## Inline Log Suppression

Suppress logging for a specific call:

```bash
_dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
# shellcheck disable=SC2181 # inline var assignment requires $?
if [ $? -ne 0 ]; then
```

The `if !` idiom cannot be combined with inline variable assignment -- hence the `$?` pattern with the shellcheck disable comment.

---

## Naming Conventions

| Type | Convention | Example |
|---|---|---|
| Exposed functions | `tf-*`, `az-*` | `tf-init`, `az-login` |
| Internal functions | `_dsb_tf_*` | `_dsb_tf_init_module_root` |
| Utility functions | `_dsb_*` | `_dsb_e`, `_dsb_tf_error_push` |
| Persistent globals | `_dsbTf*` (camelCase) | `_dsbTfSelectedEnv` |
| Lifecycle globals | `_dsbTf*` (cleared by restore_shell) | `_dsbTfLogInfo` |
| Config env vars | `ARM_SUBSCRIPTION_ID` | (exported for terraform) |

---

## Adding a New Command

1. **Decide the scope**: common, project-only, or module-only.
2. **Write the internal function** following the direct-return + error-push pattern.
3. **Write the exposed function** following the template (neutralization, configure/restore, error dump).
4. **Add repo-type gating** if needed (`_dsb_tf_require_project_repo` or `_dsb_tf_require_module_repo`).
5. **Add help text**: entry in `_dsb_tf_help_specific_command`, add to the relevant group function, add to `_dsb_tf_help_get_commands_supported_by_help`.
6. **Add tab completion** if the command takes arguments.
7. **Write tests** in the appropriate `.bats` file.
8. **Run the full suite**: `npx bats test/*.bats`.

---

## Adding a New External Tool Dependency

1. Add `_dsb_tf_check_<tool>` function (follows the existing pattern).
2. Add to `_dsb_tf_check_tools` -- decide if it's always checked or conditional on repo type.
3. Add mock to `test/helpers/mock_helper.bash` (`mock_<tool>` and `mock_<tool>_not_installed`).
4. Add to `mock_standard_tools` and `unmock_all` in the mock helper.
5. Write tests for the check function in `test/05_tool_checks.bats`.

---

## Documentation

| Document | Purpose |
|---|---|
| [README.md](README.md) | User-facing: how to load and use |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Design reference: structure, lifecycle, globals, sections |
| [CONTRIBUTING.md](CONTRIBUTING.md) | This document: developer guide |
| [TESTING.md](TESTING.md) | Test suite: how to run, write, and maintain tests |

---

## Caveats

- **`_dsb_tf_error_push` is manual.** If you forget it at a failure point, the error stack has a gap. Audit every `return 1` path.
- **`_dsb_internal_error` does not return.** Always pair with `return 1`.
- **`set -u` is active.** Use `${var:-}` for potentially unset variables.
- **No `set -e`, no `pipefail`.** Every command that can fail must be checked explicitly.
- **`PIPESTATUS` is ephemeral.** Read it immediately after the pipeline.
- **The download guard (`{ }` braces) is structural.** Don't remove them.
- **Lock files in module repos are gitignored.** Never check for their existence as a prerequisite. `tf-init` creates them, `tf-clean` deletes them.
