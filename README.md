# terraform-helpers

Collection of helper scripts for terraform projects.

## `dsb-tf-proj-helpers.sh`

### Overview

`dsb-tf-proj-helpers.sh` is a collection of helper functions designed to streamline and automate various tasks in Terraform projects. The script includes a variety of functions and comes with a built-in help function to provide information on how to use each function.

### How to use `dsb-tf-proj-helpers.sh`

```bash
# load authenticated with GitHub cli
source <(gh api -H "Accept: application/vnd.github.v3.raw" /repos/dsb-norge/terraform-helpers/contents/dsb-tf-proj-helpers.sh) ;

# load from public endpoint with curl
#   note: has the potential of the user being rate limited by GitHub
source <(curl -s https://raw.githubusercontent.com/dsb-norge/terraform-helpers/blob/main/dsb-tf-proj-helpers.sh) ;

# invoke the help function
tf-help

# or start with the status function, this checks some prerequisites
tf-status
```

### Develop `dsb-tf-proj-helpers.sh`

#### Logging

Logging throughout the functions is controlled by the following variables:

- `_dsbTfLogInfo` : 1 to log info, 0 to mute
- `_dsbTfLogWarnings` : 1 to log warnings, 0 to mute
- `_dsbTfLogErrors` : 1 to log errors, 0 to mute
    note: _dsb_internal_error() ignores this setting

##### Debug logging

Is default off and can be controlled between invocations from the command line by calling the following functions. For local debugging, these can also be called from the code directly.

- Enable: `_dsb_tf_debug_enable_debug_logging`
- Disable: `_dsb_tf_debug_disable_debug_logging`

#### Other functionality for development

To have a look into what functions call which, call graphs can be generated. The following functions have been created to facilitate this:

- Install Call Graph and dependencies: `_dsb_tf_debug_install_call_graph_and_deps_ubuntu`
- Generate Call Graphs:
  - For all "exposed" functions: `_dsb_tf_debug_generate_call_graphs`
  - For a single internal function: `_dsb_tf_debug_generate_call_graphs '_dsb_tf_enumerate_directories'`
