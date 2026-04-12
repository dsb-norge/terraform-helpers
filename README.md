# terraform-helpers

Collection of helper scripts for Terraform projects and module repos.

## `dsb-tf-proj-helpers.sh`

### Overview

`dsb-tf-proj-helpers.sh` is a collection of helper functions designed to streamline and automate various tasks in Terraform projects and module repositories. The script provides 63 user-facing commands and automatically detects whether it's running in a project repo or a module repo, adapting its behavior accordingly.

Features include:
- **Project repos**: Environment management, terraform init/validate/plan/apply, version bumping, linting, Azure CLI integration
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
