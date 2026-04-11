# Developer Guide: Error Handling in dsb-tf-proj-helpers.sh

## Overview

All functions return their exit code directly via `return 0` (success) or `return 1` (failure). There is no ERR trap and no global return code variable.

A global **error context stack** provides rich diagnostics. When an error occurs deep in the call chain, each function pushes context as the error propagates upward. The exposed function dumps the stack to the user before returning.

## Shell State Guarantee

`_dsb_tf_configure_shell` establishes a known, predictable shell state before any internal code runs:

| Setting | State | Why |
|---|---|---|
| `set -e` (errexit) | **Off** | We handle errors explicitly with `if !` and `$?` |
| `set -E` (errtrace) | **Off** | No ERR trap to inherit |
| `pipefail` | **Off** | Pipe failures are checked explicitly where needed |
| ERR trap | **None** | No automatic error catching |
| `set -u` (nounset) | **On** | Catches unset variable bugs immediately |
| SIGHUP/SIGINT traps | **Installed** | Restores the user's shell on Ctrl+C |

`_dsb_tf_restore_shell` restores the caller's original shell state exactly as it was, including any `set -e`, traps, or other options the caller had active.

The `set -e` neutralization guard on exposed functions is belt-and-suspenders: it handles the edge case where `set -e` is active *before* `_dsb_tf_configure_shell` gets a chance to disable it (since `set -e` could cause `shopt -o history` inside configure_shell to abort in non-interactive shells).

## Error Context Stack

Three utility functions manage the stack:

| Function | Purpose |
|---|---|
| `_dsb_tf_error_push "message"` | Push a message onto the stack. Caller name is recorded automatically. |
| `_dsb_tf_error_clear` | Clear the stack. Called automatically by `_dsb_tf_configure_shell`. |
| `_dsb_tf_error_dump` | Print the stack via `_dsb_e`, then clear it. Called by exposed functions on failure. |

The stack is a global indexed array: `_dsbTfErrorStack`.

When an error propagates through multiple layers, the stack accumulates context from each level, producing output like:

```
ERROR  : Error context:
ERROR  :   _dsb_tf_look_for_env: environment 'staging' not found in /project/envs
ERROR  :   _dsb_tf_check_env: environment check failed for 'staging'
ERROR  :   _dsb_tf_terraform_preflight: preflight failed for environment 'staging'
```

## Writing an Internal Function

```bash
_dsb_tf_my_function() {
  local someInput="${1:-}"

  if [ -z "${someInput}" ]; then
    _dsb_e "Input is empty."
    _dsb_tf_error_push "input is empty"
    return 1
  fi

  if ! _dsb_tf_some_other_function "${someInput}"; then
    _dsb_tf_error_push "other function failed for '${someInput}'"
    return 1
  fi

  return 0
}
```

**Rules:**

- **Always return directly.** `return 0` for success, `return 1` for failure. Never use a global variable to communicate status.
- **Push to the error stack at every failure point.** Call `_dsb_tf_error_push "message"` before every `return 1`. The message should describe what failed in this function's context.
- **Keep `_dsb_e` / `_dsb_w` logging alongside the push.** The error stack is for structured diagnostics; `_dsb_e` is for immediate user-visible output. Both serve different purposes.
- **When calling another internal function, propagate failure with context:**
  ```bash
  if ! _dsb_tf_inner "${arg}"; then
    _dsb_tf_error_push "inner operation failed for '${arg}'"
    return 1
  fi
  ```
  The inner function already pushed its own context. Your push adds the outer perspective.

## Writing an Exposed Function

```bash
tf-my-command() {
  # Neutralize caller's set -e
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

**Rules:**

- **Always include the `set -e` neutralization guard** as the very first line inside the function body.
- **Capture arguments before `_dsb_tf_configure_shell`** if they use `${1:-}` patterns (since `set -u` becomes active after configure).
- **Call `_dsb_tf_error_dump`** when the return code is non-zero, before `_dsb_tf_restore_shell`.
- **Return the exit code directly.**
- Exposed functions that never fail (like `tf-help`, `tf-clear-env`) don't need the error dump check.

## Using `_dsb_internal_error`

`_dsb_internal_error` is for **invariant violations** -- situations that indicate a programming error, not an operational failure. It:

1. Logs using `_dsb_ie` (always visible, cannot be muted by `_dsbTfLogErrors=0`).
2. Pushes each message to the error stack.
3. **Does NOT return.** The caller must add `return 1` after calling it.

```bash
if [ -z "${_dsbTfSelectedEnvDir:-}" ]; then
  _dsb_internal_error "expected to find selected environment directory" \
    "  expected in: _dsbTfSelectedEnvDir"
  return 1  # <-- required!
fi
```

Use this instead of `_dsb_e` when the error means something is wrong with the code itself, not with the user's input or environment.

## Inline Log Suppression

Callers can suppress logging for a specific call using bash's per-command variable assignment:

```bash
_dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
```

This suppresses `_dsb_i` and `_dsb_e` output from that function and its descendants. The suppression is scoped to that single command -- subsequent calls use the default logging levels.

Note: `_dsb_ie` (internal error logger) **ignores** the mute flag and always produces output. This is intentional -- invariant violations must always be visible.

Note: when using inline suppression, the return code must be checked with `$?` on the next line, since `if !` cannot be combined with inline variable assignment:

```bash
_dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
# shellcheck disable=SC2181 # inline var assignment requires $?
if [ $? -ne 0 ]; then
  _dsb_e "Directory check failed"
  return 1
