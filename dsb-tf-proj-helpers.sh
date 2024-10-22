#!/usr/bin/env bash

# enable debug logging  : _dsbTfLogDebug=1
# disable debug logging : unset _dsbTfLogDebug

# DEBUG commands
#   cd ~/code/github/dsb-norge/azure-ad ;
#   source <(cat ~/code/github/dsb-norge/terraform-helpers/dsb-tf-proj-helpers.sh) ;
#   source <(curl -s https://raw.githubusercontent.com/dsb-norge/terraform-helpers/refs/heads/key-bonobo/dsb-tf-proj-helpers.sh) ;
#   source <(gh api -H "Accept: application/vnd.github.v3.raw" /repos/dsb-norge/terraform-helpers/contents/dsb-tf-proj-helpers.sh?ref=key-bonobo) ;

# Implemented functionality
#   tf-check-tools      -> az cli, gh cli, terraform, jq, yq, golang, hcledit, terraform-docs, realpath
#   tf-check-gh-auth    -> need to be logged in to gh
#   tf-check-dir        -> check if in valid tf project structure
#   tf-check-prereqs    -> all checks
#   tf-list-envs        -> list existing envs (exclude _*)
#   tf-set-env [env]    -> set env/sub
#   tf-clear-env        -> unset env/sub
#   tf-select-env       -> list + select env/sub + set env/sub
#   tf-select-env [env] -> set env/sub ie. same as tf-set-env
#   tf-check-env        -> check if selected env is valid
#   tf-check-env [env]  -> check if supplied env is valid
#   az-logout           -> az logout
#   az-login            -> az login --use-device-code
#   az-relog            -> same as az-login
#   az-whoami           -> az account show
#   az-set-sub          -> az account set --subscription
#   tf-status           -> checks + help + show az upn if logged in + show sub if selected
#
#   other:
#     tab completion
#     require az sub hint file
#
#   help
#     tf-help                 -> show short help, will list most used commands and command groups
#     tf-help [group]         -> show help for command group
#     tf-help general         -> show general help
#     tf-help all             -> show all help
#     tf-help [command]       -> show help for command
#     tf-help help            -> show help for help
#
# TODO: functionality
#
# az
#   az-set-account  -> set az account
# tf operations
#   tf-init-env     -> terraform init in chosen env
#   tf-init-modules -> terraform init of submodules (requires env to be selected in advance)
#   tf-init         -> terraform init in chosen env + submodules
#   tf-fmt          -> terraform fmt -check in chosen env
#   tf-fmt-fix      -> terraform fmt in chosen env
#   tf-validate     -> terraform validate in chosen env
#   tf-plan         -> terraform plan in chosen env
#   tf-apply        -> terraform apply in chosen env
#   tf-clean        -> rm .terraform everywhere /home/peder/code/github/dsb-norge/terraform-tflint-wrappers/tf_clean.sh
#   tf-clean-all    -> rm .terraform everywhere + rm .tflint everywhere
#
# linting
#   tf-lint         -> tflint in chosen env, using tflint-wrapper, download and store locally? in root/.tflint ?
#   tf-lint-clean   -> rm .tflint everywhere
#
# upgrading
#  look into:
#   tfupdate :
#     install  : go install github.com/minamijoyo/tfupdate@latest
#     providers:
#       - read 'version' from lock file
#       - use tfupdate: tfupdate release latest --source-type tfregistryProvider 'hashicorp/azurerm'
#       - show possible upgrades
#     modules  :
#       - read 'source' from tf files
#       - use tfupdate: tfupdate release latest --source-type tfregistryModule "Azure/naming/azurerm"
#       - show possible upgrades
#     note: there is also a list command: fupdate release list --source-type tfregistryModule --max-length 3 "Azure/naming/azurerm"
#  proposed commands:
#   tf-bump-providers       -> upgrade within given constraints: terraform init -upgrade in chosen env
#   tf-bump-tflint-plugins  -> tflint-plugins in chosen env
#   tf-bump                 -> providers og tflint-plugins in chosen env
#   tf-bump-gh              -> terraform and tflint in GitHub workflows
#   tf-bump-all             -> providers og tflint-plugins in alle env + terraform and tflint in GitHub workflows
#
# TODO: future functionality
#
#   tf-test         -> terraform test in chosen env, use poc from lock module
#   tf-bump-modules -> upgrade modules in code everywhere
#   tf-* functions for _terraform-state env
#

###################################################################################################
#
# Remove any old code remnants
#
###################################################################################################

# variables starting with '_dsbTf'
varNames=$(typeset -p | awk '$3 ~ /^_dsbTf/ { sub(/=.*/, "", $3); print $3 }') || varNames=''
for varName in ${varNames}; do
  unset -v "${varName}" || :
done

# for functions
unsetFunctionsWithPrefix() {
  local prefix="${1}"
  local functionNames
  functionNames=$(declare -F | grep -e " ${prefix}" | cut --fields 3 --delimiter=' ') || functionNames=''
  for functionName in ${functionNames}; do
    unset -f "${functionName}" || :
  done
}

# functions with knonw prefixes
unsetFunctionsWithPrefix '_dsb_'
unsetFunctionsWithPrefix 'tf-'
unsetFunctionsWithPrefix 'az-'

# for tab completion
unsetCompletionsWithPrefix() {
  local prefix="${1}"
  local completions
  completions=$(
    complete -p |
      grep -o "complete -F [^ ]* ${prefix}[^ ]*" |
      awk '{print $NF}'
  ) || completions=''
  for completion in ${completions}; do
    complete -r "${completion}" || :
  done
}

# tab completion with known prefixes
unsetCompletionsWithPrefix 'tf-'
unsetCompletionsWithPrefix 'az-'

# cleanup the cleanup
unset -f unsetFunctionsWithPrefix unsetCompletionsWithPrefix
unset -v varNames varName

###################################################################################################
#
# Global variables
#
###################################################################################################

declare -g _dsbTfShellOldOpts=""
declare -g _dsbTfShellHistoryState=""

declare -g _dsbTfSelectedEnv=""
declare -g _dsbTfSelectedEnvDir=""
declare -g _dsbTfSelectedEnvLockFile=""
declare -g _dsbTfSelectedEnvSubscriptionHintFile=""
declare -g _dsbTfSelectedEnvSubscriptionHintContent=""
declare -gA _dsbTfEnvsDirList   # Associative array
declare -ga _dsbTfAvailableEnvs # Indexed array

declare -g _dsbTfModulesDir=""
declare -gA _dsbTfModulesDirList # Associative array

declare -g _dsbTfAzureUpn=""
declare -g _dsbTfSubscriptionId=""

###################################################################################################
#
# Utility functions
#
###################################################################################################

_dsb_err() {
  local logErr=${_dsbTfLogErrors:-1}
  if [ "${logErr}" == "1" ]; then
    echo -e "\e[31mERROR  : $1\e[0m"
  fi
}

_dsb_i_append() {
  local logInfo=${_dsbTfLogInfo:-1}
  local logText=${1:-}
  if [ "${logInfo}" == "1" ]; then
    echo -en "${logText}\n"
  fi
}

_dsb_i_nonewline() {
  local logInfo=${_dsbTfLogInfo:-1}
  local logText=${1:-}
  if [ "${logInfo}" == "1" ]; then
    echo -en "\e[34mINFO   : \e[0m${logText}"
  fi
}

_dsb_i() {
  local logText=${1:-}
  _dsb_i_nonewline "${logText}\n"
}

_dsb_w() {
  local logWarn=${_dsbTfLogWarnings:-1}
  if [ "${logWarn}" == "1" ]; then
    echo -e "\e[33mWARNING: $1\e[0m"
  fi
}

_dsb_d() {
  local logDebug=${_dsbTfLogDebug:-0}
  if [ "${logDebug}" == "1" ]; then
    echo -e "\e[35mDEBUG  : $1\e[0m"
  fi
}

_dsb_tf_get_rel_dir() {
  local dirName=$1
  realpath --relative-to="${_dsbTfRootDir}" "${dirName}"
}

_dsb_tf_get_github_cli_account() {
  local ghAccount
  ghAccount=$(gh auth status --hostname github.com | grep "Logged in to github.com account" | sed 's/.*Logged in to github.com account //' | awk '{print $1}')
  echo "${ghAccount}"
}

