# terraform-helpers

Collection of helper scripts for Terraform projects and module repos.

## `dsb-tf-proj-helpers.sh`

### Overview

`dsb-tf-proj-helpers.sh` is a collection of helper functions designed to streamline and automate various tasks in Terraform projects and module repositories. The script provides 86 user-facing commands and automatically detects whether it's running in a project repo or a module repo, adapting its behavior accordingly.

Features include:
- **Project repos**: Environment management, terraform init/validate/plan/apply, version bumping, linting (also of `envs/_terraform-state`), Azure CLI integration
- **Module repos**: Init/validate/lint at root and per-example, terraform test support (unit and integration), documentation generation, version bumping
- Built-in help system (`tf-help`)
- Tab completion for all commands
- Structured error diagnostics

### How to use

```bash
# Load authenticated with GitHub CLI
source <(gh api -H "Accept: application/vnd.github.v3.raw" /repos/dsb-norge/terraform-helpers/contents/dsb-tf-proj-helpers.sh) ;

# Load from public endpoint with curl
#   note: has the potential of the user being rate limited by GitHub
source <(curl -s https://raw.githubusercontent.com/dsb-norge/terraform-helpers/main/dsb-tf-proj-helpers.sh) ;

# Invoke the help function
tf-help

# Or start with the status function, this checks some prerequisites
tf-status
```

#### Note for AI agents

Some AI agents may have trouble with the `source <(...)` pattern because they are prevented from executing commands with process substitution. If you encounter issues with this, use this workaround to load the script:

```bash
# Load authenticated with GitHub CLI, workaround for AI agents
eval "$(gh api -H 'Accept: application/vnd.github.v3.raw' /repos/dsb-norge/terraform-helpers/contents/dsb-tf-proj-helpers.sh)"

# Load from public endpoint with curl, workaround for AI agents
eval "$(curl -s https://raw.githubusercontent.com/dsb-norge/terraform-helpers/main/dsb-tf-proj-helpers.sh)"
```

### Supported repo types

The script detects the repo type automatically:

- **Project repo** (has `main/` and `envs/` directories): Full functionality -- environment management, terraform operations, Azure subscription management, version bumping
- **Module repo** (has root `.tf` files, no `main/` or `envs/`): Module-specific commands -- init/validate/lint at root and per-example, terraform testing, documentation generation, version bumping

Run `tf-help` after loading to see commands available for your repo type.

### Linting

The lint commands follow the same lint contract as CI, so linting locally gives the result CI gives. The contract is written down in [github-actions-terraform: docs/Linting.md](https://github.com/dsb-norge/github-actions-terraform/blob/main/docs/Linting.md). In short:

- **Directories**: the root being linted (an environment, `envs/_terraform-state`, a module repo's root or an example), then every local module directory in the root's `.terraform/modules/modules.json`, each linted on its own. Remote modules are not linted.
- **Preparation**: none for the root, which must be initialized when it calls modules (`tf-init-env-offline <env>`, `tf-init`, `tf-init-example <example>`). Each module directory is linted against a manifest derived from the root's, in a temporary `TF_DATA_DIR`, so it sees exactly the modules the root installed. Nothing is written into the repository.
- **Config**: `<root>/.tflint.hcl`, else the repository root's `.tflint.hcl`. An example always uses the module root's. When there is none, the default config is written into the root (never into a project repo's root), with its plugins bumped to their latest versions; review it and commit it.
- **Var files**: the root is linted once per `*.tfvars` in it other than `terraform.tfvars` and `*.auto.tfvars`, which tflint reads itself. Module directories never get var files.
- **tflint version**: the `tflint-version` of the GitHub workflow that calls the shared terraform workflow, the latest release when it is `latest` or not set. `--use-version <version>` overrides it.

tflint is installed once per user and version into `${XDG_CACHE_HOME:-~/.cache}/dsb-tf-proj-helpers/tflint/<version>/`, and the download is verified against the release's `checksums.txt`. Installing needs `unzip`.

| Repo type | Command | Lints |
|---|---|---|
| project | `tf-lint [env]` | the environment and its local module directories |
| project | `tf-lint-tfstate` | `envs/_terraform-state`, once per `env.<env>.tfvars`, initialized offline when needed |
| project | `tf-lint-all` | every environment, and `envs/_terraform-state` |
| module | `tf-lint` | the module root and its sub-modules |
| module | `tf-lint-example <example>`, `tf-lint-all-examples` | each example and the local module directories inside it |
| module | `tf-lint-all` | the module root and its sub-modules, then every example |

`envs/_terraform-state` is not an environment, as one directory serves every environment, so the environment commands leave it out. `tf-validate-tfstate` validates it and `tf-init-tfstate-offline` initializes it without backend, neither needing an Azure subscription; `tf-validate-all` includes it. Plan and apply of it stay the terraform commands in its README.

### Develop

See [CONTRIBUTING.md](CONTRIBUTING.md) for the developer guide, [ARCHITECTURE.md](ARCHITECTURE.md) for the design reference, and [TESTING.md](TESTING.md) for how to run and write tests.

#### Logging

Logging throughout the functions is controlled by the following variables:

- `_dsbTfLogInfo` : 1 to log info, 0 to mute
- `_dsbTfLogWarnings` : 1 to log warnings, 0 to mute
- `_dsbTfLogErrors` : 1 to log errors, 0 to mute
    note: `_dsb_internal_error()` ignores this setting

##### Debug logging

Off by default. Controlled from the command line:

- Enable: `_dsb_tf_debug_enable_debug_logging`
- Disable: `_dsb_tf_debug_disable_debug_logging`

#### Call graphs

To visualize function call chains, call graphs can be generated:

- Install callGraph and dependencies: `_dsb_tf_debug_install_call_graph_and_deps_ubuntu`
- Generate call graphs:
  - For all exposed functions: `_dsb_tf_debug_generate_call_graphs`
  - For a single internal function: `_dsb_tf_debug_generate_call_graphs '_dsb_tf_enumerate_directories'`
