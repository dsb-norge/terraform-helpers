#!/usr/bin/env bash

# DEBUG commands
#   source ./dsb-tf-proj-helpers.sh ; pushd ./../azure-ad/ >/dev/null ; ( tf-select-env && popd >/dev/null  ) || popd >/dev/null ;

# TODO: wanted functionality
#   tf-logout         -> az logout
#   tf-login          -> az login --use-device-code
#   tf-relog          -> az logout + az login --use-device-code
#   tf-check-tools    -> need az cli, gh cli, terraform, jq, yq, golang, hcledit, terraform-docs, realpath
#   tf-check-gh-auth  -> need to be logged in to gh
#   tf-check-dir      -> check if in valid tf project structure
#   tf-check-prereqs  -> all checks
#   tf-check-env      -> check if selected env is valid
#   tf-check-env [env]-> check if supplied env is valid
#   tf-status         -> checks + help + show az upn if logged in + show sub if selected
#   tf-list-envs      -> list existing envs (exckude _*)
#   tf-set-env        -> set env/sub
#   tf-select-env     -> list + select env/sub
#
#   tf-init-env             -> terraform init in chosen env
#   tf-init-modules         -> terraform init of submodules (requires env to be selected in advance)
#   tf-init                 -> terraform init in chosen env + submodules
#   tf-fmt                  -> terraform fmt -check in chosen env
#   tf-fmt-fix              -> terraform fmt in chosen env
#   tf-validate             -> terraform validate in chosen env
#   tf-plan                 -> terraform plan in chosen env
#   tf-apply                -> terraform apply in chosen env
#   tf-clean                -> rm .terraform
#
#   tf-bump-providers       -> providers in chosen env
#   tf-bump-tflint-plugins  -> tflint-plugins in chosen env
#   tf-bump                 -> providers og tflint-plugins in chosen env
#
#   tf-init-modules   -> terraform init in chosen envs submodules
#   tf-clean-all      -> /home/peder/code/github/dsb-norge/terraform-tflint-wrappers/tf_clean.sh
#   tf-bump-gh        -> terraform and tflint in GitHub workflows
#   tf-bump-all       -> providers og tflint-plugins in alle env + terraform and tflint in GitHub workflows
#
#   Future:
#     tf-* functions for _terraform-state env

###################################################################################################
#
# Global variables
#
###################################################################################################

export _dsbTfSelectedEnv=""
export _dsbTfSelectedEnvDir=""

declare -A _dsbTfEnvsDirList   # Associative array
declare -a _dsbTfAvailableEnvs # Indexed array
_dsbTfShellOldOpts=""
_dsbTfShellHistoryState=""
_dsbTfLogInfo=""
_dsbTfLogWarnings=""
_dsbTfLogErrors=""
_dsbTfReturnCode=""

###################################################################################################
#
# Utility functions
#
###################################################################################################

_dsb_err() {
  local logErr
  logErr=${_dsbTfLogErrors:-1}
  if [ "${logErr}" == "1" ]; then
    echo -e "\e[31mERROR  : $1\e[0m"
  fi
}

_dsb_i_append() {
  local logInfo logText
  logInfo=${_dsbTfLogInfo:-1}
  logText=${1:-}
  if [ "${logInfo}" == "1" ]; then
    echo -en "${logText}\n"
  fi
}

_dsb_i_nonewline() {
  local logInfo logText
  logInfo=${_dsbTfLogInfo:-1}
  logText=${1:-}
  if [ "${logInfo}" == "1" ]; then
    echo -en "\e[34mINFO   : \e[0m${logText}"
  fi
}

_dsb_i() {
  local logText
  logText=${1:-}
  _dsb_i_nonewline "${logText}\n"
}

_dsb_w() {
  local logWarn
  logWarn=${_dsbTfLogWarnings:-1}
  if [ "${logWarn}" == "1" ]; then
    echo -e "\e[33mWARNING: $1\e[0m"
  fi
}

_dsb_tf_get_rel_dir() {
  local dirName
  dirName=$1
  realpath --relative-to="${_dsbTfRootDir}" "${dirName}"
}