_dsb_tf_report_status() {
  _dsbTfLogInfo=0
  _dsbTfLogErrors=0
  _dsb_tf_error_stop_trapping

  _dsb_tf_check_prereqs
  local prereqStatus="${_dsbTfReturnCode}"

  local githubStatus=1
  local githubAccount="  ☐  Logged in to github.com as  : N/A, github cli not available, please run 'tf-check-tools'"
  if _dsbTfLogErrors=0 _dsb_tf_check_gh_cli; then
    githubAccount="  \e[32m☑\e[0m  Logged in to github.com as  : $(_dsb_tf_get_github_cli_account)"
    githubStatus=0
  fi

  local azureStatus=1
  local azureAccount="  ☐  Logged in to Azure as       : N/A, azure cli not available, please run 'tf-check-tools'"
  if _dsb_tf_check_az_cli; then
    if _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_az_enumerate_account; then
      local azUpn="${_dsbTfAzureUpn:-}"
      if [ -z "${azUpn}" ]; then
        _dsbTfLogErrors=1
        _dsb_err "Internal error: in _dsb_tf_report_status(): Azure UPN not found."
        _dsb_err "  expected in _dsbTfAzureUpn, which is: ${_dsbTfAzureUpn:-}"
        _dsb_err "  azUpn is: ${azUpn}"
        return 1
      fi
      local azSub="${_dsbTfSubscriptionId:-}"
      if [ -z "${azSub}" ]; then
        _dsbTfLogErrors=1
        _dsb_err "Internal error: in _dsb_tf_report_status(): Azure Subscription ID not found."
        _dsb_err "  expected in _dsbTfSubscriptionId, which is: ${_dsbTfSubscriptionId:-}"
        _dsb_err "  azSub is: ${azSub}"
        return 1
      fi
      azureAccount="  \e[32m☑\e[0m  Logged in to Azure as       : ${_dsbTfAzureUpn}"
      azureStatus=0
    else
      azureAccount="  \e[31m☒\e[0m  Logged in to Azure as       : N/A, please run 'az-whoami'"
    fi
  fi

  local modulesDir="${_dsbTfModulesDir:-}"

  local availableModulesCommaSeparated
  availableModulesCommaSeparated=$(_dsb_tf_get_module_names_commaseparated)

  local envsDir="${_dsbTfEnvsDir:-}"

  local availableEnvsCommaSeparated
  availableEnvsCommaSeparated=$(_dsb_tf_get_env_names_commaseparated)

  local selectedEnv="${_dsbTfSelectedEnv:-}"
  local selectedEnvDir="${_dsbTfSelectedEnvDir:-}"

  local envStatus=1
  local lockFileStatus=1
  local subHintFileStatus=1
  if [ -n "${selectedEnv}" ]; then
    _dsb_tf_look_for_env "${selectedEnv}"
    envStatus=$?

    _dsb_tf_look_for_lock_file "${selectedEnv}"
    lockFileStatus=$?

    _dsb_tf_look_for_subscription_hint_file "${selectedEnv}"
    subHintFileStatus=$?
  fi

  _dsbTfLogInfo=1
  _dsbTfLogErrors=1
  _dsb_tf_error_start_trapping
  local returnCode=$((prereqStatus + githubStatus + azureStatus + envStatus + lockFileStatus + subHintFileStatus))

  _dsb_i "Overall:"

  _dsb_d "_dsb_tf_report_status(): returnCode: ${returnCode}"
  _dsb_d "_dsb_tf_report_status(): prereqStatus: ${prereqStatus}"
  _dsb_d "_dsb_tf_report_status(): githubStatus: ${githubStatus}"
  _dsb_d "_dsb_tf_report_status(): azureStatus: ${azureStatus}"
  _dsb_d "_dsb_tf_report_status(): envStatus: ${envStatus}"
  _dsb_d "_dsb_tf_report_status(): lockFileStatus: ${lockFileStatus}"
  _dsb_d "_dsb_tf_report_status(): subHintFileStatus: ${subHintFileStatus}"

  if [ ${prereqStatus} -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  Pre-requisites check: passed."
  else
    _dsb_i "  \e[31m☒\e[0m  Pre-requisites check: fails, please run 'tf-check-prereqs'"
  fi
  _dsb_i ""
  _dsb_i "Auth:"
  _dsb_i "${githubAccount}"
  _dsb_i "${azureAccount}"
  _dsb_i ""
  _dsb_i "File system:"
  _dsb_i "  Root directory          : ${_dsbTfRootDir}"
  _dsb_i "  Environments directory  : ${envsDir}"
  _dsb_i "  Modules directory       : ${modulesDir}"
  _dsb_i "  Available modules       : ${availableModulesCommaSeparated}"
  _dsb_i ""
  _dsb_i "Environment:"
  _dsb_i "  Available environments    : ${availableEnvsCommaSeparated}"
  if [ -z "${selectedEnv}" ]; then
    _dsb_i "  ☐  Selected environment    : N/A, please run 'tf-select-env'"
    _dsb_i "  ☐  Environment directory   : N/A"
    _dsb_i "  ☐  Lock file               : N/A"
    _dsb_i "  ☐  Subscription hint file  : N/A"
  else
    if [ ${envStatus} -eq 0 ]; then
      _dsb_i "  \e[32m☑\e[0m  Selected environment   : ${selectedEnv}"
      _dsb_i "  \e[32m☑\e[0m  Environment directory  : ${selectedEnvDir}"
      if [ ${lockFileStatus} -eq 0 ]; then
        _dsb_i "  \e[32m☑\e[0m  Lock file              : ${_dsbTfSelectedEnvLockFile}"
      else
        _dsb_i "  \e[31m☒\e[0m  Lock file              : not found, please run 'tf-check-env ${selectedEnv}'"
      fi
      if [ ${subHintFileStatus} -eq 0 ]; then
        _dsb_i "  \e[32m☑\e[0m  Subscription hint file : ${_dsbTfSelectedEnvSubscriptionHintFile}"
        _dsb_i "  \e[32m☑\e[0m  Subscription hint      : ${_dsbTfSelectedEnvSubscriptionHintContent:-}"
      else
        _dsb_i "  \e[31m☒\e[0m  Subscription hint file : not found, please run 'tf-check-env ${selectedEnv}'"
        _dsb_i "  \e[31m☒\e[0m  Subscription hint      : N/A"
      fi
    else
      _dsb_i "  \e[31m☒\e[0m  Selected environment  : ${selectedEnv}, does not exist, please run 'tf-select-env'"
      _dsb_i "  ☐  Environment directory  : N/A"
      _dsb_i "  ☐  Lock file              : N/A"
      _dsb_i "  ☐  Subscription hint file : N/A"
      _dsb_i "  ☐  Subscription hint      : N/A"
    fi
  fi
  if [ ${returnCode} -ne 0 ]; then
    _dsb_i ""
    _dsb_w "not all green 🧐"
  fi

  _dsbTfReturnCode=$returnCode
}

###################################################################################################
#
# Help functions
#
###################################################################################################

# the help function
#   supports many inupts:
#     tf-help                 -> show short help, will list most used commands and command groups
#     tf-help groups          -> show all command groups
#                                valid groups are 'general'/'overall', 'all', 'azure', 'checks', 'environments', 'terraform', 'linting'/'tflint', 'upgrading'/'bumping'
#                                NOT IMPLMENTING IN HELP FOR NOW: 'terraform', 'linting'/'tflint', 'upgrading'/'bumping'
#     tf-help [group]         -> show help for command group,
#                                valid groups are 'general'/'overall', 'all', 'azure', 'checks', 'environments', 'terraform', 'linting'/'tflint', 'upgrading'/'bumping'
#                                NOT IMPLMENTING IN HELP FOR NOW: 'terraform', 'linting'/'tflint', 'upgrading'/'bumping'
#     tf-help general         -> show general help
#                                mention that 'tf-help' is the same as 'tf-help general'
#                                talk about 'tf-help groups'
#                                talk about 'tf-help commands'
#                                mention 'tf-help all'
#     tf-help all             -> show all help
#     tf-help commands        -> show all commands, make sure to group and indent commands by group
#                                valid commands are: 'check-tools', 'check-gh-auth', 'check-dir', 'check-prereqs', 'list-envs', 'set-env', 'clear-env', 'select-env', 'check-env', 'az-logout', 'az-login', 'az-relog', 'az-whoami', 'tf-status'
#                                NOT IMPLMENTING IN HELP FOR NOW: future commands
#     tf-help [command]       -> show help for command
#                                valid commands are: 'check-tools', 'check-gh-auth', 'check-dir', 'check-prereqs', 'list-envs', 'set-env', 'clear-env', 'select-env', 'check-env', 'az-logout', 'az-login', 'az-relog', 'az-whoami', 'tf-status'
#                                NOT IMPLMENTING IN HELP FOR NOW: future commands

_ds_tf_help_get_commands_supported_by_help() {
  local -a commands=(
    "az-login"
    "az-logout"
    "az-relog"
    "az-set-sub"
    "az-whoami"
    "tf-check-dir"
    "tf-check-env"
    "tf-check-gh-auth"
    "tf-check-prereqs"
    "tf-check-tools"
    "tf-clear-env"
    "tf-list-envs"
    "tf-select-env"
    "tf-set-env"
    "tf-status"
  )
  echo "${commands[@]}"
}

_dsb_tf_help() {
  local arg="${1:-help}"
  case "${arg}" in
  all)
    _dsb_tf_help_commands
    ;;
  commands)
    _dsb_tf_help_commands
    ;;
  help)
    _dsb_tf_help_help
    ;;
  general)
    _dsb_tf_help_group_general
    ;;
  groups)
    _dsb_tf_help_groups
    ;;
  environments)
    _dsb_tf_help_group_environments
    ;;
  checks)
    _dsb_tf_help_group_checks
    ;;
  azure)
    _dsb_tf_help_group_azure
    ;;
  *)
    local -a validCommands
    mapfile -t validCommands < <(_ds_tf_help_get_commands_supported_by_help)
    if [[ " ${validCommands[*]} " =~ (^|[[:space:]])"${arg}"($|[[:space:]]) ]]; then
      _dsb_tf_help_specific_command "${arg}"
    else
      _dsb_w "Unknown help topic: ${arg}"
    fi
    ;;
  esac
}

_dsb_tf_help_help() {
  _dsb_i "General Help:"
  _dsb_i "  tf-help groups          -> show all command groups"
  _dsb_i "  tf-help [group]         -> show help for a specific command group"
  _dsb_i "  tf-help commands        -> show all commands, make sure to group and indent commands by group"
  _dsb_i "  tf-help [command]       -> show help for a specific command"
  _dsb_i "  tf-help all             -> show all help"
  _dsb_i ""
  _dsb_i "Common Commands:"
  _dsb_i "  tf-status               -> Show status of tools, authentication, and environment"
  _dsb_i "  az-relog                -> Azure relogin"
  _dsb_i "  az-whoami               -> Show Azure account information"
  _dsb_i "  tf-check-prereqs        -> Run all prerequisite checks"
  _dsb_i "  tf-set-env [env]        -> Set environment"
  _dsb_i "  tf-check-env [env]      -> Check if environment is valid"
}

_dsb_tf_help_groups() {
  _dsb_i "Help Groups:"
  _dsb_i "  environments            -> Environment related commands"
  _dsb_i "  checks                  -> Check related commands"
  _dsb_i "  general                 -> General help"
  _dsb_i "  azure                   -> Azure related commands"
  _dsb_i "  all                     -> All help"
  _dsb_i ""
  _dsb_i "Use 'tf-help [group]' to get detailed help for a specific group."
}

