#!/usr/bin/env bash

# shopt -s extglob # enable extended globbing

# TODO: wanted functionality
#   tf-logout         -> az logout
#   tf-login          -> az login --use-device-code
#   tf-relog          -> az logout + az login --use-device-code
#   tf-check-tools    -> need az cli, gh cli, terraform, jq, yq, golang, hcledit, terraform-docs, realpath
#   tf-check-gh-auth  -> need to be logged in to gh
#   tf-check-dir      -> check if in valid tf project structure
#   tf-check-prereqs  -> all checks
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
# Utility functions
#
###################################################################################################

_dsb-err() {
  local logErr
  logErr=${_dsbTfLogErrors:-1}
  if [ "${logErr}" == "1" ]; then
    echo -e "\e[31mERROR  : $1\e[0m"
  fi
}

_dsb-i-append() {
  local logInfo logText
  logInfo=${_dsbTfLogInfo:-1}
  logText=${1:-}
  if [ "${logInfo}" == "1" ]; then
    echo -en "${logText}\n"
  fi
}

_dsb-i-nonewline() {
  local logInfo logText
  logInfo=${_dsbTfLogInfo:-1}
  logText=${1:-}
  if [ "${logInfo}" == "1" ]; then
    echo -en "\e[34mINFO   : \e[0m${logText}"
  fi
}

_dsb-i() {
  local logText
  logText=${1:-}
  _dsb-i-nonewline "${logText}\n"
}

_dsb-w() {
  local logWarn
  logWarn=${_dsbTfLogWarnings:-1}
  if [ "${logWarn}" == "1" ]; then
    echo -e "\e[33mWARNING: $1\e[0m"
  fi
}

_dsb-tf-get-rel-dir() {
  local dirName
  dirName=$1
  realpath --relative-to="${_dsbTfRootDir}" "${dirName}"
}

###################################################################################################
#
# Check functions
#
###################################################################################################

_dsb-tf-check-az-cli() {
  if ! az --version &>/dev/null; then
    _dsb-err "Azure CLI is not installed. Please install it from https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
    return 1
  fi
}

_dsb-tf-check-gh-cli() {
  if ! gh --version &>/dev/null; then
    _dsb-err "GitHub CLI is not installed. Please install it from https://cli.github.com/"
    return 1
  fi
}

_dsb-tf-check-terraform() {
  if ! terraform -version &>/dev/null; then
    _dsb-err "Terraform is not installed. Please install it from https://learn.hashicorp.com/tutorials/terraform/install-cli"
    return 1
  fi
}

_dsb-tf-check-jq() {
  if ! jq --version &>/dev/null; then
    _dsb-err "jq is not installed. Please install it from https://stedolan.github.io/jq/download/"
    return 1
  fi
}

_dsb-tf-check-yq() {
  if ! yq --version &>/dev/null; then
    _dsb-err "yq is not installed. Please install it from https://github.com/mikefarah/yq"
    return 1
  fi
}

_dsb-tf-check-golang() {
  if ! go version &>/dev/null; then
    _dsb-err "Go is not installed. Please install it from https://golang.org/doc/install"
    return 1
  fi
}

_dsb-tf-check-hcledit() {
  if ! hcledit version &>/dev/null; then
    _dsb-err "hcledit is not installed. Please install it with: 'go install github.com/minamijoyo/hcledit@latest; export PATH=\$PATH:\$(go env GOPATH)/bin; echo \"export PATH=\$PATH:\$(go env GOPATH)/bin\" >> ~/.bashrc'"
    return 1
  fi
}

_dsb-tf-check-terraform-docs() {
  if ! terraform-docs --version &>/dev/null; then
    _dsb-err "terraform-docs is not installed. Please install it with: 'go install github.com/terraform-docs/terraform-docs@v0.19.0; export PATH=\$PATH:\$(go env GOPATH)/bin; echo \"export PATH=\$PATH:\$(go env GOPATH)/bin\" >> ~/.bashrc'"
    return 1
  fi
}

_dsb-tf-check-realpath() {
  if ! realpath --version &>/dev/null; then
    _dsb-err "realpath is not installed. Please install it with: 'sudo apt install realpath'"
    return 1
  fi
}