###################################################################################################
#
# Check functions
#
###################################################################################################

_dsb_tf_check_az_cli() {
  if ! az --version &>/dev/null; then
    _dsb_err "Azure CLI not found."
    _dsb_err "  checked command: az --version"
    _dsb_err "  make sure az is available in your PATH"
    _dsb_err "  for installation instructions see: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
    return 1
  fi
}

_dsb_tf_check_gh_cli() {
  if ! gh --version &>/dev/null; then
    _dsb_err "GitHub CLI not found."
    _dsb_err "  checked command: gh --version"
    _dsb_err "  make sure gh is available in your PATH"
    _dsb_err "  for installation instructions see: https://github.com/cli/cli#installation"
    return 1
  fi
}

_dsb_tf_check_terraform() {
  if ! terraform -version &>/dev/null; then
    _dsb_err "Terraform not found."
    _dsb_err "  checked command: terraform -version"
    _dsb_err "  make sure terraform is available in your PATH"
    _dsb_err "  for installation instructions see: https://learn.hashicorp.com/tutorials/terraform/install-cli"
    return 1
  fi
}

_dsb_tf_check_jq() {
  if ! jq --version &>/dev/null; then
    _dsb_err "jq not found."
    _dsb_err "  checked command: jq --version"
    _dsb_err "  make sure jq is available in your PATH"
    _dsb_err "  for installation instructions see: https://stedolan.github.io/jq/download/"
    return 1
  fi
}

_dsb_tf_check_yq() {
  if ! yq --version &>/dev/null; then
    _dsb_err "yq not found."
    _dsb_err "  checked command: yq --version"
    _dsb_err "  make sure yq is available in your PATH"
    _dsb_err "  for installation instructions see: https://mikefarah.gitbook.io/yq#install"
    return 1
  fi
}

_dsb_tf_check_golang() {
  if ! go version &>/dev/null; then
    _dsb_err "Go not found."
    _dsb_err "  checked command: go version"
    _dsb_err "  make sure go is available in your PATH"
    _dsb_err "  for installation instructions see: https://go.dev/doc/install"
    return 1
  fi
}

_dsb_tf_check_hcledit() {
  if ! hcledit version &>/dev/null; then
    _dsb_err "hcledit not found."
    _dsb_err "  checked command: hcledit version"
    _dsb_err "  make sure hcledit is available in your PATH"
    _dsb_err "  for installation instructions see: https://github.com/minamijoyo/hcledit?tab=readme-ov-file#install"
    _dsb_err "  or install it with: 'go install github.com/minamijoyo/hcledit@latest; export PATH=\$PATH:\$(go env GOPATH)/bin; echo \"export PATH=\$PATH:\$(go env GOPATH)/bin\" >> ~/.bashrc'"
    return 1
  fi
}

_dsb_tf_check_terraform_docs() {
  if ! terraform-docs --version &>/dev/null; then
    _dsb_err "terraform-docs not found."
    _dsb_err "  checked command: terraform-docs --version"
    _dsb_err "  make sure terraform-docs is available in your PATH"
    _dsb_err "  for installation instructions see: https://terraform-docs.io/user-guide/installation/"
    _dsb_err "  or install it with: 'go install github.com/terraform-docs/terraform-docs@latest; export PATH=\$PATH:\$(go env GOPATH)/bin; echo \"export PATH=\$PATH:\$(go env GOPATH)/bin\" >> ~/.bashrc'"
    return 1
  fi
}

_dsb_tf_check_realpath() {
  if ! realpath --version &>/dev/null; then
    _dsb_err "realpath not found."
    _dsb_err "  checked command: realpath --version"
    _dsb_err "  make sure realpath is available in your PATH"
    _dsb_err "  install it with one of:"
    _dsb_err "    - Ubuntu: 'sudo apt-get install coreutils'"
    _dsb_err "    - OS X  : 'brew install coreutils'"
    return 1
  fi
}