_dsb_tf_help_group_environments() {
  _dsb_i "  Environment Commands:"
  _dsb_i "    tf-list-envs          -> List existing environments"
  _dsb_i "    tf-select-env         -> List and select environment"
  _dsb_i "    tf-set-env [env]      -> Set environment"
  _dsb_i "    tf-check-env [env]    -> Check if environment is valid"
  _dsb_i "    tf-clear-env          -> Clear selected environment"
}

_dsb_tf_help_group_checks() {
  _dsb_i "  Check Commands:"
  _dsb_i "    tf-check-dir          -> Check if in valid Terraform project structure"
  _dsb_i "    tf-check-prereqs      -> Run all prerequisite checks"
  _dsb_i "    tf-check-tools        -> Check for required tools"
  _dsb_i "    tf-check-gh-auth      -> Check GitHub authentication"
}

_dsb_tf_help_group_general() {
  _dsb_i "  General Commands:"
  _dsb_i "    tf-status             -> Show status of tools, authentication, and environment"
}

_dsb_tf_help_group_azure() {
  _dsb_i "  Azure Commands:"
  _dsb_i "    az-logout             -> Azure logout"
  _dsb_i "    az-login              -> Azure login"
  _dsb_i "    az-relog              -> Azure relogin"
  _dsb_i "    az-whoami             -> Show Azure account information"
  _dsb_i "    az-set-sub            -> Set Azure subscription from current env hint file"
}

_dsb_tf_help_commands() {
  _dsb_tf_help_help
  _dsb_i ""
  _dsb_i "Groups:"
  _dsb_i ""
  _dsb_tf_help_group_environments
  _dsb_i ""
  _dsb_tf_help_group_checks
  _dsb_i ""
  _dsb_tf_help_group_general
  _dsb_i ""
  _dsb_tf_help_group_azure
  _dsb_i ""
  _dsb_i "All Commands:"
  _dsb_i ""
  local commands
  commands=$(_ds_tf_help_get_commands_supported_by_help)
  local -a validCommands
  # shellcheck disable=SC2162
  read -a validCommands <<<"$commands"
  for command in "${validCommands[@]}"; do
    _dsb_tf_help_specific_command "${command}"
    _dsb_i ""
  done
}

_dsb_tf_help_specific_command() {
  local command="${1}"
  case "${command}" in
  # environments
  tf-list-envs)
    _dsb_i "tf-list-envs:"
    _dsb_i "  List existing environments."
    _dsb_i "  Related commands: tf-set-env, tf-select-env, tf-clear-env."
    ;;
  tf-select-env)
    _dsb_i "tf-select-env:"
    _dsb_i "  List and select an environment."
    _dsb_i "  Related commands: tf-list-envs, tf-set-env, tf-clear-env."
    ;;
  tf-set-env)
    _dsb_i "tf-set-env [env]:"
    _dsb_i "  Set the specified environment."
    _dsb_i "  Related commands: tf-list-envs, tf-select-env, tf-clear-env."
    ;;
  tf-check-env)
    _dsb_i "tf-check-env [env]:"
    _dsb_i "  Check if the specified environment is valid."
    _dsb_i "  Related commands: tf-list-envs, tf-set-env, tf-select-env."
    ;;
  tf-clear-env)
    _dsb_i "tf-clear-env:"
    _dsb_i "  Clear the selected environment."
    _dsb_i "  Related commands: tf-list-envs, tf-set-env, tf-select-env."
    ;;
  # checks
  tf-check-dir)
    _dsb_i "tf-check-dir:"
    _dsb_i "  Check if you are in a valid Terraform project structure."
    ;;
  tf-check-prereqs)
    _dsb_i "tf-check-prereqs:"
    _dsb_i "  Run all prerequisite checks (tools, GitHub authentication, directory structure)."
    ;;
  tf-check-tools)
    _dsb_i "tf-check-tools:"
    _dsb_i "  Check for required tools (az cli, gh cli, terraform, jq, yq, golang, hcledit, terraform-docs, realpath)."
    ;;
  tf-check-gh-auth)
    _dsb_i "tf-check-gh-auth:"
    _dsb_i "  Check if you are authenticated with GitHub."
    ;;
  # general
  tf-status)
    _dsb_i "tf-status:"
    _dsb_i "  Show the status of tools, authentication, and environment."
    ;;
  # azure
  az-logout)
    _dsb_i "az-logout:"
    _dsb_i "  Logout from Azure."
    ;;
  az-login)
    _dsb_i "az-login:"
    _dsb_i "  Login to Azure using device code."
    ;;
  az-relog)
    _dsb_i "az-relog:"
    _dsb_i "  Relogin to Azure."
    ;;
  az-whoami)
    _dsb_i "az-whoami:"
    _dsb_i "  Show the currently logged in Azure account."
    ;;
  az-set-sub)
    _dsb_i "az-set-sub:"
    _dsb_i "  Set Azure subscription using subscription hint file from selected environment."
    _dsb_i ""
    _dsb_i "  Example usage:"
    _dsb_i "    tf-set-env myenv"
    _dsb_i "    az-set-sub"
    ;;
  *)
    _dsb_w "Unknown help topic: ${command}"
    ;;
  esac
}

_dsb_tf_help_enumerate_supported_topics() {
  local -a validgroups=(
    "all"
    "commands"
    "help"
    "groups"
    "environments"
    "checks"
    "azure"
    "general"
  )
  local -a validCommands
  mapfile -t validCommands < <(_ds_tf_help_get_commands_supported_by_help)
  echo "${validgroups[@]}" "${validCommands[@]}"
}

###################################################################################################
#
# Check functions
#
###################################################################################################

_dsb_tf_check_az_cli() {
  if ! az --version &>/dev/null; then
    _dsb_err "Azure CLI not found."
    _dsb_err "  checked with command: az --version"
    _dsb_err "  make sure az is available in your PATH"
    _dsb_err "  for installation instructions see: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
    return 1
  fi
}

_dsb_tf_check_gh_cli() {
  if ! gh --version &>/dev/null; then
    _dsb_err "GitHub CLI not found."
    _dsb_err "  checked with command: gh --version"
    _dsb_err "  make sure gh is available in your PATH"
    _dsb_err "  for installation instructions see: https://github.com/cli/cli#installation"
    return 1
  fi
}

_dsb_tf_check_terraform() {
  if ! terraform -version &>/dev/null; then
    _dsb_err "Terraform not found."
    _dsb_err "  checked with command: terraform -version"
    _dsb_err "  make sure terraform is available in your PATH"
    _dsb_err "  for installation instructions see: https://learn.hashicorp.com/tutorials/terraform/install-cli"
    return 1
  fi
}

_dsb_tf_check_jq() {
  if ! jq --version &>/dev/null; then
    _dsb_err "jq not found."
    _dsb_err "  checked with command: jq --version"
    _dsb_err "  make sure jq is available in your PATH"
    _dsb_err "  for installation instructions see: https://stedolan.github.io/jq/download/"
    return 1
  fi
}

_dsb_tf_check_yq() {
  if ! yq --version &>/dev/null; then
    _dsb_err "yq not found."
    _dsb_err "  checked with command: yq --version"
    _dsb_err "  make sure yq is available in your PATH"
    _dsb_err "  for installation instructions see: https://mikefarah.gitbook.io/yq#install"
    return 1
  fi
}

_dsb_tf_check_golang() {
  if ! go version &>/dev/null; then
    _dsb_err "Go not found."
    _dsb_err "  checked with command: go version"
    _dsb_err "  make sure go is available in your PATH"
    _dsb_err "  for installation instructions see: https://go.dev/doc/install"
    return 1
  fi
}

_dsb_tf_check_hcledit() {
  if ! hcledit version &>/dev/null; then
    _dsb_err "hcledit not found."
    _dsb_err "  checked with command: hcledit version"
    _dsb_err "  make sure hcledit is available in your PATH"
    _dsb_err "  for installation instructions see: https://github.com/minamijoyo/hcledit?tab=readme-ov-file#install"
    _dsb_err "  or install it with: 'go install github.com/minamijoyo/hcledit@latest; export PATH=\$PATH:\$(go env GOPATH)/bin; echo \"export PATH=\$PATH:\$(go env GOPATH)/bin\" >> ~/.bashrc'"
    return 1
  fi
}

_dsb_tf_check_terraform_docs() {
  if ! terraform-docs --version &>/dev/null; then
    _dsb_err "terraform-docs not found."
    _dsb_err "  checked with command: terraform-docs --version"
    _dsb_err "  make sure terraform-docs is available in your PATH"
    _dsb_err "  for installation instructions see: https://terraform-docs.io/user-guide/installation/"
    _dsb_err "  or install it with: 'go install github.com/terraform-docs/terraform-docs@latest; export PATH=\$PATH:\$(go env GOPATH)/bin; echo \"export PATH=\$PATH:\$(go env GOPATH)/bin\" >> ~/.bashrc'"
    return 1
  fi
}

_dsb_tf_check_realpath() {
  if ! realpath --version &>/dev/null; then
    _dsb_err "realpath not found."
    _dsb_err "  checked with command: realpath --version"
    _dsb_err "  make sure realpath is available in your PATH"
    _dsb_err "  install it with one of:"
    _dsb_err "    - Ubuntu: 'sudo apt-get install coreutils'"
    _dsb_err "    - OS X  : 'brew install coreutils'"
    return 1
  fi
}

