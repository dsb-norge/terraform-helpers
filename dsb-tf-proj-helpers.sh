#!/usr/bin/env bash
{ # this ensures the entire script is downloaded before execution

# Require bash 4.3+ for associative arrays, namerefs, etc.
if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ] || \
   { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 3 ]; }; then
  echo "ERROR: dsb-tf-proj-helpers.sh requires bash 4.3 or later (current: ${BASH_VERSION:-unknown})" >&2
  # shellcheck disable=SC2317 # exit 1 is the fallback when not sourced (return fails)
  return 1 2>/dev/null || exit 1
fi

# cSpell: ignore dsb, tflint, azurerm, az, tf, gh, cpanm, realpath, tfupdate, coreutils, grealpath, nonewline, prereq, prereqs, commaseparated, graphviz, libexpat, mktemp, wedi, relog, cicd, hcledit, CWORD, GOPATH, minamijoyo, reqs, chdir, alnum, ruleset, xclip, xsel, gcut, tfstate, tftest, namerefs, Iseconds
#
# Developer notes
#
#   about global variables:
#     this script uses global variables to persist data between function calls and user invocations
#     all global variables should prefixed with '_dsbTf'. this is both to avoid conflicts with other scripts
#     and to make it possible during initialization to remove potential global variables left by previous
#     versions of the script
#
#   types of functions in this file:
#     "exposed" functions
#       are those prefixed with 'tf-' and 'az-'
#       these are the functions that are intended to be called by the user from the command line
#       these are supported by tf-help
#       these should always return their exit code directly
#       they include a set -e neutralization guard and the configure/restore shell lifecycle
#
#     internal functions
#       are those prefixed with '_dsb_'
#       these are not intended to be called directly from the command line
#       they always return their exit code directly (return 0 for success, return 1 for failure)
#       many of these populate global variables to persist results
#       on failure, they push context to the error stack via _dsb_tf_error_push
#
#     utility functions
#       are also prefixed with '_dsb_'
#       these are not intended to be called directly from the command line
#       typically they do not return exit code explicitly
#       they are for things like logging, error handling, displaying help, and other common tasks
#
#   error handling:
#     all functions return their exit code directly -- there is no global return code variable
#     there is no ERR trap, no set -e, no set -E, no pipefail during execution
#     _dsb_tf_configure_shell establishes a known shell state (only set -u is enabled)
#     a global error context stack (_dsbTfErrorStack) provides rich diagnostics
#     see DEVELOPER-ERROR-HANDLING.md for the full guide
#
#   logging
#     logging throughout the functions is controlled by the following variables:
#       _dsbTfLogInfo     : 1 to log info, 0 to mute
#       _dsbTfLogWarnings : 1 to log warnings, 0 to mute
#       _dsbTfLogErrors   : 1 to log errors, 0 to mute
#         note: _dsb_internal_error() ignores this setting
#     debug logging should be controlled from the command line by calling
#       _dsb_tf_debug_enable_debug_logging
#       _dsb_tf_debug_disable_debug_logging
#
#   debug functionality
#     debug logging can be enabled from the command line by calling
#       _dsb_tf_debug_enable_debug_logging
#     debug logging can be disabled from the command line by calling
#       _dsb_tf_debug_disable_debug_logging
#
#   maintenance and development
#     call graph functionality can be installed from the command line by calling
#       _dsb_tf_debug_install_call_graph_and_deps_ubuntu
#     call graphs can be generated from the command line
#       for all exposed functions:
#         _dsb_tf_debug_generate_call_graphs
#       for a single function (note: only non-exposed functions can be used):
#         _dsb_tf_debug_generate_call_graphs '_dsb_tf_enumerate_directories'
#
#
#   repo type detection and module support:
#     the script detects the repo type at enumeration time:
#       "project" - has main/ and envs/ directories (traditional DSB project structure)
#       "module"  - has .tf files at root, no main/ or envs/ (published Terraform module)
#       ""        - unknown/invalid
#     the repo type is stored in _dsbTfRepoType
#     project-only functions are gated with _dsb_tf_require_project_repo
#     functions that work in both repo types branch on _dsbTfRepoType
#
# TODO: future functionality
#   other
#     tf-* functions support for _terraform-state env
#

###################################################################################################
#
# Init: remove any old code remnants
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
  local cutCmd

  # MacOS: GNU commands mapping
  if [[ $(uname -m) == "arm64" ]]; then
    cutCmd="gcut"
  fi
  # ARM64 Linux
  if [[ $(uname -m) == "aarch64" ]] && [[ $(uname -s) == "Linux" ]]; then
    cutCmd="cut"
  fi
  # x86_64 Linux
  if [[ $(uname -m) == "x86_64" ]] && [[ $(uname -s) == "Linux" ]]; then
    cutCmd="cut"
  fi

  # run just if cut command is set
  if [ -n "${cutCmd}" ]; then
    functionNames=$(declare -F | grep -e " ${prefix}" | "${cutCmd}" --fields 3 --delimiter=' ') || functionNames=''
    for functionName in ${functionNames}; do
      unset -f "${functionName}" || :
    done
  fi
}

# functions with known prefixes
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
# Init: global variables
#
###################################################################################################

declare -g _dsbTfShellOldOpts=""      # used for persisting original shell options, and restoring them on exit
declare -g _dsbTfShellHistoryState="" # used for persisting original shell history state, and restoring it on exit

declare -g _dsbTfRootDir=""      # root directory of the project, ie. the current directory when a function is called
declare -g _dsbTfEnvsDir=""      # environments directory of the project
declare -g _dsbTfMainDir=""      # main directory of the project
declare -g _dsbTfModulesDir=""   # modules directory of the project
declare -ga _dsbTfFilesList      # Indexed array, list of all .tf files in the project
declare -gA _dsbTfEnvsDirList    # Associative array, key is environment name, value is directory
declare -ga _dsbTfAvailableEnvs  # Indexed array, list of available environment names in the project
declare -gA _dsbTfModulesDirList # Associative array, key is module name, value is directory

declare -g _dsbTfTflintWrapperDir=""  # directory where the tflint wrapper script will be placed
declare -g _dsbTfTflintWrapperPath="" # full path to the tflint wrapper script

declare -g _dsbTfRealpathCmd="" # the command to use for realpath
declare -g _dsbTfCutCmd=""      # the command to use for cut
declare -g _dsbTfMvCmd=""       # the command to use for mv

declare -g _dsbTfSelectedEnv=""                        # the currently selected environment is persisted here
declare -g _dsbTfSelectedEnvDir=""                     # full path to the directory of the currently selected environment
declare -g _dsbTfSelectedEnvLockFile=""                # full path to the lock file of the currently selected environment
declare -g _dsbTfSelectedEnvSubscriptionHintFile=""    # full path to the subscription hint file of the currently selected environment
declare -g _dsbTfSelectedEnvSubscriptionHintContent="" # content of the subscription hint file of the currently selected environment

declare -g _dsbTfAzureUpn=""         # Azure UPN of the currently logged in user
declare -g _dsbTfSubscriptionId=""   # Azure subscription ID of the currently selected subscription
declare -g _dsbTfSubscriptionName="" # Azure subscription name of the currently selected subscription

# Module repo support
declare -g _dsbTfRepoType=""                    # "project", "module", or "" (unknown/invalid)
declare -g _dsbTfExamplesDir=""                  # path to examples directory (module repos)
declare -gA _dsbTfExamplesDirList               # Associative array, key is example name, value is directory (module repos)
declare -g _dsbTfTestsDir=""                     # path to tests directory (module repos)
declare -ga _dsbTfTestFilesList                  # Indexed array, all .tftest.hcl files (module repos)
declare -ga _dsbTfUnitTestFilesList              # Indexed array, unit-*.tftest.hcl files (module repos)
declare -ga _dsbTfIntegrationTestFilesList       # Indexed array, integration-*.tftest.hcl files (module repos)

# Setup/install support
declare -g _dsbTfInstallDir=""                   # path where script is installed locally (e.g., ~/.local/bin)
declare -g _dsbTfScriptSourcePath=""             # path to the currently running script (BASH_SOURCE at source time)

###################################################################################################
#
# Utility functions: logging
#
###################################################################################################

# what:
#   error logger, mute with _dsbTfLogErrors=0
# input:
#   $1 : message
_dsb_e() {
  local logErr=${_dsbTfLogErrors:-1}
  if [ "${logErr}" == "1" ]; then
    echo -e "\e[31mERROR  : $1\e[0m"
  fi
}

# what:
#   internal error logger, always logs
# input:
#   $1 : calling function name
#   $2 : message
_dsb_ie() {
  local caller=${1}
  local message=${2}
  echo -e "\e[31mERROR  : ${caller} : $message\e[0m"
}

# what:
#   log an internal error and push to error stack
#   NOTE: does NOT return 1 itself -- caller must 'return 1' after calling this
# input:
#   $@ : one or more messages
_dsb_internal_error() {
  local messages=("$@")
  local caller=${FUNCNAME[1]}
  local message
  for message in "${messages[@]}"; do
    _dsb_ie "${caller}" "${message}"
    _dsb_tf_error_push "${message}"
  done
}

# what:
#   info logger, mute with _dsbTfLogInfo=0
# input:
#   $1 : message
_dsb_i() {
  local logText=${1:-}
  local caller=${FUNCNAME[1]}
  _dsb_i_nonewline "${logText}\n" "${caller}"
}

# what:
#   info logger, mute with _dsbTfLogInfo=0
#   message is logged without trailing newline
# input:
#   $1 : message
_dsb_i_nonewline() {
  local logInfo=${_dsbTfLogInfo:-1}
  local logText=${1:-}
  if [ "${logInfo}" == "1" ]; then
    echo -en "\e[34mINFO   : \e[0m${logText}"
  fi
}

# what:
#   info logger, mute with _dsbTfLogInfo=0
#   message is logged without being prefixed with INFO:
# input:
#   $1 : message
_dsb_i_append() {
  local logInfo=${_dsbTfLogInfo:-1}
  local logText=${1:-}
  if [ "${logInfo}" == "1" ]; then
    echo -en "${logText}\n"
  fi
}

# what:
#   warning logger, mute with _dsbTfLogWarnings=0
# input:
#   $1 : message
_dsb_w() {
  local logWarn=${_dsbTfLogWarnings:-1}
  if [ "${logWarn}" == "1" ]; then
    echo -e "\e[33mWARNING: $1\e[0m"
  fi
}

###################################################################################################
#
# Init: Architecture check and specific setup
#
###################################################################################################

# Check architecture
if [[ $(uname -m) == "arm64" ]]; then
  # MacOS
  _dsbTfRealpathCmd="grealpath" # location of GNU realpath binary
  _dsbTfCutCmd="gcut"           # location of GNU cut binary
  _dsbTfMvCmd="gmv"             # location of GNU mv binary
elif [[ $(uname -m) == "aarch64" ]] && [[ $(uname -s) == "Linux" ]]; then
  # ARM64 Linux
  _dsbTfRealpathCmd="realpath"
  _dsbTfCutCmd="cut"
  _dsbTfMvCmd="mv"
elif [[ $(uname -m) == "x86_64" ]] && [[ $(uname -s) == "Linux" ]]; then
  # x86_64 Linux
  _dsbTfRealpathCmd="realpath"
  _dsbTfCutCmd="cut"
  _dsbTfMvCmd="mv"
else
  _dsb_e "Init error: architecture: $(uname -m), operating system: $(uname -s) is unsupported."
  _dsb_e "DSB Terraform Project Helpers was not loaded."
  return 1
fi

###################################################################################################
#
# Utility functions: general
#
###################################################################################################

# what:
#   use gh cli to get the currently logged in GitHub account
# input:
#   none
# returns:
#   echos the GitHub account name
_dsb_tf_get_github_cli_account() {
  local ghAccount
  ghAccount=$(
    gh auth status --hostname github.com |
      grep "Logged in to github.com account" |
      sed 's/.*Logged in to github.com account //' |
      awk '{print $1}'
  )
  echo "${ghAccount}"
}

# what:
#   gives the user a full insight into the current status of the tools, authentication, and environment
# input:
#   none
# returns:
#   exit code directly
#   internal errors return 1 directly
_dsb_tf_report_status() {
  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_prereqs
  local prereqStatus=$?

  local githubStatus=1
  local githubAccount="  ☐  Logged in to github.com as  : N/A, github cli not available, please run 'tf-check-tools'"
  if _dsbTfLogErrors=0 _dsb_tf_check_gh_cli; then
    githubStatus=0
    githubAccount="  \e[32m☑\e[0m  Logged in to github.com as  : $(_dsb_tf_get_github_cli_account)"
  fi

  local azSubId=""
  local azSubName=""
  local azureStatus=1
  local azureAccount="  ☐  Logged in to Azure as       : N/A, azure cli not available, please run 'tf-check-tools'"
  if _dsbTfLogErrors=0 _dsb_tf_check_az_cli; then
    if _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_az_enumerate_account; then
      local azUpn="${_dsbTfAzureUpn:-}"
      if [ -z "${azUpn}" ]; then
        azureAccount="  \e[31m☒\e[0m  Logged in to Azure as       : N/A, not logged in or session expired, please run 'az-login'"
      else
        azSubId="${_dsbTfSubscriptionId:-}"
        azSubName="${_dsbTfSubscriptionName:-}"
        azureAccount="  \e[32m☑\e[0m  Logged in to Azure as       : ${_dsbTfAzureUpn}"
        azureStatus=0
      fi
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

  _dsb_d "selectedEnv: ${selectedEnv}"
  _dsb_d "selectedEnvDir: ${selectedEnvDir}"

  local envStatus=0
  local lockFileStatus=0
  local subHintFileStatus=0
  if [ -n "${selectedEnv}" ]; then # environment is selected
    if ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_look_for_env "${selectedEnv}"; then
      envStatus=1
    fi

    if ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_look_for_lock_file "${selectedEnv}"; then
      lockFileStatus=1
    fi

    if ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_look_for_subscription_hint_file "${selectedEnv}"; then
      subHintFileStatus=1
    fi
  fi

  local returnCode=$((prereqStatus + githubStatus + azureStatus + envStatus + lockFileStatus + subHintFileStatus))

  _dsb_d "returnCode: ${returnCode}"
  _dsb_d "prereqStatus: ${prereqStatus}"
  _dsb_d "githubStatus: ${githubStatus}"
  _dsb_d "azureStatus: ${azureStatus}"
  _dsb_d "envStatus: ${envStatus}"
  _dsb_d "lockFileStatus: ${lockFileStatus}"
  _dsb_d "subHintFileStatus: ${subHintFileStatus}"

  _dsb_i "Overall:"
  if [ "${prereqStatus}" -eq 0 ]; then
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
  _dsb_i "  Repo type               : ${_dsbTfRepoType:-unknown}"
  _dsb_i "  Root directory          : . (${_dsbTfRootDir})"
  if [ "${_dsbTfRepoType}" == "module" ]; then
    # Root .tf files count
    local -a _rootTfFiles=()
    local _rtf
    for _rtf in "${_dsbTfRootDir}"/*.tf; do
      if [ -f "${_rtf}" ]; then
        _rootTfFiles+=("${_rtf}")
      fi
    done
    _dsb_i "  Root .tf files          : ${#_rootTfFiles[@]}"

    # TFLint config
    if [ -f "${_dsbTfRootDir}/.tflint.hcl" ]; then
      _dsb_i "  TFLint config           : found (.tflint.hcl)"
    else
      _dsb_i "  TFLint config           : not found"
    fi

    # Lock file
    if [ -f "${_dsbTfRootDir}/.terraform.lock.hcl" ]; then
      _dsb_i "  Lock file               : found"
    else
      _dsb_i "  Lock file               : not found (expected in fresh clone, run tf-init)"
    fi

    # terraform-docs config
    if [ -f "${_dsbTfRootDir}/.terraform-docs.yml" ]; then
      _dsb_i "  terraform-docs config   : found"
    else
      _dsb_i "  terraform-docs config   : not found"
    fi

    # Examples
    _dsb_i "  Examples directory      : examples/"
    local -a _exNames=()
    if declare -p _dsbTfExamplesDirList &>/dev/null; then
      local _exKey
      for _exKey in "${!_dsbTfExamplesDirList[@]}"; do
        _exNames+=("${_exKey}")
      done
    fi
    mapfile -t _exNames < <(printf '%s\n' "${_exNames[@]}" | sort)
    local _exCommaSep
    _exCommaSep=$(IFS=,; echo "${_exNames[*]}")
    _exCommaSep=${_exCommaSep//,/, }
    _dsb_i "  Available examples      : ${_exCommaSep:-none} (${#_exNames[@]})"

    # Tests
    _dsb_i "  Tests directory         : tests/"
    _dsb_i "  Test files              : ${#_dsbTfTestFilesList[@]}"
    _dsb_i "  Unit test files         : ${#_dsbTfUnitTestFilesList[@]}"
    _dsb_i "  Integration test files  : ${#_dsbTfIntegrationTestFilesList[@]}"
  else
    _dsb_i "  Environments directory  : $(_dsb_tf_get_rel_dir "${envsDir}")/"
    _dsb_i "  Modules directory       : $(_dsb_tf_get_rel_dir "${modulesDir}")/"
    _dsb_i "  Available modules       : ${availableModulesCommaSeparated}"
  fi
  _dsb_i ""
  if [ "${_dsbTfRepoType}" != "module" ]; then
  _dsb_i "Environment:"
  _dsb_i "  Available environments      : ${availableEnvsCommaSeparated}"
  if [ -z "${selectedEnv}" ]; then
    _dsb_i "  ☐  Selected environment     : N/A, please run 'tf-select-env'"
    _dsb_i "  ☐  Environment directory    : N/A"
    _dsb_i "  ☐  Lock file                : N/A"
    _dsb_i "  ☐  Subscription hint file   : N/A"
    _dsb_i "  ☐  Subscription hint        : N/A"
    _dsb_i "  ☐  Az CLI subscription name : N/A"
    _dsb_i "  ☐  Az CLI subscription id   : N/A"
  else
    if [ ${envStatus} -eq 0 ]; then
      _dsb_i "  \e[32m☑\e[0m  Selected environment     : ${selectedEnv}"
      _dsb_i "  \e[32m☑\e[0m  Environment directory    : $(_dsb_tf_get_rel_dir "${selectedEnvDir}")/"
      if [ ${lockFileStatus} -eq 0 ]; then
        _dsb_i "  \e[32m☑\e[0m  Lock file                : $(_dsb_tf_get_rel_dir "${_dsbTfSelectedEnvLockFile}")"
      else
        _dsb_i "  \e[31m☒\e[0m  Lock file                : not found, please run 'tf-check-env ${selectedEnv}'"
      fi
      if [ ${subHintFileStatus} -eq 0 ]; then
        _dsb_i "  \e[32m☑\e[0m  Subscription hint file   : $(_dsb_tf_get_rel_dir "${_dsbTfSelectedEnvSubscriptionHintFile}")"
        _dsb_i "  \e[32m☑\e[0m  Subscription hint        : ${_dsbTfSelectedEnvSubscriptionHintContent:-}"
        _dsb_i "  \e[32m☑\e[0m  Az CLI subscription name : ${azSubName:-}"
        _dsb_i "  \e[32m☑\e[0m  Az CLI subscription id   : ${azSubId:-}"
      else
        _dsb_i "  \e[31m☒\e[0m  Subscription hint file   : not found, please run 'tf-check-env ${selectedEnv}'"
        _dsb_i "  \e[31m☒\e[0m  Subscription hint        : N/A"
        _dsb_i "  \e[31m☒\e[0m  Az CLI subscription name : N/A"
        _dsb_i "  \e[31m☒\e[0m  Az CLI subscription id   : N/A"
      fi
    else
      _dsb_i "  \e[31m☒\e[0m  Selected environment     : ${selectedEnv}, does not exist, please run 'tf-select-env'"
      _dsb_i "  ☐  Environment directory    : N/A"
      _dsb_i "  ☐  Lock file                : N/A"
      _dsb_i "  ☐  Subscription hint file   : N/A"
      _dsb_i "  ☐  Subscription hint        : N/A"
      _dsb_i "  ☐  Az CLI subscription name : N/A"
      _dsb_i "  ☐  Az CLI subscription id   : N/A"
    fi
  fi
  fi # end of if [ "${_dsbTfRepoType}" != "module" ]
  if [ ${returnCode} -ne 0 ]; then
    _dsb_i ""
    _dsb_w "not all green 🧐"
  fi

  _dsb_d "returning exit code: ${returnCode}"
  return "${returnCode}"
}

###################################################################################################
#
# Utility functions: debug
#
###################################################################################################

# what:
#   debug logger, mute with _dsbTfLogDebug=0
# input:
#   $1 : message
_dsb_d() {
  local logDebug=${_dsbTfLogDebug:-0}
  local caller=${FUNCNAME[1]}
  if [ "${logDebug}" == "1" ]; then
    echo -e "\e[35mDEBUG  : ${caller} : $1\e[0m"
  fi
}

# what:
#   enable debug logging
# input:
#   none
# returns:
#   none
_dsb_tf_debug_enable_debug_logging() {
  _dsbTfLogDebug=1
}

# what:
#   disable debug logging
# input:
#   none
# returns:
#   none
_dsb_tf_debug_disable_debug_logging() {
  unset _dsbTfLogDebug
}

# what:
#   install callGraph and dependencies on Ubuntu
# input:
#   $1 : destination directory (optional)
# returns:
#   none
_dsb_tf_debug_install_call_graph_and_deps_ubuntu() {
  local destDir="${1:-./call-graphs}"
  local callGraphFile="${destDir}/callGraph"

  # deps
  sudo apt install graphviz make libexpat1-dev
  sudo cpanm install GraphViz

  # install
  mkdir -P "${destDir}"
  curl -s https://raw.githubusercontent.com/koknat/callGraph/refs/heads/main/callGraph >"${callGraphFile}"
  chmod +x "${callGraphFile}"

  # test
  "${callGraphFile}" -version
}

# what:
#   generate call graphs for all exposed functions
#   generates a single call graph if a function name is provided
# input:
#   $1 : function to generate single call graph for (optional)
# returns:
#   none
_dsb_tf_debug_generate_call_graphs() {
  local functionToGenerateFor="${1:-}"

  local inFile='dsb-tf-proj-helpers.sh'
  local outFile='dsb-tf-proj-helpers-underscored.sh'
  local callGraphDir="./call-graphs"
  local toBeReplaced
  local -A replacements

  # look for function names to replace, the "exposed" functions
  # those that are prefixed with 'tf-' and 'az-'
  mapfile -t toBeReplaced < <(grep -oP '^(tf|az)-[a-zA-Z-]+(\(\))' ${inFile})

  # create the output directory
  mkdir -p ./${callGraphDir}

  # create a copy of the script file with the exposed functions renamed
  # in such a way that they can be picked up by callGraph
  cat ${inFile} >${outFile}
  local funcName
  for funcName in "${toBeReplaced[@]}"; do
    local newFuncName
    newFuncName="${funcName//-/__}"      # tf-check-tools -> tf__check__tools
    newFuncName="exposed_${newFuncName}" # tf__check__tools -> exposed_tf__check__tools

    # do the replacement
    local tmpFile
    tmpFile=$(mktemp)
    sed "s/${funcName}/${newFuncName}/g" ${outFile} >"${tmpFile}"
    "${_dsbTfMvCmd}" "${tmpFile}" ${outFile}

    replacements[${funcName}]="${newFuncName}" # record the replacement
  done

  # ignore uninteresting functions
  # shellcheck disable=SC2016
  local ignoreStatic='($unset.*|_dsb_[wedi](\(\))?|$_dsb_tf_error_.*|_dsb_tf_signal_handler(\(\))?|_dsb_tf_configure_shell(\(\))?|_dsb_tf_restore_shell.*(\(\))?|$_dsb_tf_help.*|_dsb_tf_completions(\(\))?|$_dsb_tf_register_.*|$_dsb_tf_debug_.*'

  if [ -n "${functionToGenerateFor}" ]; then
    local startFuncStrip="${functionToGenerateFor//()/}" # no trailing ()
    local startFunc="${functionToGenerateFor}()"         # with trailing ()
    local funcGraphFile="${callGraphDir}/${inFile}-call-graph-${startFuncStrip}"

    # echo "Generating call graph for function: ${functionToGenerateFor}"
    # echo "  input file : ${inFile}"
    # echo "  start func : ${startFunc}"
    # echo "  stripped   : ${startFuncStrip}"
    # echo "  output file: ${funcGraphFile}"
    # echo "  ignore     : ${ignoreStatic}"

    # create a call graph containing single function
    "${callGraphDir}/callGraph" ${outFile} -start "${startFunc}" -output "${funcGraphFile}" -ignore "${ignoreStatic})"

    rm "${funcGraphFile}.dot" # not interested in the dot files
  else
    # create a call graph containing all functions
    "${callGraphDir}/callGraph" ${outFile} -output "${callGraphDir}/${inFile}-call-graph-all" -ignore "${ignoreStatic})"

    rm "${callGraphDir}/${inFile}-call-graph-all.dot" # not interested in the dot files

    # create call graphs for each function of the exposed functions
    local startFunc
    for startFunc in "${!replacements[@]}"; do
      local graphFuncName="${replacements[$startFunc]}" # the name of the function in the call graph
      # local graphFuncNameStrip="${graphFuncName//()/}"  # the name of the function in the call graph without trailing ()
      local ignoreLocal="${ignoreStatic}" # copy the static ignore list

      # add all other than the current function to the ignore list
      local funcName
      for funcName in "${replacements[@]}"; do
        if [[ ! "$funcName" == "${graphFuncName}" ]]; then
          ignoreLocal+="|\$${funcName}.*" # append all exposed functions that is not the current function
        fi
      done
      ignoreLocal+=")" # finalize the ignore list

      # name of output file
      local funcGraphFile="${callGraphDir}/${inFile}-call-graph-${startFunc//()/}"

      # echo "Generating call graph for function: ${graphFuncName}"
      # echo "  input file : ${inFile}"
      # echo "  start func : ${graphFuncName}"
      # echo "  output file: ${funcGraphFile}"
      # echo "  ignore     : ${ignoreLocal}"

      # run callGraph
      "${callGraphDir}/callGraph" ${outFile} -start "${graphFuncName}" -output "${funcGraphFile}" -ignore "${ignoreLocal}"

      rm "$funcGraphFile.dot" # not interested in the dot files
    done
  fi

  # remove the copy of the shell script with the exposed functions renamed
  rm -f "${outFile}"
}

###################################################################################################
#
# Utility functions: error handling
#
###################################################################################################

# Error context stack -- accumulates messages as errors propagate up the call chain.
# Drained and displayed by exposed functions when a non-zero return is detected.
declare -ga _dsbTfErrorStack=()

# what:
#   push an error message onto the error stack
#   automatically records the calling function name
# input:
#   $1 : message
_dsb_tf_error_push() {
  local caller="${FUNCNAME[1]}"
  local message="$1"
  _dsbTfErrorStack+=("${caller}: ${message}")
}

# what:
#   clear the error stack
_dsb_tf_error_clear() {
  _dsbTfErrorStack=()
}

# what:
#   dump the error stack to the user via _dsb_e, then clear it
_dsb_tf_error_dump() {
  if [ ${#_dsbTfErrorStack[@]} -gt 0 ]; then
    _dsb_e "Error context:"
    local entry
    for entry in "${_dsbTfErrorStack[@]}"; do
      _dsb_e "  ${entry}"
    done
  fi
  _dsb_tf_error_clear
}

_dsb_tf_signal_handler() {
  _dsb_e "Signal received, aborting."
  _dsb_tf_restore_shell
}

_dsb_tf_configure_shell() {
  _dsb_d "configuring shell"

  _dsbTfShellHistoryState=$(shopt -o history) # Save current history recording state
  set +o history                              # Disable history recording

  _dsbTfShellOldOpts=$(set +o) # Save current shell options

  # Establish a known shell state -- explicitly disable dangerous options
  # that the caller may have active. This is belt-and-suspenders with the
  # set -e neutralization guard on exposed functions.
  set +e          # Do NOT exit on error -- we handle errors explicitly
  set +E          # Do NOT inherit ERR trap in sub-shells
  set +o pipefail # Do NOT propagate pipe failures implicitly
  trap - ERR      # Remove any ERR trap the caller may have set

  # -u: Treat unset variables as an error -- this catches real bugs
  set -u

  # Signal traps only (for cleanup on Ctrl+C) -- NO ERR trap
  trap '_dsb_tf_signal_handler' SIGHUP SIGINT

  # Clean up any leftover temp files from interrupted operations
  rm -f "/tmp/dsb-tf-helpers-$$-"* 2>/dev/null || :

  # some default values
  declare -g _dsbTfLogInfo=1
  declare -g _dsbTfLogWarnings=1
  declare -g _dsbTfLogErrors=1

  declare -ga _dsbTfFilesList=()
  declare -ga _dsbTfLintConfigFilesList=()
  declare -gA _dsbTfEnvsDirList=()
  declare -ga _dsbTfAvailableEnvs=()
  declare -gA _dsbTfModulesDirList=()

  _dsb_tf_error_clear
}

_dsb_tf_restore_shell() {
  _dsb_d "restoring shell"

  # Remove all traps we may have set (signal traps + ERR just in case)
  trap - ERR SIGHUP SIGINT

  eval "$_dsbTfShellOldOpts" # Restore previous shell options (includes set -e/+e, pipefail, etc.)

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
}

###################################################################################################
#
# Utility functions: --log output capture
#
###################################################################################################

# what:
#   runs a function/command with optional --log output capture
#   when logFile is non-empty, pipes output through tee and strips ANSI for the log file
#   PIPESTATUS discipline: the exit code is read on the VERY NEXT LINE after the pipeline
# input:
#   $1: logFile (empty string means no logging)
#   $2..: command and arguments to run
# on info:
#   prints "Output saved to: <file>" when logging
# returns:
#   exit code from the command
_dsb_tf_run_with_log() {
  local logFile="${1}"
  shift
  local -a cmd=("$@")

  if [ -n "${logFile}" ]; then
    { "${cmd[@]}"; } 2>&1 | tee >(sed 's/\x1b\[[0-9;]*[mGKHJ]//g' > "${logFile}")
    local rc=${PIPESTATUS[0]}
    _dsb_i "Output saved to: ${logFile}"
    return "${rc}"
  else
    "${cmd[@]}"
  fi
}

# what:
#   generates an auto log filename from command name and optional qualifier
# input:
#   $1: command name (e.g. "tf-plan")
#   $2: qualifier (e.g. env name, test name) -- optional
# returns:
#   echoes the generated filename
_dsb_tf_auto_log_filename() {
  local cmdName="${1}"
  local qualifier="${2:-}"
  local timestamp
  timestamp=$(date +%Y%m%d-%H%M%S)
  if [ -n "${qualifier}" ]; then
    echo "${cmdName}-${qualifier}-${timestamp}.log"
  else
    echo "${cmdName}-${timestamp}.log"
  fi
}

###################################################################################################
#
# Utility functions: Display help
#
###################################################################################################

_dsb_tf_help_get_commands_supported_by_help() {
  local -a commands=(
    # azure
    "az-login"
    "az-logout"
    "az-relog"
    "az-set-sub"
    "az-select-sub"
    "az-whoami"
    # checks
    "tf-check-dir"
    "tf-check-env"
    "tf-check-az-auth"
    "tf-check-gh-auth"
    "tf-check-prereqs"
    "tf-check-tools"
    # environments
    "tf-clear-env"
    "tf-unset-env"
    "tf-list-envs"
    "tf-select-env"
    "tf-set-env"
    # general
    "tf-status"
    "tf-lint"
    "tf-clean"
    "tf-clean-tflint"
    "tf-clean-all"
    # terraform
    "tf-init"
    "tf-init-env"
    "tf-init-all"
    "tf-init-main"
    "tf-init-modules"
    "tf-init-offline"
    "tf-init-env-offline"
    "tf-init-all-offline"
    "tf-fmt"
    "tf-fmt-fix"
    "tf-validate"
    "tf-validate-all"
    "tf-lint-all"
    "tf-outputs"
    "tf-plan"
    "tf-apply"
    "tf-destroy"
    # versions
    "tf-versions"
    # upgrading
    "tf-upgrade"
    "tf-upgrade-env"
    "tf-upgrade-all"
    "tf-upgrade-offline"
    "tf-upgrade-env-offline"
    "tf-upgrade-all-offline"
    "tf-bump-cicd"
    "tf-bump-modules"
    "tf-bump-tflint-plugins"
    "tf-show-provider-upgrades"
    "tf-show-all-provider-upgrades"
    "tf-bump"
    "tf-bump-env"
    "tf-bump-all"
    "tf-bump-offline"
    "tf-bump-env-offline"
    "tf-bump-all-offline"
    # examples (module only)
    "tf-init-all-examples"
    "tf-init-example"
    "tf-validate-all-examples"
    "tf-validate-example"
    "tf-lint-all-examples"
    "tf-lint-example"
    # testing (module only)
    "tf-test"
    "tf-test-unit"
    "tf-test-integration"
    "tf-test-all-integrations"
    "tf-test-all-examples"
    "tf-test-example"
    # docs (module only)
    "tf-docs"
    "tf-docs-all-examples"
    "tf-docs-example"
    "tf-docs-all"
    # setup
    "tf-install-helpers"
    "tf-uninstall-helpers"
    "tf-update-helpers"
    "tf-reload-helpers"
    "tf-unload-helpers"
  )
  echo "${commands[@]}"
}

_dsb_tf_help_enumerate_supported_topics() {
  local -a validGroups=(
    "all"
    "commands"
    "help"
    "groups"
    "environments"
    "checks"
    "azure"
    "general"
    "terraform"
    "upgrading"
    "offline"
    "examples"
    "testing"
    "docs"
    "flags"
    "setup"
  )
  local -a validCommands
  mapfile -t validCommands < <(_dsb_tf_help_get_commands_supported_by_help)
  echo "${validGroups[@]}" "${validCommands[@]}"
}

_dsb_tf_help() {
  local arg="${1:-help}"
  case "${arg}" in
  all)
    _dsb_tf_help_all
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
  terraform)
    _dsb_tf_help_group_terraform
    ;;
  upgrading)
    _dsb_tf_help_group_upgrading
    ;;
  offline)
    _dsb_tf_help_group_offline
    ;;
  examples)
    _dsb_tf_help_group_examples
    ;;
  testing)
    _dsb_tf_help_group_testing
    ;;
  docs)
    _dsb_tf_help_group_docs
    ;;
  flags)
    _dsb_tf_help_group_flags
    ;;
  setup)
    _dsb_tf_help_group_setup
    ;;
  *)
    local -a validCommands
    mapfile -t validCommands < <(_dsb_tf_help_get_commands_supported_by_help)
    if [[ " ${validCommands[*]} " =~ (^|[[:space:]])"${arg}"($|[[:space:]]) ]]; then
      _dsb_tf_help_specific_command "${arg}"
    else
      _dsb_w "Unknown help topic: ${arg}"
    fi
    ;;
  esac
}

_dsb_tf_help_help() {
  _dsb_i "DSB Terraform Project Helpers 🚀"
  _dsb_i ""
  if [ "${_dsbTfRepoType:-}" == "module" ]; then
    _dsb_i "  A collection of functions to help working with DSB Terraform modules."
  else
    _dsb_i "  A collection of functions to help working with DSB Terraform projects."
  fi
  _dsb_i "  All available commands are organized into groups."
  _dsb_i "  Below are commands for getting help with groups or specific commands."
  _dsb_i ""
  _dsb_i "General Help:"
  _dsb_i "  tf-help groups     -> Show all command groups"
  _dsb_i "  tf-help [group]    -> Show help for a specific command group"
  _dsb_i "  tf-help commands   -> Show all commands"
  _dsb_i "  tf-help [command]  -> Show help for a specific command"
  _dsb_i "  tf-help all        -> Show all help"
  _dsb_i ""
  if [ "${_dsbTfRepoType:-}" == "module" ]; then
    _dsb_i "Common Commands (module repo):"
    _dsb_i "  tf-status                -> Show status of tools, authentication, and module structure"
    _dsb_i "  tf-init                  -> Initialize Terraform module at root"
    _dsb_i "  tf-init-all              -> Initialize module root and all examples"
    _dsb_i "  tf-validate              -> Validate Terraform module at root"
    _dsb_i "  tf-validate-all          -> Validate module root and all examples"
    _dsb_i "  tf-lint                  -> Run tflint at root"
    _dsb_i "  tf-lint-all              -> Lint module root and all examples"
    _dsb_i "  tf-fmt-fix               -> Run syntax check and fix recursively from current directory"
    _dsb_i "  tf-upgrade               -> Upgrade Terraform dependencies at root"
    _dsb_i "  tf-bump                  -> All-in-one bump (modules, tflint plugins, cicd, providers)"
    _dsb_i "  tf-clean                 -> Remove .terraform and .terraform.lock.hcl files"
    _dsb_i "  tf-init-all-examples     -> Initialize example directories"
    _dsb_i "  tf-validate-all-examples -> Validate example directories"
    _dsb_i "  tf-test-unit             -> Run unit tests"
    _dsb_i "  tf-test-all-integrations -> Run all integration tests (requires Azure)"
    _dsb_i "  tf-docs-all              -> Generate documentation for root and examples"
    _dsb_i "  tf-versions              -> Show comprehensive version information"
  else
    _dsb_i "Common Commands:"
    _dsb_i "  tf-status           -> Show status of tools, authentication, and environment"
    _dsb_i "  az-relog            -> Azure re-login"
    _dsb_i "  tf-set-env [env]    -> Set environment"
    _dsb_i "  tf-init             -> Initialize Terraform project"
    _dsb_i "  tf-init-offline     -> Initialize Terraform project, without backend"
    _dsb_i "  tf-upgrade          -> Upgrade Terraform dependencies (within existing version constraints)"
    _dsb_i "  tf-fmt-fix          -> Run syntax check and fix recursively from current directory"
    _dsb_i "  tf-validate         -> Make Terraform validate the project"
    _dsb_i "  tf-plan             -> Make Terraform create a plan"
    _dsb_i "  tf-apply            -> Make Terraform apply changes"
    _dsb_i "  tf-lint             -> Run tflint"
  fi
  _dsb_i ""
  _dsb_i "Setup:"
  _dsb_i "  tf-help setup       -> Install, update, and manage the helpers locally"
  _dsb_i ""
  _dsb_i "Note:"
  _dsb_i "  tf-help supports tab completion for available arguments,"
  _dsb_i "  simply add a space after the tf-help command and press tab."
}

_dsb_tf_help_groups() {
  _dsb_i "Help Groups:"
  if [ "${_dsbTfRepoType:-}" == "module" ]; then
    # Module repos: no environments or offline groups
    _dsb_i "  terraform     -> Terraform related commands"
    _dsb_i "  upgrading     -> Upgrade related commands"
    _dsb_i "  checks        -> Check related commands"
    _dsb_i "  general       -> General help"
    _dsb_i "  azure         -> Azure related commands"
    _dsb_i "  examples      -> Example directory commands (module repo)"
    _dsb_i "  testing       -> Terraform test commands (module repo)"
    _dsb_i "  docs          -> Documentation generation commands (module repo)"
    _dsb_i "  flags         -> Flags supported by commands (--log, terraform passthrough)"
    _dsb_i "  setup         -> Install, update, and manage the helpers"
  else
    # Project repos: no examples, testing, or docs groups
    _dsb_i "  environments  -> Environment related commands"
    _dsb_i "  terraform     -> Terraform related commands"
    _dsb_i "  upgrading     -> Upgrade related commands"
    _dsb_i "  checks        -> Check related commands"
    _dsb_i "  general       -> General help"
    _dsb_i "  azure         -> Azure related commands"
    _dsb_i "  offline       -> Commands for working without access to remote state"
    _dsb_i "  flags         -> Flags supported by commands (--log, terraform passthrough)"
    _dsb_i "  setup         -> Install, update, and manage the helpers"
  fi
  _dsb_i "  all           -> All help"
  _dsb_i ""
  _dsb_i "Use 'tf-help [group]' to get detailed help for a specific group."
}

_dsb_tf_help_group_environments() {
  _dsb_i "  Environment Commands:"
  _dsb_i "    tf-list-envs          -> List existing environments"
  _dsb_i "    tf-select-env         -> List and select environment"
  _dsb_i "    tf-set-env [env]      -> Set environment (tab completion supported for [env])"
  _dsb_i "    tf-check-env [env]    -> Check if environment is valid (tab completion supported for [env])"
  _dsb_i "    tf-clear-env          -> Clear selected environment"
  _dsb_i "    tf-unset-env          -> Alias for tf-clear-env"
}

_dsb_tf_help_group_checks() {
  _dsb_i "  Check Commands:"
  _dsb_i "    tf-check-dir          -> Check if in valid Terraform project structure"
  _dsb_i "    tf-check-prereqs      -> Run all prerequisite checks"
  _dsb_i "    tf-check-tools        -> Check for required tools"
  _dsb_i "    tf-check-az-auth      -> Check Azure CLI authentication"
  _dsb_i "    tf-check-gh-auth      -> Check GitHub authentication"
}

_dsb_tf_help_group_general() {
  _dsb_i "  General Commands:"
  _dsb_i "    tf-status             -> Show status of tools, authentication, and environment"
  _dsb_i "    tf-lint [env]         -> Run tflint for the selected or given environment"
  _dsb_i "    tf-clean              -> Look for and delete '.terraform' directories"
  _dsb_i "    tf-clean-tflint       -> Look for and delete '.tflint' directories"
  _dsb_i "    tf-clean-all          -> Look for and delete both '.terraform' and '.tflint' directories"
}

_dsb_tf_help_group_azure() {
  _dsb_i "  Azure Commands:"
  _dsb_i "    az-logout             -> Azure logout"
  _dsb_i "    az-login              -> Azure login"
  _dsb_i "    az-relog              -> Azure re-login"
  _dsb_i "    az-whoami             -> Show Azure account information"
  _dsb_i "    az-set-sub            -> Set Azure subscription from current env hint file"
  _dsb_i "    az-select-sub         -> List and select active Azure subscription"
}

_dsb_tf_help_group_terraform() {
  _dsb_i "  Terraform Commands:"
  _dsb_i "    tf-init [env] [-flags]    -> Initialize (supports terraform flag passthrough)"
  _dsb_i "    tf-init-env [env]         -> Initialize selected or given environment (environment directory only)"
  _dsb_i "    tf-init-all               -> Initialize entire Terraform project, all environments"
  _dsb_i "    tf-init-main              -> Initialize Terraform project's main module"
  _dsb_i "    tf-init-modules           -> Initialize Terraform project's local sub-modules"
  _dsb_i "    tf-init-offline [env]     -> Same as 'tf-init', without backend"
  _dsb_i "    tf-init-env-offline [env] -> Same as 'tf-init-env', without backend"
  _dsb_i "    tf-init-all-offline       -> Same as 'tf-init-all', without backend"
  _dsb_i "    tf-fmt                    -> Run syntax check recursively from current directory"
  _dsb_i "    tf-fmt-fix                -> Run syntax check and fix recursively from current directory"
  _dsb_i "    tf-validate [env]         -> Make Terraform validate the project with selected or given environment"
  _dsb_i "    tf-validate-all           -> Validate all environments (project) or root + examples (module)"
  _dsb_i "    tf-lint-all               -> Lint all environments (project) or root + examples (module)"
  _dsb_i "    tf-outputs [env]          -> Show Terraform outputs for selected or given environment"
  _dsb_i "    tf-plan [env] [-flags]    -> Create a plan (supports terraform flags and --log)"
  _dsb_i "    tf-apply [env] [-flags]   -> Apply changes (supports terraform flags and --log)"
  _dsb_i "    tf-destroy [env]          -> Show command to manually destroy the selected or given environment"
  _dsb_i "    tf-versions               -> Show comprehensive version information"
  _dsb_i ""
  _dsb_i "  See 'tf-help flags' for details on terraform flag passthrough and --log."
}

_dsb_tf_help_group_offline() {
  _dsb_i "Offline Commands"
  _dsb_i ""
  _dsb_i "  These are variants of commands that supports \"offline\" mode."
  _dsb_i ""
  _dsb_i "  Offline meaning that operations are performed without a terraform backend."
  _dsb_i "  Useful when working without access to the remote terraform backend."
  _dsb_i ""
  _dsb_i "  Terraform Offline Commands:"
  _dsb_i "    tf-init-offline [env]         -> Initialize selected or given environment (incl. main and local sub-modules)"
  _dsb_i "    tf-init-env-offline [env]     -> Initialize selected or given environment (environment directory only)"
  _dsb_i "    tf-init-all-offline           -> Initialize entire Terraform project, all environments"
  _dsb_i ""
  _dsb_i "  Upgrade Offline Commands:"
  _dsb_i "    tf-bump-env-offline [env]     -> Upgrade Terraform deps. for selected or given environment and list provider versions, latest vs. lock file"
  _dsb_i "    tf-bump-offline [env]         -> All-in-one bump function for selected or given environment"
  _dsb_i "    tf-bump-all-offline           -> All-in-one bump function for entire project, all environments"
  _dsb_i "    tf-upgrade-env-offline [env]  -> Upgrade Terraform deps. for selected or given environment (environment directory only)"
  _dsb_i "    tf-upgrade-offline [env]      -> Upgrade Terraform deps. for selected or given environment (also upgrades main and local sub-modules)"
  _dsb_i "    tf-upgrade-all-offline        -> Upgrade Terraform deps. in entire project, all environments"
}

_dsb_tf_help_group_upgrading() {
  _dsb_i "  Upgrade Commands:"
  _dsb_i "    tf-bump-env [env]               -> Upgrade Terraform deps. for selected or given environment and list provider versions, latest vs. lock file"
  _dsb_i "    tf-bump [env]                   -> All-in-one bump function for selected or given environment"
  _dsb_i "    tf-bump-all                     -> All-in-one bump function for entire project, all environments"
  _dsb_i "    tf-bump-env-offline [env]       -> Same as 'tf-bump-env', without backend"
  _dsb_i "    tf-bump-offline [env]           -> Same as 'tf-bump', without backend"
  _dsb_i "    tf-bump-all-offline             -> Same as 'tf-bump-all', without backend"
  _dsb_i "    tf-upgrade-env [env]            -> Upgrade Terraform deps. for selected or given environment (environment directory only)"
  _dsb_i "    tf-upgrade [env]                -> Upgrade Terraform deps. for selected or given environment (also upgrades main and local sub-modules)"
  _dsb_i "    tf-upgrade-all                  -> Upgrade Terraform deps. in entire project, all environments"
  _dsb_i "    tf-upgrade-env-offline [env]    -> Same as 'tf-upgrade-env', without backend"
  _dsb_i "    tf-upgrade-offline [env]        -> Same as 'tf-upgrade', without backend"
  _dsb_i "    tf-upgrade-all-offline          -> Same as 'tf-upgrade-all', without backend"
  _dsb_i "    tf-bump-modules                 -> Bump module versions in .tf files (only applies to official registry modules)"
  _dsb_i "    tf-bump-cicd                    -> Bump versions in GitHub workflows"
  _dsb_i "    tf-bump-tflint-plugins          -> Bump tflint plugin versions in .tflint.hcl files"
  _dsb_i "    tf-show-provider-upgrades [env] -> Show available provider upgrades for selected or given environment"
  _dsb_i "    tf-show-all-provider-upgrades   -> Show all available provider upgrades for all environments"
}

_dsb_tf_help_group_examples() {
  _dsb_i "  Example Commands (module repo only):"
  _dsb_i "    tf-init-all-examples [example]     -> Initialize all or a specific example directory"
  _dsb_i "    tf-init-example <example>           -> Initialize a specific example directory"
  _dsb_i "    tf-validate-all-examples [example] -> Validate all or a specific example directory"
  _dsb_i "    tf-validate-example <example>       -> Validate a specific example directory"
  _dsb_i "    tf-lint-all-examples [example]     -> Run tflint on all or a specific example directory"
  _dsb_i "    tf-lint-example <example>           -> Run tflint on a specific example directory"
}

_dsb_tf_help_group_testing() {
  _dsb_i "  Testing Commands (module repo only):"
  _dsb_i "    tf-test [filter]               -> Run terraform test (supports --log)"
  _dsb_i "    tf-test-unit                   -> Run unit tests only (supports --log)"
  _dsb_i "    tf-test-integration <name>     -> Run a specific integration test (Azure sub, supports --log)"
  _dsb_i "    tf-test-all-integrations       -> Run all integration tests (Azure sub, supports --log)"
  _dsb_i "    tf-test-all-examples [example] -> Test examples via apply+destroy (Azure sub, supports --log)"
  _dsb_i "    tf-test-example <example>      -> Test a specific example via apply+destroy (Azure sub, supports --log)"
  _dsb_i ""
  _dsb_i "  All testing commands support --log to save output. See 'tf-help flags' for details."
}

_dsb_tf_help_group_docs() {
  _dsb_i "  Documentation Commands (module repo only):"
  _dsb_i "    tf-docs                        -> Generate terraform-docs for module root"
  _dsb_i "    tf-docs-all-examples           -> Generate terraform-docs for all examples"
  _dsb_i "    tf-docs-example <example>      -> Generate terraform-docs for a specific example"
  _dsb_i "    tf-docs-all                    -> Generate terraform-docs for root and all examples"
}

_dsb_tf_help_group_flags() {
  _dsb_i "Flags"
  _dsb_i ""
  _dsb_i "  Some commands support additional flags:"
  _dsb_i ""
  _dsb_i "  --log / --log=<file>  (output capture)"
  _dsb_i "    Save command output to a log file with ANSI colors stripped."
  _dsb_i "    When used without =<file>, an auto-generated timestamped filename is used."
  _dsb_i "    Output is still displayed live on the terminal."
  _dsb_i ""
  _dsb_i "    Supported by:"
  _dsb_i "      tf-plan, tf-apply, tf-test, tf-test-unit, tf-test-integration,"
  _dsb_i "      tf-test-all-integrations, tf-test-all-examples, tf-test-example"
  _dsb_i ""
  _dsb_i "    Examples:"
  _dsb_i "      tf-plan dev --log                    -> saves to tf-plan-dev-YYYYMMDD-HHMMSS.log"
  _dsb_i "      tf-plan dev --log=./plans/today.log  -> saves to specified path"
  _dsb_i "      tf-test-unit --log                   -> saves test output to file"
  _dsb_i ""
  _dsb_i "  Terraform passthrough flags  (single dash)"
  _dsb_i "    Flags starting with a single dash are passed through directly to terraform."
  _dsb_i "    These are not interpreted by the helpers -- they go straight to the"
  _dsb_i "    terraform CLI command. Any terraform flag is supported."
  _dsb_i ""
  _dsb_i "    Supported by:"
  _dsb_i "      tf-init, tf-init-offline, tf-plan, tf-apply"
  _dsb_i ""
  _dsb_i "    Examples:"
  _dsb_i "      tf-plan dev -target=module.foo          -> plan specific resource"
  _dsb_i "      tf-plan dev -out=plan.tfplan            -> save binary plan file"
  _dsb_i "      tf-plan dev -destroy                    -> show destroy plan"
  _dsb_i "      tf-apply dev -auto-approve              -> apply without prompt"
  _dsb_i "      tf-init dev -backend-config=dev.hcl     -> custom backend config"
  _dsb_i ""
  _dsb_i "  Combining flags:"
  _dsb_i "    Both our flags and terraform flags can be used together:"
  _dsb_i "      tf-plan dev -target=module.foo --log    -> plan one resource and save output"
  _dsb_i "      tf-apply dev -auto-approve --log=apply.log"
  _dsb_i ""
  _dsb_i "  Convention:"
  _dsb_i "    --double-dash flags  -> consumed by the helpers (e.g., --log)"
  _dsb_i "    -single-dash flags   -> passed through to terraform (e.g., -target)"
  _dsb_i ""
  _dsb_i "  For more details, see help for the specific command: tf-help <command>"
}

_dsb_tf_help_group_setup() {
  _dsb_i "  Setup Commands:"
  _dsb_i "    tf-install-helpers     -> Install the helpers script locally (~/.local/bin)"
  _dsb_i "    tf-uninstall-helpers   -> Remove the installed script and shell alias"
  _dsb_i "    tf-update-helpers      -> Download the latest version and reload"
  _dsb_i "    tf-reload-helpers      -> Reload helpers from local copy (resets shell state)"
  _dsb_i "    tf-unload-helpers      -> Completely remove all helpers from the current shell"
  _dsb_i ""
  _dsb_i "  Workflow:"
  _dsb_i "    1. tf-install-helpers   Install and optionally add tf-load-helpers alias"
  _dsb_i "    2. tf-load-helpers      Load helpers in a new shell (alias in .bashrc/.zshrc)"
  _dsb_i "    3. tf-update-helpers    Check for updates and reload"
  _dsb_i "    4. tf-reload-helpers    Reload from local copy to reset state"
  _dsb_i "    5. tf-unload-helpers    Remove helpers from the current session"
  _dsb_i "    6. tf-uninstall-helpers Remove the script and shell alias entirely"
  _dsb_i ""
  _dsb_i "  Notes:"
  _dsb_i "    - tf-install-helpers copies the script to ~/.local/bin and makes it executable."
  _dsb_i "    - If loaded via process substitution, it downloads from GitHub automatically."
  _dsb_i "    - Downloads prefer gh cli (authenticated) with curl as fallback."
  _dsb_i "    - It optionally adds a tf-load-helpers alias to your shell profile (.bashrc/.zshrc)."
  _dsb_i "    - Running tf-install-helpers multiple times is safe (idempotent)."
  _dsb_i "    - tf-update-helpers downloads the latest version from GitHub."
  _dsb_i "    - tf-reload-helpers is useful after debugging or to reset all internal state."
  _dsb_i ""
  _dsb_i "  Feature branch testing:"
  _dsb_i "    Set DSB_TF_HELPERS_BRANCH to download from a specific branch:"
  _dsb_i "      export DSB_TF_HELPERS_BRANCH=my-feature-branch"
  _dsb_i "      tf-install-helpers   # or tf-update-helpers"
}

_dsb_tf_help_commands() {
  _dsb_i "DSB Terraform Project Helpers 🚀"
  _dsb_i ""
  if [ "${_dsbTfRepoType:-}" == "module" ]; then
    _dsb_i "Available commands (module repo):"
    _dsb_i ""
    _dsb_tf_help_group_general
    _dsb_i ""
    _dsb_i "  Module Terraform Commands:"
    _dsb_i "    tf-init               -> Initialize Terraform module at root"
    _dsb_i "    tf-init-all           -> Initialize module root and all examples"
    _dsb_i "    tf-init-offline       -> Same as tf-init (no backend in module repos)"
    _dsb_i "    tf-init-all-offline   -> Same as tf-init-all (no backend in module repos)"
    _dsb_i "    tf-validate           -> Validate Terraform module at root"
    _dsb_i "    tf-validate-all       -> Validate module root and all examples"
    _dsb_i "    tf-lint               -> Run tflint at module root"
    _dsb_i "    tf-lint-all           -> Lint module root and all examples"
    _dsb_i "    tf-outputs            -> Show Terraform outputs at module root"
    _dsb_i "    tf-fmt                -> Run syntax check recursively from current directory"
    _dsb_i "    tf-fmt-fix            -> Run syntax check and fix recursively from current directory"
    _dsb_i "    tf-versions           -> Show comprehensive version information"
    _dsb_i ""
    _dsb_i "  Module Upgrade Commands:"
    _dsb_i "    tf-upgrade            -> Upgrade Terraform dependencies at root"
    _dsb_i "    tf-upgrade-all        -> Upgrade root and init all examples"
    _dsb_i "    tf-upgrade-offline    -> Same as tf-upgrade (no backend in module repos)"
    _dsb_i "    tf-upgrade-all-offline -> Same as tf-upgrade-all (no backend in module repos)"
    _dsb_i "    tf-bump               -> All-in-one bump (modules, tflint plugins, cicd, providers)"
    _dsb_i "    tf-bump-all           -> Same as tf-bump for module repos"
    _dsb_i "    tf-bump-offline       -> Same as tf-bump (no backend in module repos)"
    _dsb_i "    tf-bump-all-offline   -> Same as tf-bump-all (no backend in module repos)"
    _dsb_i "    tf-bump-modules       -> Bump module versions in .tf files"
    _dsb_i "    tf-bump-cicd          -> Bump versions in GitHub workflows"
    _dsb_i "    tf-bump-tflint-plugins -> Bump tflint plugin versions in .tflint.hcl files"
    _dsb_i "    tf-show-provider-upgrades -> Show available provider upgrades for root"
    _dsb_i ""
    _dsb_tf_help_group_examples
    _dsb_i ""
    _dsb_tf_help_group_testing
    _dsb_i ""
    _dsb_tf_help_group_docs
    _dsb_i ""
    _dsb_tf_help_group_checks
    _dsb_i ""
    _dsb_tf_help_group_azure
    _dsb_i ""
    _dsb_i "  Note: Environment commands (tf-set-env, tf-list-envs, etc.) are not available in module repos."
    _dsb_i ""
    _dsb_tf_help_group_setup
  else
    _dsb_i "All available commands:"
    _dsb_i ""
    _dsb_tf_help_group_environments
    _dsb_i ""
    _dsb_tf_help_group_terraform
    _dsb_i ""
    _dsb_tf_help_group_upgrading
    _dsb_i ""
    _dsb_tf_help_group_checks
    _dsb_i ""
    _dsb_tf_help_group_general
    _dsb_i ""
    _dsb_tf_help_group_azure
    _dsb_i ""
    _dsb_tf_help_group_setup
  fi
  _dsb_i ""
}

_dsb_tf_help_all() {
  _dsb_tf_help_help
  _dsb_i ""
  _dsb_tf_help_group_flags
  _dsb_i ""
  _dsb_tf_help_group_setup
  _dsb_i ""
  _dsb_i "Detailed Help For All Commands:"
  _dsb_i ""
  local commands
  commands=$(_dsb_tf_help_get_commands_supported_by_help)
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
    _dsb_i "  List existing environments, if an environment is selected this is indicated."
    _dsb_i ""
    _dsb_i "  Related commands: tf-set-env, tf-select-env, tf-clear-env."
    ;;
  tf-select-env)
    _dsb_i "tf-select-env:"
    _dsb_i "  List and select an environment."
    _dsb_i ""
    _dsb_i "  Additionally supply the environment as an argument to select it directly."
    _dsb_i "  Tab completion is supported for specifying environment."
    _dsb_i ""
    _dsb_i "  Related commands: tf-list-envs, tf-set-env, tf-clear-env."
    ;;
  tf-set-env)
    _dsb_i "tf-set-env [env]:"
    _dsb_i "  Set the specified environment."
    _dsb_i ""
    _dsb_i "  Supports tab completion for environment."
    _dsb_i ""
    _dsb_i "  Related commands: tf-list-envs, tf-select-env, tf-clear-env."
    ;;
  tf-check-env)
    _dsb_i "tf-check-env [env]:"
    _dsb_i "  Check if the specified environment is valid."
    _dsb_i "  If environment is not specified, the selected environment is checked."
    _dsb_i ""
    _dsb_i "  Supports tab completion for environment."
    _dsb_i ""
    _dsb_i "  Related commands: tf-list-envs, tf-set-env, tf-select-env."
    ;;
  tf-clear-env)
    _dsb_i "tf-clear-env / tf-unset-env:"
    _dsb_i "  Clear the selected environment."
    _dsb_i ""
    _dsb_i "  Related commands: tf-list-envs, tf-set-env, tf-select-env."
    ;;
  tf-unset-env)
    _dsb_i "tf-clear-env / tf-unset-env:"
    _dsb_i "  Clear the selected environment."
    _dsb_i ""
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
    _dsb_i "  Check for required tools (az cli, gh cli, terraform, jq, yq, golang, hcledit, realpath)."
    _dsb_i "  In module repos, also checks for terraform-docs (optional)."
    ;;
  tf-check-az-auth)
    _dsb_i "tf-check-az-auth:"
    _dsb_i "  Check if you are authenticated with Azure CLI."
    _dsb_i "  If authenticated, shows account and subscription details."
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
  tf-lint)
    _dsb_i "tf-lint [env] [wrapper script flags]:"
    _dsb_i "  Run tflint for the specified environment."
    _dsb_i "  If environment is not specified, the selected environment is used."
    _dsb_i ""
    _dsb_i "  Supports tab completion for environment."
    _dsb_i ""
    _dsb_i "  Note that this uses an external TFLint wrapper script from:"
    _dsb_i "    https://github.com/dsb-norge/terraform-tflint-wrappers/blob/main/tflint_linux.sh"
    _dsb_i ""
    _dsb_i "  About the wrapper script:"
    _dsb_i "    - It will be cached locally in the project directory under './.tflint'"
    _dsb_i "    - It will not be updated automatically by tf-helpers"
    _dsb_i "    - To update the wrapper script, first run tf-clean-tflint, then run tf-lint."
    _dsb_i "    - The script supports flags to control it's operation, some examples:"
    _dsb_i "      - Skip checking if latest tflint is installed locally:"
    _dsb_i "          tf-lint --skip-check"
    _dsb_i "      - Use specific TFLint version:"
    _dsb_i "          tf-lint --use-version 'v0.54.0'"
    _dsb_i "      - Force re-download of TFLint plugins:"
    _dsb_i "          tf-lint --re-init"
    _dsb_i "      - See more options by running:"
    _dsb_i "          tf-lint --help"
    _dsb_i ""
    _dsb_i "  Related commands: tf-init, tf-validate."
    ;;
  tf-clean)
    _dsb_i "tf-clean:"
    _dsb_i "  Look for and delete '.terraform' directories."
    _dsb_i ""
    _dsb_i "  Related commands: tf-clean-tflint, tf-clean-all."
    ;;
  tf-clean-tflint)
    _dsb_i "tf-clean-tflint:"
    _dsb_i "  Look for and delete '.tflint' directories."
    _dsb_i ""
    _dsb_i "  Related commands: tf-clean, tf-clean-all."
    ;;
  tf-clean-all)
    _dsb_i "tf-clean-all:"
    _dsb_i "  Look for and delete both '.terraform' and '.tflint' directories."
    _dsb_i ""
    _dsb_i "  Related commands: tf-clean, tf-clean-tflint."
    ;;
  # azure
  az-logout)
    _dsb_i "az-logout:"
    _dsb_i "  Logout from Azure CLI."
    ;;
  az-login)
    _dsb_i "az-login:"
    _dsb_i "  Login to Azure with the Azure CLI using device code."
    _dsb_i "  If possible the code will be copied to the clipboard automatically."
    _dsb_i ""
    _dsb_i "  Related commands: az-whoami, az-relog."
    ;;
  az-relog)
    _dsb_i "az-relog:"
    _dsb_i "  Re-login to Azure with the Azure CLI using device code."
    _dsb_i "  If possible the code will be copied to the clipboard automatically."
    _dsb_i ""
    _dsb_i "  Related commands: az-whoami, az-logout, az-login."
    ;;
  az-whoami)
    _dsb_i "az-whoami:"
    _dsb_i "  Show the Azure account currently logged in with the Azure CLI."
    _dsb_i ""
    _dsb_i "  Related commands: az-login, az-set-sub."
    ;;
  az-set-sub)
    _dsb_i "az-set-sub:"
    _dsb_i "  Use the the Azure CLI to set Azure subscription using subscription hint file from selected environment."
    _dsb_i ""
    _dsb_i "  Related commands: az-login, az-whoami, az-select-sub."
    ;;
  az-select-sub)
    _dsb_i "az-select-sub:"
    _dsb_i "  Use the the Azure CLI to list available subscriptions, then select the active subscription."
    _dsb_i ""
    _dsb_i "  Related commands: az-login, az-whoami."
    ;;
  # terraform
  tf-init | tf-init-offline)
    _dsb_i "tf-init [env] [terraform-flags]"
    _dsb_i "tf-init-offline [env] [terraform-flags]"
    _dsb_i "  Initialize the specified Terraform environment."
    _dsb_i "  If environment is not specified, the selected environment is used."
    _dsb_i ""
    _dsb_i "  This also initializes the main module and any local sub-modules."
    _dsb_i ""
    _dsb_i "  When using the '-offline' variant terraform will not attempt to connect to the state backend."
    _dsb_i ""
    _dsb_i "  Terraform flags (single dash, e.g. -input=false) are passed through to terraform init."
    _dsb_i ""
    _dsb_i "  Note:"
    _dsb_i "    For a complete initialization of the entire project, use 'tf-init-all'."
    _dsb_i ""
    _dsb_i "  Supports tab completion for environment."
    _dsb_i ""
    _dsb_i "  Related commands: tf-init-all, tf-upgrade, tf-plan, tf-apply."
    ;;
  tf-init-env | tf-init-env-offline)
    _dsb_i "tf-init-env [env]"
    _dsb_i "tf-init-env-offline [env]"
    _dsb_i "  Initialize the specified Terraform environment."
    _dsb_i "  If environment is not specified, the selected environment is used."
    _dsb_i ""
    _dsb_i "  When using the '-offline' variant terraform will not attempt to connect to the state backend."
    _dsb_i ""
    _dsb_i "  Note:"
    _dsb_i "    This initializes just the environment directory, not sub-modules and not the main module."
    _dsb_i "    Use 'tf-init' for a complete initialization of the environment."
    _dsb_i "    Or, use 'tf-init-all' for a complete initialization of the entire project."
    _dsb_i ""
    _dsb_i "  Supports tab completion for environment."
    _dsb_i ""
    _dsb_i "  Related commands: tf-init-main, tf-init-modules, tf-upgrade-env, tf-init, tf-init-all."
    ;;
  tf-init-all | tf-init-all-offline)
    _dsb_i "tf-init-all"
    _dsb_i "tf-init-all-offline"
    _dsb_i "  Initialize the entire Terraform project."
    _dsb_i ""
    _dsb_i "  In project repos, initializes all environment directories, main module, and local sub-modules."
    _dsb_i "  In module repos, initializes the module root and all examples."
    _dsb_i ""
    _dsb_i "  When using the '-offline' variant terraform will not attempt to connect to the state backend."
    _dsb_i ""
    _dsb_i "  Related commands: tf-upgrade, tf-plan, tf-apply, tf-upgrade-all, tf-bump-all"
    ;;
  tf-init-main)
    _dsb_i "tf-init-main:"
    _dsb_i "  Initialize Terraform project's main module."
    _dsb_i ""
    _dsb_i "  Note:"
    _dsb_i "    Since the environment directory is used as plugin cache during the operation,"
    _dsb_i "    it is required that an environment has been select and initialized first."
    _dsb_i "    For example by running 'tf-init-env'."
    _dsb_i ""
    _dsb_i "  Also note:"
    _dsb_i "    This initializes just the main directory, not sub-modules."
    _dsb_i "    Use 'tf-init' for a complete initialization of the project."
    _dsb_i ""
    _dsb_i ""
    _dsb_i "  Related commands: tf-init-env, tf-init, tf-init-all."
    ;;
  tf-init-modules)
    _dsb_i "tf-init-modules:"
    _dsb_i "  Initialize Terraform project's local sub-modules."
    _dsb_i ""
    _dsb_i "  Note:"
    _dsb_i "    Since the environment directory is used as plugin cache during the operation,"
    _dsb_i "    it is required that an environment has been select and initialized first."
    _dsb_i "    For example by running 'tf-init-env'."
    _dsb_i ""
    _dsb_i "  Also note:"
    _dsb_i "    This initializes just the su module directories, not the main directory."
    _dsb_i "    Use 'tf-init' for a complete initialization of the project."
    _dsb_i ""
    _dsb_i "  Related commands: tf-init-env, tf-init, tf-init-all."
    ;;
  tf-fmt)
    _dsb_i "tf-fmt:"
    _dsb_i "  Run Terraform syntax check recursively from current directory."
    _dsb_i ""
    _dsb_i "  This command only checks the syntax of the files."
    _dsb_i "  Use 'tf-fmt-fix' to fix syntax issues."
    _dsb_i ""
    _dsb_i "  Related commands: tf-fmt-fix."
    ;;
  tf-fmt-fix)
    _dsb_i "tf-fmt-fix:"
    _dsb_i "  Run Terraform syntax check and fix recursively from current directory."
    _dsb_i ""
    _dsb_i "  This command checks and fixes syntax issues in the files."
    _dsb_i "  Use 'tf-fmt' to only check the syntax."
    _dsb_i ""
    _dsb_i "  Related commands: tf-fmt."
    ;;
  tf-validate)
    _dsb_i "tf-validate [env]:"
    _dsb_i "  Make Terraform validate the project with the specified environment."
    _dsb_i "  If environment is not specified, the selected environment is used."
    _dsb_i ""
    _dsb_i "  Supports tab completion for environment."
    _dsb_i ""
    _dsb_i "  Related commands: tf-init, tf-validate-all, tf-plan, tf-apply."
    ;;
  tf-validate-all)
    _dsb_i "tf-validate-all:"
    _dsb_i "  Validate all Terraform configurations."
    _dsb_i ""
    _dsb_i "  In project repos, validates all environments."
    _dsb_i "  In module repos, validates the module root and all examples."
    _dsb_i ""
    _dsb_i "  Related commands: tf-validate, tf-init-all."
    ;;
  tf-lint-all)
    _dsb_i "tf-lint-all:"
    _dsb_i "  Lint all Terraform configurations."
    _dsb_i ""
    _dsb_i "  In project repos, runs tflint for all environments."
    _dsb_i "  In module repos, lints the module root and all examples."
    _dsb_i ""
    _dsb_i "  Related commands: tf-lint, tf-validate-all."
    ;;
  tf-outputs)
    _dsb_i "tf-outputs [env]:"
    _dsb_i "  Show Terraform outputs."
    _dsb_i ""
    _dsb_i "  In project repos, shows outputs for the selected or specified environment."
    _dsb_i "  In module repos, shows outputs at the module root."
    _dsb_i ""
    _dsb_i "  Supports tab completion for environment (project repos)."
    _dsb_i ""
    _dsb_i "  Related commands: tf-plan, tf-apply."
    ;;
  tf-versions)
    _dsb_i "tf-versions:"
    _dsb_i "  Show comprehensive version information."
    _dsb_i ""
    _dsb_i "  Shows tool versions (Terraform CLI, TFLint), required terraform versions,"
    _dsb_i "  provider constraints and locked versions, tflint plugin versions,"
    _dsb_i "  and GitHub workflow terraform/tflint versions."
    _dsb_i ""
    _dsb_i "  In project repos, shows per-environment details plus project-wide workflow versions."
    _dsb_i "  In module repos, shows module root details and workflow versions."
    _dsb_i ""
    _dsb_i "  Related commands: tf-status, tf-check-tools."
    ;;
  tf-plan)
    _dsb_i "tf-plan [env] [terraform-flags] [--log[=file]]:"
    _dsb_i "  Make Terraform create a plan for the specified environment."
    _dsb_i "  If environment is not specified, the selected environment is used."
    _dsb_i ""
    _dsb_i "  Terraform flags (single dash) are passed through to terraform plan."
    _dsb_i "  Use --log to save output to a file (ANSI colors stripped)."
    _dsb_i "  Use --log=<path> to specify the output file path."
    _dsb_i ""
    _dsb_i "  Examples:"
    _dsb_i "    tf-plan dev                        -> basic plan"
    _dsb_i "    tf-plan dev -target=module.foo      -> plan specific resource"
    _dsb_i "    tf-plan dev -out=plan.tfplan        -> save binary plan file"
    _dsb_i "    tf-plan dev --log                   -> save console output to file"
    _dsb_i "    tf-plan dev -target=module.foo --log=./my-plan.log"
    _dsb_i ""
    _dsb_i "  Supports tab completion for environment."
    _dsb_i ""
    _dsb_i "  Related commands: tf-init, tf-validate, tf-apply."
    ;;
  tf-apply)
    _dsb_i "tf-apply [env] [terraform-flags] [--log[=file]]:"
    _dsb_i "  Make Terraform apply changes for the specified environment."
    _dsb_i "  If environment is not specified, the selected environment is used."
    _dsb_i ""
    _dsb_i "  Terraform flags (single dash) are passed through to terraform apply."
    _dsb_i "  Use --log to save output to a file (ANSI colors stripped)."
    _dsb_i "  Use --log=<path> to specify the output file path."
    _dsb_i ""
    _dsb_i "  Examples:"
    _dsb_i "    tf-apply dev                            -> interactive apply"
    _dsb_i "    tf-apply dev -auto-approve              -> non-interactive apply"
    _dsb_i "    tf-apply dev plan.tfplan                -> apply saved plan file"
    _dsb_i "    tf-apply dev --log                      -> save console output to file"
    _dsb_i ""
    _dsb_i "  Supports tab completion for environment."
    _dsb_i ""
    _dsb_i "  Related commands: tf-init, tf-validate, tf-plan."
    ;;
  tf-destroy)
    _dsb_i "tf-destroy [env]:"
    _dsb_i "  Show command to manually destroy the specified environment."
    _dsb_i "  If environment is not specified, the selected environment is used."
    _dsb_i ""
    _dsb_i "  Supports tab completion for environment."
    _dsb_i ""
    _dsb_i "  Related commands: tf-init, tf-validate, tf-plan, tf-apply."
    ;;
    # upgrading
  tf-bump | tf-bump-offline)
    _dsb_i "tf-bump [env]"
    _dsb_i "tf-bump-offline [env]"
    _dsb_i "  All-in-one bump function for the specified environment."
    _dsb_i "  If environment is not specified, the selected environment is used."
    _dsb_i ""
    _dsb_i "  Upgrades:"
    _dsb_i "    - all modules sourced from the official Hashicorp registry, to latest, in entire project"
    _dsb_i "    - tflint plugin versions in .tflint.hcl files, in entire project"
    _dsb_i "    - versions in GitHub workflows"
    _dsb_i ""
    _dsb_i "  When using the '-offline' variant terraform will not attempt to connect to the state backend."
    _dsb_i ""
    _dsb_i "  Also:"
    _dsb_i "    - upgrades Terraform dependencies for the specified environment"
    _dsb_i "      - within the current version constraints, ie. no version constraints are changed."
    _dsb_i "    - aids with provider upgrading by also:"
    _dsb_i "      - listing provider versions, latest available vs. lock file for the specified environment"
    _dsb_i ""
    _dsb_i "  Supports tab completion for environment."
    _dsb_i ""
    _dsb_i "  Related commands: tf-bump-all, tf-upgrade, tf-bump-modules, tf-bump-cicd, tf-bump-tflint-plugins, tf-show-provider-upgrades."
    ;;
  tf-bump-env | tf-bump-env-offline)
    _dsb_i "tf-bump-env [env]"
    _dsb_i "tf-bump-env-offline [env]"
    _dsb_i "  Bump function for the specified environment."
    _dsb_i "  If environment is not specified, the selected environment is used."
    _dsb_i ""
    _dsb_i "  Upgrades Terraform dependencies for the specified environment"
    _dsb_i "    - within the current version constraints, ie. no version constraints are changed."
    _dsb_i ""
    _dsb_i "  Aids with provider upgrading by also listing provider versions."
    _dsb_i "  Latest available vs. lock file for the specified environment."
    _dsb_i ""
    _dsb_i "  When using the '-offline' variant terraform will not attempt to connect to the state backend."
    _dsb_i ""
    _dsb_i "  Note:"
    _dsb_i "    This does not upgrade modules, tflint plugins, or GitHub workflows."
    _dsb_i "    See 'tf-bump' or 'tf-bump-all' for more complete upgrade scenarios."
    _dsb_i ""
    _dsb_i "  Supports tab completion for environment."
    _dsb_i ""
    _dsb_i "  Related commands: tf-bump, tf-bump-all, tf-bump-modules, tf-bump-cicd, tf-bump-tflint-plugins, tf-show-provider-upgrades."
    ;;
  tf-bump-all | tf-bump-all-offline)
    _dsb_i "tf-bump-all [env]"
    _dsb_i "tf-bump-all-offline [env]"
    _dsb_i "  All-in-one bump function the entire project."
    _dsb_i ""
    _dsb_i "  Upgrades:"
    _dsb_i "    - all modules sourced from the official Hashicorp registry, to latest, in entire project"
    _dsb_i "    - tflint plugin versions in .tflint.hcl files, in entire project"
    _dsb_i "    - versions in GitHub workflows"
    _dsb_i ""
    _dsb_i "  Also:"
    _dsb_i "    - upgrades Terraform dependencies for all environments"
    _dsb_i "      - within the current version constraints, ie. no version constraints are changed."
    _dsb_i "    - aids with provider upgrading by also:"
    _dsb_i "      - listing provider versions, latest available vs. lock file for all environments"
    _dsb_i ""
    _dsb_i "  When using the '-offline' variant terraform will not attempt to connect to the state backend."
    _dsb_i ""
    _dsb_i "  Related commands: tf-upgrade-all, tf-init-all, tf-bump, tf-upgrade, tf-bump-modules, tf-bump-cicd, tf-bump-tflint-plugins, tf-show-provider-upgrades."
    ;;
  tf-upgrade | tf-upgrade-offline)
    _dsb_i "tf-upgrade [env]"
    _dsb_i "tf-upgrade-offline [env]"
    _dsb_i "  Upgrade Terraform dependencies for the specified environment."
    _dsb_i "  If environment is not specified, the selected environment is used."
    _dsb_i ""
    _dsb_i "  This also upgrades and initializes the main module and any local sub-modules."
    _dsb_i "  Upgrade is performed within the current version constraints, ie. no version constraints are changed."
    _dsb_i ""
    _dsb_i "  When using the '-offline' variant terraform will not attempt to connect to the state backend."
    _dsb_i ""
    _dsb_i "  Note:"
    _dsb_i "    For a complete upgrade of the entire project, use 'tf-upgrade-all'."
    _dsb_i ""
    _dsb_i "  Supports tab completion for environment."
    _dsb_i ""
    _dsb_i "  Related commands: tf-init, tf-upgrade-all, tf-plan, tf-apply, tf-bump-modules, tf-bump."
    ;;
  tf-upgrade-env | tf-upgrade-env-offline)
    _dsb_i "tf-upgrade-env [env]"
    _dsb_i "tf-upgrade-env-offline [env]"
    _dsb_i "  Upgrade Terraform dependencies and initialize the specified environment."
    _dsb_i "  If environment is not specified, the selected environment is used."
    _dsb_i ""
    _dsb_i "  Upgrade is performed within the current version constraints, ie. no version constraints are changed."
    _dsb_i ""
    _dsb_i "  When using the '-offline' variant terraform will not attempt to connect to the state backend."
    _dsb_i ""
    _dsb_i "  Note:"
    _dsb_i "    This upgrades and initializes just the environment directory, not sub-modules and main."
    _dsb_i "    Use 'tf-upgrade' for a complete dependency upgrade and initialization of the environment."
    _dsb_i "    Or, use 'tf-upgrade-all' for a complete upgrade and initialization of the entire project."
    _dsb_i ""
    _dsb_i "  Supports tab completion for environment."
    _dsb_i ""
    _dsb_i "  Related commands: tf-init-main, tf-init-modules, tf-upgrade, tf-upgrade-all, tf-bump."
    ;;
  tf-upgrade-all | tf-upgrade-all-offline)
    _dsb_i "tf-upgrade-all"
    _dsb_i "tf-upgrade-all-offline"
    _dsb_i "  Upgrade Terraform dependencies and initialize the entire project."
    _dsb_i ""
    _dsb_i "  This upgrades and initializes the project completely, environment directory, sub-modules and main."
    _dsb_i "  Upgrade is performed within the current version constraints, ie. no version constraints are changed."
    _dsb_i ""
    _dsb_i "  When using the '-offline' variant terraform will not attempt to connect to the state backend."
    _dsb_i ""
    _dsb_i "  Related commands: tf-bump-all, tf-init, tf-plan, tf-apply, tf-bump-modules."
    ;;
  tf-bump-cicd)
    _dsb_i "tf-bump-cicd:"
    _dsb_i "  Bump versions in GitHub workflows."
    _dsb_i "  Currently supports bumping Terraform and tflint versions."
    _dsb_i ""
    _dsb_i "  Retrieves the latest versions from GitHub and updates all workflow files in .github/workflows."
    _dsb_i "  If a tool is configured with 'latest' it will not be updated."
    _dsb_i ""
    _dsb_i "  If a tool is configured with partial semver version or x as wildcard, the syntax is preserved and versions updated as needed."
    _dsb_i "  Examples where latest version is 'v1.13.7':"
    _dsb_i "    - \e[90m'v1.12.2'\e[0m becomes \e[32m'v1.13.7'\e[0m"
    _dsb_i "    - \e[90m'v1.12.x'\e[0m becomes \e[32m'v1.13.x'\e[0m"
    _dsb_i "    - \e[90m'v1.12'\e[0m becomes \e[32m'v1.13'\e[0m"
    _dsb_i "    - \e[90m'v0'\e[0m becomes \e[32m'v1'\e[0m"
    _dsb_i ""
    _dsb_i "  Related commands: tf-upgrade-all, tf-bump-modules, tf-bump-tflint-plugins, tf-bump, tf-bump-all."
    ;;
  tf-bump-modules)
    _dsb_i "tf-bump-modules:"
    _dsb_i "  Bump module versions referenced in the project."
    _dsb_i "  Currently only applies to modules sourced from the official Hashicorp registry."
    _dsb_i ""
    _dsb_i "  Retrieves the latest versions from the Terraform registry and updates modules in all .tf files in the project."
    _dsb_i ""
    _dsb_i "  Note:"
    _dsb_i "    When deciding where to update, this command only checks for difference between the declared version and the latest version."
    _dsb_i "    No consideration is taken for version constraints or partial version values."
    _dsb_i ""
    _dsb_i "  Related commands: tf-upgrade-all, tf-bump-cicd, tf-bump-tflint-plugins, tf-bump, tf-bump-all."
    ;;
  tf-bump-tflint-plugins)
    _dsb_i "tf-bump-tflint-plugins:"
    _dsb_i "  Bump tflint plugin versions in all .tflint.hcl files."
    _dsb_i ""
    _dsb_i "  Retrieves the latest plugin versions from GitHub and updates plugins in all .tflint.hcl files in the project."
    _dsb_i ""
    _dsb_i "  Note:"
    _dsb_i "    When deciding where to update, this command only checks for difference between the declared version and the latest version."
    _dsb_i "    No consideration is taken for version constraints or partial version values."
    _dsb_i ""
    _dsb_i "  Related commands: tf-upgrade-all, tf-bump-cicd, tf-bump-modules, tf-bump, tf-bump-all."
    ;;
  tf-show-provider-upgrades)
    _dsb_i "tf-show-provider-upgrades [env]:"
    _dsb_i "  Show available provider upgrades for the specified environment."
    _dsb_i "  If environment is not specified, the selected environment is used."
    _dsb_i ""
    _dsb_i "  Lists all providers and retrieves the latest available versions."
    _dsb_i "  Also shows the version constraint(s) currently configured, as well as the locked version (from the lock file)."
    _dsb_i ""
    _dsb_i "  Supports tab completion for environment."
    _dsb_i ""
    _dsb_i "  Related commands: tf-show-all-provider-upgrades, tf-bump."
    ;;
  tf-show-all-provider-upgrades)
    _dsb_i "tf-show-all-provider-upgrades:"
    _dsb_i "  Show all available provider upgrades for all environments."
    _dsb_i ""
    _dsb_i "  Lists all providers and retrieves the latest available versions."
    _dsb_i "  Also shows the version constraint(s) currently configured, as well as the locked version (from the lock file)."
    _dsb_i ""
    _dsb_i "  Related commands: tf-show-provider-upgrades, tf-bump, tf-bump-all."
    ;;
  # examples (module only)
  tf-init-all-examples)
    _dsb_i "tf-init-all-examples [example]:"
    _dsb_i "  Initialize all or a specific example directory (module repo only)."
    _dsb_i ""
    _dsb_i "  Runs 'terraform init -reconfigure' in each example subdirectory under examples/."
    _dsb_i "  If an example name is given, only that example is initialized."
    _dsb_i ""
    _dsb_i "  Supports tab completion for example names."
    _dsb_i ""
    _dsb_i "  Related commands: tf-init-example, tf-validate-all-examples, tf-lint-all-examples."
    ;;
  tf-init-example)
    _dsb_i "tf-init-example <example>:"
    _dsb_i "  Initialize a specific example directory (module repo only)."
    _dsb_i ""
    _dsb_i "  Requires an example name. Supports tab completion."
    _dsb_i ""
    _dsb_i "  Related commands: tf-init-all-examples, tf-validate-example."
    ;;
  tf-validate-all-examples)
    _dsb_i "tf-validate-all-examples [example]:"
    _dsb_i "  Validate all or a specific example directory (module repo only)."
    _dsb_i ""
    _dsb_i "  Runs 'terraform validate' in each example subdirectory under examples/."
    _dsb_i "  Examples must be initialized first (run tf-init-all-examples)."
    _dsb_i ""
    _dsb_i "  Supports tab completion for example names."
    _dsb_i ""
    _dsb_i "  Related commands: tf-validate-example, tf-init-all-examples, tf-lint-all-examples."
    ;;
  tf-validate-example)
    _dsb_i "tf-validate-example <example>:"
    _dsb_i "  Validate a specific example directory (module repo only)."
    _dsb_i ""
    _dsb_i "  Example must be initialized first (run tf-init-example)."
    _dsb_i "  Requires an example name. Supports tab completion."
    _dsb_i ""
    _dsb_i "  Related commands: tf-validate-all-examples, tf-init-example."
    ;;
  tf-lint-all-examples)
    _dsb_i "tf-lint-all-examples [example]:"
    _dsb_i "  Run tflint on all or a specific example directory (module repo only)."
    _dsb_i ""
    _dsb_i "  Lints each example using the root .tflint.hcl configuration."
    _dsb_i ""
    _dsb_i "  Supports tab completion for example names."
    _dsb_i ""
    _dsb_i "  Related commands: tf-lint-example, tf-init-all-examples, tf-validate-all-examples."
    ;;
  tf-lint-example)
    _dsb_i "tf-lint-example <example>:"
    _dsb_i "  Run tflint on a specific example directory (module repo only)."
    _dsb_i ""
    _dsb_i "  Uses the root .tflint.hcl configuration."
    _dsb_i "  Requires an example name. Supports tab completion."
    _dsb_i ""
    _dsb_i "  Related commands: tf-lint-all-examples, tf-init-example."
    ;;
  # testing (module only)
  tf-test)
    _dsb_i "tf-test [filter] [--log[=file]]:"
    _dsb_i "  Run terraform test at module root (module repo only)."
    _dsb_i ""
    _dsb_i "  If a filter is given (a test file name), only that test file is run."
    _dsb_i "  If no filter is given and integration tests exist, subscription confirmation is required."
    _dsb_i "  Use --log to save output to a file (ANSI colors stripped)."
    _dsb_i ""
    _dsb_i "  Supports tab completion for test file names."
    _dsb_i ""
    _dsb_i "  Related commands: tf-test-unit, tf-test-integration, tf-test-all-integrations."
    ;;
  tf-test-unit)
    _dsb_i "tf-test-unit [--log[=file]]:"
    _dsb_i "  Run unit tests only (module repo only)."
    _dsb_i ""
    _dsb_i "  Runs all test files matching unit-*.tftest.hcl."
    _dsb_i "  Unit tests use mocked providers and do not need Azure authentication."
    _dsb_i "  Use --log to save output to a file (ANSI colors stripped)."
    _dsb_i ""
    _dsb_i "  Related commands: tf-test, tf-test-integration, tf-test-all-integrations."
    ;;
  tf-test-integration)
    _dsb_i "tf-test-integration <name> [--log[=file]]:"
    _dsb_i "  Run a specific integration test file (module repo only)."
    _dsb_i ""
    _dsb_i "  Requires an integration test file name (e.g., integration-test-01-basic.tftest.hcl)."
    _dsb_i "  WARNING: Integration tests deploy real Azure resources."
    _dsb_i "  Requires Azure CLI login and subscription confirmation."
    _dsb_i "  Use --log to save output to a file (ANSI colors stripped)."
    _dsb_i "  Supports tab completion for integration test file names."
    _dsb_i ""
    _dsb_i "  Related commands: tf-test-all-integrations, tf-test, tf-test-unit."
    ;;
  tf-test-all-integrations)
    _dsb_i "tf-test-all-integrations [--log[=file]]:"
    _dsb_i "  Run all integration tests (module repo only)."
    _dsb_i ""
    _dsb_i "  Runs all test files matching integration-*.tftest.hcl."
    _dsb_i "  WARNING: Integration tests deploy real Azure resources."
    _dsb_i "  Requires Azure CLI login and subscription confirmation."
    _dsb_i "  Use --log to save output to a file (ANSI colors stripped)."
    _dsb_i ""
    _dsb_i "  Related commands: tf-test-integration, tf-test, tf-test-unit."
    ;;
  tf-test-all-examples)
    _dsb_i "tf-test-all-examples [example] [--log[=file]]:"
    _dsb_i "  Test all examples by running init + apply + destroy (module repo only)."
    _dsb_i ""
    _dsb_i "  For each example: initializes, applies, then destroys."
    _dsb_i "  WARNING: This deploys real Azure resources."
    _dsb_i "  Requires Azure CLI login and subscription name confirmation."
    _dsb_i "  On failure, asks whether to continue with remaining examples."
    _dsb_i "  Use --log to save output to a file (ANSI colors stripped)."
    _dsb_i ""
    _dsb_i "  Supports tab completion for example names."
    _dsb_i ""
    _dsb_i "  Related commands: tf-test-example, tf-init-all-examples, tf-test-all-integrations."
    ;;
  tf-test-example)
    _dsb_i "tf-test-example <example> [--log[=file]]:"
    _dsb_i "  Test a specific example by running init + apply + destroy (module repo only)."
    _dsb_i ""
    _dsb_i "  For the specified example: initializes, applies, then destroys."
    _dsb_i "  WARNING: This deploys real Azure resources."
    _dsb_i "  Requires Azure CLI login and subscription name confirmation."
    _dsb_i "  Use --log to save output to a file (ANSI colors stripped)."
    _dsb_i ""
    _dsb_i "  Supports tab completion for example names."
    _dsb_i ""
    _dsb_i "  Related commands: tf-test-all-examples, tf-init-all-examples, tf-test-all-integrations."
    ;;
  # docs (module only)
  tf-docs)
    _dsb_i "tf-docs:"
    _dsb_i "  Generate terraform-docs for the module root (module repo only)."
    _dsb_i ""
    _dsb_i "  Runs 'terraform-docs .' using the root .terraform-docs.yml configuration."
    _dsb_i "  Requires terraform-docs to be installed."
    _dsb_i ""
    _dsb_i "  Related commands: tf-docs-all-examples, tf-docs-all."
    ;;
  tf-docs-all-examples)
    _dsb_i "tf-docs-all-examples:"
    _dsb_i "  Generate terraform-docs for all example directories (module repo only)."
    _dsb_i ""
    _dsb_i "  Uses the examples/.terraform-docs.yml configuration."
    _dsb_i "  Requires terraform-docs to be installed."
    _dsb_i ""
    _dsb_i "  Related commands: tf-docs-example, tf-docs, tf-docs-all."
    ;;
  tf-docs-example)
    _dsb_i "tf-docs-example <example>:"
    _dsb_i "  Generate terraform-docs for a specific example directory (module repo only)."
    _dsb_i ""
    _dsb_i "  Uses the examples/.terraform-docs.yml configuration."
    _dsb_i "  Requires terraform-docs to be installed."
    _dsb_i "  Requires an example name. Supports tab completion."
    _dsb_i ""
    _dsb_i "  Related commands: tf-docs-all-examples, tf-docs."
    ;;
  tf-docs-all)
    _dsb_i "tf-docs-all:"
    _dsb_i "  Generate terraform-docs for root and all examples (module repo only)."
    _dsb_i ""
    _dsb_i "  Runs tf-docs then tf-docs-all-examples."
    _dsb_i "  Requires terraform-docs to be installed."
    _dsb_i ""
    _dsb_i "  Related commands: tf-docs, tf-docs-all-examples."
    ;;
  # setup
  tf-install-helpers)
    _dsb_i "tf-install-helpers:"
    _dsb_i "  Install the helpers script locally to ~/.local/bin."
    _dsb_i ""
    _dsb_i "  If sourced from a file, copies it to ~/.local/bin/dsb-tf-proj-helpers.sh."
    _dsb_i "  If loaded via process substitution (source <(curl ...)), downloads the"
    _dsb_i "  script from GitHub using gh cli (preferred) or curl (fallback)."
    _dsb_i "  Optionally adds a 'tf-load-helpers' alias to your shell profile"
    _dsb_i "  (.bashrc or .zshrc) so you can load the helpers by typing: tf-load-helpers"
    _dsb_i ""
    _dsb_i "  Safe to run multiple times (idempotent -- no duplicate alias entries)."
    _dsb_i ""
    _dsb_i "  Set DSB_TF_HELPERS_BRANCH to download from a feature branch:"
    _dsb_i "    export DSB_TF_HELPERS_BRANCH=my-feature-branch"
    _dsb_i "    tf-install-helpers"
    _dsb_i ""
    _dsb_i "  Related commands: tf-uninstall-helpers, tf-update-helpers, tf-reload-helpers."
    ;;
  tf-uninstall-helpers)
    _dsb_i "tf-uninstall-helpers:"
    _dsb_i "  Remove the locally installed helpers script and shell alias."
    _dsb_i ""
    _dsb_i "  Removes ~/.local/bin/dsb-tf-proj-helpers.sh and the tf-load-helpers"
    _dsb_i "  alias from your shell profile (if present). Asks for confirmation."
    _dsb_i ""
    _dsb_i "  Related commands: tf-install-helpers, tf-unload-helpers."
    ;;
  tf-update-helpers)
    _dsb_i "tf-update-helpers:"
    _dsb_i "  Download the latest version and reload the helpers."
    _dsb_i ""
    _dsb_i "  Downloads the latest script from GitHub using gh cli (preferred) or"
    _dsb_i "  curl (fallback), replaces the local copy, and re-sources it."
    _dsb_i "  Requires the helpers to be installed locally first."
    _dsb_i ""
    _dsb_i "  Set DSB_TF_HELPERS_BRANCH to download from a feature branch:"
    _dsb_i "    export DSB_TF_HELPERS_BRANCH=my-feature-branch"
    _dsb_i "    tf-update-helpers"
    _dsb_i ""
    _dsb_i "  Related commands: tf-install-helpers, tf-reload-helpers."
    ;;
  tf-reload-helpers)
    _dsb_i "tf-reload-helpers:"
    _dsb_i "  Reload the helpers from the local copy."
    _dsb_i ""
    _dsb_i "  Re-sources the installed script from ~/.local/bin."
    _dsb_i "  Useful for resetting internal state or after manual edits."
    _dsb_i "  Requires the helpers to be installed locally."
    _dsb_i ""
    _dsb_i "  Related commands: tf-update-helpers, tf-unload-helpers."
    ;;
  tf-unload-helpers)
    _dsb_i "tf-unload-helpers:"
    _dsb_i "  Completely remove all DSB Terraform Helpers from the current shell."
    _dsb_i ""
    _dsb_i "  Removes all functions (tf-*, az-*, _dsb_*), global variables (_dsbTf*),"
    _dsb_i "  tab completions, and temporary files."
    _dsb_i "  After running, the shell returns to its state before the helpers were loaded."
    _dsb_i "  Does not affect the installed copy -- use tf-uninstall-helpers for that."
    _dsb_i ""
    _dsb_i "  Related commands: tf-reload-helpers, tf-uninstall-helpers."
    ;;
  *)
    _dsb_w "Unknown help topic: ${command}"
    ;;
  esac
}

###################################################################################################
#
# Utility functions: Tab completion
#
###################################################################################################

# for _dsbTfAvailableEnvs
# --------------------------------------------------
_dsb_tf_completions_for_available_envs() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  COMPREPLY=()

  # always enumerate, we do not know the directory the function is called from
  # note: debug mode must be disabled, otherwise the debug output will mess up the completions
  _dsbTfLogDebug=0 _dsb_tf_enumerate_directories || :

  # only complete the first argument
  if [[ ${COMP_CWORD} -eq 1 ]]; then
    # only complete if _dsbTfAvailableEnvs is set
    if [[ -v _dsbTfAvailableEnvs ]]; then
      if [[ -n "${_dsbTfAvailableEnvs[*]}" ]]; then
        mapfile -t COMPREPLY < <(compgen -W "${_dsbTfAvailableEnvs[*]}" -- "${cur}")
      fi
    fi
  fi
}

_dsb_tf_register_completions_for_available_envs() {
  complete -F _dsb_tf_completions_for_available_envs tf-set-env
  complete -F _dsb_tf_completions_for_available_envs tf-check-env
  complete -F _dsb_tf_completions_for_available_envs tf-select-env
  complete -F _dsb_tf_completions_for_available_envs tf-init-env
  complete -F _dsb_tf_completions_for_available_envs tf-init-env-offline
  complete -F _dsb_tf_completions_for_available_envs tf-init
  complete -F _dsb_tf_completions_for_available_envs tf-init-offline
  complete -F _dsb_tf_completions_for_available_envs tf-upgrade-env
  complete -F _dsb_tf_completions_for_available_envs tf-upgrade-env-offline
  complete -F _dsb_tf_completions_for_available_envs tf-upgrade
  complete -F _dsb_tf_completions_for_available_envs tf-upgrade-offline
  complete -F _dsb_tf_completions_for_available_envs tf-validate
  complete -F _dsb_tf_completions_for_available_envs tf-plan
  complete -F _dsb_tf_completions_for_available_envs tf-apply
  complete -F _dsb_tf_completions_for_available_envs tf-destroy
  complete -F _dsb_tf_completions_for_available_envs tf-show-provider-upgrades
  complete -F _dsb_tf_completions_for_available_envs tf-bump
  complete -F _dsb_tf_completions_for_available_envs tf-bump-offline
  complete -F _dsb_tf_completions_for_available_envs tf-bump-env
  complete -F _dsb_tf_completions_for_available_envs tf-bump-env-offline
  complete -F _dsb_tf_completions_for_available_envs tf-outputs
}

# special for tf-lint
# supports [env] and wrapper script flags
# --------------------------------------------------
_dsb_tf_completions_for_tf_lint() {
  local cur
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"

  # always enumerate, we do not know the directory the function is called from
  # note: debug mode must be disabled, otherwise the debug output will mess up the completions
  _dsbTfLogDebug=0 _dsb_tf_enumerate_directories || :

  if [[ ${COMP_CWORD} -eq 1 ]]; then
    # complete for the first argument
    # only complete if _dsbTfAvailableEnvs is set
    if [[ -v _dsbTfAvailableEnvs ]]; then
      if [[ -n "${_dsbTfAvailableEnvs[*]}" ]]; then
        mapfile -t COMPREPLY < <(compgen -W "${_dsbTfAvailableEnvs[*]}" -- "${cur}")
      fi
    fi
  elif [[ ${COMP_CWORD} -ge 2 && ${COMP_WORDS[0]} == "tf-lint" ]]; then
    # complete for the second argument and beyond
    mapfile -t COMPREPLY < <(compgen -W "--force-install --help --re-init --remove --skip-latest-check --uninstall --use-version" -- "${cur}")
  fi
}

_dsb_tf_register_completions_for_tf_lint() {
  complete -F _dsb_tf_completions_for_tf_lint tf-lint
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

# for module repo example names
# --------------------------------------------------
_dsb_tf_completions_for_example_names() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  COMPREPLY=()

  # re-enumerate to get fresh example list
  _dsbTfLogDebug=0 _dsb_tf_enumerate_directories || :

  # debug: write to file to avoid corrupting completion output on the terminal
  # enable with: export _DSB_TF_COMPLETION_DEBUG=1
  local _debugFile="/tmp/dsb-tf-completion-debug.log"
  if [[ "${_DSB_TF_COMPLETION_DEBUG:-0}" == "1" ]]; then
    {
      echo "--- $(date -Iseconds) _dsb_tf_completions_for_example_names ---"
      echo "  COMP_WORDS: ${COMP_WORDS[*]}"
      echo "  COMP_CWORD: ${COMP_CWORD}"
      echo "  cur: ${cur}"
      echo "  _dsbTfRepoType: ${_dsbTfRepoType:-unset}"
      echo "  _dsbTfExamplesDirList declared: $(declare -p _dsbTfExamplesDirList 2>&1 | head -1)"
    } >> "${_debugFile}"
  fi

  # complete the first argument with example names
  if [[ ${COMP_CWORD} -eq 1 ]]; then
    # note: [[ -v ]] doesn't work for associative arrays in bash, use declare -p
    if declare -p _dsbTfExamplesDirList &>/dev/null; then
      local -a exNames=()
      local _exKey
      for _exKey in "${!_dsbTfExamplesDirList[@]}"; do
        exNames+=("${_exKey}")
      done
      if [[ -n "${exNames[*]}" ]]; then
        mapfile -t COMPREPLY < <(compgen -W "${exNames[*]}" -- "${cur}")
      fi
      if [[ "${_DSB_TF_COMPLETION_DEBUG:-0}" == "1" ]]; then
        echo "  exNames: ${exNames[*]}" >> "${_debugFile}"
        echo "  COMPREPLY: ${COMPREPLY[*]}" >> "${_debugFile}"
      fi
    else
      if [[ "${_DSB_TF_COMPLETION_DEBUG:-0}" == "1" ]]; then
        echo "  _dsbTfExamplesDirList not declared" >> "${_debugFile}"
      fi
    fi
  fi
}

_dsb_tf_register_completions_for_example_names() {
  complete -F _dsb_tf_completions_for_example_names tf-init-all-examples
  complete -F _dsb_tf_completions_for_example_names tf-init-example
  complete -F _dsb_tf_completions_for_example_names tf-validate-all-examples
  complete -F _dsb_tf_completions_for_example_names tf-validate-example
  complete -F _dsb_tf_completions_for_example_names tf-lint-all-examples
  complete -F _dsb_tf_completions_for_example_names tf-lint-example
  complete -F _dsb_tf_completions_for_example_names tf-test-all-examples
  complete -F _dsb_tf_completions_for_example_names tf-test-example
  complete -F _dsb_tf_completions_for_example_names tf-docs-example
}

# for module repo test file names
# --------------------------------------------------
_dsb_tf_completions_for_test_names() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  COMPREPLY=()

  _dsbTfLogDebug=0 _dsb_tf_enumerate_directories || :

  if [[ ${COMP_CWORD} -eq 1 ]]; then
    if [[ -v _dsbTfTestFilesList ]]; then
      local -a testNames=()
      local _tFile
      for _tFile in "${_dsbTfTestFilesList[@]}"; do
        testNames+=("$(basename "${_tFile}")")
      done
      if [[ -n "${testNames[*]}" ]]; then
        mapfile -t COMPREPLY < <(compgen -W "${testNames[*]}" -- "${cur}")
      fi
    fi
  fi
}

_dsb_tf_register_completions_for_test_names() {
  complete -F _dsb_tf_completions_for_test_names tf-test
}

# for module repo integration test file names
# --------------------------------------------------
_dsb_tf_completions_for_integration_test_names() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  COMPREPLY=()

  _dsbTfLogDebug=0 _dsb_tf_enumerate_directories || :

  if [[ ${COMP_CWORD} -eq 1 ]]; then
    if [[ -v _dsbTfIntegrationTestFilesList ]]; then
      local -a testNames=()
      local _tFile
      for _tFile in "${_dsbTfIntegrationTestFilesList[@]}"; do
        testNames+=("$(basename "${_tFile}")")
      done
      if [[ -n "${testNames[*]}" ]]; then
        mapfile -t COMPREPLY < <(compgen -W "${testNames[*]}" -- "${cur}")
      fi
    fi
  fi
}

_dsb_tf_register_completions_for_integration_test_names() {
  complete -F _dsb_tf_completions_for_integration_test_names tf-test-integration
}

# make it easier to configure the shell
_dsb_tf_register_all_completions() {
  _dsb_tf_register_completions_for_available_envs
  _dsb_tf_register_completions_for_tf_lint
  _dsb_tf_register_completions_for_tf_help
  _dsb_tf_register_completions_for_example_names
  _dsb_tf_register_completions_for_test_names
  _dsb_tf_register_completions_for_integration_test_names
}

###################################################################################################
#
# Utility functions: Version parsing
#
###################################################################################################

# what:
#   check if a version string is a valid semver
#   supports x as wildcard in last number of version string, default is not allowed
#   supports v as first character, default is not allowed
# input:
#   $1: version string
#   $2: xInLastNumberIsWildcard (optional, default 0)
#   $3: vAsFirstCharacterAllowed (optional, default 0)
# on info:
#   nothing
# return:
#   0: valid semver
#   1: not a valid semver
_dsb_tf_semver_is_semver() {
  local inputVersion="${1}"
  local xInLastNumberIsWildcard="${2:-0}"
  local vAsFirstCharacterAllowed="${3:-0}"

  local isSemver=0

  if [ "${xInLastNumberIsWildcard}" -eq 1 ]; then
    if [ "${vAsFirstCharacterAllowed}" -eq 1 ]; then
      if [[ "${inputVersion}" =~ ^v?[0-9]+\.[0-9]+\.([0-9]+|[xX])$ ]]; then
        isSemver=1
      elif [[ "${inputVersion}" =~ ^v?[0-9]+\.([0-9]+|[xX])$ ]]; then
        isSemver=1
      elif [[ "${inputVersion}" =~ ^v?[0-9]+$ ]]; then
        isSemver=1
      fi
    else
      if [[ "${inputVersion}" =~ ^[0-9]+\.[0-9]+\.([0-9]+|[xX])$ ]]; then
        isSemver=1
      elif [[ "${inputVersion}" =~ ^[0-9]+\.([0-9]+|[xX])$ ]]; then
        isSemver=1
      elif [[ "${inputVersion}" =~ ^[0-9]+$ ]]; then
        isSemver=1
      fi
    fi
  else
    if [ "${vAsFirstCharacterAllowed}" -eq 1 ]; then
      if [[ "${inputVersion}" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        isSemver=1
      elif [[ "${inputVersion}" =~ ^v?[0-9]+\.[0-9]+$ ]]; then
        isSemver=1
      elif [[ "${inputVersion}" =~ ^v?[0-9]+$ ]]; then
        isSemver=1
      fi
    else
      if [[ "${inputVersion}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        isSemver=1
      elif [[ "${inputVersion}" =~ ^[0-9]+\.[0-9]+$ ]]; then
        isSemver=1
      elif [[ "${inputVersion}" =~ ^[0-9]+$ ]]; then
        isSemver=1
      fi
    fi
  fi

  [ "${isSemver}" -eq 1 ] && return 0 || return 1
}

# what:
#   check if a version string is a valid semver
#   allows x as wildcard in last number of version string
# input:
#   $1: version string
# on info:
#   nothing
# return:
#   0: valid semver
#   1: not a valid semver
_dsb_tf_semver_is_semver_allow_x_as_wildcard_in_last() {
  local inputVersion="${1}"

  _dsb_tf_semver_is_semver "${inputVersion}" 1 0 # $2 = xInLastNumberIsWildcard, $3 = vAsFirstCharacterAllowed
}

# what:
#   check if a version string is a valid semver
#   allows v as first character
# input:
#   $1: version string
# on info:
#   nothing
# return:
#   0: valid semver
#   1: not a valid semver
_dsb_tf_semver_is_semver_allow_v_as_first_character() {
  local inputVersion="${1}"

  _dsb_tf_semver_is_semver "${inputVersion}" 0 1 # $2 = xInLastNumberIsWildcard, $3 = vAsFirstCharacterAllowed
}

# what:
#   given a version string, return the major version part
# input:
#   $1: version string
# on info:
#   nothing
# return:
#   echos the major version part
#   returns 1 if version string is not a valid semver
_dsb_tf_semver_get_major_version() {
  local inputVersion="${1}"

  local countOfDots
  countOfDots=$(grep -o '\.' <<<"${inputVersion}" | wc -l)

  local majorVersion
  if [ "${countOfDots}" -eq 0 ]; then
    majorVersion="${inputVersion}"
  elif [ "${countOfDots}" -eq 1 ] || [ "${countOfDots}" -eq 2 ]; then
    majorVersion="${inputVersion%%.*}" # removes the longest match of .* from the end
  else
    return 1 # invalid version format
  fi

  echo "${majorVersion}"
}

# what:
#   given a version string, return the minor version part
# input:
#   $1: version string
# on info:
#   nothing
# return:
#   echos the minor version part
#   returns 1 if version string is not a valid semver
_dsb_tf_semver_get_minor_version() {
  local inputVersion="${1}"

  local countOfDots
  countOfDots=$(grep -o '\.' <<<"${inputVersion}" | wc -l)

  local minorVersion
  if [ "${countOfDots}" -eq 0 ]; then
    minorVersion=""
  elif [ "${countOfDots}" -eq 1 ]; then
    minorVersion="${inputVersion#*.}" # remove everything up to and including the first dot
  elif [ "${countOfDots}" -eq 2 ]; then
    minorVersion="${inputVersion#*.}"  # remove everything up to and including the first dot
    minorVersion="${minorVersion%%.*}" # removes the longest match of .* from the end
  else
    return 1 # invalid version format
  fi

  echo "${minorVersion}"
}

# what:
#   given a version string, return the patch version part
# input:
#   $1: version string
# on info:
#   nothing
# return:
#   echos the patch version part
#   returns 1 if version string is not a valid semver
_dsb_tf_semver_get_patch_version() {
  local inputVersion="${1}"

  local countOfDots
  countOfDots=$(grep -o '\.' <<<"${inputVersion}" | wc -l)

  local patchVersion
  if [ "${countOfDots}" -eq 0 ] || [ "${countOfDots}" -eq 1 ]; then
    patchVersion=""
  elif [ "${countOfDots}" -eq 2 ]; then
    patchVersion="${inputVersion##*.}" # remove everything up to and including the last dot
  else
    return 1 # invalid version format
  fi

  echo "${patchVersion}"
}

###################################################################################################
#
# Internal functions: checks
#
###################################################################################################

# what:
#   check if Azure CLI is available
# input:
#   none
# on info:
#   nothing
# returns:
#   exit code directly
_dsb_tf_check_az_cli() {
  if ! az --version &>/dev/null; then
    _dsb_e "Azure CLI not found."
    _dsb_e "  checked with command: az --version"
    _dsb_e "  make sure az is available in your PATH"
    _dsb_e "  for installation instructions see: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
    return 1
  fi
  return 0
}

# what:
#   check if GitHub CLI is available
# input:
#   none
# on info:
#   nothing
# returns:
#   exit code directly
_dsb_tf_check_gh_cli() {
  if ! gh --version &>/dev/null; then
    _dsb_e "GitHub CLI not found."
    _dsb_e "  checked with command: gh --version"
    _dsb_e "  make sure gh is available in your PATH"
    _dsb_e "  for installation instructions see: https://github.com/cli/cli#installation"
    return 1
  fi
  return 0
}

# what:
#   check if Terraform is available
# input:
#   none
# on info:
#   nothing
# returns:
#   exit code directly
_dsb_tf_check_terraform() {
  if ! terraform -version &>/dev/null; then
    _dsb_e "Terraform not found."
    _dsb_e "  checked with command: terraform -version"
    _dsb_e "  make sure terraform is available in your PATH"
    _dsb_e "  for installation instructions see: https://learn.hashicorp.com/tutorials/terraform/install-cli"
    return 1
  fi
  return 0
}

# what:
#   check if jq is available
# input:
#   none
# on info:
#   nothing
# returns:
#   exit code directly
_dsb_tf_check_jq() {
  if ! jq --version &>/dev/null; then
    _dsb_e "jq not found."
    _dsb_e "  checked with command: jq --version"
    _dsb_e "  make sure jq is available in your PATH"
    _dsb_e "  for installation instructions see: https://stedolan.github.io/jq/download/"
    return 1
  fi
  return 0
}

# what:
#   check if yq is available
# input:
#   none
# on info:
#   nothing
# returns:
#   exit code directly
_dsb_tf_check_yq() {
  if ! yq --version &>/dev/null; then
    _dsb_e "yq not found."
    _dsb_e "  checked with command: yq --version"
    _dsb_e "  make sure yq is available in your PATH"
    _dsb_e "  for installation instructions see: https://mikefarah.gitbook.io/yq#install"
    return 1
  fi
  return 0
}

# what:
#   check if Go is available
# input:
#   none
# on info:
#   nothing
# returns:
#   exit code directly
_dsb_tf_check_golang() {
  if ! go version &>/dev/null; then
    _dsb_e "Go not found."
    _dsb_e "  checked with command: go version"
    _dsb_e "  make sure go is available in your PATH"
    _dsb_e "  for installation instructions see: https://go.dev/doc/install"
    return 1
  fi
  return 0
}

# what:
#   check if hcledit is available
# input:
#   none
# on info:
#   nothing
# returns:
#   exit code directly
_dsb_tf_check_hcledit() {
  if ! hcledit version &>/dev/null; then
    _dsb_e "hcledit not found."
    _dsb_e "  checked with command: hcledit version"
    _dsb_e "  make sure hcledit is available in your PATH"
    _dsb_e "  for installation instructions see: https://github.com/minamijoyo/hcledit?tab=readme-ov-file#install"
    _dsb_e "  or install it with: 'go install github.com/minamijoyo/hcledit@latest; export PATH=\$PATH:\$(go env GOPATH)/bin; echo 'export PATH=\$PATH:\$(go env GOPATH)/bin' >> ~/.bashrc'"
    return 1
  fi
  return 0
}

# what:
#   check if terraform-docs is available
# input:
#   none
# on info:
#   nothing
# returns:
#   exit code directly
_dsb_tf_check_terraform_docs() {
  if ! terraform-docs --version &>/dev/null; then
    _dsb_e "terraform-docs not found."
    _dsb_e "  checked with command: terraform-docs --version"
    _dsb_e "  make sure terraform-docs is available in your PATH"
    _dsb_e "  for installation instructions see: https://terraform-docs.io/user-guide/installation/"
    _dsb_e "  or install it with: 'go install github.com/terraform-docs/terraform-docs@latest; export PATH=\$PATH:\$(go env GOPATH)/bin; echo 'export PATH=\$PATH:\$(go env GOPATH)/bin' >> ~/.bashrc'"
    return 1
  fi
  return 0
}

# what:
#   check if terraform-config-inspect is available
# input:
#   none
# on info:
#   nothing
# returns:
#   exit code directly
_dsb_tf_check_terraform_config_inspect() {
  if ! terraform-config-inspect &>/dev/null; then
    _dsb_e "terraform-config-inspect not found."
    _dsb_e "  checked with command: terraform-config-inspect"
    _dsb_e "  make sure terraform-config-inspect is available in your PATH"
    _dsb_e "  for installation instructions see: https://github.com/hashicorp/terraform-config-inspect"
    _dsb_e "  or install it with: 'go install github.com/hashicorp/terraform-config-inspect@latest; export PATH=\$PATH:\$(go env GOPATH)/bin; echo 'export PATH=\$PATH:\$(go env GOPATH)/bin' >> ~/.bashrc'"
    return 1
  fi
  return 0
}

# what:
#   check if realpath is available
# input:
#   none
# on info:
#   nothing
# returns:
#   exit code directly
_dsb_tf_check_realpath() {
  if ! $_dsbTfRealpathCmd . &>/dev/null; then
    _dsb_e "realpath not found."
    _dsb_e "  checked with command: '$_dsbTfRealpathCmd .'"
    _dsb_e "  make sure realpath is available in your PATH"
    _dsb_e "  install it with one of:"
    _dsb_e "    - Ubuntu: 'sudo apt-get install coreutils'"
    _dsb_e "    - OS X  : 'brew install coreutils'"
    return 1
  fi
  return 0
}

# what:
#   check if curl is available
# input:
#   none
# on info:
#   nothing
# returns:
#   exit code directly
_dsb_tf_check_curl() {
  if ! curl --version &>/dev/null; then
    _dsb_e "curl not found."
    _dsb_e "  checked with command: curl --version"
    _dsb_e "  make sure curl is available in your PATH"
    _dsb_e "  for installation instructions see: https://curl.se/download.html"
    return 1
  fi
  return 0
}

# what:
#   check if all required tools are available
# input:
#   none
# on info:
#  a summary of the check results is printed
# returns:
#   exit code directly
_dsb_tf_check_tools() {

  # Required tools -- failure here means tf-check-tools returns non-zero
  _dsb_i "Checking required tools ..."

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

  _dsb_i "Checking realpath ..."
  _dsb_tf_check_realpath
  local realpathStatus=$?

  _dsb_i "Checking curl ..."
  _dsb_tf_check_curl
  local curlStatus=$?

  # On-demand tools -- only needed by specific commands (bump, provider upgrades)
  # Checked here for visibility, but missing ones don't fail the overall check
  _dsb_i ""
  _dsb_i "Checking on-demand tools ..."

  _dsb_i "Checking yq ..."
  _dsb_tf_check_yq
  local yqStatus=$?

  _dsb_i "Checking hcledit ..."
  _dsb_tf_check_hcledit
  local hcleditStatus=$?

  _dsb_i "Checking terraform-config-inspect ..."
  _dsb_tf_check_terraform_config_inspect
  local terraformConfigInspectStatus=$?

  _dsb_i "Checking Go ..."
  _dsb_tf_check_golang
  local golangStatus=$?

  _dsb_i "Checking terraform-docs ..."
  _dsb_tf_check_terraform_docs
  local terraformDocsStatus=$?

  # Only required tools affect the return code
  local returnCode=$((azCliStatus + ghCliStatus + terraformStatus + jqStatus + realpathStatus + curlStatus))

  _dsb_i ""
  _dsb_i "Tools check summary:"
  _dsb_i ""
  _dsb_i "  Required:"
  if [ ${azCliStatus} -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  Azure CLI                      : passed."
  else
    _dsb_i "  \e[31m☒\e[0m  Azure CLI                      : MISSING, see above."
  fi
  if [ ${ghCliStatus} -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  GitHub CLI                     : passed."
  else
    _dsb_i "  \e[31m☒\e[0m  GitHub CLI                     : MISSING, see above."
  fi
  if [ ${terraformStatus} -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  Terraform                      : passed."
  else
    _dsb_i "  \e[31m☒\e[0m  Terraform                      : MISSING, see above."
  fi
  if [ ${jqStatus} -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  jq                             : passed."
  else
    _dsb_i "  \e[31m☒\e[0m  jq                             : MISSING, see above."
  fi
  if [ ${realpathStatus} -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  realpath                       : passed."
  else
    _dsb_i "  \e[31m☒\e[0m  realpath                       : MISSING, see above."
  fi
  if [ ${curlStatus} -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  curl                           : passed."
  else
    _dsb_i "  \e[31m☒\e[0m  curl                           : MISSING, see above."
  fi
  _dsb_i ""
  _dsb_i "  On-demand:"
  if [ ${yqStatus} -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  yq                             : passed."
  else
    _dsb_i "  \e[33m☐\e[0m  yq                             : not found (needed by tf-bump-cicd)"
  fi
  if [ ${hcleditStatus} -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  hcledit                        : passed."
  else
    _dsb_i "  \e[33m☐\e[0m  hcledit                        : not found (needed by tf-bump-modules, tf-bump-tflint-plugins, tf-show-provider-upgrades)"
  fi
  if [ ${terraformConfigInspectStatus} -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  terraform-config-inspect       : passed."
  else
    _dsb_i "  \e[33m☐\e[0m  terraform-config-inspect       : not found (needed by tf-show-provider-upgrades)"
  fi
  if [ ${golangStatus} -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  Go                             : passed."
  else
    _dsb_i "  \e[33m☐\e[0m  Go                             : not found (needed to install hcledit, terraform-config-inspect)"
  fi
  if [ ${terraformDocsStatus} -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  terraform-docs                 : passed."
  else
    _dsb_i "  \e[33m☐\e[0m  terraform-docs                 : not found (needed by tf-docs in module repos)"
  fi

  return $returnCode
}

# what:
#   check if GitHub CLI is authenticated
# input:
#   none
# on info:
#   nothing
# returns:
#   exit code directly
#   fails if gh cli is not installed
_dsb_tf_check_gh_auth() {
  # check fails if gh cli is not installed
  if ! _dsbTfLogErrors=0 _dsb_tf_check_gh_cli; then
    return 1
  fi

  if ! gh auth status &>/dev/null; then
    _dsb_e "You are not authenticated with GitHub. Please run 'gh auth login' to authenticate."
    return 1
  fi

  return 0
}

# what:
#   enumerate directories and checks if the current directory is a valid Terraform project
#     does it contain a main directory
#     does it contain an envs directory
# input:
#   none
# on info:
#   continuous output with summary of the check results
# returns:
#   exit code directly
_dsb_tf_check_current_dir() {
  _dsb_d "checking current directory: ${PWD:-}"

  _dsb_tf_enumerate_directories

  if [ "${_dsbTfRepoType}" == "module" ]; then
    # Module repo: check for root .tf files and versions.tf
    _dsb_i "Checking root .tf files  ..."
    local rootTfStatus=0
    local -a rootTfFiles=()
    local _tfCheckFile
    for _tfCheckFile in "${_dsbTfRootDir}"/*.tf; do
      if [ -f "${_tfCheckFile}" ]; then
        rootTfFiles+=("${_tfCheckFile}")
      fi
    done
    if [ "${#rootTfFiles[@]}" -eq 0 ]; then
      rootTfStatus=1
      _dsb_e "No .tf files found in root directory: ${_dsbTfRootDir}"
      _dsb_tf_error_push "no .tf files found in root directory"
    fi

    _dsb_i "Checking versions.tf  ..."
    local versionsTfStatus=0
    if [ ! -f "${_dsbTfRootDir}/versions.tf" ]; then
      versionsTfStatus=1
      _dsb_e "versions.tf not found in root directory: ${_dsbTfRootDir}"
      _dsb_tf_error_push "versions.tf not found in root directory"
    fi

    # Registry requirements
    _dsb_i "Checking README.md  ..."
    local readmeStatus=0
    if [ ! -f "${_dsbTfRootDir}/README.md" ]; then
      readmeStatus=1
      _dsb_e "README.md not found in root directory (required for Terraform registry)"
      _dsb_tf_error_push "README.md not found in root directory"
    fi

    _dsb_i "Checking LICENSE  ..."
    local licenseStatus=0
    if [ ! -f "${_dsbTfRootDir}/LICENSE" ] && [ ! -f "${_dsbTfRootDir}/LICENSE.md" ]; then
      licenseStatus=1
      _dsb_e "LICENSE or LICENSE.md not found in root directory (required for Terraform registry)"
      _dsb_tf_error_push "LICENSE not found in root directory"
    fi

    # Recommended directories (warn only, don't affect return code)
    _dsb_i "Checking examples/  ..."
    if [ ! -d "${_dsbTfRootDir}/examples" ]; then
      _dsb_w "examples/ directory not found (recommended)"
    fi

    _dsb_i "Checking tests/  ..."
    if [ ! -d "${_dsbTfRootDir}/tests" ]; then
      _dsb_w "tests/ directory not found (recommended)"
    fi

    local returnCode=$((rootTfStatus + versionsTfStatus + readmeStatus + licenseStatus))

    _dsb_i ""
    _dsb_i "Directory check summary (module repo):"

    if [ "${rootTfStatus}" -eq 0 ]; then
      _dsb_i "  \e[32m☑\e[0m  Root .tf files check         : passed."
    else
      _dsb_i "  \e[31m☒\e[0m  Root .tf files check         : failed."
    fi

    if [ "${versionsTfStatus}" -eq 0 ]; then
      _dsb_i "  \e[32m☑\e[0m  versions.tf check            : passed."
    else
      _dsb_i "  \e[31m☒\e[0m  versions.tf check            : failed."
    fi

    if [ "${readmeStatus}" -eq 0 ]; then
      _dsb_i "  \e[32m☑\e[0m  README.md check              : passed."
    else
      _dsb_i "  \e[31m☒\e[0m  README.md check              : failed (required for registry)."
    fi

    if [ "${licenseStatus}" -eq 0 ]; then
      _dsb_i "  \e[32m☑\e[0m  LICENSE check                : passed."
    else
      _dsb_i "  \e[31m☒\e[0m  LICENSE check                : failed (required for registry)."
    fi

    if [ -d "${_dsbTfRootDir}/examples" ]; then
      _dsb_i "  \e[32m☑\e[0m  examples/ check              : present."
    else
      _dsb_i "  \e[33m⚠\e[0m  examples/ check              : not found (recommended)."
    fi

    if [ -d "${_dsbTfRootDir}/tests" ]; then
      _dsb_i "  \e[32m☑\e[0m  tests/ check                 : present."
    else
      _dsb_i "  \e[33m⚠\e[0m  tests/ check                 : not found (recommended)."
    fi

    _dsb_i ""
    if [ "${returnCode}" -eq 0 ]; then
      _dsb_i "\e[32mAll directory checks passed.\e[0m"
    else
      _dsb_e "Directory check(s) failed, the current directory does not seem to be a valid Terraform module repo."
      _dsb_e "  directory checked: ${_dsbTfRootDir:-}"
      _dsb_e "  for more information see above."
    fi

    _dsb_d "returning exit code: ${returnCode}"
    return "${returnCode}"
  fi

  # Project repo (or unknown): existing behavior
  _dsb_i "Checking main dir  ..."
  local mainDirStatus=0
  if ! _dsb_tf_look_for_main_dir; then
    mainDirStatus=1
  fi

  _dsb_i "Checking envs dir  ..."
  local envsDirStatus=0
  if ! _dsb_tf_look_for_envs_dir; then
    envsDirStatus=1
  fi

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
  _dsb_d "selectedEnv: ${selectedEnv}"

  _dsb_i ""
  if [ "${returnCode}" -eq 0 ]; then
    _dsb_i "\e[32mAll directory checks passed.\e[0m"
  else
    _dsb_e "Directory check(s) failed, the current directory does not seem to be a valid Terraform project."
    _dsb_e "  directory checked: ${_dsbTfRootDir:-}"
    _dsb_e "  for more information see above."
  fi

  _dsb_d "returning exit code: ${returnCode}"
  return "${returnCode}"
}

# what:
#   check all pre-requisites
#     tools
#     GitHub authentication
#     working directory
# input:
#   none
# on info:
#   continuous output with summary of the check results
# returns:
#   exit code directly
_dsb_tf_check_prereqs() {
  _dsb_tf_enumerate_directories

  _dsb_i_nonewline "Checking tools ..."
  local toolsStatus=0
  if ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_tools; then
    toolsStatus=1
  fi
  _dsb_i_append " done."

  _dsb_i_nonewline "Checking GitHub authentication ..."
  local ghAuthStatus=0
  if ! _dsb_tf_check_gh_auth; then
    ghAuthStatus=1
  fi
  _dsb_i_append " done."

  _dsb_i_nonewline "Checking working directory ..."
  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  local workingDirStatus=$?
  _dsb_i_append " done."

  local returnCode=$((toolsStatus + ghAuthStatus + workingDirStatus))

  _dsb_d "returnCode: ${returnCode}"
  _dsb_d "toolsStatus: ${toolsStatus}"
  _dsb_d "ghAuthStatus: ${ghAuthStatus}"
  _dsb_d "workingDirStatus: ${workingDirStatus}"

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
  if [ "${workingDirStatus}" -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  Working directory check      : passed."
  else
    _dsb_i "  \e[31m☒\e[0m  Working directory check      : failed, please run 'tf-check-dir'"
  fi

  if [ "${_dsbTfRepoType}" == "module" ]; then
    # Module repos: check Azure auth (info only, don't fail)
    _dsb_i_nonewline "Checking Azure authentication (for integration tests) ..."
    local azAuthStatus=0
    if ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_az_cli; then
      azAuthStatus=1
    elif ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_az_is_logged_in; then
      azAuthStatus=1
    fi
    _dsb_i_append " done."

    if [ ${azAuthStatus} -eq 0 ]; then
      _dsb_i "  \e[32m☑\e[0m  Azure authentication check   : passed (needed for integration tests only)."
    else
      _dsb_i "  \e[33m⚠\e[0m  Azure authentication check   : not available."
    fi
  fi

  _dsb_i ""
  if [ ${returnCode} -eq 0 ]; then
    _dsb_i "\e[32mAll pre-reqs check passed.\e[0m"
    if [ "${_dsbTfRepoType}" == "module" ]; then
      _dsb_i "  now try 'tf-status' for a full overview."
    else
      _dsb_i "  now try 'tf-select-env' to select an environment."
    fi
  else
    _dsb_e "\e[31mPre-reqs check failed, for more information see above.\e[0m"
  fi

  _dsb_d "returning exit code: ${returnCode}"
  return "${returnCode}"
}

# what:
#   check if environment exists, either supplied or the currently selected environment
# input:
#   environment name (optional)
# on info:
#   continuous output with summary of the check results
# returns:
#   exit code directly
_dsb_tf_check_env() {
  local selectedEnv="${_dsbTfSelectedEnv:-}" # allowed to be empty
  local envToCheck="${1:-${selectedEnv}}"    # input with fallback to selected environment
  local skipLockCheck="${2:-0}"              # optional, defaults to 0

  if [ -z "${envToCheck}" ]; then
    _dsb_e "No environment specified and no environment selected."
    _dsb_e "  either specify environment: tf-check-env [env]"
    _dsb_e "  or run one of the following: tf-select-env, tf-set-env [env], tf-list-envs"
    _dsb_tf_error_push "no environment specified and no environment selected"
    return 1
  fi

  _dsb_i "Environment: ${envToCheck}"

  _dsb_tf_enumerate_directories

  _dsb_i "Looking for environment ..."
  local envStatus=0
  local lockFileStatus=0
  local subscriptionHintFileStatus=0
  if ! _dsb_tf_look_for_env "${envToCheck}"; then
    envStatus=1
  else
    if [ "${skipLockCheck}" -eq 0 ]; then
      _dsb_i "Checking lock file ..."
      if ! _dsb_tf_look_for_lock_file "${envToCheck}"; then
        lockFileStatus=1
      fi
    fi

    _dsb_i "Checking subscription hint file ..."
    if ! _dsb_tf_look_for_subscription_hint_file "${envToCheck}"; then
      subscriptionHintFileStatus=1
    fi
  fi

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
    _dsb_e "\e[31mChecks failed, for more information see above.\e[0m"
  fi

  _dsb_d "returning exit code: ${returnCode}"
  return "${returnCode}"
}

###################################################################################################
#
# Internal functions: repo type gating
#
###################################################################################################

# what:
#   check that the current repo is a project repo, return 1 with clear message if not
# input:
#   none
# returns:
#   0 if repo type is "project", 1 otherwise
_dsb_tf_require_project_repo() {
  if [ "${_dsbTfRepoType:-}" != "project" ]; then
    _dsb_e "This command is only available in Terraform project repos."
    _dsb_e "  detected repo type: ${_dsbTfRepoType:-unknown}"
    _dsb_tf_error_push "command requires project repo, current repo type: ${_dsbTfRepoType:-unknown}"
    return 1
  fi
  return 0
}

_dsb_tf_require_module_repo() {
  if [ "${_dsbTfRepoType:-}" != "module" ]; then
    _dsb_e "This command is only available in Terraform module repos."
    _dsb_e "  detected repo type: ${_dsbTfRepoType:-unknown}"
    _dsb_tf_error_push "command requires module repo, current repo type: ${_dsbTfRepoType:-unknown}"
    return 1
  fi
  return 0
}

###################################################################################################
#
# Internal functions: directory enumeration
#
###################################################################################################

# what:
#   gets the relative path of a directory to the root directory of the Terraform project
# input:
#   directory path
# on info:
#   nothing
# returns:
#   echos the relative path
_dsb_tf_get_rel_dir() {
  local dirName=${1}
  ${_dsbTfRealpathCmd} --relative-to="${_dsbTfRootDir:-.}" "${dirName}"
}

# what:
#   a function that should be piped to, receives lines of data on stdin
#   looks for log line patterns known to contain paths, if found, modifies the path in the log line
#   so that it is relative to the to the root directory of the Terraform project
#   if no known log line pattern is found or the selected environment is not set, the line is echoed as is.
# input:
#   line(s) on stdin
# on info:
#   nothing
# returns:
#   echos the modified line(s)
_dsb_tf_fixup_paths_from_stdin() {
  local appendPath=${_dsbTfSelectedEnvDir:-}
  local line path modified_path relative_path modified_line

  # this loop reads each line from the input and stores it in the variable 'line'.
  #   the 'IFS=' ensures that leading/trailing whitespace is not trimmed.
  #   the '-r' option prevents backslashes from being interpreted as escape characters.
  while IFS= read -r line; do

    # if path to append is empty, echo the line as is
    if [ -z "${appendPath}" ]; then
      echo -e "${line}"
      continue
    fi

    # Pattern 1: "on <path> line <number>"
    if [[ ${line} =~ on[[:space:]]+(.+)[[:space:]]+line[[:space:]]+([0-9]+) ]]; then
      path="${BASH_REMATCH[1]}" # extract the path from the regex match

    # Pattern 2: "@ <path>"
    elif [[ ${line} =~ @[[:space:]]+(.+) ]]; then
      path="${BASH_REMATCH[1]}" # extract the path from the regex match

    # Pattern 3: "Linting in: <path>"
    elif [[ ${line} =~ Linting[[:space:]]+in:[[:space:]]+(.+) ]]; then
      path="${BASH_REMATCH[1]}" # extract the path from the regex match

    # Pattern 4: "../../<path>:<number>"
    elif [[ ${line} =~ (\.\./\.\./[^:]+):([0-9]+) ]]; then
      path="${BASH_REMATCH[1]}" # extract the path from the regex match

    # Echo the line as is
    else
      echo -e "${line}"
      continue
    fi

    modified_path="${appendPath}/${path}"                   # ex. '../../main/providers.tf' -> '/my/abs/path/to/env/../../main/providers.tf'
    relative_path=$(_dsb_tf_get_rel_dir "${modified_path}") # becomes relative to the root dir, ex. '/my/abs/path/to/env/../../main/providers.tf' -> 'main/providers.tf'
    modified_line="${line//${path}/${relative_path}}"       # modify the path in the line
    echo -e "${modified_line}"                              # echo the modified line

  done
}

# what:
#   enumerate directories with current directory as root
#     - modules
#     - main
#     - envs + subdirectories
#   if an environment is selected, stored in _dsbTfSelectedEnv, and it exists as a subdirectory of envs,
#   the corresponding directory is stored in _dsbTfSelectedEnvDir
# input:
#   none
# on info:
#   nothing
# returns:
#   exit code directly
#   populates several global variables:
#     - _dsbTfRootDir
#       - _dsbTfFilesList
#       - _dsbTfLintConfigFilesList
#     - _dsbTfModulesDir
#       - _dsbTfModulesDirList
#     - _dsbTfMainDir
#     - _dsbTfEnvsDir
#       - _dsbTfEnvsDirList
#       - _dsbTfAvailableEnvs
#       - _dsbTfSelectedEnvDir
#     - _dsbTfTflintWrapperDir
#     - _dsbTfTflintWrapperPath
_dsb_tf_enumerate_directories() {
  _dsbTfRootDir="$(pwd)"

  _dsbTfFilesList=()
  _dsbTfLintConfigFilesList=()
  if [ -d "${_dsbTfRootDir}" ]; then
    # populate _dsbTfFilesList with .tf files found recursively under _dsbTfRootDir
    # find args explained:
    #    '-type d': Specifies that the search should look for directories.
    #    '-name ".*"': Matches directories with names starting with a dot (hidden directories).
    #    '-prune': Prevents find from descending into the matched directories.
    #   '-o': Logical OR operator, used to combine multiple conditions.
    #    '-type f': Specifies that the search should look for files.
    #    '-name "*.tf"'': Matches files with a .tf extension (Terraform files).
    #    '-print': Prints the matched files to the standard output.
    mapfile -t _dsbTfFilesList < <(find "${_dsbTfRootDir}" -type d -name ".*" -prune -o -type f -name "*.tf" -print)

    # find all .tflint.hcl files in the project recursively, excluding dot directories
    mapfile -t _dsbTfLintConfigFilesList < <(find "${_dsbTfRootDir}" -type d -name ".*" -prune -o -type f -name ".tflint.hcl" -print)
  fi

  _dsbTfModulesDir="${_dsbTfRootDir}/modules"
  _dsbTfMainDir="${_dsbTfRootDir}/main"
  _dsbTfEnvsDir="${_dsbTfRootDir}/envs"

  _dsbTfTflintWrapperDir="${_dsbTfRootDir}/.tflint"
  _dsbTfTflintWrapperPath="${_dsbTfTflintWrapperDir}/tflint.sh"

  _dsbTfModulesDirList=()
  if [ -d "${_dsbTfModulesDir}" ]; then
    _dsb_d "Enumerating modules ..."

    local dir
    for dir in "${_dsbTfRootDir}"/modules/*/; do
      if [ -d "${dir}" ]; then # is a directory
        _dsb_d "Found module: $(basename "${dir}")"
        _dsbTfModulesDirList[$(basename "${dir}")]="${dir}"
      fi
    done
  fi

  _dsbTfEnvsDirList=()
  _dsbTfAvailableEnvs=()

  if [ -d "${_dsbTfEnvsDir}" ]; then
    _dsb_d "Enumerating environments ..."

    local item
    for item in "${_dsbTfRootDir}"/envs/*/; do
      if [ -d "${item}" ]; then # is a directory
        # this exclude directories starting with _
        if [[ "$(basename "${item}")" =~ ^_ ]]; then
          continue
        fi
        _dsb_d "Found environment: $(basename "${item}")"
        _dsbTfEnvsDirList[$(basename "${item}")]="${item}"
        _dsbTfAvailableEnvs+=("$(basename "${item}")")
      fi
    done

    _dsb_d "number of environments found: ${#_dsbTfAvailableEnvs[@]}"

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
        _dsb_d "found selectedEnv: ${selectedEnv}"
        _dsbTfSelectedEnvDir="${_dsbTfEnvsDirList["${selectedEnv}"]}"
      else
        _dsb_d "clearing '_dsbTfSelectedEnv' and '_dsbTfSelectedEnvDir'"
        local logInfoOrig="${_dsbTfLogInfo:-1}"
        _dsbTfLogInfo=0
        _dsb_tf_clear_env
        _dsbTfLogInfo="${logInfoOrig}"
      fi
    fi
  fi

  # Repo type detection
  _dsbTfRepoType=""
  _dsbTfExamplesDir=""
  _dsbTfExamplesDirList=()
  _dsbTfTestsDir=""
  _dsbTfTestFilesList=()
  _dsbTfUnitTestFilesList=()
  _dsbTfIntegrationTestFilesList=()

  if [ -d "${_dsbTfMainDir}" ] && [ -d "${_dsbTfEnvsDir}" ]; then
    _dsbTfRepoType="project"
    _dsb_d "detected repo type: project"
  else
    # Check for .tf files at root level
    local -a rootTfFiles=()
    local _tfFile
    for _tfFile in "${_dsbTfRootDir}"/*.tf; do
      if [ -f "${_tfFile}" ]; then
        rootTfFiles+=("${_tfFile}")
      fi
    done

    if [ "${#rootTfFiles[@]}" -gt 0 ] && [ ! -d "${_dsbTfMainDir}" ] && [ ! -d "${_dsbTfEnvsDir}" ]; then
      _dsbTfRepoType="module"
      _dsb_d "detected repo type: module"

      # Enumerate module-specific directories
      _dsbTfExamplesDir="${_dsbTfRootDir}/examples"
      _dsbTfTestsDir="${_dsbTfRootDir}/tests"

      # Enumerate example directories
      if [ -d "${_dsbTfExamplesDir}" ]; then
        local _exDir
        for _exDir in "${_dsbTfExamplesDir}"/*/; do
          if [ -d "${_exDir}" ]; then
            # Strip trailing slash for consistent path handling
            _exDir="${_exDir%/}"
            _dsb_d "Found example: $(basename "${_exDir}")"
            _dsbTfExamplesDirList[$(basename "${_exDir}")]="${_exDir}"
          fi
        done
      fi

      # Enumerate test files
      if [ -d "${_dsbTfTestsDir}" ]; then
        local _testFile
        for _testFile in "${_dsbTfTestsDir}"/*.tftest.hcl; do
          if [ -f "${_testFile}" ]; then
            _dsbTfTestFilesList+=("${_testFile}")
            local _testBasename
            _testBasename="$(basename "${_testFile}")"
            if [[ "${_testBasename}" == unit-*.tftest.hcl ]]; then
              _dsbTfUnitTestFilesList+=("${_testFile}")
            elif [[ "${_testBasename}" == integration-*.tftest.hcl ]]; then
              _dsbTfIntegrationTestFilesList+=("${_testFile}")
            fi
          fi
        done
      fi
    else
      _dsb_d "detected repo type: unknown"
    fi
  fi

  return 0
}

# what:
#   get a list of available project modules in a graceful way, without causing unbound variable errors
# input:
#   none
# on info:
#   nothing
# returns:
#   echos a list of available project modules
_dsb_tf_get_module_names() {
  local -a moduleNames=()

  if declare -p _dsbTfModulesDirList &>/dev/null; then
    local key
    for key in "${!_dsbTfModulesDirList[@]}"; do
      moduleNames+=("${key}")
    done

    local elemCount=${#moduleNames[@]}

    # print only when there are elements, otherwise calling function will receive array with 1 empty element
    if [ "${elemCount}" -gt 0 ]; then
      printf "%s\n" "${moduleNames[@]}"
    fi
  fi
}

# a reusable way to get a comma separated list of available project modules
# what:
#   get a comma separated list of available project modules as a string
# input:
#   none
# on info:
#   nothing
# returns:
#   echos a comma separated list of available project modules
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

# what:
#   get a list of available project module directory paths in a graceful way, without causing unbound variable errors
# input:
#   none
# on info:
#   nothing
# returns:
#   echos a list of available project module directory paths
_dsb_tf_get_module_dirs() {
  local -a moduleDirs=()

  if declare -p _dsbTfModulesDirList &>/dev/null; then
    local value
    for value in "${_dsbTfModulesDirList[@]}"; do
      moduleDirs+=("${value}")
    done

    local elemCount=${#moduleDirs[@]}

    # print only when there are elements, otherwise calling function will receive array with 1 empty element
    if [ "${elemCount}" -gt 0 ]; then
      printf "%s\n" "${moduleDirs[@]}"
    fi
  fi
}

# what:
#   get a list of available environments in a graceful way, without causing unbound variable error
#   retrieved from global variable _dsbTfAvailableEnvs
# input:
#   none
# on info:
#   nothing
# returns:
#   echos a list of environment names
_dsb_tf_get_env_names() {
  local -a envNames=()

  if declare -p _dsbTfEnvsDirList &>/dev/null; then
    local key
    for key in "${!_dsbTfEnvsDirList[@]}"; do
      envNames+=("${key}")
    done

    local elemCount=${#envNames[@]}

    # print only when there are elements, otherwise calling function will receive array with 1 empty element
    if [ "${elemCount}" -gt 0 ]; then
      printf "%s\n" "${envNames[@]}"
    fi
  fi
}

# a reusable way to get a comma separated list of available environments
# what:
#   get a comma separated list of available environments as a string
# input:
#   none
# on info:
#   nothing
# returns:
#   echos a comma separated list of environment names
_dsb_tf_get_env_names_commaseparated() {
  local -a availableEnvs
  mapfile -t availableEnvs < <(_dsb_tf_get_env_names)
  local availableEnvsCommaSeparated # declare and assign separately to avoid shellcheck warning
  availableEnvsCommaSeparated=$(
    IFS=,
    echo "${availableEnvs[*]}"
  )
  availableEnvsCommaSeparated=${availableEnvsCommaSeparated//,/, }
  echo "${availableEnvsCommaSeparated}"
}

# what:
#   get a list of available environment directory paths in a graceful way, without causing unbound variable errors
# input:
#   none
# on info:
#   nothing
# returns:
#   echos a list of available environment directory paths
_dsb_tf_get_env_dirs() {
  local -a envDirs=()

  if declare -p _dsbTfEnvsDirList &>/dev/null; then
    local value
    for value in "${_dsbTfEnvsDirList[@]}"; do
      envDirs+=("${value}")
    done

    local elemCount=${#envDirs[@]}

    # print only when there are elements, otherwise calling function will receive array with 1 empty element
    if [ "${elemCount}" -gt 0 ]; then
      printf "%s\n" "${envDirs[@]}"
    fi
  fi
}

# what:
#   checks if the path stored in _dsbTfEnvsDir actually exists as a directory
# input:
#   none
# on info:
#   nothing
# returns:
#   exit code directly
_dsb_tf_look_for_main_dir() {
  if [ ! -d "${_dsbTfMainDir}" ]; then
    _dsb_e "Directory 'main' not found in current directory: ${_dsbTfRootDir}"
    return 1
  fi
  return 0
}

# what:
#   checks if the path stored in _dsbTfEnvsDir actually exists as a directory
# input:
#   none
# on info:
#   nothing
# returns:
#   exit code directly
_dsb_tf_look_for_envs_dir() {
  if [ ! -d "${_dsbTfEnvsDir}" ]; then
    _dsb_e "Directory 'envs' not found in current directory: ${_dsbTfRootDir}"
    return 1
  fi
  return 0
}

# what:
#   checks if the supplied environment name exists in the list of available environments
# input:
#   $1: environment name
# on info:
#   nothing
# returns:
#   exit code directly
_dsb_tf_look_for_env() {
  local suppliedEnv="${1:-}"

  if [ -z "${suppliedEnv}" ]; then
    _dsb_internal_error "Internal error: no environment supplied."
    return 1
  fi

  if ! declare -p _dsbTfEnvsDir &>/dev/null; then
    _dsb_internal_error "Internal error: expected to find environments directory." \
      "  expected in: _dsbTfEnvsDir"
    return 1
  fi

  local envsDir="${_dsbTfEnvsDir:-}"

  local -a availableEnvs
  mapfile -t availableEnvs < <(_dsb_tf_get_env_names)
  local envCount=${#availableEnvs[@]}

  _dsb_d "available envs count in availableEnvs: ${envCount}"
  _dsb_d "available envs: ${availableEnvs[*]}"

  local env
  local envFound=0
  for env in "${availableEnvs[@]}"; do
    if [ "${env}" == "${suppliedEnv}" ]; then
      envFound=1
      break
    fi
  done

  if [ "${envFound}" -eq 1 ]; then
    _dsb_d "found suppliedEnv: ${suppliedEnv}"
    return 0
  else
    _dsb_e "Environment not found."
    _dsb_e "  environment: ${suppliedEnv}"
    _dsb_e "  look in: ${envsDir}"
    _dsb_e "  for available environments run 'tf-list-envs'"
    return 1
  fi
}

# what:
#   look for a given file type, either in the supplied or the selected environment
#   if an environment is supplied, a check is performed to see if it is an available environment
# input:
#   $1: environment name
#   $2: file type (lock or subscriptionHint)
#   $3: name of global variable to store the path in
# on info:
#   nothing
# returns:
#   exit code directly
#   sets the global variable named by arg 3 to the path of the file if it is found
_dsb_tf_look_for_environment_file() {
  local suppliedEnv="${1:-}"
  local suppliedFileType="${2:-}"
  local suppliedGlobalToSavePathTo="${3:-}"
  local selectedEnv selectedEnvDir lookForFilename

  _dsb_d "called with:"
  _dsb_d "  suppliedEnv: ${suppliedEnv}"
  _dsb_d "  suppliedFileType: ${suppliedFileType}"
  _dsb_d "  suppliedGlobalToSavePathTo: ${suppliedGlobalToSavePathTo}"

  case "${suppliedFileType}" in
  "lock")
    lookForFilename=".terraform.lock.hcl"
    ;;
  "subscriptionHint")
    lookForFilename=".az-subscription"
    ;;
  *)
    _dsb_internal_error "Internal error: expected suppliedFileType to be one of 'lock', 'subscriptionHint'." \
      "  suppliedFileType: ${suppliedFileType}"
    return 1
    ;;
  esac

  if [ -z "${suppliedGlobalToSavePathTo}" ]; then
    _dsb_internal_error "Internal error: expected suppliedGlobalToSavePathTo to be set." \
      "  suppliedGlobalToSavePathTo: '${suppliedGlobalToSavePathTo}'"
    return 1
  fi

  # make sure the global variable supplied in suppliedGlobalToSavePathTo is declared
  if ! declare -p "${suppliedGlobalToSavePathTo}" &>/dev/null; then
    _dsb_internal_error "Internal error: the supplied global variable is not declared." \
      "  expected in suppliedGlobalToSavePathTo: ${suppliedGlobalToSavePathTo}"
    return 1
  fi

  # this function is used in two forms:
  #   1. with a supplied environment name
  #   2. with the globally selected environment name
  if [ -n "${suppliedEnv}" ]; then # env was supplied

    _dsb_d "env was supplied: ${suppliedEnv}"

    local envFoundStatus=0
    if ! _dsb_tf_look_for_env "${suppliedEnv}"; then
      envFoundStatus=1
    fi

    _dsb_d "envFoundStatus: ${envFoundStatus}"

    if [ "${envFoundStatus}" -eq 0 ]; then
      _dsb_d "found suppliedEnv: ${suppliedEnv}"

      if ! declare -p _dsbTfEnvsDirList &>/dev/null; then
        _dsb_internal_error "Internal error: expected to find environments directory list." \
          "  expected in: _dsbTfEnvsDirList"
        return 1
      fi

      if [ -z "${_dsbTfEnvsDirList["${suppliedEnv}"]}" ]; then
        _dsb_internal_error "Internal error: expected to find selected environment directory." \
          "  expected in: _dsbTfEnvsDirList"
        return 1
      fi

      selectedEnvDir="${_dsbTfEnvsDirList["${suppliedEnv}"]}"
      selectedEnv="${suppliedEnv}"
    else
      return 1
    fi
  else # env was not supplied
    selectedEnv="${_dsbTfSelectedEnv:-}"

    _dsb_d "using selectedEnv: ${selectedEnv}"

    # we allow the check to pass if no environment is selected
    if [ -z "${selectedEnv}" ]; then
      _dsb_d "allow check to pass, no environment was selected"
      return 0
    fi

    # expect _dsbTfSelectedEnvDir to be set if an environment is selected
    if [ -z "${_dsbTfSelectedEnvDir:-}" ]; then
      _dsb_internal_error "Internal error: environment set in '_dsbTfSelectedEnv', but '_dsbTfSelectedEnvDir' was not set." \
        "  selected environment: ${selectedEnv}"
      return 1
    fi

    selectedEnvDir="${_dsbTfSelectedEnvDir:-}"
  fi

  _dsb_d "suppliedEnv: ${suppliedEnv}"
  _dsb_d "selectedEnv: ${selectedEnv}"
  _dsb_d "selectedEnvDir: ${selectedEnvDir}"

  # expect _dsbTfSelectedEnvDir to be a directory
  if [ ! -d "${selectedEnvDir}" ]; then
    _dsb_internal_error "Internal error: environment set in '_dsbTfSelectedEnv', but directory not found." \
      "  Selected environment: ${selectedEnv}" \
      "  Expected directory: ${selectedEnvDir}"
    return 1
  fi

  # require that a file exists in the environment directory to be considered a valid environment
  if [ ! -f "${selectedEnvDir}${lookForFilename}" ]; then
    _dsb_e "File not found in selected environment. A '${suppliedFileType}' file is required for an environment to be considered valid."
    _dsb_e "  selected environment: ${selectedEnv}"
    _dsb_e "  expected ${suppliedFileType} file: ${selectedEnvDir}${lookForFilename}"
    return 1
  fi

  declare -g "${suppliedGlobalToSavePathTo}=${selectedEnvDir}${lookForFilename}"
  _dsb_d "global variable ${suppliedGlobalToSavePathTo} has been set to ${selectedEnvDir}${lookForFilename}"
  return 0
}

# look for a lock file, either in the supplied or the selected environment
# what:
#   look for a lock file in the supplied or selected environment
# input:
#   $1: environment name (optional)
# on info:
#   nothing
# returns:
#   exit code directly
#   sets the global variable _dsbTfSelectedEnvLockFile to the path of the lock file if it is found
_dsb_tf_look_for_lock_file() {
  local suppliedEnv="${1:-}"

  # clear global variable
  _dsbTfSelectedEnvLockFile=""

  _dsb_d "suppliedEnv: ${suppliedEnv}"

  if _dsb_tf_look_for_environment_file "${suppliedEnv}" 'lock' '_dsbTfSelectedEnvLockFile'; then
    _dsb_d "_dsbTfSelectedEnvLockFile: ${_dsbTfSelectedEnvLockFile:-}"
    return 0
  else
    _dsb_d "lock file not found"
    return 1
  fi
}

# look for a subscription hint file, either in the supplied or the selected environment
# what:
#   look for a subscription hint file in the supplied or selected environment
# input:
#   $1: environment name (optional)
# on info:
#   nothing
# returns:
#   exit code directly
#   sets the global variable _dsbTfSelectedEnvSubscriptionHintFile to the path of the subscription hint file if it is found
#   sets the global variable _dsbTfSelectedEnvSubscriptionHintContent to the content of the subscription hint file if it is found
_dsb_tf_look_for_subscription_hint_file() {
  local suppliedEnv="${1:-}"

  # clear global variables
  _dsbTfSelectedEnvSubscriptionHintFile=""
  _dsbTfSelectedEnvSubscriptionHintContent=""

  _dsb_d "suppliedEnv: ${suppliedEnv}"

  _dsb_tf_look_for_environment_file "${suppliedEnv}" 'subscriptionHint' '_dsbTfSelectedEnvSubscriptionHintFile'

  _dsb_d "_dsbTfSelectedEnvSubscriptionHintFile: ${_dsbTfSelectedEnvSubscriptionHintFile:-}"

  if [ -f "${_dsbTfSelectedEnvSubscriptionHintFile}" ]; then
    _dsbTfSelectedEnvSubscriptionHintContent=$(cat "${_dsbTfSelectedEnvSubscriptionHintFile}")
  else
    _dsb_d "returning 1, subscription hint file not found"
    return 1
  fi

  _dsb_d "returning 0, subscription hint file found"
  return 0
}

# what:
#   returns all the GitHub workflow files in the .github/workflows directory
# input:
#   none
# on info:
#   nothing
# returns:
#   array of GitHub workflow files
_dsb_tf_get_github_workflow_files() {
  find "${_dsbTfRootDir}/.github/workflows" -name "*.yml" -type f 2>/dev/null || : # allow find to fail in case the directory does not exist
}

###################################################################################################
#
# Internal functions: environment
#
###################################################################################################

# what:
#   clear the selected environment and its corresponding directory
# input:
#   none
# on info:
#   nothing
# returns:
#   nothing
_dsb_tf_clear_env() {
  _dsb_d "clearing _dsbTfSelectedEnv and _dsbTfSelectedEnvDir"
  _dsbTfSelectedEnv=""
  _dsbTfSelectedEnvDir=""
  _dsb_i "Environment cleared."
}

# what:
#   list to the names of the available environments
#   directories under the current directory is enumerated
#   it is checked if current directory is a valid Terraform project
# input:
#   none
# on info:
#   lists out the available environments
#   or when none are found, it informs the user
# returns:
#   exit code directly
_dsb_tf_list_envs() {
  local returnCode=0
  # enumerate directories with current directory as root and
  # check if the current root directory is a valid Terraform project
  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  local dirCheckStatus=$?
  if [ "${dirCheckStatus}" -ne 0 ]; then
    _dsbTfLogErrors=1 _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
    return 1 # caller reads returnCode
  fi

  if ! declare -p _dsbTfEnvsDir &>/dev/null; then
    _dsb_internal_error "Internal error: expected to find environments directory." \
      "  expected in: _dsbTfEnvsDir"
    return 1
  fi

  local -a availableEnvs
  mapfile -t availableEnvs < <(_dsb_tf_get_env_names)
  local envCount=${#availableEnvs[@]}

  _dsb_d "available envs count in availableEnvs: ${envCount}"
  _dsb_d "available envs: ${availableEnvs[*]}"

  local envsDir="${_dsbTfEnvsDir}"
  local selectedEnv="${_dsbTfSelectedEnv:-}"

  if [ "${envCount}" -eq 0 ]; then
    _dsb_w "No environments found in: ${envsDir}"
    _dsb_i "  this probably means the directory is empty."
    _dsb_i "  either create an environment or run the command from a different root directory."
    returnCode=1
  else
    local envIdx=1
    _dsb_i "Available environments:"
    local envName
    for envName in "${availableEnvs[@]}"; do
      if [ "${envName}" == "${selectedEnv}" ]; then
        _dsb_i "  -> ${envIdx}) ${envName}"
      else
        _dsb_i "     ${envIdx}) ${envName}"
      fi
      ((envIdx++))
    done

    returnCode=0
    if [ -n "${selectedEnv}" ]; then
      _dsb_i ""
      _dsb_i " -> indicates the currently selected"
    fi
  fi

  _dsb_d "done"
  return "${returnCode}"
}

# what:
#   given an environment name, this function:
#     validates the environment directory
#       - checks if the directory exists
#       - looks for subscription hint file
#       - looks for terraform lock file
#     updates the global variables to indicate that an environment has been selected
#     if subscription hint file is found, it attempts to set the Azure subscription
# input:
#   $1: environment name
# on info:
#   selected environment and if Azure subscription is successfully set, subscription ID and name are printed
# returns:
#   exit code directly
#   several global variables are updated:
#     - _dsbTfSelectedEnv
#     - _dsbTfSelectedEnvDir
#     - _dsbTfSubscriptionId   (implicitly set by _dsb_tf_az_set_sub)
#     - _dsbTfSubscriptionName (implicitly set by _dsb_tf_az_set_sub)
_dsb_tf_set_env() {
  local envToSet="${1:-}"
  local skipLockCheck="${2:-0}" # optional, defaults to 0

  _dsb_d "envToSet: ${envToSet}"
  _dsb_d "skipLockCheck: ${skipLockCheck}"

  if [ -z "${envToSet}" ]; then
    _dsb_e "No environment specified."
    _dsb_e "  usage: tf-set-env <env>"
    return 1 # caller reads returnCode
  fi

  # check if the current root directory is a valid Terraform project
  # _dsb_tf_check_current_dir calls _dsb_tf_enumerate_directories, so we don't need to call it again in this function
  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  # shellcheck disable=SC2181 # inline var assignment requires $?
  if [ $? -ne 0 ]; then
    _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
    return 1
  fi

  if ! declare -p _dsbTfEnvsDirList &>/dev/null; then
    _dsb_internal_error "Internal error: expected to find environments directory list." \
      "  expected in: _dsbTfEnvsDirList"
    return 1
  fi

  local -a availableEnvs
  mapfile -t availableEnvs < <(_dsb_tf_get_env_names)
  local envCount=${#availableEnvs[@]}

  _dsb_d "available envs count in availableEnvs: ${envCount}"
  _dsb_d "available envs: ${availableEnvs[*]}"

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
    _dsb_e "Environment '${envToSet}' not available."
    _dsb_tf_list_envs # let the user know what environments are available
    return 1 # caller reads returnCode
  fi

  # persist in global variables
  _dsbTfSelectedEnv="${envToSet}"
  _dsbTfSelectedEnvDir="${_dsbTfEnvsDirList["${_dsbTfSelectedEnv}"]}"

  _dsb_i "Selected environment: ${_dsbTfSelectedEnv}"

  local subscriptionHintFileStatus=0
  if ! _dsbTfLogErrors=0 _dsb_tf_look_for_subscription_hint_file; then
    subscriptionHintFileStatus=1
  fi

  local azSubStatus=0
  if [ "${subscriptionHintFileStatus}" -ne 0 ]; then
    _dsb_e "Subscription hint file check failed, please run 'tf-check-env ${_dsbTfSelectedEnv}'"
  else
    # hint file exists, let's try to set the subscription
    _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_az_set_sub "${skipLockCheck}"
    local azSubStatus=$?

    if [ "${azSubStatus}" -ne 0 ]; then
      _dsb_e "Failed to configure Azure subscription using subscription hint '${_dsbTfSelectedEnvSubscriptionHintContent}', please run 'az-set-sub'"
    else
      _dsb_i "  current upn       : ${_dsbTfAzureUpn:-}"
      _dsb_i "  subscription ID   : ${_dsbTfSubscriptionId:-}"
      _dsb_i "  subscription Name : ${_dsbTfSubscriptionName:-}"
    fi
  fi

  local lockFileStatus=0
  if [ "${skipLockCheck}" -eq 0 ]; then
    if ! _dsbTfLogErrors=0 _dsb_tf_look_for_lock_file; then
      lockFileStatus=1
      _dsb_e "Lock file check failed, please run 'tf-check-env ${_dsbTfSelectedEnv}'"
    fi
  fi

  local returnCode=$((lockFileStatus + subscriptionHintFileStatus + azSubStatus))

  _dsb_d "done"
  return "${returnCode}"
}

# what:
#   prompt the user to select an environment from the list of available environments
#   set the selected environment and its corresponding directory
# input:
#   none
# on info:
#   available environment names (implicitly by _dsb_tf_list_envs)
#   selected environment name and possibly azure subscription details (implicitly by _dsb_tf_set_env)
# returns:
#   exit code directly
_dsb_tf_select_env() {
  local returnCode=0
  _dsbTfLogInfo=1 _dsbTfLogErrors=1 _dsb_tf_list_envs
  local listEnvsStatus=$?

  _dsb_d "listEnvsStatus: ${listEnvsStatus}"

  if [ "${listEnvsStatus}" -ne 0 ]; then
    _dsb_e "Failed to list environments, please run 'tf-list-envs'"
    return 1
  fi

  local -a availableEnvs
  mapfile -t availableEnvs < <(_dsb_tf_get_env_names)
  local envCount=${#availableEnvs[@]}

  _dsb_d "availableEnvs: ${availableEnvs[*]}"

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
        _dsb_d "idx = ${idx} is valid"
        break
      fi
    done
  done

  _dsb_i ""
  _dsb_tf_set_env "${availableEnvs[$((userInput - 1))]}"

  _dsb_d "done"
  return "${returnCode}"
}

###################################################################################################
#
# Internal functions: azure CLI
#
###################################################################################################

# what:
#   check if the Azure CLI is installed
# input:
#   none
# on info:
#   nothing
# returns:
#   exit code directly
_dsb_tf_az_is_logged_in() {
  local showOutput
  showOutput=$(az account show 2>&1) || return 1
  # Check that the output is valid JSON with an id field (not an error message)
  if ! echo "${showOutput}" | jq -e '.id' &>/dev/null; then
    return 1
  fi
  return 0
}

# what:
#   check if the user is logged in with Azure CLI
#   if logged in, populate global variables with account details
#   if not logged in, clear the global variables
#   does not fail if az cli is not installed
# input:
#   none
# on info:
#   account subscription details are printed
# returns:
#   exit code directly
#   several global variables are updated:
#     - _dsbTfAzureUpn
#     - _dsbTfSubscriptionId
#     - _dsbTfSubscriptionName
_dsb_tf_az_enumerate_account() {

  # if az cli is not installed, do not fail
  if ! _dsb_tf_check_az_cli; then
    _dsb_d "Azure CLI not installed, skipping enumeration."
    return 0
  fi

  if _dsb_tf_az_is_logged_in; then
    local showOutput azUpn subId subName tenantDisplayName
    showOutput=$(az account show 2>&1)
    _dsb_d "showOutput: ${showOutput}"

    azUpn=$(echo "${showOutput}" | jq -r '.user.name')
    subId=$(echo "${showOutput}" | jq -r '.id')
    subName=$(echo "${showOutput}" | jq -r '.name')
    tenantDisplayName=$(echo "${showOutput}" | jq -r '.tenantDisplayName')

    _dsb_d "azUpn: ${azUpn}"
    _dsb_d "subId: ${subId}"

    _dsb_i "Logged in with Azure CLI: '${azUpn}' in tenant '${tenantDisplayName}'"
    _dsb_i "  Subscription ID   : ${subId}"
    _dsb_i "  Subscription Name : ${subName}"

    _dsbTfAzureUpn="${azUpn}"
    _dsbTfSubscriptionId="${subId}"
    _dsbTfSubscriptionName="${subName}"
  else
    _dsb_i "Not logged in with Azure CLI."
    _dsbTfAzureUpn=""
    _dsbTfSubscriptionId=""
    _dsbTfSubscriptionName=""
  fi

  return 0
}

# what:
#   enumerate azure details and print them (implicitly calls _dsb_tf_az_enumerate_account)
# input:
#   none
# on info:
#   account subscription details are printed (implicitly by _dsb_tf_az_enumerate_account)
# returns:
#   exit code directly
_dsb_tf_az_whoami() {
  local returnCode=0
  returnCode=0
  if ! _dsb_tf_az_enumerate_account; then
    returnCode=1
  fi
  _dsb_d "done"
  return "${returnCode}"
}

# what:
#   if az cli is installed, log out the user
#   if az cli is not installed, do nothing
# input:
#   none
# on info:
#   status of operation is printed
# returns:
#   exit code directly
_dsb_tf_az_logout() {
  local returnCode=0
  local azCliStatus=0
  if ! _dsb_tf_check_az_cli; then
    azCliStatus=1
  fi

  if [ "${azCliStatus}" -ne 0 ]; then
    _dsb_i "  💡 you can also check other prerequisites by running 'tf-check-prereqs'"
    returnCode=1
    _dsb_d "done"
  return "${returnCode}"
  fi

  local clearOutput
  if ! clearOutput=$(az account clear 2>&1); then
    _dsb_e "Failed to clear subscriptions from local cache."
    _dsb_e "  please run 'az account clear --debug' manually"
    returnCode=1
  else
    _dsb_i "Logged out from Azure CLI."
    returnCode=0
  fi

  _dsb_d "clearOutput: ${clearOutput}"

  # enumerate but ignore results
  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_az_enumerate_account || :

  _dsb_d "done"
  return "${returnCode}"
}

# what:
#   if az cli is installed, log in the user
#   if az cli is not installed, do nothing
# input:
#   none
# on info:
#   status of operation is printed
#   account subscription details are printed (implicitly by _dsb_tf_az_enumerate_account)
# returns:
#   exit code directly
#   several global variables are updated (implicitly by _dsb_tf_az_enumerate_account)
#     - _dsbTfAzureUpn
#     - _dsbTfSubscriptionId
#     - _dsbTfSubscriptionName
_dsb_tf_az_login() {
  local returnCode=0

  local azCliStatus=0
  if ! _dsb_tf_check_az_cli; then
    _dsb_i "  💡 you can also check other prerequisites by running 'tf-check-prereqs'"
    returnCode=1
    _dsb_d "done"
  return "${returnCode}"
  fi

  if _dsbTfLogInfo=0 _dsb_tf_az_enumerate_account; then
    # already logged in?
    local azUpn="${_dsbTfAzureUpn:-}"
    if [ -n "${azUpn}" ]; then
      # logged in, do nothing except showing the UPN
      _dsbTfLogInfo=1 _dsb_tf_az_enumerate_account
      returnCode=0
      _dsb_d "done"
  return "${returnCode}"
    fi
  fi

  # make sure to clear any existing account
  az account clear &>/dev/null || :

  local captureFile
  captureFile="/tmp/dsb-tf-helpers-$$-az-login"
  _dsb_d "capturing az login output to ${captureFile} (streaming)"

  local deviceCode
  if eval "az login --use-device-code 2>&1" | while IFS= read -r azOutputLine; do
    if [ -z "${deviceCode:-}" ]; then
      # until code is found we do not suppress output from az cli
      printf '%s\n' "${azOutputLine}" | tee -a "${captureFile}" >&2
    else
      # when code is found we suppress further output from az cli
      echo "${azOutputLine}" >>"${captureFile}"
    fi
    if [ -z "${deviceCode:-}" ] && printf '%s' "${azOutputLine}" | grep -qi 'enter the code'; then
      maybeCode="$(printf '%s\n' "${azOutputLine}" | awk '{for(i=1;i<=NF;i++){if($i ~ /^[A-Z0-9]{6,}$/){c=$i}}}END{if(c)print c}')"
      if [ -n "${maybeCode}" ]; then
        deviceCode="${maybeCode}"
        _dsb_d "Azure device login code: ${deviceCode}"
        local _clipOk=1
        if command -v wl-copy >/dev/null 2>&1; then
          _dsb_d "Using wl-copy to copy device code to clipboard."
          printf '%s' "${deviceCode}" | wl-copy && _clipOk=0
        elif command -v xclip >/dev/null 2>&1; then
          _dsb_d "Using xclip to copy device code to clipboard."
          printf '%s' "${deviceCode}" | xclip -selection clipboard && _clipOk=0
        elif command -v xsel >/dev/null 2>&1; then
          _dsb_d "Using xsel to copy device code to clipboard."
          printf '%s' "${deviceCode}" | xsel --clipboard --input && _clipOk=0
        elif command -v pbcopy >/dev/null 2>&1; then
          _dsb_d "Using pbcopy to copy device code to clipboard."
          printf '%s' "${deviceCode}" | pbcopy && _clipOk=0
        fi
        if [ ${_clipOk} -eq 0 ]; then
          _dsb_i "Device code was copied to the clipboard for you 😉" >&2
        else
          _dsb_d "Clipboard tool not found; skipping copy of device code."
        fi
      fi
    fi
  done; then
    if [ -z "${deviceCode:-}" ]; then
      _dsb_d "device code was not found and not copied."
    fi
    _dsb_tf_az_enumerate_account
    returnCode=$? # caller reads returnCode
  else
    _dsb_e "Failed to login with Azure CLI."
    _dsb_e "  please run 'az login --debug' manually"
    returnCode=1
  fi

  local loginOutput
  loginOutput="$(cat "${captureFile}" 2>/dev/null || :)"
  _dsb_d "loginOutput: ${loginOutput}"
  rm -f -- "${captureFile}" 2>/dev/null || :

  _dsb_d "done"
  return "${returnCode}"
}

# what:
#   log out and log in the user
# input:
#   none
# on info:
#   status of operation is printed (implicitly by _dsb_tf_az_logout and _dsb_tf_az_login)
#   account subscription details are printed (implicitly by _dsb_tf_az_login -> _dsb_tf_az_enumerate_account)
# returns:
#   exit code directly
#   several global variables are updated (implicitly by _dsb_tf_az_login -> _dsb_tf_az_enumerate_account)
#     - _dsbTfAzureUpn
#     - _dsbTfSubscriptionId
#     - _dsbTfSubscriptionName
_dsb_tf_az_re_login() {
  _dsb_tf_az_logout
  local logoutStatus=$?
  _dsb_tf_az_login
  local loginStatus=$?
  local returnCode=$((logoutStatus + loginStatus)) # caller reads returnCode

  _dsb_d "done"
  return "${returnCode}"
}

# what:
#   set the Azure subscription according to the selected environment's subscription hint
# input:
#   none
# on info:
#   subscription ID and name are printed (implicitly by _dsb_tf_az_enumerate_account)
# returns:
#   exit code directly
#   several global variables are updated (implicitly by _dsb_tf_az_enumerate_account):
#     - _dsbTfAzureUpn
#     - _dsbTfSubscriptionId
#     - _dsbTfSubscriptionName
_dsb_tf_az_set_sub() {
  local returnCode=1
  local skipLockCheck="${1:-0}" # optional, defaults to 0
  local selectedEnv="${_dsbTfSelectedEnv:-}"

  if [ -z "${selectedEnv}" ]; then
    _dsb_e "No environment selected, please run one of these commands":
    _dsb_e "  - 'tf-select-env'"
    _dsb_e "  - 'tf-set-env <env>'"
    return 1
  fi

  # enumerate the directories and validate the selected environment
  # populates _dsbTfSelectedEnvSubscriptionHintContent if successful
  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_env "" "${skipLockCheck}"
  # shellcheck disable=SC2181 # inline var assignment requires $?
  if [ $? -ne 0 ]; then
    _dsb_e "Environment check failed, please run 'tf-check-env ${selectedEnv}'"
    return 1
  fi

  # need the cli
  if ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_az_cli; then
    _dsb_e "Azure CLI check failed, please run 'tf-check-prereqs'"
    return 1
  fi

  # if the globally persisted subscription name matches the subscription hint, assume the user is logged in
  # we do this because _dsb_tf_az_enumerate_account is time consuming
  local subId="${_dsbTfSubscriptionId:-}"
  local subName="${_dsbTfSubscriptionName:-}"
  _dsb_d "subscription Name: ${_dsbTfSubscriptionName:-}"
  _dsb_d "subscription hint: ${_dsbTfSelectedEnvSubscriptionHintContent:-}"
  if [ -n "${subName}" ] && [[ "${subName,,}" == "${_dsbTfSelectedEnvSubscriptionHintContent,,}" ]]; then # ,, converts all characters in the variable's value to lowercase.
    _dsb_d "subscription id matches subscription hint, assume user is logged in and subscription is set"
    _dsb_d "subscription ID  : ${_dsbTfSubscriptionId:-}"
    return 0
  fi

  _dsb_d "current subscription name does not match subscription hint, proceed with checking login status"

  # check if user is logged in
  if ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_az_enumerate_account; then
    _dsb_e "Azure CLI account enumeration failed, please run 'az-whoami'"
    return 1
  fi

  # set the subscription
  if az account set --subscription "${_dsbTfSelectedEnvSubscriptionHintContent}"; then
    # updates the selected subscription global variable
    _dsb_tf_az_enumerate_account
    _dsb_d "Subscription ID set to: ${_dsbTfSubscriptionId:-}"
    _dsb_d "Subscription name set to: ${_dsbTfSubscriptionName:-}"
    returnCode=0
  else
    _dsb_e "Failed to set subscription."
    _dsb_e "  subscription hint: ${_dsbTfSelectedEnvSubscriptionHintContent}"
  fi

  _dsb_d "done"
  return "${returnCode}"
}

# what:
#   allows the user to select the active Azure subscription using azure cli
# input:
#   none
# on info:
#   subscription ID and name are printed (implicitly by _dsb_tf_az_enumerate_account)
# returns:
#   exit code directly
#   several global variables are updated (implicitly by _dsb_tf_az_enumerate_account):
#     - _dsbTfAzureUpn
#     - _dsbTfSubscriptionId
#     - _dsbTfSubscriptionName
_dsb_tf_az_select_sub() {
  local returnCode=0

  returnCode=1 # default to failure

  # need the cli
  if ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_az_cli; then
    _dsb_e "Azure CLI check failed, please run 'tf-check-prereqs'"
    return 0
  fi

  # check if user is logged in
  if ! _dsb_tf_az_is_logged_in; then
    _dsb_i "Not logged in with Azure CLI."
    _dsb_i "  please run 'az-login'"
    return 0
  fi

  if ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_az_enumerate_account; then
    _dsb_e "Azure CLI account enumeration failed, please run 'az-whoami'"
    return 0
  fi

  local selectedSubId="${_dsbTfSubscriptionId:-}"
  _dsb_d "selected subscription id: ${selectedSubId}"

  local accountJson
  if ! accountJson=$(az account list --all 2>&1); then
    _dsb_e "Azure subscriptions enumeration failed."
    _dsb_e "  please run 'az-whoami'"
    _dsb_e "  or check output of 'az account list --all'"
    return 0
  fi

  _dsb_d "accountJson: ${accountJson}"

  # sort json on tenantDisplayName, name and id
  accountJson=$(echo "${accountJson}" | jq -r 'sort_by(.tenantDisplayName, .name, .id)')

  local -a availableSubIds availableSubNames availableSubTenantNames
  mapfile -t availableSubIds < <(echo "${accountJson}" | jq -r '.[].id')
  mapfile -t availableSubNames < <(echo "${accountJson}" | jq -r '.[].name')
  mapfile -t availableSubTenantNames < <(echo "${accountJson}" | jq -r '.[].tenantDisplayName')

  local subCount=${#availableSubIds[@]}

  _dsb_d "available subs count in availableEnvs: ${subCount}"
  _dsb_d "available subs: ${availableSubNames[*]}"

  if [ "${subCount}" -eq 0 ]; then
    _dsb_w "No Azure subscriptions found."
    _dsb_i "  verify that you are logged as the correct user with 'az-whoami'"
  else
    local envIdx=1
    _dsb_i "Available subscriptions, tenant names in parentheses:"
    local subId
    for subId in "${availableSubIds[@]}"; do
      subName="${availableSubNames[$((envIdx - 1))]}"
      subTenantName="${availableSubTenantNames[$((envIdx - 1))]}"
      # ${#subCount} is number of digits, used to right-align the index numbers
      local idxStr
      idxStr=$(printf "%*d" "${#subCount}" "${envIdx}")
      if [ "${subId}" == "${selectedSubId}" ]; then
        _dsb_i "  -> ${idxStr}) ${subName} (${subTenantName})"
      else
        _dsb_i "     ${idxStr}) ${subName} (${subTenantName})"
      fi
      ((envIdx++))
    done

    if [ -n "${selectedSubId}" ]; then
      _dsb_i ""
      _dsb_i " -> indicates the currently selected"
    fi

    local -a validChoices
    mapfile -t validChoices < <(seq 1 "${subCount}")

    local userInput idx
    local gotValidInput=0
    while [ "${gotValidInput}" -ne 1 ]; do
      read -r -p "Enter index of subscription to set: " userInput
      # clear the current console line
      echo -en "\033[1A\033[2K"
      for idx in "${validChoices[@]}"; do
        if [ "${idx}" == "${userInput}" ]; then
          gotValidInput=1
          _dsb_d "idx = ${idx} is valid"
          break
        fi
      done
    done

    _dsb_i ""

    # set the subscription
    local subNameToSet subIdToSet subTenantNameToSet
    subNameToSet="${availableSubNames[$((userInput - 1))]}"
    subIdToSet="${availableSubIds[$((userInput - 1))]}"
    subTenantNameToSet="${availableSubTenantNames[$((userInput - 1))]}"

    _dsb_d "current subscription id: ${_dsbTfSubscriptionId:-}"
    _dsb_d "current subscription name: ${_dsbTfSubscriptionName:-}"
    _dsb_d "setting:"
    _dsb_d "  subscription name: ${subNameToSet}"
    _dsb_d "  subscription id: ${subIdToSet}"
    _dsb_d "  subscription tenant name: ${subTenantNameToSet}"

    if az account set --subscription "${subIdToSet}"; then
      # updates the selected subscription global variable
      _dsb_tf_az_enumerate_account
      _dsb_d "Subscription ID set to: ${_dsbTfSubscriptionId:-}"
      _dsb_d "Subscription name set to: ${_dsbTfSubscriptionName:-}"
      returnCode=0 # indicate success
    else
      _dsb_e "Failed to set subscription."
      _dsb_e "  subscription name: ${subNameToSet}"
      _dsb_e "  subscription id: ${subIdToSet}"
      _dsb_e "  subscription tenant name: ${subTenantNameToSet}"
    fi

  fi # end subCount check

  _dsb_d "done"
  return "${returnCode}"
}

###################################################################################################
#
# terraform operations functions
#
###################################################################################################

# what:
#   validate an environment exists and set globals, without touching Azure
#   used by offline code paths that need env info but not subscription
# input:
#   $1: environment name
# returns:
#   0 on success, 1 on failure
_dsb_tf_set_env_offline() {
  local envToSet="${1:-}"
  local skipLockCheck="${2:-0}" # optional, defaults to 0

  _dsb_d "envToSet: ${envToSet}"
  _dsb_d "skipLockCheck: ${skipLockCheck}"

  if [ -z "${envToSet}" ]; then
    _dsb_e "No environment specified."
    _dsb_tf_error_push "no environment specified"
    return 1
  fi

  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  # shellcheck disable=SC2181 # inline var assignment requires $?
  if [ $? -ne 0 ]; then
    _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
    _dsb_tf_error_push "directory check failed"
    return 1
  fi

  if ! _dsb_tf_look_for_env "${envToSet}"; then
    _dsb_e "Environment '${envToSet}' not found."
    _dsb_tf_error_push "environment '${envToSet}' not found"
    return 1
  fi

  _dsbTfSelectedEnv="${envToSet}"
  _dsbTfSelectedEnvDir="${_dsbTfEnvsDirList["${envToSet}"]}"
  _dsb_i "Selected environment: ${_dsbTfSelectedEnv} (offline mode, skipping Azure)"

  if [ "${skipLockCheck}" -eq 0 ]; then
    if ! _dsbTfLogErrors=0 _dsb_tf_look_for_lock_file; then
      _dsb_e "Lock file check failed, please run 'tf-init ${envToSet}' first"
      _dsb_tf_error_push "lock file not found for '${envToSet}'"
      return 1
    fi
  fi

  return 0
}

# what:
#   preflight checks for terraform operations functions
#   checks if terraform is installed
#   selects the given environment
#   checks if the selected environment is valid
#   sets the subscription to the selected environment
# input:
#   $1: environment name
#   $2: if we are in offline mode (optional, defaults to 0)
#         ie. do not expect to be able to resolve subscription name to id
#   $3: skip lock file check (optional, defaults to 0)
#         set to 1 for init/upgrade commands that create the lock file
# on info:
#   nothing
# returns:
#   exit code directly
_dsb_tf_terraform_preflight() {
  local returnCode=0
  local selectedEnv="${1}"
  local offlineInit="${2:-0}"    # defaults to 0
  local skipLockCheck="${3:-0}"  # defaults to 0

  _dsb_d "called with:"
  _dsb_d "  selectedEnv: ${selectedEnv}"
  _dsb_d "  offlineInit: ${offlineInit}"
  _dsb_d "  skipLockCheck: ${skipLockCheck}"

  if [ -z "${selectedEnv}" ]; then
    _dsb_e "No environment selected, please run 'tf-select-env' or 'tf-set-env <env>'"
    return 1
  fi

  # terraform must be installed
  if ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_terraform; then
    _dsb_e "Terraform check failed, please run 'tf-check-tools'"
    return 1
  fi

  if [ "${offlineInit}" -eq 1 ]; then
    # Offline: validate the environment exists and set globals, skip Azure
    if ! _dsb_tf_set_env_offline "${selectedEnv}" "${skipLockCheck}"; then
      return 1
    fi
  else
    # Online: full environment setup including Azure subscription
    _dsbTfLogInfo=1 _dsbTfLogErrors=0 _dsb_tf_set_env "${selectedEnv}" "${skipLockCheck}"
    # shellcheck disable=SC2181 # inline var assignment requires $?
    if [ $? -ne 0 ]; then
      _dsb_e "Failed to set environment '${selectedEnv}'."
      _dsb_e "  please run 'tf-check-env ${selectedEnv}'"
      return 1
    fi
  fi

  # should be set when _dsbTfSelectedEnv is set
  local envDir="${_dsbTfSelectedEnvDir:-}"
  if [ -z "${envDir}" ]; then
    _dsb_internal_error "Internal error: expected to find selected environment directory." \
      "  expected in: _dsbTfSelectedEnvDir"
    return 1
  fi

  # subscription should be set when _dsb_tf_set_env was successful and we are not offline
  local subId="${_dsbTfSubscriptionId:-}"
  if [ -z "${subId}" ] && [ "${offlineInit}" -eq 0 ]; then
    _dsb_d "unset ARM_SUBSCRIPTION_ID"
    unset ARM_SUBSCRIPTION_ID
    _dsb_internal_error "Internal error: expected to find subscription ID." \
      "  expected in: _dsbTfSubscriptionId"
    return 1
  elif [ "${offlineInit}" -eq 1 ]; then
    _dsb_d "offline mode, setting ARM_SUBSCRIPTION_ID to empty string"
    export ARM_SUBSCRIPTION_ID=""
  else
    # required by azurerm terraform provider
    export ARM_SUBSCRIPTION_ID="${subId}"
  fi

  _dsb_d "current ARM_SUBSCRIPTION_ID: '${ARM_SUBSCRIPTION_ID}'"

  return 0
}

# what:
#   the function that runs terraform init in selected environment
#   this function does not perform any pre flight checks
#   if $1 is set to 1 (do upgrade), it will run terraform init -upgrade
# input:
#   $1: do upgrade (optional, defaults to 0)
#   $2: offline init, ie. with -backend=false (optional, defaults to 0)
#   $3..: extra terraform arguments (optional, passed through to terraform init)
# on info:
#   nothing
# returns:
#   1 when terraform returns non-zero exit code, otherwise 0
_dsb_tf_init_env_actual() {
  local doUpgrade="${1:-0}"   # defaults to 0
  local offlineInit="${2:-0}" # defaults to 0
  shift 2 || shift $# || :
  local -a passthroughArgs=("$@")

  local envDir="${_dsbTfSelectedEnvDir}"
  local subId="${_dsbTfSubscriptionId}"
  local extraInitArgs=""
  local localStateFile="${envDir}/.terraform/terraform.tfstate"
  local localStateFileOld="${envDir}/.terraform/terraform.tfstate.tf-helpers-old"

  _dsb_d "called with:"
  _dsb_d "  doUpgrade: ${doUpgrade}"
  _dsb_d "  offlineInit: ${offlineInit}"
  _dsb_d "  envDir: ${envDir}"
  _dsb_d "  subId: ${subId}"
  _dsb_d "  current ARM_SUBSCRIPTION_ID: '${ARM_SUBSCRIPTION_ID}'"
  if [ "${#passthroughArgs[@]}" -gt 0 ]; then
    _dsb_d "  passthroughArgs: ${passthroughArgs[*]}"
  fi

  if [ "${doUpgrade}" -eq 1 ]; then
    extraInitArgs=" -upgrade"
  fi

  if [ "${offlineInit}" -eq 1 ]; then
    extraInitArgs+=" -backend=false"

    # if a local state file exists it must be removed otherwise terraform will use the backend config declared in the file
    _dsb_d "looking for tfstate file: ${localStateFile}"
    if [ -f "${localStateFile}" ]; then
      _dsb_d "found, renaming ..."
      if ! "${_dsbTfMvCmd}" --force "${localStateFile}" "${localStateFileOld}"; then
        _dsb_d "terraform init failed, during rename of local state file"
        return 1
      fi
    fi
  fi

  _dsb_d "extraInitArgs: ${extraInitArgs}"

  # output from the command will have paths relative to the current environment directory
  #   pipe all output (stdout and stderr) to _dsb_tf_fixup_paths_from_stdin to make they are relative to the root directory
  # shellcheck disable=SC2086 # extraInitArgs is intentionally unquoted for word splitting
  terraform -chdir="${envDir}" init -reconfigure -lock=false ${extraInitArgs} "${passthroughArgs[@]}" 2>&1 | _dsb_tf_fixup_paths_from_stdin
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    _dsb_d "terraform init failed, attempting to restore tfstate file ... "

    if [ -f "${localStateFileOld}" ]; then
      "${_dsbTfMvCmd}" --force "${localStateFileOld}" "${localStateFile}" || :
    fi

    return 1
  fi

  # put the local state file back
  if [ -f "${localStateFileOld}" ]; then
    _dsb_d "attempting to restore tfstate file ... "
    if ! "${_dsbTfMvCmd}" --force "${localStateFileOld}" "${localStateFile}"; then
      _dsb_d "terraform init failed, during restore of local state file"
      return 1
    fi
  fi

  # make sure hashes for all required platforms are available in the lock file
  if [ "${doUpgrade}" -eq 1 ]; then
    _dsb_d "adding hashes to the lock file"

    # hardcoded to windows, macOS and linux
    #   pipe to _dsb_tf_fixup_paths_from_stdin to make paths relative to the root directory
    terraform -chdir="${envDir}" providers lock -platform=windows_amd64 -platform=darwin_amd64 -platform=linux_amd64 -platform=linux_arm64 2>&1 | _dsb_tf_fixup_paths_from_stdin
    if [ "${PIPESTATUS[0]}" -ne 0 ]; then
      _dsb_d "adding hashes to the lock file failed"
      return 1
    fi

    _dsb_d "hashes added"
  fi

  return 0
}

# what:
#   runs terraform init in the the given environment directory
#   if $2 is set to 1 (do upgrade), it will run terraform init -upgrade
# input:
#   $1: do upgrade
#   $2: offline init, ie. with -backend=false (optional, defaults to 0)
#   $3: environment directory (optional, defaults to selected environment directory)
# on info:
#   nothing
# returns:
#   exit code directly
_dsb_tf_init_env() {
  local returnCode=0
  local doUpgrade="${1}"
  local offlineInit="${2:-0}" # defaults to 0
  local selectedEnv="${3:-${_dsbTfSelectedEnv:-}}"

  _dsb_d "called with:"
  _dsb_d "  doUpgrade: ${doUpgrade}"
  _dsb_d "  offlineInit: ${offlineInit}"
  _dsb_d "  selectedEnv: ${selectedEnv}"

  if ! _dsb_tf_terraform_preflight "${selectedEnv}" "${offlineInit}" 1; then # $3 = 1: skip lock check, init creates it


    return 1


  fi

  _dsb_i ""
  _dsb_i "Initializing environment: $(_dsb_tf_get_rel_dir "${_dsbTfSelectedEnvDir}")"
  if ! _dsb_tf_init_env_actual "${doUpgrade}" "${offlineInit}"; then
    _dsb_e "init in ./$(_dsb_tf_get_rel_dir "${_dsbTfSelectedEnvDir:-}") failed"
    returnCode=1
  fi

  return 0
}

# what:
#   runs terraform init in the given directory (main or module)
#   copies the lock file from the selected environment to the target directory
#   uses .terraform/providers from the selected environment as plugin cache
#   removes the copied lock file after init
# input:
#   $1: directory path
# on info:
#   terraform init output
# returns:
#   exit code directly
_dsb_tf_init_dir() {
  local dirPath="${1}"
  local envDir="${_dsbTfSelectedEnvDir}"

  _dsb_d "dirPath: ${dirPath}"
  _dsb_d "envDir: ${envDir}"

  _dsb_d "copying from ${envDir}/.terraform.lock.hcl"
  _dsb_d "to ${dirPath}/.terraform.lock.hcl"
  if ! cp -f "${envDir}/.terraform.lock.hcl" "${dirPath}/.terraform.lock.hcl"; then
    _dsb_tf_error_push "failed to copy lock file to ${dirPath}"
    return 1
  fi

  _dsb_d "removing ${dirPath}/.terraform"
  rm -rf "${dirPath}/.terraform"

  _dsb_d "init in ${dirPath}"
  _dsb_d "with plugin-dir: ${envDir}/.terraform/providers"

  # output from the command will have paths relative to the current environment directory
  #   pipe all output (stdout and stderr) to _dsb_tf_fixup_paths_from_stdin to make they are relative to the root directory
  TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE=true \
    terraform -chdir="${dirPath}" init -input=false -plugin-dir="${envDir}/.terraform/providers" -backend=false -reconfigure 2>&1 | _dsb_tf_fixup_paths_from_stdin
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    _dsb_tf_error_push "terraform init failed in ${dirPath}"
    rm -f "${dirPath}/.terraform.lock.hcl"
    return 1
  fi

  _dsb_d "removing ${dirPath}/.terraform.lock.hcl"
  rm -f "${dirPath}/.terraform.lock.hcl"
}

# what:
#   initializes all local sub-modules in the current directory / terraform project
# input:
#   $1: skip preflight checks (optional)
# on info:
#   status messages are printed
# returns:
#   exit code directly
_dsb_tf_init_modules() {
  local returnCode=0
  local skipPreflight="${1:-0}"
  local selectedEnv="${_dsbTfSelectedEnv:-}"

  _dsb_d "skipPreflight: ${skipPreflight}"

  if [ "${skipPreflight}" -ne 1 ]; then
    if ! _dsb_tf_terraform_preflight "${selectedEnv}" 0 1; then # $3 = 1: skip lock check, init creates it

      return 1

    fi
  fi

  # to able to init modules, we need to have the lock file and the providers directory
  local envProvidersDir="${_dsbTfSelectedEnvDir:-}/.terraform/providers" # this exists when init has been run in the selected environment

  if [ ! -d "${envProvidersDir}" ]; then
    _dsb_e "Providers directory not found in selected environment."
    _dsb_e "  expected to find: ${envProvidersDir}"
    _dsb_e "  please run 'tf-init-env ${selectedEnv}' first"
    return 1
  fi

  local -a moduleDirs
  mapfile -t moduleDirs < <(_dsb_tf_get_module_dirs)
  local moduleDirsCount=${#moduleDirs[@]}

  _dsb_d "moduleDirsCount: ${moduleDirsCount}"

  if [ "${moduleDirsCount}" -eq 0 ]; then
    _dsb_i "No modules found to init in: ${selectedEnv}"
    return 0
  fi

  local moduleDir
  for moduleDir in "${moduleDirs[@]}"; do
    _dsb_d "init module in: ${moduleDir}"
    _dsb_i_append "" # newline without any prefix
    _dsb_i "Initializing module in: $(_dsb_tf_get_rel_dir "${moduleDir}")"
    if ! _dsb_tf_init_dir "${moduleDir}"; then
      _dsb_e "Failed to init module in: ${moduleDir}"
      _dsb_e "  init operation not complete, consider enabling debug logging"
      return 1
    fi
  done

  returnCode=0
  _dsb_d "done"

  return "${returnCode}"
}

# what:
#   initializes the main directory of the terraform project
# input:
#   $1: skip preflight checks (optional)
#   $2: environment directory (optional, defaults to selected environment directory)
# on info:
#   status messages are printed
# returns:
#   exit code directly
_dsb_tf_init_main() {
  local returnCode=0
  local skipPreflight="${1:-0}"
  local selectedEnv="${_dsbTfSelectedEnv:-}"

  _dsb_d "skipPreflight: ${skipPreflight}"

  if [ "${skipPreflight}" -ne 1 ]; then
    if ! _dsb_tf_terraform_preflight "${selectedEnv}" 0 1; then # $3 = 1: skip lock check, init creates it

      return 1

    fi
  fi

  # to be able to init, we need to have the lock file and the providers directory
  # environment lock file's existence was checked implicitly by _dsb_tf_terraform_preflight -> _dsb_tf_set_env further up
  local envProvidersDir="${_dsbTfSelectedEnvDir:-}/.terraform/providers" # this exists when init has been run in the selected environment

  if [ ! -d "${envProvidersDir}" ]; then
    _dsb_e "Providers directory not found in selected environment."
    _dsb_e "  expected to find: ${envProvidersDir}"
    _dsb_e "  please run 'tf-init-env ${selectedEnv}' first"
    return 1
  fi

  _dsb_d "Main dir: ${_dsbTfMainDir}"

  _dsb_i_append "" # newline without any prefix
  _dsb_i "Initializing dir : $(_dsb_tf_get_rel_dir "${_dsbTfMainDir}")"
  if ! _dsb_tf_init_dir "${_dsbTfMainDir}"; then
    _dsb_e "Failed to init directory: ${_dsbTfMainDir}"
    _dsb_e "  init operation not complete, consider enabling debug logging"
    return 1
  fi

  returnCode=0
  _dsb_d "done"

  return "${returnCode}"
}

# what:
#   initializes the terraform project
#   performs preflight checks
#   initializes the environment, modules and main directory
# input:
#   $1: do upgrade
#   $2: clear selected environment after (optional, defaults to 1)
#   $3: offline init, ie. with -backend=false (optional, defaults to 0)
#   $4: name of environment to init, if not provided all environments are checked
# on info:
#   status messages are printed
# returns:
#   exit code directly
_dsb_tf_init() {
  local doUpgrade="${1}"
  local clearSelectedEnvAfter="${2:-1}" # defaults to 1
  local offlineInit="${3:-0}"           # defaults to 0
  local envToInit="${4:-}"              # defaults to empty string
  shift 4 || shift $# || :
  local -a passthroughArgs=("$@")

  _dsb_d "called with:"
  _dsb_d "  doUpgrade: ${doUpgrade}"
  _dsb_d "  offlineInit: ${offlineInit}"
  _dsb_d "  clearSelectedEnvAfter: ${clearSelectedEnvAfter}"
  _dsb_d "  envToInit: ${envToInit}"
  if [ "${#passthroughArgs[@]}" -gt 0 ]; then
    _dsb_d "  passthroughArgs: ${passthroughArgs[*]}"
  fi

  local operationFriendlyName="Initialization"
  if [ "${doUpgrade}" -eq 1 ]; then
    operationFriendlyName="Upgrade"
  fi
  if [ "${offlineInit}" -eq 1 ]; then
    operationFriendlyName+=" (offline)"
  fi

  # check if the current root directory is a valid Terraform project
  # _dsb_tf_check_current_dir calls _dsb_tf_enumerate_directories, so we don't need to call it again in this function
  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  # shellcheck disable=SC2181 # inline var assignment requires $?
  if [ $? -ne 0 ]; then
    _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
    return 1
  fi

  local -a availableEnvs=()
  if [ -n "${envToInit}" ]; then
    availableEnvs=("${envToInit}")
  else
    mapfile -t availableEnvs < <(_dsb_tf_get_env_names)
  fi
  local envCount=${#availableEnvs[@]}

  _dsb_d "available envs count in availableEnvs: ${envCount}"
  _dsb_d "available envs: ${availableEnvs[*]}"

  local envsDir="${_dsbTfEnvsDir}"

  if [ "${envCount}" -eq 0 ]; then
    _dsb_e "No environments found in: ${envsDir}"
    _dsb_e "  please run 'tf-list-envs' to list available environments"
    _dsb_e "  or try running 'tf-check-dir' to verify the directory structure"
    return 1
  fi

  local preflightStatus=0
  local initEnvStatus=0
  local initModulesStatus=0
  local initMainStatus=0
  local envName envDir
  for envName in "${availableEnvs[@]}"; do
    _dsb_i ""
    _dsb_i "${operationFriendlyName} environment: ${envName}"
    _dsb_i ""

    # preflight, check if terraform is installed, set the environment and check if it is valid
    if ! _dsb_tf_terraform_preflight "${envName}" "${offlineInit}" 1; then # $3 = 1: skip lock check, init creates it

      _dsb_e "  preflight checks failed"

      ((preflightStatus += 1))
    else
      local envDir="${_dsbTfSelectedEnvDir}" # available thanks to _dsb_tf_terraform_preflight
      _dsb_d "    envDir: ${envDir}"

      if ! _dsb_tf_init_env_actual "${doUpgrade}" "${offlineInit}" "${passthroughArgs[@]}"; then
        _dsb_e "  init in ./$(_dsb_tf_get_rel_dir "${envDir:-}") failed"
        ((initEnvStatus += 1))
      else
        if ! _dsb_tf_init_modules 1 "${envName}"; then # $1 = 1 means skip preflight checks, $2 = envName
          _dsb_d "init modules failed for ${envName}"
          ((initModulesStatus += 1))
        fi

        if ! _dsb_tf_init_main 1 "${envName}"; then # $1 = 1 means skip preflight checks, $2 = envName
          _dsb_d "init main failed for ${envName}"
          ((initMainStatus += 1))
        fi
      fi
    fi
  done # end of availableEnvs loop

  local returnCode=$((preflightStatus + initEnvStatus + initModulesStatus + initMainStatus))

  if [ "${returnCode}" -ne 0 ]; then
    _dsb_e ""
    _dsb_e "Failures occurred during ${operationFriendlyName}."
    _dsb_e "  ${returnCode} operation(s) failed:"
    _dsb_e "   - ${preflightStatus} failed preflight checks"
    _dsb_e "   - ${initEnvStatus} failed terraform -init of environments"
    _dsb_e "   - ${initModulesStatus} failed init of modules"
    _dsb_e "   - ${initMainStatus} failed init of main"
    _dsb_e ""
    _dsb_e "  please review the output from each operation further up"
  else
    _dsb_i "${operationFriendlyName} complete."
  fi

  if [ "${clearSelectedEnvAfter}" -eq 1 ]; then
    # "unselect" the environment to avoid the user starting to run commands in the wrong environment
    _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_clear_env || :
  fi

  _dsb_d "done"
  return "${returnCode}"
}

# what:
#   this function is a wrapper of _dsb_tf_init
#   it allows to specify an environment to initialize
#   and if the not specified, it attempts to use the selected environment
# input:
#   $1: do upgrade
#   $2: offline init, ie. with -backend=false (optional, defaults to 0)
#   $3: optional, environment name to init, if not provided the selected environment is used
#   $4..: extra terraform arguments (optional, passed through to terraform init)
#
# on info:
#   nothing, status messages indirectly from _dsb_tf_init
# returns:
#   exit code directly
_dsb_tf_init_full_single_env() {
  local returnCode=0
  local doUpgrade="${1}"
  local offlineInit="${2:-0}" # defaults to 0
  local envToInit="${3:-}"    # defaults to empty string
  shift 3 || shift $# || :
  local -a passthroughArgs=("$@")

  _dsb_d "called with:"
  _dsb_d "  doUpgrade: ${doUpgrade}"
  _dsb_d "  envToInit: ${envToInit}"
  _dsb_d "  offlineInit: ${offlineInit}"
  if [ "${#passthroughArgs[@]}" -gt 0 ]; then
    _dsb_d "  passthroughArgs: ${passthroughArgs[*]}"
  fi

  if [ -z "${envToInit}" ]; then
    envToInit=${_dsbTfSelectedEnv:-}
  fi

  if [ -z "${envToInit}" ]; then
    _dsb_e "No environment specified and no environment selected."
    _dsb_e "  either specify environment: 'tf-init <env>'"
    _dsb_e "  or run 'tf-set-env <env>' first"
    returnCode=1
  else
    _dsb_tf_init "${doUpgrade}" 0 "${offlineInit}" "${envToInit}" "${passthroughArgs[@]}" # $1 = 'init -upgrade', $2 = clearSelectedEnvAfter, $3 = with/without backend
    returnCode=$?
  fi

  _dsb_d "done"
  return "${returnCode}"
}

# what:
#   runs terraform format in the given directory
#   if $1 is set to 1 (performFix), it will run terraform fmt -recursive
#   otherwise, it will run terraform fmt -recursive -check (ie. check only)
# input:
#   $1: performFix (optional)
# on info:
#   status messages are printed
# returns:
#   exit code directly
_dsb_tf_fmt() {
  local returnCode=0
  local performFix="${1:-0}"
  local extraFmtArgs="-check"

  _dsb_d "performFix: ${performFix}"

  if [ "${performFix}" -eq 1 ]; then
    extraFmtArgs="" # not passing -check means terraform will fix the files
  fi

  _dsb_d "extraFmtArgs: ${extraFmtArgs}"

  # terraform must be installed
  if ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_terraform; then
    _dsb_e "Terraform check failed, please run 'tf-check-tools'"
    return 1 # caller reads returnCode
  fi

  # enumerate directories with current directory as root and
  # check if the current root directory is a valid Terraform project
  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  local dirCheckStatus=$?
  if [ "${dirCheckStatus}" -ne 0 ]; then
    _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
  return "${returnCode}"
  fi

  _dsb_i "Running terraform fmt recursively"
  _dsb_i "  directory ${_dsbTfRootDir}"

  if terraform fmt -recursive ${extraFmtArgs} "${_dsbTfRootDir}"; then
    returnCode=0
    _dsb_i "Done."
  else
    returnCode=1
    if [ "${performFix}" -eq 1 ]; then
      _dsb_e "Terraform fmt operation failed."
    else
      _dsb_e "Terraform fmt check failed, please review the output above."
    fi
  fi

  _dsb_d "done"


  return "${returnCode}"
}

# what:
#   runs terraform validate in the given environment directory
#   if environment is not supplied, uses the selected environment
# input:
#   $1: environment name (optional)
# on info:
#   status messages are printed
# returns:
#   exit code directly
_dsb_tf_validate_env() {
  local returnCode=0
  local selectedEnv="${1:-${_dsbTfSelectedEnv:-}}"

  # we always do preflight in offline mode since no subscription resolution is needed for validate
  if ! _dsb_tf_terraform_preflight "${selectedEnv}" 1 1; then # $2 = offline, $3 = skip lock check
    return 1
  fi

  local envDir="${_dsbTfSelectedEnvDir}"
  _dsb_i ""
  _dsb_i "Validating environment: $(_dsb_tf_get_rel_dir "${envDir}")"

  _dsb_d "current ARM_SUBSCRIPTION_ID: '${ARM_SUBSCRIPTION_ID}'"

  # output from the command will have paths relative to the current environment directory
  #   pipe all output (stdout and stderr) to _dsb_tf_fixup_paths_from_stdin to make they are relative to the root directory
  terraform -chdir="${envDir}" validate 2>&1 | _dsb_tf_fixup_paths_from_stdin
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    _dsb_e "terraform validate in ./$(_dsb_tf_get_rel_dir "${envDir:-}") failed"
    returnCode=1
  else
    returnCode=0
  fi

  _dsb_d "done"


  return "${returnCode}"
}

# what:
#   validate all environments in a project repo
#   iterates all environments, runs terraform validate in each
# input:
#   none
# on info:
#   per-environment status messages
# returns:
#   exit code directly
_dsb_tf_validate_all_project() {
  _dsb_d "called"
  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  local dirCheckStatus=$?
  if [ "${dirCheckStatus}" -ne 0 ]; then
    _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
    return 1
  fi

  local -a availableEnvs=()
  mapfile -t availableEnvs < <(_dsb_tf_get_env_names)
  local envCount=${#availableEnvs[@]}

  if [ "${envCount}" -eq 0 ]; then
    _dsb_e "No environments found."
    return 1
  fi

  local returnCode=0
  local successCount=0
  local failCount=0

  _dsb_i "Validating all environments ..."
  for envName in "${availableEnvs[@]}"; do
    _dsb_i ""
    _dsb_i "Validating environment: ${envName}"
    _dsb_d "validating environment: ${envName}"
    if ! _dsb_tf_validate_env "${envName}"; then
      _dsb_tf_error_push "validate failed for environment: ${envName}"
      returnCode=1
      ((failCount++))
    else
      ((successCount++))
    fi
  done

  _dsb_i ""
  _dsb_i "Validate all summary: ${successCount} succeeded, ${failCount} failed out of ${envCount}"
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_e "Some environments failed validation."
  else
    _dsb_i "Done."
  fi
  return "${returnCode}"
}

# what:
#   validate module root and all examples in a module repo
# input:
#   none
# on info:
#   status messages are printed
# returns:
#   exit code directly
_dsb_tf_validate_all_module() {
  _dsb_d "called"
  local returnCode=0

  _dsb_i "Validating module root and all examples ..."

  _dsb_tf_validate_module_root
  local rootRC=$?
  if [ "${rootRC}" -ne 0 ]; then
    returnCode=1
  fi

  _dsb_tf_validate_examples
  local examplesRC=$?
  if [ "${examplesRC}" -ne 0 ]; then
    returnCode=1
  fi

  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_push "validate-all failed"
  else
    _dsb_i "Done."
  fi
  return "${returnCode}"
}

# what:
#   runs terraform output in the given environment directory
#   if environment is not supplied, uses the selected environment
# input:
#   $1: environment name (optional)
# on info:
#   status messages are printed
# returns:
#   exit code directly
_dsb_tf_outputs_env() {
  _dsb_d "called with: env=${1:-<not specified>}"
  local returnCode=0
  local selectedEnv="${1:-${_dsbTfSelectedEnv:-}}"

  # we always do preflight in offline mode since no subscription resolution is needed for output
  if ! _dsb_tf_terraform_preflight "${selectedEnv}" 1 1; then # $2 = offline, $3 = skip lock check
    return 1
  fi

  local envDir="${_dsbTfSelectedEnvDir}"
  _dsb_i ""
  _dsb_i "Showing outputs for environment: $(_dsb_tf_get_rel_dir "${envDir}")"

  terraform -chdir="${envDir}" output 2>&1 | _dsb_tf_fixup_paths_from_stdin
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    _dsb_e "terraform output in ./$(_dsb_tf_get_rel_dir "${envDir:-}") failed"
    _dsb_tf_error_push "terraform output failed"
    returnCode=1
  else
    returnCode=0
  fi

  _dsb_d "done"
  return "${returnCode}"
}

# what:
#   runs terraform output at the module root directory
# input:
#   none
# on info:
#   status messages are printed
# returns:
#   exit code directly
_dsb_tf_outputs_module_root() {
  _dsb_d "called"
  if ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_terraform; then
    _dsb_e "Terraform check failed, please run 'tf-check-tools'"
    return 1
  fi

  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  local dirCheckStatus=$?
  if [ "${dirCheckStatus}" -ne 0 ]; then
    _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
    return 1
  fi

  _dsb_i "Showing outputs for module root"
  _dsb_i "  directory: ${_dsbTfRootDir}"

  terraform -chdir="${_dsbTfRootDir}" output 2>&1 | _dsb_tf_fixup_paths_from_stdin
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    _dsb_e "terraform output at root failed"
    _dsb_tf_error_push "terraform output at module root failed"
    return 1
  fi

  _dsb_i "Done."
  _dsb_d "done"
  return 0
}

# what:
#   runs terraform plan in the given environment directory
#   if environment is not supplied, uses the selected environment
# input:
#   $1: environment name (optional)
# on info:
#   status messages are printed
# returns:
#   exit code directly
_dsb_tf_plan_env() {
  local returnCode=0
  local selectedEnv="${1:-${_dsbTfSelectedEnv:-}}"
  shift || :
  local -a extraArgs=("$@")

  if ! _dsb_tf_terraform_preflight "${selectedEnv}"; then


    return 1


  fi

  local envDir="${_dsbTfSelectedEnvDir}"
  _dsb_i ""
  _dsb_i "Creating plan for environment: $(_dsb_tf_get_rel_dir "${envDir}")"

  _dsb_d "current ARM_SUBSCRIPTION_ID: '${ARM_SUBSCRIPTION_ID}'"
  if [ "${#extraArgs[@]}" -gt 0 ]; then
    _dsb_d "extra terraform args: ${extraArgs[*]}"
  fi

  # output from the command will have paths relative to the current environment directory
  #   pipe all output (stdout and stderr) to _dsb_tf_fixup_paths_from_stdin to make they are relative to the root directory
  terraform -chdir="${envDir}" plan -lock=false "${extraArgs[@]}" 2>&1 | _dsb_tf_fixup_paths_from_stdin
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    _dsb_e "terraform plan in ./$(_dsb_tf_get_rel_dir "${envDir:-}") failed"
    returnCode=1
  else
    returnCode=0
  fi

  _dsb_d "done"


  return "${returnCode}"
}

# what:
#   runs terraform apply in the given environment directory
#   if environment is not supplied, uses the selected environment
# input:
#   $1: environment name (optional)
# on info:
#   status messages are printed
# returns:
#   exit code directly
_dsb_tf_apply_env() {
  local returnCode=0
  local selectedEnv="${1:-${_dsbTfSelectedEnv:-}}"
  shift || :
  local -a extraArgs=("$@")

  if ! _dsb_tf_terraform_preflight "${selectedEnv}"; then


    return 1


  fi

  local envDir="${_dsbTfSelectedEnvDir}"
  _dsb_i ""
  _dsb_i "Running apply in environment: $(_dsb_tf_get_rel_dir "${envDir}")"

  _dsb_d "current ARM_SUBSCRIPTION_ID: '${ARM_SUBSCRIPTION_ID}'"
  if [ "${#extraArgs[@]}" -gt 0 ]; then
    _dsb_d "extra terraform args: ${extraArgs[*]}"
  fi

  # output from the command will have paths relative to the current environment directory
  if ! terraform -chdir="${envDir}" apply "${extraArgs[@]}"; then
    _dsb_e "terraform apply in ./$(_dsb_tf_get_rel_dir "${envDir:-}") failed"
    returnCode=1
  else
    returnCode=0
  fi

  _dsb_d "done"


  return "${returnCode}"
}

# what:
#   echos the command to manually run terraform destroy in the given environment directory
#   if environment is not supplied, uses the selected environment
# input:
#   $1: environment name (optional)
# on info:
#   the information is printed
# returns:
#   exit code directly
_dsb_tf_destroy_env() {
  local returnCode=0
  local selectedEnv="${1:-${_dsbTfSelectedEnv:-}}"

  if ! _dsb_tf_terraform_preflight "${selectedEnv}"; then


    return 1


  fi

  _dsb_d "current ARM_SUBSCRIPTION_ID: '${ARM_SUBSCRIPTION_ID}'"

  local envDir="${_dsbTfSelectedEnvDir}"
  _dsb_i ""
  _dsb_i "To run terraform destroy for environment: $(_dsb_tf_get_rel_dir "${envDir}"), run the following command manually:"
  _dsb_i "  terraform -chdir='${envDir}' destroy"
  return "${returnCode}"
}

###################################################################################################
#
# Linting functions
#
###################################################################################################

# what:
#   downloads the tflint wrapper script and store it locally
#   Note: this function does not perform any pre flight checks
# input:
#   none
# on info:
#   nothing
# returns:
#   exit code directly
_dsb_tf_install_tflint_wrapper() {

  _dsb_d "_dsbTfTflintWrapperDir: ${_dsbTfTflintWrapperDir:-}"
  _dsb_d "_dsbTfTflintWrapperPath: ${_dsbTfTflintWrapperPath:-}"

  local wrapperDir="${_dsbTfTflintWrapperDir:-}"
  local wrapperPath="${_dsbTfTflintWrapperPath:-}"
  local wrapperApiUrl="/repos/dsb-norge/terraform-tflint-wrappers/contents/tflint_linux.sh"
  local wrapperPublicUrl="https://raw.githubusercontent.com/dsb-norge/terraform-tflint-wrappers/main/tflint_linux.sh"

  if [ -z "${wrapperDir}" ] || [ -z "${wrapperPath}" ]; then
    _dsb_internal_error "Internal error: expected to find tflint wrapper directory and path." \
      "  expected in: _dsbTfTflintWrapperDir and _dsbTfTflintWrapperPath"
    return 1
  fi

  if [ -f "${wrapperPath}" ]; then
    _dsb_d "tflint wrapper already exists at: ${wrapperPath}"
    return 0
  fi

  if [ ! -d "${wrapperDir}" ]; then
    _dsb_d "creating tflint wrapper directory at: ${wrapperDir}"
    mkdir -p "${wrapperDir}"
  fi

  _dsb_d "downloading tflint wrapper"
  _dsb_d "  from: ${wrapperApiUrl}"
  _dsb_d "  to: ${wrapperPath}"

  if _dsbTfLogErrors=0 _dsb_tf_check_gh_cli; then
    _dsb_d "trying with GitHub CLI"
    if ! gh api -H 'Accept: application/vnd.github.v3.raw' "${wrapperApiUrl}" 2>/dev/null >"${wrapperPath}"; then
      _dsb_d "failed using GitHub CLI, trying with curl and public URL"

      if ! curl -sSL -o "${wrapperPath}" "${wrapperPublicUrl}"; then
        _dsb_d "curl also failed"
        return 1
      fi
    fi
  else
    _dsb_d "GitHub CLI not available, trying with curl and public URL"

    if ! curl -sSL -o "${wrapperPath}" "${wrapperPublicUrl}"; then
      _dsb_d "curl fails"
      return 1
    fi
  fi

  return 0
}

# what:
#   runs tflint in the selected environment directory
#   if environment is not supplied, uses the selected environment
# input:
#   $1: environment name (optional)
# on info:
#   status messages and linting results are printed
# returns:
#   exit code directly
_dsb_tf_run_tflint() {
  local returnCode=0
  local selectedEnv="${1:-${_dsbTfSelectedEnv:-}}"
  shift || :
  local lintArguments="$*"
  local githubAuthAvailable=1 # assume available until proven otherwise

  _dsb_d "called with:"
  _dsb_d " - selectedEnv: ${selectedEnv}"
  _dsb_d " - lintArguments: ${lintArguments}"

  if [ -z "${selectedEnv}" ]; then
    _dsb_e "No environment selected, please run 'tf-select-env' or 'tf-set-env <env>'"
    return 1
  fi

  # check that gh cli is installed and user is logged in
  if ! _dsbTfLogErrors=0 _dsb_tf_check_gh_auth; then
    _dsb_d "GitHub authentication unavailable, proceeding without GitHub authentication"
    githubAuthAvailable=0
  fi

  # validate the environment (linting is local, does not need Azure or lock file)
  if ! _dsb_tf_set_env_offline "${selectedEnv}" 1; then # $2 = 1: skip lock check
    return 1
  fi

  # make sure tflint is installed
  #   function falls back to using curl if gh cli fails, ie. if not authenticated with GitHub
  if ! _dsbTfLogErrors=0 _dsb_tf_install_tflint_wrapper; then
    _dsb_e "Failed to install tflint wrapper, consider enabling debug logging"
    return 1
  fi

  # should be set when _dsbTfSelectedEnv is set
  local envDir="${_dsbTfSelectedEnvDir:-}"
  if [ -z "${envDir}" ]; then
    _dsb_internal_error "Internal error: expected to find selected environment directory." \
      "  expected in: _dsbTfSelectedEnvDir"
    return 1
  fi

  local _savedPwd="${PWD}"
  if ! cd "${envDir}"; then
    _dsb_tf_error_push "failed to change to environment directory: ${envDir}"
    return 1
  fi

  # get GitHub API token
  local ghToken
  if [ "${githubAuthAvailable}" -ne 1 ]; then
    _dsb_d "GitHub authentication unavailable, proceeding without API token"
    ghToken=""
  else
    _dsb_d "GitHub authentication available, attempting to get API token"
    if ! ghToken=$(gh auth token 2>/dev/null); then
      _dsb_w "Failed to get GitHub API token even though authentication is available, attempting to proceed without API token"
      ghToken=""
    fi
  fi

  # invoke the tflint wrapper script
  #   output from the command will have paths relative to the current environment directory
  #   pipe all output (stdout and stderr) to _dsb_tf_fixup_paths_from_stdin to make they are relative to the root directory
  # shellcheck disable=SC2086 # lintArguments is intentionally unquoted for word splitting
  GITHUB_TOKEN=${ghToken} bash -s -- ${lintArguments} <"${_dsbTfTflintWrapperPath}" 2>&1 | _dsb_tf_fixup_paths_from_stdin
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    _dsb_i_append "" # newline without any prefix
    _dsb_w "tflint operation resulted in non-zero exit code."
    returnCode=1
  else
    returnCode=0
  fi

  cd "${_savedPwd}" || _dsb_w "Failed to restore working directory"

  _dsb_d "done"


  return "${returnCode}"
}

# what:
#   lint all environments in a project repo
#   iterates all environments, runs tflint in each
# input:
#   none
# on info:
#   per-environment status messages
# returns:
#   exit code directly
_dsb_tf_lint_all_project() {
  _dsb_d "called"
  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  local dirCheckStatus=$?
  if [ "${dirCheckStatus}" -ne 0 ]; then
    _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
    return 1
  fi

  local -a availableEnvs=()
  mapfile -t availableEnvs < <(_dsb_tf_get_env_names)
  local envCount=${#availableEnvs[@]}

  if [ "${envCount}" -eq 0 ]; then
    _dsb_e "No environments found."
    return 1
  fi

  local returnCode=0
  local successCount=0
  local failCount=0

  _dsb_i "Linting all environments ..."
  for envName in "${availableEnvs[@]}"; do
    _dsb_i ""
    _dsb_i "Linting environment: ${envName}"
    _dsb_d "linting environment: ${envName}"
    if ! _dsb_tf_run_tflint "${envName}"; then
      _dsb_tf_error_push "tflint failed for environment: ${envName}"
      returnCode=1
      ((failCount++))
    else
      ((successCount++))
    fi
  done

  _dsb_i ""
  _dsb_i "Lint all summary: ${successCount} succeeded, ${failCount} failed out of ${envCount}"
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_e "Some environments failed linting."
  else
    _dsb_i "Done."
  fi
  return "${returnCode}"
}

# what:
#   lint module root and all examples in a module repo
# input:
#   none
# on info:
#   status messages are printed
# returns:
#   exit code directly
_dsb_tf_lint_all_module() {
  _dsb_d "called"
  local returnCode=0

  _dsb_i "Linting module root and all examples ..."

  _dsb_tf_lint_module_root
  local rootRC=$?
  if [ "${rootRC}" -ne 0 ]; then
    returnCode=1
  fi

  _dsb_tf_lint_examples
  local examplesRC=$?
  if [ "${examplesRC}" -ne 0 ]; then
    returnCode=1
  fi

  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_push "lint-all failed"
  else
    _dsb_i "Done."
  fi
  return "${returnCode}"
}

###################################################################################################
#
# Clean functions
#
###################################################################################################

# what:
#   returns an array of dot directories of given type
#   looks through the current directory, environment directories, main directory and module directories
# input:
#   $1: type of dot directory (.terraform or .tflint or all)
# on info:
#   nothing
# returns:
#   array of dot directories
_dsb_tf_get_dot_dirs() {
  local searchForType="${1}"
  local searchForDirType=""
  local -a dotDirs=()

  if [ "${searchForType}" = ".terraform" ]; then
    searchForDirType=".terraform"
  elif [ "${searchForType}" = ".tflint" ]; then
    searchForDirType=".tflint"
  elif [ "${searchForType}" = "all" ]; then
    # inception
    local -a dotDirsTerraform=()
    mapfile -t dotDirsTerraform < <(_dsb_tf_get_dot_dirs ".terraform")
    local -a dotDirsTflint=()
    mapfile -t dotDirsTflint < <(_dsb_tf_get_dot_dirs ".tflint")
    dotDirs=("${dotDirsTerraform[@]}" "${dotDirsTflint[@]}")
  else
    return 1
  fi

  if [ "${searchForType}" != "all" ]; then
    local -a searchInDirs=()

    if [ "${_dsbTfRepoType}" == "module" ]; then
      # Module repo: search root + example directories
      searchInDirs+=("${_dsbTfRootDir}")
      if declare -p _dsbTfExamplesDirList &>/dev/null; then
        local _exVal
        for _exVal in "${_dsbTfExamplesDirList[@]}"; do
          searchInDirs+=("${_exVal}")
        done
      fi
    else
      # Project repo: search root + envs + main + modules
      local -a envDirs
      mapfile -t envDirs < <(_dsb_tf_get_env_dirs)
      local envDirsCount=${#envDirs[@]}

      local -a moduleDirs
      mapfile -t moduleDirs < <(_dsb_tf_get_module_dirs)
      local moduleDirsCount=${#moduleDirs[@]}

      searchInDirs+=("${_dsbTfRootDir}")
      if [ "${envDirsCount}" -gt 0 ]; then
        searchInDirs+=("${envDirs[@]}")
      fi
      searchInDirs+=("${_dsbTfMainDir}")
      if [ "${moduleDirsCount}" -gt 0 ]; then
        searchInDirs+=("${moduleDirs[@]}")
      fi
    fi

    local dir
    for dir in "${searchInDirs[@]}"; do
      if [ -d "${dir}/${searchForDirType}" ]; then
        dotDirs+=("${dir}/${searchForDirType}")
      fi
    done
  fi

  local dotDirsCount=${#dotDirs[@]}

  if [ "${dotDirsCount}" -gt 0 ]; then
    printf "%s\n" "${dotDirs[@]}"
  fi
}

# what:
#   removes dot directories from the current directory, environment directories, main directory and module directories
#   if $1 is set to "terraform", it will remove .terraform directories
#   if $1 is set to "tflint", it will remove .tflint directories
# input:
#   $1: type of dot directory (.terraform or .tflint or all)
# on info:
#   status messages are printed
# returns:
#   exit code directly
_dsb_tf_clean_dot_directories() {
  local returnCode=0
  local searchForType="${1}"
  local searchForDirType=""

  if [ "${searchForType}" = "terraform" ]; then
    searchForDirType=".terraform"
  elif [ "${searchForType}" = "tflint" ]; then
    searchForDirType=".tflint"
  elif [ "${searchForType}" = "all" ]; then
    searchForDirType="all"
  else
    return 1
  fi

  # this also enumerates directories
  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  # shellcheck disable=SC2181 # inline var assignment requires $?
  if [ $? -ne 0 ]; then
    _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
    return 1 # caller reads returnCode
  fi

  _dsb_d "start looking for '${searchForDirType}' directories"

  local -a dotDirs
  mapfile -t dotDirs < <(_dsb_tf_get_dot_dirs "${searchForDirType}")
  local dotDirsCount=${#dotDirs[@]}

  _dsb_d "dotDirsCount: ${dotDirsCount}"

  if [ "${dotDirsCount}" -eq 0 ]; then
    _dsb_i "No '${searchForDirType}' directories found."
    _dsb_i "  nothing to clean"
    return 0
  fi

  _dsb_i "Ready to delete the following '${searchForDirType}' directories:"
  local dotDir
  for dotDir in "${dotDirs[@]}"; do
    _dsb_i "  - $(_dsb_tf_get_rel_dir "${dotDir}")"
  done

  local userInput idx
  local gotValidInput=0
  while [ "${gotValidInput}" -ne 1 ]; do
    read -r -p "Proceed with deletion? [y/n]: " userInput
    echo -en "\033[1A\033[2K" # clear the current console line
    if [ "${userInput}" = "y" ] || [ "${userInput}" = "Y" ]; then
      break
    elif [ "${userInput}" = "n" ] || [ "${userInput}" = "N" ]; then
      _dsb_i "Operation cancelled."
      return 0
    fi
  done

  _dsb_i "Deleting '${searchForDirType}' directories ..."

  returnCode=0
  for idx in "${!dotDirs[@]}"; do
    local dotDir="${dotDirs[idx]}"
    if ! rm -rf "${dotDir}"; then
      _dsb_e "Failed to delete: $(_dsb_tf_get_rel_dir "${dotDir}")"
      returnCode=1
    fi
  done

  # In module repos, also delete .terraform.lock.hcl files (they're gitignored artifacts)
  if [ "${_dsbTfRepoType}" == "module" ] && { [ "${searchForDirType}" = ".terraform" ] || [ "${searchForDirType}" = "all" ]; }; then
    local -a lockFileDirs=("${_dsbTfRootDir}")
    if declare -p _dsbTfExamplesDirList &>/dev/null; then
      local _exLockVal
      for _exLockVal in "${_dsbTfExamplesDirList[@]}"; do
        lockFileDirs+=("${_exLockVal}")
      done
    fi
    local lockDir
    for lockDir in "${lockFileDirs[@]}"; do
      if [ -f "${lockDir}/.terraform.lock.hcl" ]; then
        _dsb_i "  Deleting lock file: $(_dsb_tf_get_rel_dir "${lockDir}/.terraform.lock.hcl")"
        if ! rm -f "${lockDir}/.terraform.lock.hcl"; then
          _dsb_e "Failed to delete lock file: $(_dsb_tf_get_rel_dir "${lockDir}/.terraform.lock.hcl")"
          returnCode=1
        fi
      fi
    done
  fi

  if [ "${returnCode}" -eq 0 ]; then
    _dsb_i "Done."
  else
    _dsb_e "Some delete operation(s) failed, please review the output above."
  fi

  _dsb_d "done"


  return "${returnCode}"
}

###################################################################################################
#
# Upgrade functions
#
###################################################################################################

# what:
#   returns the latest version of terraform on the form vX.Y.Z
# input:
#   none
# on info:
#   nothing
# returns:
#   latest version tag of terraform in the GitHub repo hashicorp/terraform
_dsb_tf_get_latest_terraform_version_tag() {
  gh api \
    -H "Accept: application/vnd.github.v3+json" \
    '/repos/hashicorp/terraform/releases/latest' \
    --jq '.tag_name'
}

# TODO: need this?
# _dsb_tf_get_all_terraform_versions() {
#   gh api \
#     -H "Accept: application/vnd.github.v3+json" \
#     '/repos/hashicorp/terraform/releases?per_page=100' \
#     --paginate \
#     --jq '.[].tag_name | select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))'
# }

# what:
#   returns the latest version of tflint on the form X.Y.Z
# input:
#   none
# on info:
#   nothing
# returns:
#   latest version tag of tflint in the GitHub repo terraform-linters/tflint
_dsb_tf_get_latest_tflint_version() {
  gh api \
    -H "Accept: application/vnd.github.v3+json" \
    '/repos/terraform-linters/tflint/releases/latest' \
    --jq '.tag_name'
}

# TODO: need this?
# _dsb_tf_get_all_tflint_versions() {
#   gh api \
#     -H "Accept: application/vnd.github.v3+json" \
#     '/repos/terraform-linters/tflint/releases?per_page=100' \
#     --paginate \
#     --jq '.[].tag_name | select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))'
# }

# what:
#   given a current version and a latest version, returns the current version or the bumped version
#   the function is able to handle partial semver versions and version numbers with x as wildcard
#   examples:
#     1.2.3 -> 1.2.4
#     1.2 -> 1.3
#     1 -> 2
#     1.2.x -> 1.3.x
#     1.x -> 2.x
#     1.2 -> 1.2
#     1.2.x -> 1.2.x
#     1.x -> 1.x
# input:
#   $1: current version
#   $2: latest version
# on info:
#   nothing
# returns:
#   echos the resolved version
_dsb_tf_resolve_bump_version() {
  local currentVersion="${1}" # can be multiple formats: 1.2.3, 1.2, 1, 1.2.x, 1.x, 1.2
  local latestVersion="${2}"  # expect full semver version

  local currentMajorVersion currentMinorVersion currentPatchVersion
  local latestMajorVersion latestMinorVersion latestPatchVersion

  # will be 1 for all cases of 1.2.3, 1.2, 1, 1.2.x, 1.x, 1.2
  currentMajorVersion="$(_dsb_tf_semver_get_major_version "${currentVersion}")" || return 1

  # will be 2 for 1.2.3, 2 for 1.2, "" for 1, 2 for 1.2.x, x for 1.x, 2 for 1.2
  currentMinorVersion="$(_dsb_tf_semver_get_minor_version "${currentVersion}")" || return 1

  # will be 3 for 1.2.3, "" for 1.2, "" for 1, x for 1.2.x, "" for 1.x, "" for 1.2
  currentPatchVersion="$(_dsb_tf_semver_get_patch_version "${currentVersion}")" || return 1

  # full semver version
  latestMajorVersion="$(_dsb_tf_semver_get_major_version "${latestVersion}")" || return 1
  latestMinorVersion="$(_dsb_tf_semver_get_minor_version "${latestVersion}")" || return 1
  latestPatchVersion="$(_dsb_tf_semver_get_patch_version "${latestVersion}")" || return 1

  local finalVersion
  finalVersion="${currentMajorVersion}"
  if [ "${latestMajorVersion}" -gt "${currentMajorVersion}" ]; then # always a number
    finalVersion="${latestMajorVersion}"
    if [ -n "${currentMinorVersion}" ]; then
      finalVersion="${finalVersion}.${latestMinorVersion}"
      if [ -n "${currentPatchVersion}" ]; then
        finalVersion="${finalVersion}.${latestPatchVersion}"
      elif [ "${currentPatchVersion}" = "x" ]; then
        finalVersion="${finalVersion}.x"
      fi
    elif [ "${currentMinorVersion}" = "x" ]; then
      finalVersion="${finalVersion}.x"
    fi
  elif [ "${currentMajorVersion}" -gt "${latestMajorVersion}" ]; then
    finalVersion="${currentMajorVersion}.${currentMinorVersion}.${currentPatchVersion}"
  else
    # minor can be "", x or a number
    if [ -n "${currentMinorVersion}" ]; then
      if [ "${currentMinorVersion}" = "x" ]; then
        finalVersion="${finalVersion}.x"
      else
        if [ "${latestMinorVersion}" -gt "${currentMinorVersion}" ]; then
          finalVersion="${finalVersion}.${latestMinorVersion}"

          # patch can be "", x or a number
          if [ -n "${currentPatchVersion}" ]; then
            if [ "${currentPatchVersion}" = "x" ]; then
              finalVersion="${finalVersion}.x"
            else
              finalVersion="${finalVersion}.${latestPatchVersion}"
            fi
          fi
        else
          finalVersion="${finalVersion}.${currentMinorVersion}"

          # patch can be "", x or a number
          if [ -n "${currentPatchVersion}" ]; then
            if [ "${currentPatchVersion}" = "x" ]; then
              finalVersion="${finalVersion}.x"
            else
              finalVersion="${finalVersion}.${currentPatchVersion}"
            fi
          fi
        fi
      fi
    fi
  fi

  echo "${finalVersion}"
}

# what:
#   given a current version and a latest version, returns the current version or the bumped version
#   this is a wrapper function for _dsb_tf_resolve_bump_version that supports tflint version format, where version is prefixed with v
# input:
#   $1: current version
#   $2: latest version
# on info:
#   nothing
# returns:
#   echos the resolved version
_dsb_tf_resolve_tflint_bump_version() {
  local currentVersion="${1}" # expect full semver version, possibly with v prefix
  local latestVersion="${2}"  # expect full semver version, possibly with v prefix

  # if versions strings are prefixed with 'v', remove it
  currentVersion="${currentVersion#v}"
  latestVersion="${latestVersion#v}"

  _dsb_tf_resolve_bump_version "${currentVersion}" "${latestVersion}"
}

# what:
#   this function updates the version of a specified tool (either terraform or tflint) in a GitHub workflow YAML file.
#   the given latest version is compared with the currently configured version, if the given version is newer the workflow file is updated.
# input:
#   $1: tool name (terraform or tflint)
#   $2: path to the GitHub workflow file
#   $3: latest version of the tool
# on info:
#   status messages are printed
# returns:
#   exit code directly
_dsb_tf_bump_tool_in_github_workflow_file() {
  local returnCode=0
  local tool="${1}"
  local workflowFile="${2}"
  local toolLatestVersion="${3}"

  local fieldName isSemverFunction versionResolveFunction versionPrefix
  if [ "${tool}" = "terraform" ]; then
    # name of field in yaml to look for
    fieldName='terraform-version'

    # terraform version number in gh workflow file can contain x as the last number or be a full semver
    isSemverFunction='_dsb_tf_semver_is_semver_allow_x_as_wildcard_in_last'

    versionResolveFunction='_dsb_tf_resolve_bump_version'
    versionPrefix=''
  elif [ "${tool}" = "tflint" ]; then
    # name of field in yaml to look for
    fieldName='tflint-version'

    # tflint version number in gh workflow file can contain v as the first character or be a full semver
    isSemverFunction='_dsb_tf_semver_is_semver_allow_v_as_first_character'

    versionResolveFunction='_dsb_tf_resolve_tflint_bump_version' # need a different function for tflint as version is prefixed with v
    versionPrefix='v'
  else
    _dsb_internal_error "Internal error: unknown tool '${tool}'"
    return 1
  fi

  _dsb_d "called with workflowFile: ${workflowFile}"
  _dsb_d "  toolLatestVersion: ${toolLatestVersion}"

  # look up all instances of the field with the given name in the workflow file
  declare -a fieldInstances
  mapfile -t fieldInstances < <(FIELD_NAME="${fieldName}" yq eval '.. | select(has(env(FIELD_NAME))) | path | join(".")' "${workflowFile}")
  local fieldInstancesCount=${#fieldInstances[@]}

  _dsb_d "fieldInstances: ${fieldInstances[*]}"
  _dsb_d "fieldInstances count: ${fieldInstancesCount}"

  if [ "${fieldInstancesCount}" -eq 0 ]; then
    _dsb_i "    ${fieldName} version string not found"
    return 0
  fi

  local fieldPath
  for fieldPath in "${fieldInstances[@]}"; do

    _dsb_d "checking fieldPath: ${fieldPath}"

    # Skip workflow_call input definitions (these define parameter types, not actual versions)
    if [[ "${fieldPath}" == *"workflow_call.inputs"* ]]; then
      _dsb_d "skipping workflow_call input definition at: ${fieldPath}"
      continue
    fi

    # read the current version from the workflow file
    local currentVersion
    currentVersion=$(FIELD_NAME="${fieldName}" yq eval ".${fieldPath}.[env(FIELD_NAME)]" "${workflowFile}")

    _dsb_d "currentVersion: ${currentVersion}"

    # Skip template references (e.g. ${{ inputs.terraform-version }})
    # shellcheck disable=SC2016 # intentionally matching literal ${{ string
    if [[ "${currentVersion}" == *'${{'* ]]; then
      _dsb_d "skipping template reference at: ${fieldPath}"
      continue
    fi

    # test if the current version is a valid semver
    local currentVersionIsSemver=0
    if "${isSemverFunction}" "${currentVersion}"; then
      currentVersionIsSemver=1
    fi

    _dsb_d "currentVersionIsSemver: ${currentVersionIsSemver}"

    returnCode=0

    if [ "${currentVersion}" = "latest" ]; then
      # we do not touch the version if it is set to 'latest'
      _dsb_i "    ${fieldName} : set to \e[32m'latest\e[0m', not changing"
    elif [ "${currentVersionIsSemver}" -ne 1 ]; then
      _dsb_w "    ${fieldName} : '${currentVersion}' is not a valid semver, yml path: '${fieldPath}'"
    else
      _dsb_d "start resolving new version"

      local newVersion
      if ! newVersion=${versionPrefix}$("${versionResolveFunction}" "${currentVersion}" "${toolLatestVersion}"); then
        _dsb_e "    ${fieldName} : '${currentVersion}' at '${fieldPath}', unable to resolve new version"
        returnCode=1
      fi

      _dsb_d "newVersion: ${newVersion}"

      if [ "${newVersion}" = "${currentVersion}" ]; then
        _dsb_i "    ${fieldName} : already at \e[32m${newVersion}\e[0m"
      else
        _dsb_i "    ${fieldName} : from \e[90m${currentVersion}\e[0m to \e[32m${newVersion}\e[0m"
        _dsb_d "  fieldPath: ${fieldPath}"
        _dsb_d "  versionPrefix: ${versionPrefix}"
        _dsb_d "  workflowFile: ${workflowFile}"

        # actual update of version in the workflow file
        if ! yq eval ".${fieldPath}.[\"${fieldName}\"] = \"${newVersion}\"" -i "${workflowFile}"; then
          _dsb_e "      failed to update version in file."
          returnCode=1
        fi
      fi
    fi
  done

  _dsb_d "done"


  return "${returnCode}"
}

# what:
#   this function bumps the versions of terraform and tflint in all GitHub workflow files in the .github/workflows directory
# input:
#   none
# on info:
#   status messages are printed
# returns:
#   exit code directly
_dsb_tf_bump_github() {

  # we need yq to read and modify yml files
  if ! _dsb_tf_check_yq; then
    _dsbTfLogErrors=1 _dsb_e "yq check failed, please run 'tf-check-prereqs'"
    return 1 # caller reads returnCode
  fi

  # check that gh cli is installed and user is logged in
  if ! _dsb_tf_check_gh_auth; then
    return 1
  fi

  # enumerate directories with current directory as root and
  # check if the current root directory is a valid Terraform project
  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  local dirCheckStatus=$?
  if [ "${dirCheckStatus}" -ne 0 ]; then
    _dsbTfLogErrors=1 _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
    return 1 # caller reads returnCode
  fi

  _dsb_i "Bump versions in GitHub workflow file(s):"

  # lookup all github workflow files in .github/workflows
  local -a workflowFiles
  mapfile -t workflowFiles < <(_dsb_tf_get_github_workflow_files)
  local workflowFilesCount=${#workflowFiles[@]}

  if [ "${workflowFilesCount}" -eq 0 ]; then
    _dsb_i "  no github workflow files found in .github/workflows, nothing to update"
    return 0
  fi

  local terraformLatestVersionTag
  terraformLatestVersionTag=$(_dsb_tf_get_latest_terraform_version_tag)

  _dsb_d "terraform latestVersion tag: ${terraformLatestVersionTag}"

  local terraformLatestVersion="${terraformLatestVersionTag:1}" # ex. 'v1.5.7' becomes '1.5.7'

  local tflintLatestVersion
  tflintLatestVersion=$(_dsb_tf_get_latest_tflint_version)

  _dsb_i "  terraform latest version is : ${terraformLatestVersionTag}"
  _dsb_i "  tflint latest version is    : ${tflintLatestVersion}"

  # loop through all the workflow files and bump versions where needed
  local returnCode=0
  local workflowFile
  for workflowFile in "${workflowFiles[@]}"; do
    _dsb_i "  checking file: $(_dsb_tf_get_rel_dir "${workflowFile}")"

    _dsb_tf_bump_tool_in_github_workflow_file "terraform" "${workflowFile}" "${terraformLatestVersion}"
    local _toolRC1=$?
    returnCode=$((returnCode + _toolRC1))

    _dsb_tf_bump_tool_in_github_workflow_file "tflint" "${workflowFile}" "${tflintLatestVersion}"
    local _toolRC2=$?
    returnCode=$((returnCode + _toolRC2))
  done

  _dsb_i "Done."
  returnCode=$?

  _dsb_d "done"


  return "${returnCode}"
}

# what:
#   returns all hcl blocks of a given type found in a given list of files
#   data recorded for each hcl block
#     - file where declared
#     - block address ex. module.my_module
#     - value of the source field in the block
#     - value of the version field in the block
# input:
#   $1: hcl block type to look for (ex. module. or plugin.)
#   $2: name of global array variable where the list of files to search in is stored
# on info:
#   nothing
# returns:
#   in case of failure, returns exit code directly
#   returns the following global arrays:
#     - _dsbTfHclMetaAllSources
#         key: file|hclBlockAddress
#         value: value of the source field
#     - _dsbTfHclMetaAllVersions
#         key: file|hclBlockAddress
#         value: value of the version field
_dsb_tf_enumerate_hcl_blocks_meta() {
  local hclBlockTypeToLookFor="${1}"
  local globalFileListVariableName="${2}"

  _dsb_d "called with hclBlockTypeToLookFor: ${hclBlockTypeToLookFor}"
  _dsb_d "  globalFileListVariableName: ${globalFileListVariableName}"

  # outputs in global associative arrays from this function
  declare -gA _dsbTfHclMetaAllSources=()  # associative array, key: file|hclBlockAddress, value: value of the source field
  declare -gA _dsbTfHclMetaAllVersions=() # associative array, key: file|hclBlockAddress, value: value of the version field

  # check if file list is declared, empty array is ok
  local -n hclFilesRef="${globalFileListVariableName}"
  if [ -z "${!hclFilesRef:-}" ]; then
    _dsb_internal_error "Internal error: expected hclFilesRef => ${globalFileListVariableName} to be declared"
    return 1
  fi

  # copy the global array to a local array
  local key
  local -a hclFiles=()
  for key in "${!hclFilesRef[@]}"; do
    hclFiles+=("${hclFilesRef[${key}]}")
  done

  _dsb_d "enumerating '${hclBlockTypeToLookFor}' configuration in ${#hclFiles[@]} files"

  local hclFile
  for hclFile in "${hclFiles[@]}"; do

    _dsb_d "checking file: $(_dsb_tf_get_rel_dir "${hclFile}" || :)"

    local -a hclBlocks=()
    mapfile -t hclBlocks < <(hcledit block list --file "${hclFile}")

    _dsb_d "  found ${#hclBlocks[@]} num of HCL blocks"

    # if no hcl blocks found, skip to next file
    if [[ ${#hclBlocks[@]} -eq 0 ]]; then
      continue
    fi

    # filter hclBlocks array for only strings starting with '<hclBlockTypeToLookFor>.' (ex. module. or plugin.)
    #   and store the part after . as key in an associative array
    local hclBlockAddress hclBlockInstanceName hclBlockSourceAttr hclBlockVersionAttr
    for hclBlockAddress in "${hclBlocks[@]}"; do

      # not interested in blocks that are not of the type we are looking for
      if [[ ! ${hclBlockAddress} =~ ^${hclBlockTypeToLookFor}\. ]]; then
        continue
      fi

      _dsb_d "  ${hclBlockAddress} is a '${hclBlockTypeToLookFor}' type block"

      hclBlockInstanceName=$(echo "${hclBlockAddress}" | awk -F. '{print $2}') # the part after the first dot

      if ! hclBlockSourceAttr=$(hcledit attribute get "${hclBlockAddress}.source" --file "${hclFile}"); then
        _dsb_d "  source field not found in block: ${hclBlockAddress}"
        hclBlockSourceAttr=""
      else
        hclBlockSourceAttr=${hclBlockSourceAttr//\"/} # remove double quotes from strings
      fi

      if ! hclBlockVersionAttr=$(hcledit attribute get "${hclBlockAddress}.version" --file "${hclFile}"); then
        _dsb_d "  version field not found in block: ${hclBlockAddress}"
        hclBlockVersionAttr=""
      else
        hclBlockVersionAttr=${hclBlockVersionAttr//\"/} # remove double quotes from strings
      fi

      _dsb_d "  hclBlockInstanceName: ${hclBlockInstanceName}"
      _dsb_d "    hclBlockAddress: ${hclBlockAddress}"
      _dsb_d "    hclBlockSourceAttr: ${hclBlockSourceAttr}"
      _dsb_d "    hclBlockVersionAttr: ${hclBlockVersionAttr}"

      # record the source and version values in global associative arrays (outputs of this function)
      _dsbTfHclMetaAllSources["${hclFile}|${hclBlockAddress}"]="${hclBlockSourceAttr}"
      _dsbTfHclMetaAllVersions["${hclFile}|${hclBlockAddress}"]="${hclBlockVersionAttr}"

    done # end of hclBlocks loop
  done   # end of files list loop

  _dsb_d "found ${#_dsbTfHclMetaAllSources[@]} num of '${hclBlockTypeToLookFor}' blocks"

  return 0
}

# what:
#   this function goes through all tf files in the project and looks for module declarations with the official registry as source
#   sources considered official are those that start with a letter or number and have the format "namespace/name/provider"
#   data recorded for each module:
#     - file where declared
#     - module block name, the name of the module block in the file, ex. module.my_module
#     - source, the source of the module, ex. Azure/naming/azurerm
#     - version, the version of the module, ex. 1.2.3 or '~> 1.2'
#   note:
#     it's assumed that _dsb_tf_enumerate_directories has been called, _dsbTfFilesList is required to be populated
# input:
#   none
# on info:
#   nothing
# returns:
#   in case of failure, returns exit code directly
#   returns the following global arrays:
#     - _dsbTfRegistryModulesAllSources
#     - _dsbTfRegistryModulesAllVersions
_dsb_tf_enumerate_registry_modules_meta() {

  # outputs in global variables from this function
  declare -gA _dsbTfRegistryModulesAllSources=()  # associative array, key: file|moduleBlockName, value: value of the source field
  declare -gA _dsbTfRegistryModulesAllVersions=() # associative array, key: file|moduleBlockName, value: value of the version field

  # find all module blocks in tf files and get the source and version attributes
  if ! _dsb_tf_enumerate_hcl_blocks_meta "module" "_dsbTfFilesList"; then # $1: hclBlockTypeToLookFor, $2: globalFileListVariableName
    return 1
  fi

  _dsb_d "allSources count: ${#_dsbTfHclMetaAllSources[@]}"
  _dsb_d "allVersions count: ${#_dsbTfHclMetaAllVersions[@]}"

  # loop through all blocks, get source and version values, then filter out the registry modules
  local key
  for key in "${!_dsbTfHclMetaAllSources[@]}"; do

    local moduleSource="${_dsbTfHclMetaAllSources[${key}]}"
    local moduleVersion="${_dsbTfHclMetaAllVersions[${key}]}"

    # key is a string in the format "file|moduleBlockName"
    local hclFile="${key%%|*}"
    local hclBlockAddress="${key##*|}"

    _dsb_d "checking file: $(_dsb_tf_get_rel_dir "${hclFile}" || :)"
    _dsb_d "  hclBlockAddress: ${hclBlockAddress}"
    _dsb_d "  moduleSource: ${moduleSource}"
    _dsb_d "  moduleVersion: ${moduleVersion}"

    if [[ -z ${moduleSource} ]]; then
      # if hclBlockSourceAttr is empty, skip to next block instance
      _dsb_w "  'source' argument is empty for ${hclBlockAddress} in $(_dsb_tf_get_rel_dir "${hclFile}")"
      continue
    fi

    # now comes the actual filtering of the module sources
    # if module source value starts with a dot or double dot, it is a local module
    if [[ ${moduleSource} =~ ^\.{1,2} ]]; then
      _dsb_d "  ignoring local module."
      continue # to next module
    else
      if [[ ${moduleSource} =~ ^[[:alnum:]] && ${moduleSource} =~ ^[^./]+/[^./]+/[^./]+$ ]]; then
        # if module source value starts with a letter
        #   or number and has the format "namespace/name/provider"
        #   and not dot in the value
        _dsb_d "  identified as registry module."

        if [ -z "${moduleVersion}" ]; then
          _dsb_internal_error "Internal error: module version is empty" \
            "  file: $(_dsb_tf_get_rel_dir "${hclFile}" || :)" \
            "  module: ${hclBlockAddress}" \
            "  source: ${moduleSource}"
          return 1
        fi

        # record the module source and version in global associative arrays
        _dsbTfRegistryModulesAllSources["${hclFile}|${hclBlockAddress}"]="${moduleSource}"
        _dsbTfRegistryModulesAllVersions["${hclFile}|${hclBlockAddress}"]="${moduleVersion}"
      else
        # ignore other module sources

        # should be warn, could potentially be private registry module
        if [ -n "${moduleVersion}" ]; then
          _dsb_w "  Ignoring module as it doesn't seem to be sourced from the official HashiCorp registry."
          _dsb_w "    file: $(_dsb_tf_get_rel_dir "${hclFile}")"
          _dsb_w "    module: ${hclBlockAddress}"
          _dsb_w "    version: ${moduleVersion}"
        fi
        continue # to next module
      fi
    fi
  done # end of loop through all blocks

  return 0
}

# what:
#   this function gets the latest version of a module from the Terraform registry
# input:
#   $1: module source in the format "namespace/name/provider"
# on info:
#   nothing
# returns:
#   returns the latest version in the global variable _dsbTfLatestRegistryModuleVersion
#   returns 0 on success, 1 on failure
_dsb_tf_get_latest_registry_module_version() {
  local moduleSource="${1}"
  local moduleNamespace moduleProvider moduleName latestVersionResponse latestModuleVersion

  declare -g _dsbTfLatestRegistryModuleVersion="" # global variable to return the latest version

  _dsb_d "moduleSource: ${moduleSource}"

  moduleNamespace=$(echo "${moduleSource}" | awk -F/ '{print $1}')
  moduleName=$(echo "${moduleSource}" | awk -F/ '{print $2}')
  moduleProvider=$(echo "${moduleSource}" | awk -F/ '{print $3}')

  _dsb_d "moduleNamespace: ${moduleNamespace}"
  _dsb_d "moduleName: ${moduleName}"
  _dsb_d "moduleProvider: ${moduleProvider}"

  local tfBaseURL="https://registry.terraform.io"
  local tfSource="$moduleNamespace/$moduleName/$moduleProvider"

  # Latest Version for a Specific Module Provider
  #   <base_url>/:namespace/:name/:provider
  #   curl https://registry.terraform.io/v1/modules/hashicorp/consul/aws
  # ref. https://developer.hashicorp.com/terraform/registry/api-docs#latest-version-for-a-specific-module-provider
  if ! latestVersionResponse=$(curl -s -f "${tfBaseURL}/v1/modules/${tfSource}"); then
    _dsb_d "curl call failed!"
    return 1
  fi

  _dsb_d "latestVersionResponse: $(echo "${latestVersionResponse}" | jq -r 'del(.root) | del(.. | .readme?)' 2>/dev/null || :)"

  latestModuleVersion=$(echo "$latestVersionResponse" | jq -r '.version')

  if [ -z "${latestModuleVersion}" ]; then
    return 1
  fi

  _dsbTfLatestRegistryModuleVersion="${latestModuleVersion}"
  return 0
}

# what:
#   this function bumps the versions of registry modules in all tf files in the project
#   the function looks up the latest version of each module in the Terraform registry and updates the version in the tf files
#   note:
#     blindly updates the version to the latest version (if there's a difference), version constraints and partial version values are not considered
# input:
#   none
# on info:
#   status messages are printed
# returns:
#   exit code directly
_dsb_tf_bump_registry_module_versions() {
  local returnCode=0

  # check if the current root directory is a valid Terraform project
  # _dsb_tf_check_current_dir calls _dsb_tf_enumerate_directories, so we don't need to call it again in this function
  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  # shellcheck disable=SC2181 # inline var assignment requires $?
  if [ $? -ne 0 ]; then
    _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
    return 1
  fi

  # we need these specific tools (on-demand, not required globally)
  if ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_curl ||
    ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_jq ||
    ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_hcledit; then
    _dsb_e "Required tools missing for module version bumping, please run 'tf-check-tools'"
    return 1
  fi

  _dsb_i "Bump versions of registry modules in all tf files in the project:"

  # locate registry modules in the project
  _dsb_i "  Enumerating registry modules ..."
  if ! _dsb_tf_enumerate_registry_modules_meta; then
    _dsb_e "Failed to enumerate registry modules meta data, consider enabling debug logging"
    return 1 # caller reads returnCode
  fi

  _dsb_d "allSources count: ${#_dsbTfRegistryModulesAllSources[@]}"
  _dsb_d "allVersions count: ${#_dsbTfRegistryModulesAllVersions[@]}"

  local modulesSourcesCount=${#_dsbTfRegistryModulesAllSources[@]} # populate by _dsb_tf_enumerate_registry_modules_meta
  if [ "${modulesSourcesCount}" -eq 0 ]; then
    _dsb_i "No registry modules found in the project, nothing to update ☀️"
    return 0
  fi

  local -a uniqueSources=()
  mapfile -t uniqueSources < <(printf "%s\n" "${_dsbTfRegistryModulesAllSources[@]}" | sort -u)

  _dsb_d "unique sources count: ${#uniqueSources[@]}"

  _dsb_i "  Looking up latest versions for registry modules ..."
  local -A registryModulesLatestVersions=()
  local moduleSource
  for moduleSource in "${uniqueSources[@]}"; do

    _dsb_i "   - ${moduleSource}"

    if ! _dsb_tf_get_latest_registry_module_version "${moduleSource}"; then
      _dsb_e "Failed to get latest version for module: ${moduleSource}"
      returnCode=1
      registryModulesLatestVersions["${moduleSource}"]="" # empty string to indicate failure
    else
      # _dsb_tf_get_latest_registry_module_version returns the latest version in _dsbTfLatestRegistryModuleVersion
      local moduleLatestVersion
      moduleLatestVersion="${_dsbTfLatestRegistryModuleVersion:-}"

      if [ -z "${moduleLatestVersion}" ]; then
        _dsb_internal_error "Internal error: expected to find a version string, but did not" \
          "  expected in: _dsbTfLatestRegistryModuleVersion" \
          "  moduleSource: ${moduleSource}"
        returnCode=1
        registryModulesLatestVersions["${moduleSource}"]="" # empty string to indicate failure
      else
        _dsb_d "found latest version for module: ${moduleSource} -> ${moduleLatestVersion}"
        registryModulesLatestVersions["${moduleSource}"]="${moduleLatestVersion}"
      fi
    fi
  done # end of uniqueSources loop

  _dsb_i "  Updating registry modules declarations as needed ..."

  # loop all registry module declarations and upgrade version as needed
  local key
  for key in "${!_dsbTfRegistryModulesAllSources[@]}"; do # populate by _dsb_tf_enumerate_registry_modules_meta

    local moduleSource="${_dsbTfRegistryModulesAllSources[${key}]}"
    local moduleVersion="${_dsbTfRegistryModulesAllVersions[${key}]}"
    local latestVersion=${registryModulesLatestVersions["${moduleSource}"]}

    # key is a string in the format "file|moduleBlockName"
    local tfFile="${key%%|*}"
    local hclBlockAddress="${key##*|}"

    _dsb_d "upgrading in file: $(_dsb_tf_get_rel_dir "${tfFile}")"
    _dsb_d "  hclBlockAddress: ${hclBlockAddress}"
    _dsb_d "  moduleSource: ${moduleSource}"
    _dsb_d "  moduleVersion: ${moduleVersion}"
    _dsb_d "  latestVersion: ${latestVersion}"

    # resolve line number of the module declaration in the file to create a link to the file (clickable in VS Code terminal)
    local moduleName moduleDeclaration moduleDeclarationLineNumber vsCodeFileLink
    moduleName=$(echo "${hclBlockAddress}" | awk -F. '{print $2}')                                                         # block name is on the form 'module.my_module', we need just the name part
    moduleDeclaration="module \"${moduleName}\""                                                                           # we search for 'module "my_module"'
    moduleDeclarationLineNumber=$(grep -n "${moduleDeclaration}" "${tfFile}" | "${_dsbTfCutCmd}" -d: -f1 2>/dev/null || :) # extract line number
    if [ -n "${moduleDeclarationLineNumber}" ]; then
      vsCodeFileLink="($(_dsb_tf_get_rel_dir "${tfFile}")#${moduleDeclarationLineNumber})"
    fi

    # if resolving latest versions failed previously, skip upgrading version
    if [ -z "${latestVersion}" ]; then
      _dsb_w "   - ${moduleSource} : latest version is unknown, skipping ${vsCodeFileLink:-}"
      continue
    fi

    # assume declared version is older and ignores version constraints or partial versions
    # TODO: this could be improved to not blindly overwrite version
    if [[ ${moduleVersion} != "${latestVersion}" ]]; then

      _dsb_i "   - ${moduleSource} : \e[90m${moduleVersion}\e[0m => \e[32m${latestVersion}\e[0m  ${vsCodeFileLink:-}"

      # use hcledit to update the version field
      if ! hcledit attribute set "${hclBlockAddress}.version" "\"${latestVersion}\"" --update --file "${tfFile}"; then
        _dsb_e "Failed to update version, ${vsCodeFileLink:-}"
        returnCode=1
      fi
    else
      _dsb_d "Not changing ${moduleSource} : ${latestVersion} in ${tfFile}"
    fi
  done # end of loop through all registry modules

  _dsb_i "Done."

  _dsb_d "done"


  return "${returnCode}"
}

# what:
#   this function gets the latest version of a given tflint plugin from GitHub
# input:
#   $1: plugin source in the format "github.com/terraform-linters/tflint-ruleset-azurerm"
# on info:
#   nothing
# returns:
#   returns the latest version in the global variable _dsbTfLatestTflintPluginVersion
#   returns 0 on success, 1 on failure
_dsb_tf_get_latest_tflint_plugin_version() {
  local pluginSource="${1}" # github repo url, ex. "github.com/terraform-linters/tflint-ruleset-azurerm"

  declare -g _dsbTfLatestTflintPluginVersion="" # global variable to return the latest version

  _dsb_d "pluginSource: ${pluginSource}"

  # construct pluginRepo from pluginSource
  local pluginRepo
  pluginRepo=$(echo "${pluginSource}" | awk -F/ '{print $2 "/" $3}')
  local tflintPluginApiEndpoint="repos/${pluginRepo}/releases/latest"

  _dsb_d "pluginRepo: ${pluginRepo}"
  _dsb_d "tflintPluginApiEndpoint: ${tflintPluginApiEndpoint}"

  local latestVersionTag
  if ! latestVersionTag=$(gh api "${tflintPluginApiEndpoint}" --jq '.tag_name'); then
    _dsb_d "GitHub API call failed!"
    return 1
  fi

  _dsb_d "latestVersionTag: ${latestVersionTag}"

  # latestVersionTag is expected to be a string on the form 'v1.5.7'
  # remove the 'v' from the beginning to get the version string
  local latestPluginVersion="${latestVersionTag#v}"

  _dsb_d "latestPluginVersion: ${latestPluginVersion}"

  if [ -z "${latestPluginVersion}" ]; then
    return 1
  fi

  _dsbTfLatestTflintPluginVersion="${latestPluginVersion}"
  return 0
}

# what:
#   this function bumps the versions of tflint plugins in all tflint configuration files in the project
#   the function looks up the latest version of each plugin in GitHub and updates the version in the tflint files
#   note:
#     blindly updates the version to the latest version (if there's a difference), version constraints and partial version values are not considered
# input:
#   none
# on info:
#   status messages are printed
# returns:
#   exit code directly
_dsb_tf_bump_tflint_plugin_versions() {
  local returnCode=0

  # check if the current root directory is a valid Terraform project
  # _dsb_tf_check_current_dir calls _dsb_tf_enumerate_directories, so we don't need to call it again in this function
  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  # shellcheck disable=SC2181 # inline var assignment requires $?
  if [ $? -ne 0 ]; then
    _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
    return 1
  fi

  # we need several tools to be available: curl, jq, hcledit
  if ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_curl ||
    ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_jq ||
    ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_hcledit; then
    _dsb_e "Tools check failed, please run 'tf-check-tools'"
    return 1 # caller reads returnCode
  fi

  # check that gh cli is installed and user is logged in
  if ! _dsb_tf_check_gh_auth; then
    _dsb_e "GitHub cli check failed, please run 'tf-check-gh-auth'"
    return 1
  fi

  _dsb_i "Bump versions of plugins in all tflint configuration files in the project:"

  # locate tflint plugins in the project
  _dsb_i "  Enumerating tflint plugins ..."
  if ! _dsb_tf_enumerate_hcl_blocks_meta "plugin" "_dsbTfLintConfigFilesList"; then # $1: hclBlockTypeToLookFor, $2: globalFileListVariableName
    _dsb_e "Failed to enumerate tflint plugins meta data, consider enabling debug logging"
    return 1 # caller reads returnCode
  fi

  _dsb_d "allSources count: ${#_dsbTfHclMetaAllSources[@]}"
  _dsb_d "allVersions count: ${#_dsbTfHclMetaAllVersions[@]}"
  _dsb_d "allSources: ${_dsbTfHclMetaAllSources[*]}"

  local pluginsSourcesCount=${#_dsbTfHclMetaAllSources[@]} # populate by _dsb_tf_enumerate_hcl_blocks_meta

  _dsb_d "pluginsSourcesCount: ${pluginsSourcesCount}"

  if [ "${pluginsSourcesCount}" -eq 0 ]; then
    _dsb_i "No tflint plugins found in the project, nothing to update ☀️"
    return 0
  fi

  local -a uniqueSources=()
  mapfile -t uniqueSources < <(printf "%s\n" "${_dsbTfHclMetaAllSources[@]}" | sort -u)

  _dsb_d "unique sources count: ${#uniqueSources[@]}"
  _dsb_d "unique sources: ${uniqueSources[*]}"

  _dsb_i "  Looking up latest versions for tflint plugins ..."
  local -A tflintPluginsLatestVersions=()
  local pluginSource
  for pluginSource in "${uniqueSources[@]}"; do

    if [[ -z ${pluginSource} ]]; then
      _dsb_d "  found empty source, skipping"
      continue
    fi

    _dsb_i "   - ${pluginSource}"

    if ! _dsb_tf_get_latest_tflint_plugin_version "${pluginSource}"; then
      _dsb_e "Failed to get latest version for module: ${pluginSource}"
      returnCode=1
      tflintPluginsLatestVersions["${pluginSource}"]="" # empty string to indicate failure
    else
      # _dsb_tf_get_latest_tflint_plugin_version returns the latest version in _dsbTfLatestTflintPluginVersion
      local pluginLatestVersion
      pluginLatestVersion="${_dsbTfLatestTflintPluginVersion:-}"

      if [ -z "${pluginLatestVersion}" ]; then
        _dsb_internal_error "Internal error: expected to find a version string, but did not" \
          "  expected in: _dsbTfLatestTflintPluginVersion" \
          "  pluginSource: ${pluginSource}"
        returnCode=1
        tflintPluginsLatestVersions["${pluginSource}"]="" # empty string to indicate failure
      else
        _dsb_d "found latest version for plugin: ${pluginSource} -> ${pluginLatestVersion}"
        tflintPluginsLatestVersions["${pluginSource}"]="${pluginLatestVersion}"
      fi
    fi
  done # end of uniqueSources loop

  _dsb_i "  Updating tflint plugin declarations as needed ..."

  # loop all tflint plugin declarations and upgrade version as needed
  local key
  for key in "${!_dsbTfHclMetaAllSources[@]}"; do # populate by _dsb_tf_enumerate_hcl_blocks_meta

    local pluginSource="${_dsbTfHclMetaAllSources[${key}]}"

    if [[ -z ${pluginSource} ]]; then
      _dsb_d "  found empty source, skipping"
      continue
    fi

    local pluginVersion="${_dsbTfHclMetaAllVersions[${key}]}"
    local latestVersion=${tflintPluginsLatestVersions["${pluginSource}"]}

    # key is a string in the format "file|pluginBlockName"
    local hclFile="${key%%|*}"
    local hclBlockAddress="${key##*|}"

    _dsb_d "upgrading in file: $(_dsb_tf_get_rel_dir "${hclFile}")"
    _dsb_d "  hclBlockAddress: ${hclBlockAddress}"
    _dsb_d "  pluginSource: ${pluginSource}"
    _dsb_d "  pluginVersion: ${pluginVersion}"
    _dsb_d "  latestVersion: ${latestVersion}"

    # resolve line number of the plugin declaration in the file to create a link to the file (clickable in VS Code terminal)
    local pluginName pluginDeclaration pluginDeclarationLineNumber vsCodeFileLink
    pluginName=$(echo "${hclBlockAddress}" | awk -F. '{print $2}')                                                          # block name is on the form 'plugin.my_plugin', we need just the name part
    pluginDeclaration="plugin \"${pluginName}\""                                                                            # we search for 'plugin "my_plugin"'
    pluginDeclarationLineNumber=$(grep -n "${pluginDeclaration}" "${hclFile}" | "${_dsbTfCutCmd}" -d: -f1 2>/dev/null || :) # extract line number
    if [ -n "${pluginDeclarationLineNumber}" ]; then
      vsCodeFileLink="($(_dsb_tf_get_rel_dir "${hclFile}")#${pluginDeclarationLineNumber})"
    fi

    # if resolving latest versions failed previously, skip upgrading version
    if [ -z "${latestVersion}" ]; then
      _dsb_w "   - ${pluginSource} : latest version is unknown, skipping ${vsCodeFileLink:-}"
      continue
    fi

    # assume declared version is older and ignores version constraints or partial versions
    # TODO: this could be improved to not blindly overwrite version
    if [[ ${pluginVersion} != "${latestVersion}" ]]; then

      _dsb_i "   - ${pluginSource}"
      _dsb_i "     \e[90m${pluginVersion}\e[0m => \e[32m${latestVersion}\e[0m"
      if [ -n "${vsCodeFileLink}" ]; then
        _dsb_i "     ${vsCodeFileLink:-}"
      fi

      # use hcledit to update the version field
      if ! hcledit attribute set "${hclBlockAddress}.version" "\"${latestVersion}\"" --update --file "${hclFile}"; then
        _dsb_e "Failed to update version, ${vsCodeFileLink:-}"
        returnCode=1
      fi
    else
      _dsb_d "Not changing ${pluginSource} : ${latestVersion} in ${hclFile}"
    fi

  done # end of loop through all tflint plugins

  _dsb_i "Done."

  _dsb_d "done"


  return "${returnCode}"
}

# what:
#   this function gets the latest version of a given Terraform provider from the Terraform registry
#   a simple caching mechanism is used to allow speed up of multiple subsequent calls
#   the cache is stored in the global associative array _dsbTfProviderVersionsCache
#   recommended usage of cache:
#     - ignoreCache=1 for stand alone calls
#     - ignoreCache=1 for the first call in a loop, then ignoreCache=0 for subsequent calls
#     - for complete call stacks, make sure to call with ignoreCache=1 at the top level
# input:
#   $1: provider source in the format "namespace/type" ex. "hashicorp/azurerm"
#   $2: optional, set to 1 to ignore cache
# on info:
#   nothing
# returns:
#   returns the latest version in the global variable _dsbTfLatestProviderVersion
_dsb_tf_get_latest_terraform_provider_version() {
  local providerSource="${1}" # on the form "namespace/type" ex. "hashicorp/azurerm"
  local ignoreCache="${2:-0}" # default is to cache to speed up subsequent calls

  declare -g _dsbTfLatestProviderVersion="" # global variable to return the latest version

  if [ -z "${providerSource}" ]; then
    _dsb_d "Provider source is empty"
    return 1
  fi

  local cacheKey="provider-${providerSource}" # used to store and lookup cached values

  if [ "${ignoreCache}" -ne 0 ] || ! declare -p _dsbTfProviderVersionsCache &>/dev/null; then
    _dsb_d "Initializing provider versions cache array"
    declare -gA _dsbTfProviderVersionsCache # global associative array to store cache values
  else
    # check if cacheKey exists in _dsbTfProviderVersionsCache
    _dsb_d "Checking cache for provider: ${providerSource}"
    if [[ -n "${_dsbTfProviderVersionsCache[${cacheKey}]+_}" ]]; then
      _dsb_d "Cache hit."
      local cachedValue="${_dsbTfProviderVersionsCache[${cacheKey:-}]}"
      _dsb_d "  cachedValue: ${cachedValue}"
      _dsbTfLatestProviderVersion="${cachedValue}"
      return 0
    fi
  fi

  local latestVersion
  if ! latestVersion=$(curl --location --silent --fail "https://registry.terraform.io/v1/providers/${providerSource}" | jq -r '.version'); then
    _dsb_d "curl call failed!"
    return 1
  fi

  _dsb_d "latestVersion: ${latestVersion}"

  # cache the latest version
  _dsbTfProviderVersionsCache["${cacheKey}"]="${latestVersion}"

  # return the latest version
  _dsbTfLatestProviderVersion="${latestVersion}"

  return 0 # caller reads _dsbTfLatestProviderVersion
}

# what:
#   this function gets the locked version of a given Terraform provider from
#   the .terraform.lock.hcl file in a given environment directory
# input:
#   $1: directory path of the environment directory
#   $2: provider source in the format "namespace/type" ex. "hashicorp/azurerm"
# on info:
#   nothing
# returns:
#   in case of failure, returns exit code directly
#   returns the locked version in the global variable _dsbTfLockfileProviderVersion
_dsb_tf_get_lockfile_provider_version() {
  local envDir="${1}"         # directory of the environment
  local providerSource="${2}" # on the form "namespace/type" ex. "hashicorp/azurerm"

  declare -g _dsbTfLockfileProviderVersion="" # global variable to return the locked version

  _dsb_d "called with"
  _dsb_d "  envDir: ${envDir}"
  _dsb_d "  providerSource: ${providerSource}"

  if [ -z "${envDir}" ] || [ -z "${providerSource}" ]; then
    _dsb_d "Environment directory or provider source is empty"
    return 1
  fi

  local lockfilePath="${envDir}/.terraform.lock.hcl"

  if [ ! -f "${lockfilePath}" ]; then
    _dsb_d "Lockfile not found: ${lockfilePath}"
    return 1
  fi

  local -a providerBlocks=()
  mapfile -t providerBlocks < <(hcledit block list --file "${lockfilePath}")
  _dsb_d "providerBlocks: ${providerBlocks[*]}"

  local providerBlock
  local blockMatchingSource=""
  for providerBlock in "${providerBlocks[@]}"; do
    # check if providerSource exist within the providerBlock string
    if [[ "${providerBlock}" == *"${providerSource}"* ]]; then
      blockMatchingSource="${providerBlock}"
      _dsb_d "found match: ${blockMatchingSource}"
      break
    fi
  done

  if [ -z "${blockMatchingSource}" ]; then
    _dsb_d "Provider block not found in lockfile: ${providerSource}"
    return 0 # not considered an error, provider might not be installed yet
  fi

  local providerVersion
  providerVersion=$(hcledit attribute get "${blockMatchingSource}.version" --file "${lockfilePath}")
  providerVersion="${providerVersion//\"/}" # strip quotes from the version string

  if [ -z "${providerVersion}" ]; then
    _dsb_d "Provider version not found in lockfile: ${providerSource}"
    return 1 # considered an error, if provider is found in lock file it should have a version
  fi

  _dsb_d "providerVersion: ${providerVersion}"

  # return the locked version
  _dsbTfLockfileProviderVersion="${providerVersion}"

  return 0 # caller reads _dsbTfLockfileProviderVersion
}

# what:
#   this function lists the latest available terraform provider versions for providers
#   either the provider configured in a single environment or all environments in the project
#   additionally, the function lists the locked versions of the providers in the .terraform.lock.hcl file
#   and the version constraints in the Terraform configuration files for the environment(s)
# input:
#   $1: optional, environment name to check, if not provided all environments are checked
# on info:
#   status messages are printed
# returns:
#   exit code directly
_dsb_tf_list_available_terraform_provider_upgrades() {
  local returnCode=0
  local envToCheck="${1:-}"

  # check if the current root directory is a valid Terraform project
  # _dsb_tf_check_current_dir calls _dsb_tf_enumerate_directories, so we don't need to call it again in this function
  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  # shellcheck disable=SC2181 # inline var assignment requires $?
  if [ $? -ne 0 ]; then
    _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
    return 1
  fi

  # we need several tools to be available: curl, jq, terraform-config-inspect
  if ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_curl ||
    ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_jq ||
    ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_terraform_config_inspect ||
    ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_hcledit; then
    _dsb_e "Tools check failed, please run 'tf-check-tools'"
    return 1 # caller reads returnCode
  fi

  _dsb_i "Available Terraform provider upgrades:"

  local -a availableEnvs=()
  if [ -n "${envToCheck}" ]; then
    availableEnvs=("${envToCheck}")
  else
    mapfile -t availableEnvs < <(_dsb_tf_get_env_names)
  fi
  local envCount=${#availableEnvs[@]}

  _dsb_d "available envs count in availableEnvs: ${envCount}"
  _dsb_d "available envs: ${availableEnvs[*]}"

  local envsDir="${_dsbTfEnvsDir}"

  if [ "${envCount}" -eq 0 ]; then
    _dsb_w "  No environments found in: ${envsDir}"
    _dsb_i "    this probably means the directory is empty."
    _dsb_i "    either create an environment or run the command from a different root directory."
    returnCode=1
  else
    # make sure to empty the provider versions lookup cache,
    # achieved by ignoring the cache in the first iteration,
    # then flag is then flipped for subsequent iterations
    local ignoreProviderVersionCache=1
    local envName
    for envName in "${availableEnvs[@]}"; do
      local envDir="${_dsbTfEnvsDirList[${envName}]}"
      _dsb_i "  Environment: ${envName}"
      _dsb_d "    envDir: ${envDir}"

      local tfConfigJson
      tfConfigJson=$(terraform-config-inspect --json "${envDir}")
      _dsb_d "    tfConfigJson: $(echo "${tfConfigJson}" | jq -r || :)"
      if [ -z "${tfConfigJson}" ]; then
        _dsb_e "    Failed to get Terraform configuration for environment: ${envName}"
        returnCode=1
        continue
      fi

      local providers provider
      providers=$(echo "${tfConfigJson}" | jq -r '.required_providers | keys[]')
      for provider in ${providers}; do
        local source version_constraints
        source=$(echo "${tfConfigJson}" | jq -r ".required_providers[\"${provider}\"].source // empty")
        version_constraints=$(echo "${tfConfigJson}" | jq -r "(.required_providers[\"${provider}\"].version_constraints // [])[] // empty")

        _dsb_d "    provider: ${provider}"
        _dsb_d "      source: ${source}"

        # if empty we assume hashicorp provider
        if [ -z "${source}" ]; then
          source="hashicorp/${provider}"
          _dsb_d "      source is empty, assuming hashicorp provider, changed to: ${source}"
        fi

        if ! _dsb_tf_get_latest_terraform_provider_version "${source}" "${ignoreProviderVersionCache}"; then
          _dsb_e "    Failed to get latest version for provider: ${source}"
          returnCode=1
        fi

        if ! _dsb_tf_get_lockfile_provider_version "${envDir}" "${source}"; then
          _dsb_e "    Failed to get locked version for provider: ${provider}"
          returnCode=1
        fi

        _dsb_i "    ${source} => \e[32m${_dsbTfLatestProviderVersion:-}\e[0m"
        _dsb_i "      Project constraint(s): ${version_constraints}"
        if [ -n "${_dsbTfLatestProviderVersion:-}" ] &&
          [ "${_dsbTfLatestProviderVersion}" == "${_dsbTfLockfileProviderVersion:-}" ]; then
          _dsb_i "      Locked version: ${_dsbTfLockfileProviderVersion:-}"
        else
          _dsb_i "      Locked version: \e[33m${_dsbTfLockfileProviderVersion:-}\e[0m"
        fi

        # flip the ignoreProviderVersionCache flag to cache the latest version for subsequent iterations
        ignoreProviderVersionCache=0

      done # end of loop through all providers

      _dsb_i ""
      _dsb_i "    to investigate further use: terraform -chdir='$(_dsb_tf_get_rel_dir "${envDir}")' providers 2>&1 | _dsb_tf_fixup_paths_from_stdin"

    done # end of loop through all environments
  fi

  _dsb_d "done"
  return "${returnCode}"
}

# what:
#   this function is a wrapper of _dsb_tf_list_available_terraform_provider_upgrades
#   it allows to specify an environment to check for provider upgrades
#   and if the not specified, it attempts to use the selected environment
# input:
#   $1: optional, environment name to check, if not provided the selected environment is used
# on info:
#   nothing, status messages indirectly from _dsb_tf_list_available_terraform_provider_upgrades
# returns:
#   exit code directly
_dsb_tf_list_available_terraform_provider_upgrades_for_env() {
  local returnCode=0
  local envToCheck="${1:-}"

  _dsb_d "called with envToCheck: ${envToCheck}"

  if [ -z "${envToCheck}" ]; then
    envToCheck=${_dsbTfSelectedEnv:-}
  fi

  if [ -z "${envToCheck}" ]; then
    _dsb_e "No environment specified and no environment selected."
    _dsb_e "  either specify environment: 'tf-show-provider-upgrades <env>'"
    _dsb_e "  or run 'tf-set-env <env>' first"
    returnCode=1
  else
    _dsb_tf_list_available_terraform_provider_upgrades "${envToCheck}"
  fi

  _dsb_d "done"
  return "${returnCode}"
}

# what:
#   this function upgrades the Terraform dependencies for a given environment
#   it then lists the latest available provider versions and locked versions for the environment
# input:
#   $1: environment name to bump
#   $2: init without backend? (optional, defaults to 0)
# on info:
#   status messages are printed
# returns:
#   exit code directly
_dsb_tf_bump_an_env() {
  local returnCode=0
  local givenEnv="${1}"       # used when calling terraform init -upgrade
  local offlineInit="${2:-0}" # defaults to 0

  _dsb_d "givenEnv: ${givenEnv}"
  _dsb_d "offlineInit: ${offlineInit}"

  # check if the current root directory is a valid Terraform project
  # _dsb_tf_check_current_dir calls _dsb_tf_enumerate_directories, so we don't need to call it again in this function
  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  # shellcheck disable=SC2181 # inline var assignment requires $?
  if [ $? -ne 0 ]; then
    _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
    return 1
  fi

  local initStatus=0
  local listStatus=0

  # validate the environment and set globals (offline-aware, skip lock check since bump runs init)
  if [ "${offlineInit}" -eq 1 ]; then
    if ! _dsb_tf_set_env_offline "${givenEnv}" 1; then
      return 1
    fi
  else
    if ! _dsbTfLogInfo=0 _dsbTfLogErrors=1 _dsb_tf_set_env "${givenEnv}" 1; then
      return 1
    fi
  fi

  local envDir="${_dsbTfSelectedEnvDir}"
  _dsb_d "    envDir: ${envDir}"

  # terraform init -upgrade the project
  if ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_init 1 0 "${offlineInit}" "${givenEnv}"; then # $1 = 1 means do -upgrade, $2 = 0 means do not unset the selected environment, $3 = with/without backend
    _dsb_d "Failed to upgrade the environment '${givenEnv}' with non-zero exit code."
    initStatus=1
  fi

  # show latest available provider versions and locked versions in the project
  if ! _dsb_tf_list_available_terraform_provider_upgrades_for_env; then # uses the selected environment
    _dsb_d "Failed to list available provider upgrades for environment '${givenEnv}' with non-zero exit code."
    _dsb_d "  returnCode: ${returnCode}"
    listStatus=1
  fi

  # Use proper arithmetic instead of += which would do string concatenation (e.g. "0" + "1" = "01" not 1)
  returnCode=$(( returnCode + initStatus + listStatus ))

  if [ ${returnCode} -ne 0 ]; then
    _dsb_e "Failures reported during bumping, please review the output further up"
  else
    _dsb_i ""
    _dsb_i "Done."
  fi

  _dsb_d "done"


  return "${returnCode}"
}

# what:
#   this function is an all-in-one function to bump the versions of all the things
#   it bumps the versions of all modules in the project, tflint plugins and CI/CD files
#   it also upgrades the terraform version and lists potential providers upgrades
#   either for a single environment, if specified
#   or for all environments in the project, when not specified
# input:
#   $1: optional, init without backend, defaults to 0
#   $2: optional, environment name to bump, if not provided all environments are bumped
# on info:
#   status messages are printed
# returns:
#   exit code directly
_dsb_tf_bump_the_project() {
  local offlineInit="${1:-0}" # defaults to 0
  local givenEnv="${2:-}"     # defaults to empty string

  _dsb_d "offlineInit: ${offlineInit}"
  _dsb_d "givenEnv: ${givenEnv}"

  # check if the current root directory is a valid Terraform project
  # _dsb_tf_check_current_dir calls _dsb_tf_enumerate_directories, so we don't need to call it again in this function
  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  # shellcheck disable=SC2181 # inline var assignment requires $?
  if [ $? -ne 0 ]; then
    _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
    return 1
  fi

  local -a availableEnvs=()
  if [ -n "${givenEnv}" ]; then
    availableEnvs=("${givenEnv}")
  else
    mapfile -t availableEnvs < <(_dsb_tf_get_env_names)
  fi
  local envCount=${#availableEnvs[@]}

  _dsb_d "available envs count in availableEnvs: ${envCount}"
  _dsb_d "available envs: ${availableEnvs[*]}"

  local envsDir="${_dsbTfEnvsDir}"

  if [ "${envCount}" -eq 0 ]; then
    _dsb_e "No environments found in: ${envsDir}"
    _dsb_e "  please run 'tf-list-envs' to list available environments"
    _dsb_e "  or try running 'tf-check-dir' to verify the directory structure"
    return 1
  elif [ "${envCount}" -eq 1 ] && [ -n "${givenEnv}" ]; then # a single environment was explicitly specified
    if [ "${offlineInit}" -eq 1 ]; then
      if ! _dsb_tf_set_env_offline "${givenEnv}" 1; then # skip lock check, bump runs init
        return 1
      fi
    else
      if ! _dsbTfLogInfo=0 _dsbTfLogErrors=1 _dsb_tf_set_env "${givenEnv}" 1; then # skip lock check, bump runs init
        _dsb_d "Failed to set environment '${givenEnv}'."
        _dsb_e "  please run 'tf-check-env ${givenEnv}' for more information."
        return 1
      fi
    fi
  fi

  _dsb_i "Bump the project:"
  _dsb_i ""

  local moduleStatus=0
  local tflintPluginStatus=0
  local cicdStatus=0

  # bump the versions of all modules in the project
  _dsb_tf_bump_registry_module_versions
  local _modRC=$?
  if [ "${_modRC}" -ne 0 ]; then
    moduleStatus=1
  fi
  _dsb_i ""

  # bump the versions of all tflint plugins in the project
  _dsb_tf_bump_tflint_plugin_versions
  local _tflintRC=$?
  if [ "${_tflintRC}" -ne 0 ]; then
    tflintPluginStatus=1
  fi
  _dsb_i ""

  # bump tflint and terraform versions in the CI/CD pipeline files
  _dsb_tf_bump_github
  local _cicdRC=$?
  if [ "${_cicdRC}" -ne 0 ]; then
    cicdStatus=1
  fi
  _dsb_i ""

  local preflightStatus=0
  local terraformStatus=0
  local providerStatus=0
  local envName envDir
  for envName in "${availableEnvs[@]}"; do
    _dsb_i "Bump environment: ${envName}"
    _dsb_i ""

    # validate the environment and set globals (offline-aware, skip lock check since bump runs init)
    local _setEnvOk=0
    if [ "${offlineInit}" -eq 1 ]; then
      if ! _dsb_tf_set_env_offline "${envName}" 1; then
        _dsb_e "  unable to set environment '${envName}', upgrade skipped."
        ((preflightStatus += 1))
      else
        _setEnvOk=1
      fi
    else
      if ! _dsbTfLogInfo=0 _dsbTfLogErrors=1 _dsb_tf_set_env "${envName}" 1; then
        _dsb_e "  unable to set environment '${envName}', upgrade skipped."
        _dsb_e "  please run 'tf-check-env ${envName}' for more information."
        ((preflightStatus += 1))
      else
        _setEnvOk=1
      fi
    fi
    if [ "${_setEnvOk}" -eq 1 ]; then
      local envDir="${_dsbTfSelectedEnvDir}"
      _dsb_d "    envDir: ${envDir}"

      # terraform init -upgrade the project
      if ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_init 1 1 "${offlineInit}" "${envName}"; then
        _dsb_e "  Failed to upgrade the environment '${envName}', please run 'tf-upgrade-env ${envName}' for more information."
        ((terraformStatus += 1))
      fi

      # show latest available provider versions and locked versions in the project
      if ! _dsb_tf_list_available_terraform_provider_upgrades_for_env "${envName}"; then
        ((providerStatus += 1))
      fi
    fi

    _dsb_d "preflightStatus for env '${envName}': ${preflightStatus}"
    _dsb_d "terraformStatus for env '${envName}': ${terraformStatus}"
    _dsb_d "providerStatus for env '${envName}': ${providerStatus}"

    _dsb_i ""
  done

  # summarize the status of all bump operations
  local returnCode=$((preflightStatus + moduleStatus + tflintPluginStatus + cicdStatus + terraformStatus + providerStatus))

  if [ "${envCount}" -gt 1 ]; then
    _dsb_i "Bump summary:"
    if [ "${returnCode}" -ne 0 ]; then
      _dsb_e "  Number of failures during bumping: ${returnCode}"
    fi
    if [ ${moduleStatus} -eq 0 ]; then
      _dsb_i "  \e[32m☑\e[0m  Module versions                : succeeded"
    else
      _dsb_e "  \e[31m☒\e[0m  Module versions                : failure reported"
    fi
    if [ ${tflintPluginStatus} -eq 0 ]; then
      _dsb_i "  \e[32m☑\e[0m  Tflint plugin versions         : succeeded"
    else
      _dsb_e "  \e[31m☒\e[0m  Tflint plugin versions         : failure reported"
    fi
    if [ ${cicdStatus} -eq 0 ]; then
      _dsb_i "  \e[32m☑\e[0m  CI/CD versions                 : succeeded"
    else
      _dsb_e "  \e[31m☒\e[0m  CI/CD versions                 : failure reported"
    fi
    if [ ${terraformStatus} -eq 0 ]; then
      _dsb_i "  \e[32m☑\e[0m  Terraform dependencies         : succeeded"
    else
      _dsb_e "  \e[31m☒\e[0m  Terraform dependencies         : ${terraformStatus} failure(s) reported"
    fi
    if [ ${providerStatus} -eq 0 ]; then
      _dsb_i "  \e[32m☑\e[0m  Provider versions              : succeeded, see further up for potential upgrades"
    else
      _dsb_e "  \e[31m☒\e[0m  Provider versions              : ${providerStatus} failure(s) reported"
    fi
  fi

  if [ ${returnCode} -ne 0 ]; then
    _dsb_e ""
    _dsb_e "Failures reported during bumping, please review the output further up"
  else
    _dsb_i ""
    _dsb_i "Done."
    _dsb_i "  Now run: 'tf-validate && tf-plan'"
  fi

  _dsb_d "done"


  return "${returnCode}"
}

# what:
#   this function is a wrapper of _dsb_tf_bump_the_project
#   it allows to specify an environment to bump the versions for
#   and if the not specified, it attempts to use the selected environment
# input:
#   $1: optional, init without backend, defaults to 0
#   $2: optional, environment name to bump, if not provided the selected environment is used
# on info:
#   nothing, status messages indirectly from _dsb_tf_bump_the_project
# returns:
#   exit code directly
_dsb_tf_bump_the_project_single_env() {
  local returnCode=0
  local offlineInit="${1:-0}" # defaults to 0
  local givenEnv="${2:-}"     # defaults to empty string

  _dsb_d "offlineInit: ${offlineInit}"
  _dsb_d "givenEnv: ${givenEnv}"

  if [ -z "${givenEnv}" ]; then
    givenEnv=${_dsbTfSelectedEnv:-}
  fi

  if [ -z "${givenEnv}" ]; then
    _dsb_e "No environment specified and no environment selected."
    _dsb_e "  either specify environment: 'tf-bump <env>'"
    _dsb_e "  or run 'tf-set-env <env>' first"
    returnCode=1
  else
    _dsb_tf_bump_the_project "${offlineInit}" "${givenEnv}"
  fi

  _dsb_d "done"
  return "${returnCode}"
}

###################################################################################################
#
# Internal functions: module repo operations
#
###################################################################################################

# what:
#   runs terraform init at the module root directory
#   used for module repos -- no environment, no backend, no subscription
# input:
#   $1: doUpgrade (optional, defaults to 0)
# on info:
#   status messages are printed
# returns:
#   exit code directly
_dsb_tf_init_module_root() {
  local doUpgrade="${1:-0}"
  shift || :
  local -a passthroughArgs=("$@")

  _dsb_d "called with doUpgrade: ${doUpgrade}"
  if [ "${#passthroughArgs[@]}" -gt 0 ]; then
    _dsb_d "  passthroughArgs: ${passthroughArgs[*]}"
  fi

  # terraform must be installed
  if ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_terraform; then
    _dsb_e "Terraform check failed, please run 'tf-check-tools'"
    return 1
  fi

  # enumerate directories with current directory as root and
  # check if the current root directory is a valid module repo
  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  local dirCheckStatus=$?
  if [ "${dirCheckStatus}" -ne 0 ]; then
    _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
    return 1
  fi

  local extraInitArgs=""
  if [ "${doUpgrade}" -eq 1 ]; then
    extraInitArgs=" -upgrade"
  fi

  _dsb_i "Initializing Terraform module at root"
  _dsb_i "  directory: ${_dsbTfRootDir}"

  # shellcheck disable=SC2086 # extraInitArgs is intentionally unquoted for word splitting
  terraform -chdir="${_dsbTfRootDir}" init -reconfigure -input=false ${extraInitArgs} "${passthroughArgs[@]}" 2>&1 | _dsb_tf_fixup_paths_from_stdin
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    _dsb_e "terraform init at root failed"
    _dsb_tf_error_push "terraform init at module root failed"
    return 1
  fi

  _dsb_i "Done."
  _dsb_d "done"
  return 0
}

# what:
#   runs terraform validate at the module root directory
#   used for module repos -- no environment, no subscription
# input:
#   none
# on info:
#   status messages are printed
# returns:
#   exit code directly
_dsb_tf_validate_module_root() {
  # terraform must be installed
  if ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_terraform; then
    _dsb_e "Terraform check failed, please run 'tf-check-tools'"
    return 1
  fi

  # enumerate directories with current directory as root and
  # check if the current root directory is a valid module repo
  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  local dirCheckStatus=$?
  if [ "${dirCheckStatus}" -ne 0 ]; then
    _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
    return 1
  fi

  # Check if init has been run
  if [ ! -d "${_dsbTfRootDir}/.terraform" ]; then
    _dsb_e "Terraform has not been initialized at root."
    _dsb_e "  please run 'tf-init' first"
    _dsb_tf_error_push "terraform not initialized at module root (.terraform/ missing)"
    return 1
  fi

  _dsb_i "Validating Terraform module at root"
  _dsb_i "  directory: ${_dsbTfRootDir}"

  terraform -chdir="${_dsbTfRootDir}" validate 2>&1 | _dsb_tf_fixup_paths_from_stdin
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    _dsb_e "terraform validate at root failed"
    _dsb_tf_error_push "terraform validate at module root failed"
    return 1
  fi

  _dsb_i "Done."
  _dsb_d "done"
  return 0
}

# what:
#   runs tflint at the module root directory
#   used for module repos -- no environment selection
# input:
#   $@: optional lint arguments
# on info:
#   status messages are printed
# returns:
#   exit code directly
_dsb_tf_lint_module_root() {
  local lintArguments="$*"
  local githubAuthAvailable=1

  _dsb_d "called with lintArguments: ${lintArguments}"

  # check that gh cli is installed and user is logged in
  if ! _dsbTfLogErrors=0 _dsb_tf_check_gh_auth; then
    _dsb_d "GitHub authentication unavailable, proceeding without GitHub authentication"
    githubAuthAvailable=0
  fi

  # enumerate directories with current directory as root and
  # check if the current root directory is a valid module repo
  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  local dirCheckStatus=$?
  if [ "${dirCheckStatus}" -ne 0 ]; then
    _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
    return 1
  fi

  # make sure tflint wrapper is installed
  if ! _dsbTfLogErrors=0 _dsb_tf_install_tflint_wrapper; then
    _dsb_e "Failed to install tflint wrapper, consider enabling debug logging"
    return 1
  fi

  local _savedPwd="${PWD}"
  if ! cd "${_dsbTfRootDir}"; then
    _dsb_tf_error_push "failed to change to root directory: ${_dsbTfRootDir}"
    return 1
  fi

  # get GitHub API token
  local ghToken
  if [ "${githubAuthAvailable}" -ne 1 ]; then
    _dsb_d "GitHub authentication unavailable, proceeding without API token"
    ghToken=""
  else
    _dsb_d "GitHub authentication available, attempting to get API token"
    if ! ghToken=$(gh auth token 2>/dev/null); then
      _dsb_w "Failed to get GitHub API token, attempting to proceed without API token"
      ghToken=""
    fi
  fi

  # invoke the tflint wrapper script
  # shellcheck disable=SC2086 # lintArguments is intentionally unquoted for word splitting
  GITHUB_TOKEN=${ghToken} bash -s -- ${lintArguments} <"${_dsbTfTflintWrapperPath}" 2>&1 | _dsb_tf_fixup_paths_from_stdin
  local returnCode=0
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    _dsb_i_append "" # newline without any prefix
    _dsb_w "tflint operation resulted in non-zero exit code."
    returnCode=1
  fi

  cd "${_savedPwd}" || _dsb_w "Failed to restore working directory"

  _dsb_d "done"
  return "${returnCode}"
}

# what:
#   module repo version of tf-bump: bumps modules, tflint plugins, cicd versions,
#   then runs terraform init -upgrade at root and shows provider upgrades
# input:
#   none
# on info:
#   status messages are printed
# returns:
#   exit code directly
_dsb_tf_bump_module_repo() {
  # check if the current root directory is a valid module repo
  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  local dirCheckStatus=$?
  if [ "${dirCheckStatus}" -ne 0 ]; then
    _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
    return 1
  fi

  _dsb_i "Bump module repo:"
  _dsb_i ""

  local moduleStatus=0
  local tflintPluginStatus=0
  local cicdStatus=0
  local upgradeStatus=0
  local providerStatus=0

  # bump the versions of all registry modules in the module
  _dsb_tf_bump_registry_module_versions
  local _modRC=$?
  if [ "${_modRC}" -ne 0 ]; then
    moduleStatus=1
  fi
  _dsb_i ""

  # bump the versions of all tflint plugins
  _dsb_tf_bump_tflint_plugin_versions
  local _tflintRC=$?
  if [ "${_tflintRC}" -ne 0 ]; then
    tflintPluginStatus=1
  fi
  _dsb_i ""

  # bump tflint and terraform versions in the CI/CD pipeline files
  _dsb_tf_bump_github
  local _cicdRC=$?
  if [ "${_cicdRC}" -ne 0 ]; then
    cicdStatus=1
  fi
  _dsb_i ""

  # terraform init -upgrade at root
  _dsb_i "Upgrading Terraform dependencies at root ..."
  if ! _dsb_tf_init_module_root 1; then # 1 = do upgrade
    _dsb_e "Failed to upgrade Terraform dependencies at root"
    upgradeStatus=1
  fi
  _dsb_i ""

  # show provider upgrades from root
  if ! _dsb_tf_list_available_terraform_provider_upgrades_module; then
    providerStatus=1
  fi

  local returnCode=$((moduleStatus + tflintPluginStatus + cicdStatus + upgradeStatus + providerStatus))

  if [ ${returnCode} -ne 0 ]; then
    _dsb_e ""
    _dsb_e "Failures reported during bumping, please review the output further up"
  else
    _dsb_i ""
    _dsb_i "Done."
  fi

  _dsb_d "done"
  return "${returnCode}"
}

# what:
#   lists available terraform provider upgrades for a module repo
#   reads from root using terraform-config-inspect
#   lock file may not exist (gitignored in module repos)
# input:
#   none
# on info:
#   status messages are printed
# returns:
#   exit code directly
_dsb_tf_list_available_terraform_provider_upgrades_module() {
  local returnCode=0

  # we need several tools to be available: curl, jq, terraform-config-inspect
  if ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_curl ||
    ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_jq ||
    ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_terraform_config_inspect ||
    ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_hcledit; then
    _dsb_e "Tools check failed, please run 'tf-check-tools'"
    return 1
  fi

  _dsb_i "Available Terraform provider upgrades (module root):"

  local tfConfigJson
  tfConfigJson=$(terraform-config-inspect --json "${_dsbTfRootDir}")
  _dsb_d "tfConfigJson: $(echo "${tfConfigJson}" | jq -r || :)"
  if [ -z "${tfConfigJson}" ]; then
    _dsb_e "  Failed to get Terraform configuration for module root"
    return 1
  fi

  local providers provider
  providers=$(echo "${tfConfigJson}" | jq -r '.required_providers | keys[]')

  if [ -z "${providers}" ]; then
    _dsb_i "  No providers found in module root configuration."
    return 0
  fi

  local ignoreProviderVersionCache=1
  for provider in ${providers}; do
    local source version_constraints
    source=$(echo "${tfConfigJson}" | jq -r ".required_providers[\"${provider}\"].source // empty")
    version_constraints=$(echo "${tfConfigJson}" | jq -r "(.required_providers[\"${provider}\"].version_constraints // [])[] // empty")

    _dsb_d "provider: ${provider}"
    _dsb_d "  source: ${source}"

    # if empty we assume hashicorp provider
    if [ -z "${source}" ]; then
      source="hashicorp/${provider}"
      _dsb_d "  source is empty, assuming hashicorp provider, changed to: ${source}"
    fi

    if ! _dsb_tf_get_latest_terraform_provider_version "${source}" "${ignoreProviderVersionCache}"; then
      _dsb_e "  Failed to get latest version for provider: ${source}"
      returnCode=1
    fi

    # lock file is optional in module repos (gitignored)
    local lockfileVersion=""
    if [ -f "${_dsbTfRootDir}/.terraform.lock.hcl" ]; then
      if _dsb_tf_get_lockfile_provider_version "${_dsbTfRootDir}" "${source}"; then
        lockfileVersion="${_dsbTfLockfileProviderVersion:-}"
      fi
    fi

    _dsb_i "  ${source} => \e[32m${_dsbTfLatestProviderVersion:-}\e[0m"
    _dsb_i "    Project constraint(s): ${version_constraints}"
    if [ -n "${lockfileVersion}" ]; then
      if [ -n "${_dsbTfLatestProviderVersion:-}" ] &&
        [ "${_dsbTfLatestProviderVersion}" == "${lockfileVersion}" ]; then
        _dsb_i "    Locked version: ${lockfileVersion}"
      else
        _dsb_i "    Locked version: \e[33m${lockfileVersion}\e[0m"
      fi
    else
      _dsb_i "    Locked version: N/A (lock file not present)"
    fi

    ignoreProviderVersionCache=0
  done

  _dsb_d "done"
  return "${returnCode}"
}

# what:
#   init module root and all examples in a module repo
# input:
#   none
# on info:
#   status messages are printed
# returns:
#   exit code directly
_dsb_tf_init_all_module() {
  _dsb_d "called"
  local returnCode=0

  _dsb_i "Initializing module root and all examples ..."

  _dsb_tf_init_module_root
  local rootRC=$?
  if [ "${rootRC}" -ne 0 ]; then
    returnCode=1
  fi

  _dsb_tf_init_examples
  local examplesRC=$?
  if [ "${examplesRC}" -ne 0 ]; then
    returnCode=1
  fi

  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_push "init-all failed"
  else
    _dsb_i "Done."
  fi
  return "${returnCode}"
}

###################################################################################################
#
# Internal functions: Module examples support
#
###################################################################################################

# what:
#   runs terraform init on one or all example directories
# input:
#   $1: exampleName (optional, if empty runs on all examples)
# on info:
#   per-example status messages
# returns:
#   exit code directly
_dsb_tf_init_examples() {
  local exampleFilter="${1:-}"

  if ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_terraform; then
    _dsb_e "Terraform check failed, please run 'tf-check-tools'"
    return 1
  fi

  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  local dirCheckStatus=$?
  if [ "${dirCheckStatus}" -ne 0 ]; then
    _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
    return 1
  fi

  local -a exampleNames=()
  if [ -n "${exampleFilter}" ]; then
    if [ -z "${_dsbTfExamplesDirList[${exampleFilter}]:-}" ]; then
      _dsb_e "Example '${exampleFilter}' not found."
      _dsb_e "  available examples: $(IFS=', '; echo "${!_dsbTfExamplesDirList[*]}")"
      return 1
    fi
    exampleNames=("${exampleFilter}")
  else
    local _exKey
    for _exKey in "${!_dsbTfExamplesDirList[@]}"; do
      exampleNames+=("${_exKey}")
    done
  fi

  if [ "${#exampleNames[@]}" -eq 0 ]; then
    _dsb_w "No examples found."
    return 0
  fi

  # sort for deterministic order
  mapfile -t exampleNames < <(printf '%s\n' "${exampleNames[@]}" | sort)

  local returnCode=0
  local successCount=0
  local failCount=0

  _dsb_i "Initializing examples ..."
  for exName in "${exampleNames[@]}"; do
    local exDir="${_dsbTfExamplesDirList[${exName}]}"
    _dsb_i "  Initializing example: ${exName}"
    _dsb_i "    directory: ${exDir}"

    terraform -chdir="${exDir}" init -reconfigure -input=false 2>&1 | _dsb_tf_fixup_paths_from_stdin
    if [ "${PIPESTATUS[0]}" -ne 0 ]; then
      _dsb_e "  terraform init failed for example: ${exName}"
      _dsb_tf_error_push "terraform init failed for example: ${exName}"
      returnCode=1
      ((failCount++))
    else
      ((successCount++))
    fi
  done

  _dsb_i ""
  _dsb_i "Examples init summary: ${successCount} succeeded, ${failCount} failed out of ${#exampleNames[@]}"
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_e "Some examples failed to initialize."
  else
    _dsb_i "Done."
  fi
  return "${returnCode}"
}

# what:
#   runs terraform validate on one or all example directories
# input:
#   $1: exampleName (optional, if empty runs on all examples)
# on info:
#   per-example status messages
# returns:
#   exit code directly
_dsb_tf_validate_examples() {
  local exampleFilter="${1:-}"

  if ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_terraform; then
    _dsb_e "Terraform check failed, please run 'tf-check-tools'"
    return 1
  fi

  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  local dirCheckStatus=$?
  if [ "${dirCheckStatus}" -ne 0 ]; then
    _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
    return 1
  fi

  local -a exampleNames=()
  if [ -n "${exampleFilter}" ]; then
    if [ -z "${_dsbTfExamplesDirList[${exampleFilter}]:-}" ]; then
      _dsb_e "Example '${exampleFilter}' not found."
      return 1
    fi
    exampleNames=("${exampleFilter}")
  else
    local _exKey
    for _exKey in "${!_dsbTfExamplesDirList[@]}"; do
      exampleNames+=("${_exKey}")
    done
  fi

  if [ "${#exampleNames[@]}" -eq 0 ]; then
    _dsb_w "No examples found."
    return 0
  fi

  mapfile -t exampleNames < <(printf '%s\n' "${exampleNames[@]}" | sort)

  local returnCode=0
  local successCount=0
  local failCount=0

  _dsb_i "Validating examples ..."
  for exName in "${exampleNames[@]}"; do
    local exDir="${_dsbTfExamplesDirList[${exName}]}"
    _dsb_i "  Validating example: ${exName}"

    # Check if init has been run
    if [ ! -d "${exDir}/.terraform" ]; then
      _dsb_e "  Example '${exName}' has not been initialized. Run 'tf-init-all-examples ${exName}' first."
      _dsb_tf_error_push "example '${exName}' not initialized (.terraform/ missing)"
      returnCode=1
      ((failCount++))
      continue
    fi

    terraform -chdir="${exDir}" validate 2>&1 | _dsb_tf_fixup_paths_from_stdin
    if [ "${PIPESTATUS[0]}" -ne 0 ]; then
      _dsb_e "  terraform validate failed for example: ${exName}"
      _dsb_tf_error_push "terraform validate failed for example: ${exName}"
      returnCode=1
      ((failCount++))
    else
      ((successCount++))
    fi
  done

  _dsb_i ""
  _dsb_i "Examples validate summary: ${successCount} succeeded, ${failCount} failed out of ${#exampleNames[@]}"
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_e "Some examples failed validation."
  else
    _dsb_i "Done."
  fi
  return "${returnCode}"
}

# what:
#   runs tflint on one or all example directories using root .tflint.hcl config
# input:
#   $1: exampleName (optional, if empty runs on all examples)
# on info:
#   per-example status messages
# returns:
#   exit code directly
_dsb_tf_lint_examples() {
  local exampleFilter="${1:-}"
  local githubAuthAvailable=1

  if ! _dsbTfLogErrors=0 _dsb_tf_check_gh_auth; then
    _dsb_d "GitHub authentication unavailable, proceeding without GitHub authentication"
    githubAuthAvailable=0
  fi

  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  local dirCheckStatus=$?
  if [ "${dirCheckStatus}" -ne 0 ]; then
    _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
    return 1
  fi

  if ! _dsbTfLogErrors=0 _dsb_tf_install_tflint_wrapper; then
    _dsb_e "Failed to install tflint wrapper, consider enabling debug logging"
    return 1
  fi

  local -a exampleNames=()
  if [ -n "${exampleFilter}" ]; then
    if [ -z "${_dsbTfExamplesDirList[${exampleFilter}]:-}" ]; then
      _dsb_e "Example '${exampleFilter}' not found."
      return 1
    fi
    exampleNames=("${exampleFilter}")
  else
    local _exKey
    for _exKey in "${!_dsbTfExamplesDirList[@]}"; do
      exampleNames+=("${_exKey}")
    done
  fi

  if [ "${#exampleNames[@]}" -eq 0 ]; then
    _dsb_w "No examples found."
    return 0
  fi

  mapfile -t exampleNames < <(printf '%s\n' "${exampleNames[@]}" | sort)

  # get GitHub API token
  local ghToken
  if [ "${githubAuthAvailable}" -ne 1 ]; then
    ghToken=""
  else
    if ! ghToken=$(gh auth token 2>/dev/null); then
      ghToken=""
    fi
  fi

  local returnCode=0
  local successCount=0
  local failCount=0

  _dsb_i "Linting examples ..."
  for exName in "${exampleNames[@]}"; do
    local exDir="${_dsbTfExamplesDirList[${exName}]}"
    _dsb_i "  Linting example: ${exName}"

    local _savedPwd="${PWD}"
    if ! cd "${exDir}"; then
      _dsb_tf_error_push "failed to change to example directory: ${exDir}"
      returnCode=1
      ((failCount++))
      continue
    fi

    # shellcheck disable=SC2086 # intentional
    GITHUB_TOKEN=${ghToken} bash -s -- --config "${_dsbTfRootDir}/.tflint.hcl" <"${_dsbTfTflintWrapperPath}" 2>&1 | _dsb_tf_fixup_paths_from_stdin
    if [ "${PIPESTATUS[0]}" -ne 0 ]; then
      _dsb_w "  tflint failed for example: ${exName}"
      returnCode=1
      ((failCount++))
    else
      ((successCount++))
    fi

    cd "${_savedPwd}" || _dsb_w "Failed to restore working directory"
  done

  _dsb_i ""
  _dsb_i "Examples lint summary: ${successCount} succeeded, ${failCount} failed out of ${#exampleNames[@]}"
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_e "Some examples failed linting."
  else
    _dsb_i "Done."
  fi
  return "${returnCode}"
}

###################################################################################################
#
# Internal functions: Terraform test support
#
###################################################################################################

# what:
#   checks Azure subscription and prompts for confirmation
#   on success, exports ARM_SUBSCRIPTION_ID
# input:
#   none (reads from stdin for y/n prompt)
# on info:
#   warning and subscription details are printed
# returns:
#   exit code directly
_dsb_tf_require_azure_subscription() {
  # check az cli is installed
  if ! _dsbTfLogErrors=0 _dsb_tf_check_az_cli; then
    _dsb_e "Azure CLI is not installed. Required for integration tests."
    _dsb_e "  please install the Azure CLI: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
    return 1
  fi

  # check logged in
  if ! _dsb_tf_az_is_logged_in; then
    _dsb_e "Not logged in with Azure CLI. Required for integration tests."
    _dsb_e "  please run 'az-login' first"
    return 1
  fi

  # get subscription details
  local showOutput subId subName
  showOutput=$(az account show 2>&1)
  subId=$(echo "${showOutput}" | jq -r '.id')
  subName=$(echo "${showOutput}" | jq -r '.name')

  if [ -z "${subId}" ] || [ "${subId}" == "null" ]; then
    _dsb_e "Failed to get Azure subscription ID."
    return 1
  fi

  # display warning
  _dsb_w ""
  _dsb_w "WARNING: Integration tests deploy real Azure resources."
  _dsb_w "  Current subscription: ${subName} (${subId})"
  _dsb_w ""

  # prompt for confirmation -- user must type the subscription name to confirm
  _dsb_i "To confirm, type the subscription name exactly as shown above:"
  local answer
  read -r -p "> " answer
  # case-insensitive comparison
  if [[ "${answer,,}" != "${subName,,}" ]]; then
    _dsb_i "Subscription name did not match. Aborted."
    return 1
  fi

  # export the subscription id
  export ARM_SUBSCRIPTION_ID="${subId}"
  _dsb_i "ARM_SUBSCRIPTION_ID set to: ${subId}"
  return 0
}

# what:
#   runs terraform test with optional filter
# input:
#   $@: filter arguments (optional)
# on info:
#   test output
# returns:
#   exit code directly
_dsb_tf_run_terraform_test() {
  local -a filterArgs=("$@")

  if ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_terraform; then
    _dsb_e "Terraform check failed, please run 'tf-check-tools'"
    return 1
  fi

  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  local dirCheckStatus=$?
  if [ "${dirCheckStatus}" -ne 0 ]; then
    _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
    return 1
  fi

  _dsb_i "Running terraform test ..."
  if [ "${#filterArgs[@]}" -gt 0 ]; then
    _dsb_i "  filters: ${filterArgs[*]}"
  fi

  local -a testCmd=(terraform -chdir="${_dsbTfRootDir}" test)
  local filter
  for filter in "${filterArgs[@]}"; do
    testCmd+=(-filter="tests/${filter}")
  done

  _dsb_d "testCmd: ${testCmd[*]}"

  "${testCmd[@]}" 2>&1 | _dsb_tf_fixup_paths_from_stdin
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    _dsb_e "terraform test failed"
    _dsb_tf_error_push "terraform test failed"
    return 1
  fi

  _dsb_i "Done."
  return 0
}

# what:
#   runs terraform test for example directories (apply + destroy)
# input:
#   $1: exampleName (optional, if empty runs on all examples)
# on info:
#   per-example status messages
# returns:
#   exit code directly
_dsb_tf_test_examples() {
  local exampleFilter="${1:-}"

  if ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_terraform; then
    _dsb_e "Terraform check failed, please run 'tf-check-tools'"
    return 1
  fi

  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  local dirCheckStatus=$?
  if [ "${dirCheckStatus}" -ne 0 ]; then
    _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
    return 1
  fi

  local -a exampleNames=()
  if [ -n "${exampleFilter}" ]; then
    if [ -z "${_dsbTfExamplesDirList[${exampleFilter}]:-}" ]; then
      _dsb_e "Example '${exampleFilter}' not found."
      return 1
    fi
    exampleNames=("${exampleFilter}")
  else
    local _exKey
    for _exKey in "${!_dsbTfExamplesDirList[@]}"; do
      exampleNames+=("${_exKey}")
    done
  fi

  if [ "${#exampleNames[@]}" -eq 0 ]; then
    _dsb_w "No examples found."
    return 0
  fi

  mapfile -t exampleNames < <(printf '%s\n' "${exampleNames[@]}" | sort)

  local returnCode=0
  local successCount=0
  local failCount=0

  _dsb_i "Testing examples (init + apply + destroy) ..."
  for exName in "${exampleNames[@]}"; do
    local exDir="${_dsbTfExamplesDirList[${exName}]}"
    _dsb_i ""
    _dsb_i "  Testing example: ${exName}"
    _dsb_i "    directory: ${exDir}"

    local exFailed=0

    # init
    _dsb_i "    Step 1/3: terraform init ..."
    terraform -chdir="${exDir}" init -reconfigure -input=false 2>&1 | _dsb_tf_fixup_paths_from_stdin
    if [ "${PIPESTATUS[0]}" -ne 0 ]; then
      _dsb_e "    terraform init failed for example: ${exName}"
      exFailed=1
    fi

    # apply
    if [ "${exFailed}" -eq 0 ]; then
      _dsb_i "    Step 2/3: terraform apply ..."
      ARM_SUBSCRIPTION_ID="${ARM_SUBSCRIPTION_ID:-}" terraform -chdir="${exDir}" apply -auto-approve 2>&1 | _dsb_tf_fixup_paths_from_stdin
      if [ "${PIPESTATUS[0]}" -ne 0 ]; then
        _dsb_e "    terraform apply failed for example: ${exName}"
        exFailed=1
      fi
    fi

    # destroy (always attempt if apply succeeded or partially ran)
    if [ "${exFailed}" -eq 0 ]; then
      _dsb_i "    Step 3/3: terraform destroy ..."
      ARM_SUBSCRIPTION_ID="${ARM_SUBSCRIPTION_ID:-}" terraform -chdir="${exDir}" destroy -auto-approve 2>&1 | _dsb_tf_fixup_paths_from_stdin
      if [ "${PIPESTATUS[0]}" -ne 0 ]; then
        _dsb_e "    terraform destroy failed for example: ${exName}"
        exFailed=1
      fi
    fi

    if [ "${exFailed}" -ne 0 ]; then
      returnCode=1
      ((failCount++))
      _dsb_tf_error_push "example test failed for: ${exName}"

      # ask whether to continue (only if there are more examples)
      if [ "${failCount}" -lt "${#exampleNames[@]}" ]; then
        local answer
        read -r -p "Continue with remaining examples? [y/n]: " answer
        if [ "${answer}" != "y" ] && [ "${answer}" != "Y" ]; then
          _dsb_i "Aborted by user."
          break
        fi
      fi
    else
      ((successCount++))
      _dsb_i "    Example '${exName}' passed."
    fi
  done

  _dsb_i ""
  _dsb_i "Examples test summary: ${successCount} succeeded, ${failCount} failed out of ${#exampleNames[@]}"
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_e "Some examples failed testing."
  else
    _dsb_i "Done."
  fi
  return "${returnCode}"
}

###################################################################################################
#
# Internal functions: Documentation generation
#
###################################################################################################

# what:
#   runs terraform-docs at module root
# input:
#   none
# on info:
#   status messages
# returns:
#   exit code directly
_dsb_tf_docs_root() {
  if ! _dsb_tf_check_terraform_docs; then
    return 1
  fi

  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  local dirCheckStatus=$?
  if [ "${dirCheckStatus}" -ne 0 ]; then
    _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
    return 1
  fi

  _dsb_i "Generating terraform-docs for module root ..."
  _dsb_i "  directory: ${_dsbTfRootDir}"

  if ! terraform-docs "${_dsbTfRootDir}" 2>&1; then
    _dsb_e "terraform-docs failed at root"
    _dsb_tf_error_push "terraform-docs failed at module root"
    return 1
  fi

  _dsb_i "Done."
  return 0
}

# what:
#   runs terraform-docs for all example directories
# input:
#   none
# on info:
#   per-example status messages
# returns:
#   exit code directly
_dsb_tf_docs_examples() {
  local exampleFilter="${1:-}"

  if ! _dsb_tf_check_terraform_docs; then
    return 1
  fi

  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  local dirCheckStatus=$?
  if [ "${dirCheckStatus}" -ne 0 ]; then
    _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
    return 1
  fi

  # check for examples terraform-docs config
  local examplesDocsConfig="${_dsbTfExamplesDir}/.terraform-docs.yml"
  if [ ! -f "${examplesDocsConfig}" ]; then
    _dsb_e "Examples terraform-docs config not found: ${examplesDocsConfig}"
    _dsb_e "  expected at: examples/.terraform-docs.yml"
    return 1
  fi

  local -a exampleNames=()
  if [ -n "${exampleFilter}" ]; then
    if [ -z "${_dsbTfExamplesDirList[${exampleFilter}]:-}" ]; then
      _dsb_e "Example '${exampleFilter}' not found."
      _dsb_e "  available examples: $(IFS=', '; echo "${!_dsbTfExamplesDirList[*]}")"
      _dsb_tf_error_push "example '${exampleFilter}' not found"
      return 1
    fi
    exampleNames=("${exampleFilter}")
  else
    local _exKey
    for _exKey in "${!_dsbTfExamplesDirList[@]}"; do
      exampleNames+=("${_exKey}")
    done
  fi

  if [ "${#exampleNames[@]}" -eq 0 ]; then
    _dsb_w "No examples found."
    return 0
  fi

  mapfile -t exampleNames < <(printf '%s\n' "${exampleNames[@]}" | sort)

  local returnCode=0
  local successCount=0
  local failCount=0

  _dsb_i "Generating terraform-docs for examples ..."
  for exName in "${exampleNames[@]}"; do
    local exDir="${_dsbTfExamplesDirList[${exName}]}"
    _dsb_i "  Generating docs for example: ${exName}"

    if ! terraform-docs "${exDir}" --config "${examplesDocsConfig}" 2>&1; then
      _dsb_e "  terraform-docs failed for example: ${exName}"
      _dsb_tf_error_push "terraform-docs failed for example: ${exName}"
      returnCode=1
      ((failCount++))
    else
      ((successCount++))
    fi
  done

  _dsb_i ""
  _dsb_i "Examples docs summary: ${successCount} succeeded, ${failCount} failed out of ${#exampleNames[@]}"
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_e "Some examples failed documentation generation."
  else
    _dsb_i "Done."
  fi
  return "${returnCode}"
}

###################################################################################################
#
# Internal functions: Version information
#
###################################################################################################

# what:
#   displays comprehensive version information
#   shows tool versions, terraform/provider versions, tflint plugin versions
#   adapts output based on repo type
# input:
#   none
# on info:
#   formatted version information
# returns:
#   exit code directly
_dsb_tf_versions() {
  _dsb_d "called"
  local returnCode=0

  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  local dirCheckStatus=$?
  if [ "${dirCheckStatus}" -ne 0 ]; then
    _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
    return 1
  fi

  _dsb_i "Version Information"
  _dsb_i "==================="
  _dsb_i ""

  # -- Tool Versions --
  _dsb_i "Tool Versions:"

  # Terraform CLI version
  local tfVersion=""
  if _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_terraform; then
    tfVersion=$(terraform -version 2>/dev/null | head -1) || tfVersion="unknown"
    _dsb_i "  Terraform CLI:  ${tfVersion}"
  else
    _dsb_d "terraform not installed"
    _dsb_i "  Terraform CLI:  not installed"
  fi

  # TFLint version (via wrapper or direct)
  if [ -f "${_dsbTfTflintWrapperPath:-/dev/null}" ]; then
    _dsb_i "  TFLint wrapper: installed at ${_dsbTfTflintWrapperPath}"
  else
    local tflintVersion=""
    if command -v tflint &>/dev/null; then
      tflintVersion=$(tflint --version 2>/dev/null | head -1) || tflintVersion="unknown"
      _dsb_i "  TFLint:         ${tflintVersion}"
    else
      _dsb_i "  TFLint:         not installed (wrapper not yet downloaded)"
    fi
  fi
  _dsb_i ""

  if [ "${_dsbTfRepoType}" == "module" ]; then
    _dsb_d "repo type is module, calling _dsb_tf_versions_module_root"
    _dsb_tf_versions_module_root
    local modRC=$?
    if [ "${modRC}" -ne 0 ]; then returnCode=1; fi
  else
    _dsb_d "repo type is project, calling _dsb_tf_versions_project"
    _dsb_tf_versions_project
    local projRC=$?
    if [ "${projRC}" -ne 0 ]; then returnCode=1; fi
  fi

  _dsb_d "returning exit code: ${returnCode}"
  return "${returnCode}"
}

# what:
#   show version info for a module repo
# input:
#   none
# on info:
#   version details for module root
# returns:
#   exit code directly
_dsb_tf_versions_module_root() {
  _dsb_d "called"
  local returnCode=0

  _dsb_i "Module Root Versions:"

  # Required terraform version from versions.tf
  local versionsFile="${_dsbTfRootDir}/versions.tf"
  if [ -f "${versionsFile}" ]; then
    local reqTfVer=""
    if _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_hcledit; then
      reqTfVer=$(hcledit attribute get terraform.required_version --file "${versionsFile}" 2>/dev/null) || reqTfVer=""
    fi
    if [ -n "${reqTfVer}" ]; then
      _dsb_i "  Required Terraform: ${reqTfVer}"
    else
      _dsb_i "  Required Terraform: (not specified)"
    fi
  else
    _dsb_i "  versions.tf: not found"
  fi

  # Required providers from versions.tf using terraform-config-inspect
  if _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_terraform_config_inspect &&
    _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_jq; then
    local tfConfigJson
    tfConfigJson=$(terraform-config-inspect --json "${_dsbTfRootDir}" 2>/dev/null) || tfConfigJson=""
    if [ -n "${tfConfigJson}" ]; then
      local providers
      providers=$(echo "${tfConfigJson}" | jq -r '.required_providers | keys[]' 2>/dev/null) || providers=""
      if [ -n "${providers}" ]; then
        _dsb_i "  Required Providers:"
        local provider
        for provider in ${providers}; do
          local source constraints
          source=$(echo "${tfConfigJson}" | jq -r ".required_providers[\"${provider}\"].source // empty" 2>/dev/null) || source=""
          constraints=$(echo "${tfConfigJson}" | jq -r "(.required_providers[\"${provider}\"].version_constraints // [])[] // empty" 2>/dev/null) || constraints=""
          _dsb_i "    ${provider}: ${source:-hashicorp/${provider}} ${constraints:+(${constraints})}"
        done
      fi
    fi
  fi

  # Locked provider versions from .terraform.lock.hcl
  local lockFile="${_dsbTfRootDir}/.terraform.lock.hcl"
  if [ -f "${lockFile}" ]; then
    _dsb_i "  Locked Providers (from .terraform.lock.hcl):"
    if _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_hcledit; then
      local lockProviders
      lockProviders=$(hcledit block list --file "${lockFile}" 2>/dev/null) || lockProviders=""
      local lockLine
      while IFS= read -r lockLine; do
        if [ -n "${lockLine}" ]; then
          local lockVersion
          lockVersion=$(hcledit attribute get "${lockLine}.version" --file "${lockFile}" 2>/dev/null) || lockVersion=""
          # Convert: provider.registry\.terraform\.io/hashicorp/azurerm -> hashicorp/azurerm
          local displayName
          # shellcheck disable=SC2001 # bash substitution doesn't handle hcledit's escaped dots
          displayName=$(echo "${lockLine}" | sed 's|^provider\.registry\\\.terraform\\\.io/||')
          # Strip quotes from version
          lockVersion="${lockVersion//\"/}"
          _dsb_i "    ${displayName}: ${lockVersion:-unknown}"
        fi
      done <<< "${lockProviders}"
    else
      _dsb_i "    (hcledit not available)"
    fi
  else
    _dsb_i "  Lock file: not present (run tf-init to create)"
  fi

  # TFLint plugin versions from .tflint.hcl
  local tflintFile="${_dsbTfRootDir}/.tflint.hcl"
  if [ -f "${tflintFile}" ]; then
    _dsb_i "  TFLint Plugins (from .tflint.hcl):"
    if _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_hcledit; then
      local pluginBlocks
      pluginBlocks=$(hcledit block list --file "${tflintFile}" 2>/dev/null | grep '^plugin\.' || true)
      local pluginLine
      while IFS= read -r pluginLine; do
        if [ -n "${pluginLine}" ]; then
          local pluginVersion
          pluginVersion=$(hcledit attribute get "${pluginLine}.version" --file "${tflintFile}" 2>/dev/null) || pluginVersion=""
          local pluginName="${pluginLine#plugin.}"
          _dsb_i "    ${pluginName}: ${pluginVersion:-unknown}"
        fi
      done <<< "${pluginBlocks}"
    else
      _dsb_i "    (hcledit not available)"
    fi
  fi

  # GitHub workflow versions
  _dsb_i "  GitHub Workflow Versions:"
  local workflowDir="${_dsbTfRootDir}/.github/workflows"
  if [ -d "${workflowDir}" ]; then
    if _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_yq; then
      local ymlFile
      local workflowVersionFound=0
      for ymlFile in "${workflowDir}"/*.yml "${workflowDir}"/*.yaml; do
        [ -f "${ymlFile}" ] || continue
        local baseName
        baseName=$(basename "${ymlFile}")
        local tfWorkflowVer="" tflintWorkflowVer=""
        # Find terraform-version anywhere in the YAML, filtering out non-version values
        local _candidate
        while IFS= read -r _candidate; do
    # shellcheck disable=SC2016 # intentionally matching literal ${{ string
          [[ -z "${_candidate}" ]] && continue
          [[ "${_candidate}" == *'${{'* ]] && continue
          [[ "${_candidate}" == *'type:'* ]] && continue
          if _dsb_tf_semver_is_semver "${_candidate}" 1 1; then
            tfWorkflowVer="${_candidate}"
            break
          fi
        done < <(FIELD_NAME="terraform-version" yq eval '.. | select(has(env(FIELD_NAME))) | .[env(FIELD_NAME)]' "${ymlFile}" 2>/dev/null)
    # shellcheck disable=SC2016 # intentionally matching literal ${{ string
        while IFS= read -r _candidate; do
          [[ -z "${_candidate}" ]] && continue
          [[ "${_candidate}" == *'${{'* ]] && continue
          [[ "${_candidate}" == *'type:'* ]] && continue
          if _dsb_tf_semver_is_semver "${_candidate}" 1 1; then
            tflintWorkflowVer="${_candidate}"
            break
          fi
        done < <(FIELD_NAME="tflint-version" yq eval '.. | select(has(env(FIELD_NAME))) | .[env(FIELD_NAME)]' "${ymlFile}" 2>/dev/null)
        if [ -n "${tfWorkflowVer}" ] || [ -n "${tflintWorkflowVer}" ]; then
          workflowVersionFound=1
          _dsb_i "    ${baseName}:"
          if [ -n "${tfWorkflowVer}" ]; then
            _dsb_i "      terraform-version: ${tfWorkflowVer}"
          fi
          if [ -n "${tflintWorkflowVer}" ]; then
            _dsb_i "      tflint-version: ${tflintWorkflowVer}"
          fi
        fi
      done
      if [ "${workflowVersionFound}" -eq 0 ]; then
        _dsb_i "    (no terraform-version/tflint-version found in workflow files)"
      fi
    else
      _dsb_i "    (yq not available)"
    fi
  else
    _dsb_i "    (no .github/workflows directory)"
  fi
  _dsb_i ""

  _dsb_d "returning exit code: ${returnCode}"
  return "${returnCode}"
}

# what:
#   show version info for a project repo
# input:
#   none
# on info:
#   version details for all environments
# returns:
#   exit code directly
_dsb_tf_versions_project() {
  _dsb_d "called"
  local returnCode=0

  local -a availableEnvs=()
  mapfile -t availableEnvs < <(_dsb_tf_get_env_names)

  if [ "${#availableEnvs[@]}" -eq 0 ]; then
    _dsb_i "  No environments found."
    return 0
  fi

  for envName in "${availableEnvs[@]}"; do
    local envDir="${_dsbTfEnvsDirList[${envName}]:-}"
    if [ -z "${envDir}" ]; then continue; fi

    _dsb_i "Environment: ${envName}"

    # Required terraform version
    local versionsFile="${envDir}/versions.tf"
    if [ -f "${versionsFile}" ]; then
      local reqTfVer=""
      if _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_hcledit; then
        reqTfVer=$(hcledit attribute get terraform.required_version --file "${versionsFile}" 2>/dev/null) || reqTfVer=""
      fi
      if [ -n "${reqTfVer}" ]; then
        _dsb_i "  Required Terraform: ${reqTfVer}"
      else
        _dsb_i "  Required Terraform: (not specified)"
      fi
    fi

    # Required providers
    if _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_terraform_config_inspect &&
      _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_jq; then
      local tfConfigJson
      tfConfigJson=$(terraform-config-inspect --json "${envDir}" 2>/dev/null) || tfConfigJson=""
      if [ -n "${tfConfigJson}" ]; then
        local providers
        providers=$(echo "${tfConfigJson}" | jq -r '.required_providers | keys[]' 2>/dev/null) || providers=""
        if [ -n "${providers}" ]; then
          _dsb_i "  Required Providers:"
          local provider
          for provider in ${providers}; do
            local source constraints
            source=$(echo "${tfConfigJson}" | jq -r ".required_providers[\"${provider}\"].source // empty" 2>/dev/null) || source=""
            constraints=$(echo "${tfConfigJson}" | jq -r "(.required_providers[\"${provider}\"].version_constraints // [])[] // empty" 2>/dev/null) || constraints=""
            _dsb_i "    ${provider}: ${source:-hashicorp/${provider}} ${constraints:+(${constraints})}"
          done
        fi
      fi
    fi

    # Locked provider versions
    local lockFile="${envDir}/.terraform.lock.hcl"
    if [ -f "${lockFile}" ]; then
      _dsb_i "  Locked Providers (from .terraform.lock.hcl):"
      if _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_hcledit; then
        local lockProviders
        lockProviders=$(hcledit block list --file "${lockFile}" 2>/dev/null) || lockProviders=""
        local lockLine
        while IFS= read -r lockLine; do
          if [ -n "${lockLine}" ]; then
            local lockVersion
            lockVersion=$(hcledit attribute get "${lockLine}.version" --file "${lockFile}" 2>/dev/null) || lockVersion=""
            # Convert: provider.registry\.terraform\.io/hashicorp/azurerm -> hashicorp/azurerm
          # shellcheck disable=SC2001 # bash substitution doesn't handle hcledit's escaped dots
            local displayName
            displayName=$(echo "${lockLine}" | sed 's|^provider\.registry\\\.terraform\\\.io/||')
            # Strip quotes from version
            lockVersion="${lockVersion//\"/}"
            _dsb_i "    ${displayName}: ${lockVersion:-unknown}"
          fi
        done <<< "${lockProviders}"
      fi
    else
      _dsb_i "  Lock file: not present"
    fi

    # TFLint plugin versions
    local tflintFile="${envDir}/.tflint.hcl"
    if [ -f "${tflintFile}" ]; then
      _dsb_i "  TFLint Plugins (from .tflint.hcl):"
      if _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_hcledit; then
        local pluginBlocks
        pluginBlocks=$(hcledit block list --file "${tflintFile}" 2>/dev/null | grep '^plugin\.' || true)
        local pluginLine
        while IFS= read -r pluginLine; do
          if [ -n "${pluginLine}" ]; then
            local pluginVersion
            pluginVersion=$(hcledit attribute get "${pluginLine}.version" --file "${tflintFile}" 2>/dev/null) || pluginVersion=""
            local pluginName="${pluginLine#plugin.}"
            _dsb_i "    ${pluginName}: ${pluginVersion:-unknown}"
          fi
        done <<< "${pluginBlocks}"
      fi
    fi

    _dsb_i ""
  done

  # GitHub workflow versions (project-wide, not per-environment)
  _dsb_i "GitHub Workflow Versions:"
  local workflowDir="${_dsbTfRootDir}/.github/workflows"
  if [ -d "${workflowDir}" ]; then
    if _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_yq; then
      local ymlFile
      local workflowVersionFound=0
      for ymlFile in "${workflowDir}"/*.yml "${workflowDir}"/*.yaml; do
        [ -f "${ymlFile}" ] || continue
        local baseName
        baseName=$(basename "${ymlFile}")
        local tfWorkflowVer="" tflintWorkflowVer=""
        # Find terraform-version anywhere in the YAML, filtering out non-version values
    # shellcheck disable=SC2016 # intentionally matching literal ${{ string
        local _candidate
        while IFS= read -r _candidate; do
          [[ -z "${_candidate}" ]] && continue
          [[ "${_candidate}" == *'${{'* ]] && continue
          [[ "${_candidate}" == *'type:'* ]] && continue
          if _dsb_tf_semver_is_semver "${_candidate}" 1 1; then
            tfWorkflowVer="${_candidate}"
            break
          fi
        done < <(FIELD_NAME="terraform-version" yq eval '.. | select(has(env(FIELD_NAME))) | .[env(FIELD_NAME)]' "${ymlFile}" 2>/dev/null)
        while IFS= read -r _candidate; do
          [[ -z "${_candidate}" ]] && continue
          # shellcheck disable=SC2016 # intentionally matching literal ${{ string
          [[ "${_candidate}" == *'${{'* ]] && continue
          [[ "${_candidate}" == *'type:'* ]] && continue
          if _dsb_tf_semver_is_semver "${_candidate}" 1 1; then
            tflintWorkflowVer="${_candidate}"
            break
          fi
        done < <(FIELD_NAME="tflint-version" yq eval '.. | select(has(env(FIELD_NAME))) | .[env(FIELD_NAME)]' "${ymlFile}" 2>/dev/null)
        if [ -n "${tfWorkflowVer}" ] || [ -n "${tflintWorkflowVer}" ]; then
          workflowVersionFound=1
          _dsb_i "  ${baseName}:"
          if [ -n "${tfWorkflowVer}" ]; then
            _dsb_i "    terraform-version: ${tfWorkflowVer}"
          fi
          if [ -n "${tflintWorkflowVer}" ]; then
            _dsb_i "    tflint-version: ${tflintWorkflowVer}"
          fi
        fi
      done
      if [ "${workflowVersionFound}" -eq 0 ]; then
        _dsb_i "  (no terraform-version/tflint-version found in workflow files)"
      fi
    else
      _dsb_i "  (yq not available)"
    fi
  else
    _dsb_i "  (no .github/workflows directory)"
  fi
  _dsb_i ""

  _dsb_d "returning exit code: ${returnCode}"
  return "${returnCode}"
}

###################################################################################################
#
# Internal: setup/install management
#
###################################################################################################

# Constants for setup commands (HOME-dependent paths are computed at call time via functions)
_DSB_TF_INSTALL_FILENAME="dsb-tf-proj-helpers.sh"
_DSB_TF_PROFILE_MARKER="# dsb-terraform-helpers"
_DSB_TF_GH_REPO="dsb-norge/terraform-helpers"

# what:
#   get the install directory path (computed at call time to respect current HOME)
_dsb_tf_get_install_dir() {
  echo "${HOME}/.local/bin"
}

# what:
#   get the full install path for the script
_dsb_tf_get_install_path() {
  echo "${HOME}/.local/bin/${_DSB_TF_INSTALL_FILENAME}"
}

# what:
#   determine the shell profile file to modify based on the user's login shell
# output:
#   prints the path to the profile file
# returns:
#   0 if supported shell, 1 if unsupported
_dsb_tf_get_shell_profile() {
  local shellName
  shellName="$(basename "${SHELL}")" || shellName=""

  case "${shellName}" in
    bash) echo "${HOME}/.bashrc" ;;
    zsh)  echo "${HOME}/.zshrc" ;;
    *)
      _dsb_e "Unsupported shell: '${shellName}'. Only bash and zsh are supported."
      _dsb_tf_error_push "unsupported shell '${shellName}'"
      return 1
      ;;
  esac
  return 0
}

# what:
#   check if the helpers are installed locally
# returns:
#   0 if installed, 1 if not
_dsb_tf_is_installed_locally() {
  local installPath
  installPath="$(_dsb_tf_get_install_path)"
  [[ -f "${installPath}" ]]
}

# what:
#   add the tf-load-helpers alias to the user's shell profile
#   idempotent: will not add duplicate entries
# returns:
#   0 on success, 1 on failure
_dsb_tf_add_shell_alias() {
  local profileFile
  profileFile=$(_dsb_tf_get_shell_profile) || return 1

  local aliasLine="alias tf-load-helpers='source \"\$HOME/.local/bin/${_DSB_TF_INSTALL_FILENAME}\"' ${_DSB_TF_PROFILE_MARKER}"

  # Create profile file if it doesn't exist
  touch "${profileFile}" 2>/dev/null || :

  # Only add if marker not already present (idempotent)
  if ! grep -qF "${_DSB_TF_PROFILE_MARKER}" "${profileFile}" 2>/dev/null; then
    printf '\n%s\n' "${aliasLine}" >> "${profileFile}"
    _dsb_i "Added tf-load-helpers alias to ${profileFile}"
  else
    _dsb_i "Alias already exists in ${profileFile} (no changes made)"
  fi

  return 0
}

# what:
#   remove the tf-load-helpers alias from the user's shell profile
# returns:
#   0 on success (or nothing to remove)
_dsb_tf_remove_shell_alias() {
  local profileFile
  profileFile=$(_dsb_tf_get_shell_profile) || return 0

  if [[ -f "${profileFile}" ]] && grep -qF "${_DSB_TF_PROFILE_MARKER}" "${profileFile}" 2>/dev/null; then
    # Portable sed in-place: use .bak suffix then remove (works on both GNU and BSD sed)
    sed -i.bak "/${_DSB_TF_PROFILE_MARKER}/d" "${profileFile}" && rm -f "${profileFile}.bak"
    _dsb_i "Removed tf-load-helpers alias from ${profileFile}"
  fi

  return 0
}

# what:
#   get the branch to use for downloading the script
#   respects DSB_TF_HELPERS_BRANCH env var for feature branch testing
# output:
#   prints the branch name
_dsb_tf_get_download_branch() {
  echo "${DSB_TF_HELPERS_BRANCH:-main}"
}

# what:
#   download the script from GitHub to a target file
#   prefers gh cli (authenticated) over curl (public, may be rate-limited)
#   respects DSB_TF_HELPERS_BRANCH env var for branch override
# input:
#   $1 : target file path to write the downloaded script to
# returns:
#   0 on success, 1 on failure
_dsb_tf_download_script_to_file() {
  local targetFile="${1}"
  local branch
  branch="$(_dsb_tf_get_download_branch)"

  local branchInfo=""
  if [[ "${branch}" != "main" ]]; then
    branchInfo=" (branch: ${branch})"
  fi

  # Try gh cli first (authenticated, no rate limiting)
  if _dsbTfLogErrors=0 _dsb_tf_check_gh_cli &>/dev/null && gh auth status &>/dev/null; then
    local ghApiUrl="/repos/${_DSB_TF_GH_REPO}/contents/${_DSB_TF_INSTALL_FILENAME}?ref=${branch}"
    _dsb_i "Downloading via gh cli${branchInfo} ..."
    if gh api -H "Accept: application/vnd.github.v3.raw" "${ghApiUrl}" > "${targetFile}" 2>/dev/null; then
      if [[ -s "${targetFile}" ]]; then
        return 0
      fi
    fi
    rm -f "${targetFile}" 2>/dev/null || :
    _dsb_w "gh cli download failed, trying curl ..."
  fi

  # Fallback to curl (public endpoint, may be rate-limited)
  if command -v curl &>/dev/null; then
    local curlUrl="https://raw.githubusercontent.com/${_DSB_TF_GH_REPO}/${branch}/${_DSB_TF_INSTALL_FILENAME}"
    _dsb_i "Downloading via curl${branchInfo} ..."
    if curl -fsSL "${curlUrl}" -o "${targetFile}" 2>/dev/null; then
      if [[ -s "${targetFile}" ]]; then
        return 0
      fi
    fi
    rm -f "${targetFile}" 2>/dev/null || :
    _dsb_e "curl download failed from: ${curlUrl}"
  fi

  _dsb_e "Failed to download script. Neither gh cli nor curl succeeded."
  _dsb_tf_error_push "download failed"
  return 1
}

# what:
#   install the script to ~/.local/bin
# input:
#   none (uses _dsbTfScriptSourcePath to locate the running script, or downloads if not available)
# returns:
#   0 on success, 1 on failure
_dsb_tf_install_script() {
  local installDir installPath
  installDir="$(_dsb_tf_get_install_dir)"
  installPath="$(_dsb_tf_get_install_path)"

  # Create install directory
  mkdir -p "${installDir}" 2>/dev/null
  if [[ ! -d "${installDir}" ]]; then
    _dsb_e "Failed to create directory: ${installDir}"
    _dsb_tf_error_push "failed to create install directory"
    return 1
  fi

  # Determine the source: local file or download
  local sourceFile="${_dsbTfScriptSourcePath:-}"
  if [[ -n "${sourceFile}" ]] && [[ -f "${sourceFile}" ]]; then
    # Check if source and destination are the same file (already installed and sourced from there)
    local resolvedSource resolvedDest
    resolvedSource="$(readlink -f "${sourceFile}" 2>/dev/null || echo "${sourceFile}")"
    resolvedDest="$(readlink -f "${installPath}" 2>/dev/null || echo "${installPath}")"
    if [[ "${resolvedSource}" == "${resolvedDest}" ]]; then
      _dsb_i "Script is already installed at ${installPath} (no copy needed)"
    elif ! cp "${sourceFile}" "${installPath}"; then
      _dsb_e "Failed to copy script to ${installPath}"
      _dsb_tf_error_push "failed to copy script"
      return 1
    fi
  else
    # No local source (loaded via process substitution) -- download from GitHub
    _dsb_i "Script was loaded via process substitution, downloading from GitHub ..."
    if ! _dsb_tf_download_script_to_file "${installPath}"; then
      return 1
    fi
  fi

  # Make executable
  chmod +x "${installPath}"

  # Update the global to reflect install location
  _dsbTfInstallDir="${installDir}"

  _dsb_i "Script installed to ${installPath}"
  return 0
}

# what:
#   download the latest version of the script and replace the local copy
# returns:
#   0 on success, 1 on failure
_dsb_tf_download_latest_script() {
  local installPath
  installPath="$(_dsb_tf_get_install_path)"

  if ! _dsb_tf_is_installed_locally; then
    _dsb_e "Helpers are not installed locally. Run tf-install-helpers first."
    _dsb_tf_error_push "helpers not installed locally"
    return 1
  fi

  # Download to a temp file first, then replace
  local tmpFile="${installPath}.tmp"
  if ! _dsb_tf_download_script_to_file "${tmpFile}"; then
    rm -f "${tmpFile}" 2>/dev/null || :
    return 1
  fi

  # Replace the installed copy
  mv "${tmpFile}" "${installPath}"
  chmod +x "${installPath}"

  _dsb_i "Script updated successfully."
  return 0
}

###################################################################################################
#
# Exposed functions
#
###################################################################################################

# Check functions
# ---------------
tf-check-dir() {
  if [[ "${-}" == *e* ]]; then set +e; tf-check-dir "$@"; local rc=$?; set -e; return "${rc}"; fi
  local returnCode

  _dsb_tf_configure_shell
  _dsb_tf_check_current_dir
  returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-check-prereqs() {
  if [[ "${-}" == *e* ]]; then set +e; tf-check-prereqs "$@"; local rc=$?; set -e; return "${rc}"; fi
  local returnCode

  _dsb_tf_configure_shell
  _dsb_tf_check_prereqs
  returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-check-tools() {
  if [[ "${-}" == *e* ]]; then set +e; tf-check-tools "$@"; local rc=$?; set -e; return "${rc}"; fi
  _dsb_tf_configure_shell

  _dsb_tf_check_tools
  local returnCode=$?

  if [ "${returnCode}" -ne 0 ]; then
    _dsb_e "Tools check failed."
  else
    _dsb_i "Tools check passed."
  fi

  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-status() {
  if [[ "${-}" == *e* ]]; then set +e; tf-status "$@"; local rc=$?; set -e; return "${rc}"; fi
  _dsb_tf_configure_shell
  _dsb_tf_report_status
  local returnCode="${returnCode:-1}"
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

# Environment functions
# ---------------------
tf-list-envs() {
  if [[ "${-}" == *e* ]]; then set +e; tf-list-envs "$@"; local rc=$?; set -e; return "${rc}"; fi
  _dsb_tf_configure_shell
  if ! _dsb_tf_require_project_repo; then _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1; fi
  _dsb_tf_list_envs
  local returnCode=$?
  if [ "${returnCode}" -eq 0 ]; then
    _dsb_i ""
    _dsb_i "To choose an environment, use either 'tf-set-env <env>' or 'tf-select-env'"
  fi
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-set-env() {
  if [[ "${-}" == *e* ]]; then set +e; tf-set-env "$@"; local rc=$?; set -e; return "${rc}"; fi
  local envToSet="${1:-}"
  _dsb_tf_configure_shell
  if ! _dsb_tf_require_project_repo; then _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1; fi
  _dsb_tf_set_env "${envToSet}"
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-select-env() {
  if [[ "${-}" == *e* ]]; then set +e; tf-select-env "$@"; local rc=$?; set -e; return "${rc}"; fi
  local envToSet="${1:-}"
  _dsb_tf_configure_shell
  if ! _dsb_tf_require_project_repo; then _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1; fi
  if [ -n "${envToSet}" ]; then
    _dsb_tf_set_env "${envToSet}"
  else
    _dsb_tf_select_env
  fi
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-clear-env() {
  _dsb_tf_configure_shell
  if ! _dsb_tf_require_project_repo; then _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1; fi
  _dsb_tf_clear_env # has no return code
  _dsb_tf_restore_shell
}

tf-unset-env() {
  _dsb_tf_configure_shell
  if ! _dsb_tf_require_project_repo; then _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1; fi
  _dsb_tf_clear_env # has no return code
  _dsb_tf_restore_shell
}

tf-check-az-auth() {
  if [[ "${-}" == *e* ]]; then set +e; tf-check-az-auth "$@"; local rc=$?; set -e; return "${rc}"; fi
  _dsb_tf_configure_shell
  if ! _dsb_tf_check_az_cli; then
    _dsb_tf_error_dump
    _dsb_tf_restore_shell
    return 1
  fi
  if ! _dsb_tf_az_is_logged_in; then
    _dsb_e "Not logged in to Azure CLI. Please run 'az login'."
    _dsb_tf_error_dump
    _dsb_tf_restore_shell
    return 1
  fi
  _dsb_tf_az_enumerate_account
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-check-gh-auth() {
  if [[ "${-}" == *e* ]]; then set +e; tf-check-gh-auth "$@"; local rc=$?; set -e; return "${rc}"; fi
  _dsb_tf_configure_shell
  _dsb_tf_check_gh_auth
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-check-env() {
  if [[ "${-}" == *e* ]]; then set +e; tf-check-env "$@"; local rc=$?; set -e; return "${rc}"; fi
  local envToCheck="${1:-}"
  _dsb_tf_configure_shell
  if ! _dsb_tf_require_project_repo; then _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1; fi
  _dsb_tf_check_env "${envToCheck}"
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

# Azure CLI functions
# -------------------
az-whoami() {
  if [[ "${-}" == *e* ]]; then set +e; az-whoami "$@"; local rc=$?; set -e; return "${rc}"; fi
  _dsb_tf_configure_shell
  _dsb_tf_az_whoami
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

az-logout() {
  if [[ "${-}" == *e* ]]; then set +e; az-logout "$@"; local rc=$?; set -e; return "${rc}"; fi
  _dsb_tf_configure_shell
  _dsb_tf_az_logout
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

az-login() {
  if [[ "${-}" == *e* ]]; then set +e; az-login "$@"; local rc=$?; set -e; return "${rc}"; fi
  _dsb_tf_configure_shell
  _dsb_tf_az_login
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

az-relog() {
  if [[ "${-}" == *e* ]]; then set +e; az-relog "$@"; local rc=$?; set -e; return "${rc}"; fi
  _dsb_tf_configure_shell
  _dsb_tf_az_re_login
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

az-set-sub() {
  if [[ "${-}" == *e* ]]; then set +e; az-set-sub "$@"; local rc=$?; set -e; return "${rc}"; fi
  _dsb_tf_configure_shell
  _dsb_tf_az_set_sub
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

az-select-sub() {
  if [[ "${-}" == *e* ]]; then set +e; az-select-sub "$@"; local rc=$?; set -e; return "${rc}"; fi
  _dsb_tf_configure_shell
  _dsb_tf_az_select_sub
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

# Terraform functions
# -------------------
tf-init-env() {
  if [[ "${-}" == *e* ]]; then set +e; tf-init-env "$@"; local rc=$?; set -e; return "${rc}"; fi
  local envName="${1:-}"
  _dsb_tf_configure_shell
  if ! _dsb_tf_require_project_repo; then _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1; fi
  _dsb_tf_init_env 0 0 "${envName}" # $1 = 0 means do not -upgrade, $2 = 0 means with backend
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-init-env-offline() {
  if [[ "${-}" == *e* ]]; then set +e; tf-init-env-offline "$@"; local rc=$?; set -e; return "${rc}"; fi
  local envName="${1:-}"
  _dsb_tf_configure_shell
  if ! _dsb_tf_require_project_repo; then _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1; fi
  _dsb_tf_init_env 0 1 "${envName}" # $1 = 0 means do not -upgrade, $2 = 1 means without backend
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-init-modules() {
  if [[ "${-}" == *e* ]]; then set +e; tf-init-modules "$@"; local rc=$?; set -e; return "${rc}"; fi
  _dsb_tf_configure_shell
  if ! _dsb_tf_require_project_repo; then _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1; fi
  _dsb_tf_init_modules
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-init-main() {
  if [[ "${-}" == *e* ]]; then set +e; tf-init-main "$@"; local rc=$?; set -e; return "${rc}"; fi
  _dsb_tf_configure_shell
  if ! _dsb_tf_require_project_repo; then _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1; fi
  _dsb_tf_init_main
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-init() {
  if [[ "${-}" == *e* ]]; then set +e; tf-init "$@"; local rc=$?; set -e; return "${rc}"; fi

  # Parse args BEFORE configure_shell (set -u not yet active)
  local envName=""
  local -a terraformArgs=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --*)      shift ;;  # ignore unknown double-dash flags (ours)
      -*)       terraformArgs+=("$1"); shift ;;  # single-dash = terraform
      *)
        if [ -z "${envName}" ]; then
          envName="$1"
        else
          terraformArgs+=("$1")
        fi
        shift
        ;;
    esac
  done

  _dsb_tf_configure_shell
  if [ "${_dsbTfRepoType}" == "module" ]; then
    _dsb_tf_init_module_root 0 "${terraformArgs[@]}"
  else
    _dsb_tf_init_full_single_env 0 0 "${envName}" "${terraformArgs[@]}" # $1 = 0 means do not -upgrade, $2 = 0 means with backend
  fi
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-init-offline() {
  if [[ "${-}" == *e* ]]; then set +e; tf-init-offline "$@"; local rc=$?; set -e; return "${rc}"; fi

  # Parse args BEFORE configure_shell (set -u not yet active)
  local envName=""
  local -a terraformArgs=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --*)      shift ;;  # ignore unknown double-dash flags (ours)
      -*)       terraformArgs+=("$1"); shift ;;  # single-dash = terraform
      *)
        if [ -z "${envName}" ]; then
          envName="$1"
        else
          terraformArgs+=("$1")
        fi
        shift
        ;;
    esac
  done

  _dsb_tf_configure_shell
  if [ "${_dsbTfRepoType}" == "module" ]; then
    _dsb_tf_init_module_root 0 "${terraformArgs[@]}" # no backend in module repos anyway
  else
    _dsb_tf_init_full_single_env 0 1 "${envName}" "${terraformArgs[@]}" # $1 = 0 means do not -upgrade, $2 = 1 means without backend
  fi
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-init-all() {
  if [[ "${-}" == *e* ]]; then set +e; tf-init-all "$@"; local rc=$?; set -e; return "${rc}"; fi
  _dsb_tf_configure_shell
  if [ "${_dsbTfRepoType}" == "module" ]; then
    _dsb_tf_init_all_module
  else
    _dsb_tf_init 0 1 0 # $1 = 0 means do not -upgrade, $2 = 1 means clear env after, $3 = 0 means with backend
  fi
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-init-all-offline() {
  if [[ "${-}" == *e* ]]; then set +e; tf-init-all-offline "$@"; local rc=$?; set -e; return "${rc}"; fi
  _dsb_tf_configure_shell
  if [ "${_dsbTfRepoType}" == "module" ]; then
    _dsb_tf_init_all_module # no backend in module repos anyway
  else
    _dsb_tf_init 0 1 1 # $1 = 0 means do not -upgrade, $2 = 1 means clear env after, $3 = 1 means without backend
  fi
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-fmt() {
  if [[ "${-}" == *e* ]]; then set +e; tf-fmt "$@"; local rc=$?; set -e; return "${rc}"; fi
  _dsb_tf_configure_shell
  _dsb_tf_fmt 0 # $1 = 0 means perform check
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-fmt-fix() {
  if [[ "${-}" == *e* ]]; then set +e; tf-fmt-fix "$@"; local rc=$?; set -e; return "${rc}"; fi
  _dsb_tf_configure_shell
  _dsb_tf_fmt 1 # $1 = 1 means perform fix
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-validate() {
  if [[ "${-}" == *e* ]]; then set +e; tf-validate "$@"; local rc=$?; set -e; return "${rc}"; fi
  local envName="${1:-}"
  _dsb_tf_configure_shell
  if [ "${_dsbTfRepoType}" == "module" ]; then
    _dsb_tf_validate_module_root
  else
    _dsb_tf_validate_env "${envName}"
  fi
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-validate-all() {
  if [[ "${-}" == *e* ]]; then set +e; tf-validate-all "$@"; local rc=$?; set -e; return "${rc}"; fi
  _dsb_tf_configure_shell
  if [ "${_dsbTfRepoType}" == "module" ]; then
    _dsb_tf_validate_all_module
  else
    _dsb_tf_validate_all_project
  fi
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-outputs() {
  if [[ "${-}" == *e* ]]; then set +e; tf-outputs "$@"; local rc=$?; set -e; return "${rc}"; fi
  local envName="${1:-}"
  _dsb_tf_configure_shell
  if [ "${_dsbTfRepoType}" == "module" ]; then
    _dsb_tf_outputs_module_root
  else
    _dsb_tf_outputs_env "${envName}"
  fi
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-plan() {
  if [[ "${-}" == *e* ]]; then set +e; tf-plan "$@"; local rc=$?; set -e; return "${rc}"; fi

  # Parse args BEFORE configure_shell (set -u not yet active)
  local envName=""
  local logFile=""
  local -a terraformArgs=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --log)    logFile="auto"; shift ;;
      --log=*)  logFile="${1#--log=}"; shift ;;
      --*)      shift ;;  # ignore unknown double-dash flags (ours)
      -*)       terraformArgs+=("$1"); shift ;;  # single-dash = terraform
      *)
        if [ -z "${envName}" ]; then
          envName="$1"
        else
          terraformArgs+=("$1")
        fi
        shift
        ;;
    esac
  done
  if [ "${logFile}" == "auto" ]; then
    logFile=$(_dsb_tf_auto_log_filename "tf-plan" "${envName}")
  fi

  _dsb_tf_configure_shell
  if ! _dsb_tf_require_project_repo; then _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1; fi
  _dsb_tf_run_with_log "${logFile}" _dsb_tf_plan_env "${envName}" "${terraformArgs[@]}"
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-apply() {
  if [[ "${-}" == *e* ]]; then set +e; tf-apply "$@"; local rc=$?; set -e; return "${rc}"; fi

  # Parse args BEFORE configure_shell (set -u not yet active)
  local envName=""
  local logFile=""
  local -a terraformArgs=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --log)    logFile="auto"; shift ;;
      --log=*)  logFile="${1#--log=}"; shift ;;
      --*)      shift ;;  # ignore unknown double-dash flags (ours)
      -*)       terraformArgs+=("$1"); shift ;;  # single-dash = terraform
      *)
        if [ -z "${envName}" ]; then
          envName="$1"
        else
          terraformArgs+=("$1")  # positional args (e.g., planfile for apply)
        fi
        shift
        ;;
    esac
  done
  if [ "${logFile}" == "auto" ]; then
    logFile=$(_dsb_tf_auto_log_filename "tf-apply" "${envName}")
  fi

  _dsb_tf_configure_shell
  if ! _dsb_tf_require_project_repo; then _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1; fi
  _dsb_tf_run_with_log "${logFile}" _dsb_tf_apply_env "${envName}" "${terraformArgs[@]}"
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-destroy() {
  if [[ "${-}" == *e* ]]; then set +e; tf-destroy "$@"; local rc=$?; set -e; return "${rc}"; fi
  local envName="${1:-}"
  _dsb_tf_configure_shell
  if ! _dsb_tf_require_project_repo; then _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1; fi
  _dsb_tf_destroy_env "${envName}"
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

# Linting functions
# -----------------

tf-lint() {
  if [[ "${-}" == *e* ]]; then set +e; tf-lint "$@"; local rc=$?; set -e; return "${rc}"; fi
  local lintArguments=()
  local envName=""

  # check if the first argument is a flag or an environment name
  if [[ ${1:-} == -* ]]; then
    lintArguments=("$@")
  else
    envName="${1:-}"
    shift || :
    lintArguments=("$@")
  fi

  _dsb_tf_configure_shell
  if [ "${_dsbTfRepoType}" == "module" ]; then
    _dsb_tf_lint_module_root "${lintArguments[@]}"
  else
    _dsb_tf_run_tflint "${envName}" "${lintArguments[@]}"
  fi
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-lint-all() {
  if [[ "${-}" == *e* ]]; then set +e; tf-lint-all "$@"; local rc=$?; set -e; return "${rc}"; fi
  _dsb_tf_configure_shell
  if [ "${_dsbTfRepoType}" == "module" ]; then
    _dsb_tf_lint_all_module
  else
    _dsb_tf_lint_all_project
  fi
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

# Clean functions
# ---------------

tf-clean() {
  if [[ "${-}" == *e* ]]; then set +e; tf-clean "$@"; local rc=$?; set -e; return "${rc}"; fi
  _dsb_tf_configure_shell
  _dsb_tf_clean_dot_directories "terraform"
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-clean-tflint() {
  if [[ "${-}" == *e* ]]; then set +e; tf-clean-tflint "$@"; local rc=$?; set -e; return "${rc}"; fi
  _dsb_tf_configure_shell
  _dsb_tf_clean_dot_directories "tflint"
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-clean-all() {
  if [[ "${-}" == *e* ]]; then set +e; tf-clean-all "$@"; local rc=$?; set -e; return "${rc}"; fi
  _dsb_tf_configure_shell
  _dsb_tf_clean_dot_directories "all"
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

# Upgrade functions
# -----------------

tf-upgrade-env() {
  if [[ "${-}" == *e* ]]; then set +e; tf-upgrade-env "$@"; local rc=$?; set -e; return "${rc}"; fi
  local envName="${1:-}"
  _dsb_tf_configure_shell
  if ! _dsb_tf_require_project_repo; then _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1; fi
  _dsb_tf_init_env 1 0 "${envName}" # $1 = 1 means do-upgrade, $2 = 0 means with backend
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-upgrade-env-offline() {
  if [[ "${-}" == *e* ]]; then set +e; tf-upgrade-env-offline "$@"; local rc=$?; set -e; return "${rc}"; fi
  local envName="${1:-}"
  _dsb_tf_configure_shell
  if ! _dsb_tf_require_project_repo; then _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1; fi
  _dsb_tf_init_env 1 1 "${envName}" # $1 = 1 means do-upgrade, $2 = 1 means without backend
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-upgrade() {
  if [[ "${-}" == *e* ]]; then set +e; tf-upgrade "$@"; local rc=$?; set -e; return "${rc}"; fi
  local envName="${1:-}"
  _dsb_tf_configure_shell
  if [ "${_dsbTfRepoType}" == "module" ]; then
    _dsb_tf_init_module_root 1 # 1 = do upgrade
  else
    _dsb_tf_init_full_single_env 1 0 "${envName}" # $1 = 1 means do -upgrade, $2 = 0 means with backend
  fi
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-upgrade-offline() {
  if [[ "${-}" == *e* ]]; then set +e; tf-upgrade-offline "$@"; local rc=$?; set -e; return "${rc}"; fi
  local envName="${1:-}"
  _dsb_tf_configure_shell
  if [ "${_dsbTfRepoType}" == "module" ]; then
    _dsb_tf_init_module_root 1 # no backend in module repos anyway
  else
    _dsb_tf_init_full_single_env 1 1 "${envName}" # $1 = 1 means do -upgrade, $2 = 1 means without backend
  fi
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-upgrade-all() {
  if [[ "${-}" == *e* ]]; then set +e; tf-upgrade-all "$@"; local rc=$?; set -e; return "${rc}"; fi
  _dsb_tf_configure_shell
  if [ "${_dsbTfRepoType}" == "module" ]; then
    # upgrade root then init all examples
    local _rc1=0 _rc2=0
    _dsb_tf_init_module_root 1 # 1 = do upgrade
    _rc1=$?
    _dsb_tf_init_examples
    _rc2=$?
    local returnCode=$((_rc1 + _rc2))
  else
    _dsb_tf_init 1 1 0 # $1 = 1 means do -upgrade, $2 = 1 means clear env after, $3 = 0 means with backend
    local returnCode=$?
  fi
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-upgrade-all-offline() {
  if [[ "${-}" == *e* ]]; then set +e; tf-upgrade-all-offline "$@"; local rc=$?; set -e; return "${rc}"; fi
  _dsb_tf_configure_shell
  if [ "${_dsbTfRepoType}" == "module" ]; then
    # same as tf-upgrade-all for modules (no backend anyway)
    local _rc1=0 _rc2=0
    _dsb_tf_init_module_root 1 # 1 = do upgrade
    _rc1=$?
    _dsb_tf_init_examples
    _rc2=$?
    local returnCode=$((_rc1 + _rc2))
  else
    _dsb_tf_init 1 1 1 # $1 = 1 means do -upgrade, $2 = 1 means clear env after, $3 = 1 means without backend
    local returnCode=$?
  fi
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-bump-cicd() {
  if [[ "${-}" == *e* ]]; then set +e; tf-bump-cicd "$@"; local rc=$?; set -e; return "${rc}"; fi
  _dsb_tf_configure_shell
  _dsb_tf_bump_github
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-bump-modules() {
  if [[ "${-}" == *e* ]]; then set +e; tf-bump-modules "$@"; local rc=$?; set -e; return "${rc}"; fi
  _dsb_tf_configure_shell
  _dsb_tf_bump_registry_module_versions
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-bump-tflint-plugins() {
  if [[ "${-}" == *e* ]]; then set +e; tf-bump-tflint-plugins "$@"; local rc=$?; set -e; return "${rc}"; fi
  _dsb_tf_configure_shell
  _dsb_tf_bump_tflint_plugin_versions
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-show-provider-upgrades() {
  if [[ "${-}" == *e* ]]; then set +e; tf-show-provider-upgrades "$@"; local rc=$?; set -e; return "${rc}"; fi
  local envToCheck="${1:-}"
  _dsb_tf_configure_shell
  if [ "${_dsbTfRepoType}" == "module" ]; then
    _dsb_tf_list_available_terraform_provider_upgrades_module
  else
    _dsb_tf_list_available_terraform_provider_upgrades_for_env "${envToCheck}"
  fi
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-show-all-provider-upgrades() {
  if [[ "${-}" == *e* ]]; then set +e; tf-show-all-provider-upgrades "$@"; local rc=$?; set -e; return "${rc}"; fi
  _dsb_tf_configure_shell
  if ! _dsb_tf_require_project_repo; then _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1; fi
  _dsb_tf_list_available_terraform_provider_upgrades
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-bump-env() {
  if [[ "${-}" == *e* ]]; then set +e; tf-bump-env "$@"; local rc=$?; set -e; return "${rc}"; fi
  local envName="${1:-}"
  _dsb_tf_configure_shell
  if ! _dsb_tf_require_project_repo; then _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1; fi
  _dsb_tf_bump_an_env "${envName}" 0 # $2 = 0 means with backend
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-bump-env-offline() {
  if [[ "${-}" == *e* ]]; then set +e; tf-bump-env-offline "$@"; local rc=$?; set -e; return "${rc}"; fi
  local envName="${1:-}"
  _dsb_tf_configure_shell
  if ! _dsb_tf_require_project_repo; then _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1; fi
  _dsb_tf_bump_an_env "${envName}" 1 # $2 = 1 means without backend
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-bump() {
  if [[ "${-}" == *e* ]]; then set +e; tf-bump "$@"; local rc=$?; set -e; return "${rc}"; fi
  local envName="${1:-}"
  _dsb_tf_configure_shell
  if [ "${_dsbTfRepoType}" == "module" ]; then
    _dsb_tf_bump_module_repo
  else
    _dsb_tf_bump_the_project_single_env 0 "${envName}" # $1 = 0 means with backend
  fi
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-bump-offline() {
  if [[ "${-}" == *e* ]]; then set +e; tf-bump-offline "$@"; local rc=$?; set -e; return "${rc}"; fi
  local envName="${1:-}"
  _dsb_tf_configure_shell
  if [ "${_dsbTfRepoType}" == "module" ]; then
    _dsb_tf_bump_module_repo # same as tf-bump for modules (no backend anyway)
  else
    _dsb_tf_bump_the_project_single_env 1 "${envName}" # $1 = 1 means without backend
  fi
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-bump-all() {
  if [[ "${-}" == *e* ]]; then set +e; tf-bump-all "$@"; local rc=$?; set -e; return "${rc}"; fi
  _dsb_tf_configure_shell
  if [ "${_dsbTfRepoType}" == "module" ]; then
    _dsb_tf_bump_module_repo # same as tf-bump for modules
  else
    _dsb_tf_bump_the_project 0 # $1 = 0 means with backend
  fi
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-bump-all-offline() {
  if [[ "${-}" == *e* ]]; then set +e; tf-bump-all-offline "$@"; local rc=$?; set -e; return "${rc}"; fi
  _dsb_tf_configure_shell
  if [ "${_dsbTfRepoType}" == "module" ]; then
    _dsb_tf_bump_module_repo # same as tf-bump for modules (no backend anyway)
  else
    _dsb_tf_bump_the_project 1 # $1 = 1 means without backend
  fi
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

# Examples functions (module repo only)
# -------------------------------------

tf-init-all-examples() {
  if [[ "${-}" == *e* ]]; then set +e; tf-init-all-examples "$@"; local rc=$?; set -e; return "${rc}"; fi
  local exampleName="${1:-}"
  _dsb_tf_configure_shell
  if ! _dsb_tf_require_module_repo; then _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1; fi
  _dsb_tf_init_examples "${exampleName}"
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-init-example() {
  if [[ "${-}" == *e* ]]; then set +e; tf-init-example "$@"; local rc=$?; set -e; return "${rc}"; fi
  local exampleName="${1:-}"
  _dsb_tf_configure_shell
  if ! _dsb_tf_require_module_repo; then _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1; fi
  if [ -z "${exampleName}" ]; then
    _dsb_e "No example specified."
    _dsb_e "  usage: tf-init-example <example-name>"
    _dsb_e "  available examples: $(printf '%s\n' "${!_dsbTfExamplesDirList[@]}" | sort | paste -sd', ')"
    _dsb_tf_error_push "no example name provided"
    _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1
  fi
  _dsb_tf_init_examples "${exampleName}"
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then _dsb_tf_error_dump; fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-validate-all-examples() {
  if [[ "${-}" == *e* ]]; then set +e; tf-validate-all-examples "$@"; local rc=$?; set -e; return "${rc}"; fi
  local exampleName="${1:-}"
  _dsb_tf_configure_shell
  if ! _dsb_tf_require_module_repo; then _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1; fi
  _dsb_tf_validate_examples "${exampleName}"
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-validate-example() {
  if [[ "${-}" == *e* ]]; then set +e; tf-validate-example "$@"; local rc=$?; set -e; return "${rc}"; fi
  local exampleName="${1:-}"
  _dsb_tf_configure_shell
  if ! _dsb_tf_require_module_repo; then _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1; fi
  if [ -z "${exampleName}" ]; then
    _dsb_e "No example specified."
    _dsb_e "  usage: tf-validate-example <example-name>"
    _dsb_e "  available examples: $(printf '%s\n' "${!_dsbTfExamplesDirList[@]}" | sort | paste -sd', ')"
    _dsb_tf_error_push "no example name provided"
    _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1
  fi
  _dsb_tf_validate_examples "${exampleName}"
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then _dsb_tf_error_dump; fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-lint-all-examples() {
  if [[ "${-}" == *e* ]]; then set +e; tf-lint-all-examples "$@"; local rc=$?; set -e; return "${rc}"; fi
  local exampleName="${1:-}"
  _dsb_tf_configure_shell
  if ! _dsb_tf_require_module_repo; then _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1; fi
  _dsb_tf_lint_examples "${exampleName}"
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-lint-example() {
  if [[ "${-}" == *e* ]]; then set +e; tf-lint-example "$@"; local rc=$?; set -e; return "${rc}"; fi
  local exampleName="${1:-}"
  _dsb_tf_configure_shell
  if ! _dsb_tf_require_module_repo; then _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1; fi
  if [ -z "${exampleName}" ]; then
    _dsb_e "No example specified."
    _dsb_e "  usage: tf-lint-example <example-name>"
    _dsb_e "  available examples: $(printf '%s\n' "${!_dsbTfExamplesDirList[@]}" | sort | paste -sd', ')"
    _dsb_tf_error_push "no example name provided"
    _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1
  fi
  _dsb_tf_lint_examples "${exampleName}"
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then _dsb_tf_error_dump; fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

# Testing functions (module repo only)
# -------------------------------------

tf-test() {
  if [[ "${-}" == *e* ]]; then set +e; tf-test "$@"; local rc=$?; set -e; return "${rc}"; fi

  # Parse args BEFORE configure_shell (set -u not yet active)
  local testFilter=""
  local logFile=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --log)    logFile="auto"; shift ;;
      --log=*)  logFile="${1#--log=}"; shift ;;
      --*)      shift ;;
      *)
        if [ -z "${testFilter}" ]; then
          testFilter="$1"
        fi
        shift
        ;;
    esac
  done
  if [ "${logFile}" == "auto" ]; then
    logFile=$(_dsb_tf_auto_log_filename "tf-test" "")
  fi

  _dsb_tf_configure_shell
  if ! _dsb_tf_require_module_repo; then _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1; fi

  _dsb_tf_enumerate_directories

  # determine if we need subscription confirmation
  local needsSubscription=0
  if [ -n "${testFilter}" ]; then
    # specific test file -- check if it's an integration test
    if [[ "${testFilter}" == integration-* ]]; then
      needsSubscription=1
    fi
  elif [ "${#_dsbTfIntegrationTestFilesList[@]}" -gt 0 ]; then
    # no filter and integration tests exist -- will run them
    needsSubscription=1
  fi

  if [ "${needsSubscription}" -eq 1 ]; then
    if ! _dsb_tf_require_azure_subscription; then
      _dsb_tf_error_dump
      _dsb_tf_restore_shell
      return 1
    fi
  fi

  if [ -n "${testFilter}" ]; then
    _dsb_tf_run_with_log "${logFile}" _dsb_tf_run_terraform_test "${testFilter}"
  else
    _dsb_tf_run_with_log "${logFile}" _dsb_tf_run_terraform_test
  fi
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-test-unit() {
  if [[ "${-}" == *e* ]]; then set +e; tf-test-unit "$@"; local rc=$?; set -e; return "${rc}"; fi

  # Parse args BEFORE configure_shell (set -u not yet active)
  local logFile=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --log)    logFile="auto"; shift ;;
      --log=*)  logFile="${1#--log=}"; shift ;;
      --*)      shift ;;
      *)        shift ;;
    esac
  done
  if [ "${logFile}" == "auto" ]; then
    logFile=$(_dsb_tf_auto_log_filename "tf-test-unit" "")
  fi

  _dsb_tf_configure_shell
  if ! _dsb_tf_require_module_repo; then _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1; fi

  _dsb_tf_enumerate_directories

  if [ "${#_dsbTfUnitTestFilesList[@]}" -eq 0 ]; then
    _dsb_w "No unit test files found (matching unit-*.tftest.hcl)."
    _dsb_tf_restore_shell
    return 0
  fi

  local -a unitFilters=()
  local _utFile
  for _utFile in "${_dsbTfUnitTestFilesList[@]}"; do
    unitFilters+=("$(basename "${_utFile}")")
  done

  _dsb_tf_run_with_log "${logFile}" _dsb_tf_run_terraform_test "${unitFilters[@]}"
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-test-integration() {
  if [[ "${-}" == *e* ]]; then set +e; tf-test-integration "$@"; local rc=$?; set -e; return "${rc}"; fi

  # Parse args BEFORE configure_shell (set -u not yet active)
  local testName=""
  local logFile=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --log)    logFile="auto"; shift ;;
      --log=*)  logFile="${1#--log=}"; shift ;;
      --*)      shift ;;
      *)
        if [ -z "${testName}" ]; then
          testName="$1"
        fi
        shift
        ;;
    esac
  done
  if [ "${logFile}" == "auto" ]; then
    logFile=$(_dsb_tf_auto_log_filename "tf-test-integration" "${testName}")
  fi

  _dsb_tf_configure_shell
  if ! _dsb_tf_require_module_repo; then _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1; fi

  _dsb_tf_enumerate_directories

  if [ -z "${testName}" ]; then
    _dsb_e "No integration test name specified."
    _dsb_e "  usage: tf-test-integration <name>"
    if [ "${#_dsbTfIntegrationTestFilesList[@]}" -gt 0 ]; then
      local -a availNames=()
      local _itf
      for _itf in "${_dsbTfIntegrationTestFilesList[@]}"; do
        availNames+=("$(basename "${_itf}")")
      done
      _dsb_e "  available integration tests: ${availNames[*]}"
    fi
    _dsb_tf_error_push "no integration test name provided"
    _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1
  fi

  # validate the file exists in the integration test list
  local _found=0
  local _itFile
  for _itFile in "${_dsbTfIntegrationTestFilesList[@]}"; do
    if [ "$(basename "${_itFile}")" == "${testName}" ]; then
      _found=1
      break
    fi
  done
  if [ "${_found}" -eq 0 ]; then
    _dsb_e "Integration test '${testName}' not found in integration test files."
    if [ "${#_dsbTfIntegrationTestFilesList[@]}" -gt 0 ]; then
      local -a availNames2=()
      local _itf2
      for _itf2 in "${_dsbTfIntegrationTestFilesList[@]}"; do
        availNames2+=("$(basename "${_itf2}")")
      done
      _dsb_e "  available integration tests: ${availNames2[*]}"
    fi
    _dsb_tf_error_push "integration test '${testName}' not found"
    _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1
  fi

  if ! _dsb_tf_require_azure_subscription; then
    _dsb_tf_error_dump
    _dsb_tf_restore_shell
    return 1
  fi

  _dsb_tf_run_with_log "${logFile}" _dsb_tf_run_terraform_test "${testName}"
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-test-all-integrations() {
  if [[ "${-}" == *e* ]]; then set +e; tf-test-all-integrations "$@"; local rc=$?; set -e; return "${rc}"; fi

  # Parse args BEFORE configure_shell (set -u not yet active)
  local logFile=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --log)    logFile="auto"; shift ;;
      --log=*)  logFile="${1#--log=}"; shift ;;
      --*)      shift ;;
      *)        shift ;;
    esac
  done
  if [ "${logFile}" == "auto" ]; then
    logFile=$(_dsb_tf_auto_log_filename "tf-test-all-integrations" "")
  fi

  _dsb_tf_configure_shell
  if ! _dsb_tf_require_module_repo; then _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1; fi

  _dsb_tf_enumerate_directories

  if [ "${#_dsbTfIntegrationTestFilesList[@]}" -eq 0 ]; then
    _dsb_w "No integration test files found (matching integration-*.tftest.hcl)."
    _dsb_tf_restore_shell
    return 0
  fi

  if ! _dsb_tf_require_azure_subscription; then
    _dsb_tf_error_dump
    _dsb_tf_restore_shell
    return 1
  fi

  local -a integrationFilters=()
  local _itFile
  for _itFile in "${_dsbTfIntegrationTestFilesList[@]}"; do
    integrationFilters+=("$(basename "${_itFile}")")
  done

  _dsb_tf_run_with_log "${logFile}" _dsb_tf_run_terraform_test "${integrationFilters[@]}"
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-test-all-examples() {
  if [[ "${-}" == *e* ]]; then set +e; tf-test-all-examples "$@"; local rc=$?; set -e; return "${rc}"; fi

  # Parse args BEFORE configure_shell (set -u not yet active)
  local exampleName=""
  local logFile=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --log)    logFile="auto"; shift ;;
      --log=*)  logFile="${1#--log=}"; shift ;;
      --*)      shift ;;
      *)
        if [ -z "${exampleName}" ]; then
          exampleName="$1"
        fi
        shift
        ;;
    esac
  done
  if [ "${logFile}" == "auto" ]; then
    logFile=$(_dsb_tf_auto_log_filename "tf-test-all-examples" "")
  fi

  _dsb_tf_configure_shell
  if ! _dsb_tf_require_module_repo; then _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1; fi

  if ! _dsb_tf_require_azure_subscription; then
    _dsb_tf_error_dump
    _dsb_tf_restore_shell
    return 1
  fi

  _dsb_tf_run_with_log "${logFile}" _dsb_tf_test_examples "${exampleName}"
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-test-example() {
  if [[ "${-}" == *e* ]]; then set +e; tf-test-example "$@"; local rc=$?; set -e; return "${rc}"; fi

  # Parse args BEFORE configure_shell (set -u not yet active)
  local exampleName=""
  local logFile=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --log)    logFile="auto"; shift ;;
      --log=*)  logFile="${1#--log=}"; shift ;;
      --*)      shift ;;
      *)
        if [ -z "${exampleName}" ]; then
          exampleName="$1"
        fi
        shift
        ;;
    esac
  done
  if [ "${logFile}" == "auto" ]; then
    logFile=$(_dsb_tf_auto_log_filename "tf-test-example" "${exampleName}")
  fi

  _dsb_tf_configure_shell
  if ! _dsb_tf_require_module_repo; then _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1; fi

  if [ -z "${exampleName}" ]; then
    _dsb_e "No example specified."
    _dsb_e "  usage: tf-test-example <example-name>"
    _dsb_e "  available examples: $(printf '%s\n' "${!_dsbTfExamplesDirList[@]}" | sort | paste -sd', ')"
    _dsb_tf_error_push "no example name provided"
    _dsb_tf_error_dump
    _dsb_tf_restore_shell
    return 1
  fi

  if ! _dsb_tf_require_azure_subscription; then
    _dsb_tf_error_dump
    _dsb_tf_restore_shell
    return 1
  fi

  _dsb_tf_run_with_log "${logFile}" _dsb_tf_test_examples "${exampleName}"
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

# Documentation functions (module repo only)
# -------------------------------------------

tf-docs() {
  if [[ "${-}" == *e* ]]; then set +e; tf-docs "$@"; local rc=$?; set -e; return "${rc}"; fi
  _dsb_tf_configure_shell
  if ! _dsb_tf_require_module_repo; then _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1; fi
  _dsb_tf_docs_root
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-docs-all-examples() {
  if [[ "${-}" == *e* ]]; then set +e; tf-docs-all-examples "$@"; local rc=$?; set -e; return "${rc}"; fi
  local exampleName="${1:-}"
  _dsb_tf_configure_shell
  if ! _dsb_tf_require_module_repo; then _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1; fi
  _dsb_tf_docs_examples "${exampleName}"
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-docs-example() {
  if [[ "${-}" == *e* ]]; then set +e; tf-docs-example "$@"; local rc=$?; set -e; return "${rc}"; fi
  local exampleName="${1:-}"
  _dsb_tf_configure_shell
  if ! _dsb_tf_require_module_repo; then _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1; fi
  if [ -z "${exampleName}" ]; then
    _dsb_e "No example specified."
    _dsb_e "  usage: tf-docs-example <example-name>"
    _dsb_e "  available examples: $(printf '%s\n' "${!_dsbTfExamplesDirList[@]}" | sort | paste -sd', ')"
    _dsb_tf_error_push "no example name provided"
    _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1
  fi
  _dsb_tf_docs_examples "${exampleName}"
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then _dsb_tf_error_dump; fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-docs-all() {
  if [[ "${-}" == *e* ]]; then set +e; tf-docs-all "$@"; local rc=$?; set -e; return "${rc}"; fi
  _dsb_tf_configure_shell
  if ! _dsb_tf_require_module_repo; then _dsb_tf_error_dump; _dsb_tf_restore_shell; return 1; fi

  _dsb_tf_docs_root
  local rootRC=$?
  _dsb_tf_docs_examples
  local examplesRC=$?

  local returnCode=$((rootRC + examplesRC))
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

# Setup/install functions
# ----------------------
tf-install-helpers() {
  if [[ "${-}" == *e* ]]; then set +e; tf-install-helpers "$@"; local rc=$?; set -e; return "${rc}"; fi
  _dsb_tf_configure_shell

  # Install the script
  if ! _dsb_tf_install_script; then
    _dsb_tf_error_dump
    _dsb_tf_restore_shell
    return 1
  fi

  # Ask about shell profile alias (skip if already present)
  local profileFile
  profileFile=$(_dsb_tf_get_shell_profile 2>/dev/null) || profileFile=""
  if [[ -n "${profileFile}" ]] && grep -qF "${_DSB_TF_PROFILE_MARKER}" "${profileFile}" 2>/dev/null; then
    _dsb_i "Shell alias tf-load-helpers already configured in ${profileFile}"
  else
    local addAlias=""
    _dsb_i ""
    _dsb_i "Would you like to add a 'tf-load-helpers' alias to your shell profile?"
    _dsb_i "This lets you load the helpers by typing: tf-load-helpers"
    read -r -p "Add alias? (y/n): " addAlias

    if [[ "${addAlias}" == "y" || "${addAlias}" == "Y" ]]; then
      if ! _dsb_tf_add_shell_alias; then
        _dsb_tf_error_dump
        _dsb_tf_restore_shell
        return 1
      fi
    fi
  fi

  _dsb_i ""
  _dsb_i "Installation complete."

  _dsb_tf_restore_shell
  return 0
}

tf-uninstall-helpers() {
  if [[ "${-}" == *e* ]]; then set +e; tf-uninstall-helpers "$@"; local rc=$?; set -e; return "${rc}"; fi
  _dsb_tf_configure_shell

  local installPath
  installPath="$(_dsb_tf_get_install_path)"

  if ! _dsb_tf_is_installed_locally; then
    _dsb_w "Helpers are not installed locally (nothing to uninstall)."
    _dsb_tf_restore_shell
    return 0
  fi

  # Ask for confirmation
  local confirm=""
  _dsb_i "This will remove the helpers script from ${installPath}"
  _dsb_i "and remove the tf-load-helpers alias from your shell profile (if present)."
  read -r -p "Proceed? (y/n): " confirm

  if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
    _dsb_i "Uninstall cancelled."
    _dsb_tf_restore_shell
    return 0
  fi

  # Remove the shell alias first
  _dsb_tf_remove_shell_alias

  # Remove the installed script
  rm -f "${installPath}" 2>/dev/null || :

  # Clear the install dir global
  _dsbTfInstallDir=""

  _dsb_i "Helpers uninstalled successfully."
  _dsb_tf_restore_shell
  return 0
}

tf-update-helpers() {
  if [[ "${-}" == *e* ]]; then set +e; tf-update-helpers "$@"; local rc=$?; set -e; return "${rc}"; fi
  _dsb_tf_configure_shell

  local installPath
  installPath="$(_dsb_tf_get_install_path)"

  if ! _dsb_tf_is_installed_locally; then
    _dsb_e "Helpers are not installed locally. Run tf-install-helpers first."
    _dsb_tf_error_push "helpers not installed locally"
    _dsb_tf_error_dump
    _dsb_tf_restore_shell
    return 1
  fi

  if ! _dsb_tf_download_latest_script; then
    _dsb_tf_error_dump
    _dsb_tf_restore_shell
    return 1
  fi

  _dsb_i "Reloading helpers from updated script..."
  _dsb_tf_restore_shell

  # Re-source the updated script
  # shellcheck disable=SC1090
  source "${installPath}"
  return $?
}

tf-reload-helpers() {
  if [[ "${-}" == *e* ]]; then set +e; tf-reload-helpers "$@"; local rc=$?; set -e; return "${rc}"; fi
  _dsb_tf_configure_shell

  local installPath
  installPath="$(_dsb_tf_get_install_path)"

  if ! _dsb_tf_is_installed_locally; then
    _dsb_e "Helpers are not installed locally. Run tf-install-helpers first."
    _dsb_tf_error_push "helpers not installed locally"
    _dsb_tf_error_dump
    _dsb_tf_restore_shell
    return 1
  fi

  _dsb_i "Reloading helpers from ${installPath}..."
  _dsb_tf_restore_shell

  # Re-source the installed script
  # shellcheck disable=SC1090
  source "${installPath}"
  local rc=$?
  if [ "${rc}" -eq 0 ]; then
    _dsb_i "Helpers reloaded successfully."
  fi
  return "${rc}"
}

# Unload function
# ----------------
tf-unload-helpers() {
  # Remove all global variables with _dsbTf prefix
  local _varNames
  _varNames=$(typeset -p 2>/dev/null | awk '$3 ~ /^_dsbTf/ { sub(/=.*/, "", $3); print $3 }') || _varNames=''
  local _varName
  for _varName in ${_varNames}; do
    unset -v "${_varName}" 2>/dev/null || :
  done

  # Remove tab completions for tf-* and az-*
  local _completions
  _completions=$(complete -p 2>/dev/null | grep -oE '(tf-|az-)[^ ]+') || _completions=''
  local _comp
  for _comp in ${_completions}; do
    complete -r "${_comp}" 2>/dev/null || :
  done

  # Remove all functions with known prefixes
  local _funcNames
  _funcNames=$(declare -F | awk '{print $3}' | grep -E '^(_dsb_|tf-|az-)') || _funcNames=''
  local _funcName
  for _funcName in ${_funcNames}; do
    unset -f "${_funcName}" 2>/dev/null || :
  done

  # Remove the error stack array
  unset -v _dsbTfErrorStack 2>/dev/null || :

  # Remove setup constants
  unset -v _DSB_TF_INSTALL_FILENAME _DSB_TF_PROFILE_MARKER _DSB_TF_GH_REPO 2>/dev/null || :

  # Remove ARM_SUBSCRIPTION_ID if we set it
  unset ARM_SUBSCRIPTION_ID 2>/dev/null || :

  # Clean up temp files
  rm -f "/tmp/dsb-tf-helpers-$$-"* 2>/dev/null || :

  # Finally unset ourselves
  unset -f tf-unload-helpers 2>/dev/null || :

  echo "DSB Terraform Helpers unloaded."
}

# Help functions
# --------------
tf-help() {
  local arg="${1:-}"
  _dsb_tf_configure_shell
  _dsb_tf_help "${arg}"
  _dsb_tf_restore_shell
}

# Version information functions
# ----------------------------
tf-versions() {
  if [[ "${-}" == *e* ]]; then set +e; tf-versions "$@"; local rc=$?; set -e; return "${rc}"; fi
  _dsb_tf_configure_shell
  _dsb_tf_versions
  local returnCode=$?
  if [ "${returnCode}" -ne 0 ]; then
    _dsb_tf_error_dump
  fi
  _dsb_tf_restore_shell
  return "${returnCode}"
}

###################################################################################################
#
# Init: final setup
#
###################################################################################################

# Record the source path of this script for setup commands
# BASH_SOURCE[0] is the path to this file when sourced from a file,
# or /dev/fd/N when sourced via process substitution (source <(curl ...))
_dsbTfScriptSourcePath="${BASH_SOURCE[0]:-}" || _dsbTfScriptSourcePath=""
# Clear if it's not a real file (e.g., /dev/fd/N from process substitution)
if [[ -z "${_dsbTfScriptSourcePath}" ]] || [[ ! -f "${_dsbTfScriptSourcePath}" ]] || [[ "${_dsbTfScriptSourcePath}" == /dev/* ]] || [[ "${_dsbTfScriptSourcePath}" == /proc/* ]]; then
  _dsbTfScriptSourcePath=""
fi
# Track install location if already installed
if _dsb_tf_is_installed_locally 2>/dev/null; then
  _dsbTfInstallDir="$(_dsb_tf_get_install_dir)" || _dsbTfInstallDir=""
else
  _dsbTfInstallDir=""
fi

# TODO: consider this scrolling other places as well
printf "\033[2J\033[H" # Scroll the shell output to hide previous output without clearing the buffer
_dsb_tf_enumerate_directories || :
_dsb_tf_register_all_completions || :
if [ "${_dsbTfRepoType:-}" == "module" ]; then
  _dsb_i "DSB Terraform Module Helpers 🚀"
  _dsb_i "  repo type: module"
else
  _dsb_i "DSB Terraform Project Helpers 🚀"
fi
_dsb_i "  to get started, run 'tf-help' or 'tf-status'"
} # this ensures the entire script is downloaded before execution
