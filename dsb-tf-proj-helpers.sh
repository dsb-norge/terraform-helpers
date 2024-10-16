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

_dsb-err() {
  echo -e "\e[31mERROR  : $1\e[0m"
}

_dsb-i() {
  echo -e "\e[34mINFO   : \e[0m$1"
}

_dsb-w() {
  echo -e "\e[33mWARNING: $1\e[0m"
}

_dsb-tf-check-az-cli() {
  if ! az --version &>/dev/null; then
    _dsb-err "Azure CLI is not installed. Please install it from https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
    return 1
  fi
}

_dsb-tf-check-gh-cli() {
  logVerbose=${_dsbTfLogVerbose:-0}
  if ! gh --version &>/dev/null; then
    if [ "${logVerbose}" == "1" ]; then
      _dsb-err "GitHub CLI is not installed. Please install it from https://cli.github.com/"
    fi
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

  if ! (_dsbTfLogVerbose=0 _dsb-tf-check-gh-cli); then
    return 1
  fi
  if ! gh auth status &>/dev/null; then
    _dsb-err "You are not authenticated with GitHub. Please run 'gh auth login' to authenticate."
    return 1
  fi
}

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
  declare -A _dsbTfEnvsDirList
  declare -a _dsbTfAvailableEnvs
  if [ -d "${_dsbTfEnvsDir}" ]; then
    for dir in "${_dsbTfRootDir}"/envs/!(_*)/; do # this excludes directories starting with _
      _dsbTfEnvsDirList[$(basename "${dir}")]="${dir}"
      _dsbTfAvailableEnvs+=("$(basename "${dir}")")
    done
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

_dsb-tf-get-rel-dir() {
  local dirName
  dirName=$1
  realpath --relative-to="${_dsbTfRootDir}" "${dirName}"
}

_dsb-tf-look-for-main-dir() {
  if [ -d "${_dsbTfMainDir}" ]; then
    _dsb-err "Directory 'main' not found in current directory: ${_dsbTfRootDir}"
    return 1
  fi
}

_dsb-tf-look-for-envs-dir() {
  if [ -d "${_dsbTfEnvsDir}" ]; then
    _dsb-err "Directory 'envs' not found in current directory: ${_dsbTfRootDir}"
    return 1
  fi
}

_dsb-tf-check-working-dir() {
  local returnCode=0

  if ! _dsb-tf-look-for-main-dir; then returnCode=1; fi
  if ! _dsb-tf-look-for-envs-dir; then returnCode=1; fi

  return $returnCode
}

_dsb-tf-check-prereqs() {
  local logVerbose returnCode

  logVerbose=${_dsbTfLogVerbose:-0}
  returnCode=0

  _dsb-tf-enumerate-directories

  if [ "${logVerbose}" == "1" ]; then _dsb-i "Checking tools ..."; fi
  set +e
  _dsb-tf-check-tools
  toolsStatus=$?
  set -e

  if [ "${logVerbose}" == "1" ]; then _dsb-i "Checking GitHub authentication ..."; fi
  set +e
  _dsb-tf-check-gh-auth
  ghAuthStatus=$?
  set -e

  if [ "${logVerbose}" == "1" ]; then _dsb-i "Checking working directory ..."; fi
  set +e
  _dsb-tf-check-working-dir
  workingDirStatus=$?
  set -e

  returnCode=$((toolsStatus + ghAuthStatus + workingDirStatus))

  if [ "${logVerbose}" == "1" ]; then
    _dsb-i ""
    _dsb-i "Pre-requisites check summary:"
    if [ $toolsStatus -eq 0 ]; then
      _dsb-i "  \e[32m☑\e[0m  Tools check passed."
    else
      _dsb-i "  \e[31m☒\e[0m  Tools check failed."
    fi
    if [ $ghAuthStatus -eq 0 ]; then
      _dsb-i "  \e[32m☑\e[0m  GitHub authentication check passed."
    else
      _dsb-i "  \e[31m☒\e[0m  GitHub authentication check failed."
    fi
    if [ $workingDirStatus -eq 0 ]; then
      _dsb-i "  \e[32m☑\e[0m  Working directory check passed."
    else
      _dsb-i "  \e[31m☒\e[0m  Working directory check failed."
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
# Error handling
#
###################################################################################################

_dsb-tf-error-handler() {
  # Remove error trapping to prevent the error handler from being triggered
  trap - ERR SIGHUP SIGINT
  _dsbTfReturnCode=${1:-$?}

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

_dsb-tf-configure-shell() {
  _dsbTfShellHistoryState=$(shopt -o history) # Save current history recording state
  set +o history                              # Disable history recording

  _dsbTfShellOldOpts=$(set +o)                   # Save current shell options
  _dsbTfShellOldShoptExtglob=$(shopt -p extglob) # Save current extglob state

  # Enable strict mode with the following options:
  # -E: Inherit ERR trap in subshells
  # -e: Exit immediately if a command exits with a non-zero status
  # -u: Treat unset variables as an error and exit immediately
  # -o pipefail: Return the exit status of the last command in the pipeline that failed
  set -Eeuo pipefail

  # Start trapping errors
  #
  # Signals:
  # - ERR: This signal is triggered when a command fails. It is useful for error handling in scripts.
  # - SIGHUP: This signal is sent to a process when its controlling terminal is closed. It is often used to reload configuration files.
  # - SIGINT: This signal is sent when an interrupt is generated (usually by pressing Ctrl+C). It is used to stop a process gracefully.
  trap '_dsb-tf-error-handler $?' ERR SIGHUP SIGINT
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
}

###################################################################################################
#
# Exposed functions
#
###################################################################################################

tf-check-prereqs() {
  local returnCode

  _dsb-tf-configure-shell
  unset _dsbTfReturnCode
  _dsbTfLogVerbose=1 _dsb-tf-check-prereqs
  returnCode=$_dsbTfReturnCode
  _dsb-tf-restore-shell
  return $returnCode
}
