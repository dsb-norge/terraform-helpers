# terraform-helpers

Collection of helper scripts for terraform projects.

## `dsb-tf-proj-helpers.sh`

### Overview
`dsb-tf-proj-helpers.sh` is a collection of helper scripts designed to streamline and automate various tasks in Terraform projects. The script includes a variety of functions categorized into exposed, internal, and utility functions.

### How to use `dsb-tf-proj-helpers.sh`

```bash
# load with GitHub cli
source <(gh api -H "Accept: application/vnd.github.v3.raw" /repos/dsb-norge/terraform-helpers/contents/dsb-tf-proj-helpers.sh) ;

# load with curl
source <(curl -s https://raw.githubusercontent.com/dsb-norge/terraform-helpers/refs/heads/key-bonobo/dsb-tf-proj-helpers.sh) ;

```

### Develop `dsb-tf-proj-helpers.sh`

- Controlled by variables:
  - `_dsbTfLogInfo`
  - `_dsbTfLogWarnings`
  - `_dsbTfLogErrors`

#### Debug logging 

- Enable: `_dsb_tf_debug_enable_debug_logging`
- Disable: `_dsb_tf_debug_disable_debug_logging`

#### Other functionality for development 

- **Install Call Graph**: `_dsb_tf_debug_install_call_graph_and_deps_ubuntu`
- **Generate Call Graphs**:
  - For all functions: `_dsb_tf_debug_generate_call_graphs`
  - For a single function: `_dsb_tf_debug_generate_call_graphs '_dsb_tf_enumerate_directories'`

