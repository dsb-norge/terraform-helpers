<!--
  Scaffolded by https://github.com/dsb-infra/.github-private — customize freely.
  This file is NOT overwritten by the auto-generate script. It is yours to maintain.

  Read by: Claude Code, VS Code Copilot, GitHub.com Coding Agent.
  Purpose: Project-specific instructions that complement the auto-generated .claude/CLAUDE.md.
  Only add content here that is NOT already covered by README.md.
-->

# Project-Specific Instructions

## What this is

A single bash script (`dsb-tf-proj-helpers.sh`, ~10900 lines) sourced into the user's interactive shell. It provides ~79 `tf-*` and `az-*` commands for Terraform project and module development. **It must never crash or corrupt the user's shell.**

## Key documentation

- [ARCHITECTURE.md](ARCHITECTURE.md) — design, lifecycle, function catalog, file layout
- [CONTRIBUTING.md](CONTRIBUTING.md) — coding patterns, error handling, how to add commands
- [TESTING.md](TESTING.md) — test framework, mocking, fixtures, how to write tests

Read CONTRIBUTING.md before making any code changes.

## Critical constraints

- **No `set -e`, no ERR trap, no `pipefail` during execution.** All error handling is explicit. See CONTRIBUTING.md "Error Handling" section.
- **Every exposed function** must have: `set -e` neutralization guard, `_dsb_tf_configure_shell`/`_dsb_tf_restore_shell` lifecycle, `_dsb_tf_error_dump` on failure.
- **Every `return 1`** in internal functions must be preceded by `_dsb_tf_error_push "message"`.
- **Pipelines** (`cmd | filter`): use `PIPESTATUS[0]` to check the left side's exit code. Never `if ! cmd | filter`.
- **Source-time init code**: every command that can fail must use `|| :` fallback. This is load-bearing for `set -e` callers.
- **The `{ }` download guard** wrapping the entire file prevents partial-download execution. Do not remove.
- **Lock files in module repos are gitignored.** Never check for their existence as a prerequisite.

## Repo type detection

The script detects project repos (`main/` + `envs/`) vs module repos (root `.tf` files, no `main/`/`envs/`). Branch behavior at the exposed function level using `_dsbTfRepoType`. Use `_dsb_tf_require_project_repo` or `_dsb_tf_require_module_repo` for gating.

## Testing

```bash
npm install    # install bats-core
npm test       # run 570 tests with parallel execution
```

All external tools are mocked. Tests run without az, gh, terraform, etc. installed. Use TDD when possible — write failing test first, then implement. Run full suite after every change.

## Adding a new command (checklist)

1. Internal function: direct return + `_dsb_tf_error_push` on failure
2. Exposed function: neutralization guard + configure/restore + error_dump
3. Repo-type gating if needed
4. Help: `_dsb_tf_help_get_commands_supported_by_help` + `_dsb_tf_help_specific_command` + group function
5. Tab completion if it takes arguments
6. Tests in appropriate `.bats` file
7. `npm test` — all must pass

## Naming conventions

| Type | Pattern | Example |
|---|---|---|
| Exposed functions | `tf-*`, `az-*` | `tf-init`, `az-login` |
| Internal functions | `_dsb_tf_*` | `_dsb_tf_init_module_root` |
| Utility functions | `_dsb_*` | `_dsb_e`, `_dsb_tf_error_push` |
| Global variables | `_dsbTf*` | `_dsbTfSelectedEnv` |

## Do not

- Use `exit` anywhere (kills the user's shell). Use `return`.
- Use `set -e` or ERR traps. Handle errors explicitly.
- Add bare commands to source-time init code without `|| :`.
- Use `[[ -v associative_array ]]` — it doesn't work in bash. Use `declare -p ... &>/dev/null`.
- Forget to update help entries when adding/renaming commands.
- Commit changes without running `npm test`.