fi
```

## Pipeline Safety (PIPESTATUS)

When piping a command's output through a filter (e.g. `terraform ... | _dsb_tf_fixup_paths_from_stdin`), the pipeline exit code is the exit code of the **last** command in the pipe. Since `_dsb_tf_fixup_paths_from_stdin` always succeeds (it just reads stdin), a failing `terraform` command would be silently swallowed.

**Never use `if !` with a pipeline where the left side's exit code matters.** Instead, use `PIPESTATUS`:

```bash
# WRONG -- pipeline masks terraform's exit code:
if ! terraform ... 2>&1 | _dsb_tf_fixup_paths_from_stdin; then

# CORRECT -- check PIPESTATUS[0] for the left side:
terraform ... 2>&1 | _dsb_tf_fixup_paths_from_stdin
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
  # handle failure
fi
```

`PIPESTATUS` is a bash array that holds the exit codes of all commands in the most recently executed foreground pipeline. `PIPESTATUS[0]` is the first command (terraform), `PIPESTATUS[1]` is the second (the filter), etc. It must be read **immediately** after the pipeline -- any intervening command overwrites it.

This pattern is used in all 6 pipeline sites where terraform/tflint output is piped through `_dsb_tf_fixup_paths_from_stdin`.

## Source-Time Initialization Safety

The init/cleanup code at the top and bottom of the script runs at **source time**, before any exposed function's `set -e` neutralization guard or `_dsb_tf_configure_shell` has a chance to run. If the caller has `set -e` active, any command failure in the init code will abort the sourcing silently.

**This defense is load-bearing and must be preserved in any future changes to init code.**

The specific defensive patterns used:
- `varNames=$(typeset -p | awk ...) || varNames=''` -- the `|| varNames=''` prevents `set -e` abort if the pipeline fails
- `functionNames=$(declare -F | grep ...) || functionNames=''` -- same pattern
- `completions=$( complete -p | grep ... | awk ... ) || completions=''` -- same pattern
- Architecture detection uses `[[ ]]` tests, which are conditionals and don't trigger `errexit`
- Final init uses `|| :` for safety: `_dsb_tf_enumerate_directories || :`

**Rules for init code:**
- Every command that could fail MUST use `|| :` or `|| varName=''`
- Never add bare commands to init code -- always add a failure fallback
- Test that sourcing works under `set -e` (there is a test for this in `01_source_init.bats`)

## File Operation Safety

File operations (`cp`, `rm`, `mv`) in critical paths must be checked for failure:

```bash
# WRONG -- if cp fails, terraform runs with stale/missing lock file:
cp -f "${src}" "${dst}"

# CORRECT -- check and propagate failure:
if ! cp -f "${src}" "${dst}"; then
  _dsb_tf_error_push "failed to copy lock file to ${dst}"
  return 1
fi
```

For cleanup operations where failure is non-critical, use `rm -f` (no error on missing file):

```bash
rm -f "${dirPath}/.terraform.lock.hcl"  # -f: no error if file doesn't exist
```

## Temp File Cleanup Pattern

Temp files should use a predictable naming pattern so they can be cleaned up on signal interruption:

```bash
# Use a predictable path with PID:
captureFile="/tmp/dsb-tf-helpers-$$-az-login"

# NOT this -- mktemp creates unpredictable names that can't be cleaned up:
captureFile="$(mktemp)"
```

`_dsb_tf_configure_shell` cleans up any leftover temp files matching the pattern on every invocation:
```bash
rm -f "/tmp/dsb-tf-helpers-$$-"* 2>/dev/null || :
```

This handles the case where a previous operation was interrupted by Ctrl+C before its cleanup code ran.

## Download Guard

The entire script body is wrapped in `{ ... }`:

```bash
#!/usr/bin/env bash
{ # this ensures the entire script is downloaded before execution
  # ... entire script ...
} # this ensures the entire script is downloaded before execution
```

Bash reads the entire `{ }` compound command before executing any of it. If the script is loaded from a network source (`source <(curl ...)`) and the download is truncated, the incomplete `{ }` produces a syntax error instead of executing a partial script.

**Do not remove the braces.** They are not decorative. They prevent a class of failures where partial downloads define some functions but leave the init code or other functions incomplete.

## Caveats

- **`_dsb_tf_error_push` is manual.** If you forget to push at a failure point, the error stack will be incomplete. The error is still reported via `_dsb_e`, but the structured trace will have a gap. When writing new code, audit every `return 1` path.
- **The error stack is cleared at the start of each exposed function** (via `_dsb_tf_configure_shell`). Stale errors from previous invocations cannot leak through.
- **`_dsb_internal_error` does not return.** If you forget `return 1` after it, execution will continue past the invariant check. This is a footgun -- always pair them.
- **`set -u` is active.** All variable references must use `${var:-}` or be guaranteed to be set. Unset variable access will abort the function immediately.
- **No `set -e`, no `pipefail`.** Failed commands do not automatically abort execution. Every command that can fail must be explicitly checked with `if !` or `$?`. This is the trade-off for predictable, explicit error handling.
- **`PIPESTATUS` is ephemeral.** It must be read immediately after the pipeline. Any command between the pipeline and the `PIPESTATUS` check will overwrite it.