_dsb-tf-check-tools() {
  local returnCode=0

  if ! _dsb-tf-check-az-cli; then returnCode=1; fi
  if ! _dsb-tf-check-gh-cli; then returnCode=1; fi
  if ! _dsb-tf-check-terraform; then returnCode=1; fi
  if ! _dsb-tf-check-jq; then returnCode=1; fi
  if ! _dsb-tf-check-yq; then returnCode=1; fi
  if ! _dsb-tf-check-golang; then returnCode=1; fi
  if ! _dsb-tf-check-hcledit; then returnCode=1; fi
  if ! _dsb-tf-check-terraform-docs; then returnCode=1; fi
  if ! _dsb-tf-check-realpath; then returnCode=1; fi

  return $returnCode
}

_dsb-tf-check-gh-auth() {
  local returnCode=0

  # fail check if gh cli is not installed
  if ! (_dsbTfLogErrors=0 _dsb-tf-check-gh-cli); then
    return 1
  fi

  if ! gh auth status &>/dev/null; then
    _dsb-err "You are not authenticated with GitHub. Please run 'gh auth login' to authenticate."
    return 1
  fi
}

_dsb-tf-check-directories() {
  local returnCode=0

  if ! _dsb-tf-look-for-main-dir; then returnCode=1; fi
  if ! _dsb-tf-look-for-envs-dir; then returnCode=1; fi
  if ! _dsb-tf-look-for-lock-file; then returnCode=1; fi

  return $returnCode
}

_dsb-tf-check-current-dir() {
  local returnCode selectedEnv

  _dsbTfLogErrors=1
  _dsbTfLogInfo=1
  returnCode=0

  _dsb-tf-enumerate-directories
  _dsb-tf-error-stop-trapping

  _dsb-i "Checking main dir  ..."
  _dsb-tf-look-for-main-dir
  mainDirStatus=$?
  [ $mainDirStatus -eq 0 ] && _dsb-i "  done."

  _dsb-i "Checking envs dir  ..."
  _dsb-tf-look-for-envs-dir
  envsDirStatus=$?
  [ $envsDirStatus -eq 0 ] && _dsb-i "  done."

  _dsb-i "Checking lock file ..."
  _dsb-tf-look-for-lock-file
  lockFileStatus=$?
  [ $lockFileStatus -eq 0 ] && _dsb-i "  done."

  _dsb-tf-error-start-trapping
  returnCode=$((mainDirStatus + envsDirStatus + lockFileStatus))

  _dsb-i ""
  _dsb-i "Directory check summary:"

  if [ $mainDirStatus -eq 0 ]; then
    _dsb-i "  \e[32m☑\e[0m  Main directory check passed."
  else
    _dsb-i "  \e[31m☒\e[0m  Main directory check failed."
  fi

  if [ $envsDirStatus -eq 0 ]; then
    _dsb-i "  \e[32m☑\e[0m  Environments directory check passed."
  else
    _dsb-i "  \e[31m☒\e[0m  Environments directory check failed."
  fi

  selectedEnv="${_dsbTfSelectedEnv:-}"
  if [ $lockFileStatus -eq 0 ]; then
    if [ -z "${selectedEnvDir}" ]; then
      _dsb-i "  ☐  N/A - no environment selected."
    else
      _dsb-i "  \e[32m☑\e[0m  Lock file check passed."
    fi
  else
    _dsb-i "  \e[31m☒\e[0m  Lock file check failed."
  fi

  _dsb-i ""
  if [ $returnCode -eq 0 ]; then
    _dsb-i "\e[32mAll directory checks passed.\e[0m"
  else
    _dsb-err "Directory check(s) failed, the current directory does not seem to be a valid Terraform project."
    _dsb-err "  directory checked: ${_dsbTfRootDir}"
    _dsb-err "  for more information see above."
  fi

  _dsbTfReturnCode=$returnCode
}