_dsb_tf_check_tools() {

  _dsb_i "Checking Azure CLI ..."
  _dsb_tf_check_az_cli
  local azCliStatus=$?

  _dsb_i "Checking GitHub CLI ..."
  _dsb_tf_check_gh_cli
  local ghCliStatus=$?

  _dsb_i "Checking Terraform ..."
  _dsb_tf_check_terraform
  local terraformStatus=$?

  _dsb_i "Checking jq ..."
  _dsb_tf_check_jq
  local jqStatus=$?

  _dsb_i "Checking yq ..."
  _dsb_tf_check_yq
  local yqStatus=$?

  _dsb_i "Checking Go ..."
  _dsb_tf_check_golang
  local golangStatus=$?

  _dsb_i "Checking hcledit ..."
  _dsb_tf_check_hcledit
  local hcleditStatus=$?

  _dsb_i "Checking terraform-docs ..."
  _dsb_tf_check_terraform_docs
  local terraformDocsStatus=$?

  _dsb_i "Checking realpath ..."
  _dsb_tf_check_realpath
  local realpathStatus=$?

  local returnCode=$((azCliStatus + ghCliStatus + terraformStatus + jqStatus + yqStatus + golangStatus + hcleditStatus + terraformDocsStatus + realpathStatus))

  _dsb_i ""
  _dsb_i "Tools check summary:"
  if [ ${azCliStatus} -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  Azure CLI check      : passed."
  else
    _dsb_i "  \e[31m☒\e[0m  Azure CLI check      : fails, see above for more information."
  fi
  if [ ${ghCliStatus} -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  GitHub CLI check     : passed."
  else
    _dsb_i "  \e[31m☒\e[0m  GitHub CLI check     : fails, see above for more information."
  fi
  if [ ${terraformStatus} -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  Terraform check      : passed."
  else
    _dsb_i "  \e[31m☒\e[0m  Terraform check      : fails, see above for more information."
  fi
  if [ ${jqStatus} -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  jq check             : passed."
  else
    _dsb_i "  \e[31m☒\e[0m  jq check             : fails, see above for more information."
  fi
  if [ ${yqStatus} -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  yq check             : passed."
  else
    _dsb_i "  \e[31m☒\e[0m  yq check             : fails, see above for more information."
  fi
  if [ ${golangStatus} -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  Go check             : passed."
  else
    _dsb_i "  \e[31m☒\e[0m  Go check             : fails, see above for more information."
  fi
  if [ ${hcleditStatus} -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  hcledit check        : passed."
  else
    _dsb_i "  \e[31m☒\e[0m  hcledit check        : fails, see above for more information."
  fi
  if [ ${terraformDocsStatus} -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  terraform-docs check : passed."
  else
    _dsb_i "  \e[31m☒\e[0m  terraform-docs check : fails, see above for more information."
  fi
  if [ ${realpathStatus} -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  realpath check       : passed."
  else
    _dsb_i "  \e[31m☒\e[0m  realpath check       : fails, see above for more information."
  fi

  return $returnCode
}

_dsb_tf_check_gh_auth() {
  local returnCode=0

  # check fails if gh cli is not installed
  if ! _dsbTfLogErrors=0 _dsb_tf_check_gh_cli; then
    return 1
  fi

  if ! gh auth status &>/dev/null; then
    _dsb_err "You are not authenticated with GitHub. Please run 'gh auth login' to authenticate."
    return 1
  fi
}

_dsb_tf_check_root_directory() {
  local returnCode=0

  if ! _dsb_tf_look_for_main_dir; then returnCode=1; fi
  if ! _dsb_tf_look_for_envs_dir; then returnCode=1; fi

  return $returnCode
}

_dsb_tf_check_current_dir() {
  _dsb_tf_enumerate_directories
  _dsb_tf_error_stop_trapping

  _dsb_i "Checking main dir  ..."
  _dsb_tf_look_for_main_dir
  local mainDirStatus=$?

  _dsb_i "Checking envs dir  ..."
  _dsb_tf_look_for_envs_dir
  local envsDirStatus=$?

  _dsb_tf_error_start_trapping
  local returnCode=$((mainDirStatus + envsDirStatus))

  _dsb_i ""
  _dsb_i "Directory check summary:"

  if [ "${mainDirStatus}" -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  Main directory check         : passed."
  else
    _dsb_i "  \e[31m☒\e[0m  Main directory check         : failed."
  fi

  if [ "${envsDirStatus}" -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  Environments directory check : passed."
  else
    _dsb_i "  \e[31m☒\e[0m  Environments directory check : failed."
  fi

  local selectedEnv="${_dsbTfSelectedEnv:-}"
  _dsb_d "_dsb_tf_check_current_dir(): selectedEnv: ${selectedEnv}"

  _dsb_i ""
  if [ "${returnCode}" -eq 0 ]; then
    _dsb_i "\e[32mAll directory checks passed.\e[0m"
  else
    _dsb_err "Directory check(s) failed, the current directory does not seem to be a valid Terraform project."
    _dsb_err "  directory checked: ${_dsbTfRootDir}"
    _dsb_err "  for more information see above."
  fi

  _dsbTfReturnCode=$returnCode
}

_dsb_tf_check_prereqs() {
  local prevLogInfo="${_dsbTfLogInfo}"
  local prevLogErrors="${_dsbTfLogErrors}"

  _dsb_tf_enumerate_directories
  _dsb_tf_error_stop_trapping

  _dsb_i_nonewline "Checking tools ..."
  _dsbTfLogInfo=0
  _dsbTfLogErrors=0
  _dsb_tf_check_tools
  local toolsStatus=$?
  _dsbTfLogInfo="${prevLogInfo}"
  _dsbTfLogErrors="${prevLogErrors}"
  _dsb_i_append " done."

  _dsb_i_nonewline "Checking GitHub authentication ..."
  _dsb_tf_check_gh_auth
  local ghAuthStatus=$?
  _dsb_i_append " done."

  _dsb_i_nonewline "Checking working directory ..."
  _dsb_tf_check_root_directory
  local workingDirStatus=$?
  _dsb_i_append " done."

  # _dsbTfLogErrors=1
  _dsb_tf_error_start_trapping
  local returnCode=$((toolsStatus + ghAuthStatus + workingDirStatus))

  _dsb_d "_dsb_tf_check_prereqs(): returnCode: ${returnCode}"
  _dsb_d "_dsb_tf_check_prereqs(): toolsStatus: ${toolsStatus}"
  _dsb_d "_dsb_tf_check_prereqs(): ghAuthStatus: ${ghAuthStatus}"
  _dsb_d "_dsb_tf_check_prereqs(): workingDirStatus: ${workingDirStatus}"

  _dsb_i ""
  _dsb_i "Pre-requisites check summary:"
  if [ ${toolsStatus} -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  Tools check                  : passed."
  else
    _dsb_i "  \e[31m☒\e[0m  Tools check                  : failed, please run 'tf-check-tools'"
  fi
  if [ ${ghAuthStatus} -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  GitHub authentication check  : passed."
  else
    if ! _dsbTfLogErrors=0 _dsb_tf_check_gh_cli; then
      _dsb_i "  ☐  GitHub authentication check  : N/A, please run 'tf-check-tools'"
    else
      _dsb_i "  \e[31m☒\e[0m  GitHub authentication check  : failed."
    fi
  fi
  if [ ${workingDirStatus} -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  Working directory check      : passed."
  else
    _dsb_i "  \e[31m☒\e[0m  Working directory check      : failed, please run 'tf-check-dir'"
  fi

  _dsb_i ""
  if [ ${returnCode} -eq 0 ]; then
    _dsb_i "\e[32mAll pre-reqs check passed.\e[0m"
    _dsb_i "  now try 'tf-select-env' to select an environment."
  else
    _dsb_err "\e[31mPre-reqs check failed, for more information see above.\e[0m"
  fi

  _dsb_d "_dsb_tf_check_prereqs(): returnCode: ${returnCode}"

  _dsbTfReturnCode=$returnCode
}

_dsb_tf_check_env() {
  local envToCheck="${1:-}"

  # this function is used in two forms:
  #   1. with a supplied environment name
  #   2. with the globally selected environment name
  local selectedEnv="${_dsbTfSelectedEnv:-}"
  local lockFileStatus=0
  local subscriptionHintFileStatus=0
  if [ -z "${envToCheck}" ]; then
    if [ -z "${selectedEnv}" ]; then
      _dsb_err "No environment specified and no environment selected."
      _dsb_err "  either specify environment: tf-check-env [env]"
      _dsb_err "  or run one of the following: tf-select-env, tf-set-env [env], tf-list-envs"
      _dsbTfReturnCode=1
      return 0 # caller reads _dsbTfReturnCode
    fi

    envToCheck="${selectedEnv}"
  fi

  _dsb_i "Environment: ${envToCheck}"

  _dsb_tf_enumerate_directories
  _dsb_tf_error_stop_trapping

  _dsb_i "Looking for environment ..."
  _dsb_tf_look_for_env "${envToCheck}"
  local envStatus=$?

  if [ ${envStatus} -eq 0 ]; then
    _dsb_i "Checking lock file ..."
    _dsb_tf_look_for_lock_file "${envToCheck}"
    lockFileStatus=$?

    _dsb_i "Checking subscription hint file ..."
    _dsb_tf_look_for_subscription_hint_file "${envToCheck}"
    subscriptionHintFileStatus=$?
  fi

  _dsb_tf_error_start_trapping
  local returnCode=$((envStatus + lockFileStatus + subscriptionHintFileStatus))

  _dsb_i ""
  _dsb_i "Environment check summary:"
  if [ ${envStatus} -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  Environment                  : found."
    if [ ${lockFileStatus} -eq 0 ]; then
      _dsb_i "  \e[32m☑\e[0m  Lock file check              : passed."
    else
      _dsb_i "  \e[31m☒\e[0m  Lock file check              : failed."
    fi
    if [ ${subscriptionHintFileStatus} -eq 0 ]; then
      _dsb_i "  \e[32m☑\e[0m  Subscription hint file check : passed."
    else
      _dsb_i "  \e[31m☒\e[0m  Subscription hint file check : failed."
    fi
  else
    _dsb_i "  \e[31m☒\e[0m  Environment                  : not found."
    _dsb_i "  ☐  Lock file check              : N/A, environment not found."
    _dsb_i "  ☐  Subscription hint file check : N/A, environment not found."
  fi

  _dsb_i ""
  if [ ${returnCode} -eq 0 ]; then
    _dsb_i "\e[32mAll checks passed.\e[0m"
  else
    _dsb_err "\e[31mChecks failed, for more information see above.\e[0m"
  fi

  _dsbTfReturnCode=$returnCode
}

###################################################################################################
#
# Directory enumeration
#
###################################################################################################

_dsb_tf_enumerate_directories() {
  _dsbTfRootDir="$(realpath .)"
  # DEBUG
  # _dsbTfRootDir=/home/peder/code/github/dsb-norge/azure-ad
  _dsbTfModulesDir="${_dsbTfRootDir}/modules"
  _dsbTfMainDir="${_dsbTfRootDir}/main"
  _dsbTfEnvsDir="${_dsbTfRootDir}/envs"

  _dsbTfModulesDirList=()
  if [ -d "${_dsbTfModulesDir}" ]; then
    local dir
    for dir in "${_dsbTfRootDir}"/modules/*; do
      _dsbTfModulesDirList[$(basename "${dir}")]="${dir}"
    done
  fi

  _dsbTfEnvsDirList=()
  _dsbTfAvailableEnvs=()

  if [ -d "${_dsbTfEnvsDir}" ]; then
    _dsb_d "_dsb_tf_enumerate_directories(): Enumerating environments ..."

    local item
    for item in "${_dsbTfRootDir}"/envs/*; do
      if [ -d "${item}" ]; then # is a directory
        # this exclude directories starting with _
        if [[ "$(basename "${item}")" =~ ^_ ]]; then
          continue
        fi
        _dsb_d "_dsb_tf_enumerate_directories(): Found environment: $(basename "${item}")"
        _dsbTfEnvsDirList[$(basename "${item}")]="${item}"
        _dsbTfAvailableEnvs+=("$(basename "${item}")")
      fi
    done

    _dsb_d "_dsb_tf_enumerate_directories(): number of environments found: ${#_dsbTfAvailableEnvs[@]}"

    # DEBUG
    # unset _dsbTfSelectedEnv
    # _dsbTfSelectedEnv="debug"
    # _dsbTfSelectedEnv="test"

    # checks if a selected environment is available in the list of environments.
    # If found, enumerate the corresponding env directory.
    # If not found, clear the selected environment and its corresponding env directory.
    #
    # Variables:
    # - _dsbTfSelectedEnv: The environment selected by the user.
    # - _dsbTfAvailableEnvs: An array of available environments.
    # - _dsbTfEnvsDirList: An associative array mapping environments to their directories.
    # - _dsbTfSelectedEnvDir: The directory of the selected environment.
    local selectedEnv="${_dsbTfSelectedEnv:-}"
    local envFound=0
    if [ -n "${selectedEnv}" ]; then # string is not empty
      local env
      for env in "${_dsbTfAvailableEnvs[@]}"; do
        if [ "${env}" == "${selectedEnv}" ]; then
          envFound=1
          break
        fi
      done
      if [ "${envFound}" -eq 1 ]; then
        _dsb_d "_dsb_tf_enumerate_directories(): found selectedEnv: ${selectedEnv}"
        _dsbTfSelectedEnvDir="${_dsbTfEnvsDirList["${selectedEnv}"]}"
      else
        _dsb_d "_dsb_tf_enumerate_directories(): clearing '_dsbTfSelectedEnv' and '_dsbTfSelectedEnvDir'"
        local logInfoOrig="${_dsbTfLogInfo:1}"
        _dsbTfLogInfo=0
        _dsb_tf_clear_env
        _dsbTfLogInfo="${logInfoOrig}"
      fi
    fi
  fi

  # DEBUG
  # _dsb_d "_dsb_tf_enumerate_directories(): Root dir: ${_dsbTfRootDir}"
  # _dsb_d "_dsb_tf_enumerate_directories(): Modules dir: ${_dsbTfModulesDir}"
  # _dsb_d "_dsb_tf_enumerate_directories(): Main dir: ${_dsbTfMainDir}"
  # _dsb_d "_dsb_tf_enumerate_directories(): Envs dir: ${_dsbTfEnvsDir}"
  # _dsb_d "_dsb_tf_enumerate_directories(): Modules dir list:"
  # for key in "${!_dsbTfModulesDirList[@]}"; do
  #   _dsb_d "_dsb_tf_enumerate_directories():   - ${key}: ${_dsbTfModulesDirList[$key]}"
  # done
  # _dsb_d "_dsb_tf_enumerate_directories(): Envs dir list:"
  # for key in "${!_dsbTfEnvsDirList[@]}"; do
  #   _dsb_d "_dsb_tf_enumerate_directories():   - ${key}: ${_dsbTfEnvsDirList[$key]}"
  # done
  # _dsb_d "_dsb_tf_enumerate_directories(): _dsbTfAvailableEnvs: ${_dsbTfAvailableEnvs[*]}"
  # _dsb_d "_dsb_tf_enumerate_directories(): Available envs:"
  # for dir in "${_dsbTfAvailableEnvs[@]}"; do
  #   _dsb_d "_dsb_tf_enumerate_directories():   - ${dir}"
  # done
}

# the purpose of this function is to allow getting the list of available project modules
# in a graceful way, without causing unbound variable errors
_dsb_tf_get_module_names() {
  local -a moduleNames=()
  if declare -p _dsbTfModulesDirList &>/dev/null; then
    local key
    for key in "${!_dsbTfModulesDirList[@]}"; do
      moduleNames+=("${key}")
    done
  fi
  printf "%s\n" "${moduleNames[@]}"
}

# a reusable way to get a comma separated list of available project modules
_dsb_tf_get_module_names_commaseparated() {
  local -a availableModules
  mapfile -t availableModules < <(_dsb_tf_get_module_names)
  local availableModulesCommaSeparated # declare and assign separately to avoid shellcheck warning
  availableModulesCommaSeparated=$(
    IFS=,
    echo "${availableModules[*]}"
  )
  availableModulesCommaSeparated=${availableModulesCommaSeparated//,/, }
  echo "${availableModulesCommaSeparated}"
}

# the purpose of this function is to allow getting the list of available project module
# director paths in a graceful way, without causing unbound variable errors
_dsb_tf_get_module_dirs() { # TODO: make sure to use this, possibly when performing terrasform operations
  local -a moduleDirs=()
  if declare -p _dsbTfModulesDirList &>/dev/null; then
    local value
    for value in "${_dsbTfModulesDirList[@]}"; do
      moduleDirs+=("${value}")
    done
  fi
  printf "%s\n" "${moduleDirs[@]}"
}

# the purpose of this function is to allow getting the list of available environments
# in a graceful way, without causing unbound variable errors
dsb_tf_get_env_names() {
  local -a envNames=()
  if declare -p _dsbTfEnvsDirList &>/dev/null; then
    local key
    for key in "${!_dsbTfEnvsDirList[@]}"; do
      envNames+=("${key}")
    done
  fi
  printf "%s\n" "${envNames[@]}"
}

# a reusable way to get a comma separated list of available environments
_dsb_tf_get_env_names_commaseparated() {
  local -a availableEnvs
  mapfile -t availableEnvs < <(dsb_tf_get_env_names)
  local availableEnvsCommaSeparated # declare and assign separately to avoid shellcheck warning
  availableEnvsCommaSeparated=$(
    IFS=,
    echo "${availableEnvs[*]}"
  )
  availableEnvsCommaSeparated=${availableEnvsCommaSeparated//,/, }
  echo "${availableEnvsCommaSeparated}"
}

# TODO: is this needed?
# _dsb_tf_get_env_dirs() {
#   local -a envDirs=()
#   if declare -p _dsbTfEnvsDirList &>/dev/null; then
#     local value
#     for value in "${_dsbTfEnvsDirList[@]}"; do
#         envDirs+=("${value}")
#     done
#   fi
#   printf "%s\n" "${envDirs[@]}"
# }

# checks if the path stored in _dsbTfEnvsDir actually exists as a directory
_dsb_tf_look_for_main_dir() {
  if [ ! -d "${_dsbTfMainDir}" ]; then
    _dsb_err "Directory 'main' not found in current directory: ${_dsbTfRootDir}"
    return 1
  fi
}

# checks if the path stored in _dsbTfEnvsDir actually exists as a directory
_dsb_tf_look_for_envs_dir() {
  if [ ! -d "${_dsbTfEnvsDir}" ]; then
    _dsb_err "Directory 'envs' not found in current directory: ${_dsbTfRootDir}"
    return 1
  fi
}

# either supplied or the selected environment
_dsb_tf_look_for_env() {
  local suppliedEnv="${1:-}"

  if [ -z "${suppliedEnv}" ]; then
    _dsbTfLogErrors=1
    _dsb_tf_error_start_trapping
    _dsb_err "Internal error: in _dsb_tf_look_for_env, no environment supplied."
    return 1
  fi

  if ! declare -p _dsbTfEnvsDir &>/dev/null; then
    _dsbTfLogErrors=1
    _dsb_tf_error_start_trapping
    _dsb_err "Internal error: in _dsb_tf_look_for_env, expected to find environments directory."
    _dsb_err "  expected in: _dsbTfEnvsDir"
    return 1
  fi

  local envsDir="${_dsbTfEnvsDir:-}"

  local -a availableEnvs
  mapfile -t availableEnvs < <(dsb_tf_get_env_names)
  local envCount=${#availableEnvs[@]}

  _dsb_d "_dsb_tf_look_for_env(): available envs count in availableEnvs: ${envCount}"
  _dsb_d "_dsb_tf_look_for_env(): available envs: ${availableEnvs[*]}"

  local env
  local envFound=0
  for env in "${availableEnvs[@]}"; do
    if [ "${env}" == "${suppliedEnv}" ]; then
      envFound=1
      break
    fi
  done

  if [ "${envFound}" -eq 1 ]; then
    _dsb_d "_dsb_tf_look_for_env(): found suppliedEnv: ${suppliedEnv}"
    return 0
  else
    _dsb_err "Environment not found."
    _dsb_err "  environment: ${suppliedEnv}"
    _dsb_err "  look in: ${envsDir}"
    _dsb_err "  for available environments run 'tf-list-envs'"
    return 1
  fi
}

# look for a given file type, either in the supplied or the selected environment
_dsb_tf_look_for_environment_file() {
  local suppliedEnv="${1:-}"
  local suppliedFileType="${2:-}"
  local suppliedGlobalToSavePathTo="${3:-}"
  local selectedEnv selectedEnvDir lookForFilename

  case "${suppliedFileType}" in
  "lock")
    lookForFilename=".terraform.lock.hcl"
    ;;
  "subscriptionHint")
    lookForFilename=".az-subscription"
    ;;
  *)
    _dsb_err "Internal error: in _dsb_tf_look_for_environment_file, expected suppliedFileType to be one of 'lock', 'subscriptionHint'."
    _dsb_err "  suppliedFileType: ${suppliedFileType}"
    return 1
    ;;
  esac

  if [ -z "${suppliedGlobalToSavePathTo}" ]; then
    _dsb_err "Internal error: in _dsb_tf_look_for_environment_file, expected suppliedGlobalToSavePathTo to be set."
    _dsb_err "  suppliedGlobalToSavePathTo: '${suppliedGlobalToSavePathTo}'"
    return 1
  fi

  # make sure the global variable supplied in suppliedGlobalToSavePathTo is declared
  if ! declare -p "${suppliedGlobalToSavePathTo}" &>/dev/null; then
    _dsb_err "Internal error: in _dsb_tf_look_for_environment_file, the supplied global variable is not declared."
    _dsb_err "  expected in suppliedGlobalToSavePathTo: ${suppliedGlobalToSavePathTo}"
    return 1
  fi

  # this function is used in two forms:
  #   1. with a supplied environment name
  #   2. with the globally selected environment name
  if [ -n "${suppliedEnv}" ]; then # env was supplied

    _dsb_tf_look_for_env "${suppliedEnv}"
    local envFoundStatus=$?

    if [ "${envFoundStatus}" -eq 0 ]; then
      _dsb_d "_dsb_tf_look_for_environment_file(): found suppliedEnv: ${suppliedEnv}"

      if ! declare -p _dsbTfEnvsDirList &>/dev/null; then
        _dsbTfLogErrors=1
        _dsb_tf_error_start_trapping
        _dsb_err "Internal error: in _dsb_tf_look_for_environment_file, expected to find environments directory list."
        _dsb_err "  expected in: _dsbTfEnvsDirList"
        return 1
      fi

      if [ -z "${_dsbTfEnvsDirList["${suppliedEnv}"]}" ]; then
        _dsbTfLogErrors=1
        _dsb_tf_error_start_trapping
        _dsb_err "Internal error: in _dsb_tf_look_for_environment_file, expected to find selected environment directory."
        _dsb_err "  expected in: _dsbTfEnvsDirList"
        return 1
      fi

      selectedEnvDir="${_dsbTfEnvsDirList["${suppliedEnv}"]}"
      selectedEnv="${suppliedEnv}"
    else
      return 1
    fi
  else # env was not supplied
    selectedEnv="${_dsbTfSelectedEnv:-}"

    # we allow the check to pass if no environment is selected
    _dsb_d "_dsb_tf_look_for_environment_file(): allow check to pass, no environment was selected"
    if [ -z "${selectedEnv}" ]; then return 0; fi

    # expect _dsbTfSelectedEnvDir to be set if an environment is selected
    if [ -z "${_dsbTfSelectedEnvDir:-}" ]; then
      _dsbTfLogErrors=1
      _dsb_tf_error_start_trapping
      _dsb_err "Internal error: in _dsb_tf_look_for_environment_file, environment set in '_dsbTfSelectedEnv', but '_dsbTfSelectedEnvDir' was not set."
      _dsb_err "  selected environment: ${selectedEnv}"
      return 1
    fi

    selectedEnvDir="${_dsbTfSelectedEnvDir:-}"
  fi

  _dsb_d "_dsb_tf_look_for_environment_file(): suppliedEnv: ${suppliedEnv}"
  _dsb_d "_dsb_tf_look_for_environment_file(): selectedEnv: ${selectedEnv}"
  _dsb_d "_dsb_tf_look_for_environment_file(): selectedEnvDir: ${selectedEnvDir}"

  # expect _dsbTfSelectedEnvDir to be a directory
  if [ ! -d "${selectedEnvDir}" ]; then
    _dsbTfLogErrors=1
    _dsb_tf_error_start_trapping
    _dsb_err "Internal error: in _dsb_tf_look_for_environment_file, environment set in '_dsbTfSelectedEnv', but directory not found."
    _dsb_err "  Selected environment: ${selectedEnv}"
    _dsb_err "  Expected directory: ${selectedEnvDir}"
    return 1
  fi

  # require that a file exists in the environment directory to be considered a valid environment
  if [ ! -f "${selectedEnvDir}/${lookForFilename}" ]; then
    _dsb_err "File not found in selected environment. A '${suppliedFileType}' file is required for an environment to be considered valid."
    _dsb_err "  selected environment: ${selectedEnv}"
    _dsb_err "  expected ${suppliedFileType} file: ${selectedEnvDir}/${lookForFilename}"
    return 1
  fi

  declare -g "${suppliedGlobalToSavePathTo}=${selectedEnvDir}/${lookForFilename}"
}

# look for a lock file, either in the supplied or the selected environment
_dsb_tf_look_for_lock_file() {
  local suppliedEnv="${1:-}"

  # clear global variable
  _dsbTfSelectedEnvLockFile=""
  _dsb_tf_look_for_environment_file "${suppliedEnv}" 'lock' '_dsbTfSelectedEnvLockFile'
}

# look for a subscription hint file, either in the supplied or the selected environment
_dsb_tf_look_for_subscription_hint_file() {
  local suppliedEnv="${1:-}"

  # clear global variables
  _dsbTfSelectedEnvSubscriptionHintFile=""
  _dsbTfSelectedEnvSubscriptionHintContent=""
  _dsb_tf_look_for_environment_file "${suppliedEnv}" 'subscriptionHint' '_dsbTfSelectedEnvSubscriptionHintFile'

  if [ -f "${_dsbTfSelectedEnvSubscriptionHintFile}" ]; then
    _dsbTfSelectedEnvSubscriptionHintContent=$(cat "${_dsbTfSelectedEnvSubscriptionHintFile}")
  else
    return 1
  fi
}

###################################################################################################
#
# Environment
#
###################################################################################################

_dsb_tf_clear_env() {
  _dsb_d "_dsb_tf_clear_env(): clearing _dsbTfSelectedEnv and _dsbTfSelectedEnvDir"
  _dsbTfSelectedEnv=""
  _dsbTfSelectedEnvDir=""
  _dsb_i "Environment cleared."
}

_dsb_tf_list_envs() {
  _dsbTfLogErrors=0

  _dsb_tf_enumerate_directories

  _dsb_tf_error_stop_trapping

  # check if the current root directory is a valid Terraform project
  _dsb_tf_check_root_directory
  local dirCheckStatus=$?

  if [ "${dirCheckStatus}" -ne 0 ]; then
    _dsbTfLogErrors=1
    _dsb_err "Directory check(s) fails, please run 'tf-check-dir'"
    _dsbTfReturnCode=1
    return 0 # caller reads _dsbTfReturnCode
  fi

  if ! declare -p _dsbTfEnvsDir &>/dev/null; then
    _dsbTfLogErrors=1
    _dsb_tf_error_start_trapping
    _dsb_err "Internal error: in _dsb_tf_list_envs, expected to find environments directory."
    _dsb_err "  expected in: _dsbTfEnvsDir"
    return 1
  fi

  local -a availableEnvs
  mapfile -t availableEnvs < <(dsb_tf_get_env_names)
  local envCount=${#availableEnvs[@]}

  _dsb_d "_dsb_tf_list_envs(): available envs count in availableEnvs: ${envCount}"
  _dsb_d "_dsb_tf_list_envs(): available envs: ${availableEnvs[*]}"

  if [ "${#availableEnvs[@]}" -eq 0 ]; then
    _dsbTfLogErrors=1
    _dsb_tf_error_start_trapping
    _dsb_err "Internal error: in _dsb_tf_list_envs, expected to find available environments."
    _dsb_err "  expected in: _dsbTfAvailableEnvs"
    return 1
  fi

  local envsDir="${_dsbTfEnvsDir}"

  if [ "${envCount}" -eq 0 ]; then
    _dsb_w "No environments found in: ${envsDir}"
    _dsb_i "  this probably means the directory is empty."
    _dsb_i "  either create an environment or run the command from a different root directory."
    _dsbTfReturnCode=1
  else
    local envIdx=1
    _dsb_i "Available environments:"
    local envDir
    for envDir in "${availableEnvs[@]}"; do
      _dsb_i "  $((envIdx++))) ${envDir}"
    done
    _dsbTfReturnCode=0
  fi

  return 0 # caller reads _dsbTfReturnCode
}

_dsb_tf_set_env() {
  _dsbTfLogErrors=1
  _dsbTfLogInfo=1

  local envToSet="${1:-}"

  _dsb_d "_dsb_tf_set_env(): envToSet: ${envToSet}"

  if [ -z "${envToSet}" ]; then
    _dsb_err "No environment specified."
    _dsb_err "  usage: tf-set-env <env>"
    _dsbTfReturnCode=1
    return 0 # caller reads _dsbTfReturnCode
  fi

  _dsb_tf_enumerate_directories

  _dsb_tf_error_stop_trapping

  # check if the current root directory is a valid Terraform project
  _dsb_tf_check_root_directory
  local dirCheckStatus=$?

  if [ "${dirCheckStatus}" -ne 0 ]; then
    _dsbTfLogErrors=1
    _dsb_err "Directory check(s) fails, please run 'tf-check-dir'"
    _dsbTfReturnCode=1
    return 0 # caller reads _dsbTfReturnCode
  fi

  if ! declare -p _dsbTfEnvsDirList &>/dev/null; then
    _dsbTfLogErrors=1
    _dsb_tf_error_start_trapping
    _dsb_err "Internal error: in _dsb_tf_set_env, expected to find environments directory list."
    _dsb_err "  expected in: _dsbTfEnvsDirList"
    return 1
  fi

  local -a availableEnvs
  mapfile -t availableEnvs < <(dsb_tf_get_env_names)
  local envCount=${#availableEnvs[@]}

  _dsb_d "_dsb_tf_set_env(): available envs count in availableEnvs: ${envCount}"
  _dsb_d "_dsb_tf_set_env(): available envs: ${availableEnvs[*]}"

  # check if the envToSet is available
  local env
  local envFound=0
  for env in "${availableEnvs[@]}"; do
    if [ "${env}" == "${envToSet}" ]; then
      envFound=1
      break
    fi
  done

  if [ "${envFound}" -ne 1 ]; then
    _dsb_err "Environment '${envToSet}' not available."
    _dsbTfLogErrors=1
    _dsb_tf_list_envs
    _dsbTfReturnCode=1
    return 0 # caller reads _dsbTfReturnCode
  fi

  _dsbTfSelectedEnv="${envToSet}"
  _dsbTfSelectedEnvDir="${_dsbTfEnvsDirList["${_dsbTfSelectedEnv}"]}"

  _dsb_i "Selected environment: ${_dsbTfSelectedEnv}"

  _dsbTfLogErrors=0
  _dsb_tf_error_stop_trapping

  # check if the selected environment is valid

  _dsb_tf_look_for_lock_file
  local lockFileStatus=$?

  _dsb_tf_look_for_subscription_hint_file
  local subscriptionHintFileStatus=$?

  if [ "${lockFileStatus}" -ne 0 ]; then
    _dsbTfLogErrors=1
    _dsb_err "Lock file check failed, please run 'tf-check-env ${_dsbTfSelectedEnv}'"
  fi

  if [ "${subscriptionHintFileStatus}" -ne 0 ]; then
    _dsbTfLogErrors=1
    _dsb_err "Subscription hint file check failed, please run 'tf-check-env ${_dsbTfSelectedEnv}'"
  fi

  _dsbTfReturnCode=$((lockFileStatus + subscriptionHintFileStatus))

  return 0 # caller reads _dsbTfReturnCode
}

_dsb_tf_select_env() {
  _dsbTfLogErrors=0
  _dsbTfLogInfo=1

  _dsb_tf_list_envs
  local listEnvsStatus=${_dsbTfReturnCode}

  _dsb_d "_dsb_tf_select_env(): listEnvsStatus: ${listEnvsStatus}"

  if [ "${listEnvsStatus}" -ne 0 ]; then
    return 0 # caller reads _dsbTfReturnCode
  fi

  _dsb_tf_error_start_trapping

  local -a availableEnvs
  mapfile -t availableEnvs < <(dsb_tf_get_env_names)
  local envCount=${#availableEnvs[@]}

  _dsb_d "_dsb_tf_select_env(): availableEnvs: ${availableEnvs[*]}"

  local -a validChoices
  mapfile -t validChoices < <(seq 1 "${envCount}")

  local userInput idx
  local gotValidInput=0
  while [ "${gotValidInput}" -ne 1 ]; do
    read -r -p "Enter index of environment to set: " userInput
    # clear the current console line
    echo -en "\033[1A\033[2K"
    for idx in "${validChoices[@]}"; do
      if [ "${idx}" == "${userInput}" ]; then
        gotValidInput=1
        _dsb_d "_dsb_tf_select_env(): idx = ${idx} is valid"
        break
      fi
    done
  done

  _dsb_i ""
  _dsb_tf_set_env "${availableEnvs[$((userInput - 1))]}"

  return 0 # caller reads _dsbTfReturnCode
}

###################################################################################################
#
# Azure CLI
#
###################################################################################################

# returns early if az cli is not installed
# runs 'az account show' invocation to determine if the user is logged in
# this function returns 1 if 'az account show' fails
# this function populates _dsbTfAzureUpn with the UPN from the response from 'az account show'
# this function populates _dsbTfSubscriptionId with the subscription id from the response from 'az account show'
# if the user is not logged in, _dsbTfAzureUpn is set to an empty string
# if the user is not logged in, _dsbTfSubscriptionId is set to an empty string
_dsb_tf_az_enumerate_account() {

  # if az cli is not installed, do not fail
  _dsb_tf_error_stop_trapping
  _dsb_tf_check_az_cli
  local azCliStatus=$?
  if [ "${azCliStatus}" -ne 0 ]; then
    return 0
  fi

  local showOutput
  showOutput=$(az account show 2>&1)
  local showStatus=$?
  _dsb_tf_error_start_trapping

  _dsb_d "_dsb_tf_az_enumerate_account(): showStatus: ${showStatus}"
  _dsb_d "_dsb_tf_az_enumerate_account(): showOutput: ${showOutput}"

  local azUpn=$(echo "${showOutput}" | jq -r '.user.name')
  local subId=$(echo "${showOutput}" | jq -r '.id')
  local subName=$(echo "${showOutput}" | jq -r '.name')
  local tenantDisplayName=$(echo "${showOutput}" | jq -r '.tenantDisplayName')

  _dsb_d "_dsb_tf_az_enumerate_account(): azUpn: ${azUpn}"
  _dsb_d "_dsb_tf_az_enumerate_account(): subId: ${subId}"

  if [ "${showStatus}" -eq 0 ]; then
    _dsb_i "Logged in with Azure CLI: '${azUpn}' in tenant '${tenantDisplayName}'"
    _dsb_i "  Subscription ID   : ${subId}"
    _dsb_i "  Subscription Name : ${subName}"
    _dsbTfAzureUpn="${azUpn}"
    _dsbTfSubscriptionId="${subId}"
  else
    _dsb_i "Not logged in with Azure CLI."
    _dsbTfAzureUpn=""
    _dsbTfSubscriptionId=""
  fi
}

_dsb_tf_az_whoami() {
  _dsb_tf_az_enumerate_account
  _dsbTfReturnCode=$?
}

_dsb_tf_az_logout() {

  _dsb_tf_error_stop_trapping
  _dsb_tf_check_az_cli
  local azCliStatus=$?

  if [ "${azCliStatus}" -ne 0 ]; then
    _dsb_i "  💡 you can also check other prerequisites by running 'tf-check-prereqs'"
    _dsbTfReturnCode=1
    return 0 # caller reads _dsbTfReturnCode
  fi

  local clearOutput
  clearOutput=$(az account clear 2>&1)
  local clearStatus=$?

  _dsb_d "_dsb_tf_az_logout(): clearOutput: ${clearOutput}"

  if [ "${clearStatus}" -ne 0 ]; then
    _dsb_err "Failed to clear subscriptions from local cache."
    _dsb_err "  please run 'az account clear --debug' manually"
    _dsbTfReturnCode=1
  else
    _dsb_i "Logged out from Azure CLI."
    _dsbTfReturnCode=0
  fi

  _dsbTfLogErrors=0
  _dsbTfLogInfo=0
  _dsb_tf_error_stop_trapping
  _dsb_tf_az_enumerate_account
}

_dsb_tf_az_login() {

  _dsb_tf_error_stop_trapping
  _dsb_tf_check_az_cli
  local azCliStatus=$?

  if [ "${azCliStatus}" -ne 0 ]; then
    _dsb_i "  💡 you can also check other prerequisites by running 'tf-check-prereqs'"
    _dsbTfReturnCode=1
    return 0 # caller reads _dsbTfReturnCode
  fi

  _dsb_tf_error_stop_trapping
  _dsbTfLogInfo=0
  _dsb_tf_az_enumerate_account
  local accountStatus=$?
  _dsbTfLogInfo=1

  # already logged in?
  _dsb_tf_error_start_trapping
  if [ "${accountStatus}" -eq 0 ]; then
    local azUpn="${_dsbTfAzureUpn:-}"
    if [ -n "${azUpn}" ]; then
      # logged in, do nothing except showing the UPN
      _dsbTfLogInfo=1
      _dsb_tf_az_enumerate_account
      _dsbTfReturnCode=0
      return 0 # caller reads _dsbTfReturnCode
    fi
  fi

  # make sure to clear any existing account
  _dsb_tf_error_stop_trapping
  az account clear &>/dev/null

  local loginOutput
  loginOutput=$(az login --use-device-code)
  local loginStatus=$?

  _dsb_tf_error_start_trapping

  _dsb_d "_dsb_tf_az_login(): loginOutput: ${loginOutput}"

  if [ "${loginStatus}" -ne 0 ]; then
    _dsb_err "Failed to login with Azure CLI."
    _dsb_err "  please run 'az login --debug' manually"
    _dsbTfReturnCode=1
  else
    _dsb_tf_error_stop_trapping
    _dsb_tf_az_enumerate_account
    _dsbTfReturnCode=$? # caller reads _dsbTfReturnCode
  fi
}

_dsb_tf_az_relogin() {
  _dsb_tf_az_logout
  local logoutStatus="${_dsbTfReturnCode}"
  _dsb_tf_az_login
  local loginStatus="${_dsbTfReturnCode}"
  _dsbTfReturnCode=$((logoutStatus + loginStatus)) # caller reads _dsbTfReturnCode
}

_dsb_tf_az_set_sub() {
  local selectedEnv="${_dsbTfSelectedEnv:-}"

  if [ -z "${selectedEnv}" ]; then
    _dsbTfLogErrors=1
    _dsb_err "No environment selected, please run one of these commands":
    _dsb_err "  - 'tf-select-env'"
    _dsb_err "  - 'tf-set-env <env>'"
    return 0
  fi

  # enumerate the directories and validate the selected environment
  # populates _dsbTfSelectedEnvSubscriptionHintContent if successful
  if ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_env; then
    _dsbTfLogErrors=1
    _dsb_err "Environment check failed, please run 'tf-check-env ${selectedEnv}'"
    return 0
  fi

  # need the cli
  if ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_az_cli; then
    _dsbTfLogErrors=1
    _dsb_err "Azure CLI check failed, please run 'tf-check-prereqs'"
    return 0
  fi

  # need to be logged in
  if ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_az_enumerate_account; then
    _dsbTfLogErrors=1
    _dsb_err "Azure CLI account enumeration failed, please run 'az-whoami'"
    return 0
  fi

  # set the subscription
  if az account set --subscription "${_dsbTfSelectedEnvSubscriptionHintContent}"; then
    # updates the selected subscription global variable
    _dsb_tf_az_enumerate_account
    _dsb_d "_dsb_tf_az_set_sub(): Subscription set to: ${_dsbTfSubscriptionId}"
    _dsbTfReturnCode=0
  else
    _dsbTfLogErrors=1
    _dsb_err "Failed to set subscription."
    _dsb_err "  subscription: ${_dsbTfSelectedEnvSubscriptionHintContent}"
  fi
}

###################################################################################################
#
# Error handling
#
###################################################################################################

_dsb_tf_error_handler() {
  # Remove error trapping to prevent the error handler from being triggered
  _dsbTfReturnCode=${1:-$?}

  _dsb_tf_error_stop_trapping

  if [ "${_dsbTfReturnCode}" -ne 0 ]; then
    _dsb_err "Error occured:"
    _dsb_err "  file      : dsb-tf-proj-helpers.sh" # hardcoded because file will be sourced by curl
    _dsb_err "  line      : ${BASH_LINENO[0]} (dsb-tf-proj-helpers.sh:${BASH_LINENO[0]})"
    _dsb_err "  function  : ${FUNCNAME[1]}"
    _dsb_err "  command   : ${BASH_COMMAND}"
    _dsb_err "  exit code : ${_dsbTfReturnCode}"
    _dsb_err "Call stack:"
    for ((i = 1; i < ${#FUNCNAME[@]}; i++)); do
      _dsb_err "  ${FUNCNAME[$i]} called at (dsb-tf-proj-helpers.sh:${BASH_LINENO[$((i - 1))]})"
    done
    _dsb_err "Operation aborted."
  fi

  _dsb_tf_restore_shell

  return "${_dsbTfReturnCode}"
}

_dsb_tf_error_start_trapping() {
  # Enable strict mode with the following options:
  # -E: Inherit ERR trap in subshells
  # -o pipefail: Return the exit status of the last command in the pipeline that failed
  set -Eo pipefail

  # Signals:
  # - ERR: This signal is triggered when a command fails. It is useful for error handling in scripts.
  # - SIGHUP: This signal is sent to a process when its controlling terminal is closed. It is often used to reload configuration files.
  # - SIGINT: This signal is sent when an interrupt is generated (usually by pressing Ctrl+C). It is used to stop a process gracefully.
  trap '_dsb_tf_error_handler $?' ERR SIGHUP SIGINT
}

_dsb_tf_error_stop_trapping() {
  set +Eo pipefail
  trap - ERR SIGHUP SIGINT
}

_dsb_tf_configure_shell() {
  _dsbTfShellHistoryState=$(shopt -o history) # Save current history recording state
  set +o history                              # Disable history recording

  _dsbTfShellOldOpts=$(set +o) # Save current shell options

  # -u: Treat unset variables as an error and exit immediately
  set -u

  _dsb_tf_error_start_trapping

  # some default values
  declare -g _dsbTfLogInfo=1
  declare -g _dsbTfLogWarnings=1
  declare -g _dsbTfLogErrors=1
  declare -gA _dsbTfEnvsDirList=()
  declare -ga _dsbTfAvailableEnvs=()
  declare -gA _dsbTfModulesDirList=()
  unset _dsbTfReturnCode
}

_dsb_tf_restore_shell() {

  # Remove error trapping to prevent the error handler from being triggered
  trap - ERR SIGHUP SIGINT

  eval "$_dsbTfShellOldOpts" # Restore previous shell options

  # Restore previous history recording state
  if [[ $_dsbTfShellHistoryState =~ history[[:space:]]+off ]]; then
    set +o history
  else
    set -o history
  fi

  # clear variables
  unset _dsbTfLogInfo
  unset _dsbTfLogWarnings
  unset _dsbTfLogErrors
  unset _dsbTfReturnCode
}

###################################################################################################
#
# Tab completion
#
###################################################################################################

# for _dsbTfAvailableEnvs
# --------------------------------------------------
_dsb_tf_completions_for_avalable_envs() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  COMPREPLY=()

  # always enumerate, we do not know the directory the function is called from
  # note: debug mode must be disabled, otherwise the debug output will mess up the completions
  # TODO: does this slow things down?
  _dsbTfLogDebug=0 _dsb_tf_enumerate_directories || :

  # only complete if _dsbTfAvailableEnvs is set
  if [[ -v _dsbTfAvailableEnvs ]]; then
    if [[ -n "${_dsbTfAvailableEnvs[*]}" ]]; then
      mapfile -t COMPREPLY < <(compgen -W "${_dsbTfAvailableEnvs[*]}" -- "${cur}")
    fi
  fi
}

_dsb_tf_register_completions_for_available_envs() {
  complete -F _dsb_tf_completions_for_avalable_envs tf-set-env
  complete -F _dsb_tf_completions_for_avalable_envs tf-check-env
  complete -F _dsb_tf_completions_for_avalable_envs tf-select-env
}

# for tf-help
# --------------------------------------------------
_dsb_tf_completions_for_tf_help() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  COMPREPLY=()

  # note: debug mode must be disabled, otherwise the debug output will mess up the completions
  local -a helpTopics
  mapfile -t helpTopics < <(_dsbTfLogDebug=0 _dsb_tf_help_enumerate_supported_topics)
  if [[ -n "${helpTopics[*]}" ]]; then
    mapfile -t COMPREPLY < <(compgen -W "${helpTopics[*]}" -- "${cur}")
  fi
}

_dsb_tf_register_completions_for_tf_help() {
  complete -F _dsb_tf_completions_for_tf_help tf-help
}

# make it easier to configure the shell
_dsb_tf_register_all_completions() {
  _dsb_tf_register_completions_for_available_envs
  _dsb_tf_register_completions_for_tf_help
}

###################################################################################################
#
# Exposed functions
#
###################################################################################################

# Utility functions
# -----------------
tf-enable-debug-logging() {
  _dsbTfLogDebug=1
}

tf-disable-debug-logging() {
  unset _dsbTfLogDebug
}

# Check functions
# ---------------
tf-check-dir() {
  local returnCode

  _dsb_tf_configure_shell
  _dsb_tf_check_current_dir
  returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-check-prereqs() {
  local returnCode

  _dsb_tf_configure_shell
  _dsbTfLogErrors=0
  _dsbTfLogInfo=1
  _dsb_tf_check_prereqs
  returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-check-tools() {
  _dsb_tf_configure_shell
  _dsbTfLogErrors=1
  _dsbTfLogInfo=1

  _dsb_tf_error_stop_trapping
  _dsb_tf_check_tools
  local returnCode=$?

  if [ "${returnCode}" -ne 0 ]; then
    _dsb_err "Tools check failed."
  else
    _dsb_i "Tools check passed."
  fi

  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-status() {
  _dsb_tf_configure_shell
  _dsb_tf_report_status
  local returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

# Environment functions
# ---------------------
tf-list-envs() {
  _dsb_tf_configure_shell
  _dsb_tf_list_envs
  local returnCode="${_dsbTfReturnCode}"
  _dsb_i ""
  _dsb_i "To choose an environment, use either 'tf-set-env <env>' or 'tf-select-env'"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-set-env() {
  local envToSet="${1:-}"
  _dsb_tf_configure_shell
  _dsb_tf_set_env "${envToSet}"
  local returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-select-env() {
  local envToSet="${1:-}"
  _dsb_tf_configure_shell
  if [ -n "${envToSet}" ]; then
    _dsb_tf_set_env "${envToSet}"
  else
    _dsb_tf_select_env
  fi
  local returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-clear-env() {
  _dsb_tf_configure_shell
  _dsb_tf_clear_env # has no return code
  _dsb_tf_restore_shell
}

tf-check-env() {
  local envToCheck="${1:-}"
  _dsb_tf_configure_shell
  _dsbTfLogErrors=1
  _dsbTfLogInfo=1
  _dsb_tf_check_env "${envToCheck}"
  local returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

# Azure CLI functions
# -------------------
az-whoami() {
  _dsb_tf_configure_shell
  _dsb_tf_az_whoami
  local returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
}

az-logout() {
  _dsb_tf_configure_shell
  _dsb_tf_az_logout
  local returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

az-login() {
  _dsb_tf_configure_shell
  _dsb_tf_az_login
  local returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

az-relog() {
  _dsb_tf_configure_shell
  _dsb_tf_az_relogin
  local returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

az-set-sub() {
  _dsb_tf_configure_shell
  _dsb_tf_az_set_sub
  local returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

# Help functions
# --------------
tf-help() {
  local arg="${1:-}"
  _dsb_tf_configure_shell

  # TODO: banner and eye candy

  _dsb_tf_help "${arg}"
  _dsb_tf_restore_shell
}

###################################################################################################
#
# Code sourced message
#
###################################################################################################

# TODO banner and eye candy
_dsb_tf_enumerate_directories || :
_dsb_tf_register_all_completions || :
_dsb_i "DSB terraform project helpers loaded."
_dsb_i "  use 'tf-help' to get started."