_dsb_tf_check_tools() {
  local returnCode=0

  if ! _dsb_tf_check_az_cli; then returnCode=1; fi
  if ! _dsb_tf_check_gh_cli; then returnCode=1; fi
  if ! _dsb_tf_check_terraform; then returnCode=1; fi
  if ! _dsb_tf_check_jq; then returnCode=1; fi
  if ! _dsb_tf_check_yq; then returnCode=1; fi
  if ! _dsb_tf_check_golang; then returnCode=1; fi
  if ! _dsb_tf_check_hcledit; then returnCode=1; fi
  if ! _dsb_tf_check_terraform_docs; then returnCode=1; fi
  if ! _dsb_tf_check_realpath; then returnCode=1; fi

  return $returnCode
}

_dsb_tf_check_gh_auth() {
  local returnCode=0

  # allow check to pass if gh cli is not installed
  if ! (_dsbTfLogErrors=0 _dsb_tf_check_gh_cli); then
    return 0
  fi

  if ! gh auth status &>/dev/null; then
    _dsb_err "You are not authenticated with GitHub. Please run 'gh auth login' to authenticate."
    return 1
  fi
}

_dsb_tf_check_directories() {
  local returnCode=0

  if ! _dsb_tf_look_for_main_dir; then returnCode=1; fi
  if ! _dsb_tf_look_for_envs_dir; then returnCode=1; fi
  if ! _dsb_tf_look_for_lock_file; then returnCode=1; fi

  return $returnCode
}