_dsb-tf-check-prereqs() {
  local logVerbose returnCode

  logVerbose=${_dsbTfLogVerbose:-0}
  returnCode=0

  _dsb-tf-enumerate-directories
  _dsb-tf-error-stop-trapping

  if [ "${logVerbose}" == "1" ]; then _dsb-i "Checking tools ..."; fi
  _dsb-tf-check-tools
  toolsStatus=$?

  if [ "${logVerbose}" == "1" ]; then _dsb-i "Checking GitHub authentication ..."; fi
  _dsb-tf-check-gh-auth
  ghAuthStatus=$?

  if [ "${logVerbose}" == "1" ]; then _dsb-i "Checking working directory ..."; fi
  _dsb-tf-check-directories
  workingDirStatus=$?

  _dsb-tf-error-start-trapping
  returnCode=$((toolsStatus + ghAuthStatus + workingDirStatus))

  if [ "${logVerbose}" == "1" ]; then
    _dsb-i ""
    _dsb-i "Pre-requisites check summary:"
    if [ $toolsStatus -eq 0 ]; then
      _dsb-i "  \e[32m☑\e[0m  Tools check passed."
    else
      _dsb-i "  \e[31m☒\e[0m  Tools check failed"
    fi
    if [ $ghAuthStatus -eq 0 ]; then
      _dsb-i "  \e[32m☑\e[0m  GitHub authentication check passed."
    else
      _dsb-i "  \e[31m☒\e[0m  GitHub authentication check failed."
    fi
    if [ $workingDirStatus -eq 0 ]; then
      _dsb-i "  \e[32m☑\e[0m  Working directory check passed."
    else
      _dsb-i "  \e[31m☒\e[0m  Working directory check failed, for more information, run 'tf-check-dir'"
    fi
    if [ $returnCode -eq 0 ]; then
      _dsb-i "\e[32mAll pre-reqs check passed.\e[0m"
    else
      _dsb-err "\e[31mPre-reqs check failed.\e[0m"
    fi
  fi

  _dsbTfReturnCode=$returnCode
}

###################################################################################################
#
# Directory enumeration
#
###################################################################################################

_dsb-tf-enumerate-directories() {
  local old_shopt_extglob

  old_shopt_extglob=$(shopt -p extglob) # Save current extglob state
  shopt -s extglob                      # Enable extended globbing

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

  unset _dsbTfEnvsDirList
  unset _dsbTfAvailableEnvs
  declare -A _dsbTfEnvsDirList   # Associative array
  declare -a _dsbTfAvailableEnvs # Indexed array
  if [ -d "${_dsbTfEnvsDir}" ]; then
    for dir in "${_dsbTfRootDir}"/envs/!(_*)/; do # this excludes directories starting with _
      _dsbTfEnvsDirList[$(basename "${dir}")]="${dir}"
      _dsbTfAvailableEnvs+=("$(basename "${dir}")")
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
        _dsbTfSelectedEnvDir="${_dsbTfEnvsDirList["${selectedEnv}"]}"
      else
        unset _dsbTfSelectedEnv
        unset _dsbTfSelectedEnvDir
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
  # echo "Available envs:"
  # for dir in "${_dsbTfAvailableEnvs[@]}"; do
  #   echo "  - ${dir}"
  # done

  eval "$old_shopt_extglob" # Restore previous extglob state
}

_dsb-tf-look-for-main-dir() {
  if [ ! -d "${_dsbTfMainDir}" ]; then
    _dsb-err "Directory 'main' not found in current directory: ${_dsbTfRootDir}"
    return 1
  fi
}

_dsb-tf-look-for-envs-dir() {
  if [ ! -d "${_dsbTfEnvsDir}" ]; then
    _dsb-err "Directory 'envs' not found in current directory: ${_dsbTfRootDir}"
    return 1
  fi
}

