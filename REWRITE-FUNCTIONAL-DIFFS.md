# Rewrite Functional Differences

This document lists observable behavioral changes from the error handling rewrite (Design D: Direct Return with Structured Error Context).

## Changes to error output format

### Before (ERR trap)
When an unexpected error occurred inside an internal function, the ERR trap would fire and produce output like:
```
ERROR  : Error occurred (execution continues):
ERROR  :   file      : dsb-tf-proj-helpers.sh
ERROR  :   line      : 1234 (dsb-tf-proj-helpers.sh:1234)
ERROR  :   function  : _dsb_tf_some_function
ERROR  :   command   : some_command --flag
ERROR  :   exit code : 1
ERROR  : Call stack:
ERROR  :   _dsb_tf_some_function called at (dsb-tf-proj-helpers.sh:5678)
ERROR  :   tf-some-command called at (dsb-tf-proj-helpers.sh:9012)
```

### After (error context stack)
When a function detects an error and pushes to the error stack, exposed functions now produce:
```
ERROR  : Error context:
ERROR  :   _dsb_tf_inner_function: specific error message
ERROR  :   _dsb_tf_outer_function: higher-level context message
```

Key differences:
- **No automatic `BASH_COMMAND` or `BASH_LINENO` information.** The error stack contains human-written messages, not raw shell metadata. This means the output is more readable but less precise for debugging unexpected failures.
- **No automatic catching of unexpected errors.** The old ERR trap caught any command that returned non-zero. The new design only reports errors at points where `_dsb_tf_error_push` is explicitly called. If a developer forgets to add error handling for a failure path, it may propagate silently.
- **Error context accumulates.** Multiple levels of the call chain can each add context, producing a trace-like output that shows how the error propagated.

## Changes to shell state during execution

### Before
- `set -Eo pipefail` was active during function execution
- ERR trap was installed
- `_dsbTfInErrorHandler` guard variable existed

### After
- Only `set -u` is active during function execution
- No ERR trap is installed
- Only SIGHUP/SIGINT signal traps are installed
- `_dsbTfInErrorHandler` variable no longer exists

This means:
- **Pipeline failures are no longer automatically caught.** With `pipefail` previously active, a failure in any stage of a pipeline would be caught by the ERR trap. Now, pipeline failures are only caught if the calling code explicitly checks the return code.
- **Subshell failures in command substitution are no longer caught.** The old `set -E` propagated the ERR trap into subshells. This is no longer the case.

## Changes to exposed function behavior

### set -e neutralization
All exposed functions now include a guard that neutralizes `set -e` if active:
```bash
if [[ "${-}" == *e* ]]; then set +e; tf-command "$@"; local rc=$?; set -e; return "${rc}"; fi
```
This prevents failures in bats tests and CI pipelines that have `set -e` active. Previously, this was not needed because the ERR trap handled error propagation. This is an improvement in robustness.

## Bug fixes included in this rewrite

### B1: String concatenation in _dsb_tf_bump_an_env
`_dsbTfReturnCode+=$((initStatus + listStatus))` used string concatenation instead of arithmetic. Fixed by removing the global variable entirely.

### B2: Dead code in _dsb_tf_bump_the_project
Unreachable code after `return 0` in the `_dsb_tf_set_env` failure block. Removed.

### B3: _dsb_tf_check_env always returning 0
`_dsb_tf_az_set_sub` used `if ! _dsb_tf_check_env` which never triggered because `_dsb_tf_check_env` always returned 0. Fixed: `_dsb_tf_check_env` now returns directly.

### B4: _dsb_tf_check_gh_auth missing return 0
Added explicit `return 0` at the end of the function.

### B5: _dsb_d leaks caller variable
Added `local` to the `caller` variable in `_dsb_d`.

### B6: tf-check-gh-auth missing exposed function
Added the `tf-check-gh-auth` exposed function.

### I4: _dsb_tf_install_tflint_wrapper using _dsb_e for internal error
Changed to use `_dsb_internal_error` so the error is always visible and pushed to the error stack.

## New functions

| Function | Purpose |
|---|---|
| `_dsb_tf_error_push` | Push error message to the context stack |
| `_dsb_tf_error_clear` | Clear the error context stack |
| `_dsb_tf_error_dump` | Display and clear the error context stack |
| `tf-check-gh-auth` | Exposed function to check GitHub authentication (B6 fix) |

## Removed functions

| Function | Reason |
|---|---|
| `_dsb_tf_error_handler` | ERR trap handler no longer needed |
| `_dsb_tf_error_start_trapping` | No ERR trap to manage |
| `_dsb_tf_error_stop_trapping` | No ERR trap to manage |
| `_dsb_ie_raise_error` | Trampoline no longer needed |

## Removed variables

| Variable | Reason |
|---|---|
| `_dsbTfReturnCode` | Replaced by direct return codes |
| `_dsbTfInErrorHandler` | ERR trap handler guard no longer needed |