_dsb_tf_check_current_dir() {
  local returnCode selectedEnv

  returnCode=0

  _dsb_tf_enumerate_directories
  _dsb_tf_error_stop_trapping

  _dsb_i "Checking main dir  ..."
  _dsb_tf_look_for_main_dir
  mainDirStatus=$?
  [ "${mainDirStatus}" -eq 0 ] && _dsb_i "  done."

  _dsb_i "Checking envs dir  ..."
  _dsb_tf_look_for_envs_dir
  envsDirStatus=$?
  [ "${envsDirStatus}" -eq 0 ] && _dsb_i "  done."

  _dsb_i "Checking lock file ..."
  _dsb_tf_look_for_lock_file
  lockFileStatus=$?
  [ "${lockFileStatus}" -eq 0 ] && _dsb_i "  done."

  _dsb_tf_error_start_trapping
  returnCode=$((mainDirStatus + envsDirStatus + lockFileStatus))

  _dsb_i ""
  _dsb_i "Directory check summary:"

  if [ "${mainDirStatus}" -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  Main directory check: passed."
  else
    _dsb_i "  \e[31m☒\e[0m  Main directory check: failed."
  fi

  if [ "${envsDirStatus}" -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  Environments directory check: passed."
  else
    _dsb_i "  \e[31m☒\e[0m  Environments directory check: failed."
  fi

  selectedEnv="${_dsbTfSelectedEnv:-}"
  # DEBUG
  echo "DEBUG: selectedEnv: ${selectedEnv}"

  if [ "${lockFileStatus}" -eq 0 ]; then
    if [ -z "${selectedEnv}" ]; then
      _dsb_i "  ☐  Lock file check: N/A, no environment selected, please run 'tf-select-env'"
    else
      _dsb_i "  \e[32m☑\e[0m  Lock file check: passed."
    fi
  else
    _dsb_i "  \e[31m☒\e[0m  Lock file check: failed."
  fi

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
  local returnCode

  _dsbTfLogErrors=0
  _dsbTfLogInfo=1
  returnCode=0

  _dsb_tf_enumerate_directories
  _dsb_tf_error_stop_trapping

  _dsb_i_nonewline "Checking tools ..."
  _dsb_tf_check_tools
  toolsStatus=$?
  _dsb_i_append " done."

  _dsb_i_nonewline "Checking GitHub authentication ..."
  _dsb_tf_check_gh_auth
  ghAuthStatus=$?
  _dsb_i_append " done."

  _dsb_i_nonewline "Checking working directory ..."
  _dsb_tf_check_directories
  workingDirStatus=$?
  _dsb_i_append " done."

  _dsbTfLogErrors=1
  _dsb_tf_error_start_trapping
  returnCode=$((toolsStatus + ghAuthStatus + workingDirStatus))

  _dsb_i ""
  _dsb_i "Pre-requisites check summary:"
  if [ $toolsStatus -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  Tools check: passed."
  else
    _dsb_i "  \e[31m☒\e[0m  Tools check: failed, please run 'tf-check-tools'"
  fi
  if [ $ghAuthStatus -eq 0 ]; then
    if ! (_dsbTfLogErrors=0 _dsb_tf_check_gh_cli); then
      _dsb_i "  ☐  GitHub authentication check: N/A, please run 'tf-check-tools'"
    else
      _dsb_i "  \e[32m☑\e[0m  GitHub authentication check: passed."
    fi
  else
    _dsb_i "  \e[31m☒\e[0m  GitHub authentication check: failed."
  fi
  if [ $workingDirStatus -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  Working directory check: passed."
  else
    _dsb_i "  \e[31m☒\e[0m  Working directory check: failed, please run 'tf-check-dir'"
  fi

  _dsb_i ""
  if [ $returnCode -eq 0 ]; then
    _dsb_i "\e[32mAll pre-reqs check passed.\e[0m"
  else
    _dsb_err "\e[31mPre-reqs check failed, for more information see above.\e[0m"
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

  unset _dsbTfModulesDirList
  declare -A _dsbTfModulesDirList
  if [ -d "${_dsbTfModulesDir}" ]; then
    for dir in "${_dsbTfRootDir}"/modules/*; do
      _dsbTfModulesDirList[$(basename "${dir}")]="${dir}"
    done
  fi

  # unset _dsbTfEnvsDirList
  # unset _dsbTfAvailableEnvs
  _dsbTfEnvsDirList=()
  _dsbTfAvailableEnvs=()
  # declare -A _dsbTfEnvsDirList   # Associative array
  # declare -a _dsbTfAvailableEnvs # Indexed array
  local item
  if [ -d "${_dsbTfEnvsDir}" ]; then
    # DEBUG
    # echo "DEBUG: Enumerating environments ..."
    for item in "${_dsbTfRootDir}"/envs/*; do
      if [ -d "${item}" ]; then # is a directory
        # this exclude directories starting with _
        if [[ "$(basename "${item}")" =~ ^_ ]]; then
          continue
        fi
        # DEBUG
        # echo "DEBUG: Found environment: $(basename "${item}")"
        _dsbTfEnvsDirList[$(basename "${item}")]="${item}"
        _dsbTfAvailableEnvs+=("$(basename "${item}")")
      fi
    done

    local selectedEnv envFound

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
    selectedEnv="${_dsbTfSelectedEnv:-}"
    envFound=0
    if [ -n "${selectedEnv}" ]; then # string is not empty
      for env in "${_dsbTfAvailableEnvs[@]}"; do
        if [ "${env}" == "${selectedEnv}" ]; then
          envFound=1
          break
        fi
      done
      if [ "${envFound}" -eq 1 ]; then
        # DEBUG
        echo "DEBUG: in _dsb_tf_enumerate_directories : found selectedEnv: ${selectedEnv}"
        _dsbTfSelectedEnvDir="${_dsbTfEnvsDirList["${selectedEnv}"]}"
      else
        # DEBUG
        echo "DEBUG: in _dsb_tf_enumerate_directories : unset _dsbTfSelectedEnv"
        echo "DEBUG: in _dsb_tf_enumerate_directories : unset _dsbTfSelectedEnvDir"
        # unset _dsbTfSelectedEnv
        # unset _dsbTfSelectedEnvDir
        _dsbTfSelectedEnv=""
        _dsbTfSelectedEnvDir=""
      fi
    fi
  fi

  # DEBUG
  # echo "Root dir: ${_dsbTfRootDir}"
  # echo "Modules dir: ${_dsbTfModulesDir}"
  # echo "Main dir: ${_dsbTfMainDir}"
  # echo "Envs dir: ${_dsbTfEnvsDir}"
  # echo "Modules dir list:"
  # for key in "${!_dsbTfModulesDirList[@]}"; do
  #   echo "  - ${key}: ${_dsbTfModulesDirList[$key]}"
  # done
  # echo "Envs dir list:"
  # for key in "${!_dsbTfEnvsDirList[@]}"; do
  #   echo "  - ${key}: ${_dsbTfEnvsDirList[$key]}"
  # done
  # echo "DEBUG: in _dsb_tf_enumerate_directories : _dsbTfAvailableEnvs: ${_dsbTfAvailableEnvs[*]}"
  # echo "Available envs:"
  # for dir in "${_dsbTfAvailableEnvs[@]}"; do
  #   echo "  - ${dir}"
  # done
}

_dsb_tf_look_for_main_dir() {
  if [ ! -d "${_dsbTfMainDir}" ]; then
    _dsb_err "Directory 'main' not found in current directory: ${_dsbTfRootDir}"
    return 1
  fi
}

_dsb_tf_look_for_envs_dir() {
  if [ ! -d "${_dsbTfEnvsDir}" ]; then
    _dsb_err "Directory 'envs' not found in current directory: ${_dsbTfRootDir}"
    return 1
  fi
}

_dsb_tf_look_for_lock_file() {
  local selectedEnv selectedEnvDir

  selectedEnv="${_dsbTfSelectedEnv:-}"
  selectedEnvDir="${_dsbTfSelectedEnvDir:-}"

  # DEBUG
  echo "DEBUG: in _dsb_tf_look_for_lock_file : _dsbTfSelectedEnv: ${_dsbTfSelectedEnv}"
  echo "DEBUG: in _dsb_tf_look_for_lock_file : selectedEnv: ${selectedEnv}"
  echo "DEBUG: in _dsb_tf_look_for_lock_file : selectedEnvDir: ${selectedEnvDir}"

  # we allow the check to pass if no environment is selected
  if [ -z "${selectedEnv}" ]; then return 0; fi

  # expect _dsbTfSelectedEnvDir to be set if an environment is selected
  if [ -z "${selectedEnvDir}" ]; then
    _dsbTfLogErrors=1
    _dsb_tf_error_start_trapping
    _dsb_err "Internal error: environment set in '_dsbTfSelectedEnv', but '_dsbTfSelectedEnvDir' was not set."
    _dsb_err "  Selected environment: ${selectedEnv}"
    return 1
  fi

  # expect _dsbTfSelectedEnvDir to be a directory
  if [ ! -d "${selectedEnvDir}" ]; then
    _dsbTfLogErrors=1
    _dsb_tf_error_start_trapping
    _dsb_err "Internal error: environment set in '_dsbTfSelectedEnv', but directory not found."
    _dsb_err "  Selected environment: ${selectedEnv}"
    _dsb_err "  Expected directory: ${selectedEnvDir}"
    return 1
  fi

  # require that a lock file exists in the environment directory to be considered a valid environment
  if [ ! -f "${selectedEnvDir}/.terraform.lock.hcl" ]; then
    _dsb_err "Lock file not found in selected environment. A lock file is required for an environment to be considered valid."
    _dsb_err "  Selected environment: ${selectedEnv}"
    _dsb_err "  Expected lock file: ${selectedEnvDir}/.terraform.lock.hcl"
    return 1
  fi
}

###################################################################################################
#
# Environment
#
###################################################################################################

_dsb_tf_select_env() {
  local dirCheckStatus

  _dsbTfLogErrors=0
  _dsbTfLogInfo=1

  # DEBUG
  # echo "DEBUG: in _dsb_tf_select_env before enumerate _dsbTfAvailableEnvs: ${_dsbTfAvailableEnvs[*]}"

  _dsb_tf_enumerate_directories

  # DEBUG
  # echo "DEBUG: in _dsb_tf_select_env after enumerate _dsbTfAvailableEnvs: ${_dsbTfAvailableEnvs[*]}"

  _dsb_tf_error_stop_trapping
  _dsb_tf_check_directories
  dirCheckStatus=$?
  if [ "${dirCheckStatus}" -ne 0 ]; then
    _dsbTfLogErrors=1
    _dsb_err "Directory check(s) fails, please run 'tf-check-dir'"
    _dsbTfReturnCode=1
    return 0 # caller reads _dsbTfReturnCode
  fi

  if [ -z "${_dsbTfAvailableEnvs[*]}" ]; then
    _dsbTfLogErrors=1
    _dsb_tf_error_start_trapping
    _dsb_err "Internal error: in _dsb_tf_select_env, expected to find available environments."
    _dsb_err "  expected in: _dsbTfAvailableEnvs"
    _dsb_err "  for more information see above."
    return 1
  fi

  _dsb_tf_error_start_trapping

  # DEBUG
  # echo "DEBUG: _dsbTfAvailableEnvs: ${_dsbTfAvailableEnvs[*]}"

  local envIdx envDir
  envIdx=1
  _dsb_i "Available environments:"
  for envDir in "${_dsbTfAvailableEnvs[@]}"; do
    _dsb_i "  $((envIdx++))) ${envDir}"
  done

  local -a validChoices
  mapfile -t validChoices < <(seq 1 $((--envIdx)))

  local gotValidInput userInput idx
  gotValidInput=0
  while [ "${gotValidInput}" -ne 1 ]; do
    read -r -p "Enter index of environment to set: " userInput
    for idx in "${validChoices[@]}"; do
      if [ "${idx}" == "${userInput}" ]; then
        gotValidInput=1
        # DEBUG
        # echo "DEBUG: idx = ${idx} is valid"
        break
      fi
    done
  done

  # TODO: create internal function _dsb_tf_set_env and exposed function tf-set-env

  _dsbTfSelectedEnv="${_dsbTfAvailableEnvs[$((userInput - 1))]}"
  _dsbTfSelectedEnvDir="${_dsbTfEnvsDirList["${_dsbTfSelectedEnv}"]}"

  _dsb_i "Selected environment: ${_dsbTfSelectedEnv}"
  # _dsb_i "Selected environment directory: ${_dsbTfSelectedEnvDir}"

  # check if the selected environment is valid
  _dsbTfLogErrors=0
  _dsb_tf_error_stop_trapping
  _dsb_tf_look_for_lock_file
  _dsbTfReturnCode=$? # caller reads this

  if [ "${_dsbTfReturnCode}" -ne 0 ]; then
    _dsbTfLogErrors=1
    _dsb_err "Lock file check failed, please run 'tf-check-env ${_dsbTfSelectedEnv}'"
  fi

  return 0 # caller reads _dsbTfReturnCode
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
    _dsb_err "  file      : ${BASH_SOURCE[1]}"
    _dsb_err "  line      : ${BASH_LINENO[0]}"
    _dsb_err "  function  : ${FUNCNAME[1]}"
    _dsb_err "  command   : ${BASH_COMMAND}"
    _dsb_err "  exit code : ${_dsbTfReturnCode}"
    _dsb_err "Operation aborted."
  fi

  _dsb_tf_restore_shell

  return ${_dsbTfReturnCode}
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
  _dsbTfLogInfo=1
  _dsbTfLogWarnings=1
  _dsbTfLogErrors=1
  unset _dsbTfReturnCode

  declare -A _dsbTfEnvsDirList   # Associative array
  declare -a _dsbTfAvailableEnvs # Indexed array
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
  # unset _dsbTfShellOldOpts
  # unset _dsbTfShellHistoryState
  unset _dsbTfLogInfo
  unset _dsbTfLogWarnings
  unset _dsbTfLogErrors
  unset _dsbTfReturnCode
}

###################################################################################################
#
# Exposed functions
#
###################################################################################################

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
  _dsb_tf_check_prereqs
  returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-select-env() {
  local selectedEnv

  _dsb_tf_configure_shell
  _dsb_tf_select_env
  returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}