_dsb-tf-look-for-lock-file() {
  local selectedEnv

  selectedEnv="${_dsbTfSelectedEnv:-}"
  selectedEnvDir="${_dsbTfSelectedEnvDir:-}"

  # we allow the check to pass if no environment is selected
  if [ -z "${selectedEnv}" ]; then return 0; fi

  # expect _dsbTfSelectedEnvDir to be set if an environment is selected
  if [ -z "${selectedEnvDir}" ]; then
    _dsb-err "Internal error: environment set in '_dsbTfSelectedEnv', but '_dsbTfSelectedEnvDir' was not set."
    _dsb-err "  Selected environment: ${selectedEnv}"
    return 1
  fi

  # expect _dsbTfSelectedEnvDir to be a directory
  if [ ! -d "${selectedEnvDir}" ]; then
    _dsb-err "Internal error: environment set in '_dsbTfSelectedEnv', but directory not found."
    _dsb-err "  Selected environment: ${selectedEnv}"
    _dsb-err "  Expected directory: ${selectedEnvDir}"
    return 1
  fi

  # require that a lock file exists in the environment directory to be considered a valid environment
  if [ ! -f "${selectedEnvDir}/.terraform.lock.hcl" ]; then
    _dsb-err "Lock file not found in selected environment. A lock file is required for an environment to be considered valid."
    _dsb-err "  Selected environment: ${selectedEnv}"
    _dsb-err "  Expected lock file: ${selectedEnvDir}/.terraform.lock.hcl"
    return 1
  fi
}

###################################################################################################
#
# Error handling
#
###################################################################################################

_dsb-tf-error-handler() {
  # Remove error trapping to prevent the error handler from being triggered
  _dsbTfReturnCode=${1:-$?}

  _dsb-tf-error-stop-trapping

  if [ "${_dsbTfReturnCode}" -ne 0 ]; then
    _dsb-err "Error occured:"
    _dsb-err "  file      : ${BASH_SOURCE[1]}"
    _dsb-err "  line      : ${BASH_LINENO[0]}"
    _dsb-err "  function  : ${FUNCNAME[1]}"
    _dsb-err "  command   : ${BASH_COMMAND}"
    _dsb-err "  exit code : ${_dsbTfReturnCode}"
    _dsb-err "Operation aborted."
  fi

  _dsb-tf-restore-shell

  return "${_dsbTfReturnCode}"
}

_dsb-tf-error-start-trapping() {
  # Enable strict mode with the following options:
  # -E: Inherit ERR trap in subshells
  # -o pipefail: Return the exit status of the last command in the pipeline that failed
  set -Eo pipefail

  # Signals:
  # - ERR: This signal is triggered when a command fails. It is useful for error handling in scripts.
  # - SIGHUP: This signal is sent to a process when its controlling terminal is closed. It is often used to reload configuration files.
  # - SIGINT: This signal is sent when an interrupt is generated (usually by pressing Ctrl+C). It is used to stop a process gracefully.
  trap '_dsb-tf-error-handler $?' ERR SIGHUP SIGINT
}

_dsb-tf-error-stop-trapping() {
  set +Eo pipefail
  trap - ERR SIGHUP SIGINT
}

_dsb-tf-configure-shell() {
  _dsbTfShellHistoryState=$(shopt -o history) # Save current history recording state
  set +o history                              # Disable history recording

  _dsbTfShellOldOpts=$(set +o)                   # Save current shell options
  _dsbTfShellOldShoptExtglob=$(shopt -p extglob) # Save current extglob state

  # -u: Treat unset variables as an error and exit immediately
  set -u

  _dsb-tf-error-start-trapping

  # some default values
  _dsbTfLogInfo=1
  _dsbTfLogWarnings=1
  _dsbTfLogErrors=1
  unset _dsbTfReturnCode
}

_dsb-tf-restore-shell() {

  # Remove error trapping to prevent the error handler from being triggered
  trap - ERR SIGHUP SIGINT

  eval "$_dsbTfShellOldOpts"         # Restore previous shell options
  eval "$_dsbTfShellOldShoptExtglob" # Restore previous extglob state

  # Restore previous history recording state
  if [[ $_dsbTfShellHistoryState =~ history[[:space:]]+off ]]; then
    set +o history
  else
    set -o history
  fi

  # clear variables
  unset _dsbTfShellOldOpts
  unset _dsbTfShellOldShoptExtglob
  unset _dsbTfShellHistoryState
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

  _dsb-tf-configure-shell
  _dsb-tf-check-current-dir
  returnCode="${_dsbTfReturnCode}"
  _dsb-tf-restore-shell
  return "${returnCode}"
}

tf-check-prereqs() {
  local returnCode

  _dsb-tf-configure-shell
  unset _dsbTfReturnCode
  _dsbTfLogVerbose=1 _dsb-tf-check-prereqs
  returnCode="${_dsbTfReturnCode}"
  _dsb-tf-restore-shell
  return "${returnCode}"
}
