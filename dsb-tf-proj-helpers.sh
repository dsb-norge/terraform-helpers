#!/usr/bin/env bash
# cSpell: ignore dsb, tflint, azurerm, az, tf, gh, cpanm, realpath, tfupdate, coreutils, grealpath, nonewline, prereq, prereqs, commaseparated, graphviz, libexpat, mktemp, wedi, relog, cicd, hcledit, CWORD, GOPATH, minamijoyo, reqs, chdir, alnum, ruleset
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
#
#     internal functions
#       are those prefixed with '_dsb_'
#       these are not intended to be called directly from the command line
#       they come in two flavors, see function documentation for details:
#         - those that return their exit code in _dsbTfReturnCode
#           - some of these may return 1 directly in case of internal errors
#           - many of these populate global variables to persist results
#         - those that return their exit code directly
#           - these rarely update global variables
#
#     utility functions
#       are also prefixed with '_dsb_'
#       these are not intended to be called directly from the command line
#       typically they do not return exit code explicitly
#       they are for things like logging, error handling, displaying help, and other common tasks
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
# TODO: future functionality
#   other
#     support for module projects, need to update directory enumeration functions, and block env input for many functions?
#     tf-test         -> terraform test, could support both tf projects and module projects
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
  functionNames=$(declare -F | grep -e " ${prefix}" | cut --fields 3 --delimiter=' ') || functionNames=''
  for functionName in ${functionNames}; do
    unset -f "${functionName}" || :
  done
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

declare -g _dsbTfTflintWrapperDir=""    # directory where the tflint wrapper script will be placed
declare -g _dsbTfTflintWrapperScript="" # full path to the tflint wrapper script

declare -g _dsbTfRealpathCmd="" # the command to use for realpath

declare -g _dsbTfSelectedEnv=""                        # the currently selected environment is persisted here
declare -g _dsbTfSelectedEnvDir=""                     # full path to the directory of the currently selected environment
declare -g _dsbTfSelectedEnvLockFile=""                # full path to the lock file of the currently selected environment
declare -g _dsbTfSelectedEnvSubscriptionHintFile=""    # full path to the subscription hint file of the currently selected environment
declare -g _dsbTfSelectedEnvSubscriptionHintContent="" # content of the subscription hint file of the currently selected environment

declare -g _dsbTfAzureUpn=""         # Azure UPN of the currently logged in user
declare -g _dsbTfSubscriptionId=""   # Azure subscription ID of the currently selected subscription
declare -g _dsbTfSubscriptionName="" # Azure subscription name of the currently selected subscription

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
#   return 1
# input:
#   none
# returns:
#   1
_dsb_ie_raise_error() {
  return 1
}

# what:
#   log and raise an internal error
# input:
#   $1 : message
_dsb_internal_error() {
  local messages=("$@")
  local caller=${FUNCNAME[1]}
  local message
  for message in "${messages[@]}"; do
    _dsb_ie "${caller}" "${message}"
  done
  # trapping does not work if enabled from within the same function that returns 1
  # thus we go one level deeper to raise the error
  _dsb_tf_error_start_trapping
  _dsb_ie_raise_error
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
  _dsbTfRealpathCmd="grealpath" # location of realpath binary
elif [[ $(uname -m) == "aarch64" ]] && [[ $(uname -s) == "Linux" ]]; then
  # ARM64 Linux
  _dsbTfRealpathCmd="realpath"
elif [[ $(uname -m) == "x86_64" ]] && [[ $(uname -s) == "Linux" ]]; then
  # x86_64 Linux
  _dsbTfRealpathCmd="realpath"
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
#   exit code in _dsbTfReturnCode
#   internal errors return 1 directly
_dsb_tf_report_status() {
  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_prereqs
  local prereqStatus="${_dsbTfReturnCode}"

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
        _dsb_internal_error "Internal error: Azure UPN not found." \
          "  expected in _dsbTfAzureUpn, which is: ${_dsbTfAzureUpn:-}" \
          "  azUpn is: ${azUpn}"
        return 1
      fi
      azSubId="${_dsbTfSubscriptionId:-}"
      azSubName="${_dsbTfSubscriptionName:-}"
      if [ -z "${azSubId}" ]; then
        _dsb_internal_error "Internal error: Azure Subscription ID not found." \
          "  expected in _dsbTfSubscriptionId, which is: ${_dsbTfSubscriptionId:-}" \
          "  azSubId is: ${azSubId}"
        return 1
      fi
      if [ -z "${azSubName}" ]; then
        _dsb_internal_error "Internal error: Azure Subscription ID not found." \
          "  expected in _dsbTfSubscriptionId, which is: ${_dsbTfSubscriptionName:-}" \
          "  azSubName is: ${azSubName}"
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
  _dsb_i "  Root directory          : ${_dsbTfRootDir}"
  _dsb_i "  Environments directory  : ${envsDir}"
  _dsb_i "  Modules directory       : ${modulesDir}"
  _dsb_i "  Available modules       : ${availableModulesCommaSeparated}"
  _dsb_i ""
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
      _dsb_i "  \e[32m☑\e[0m  Environment directory    : ${selectedEnvDir}"
      if [ ${lockFileStatus} -eq 0 ]; then
        _dsb_i "  \e[32m☑\e[0m  Lock file                : ${_dsbTfSelectedEnvLockFile}"
      else
        _dsb_i "  \e[31m☒\e[0m  Lock file                : not found, please run 'tf-check-env ${selectedEnv}'"
      fi
      if [ ${subHintFileStatus} -eq 0 ]; then
        _dsb_i "  \e[32m☑\e[0m  Subscription hint file   : ${_dsbTfSelectedEnvSubscriptionHintFile}"
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
  if [ ${returnCode} -ne 0 ]; then
    _dsb_i ""
    _dsb_w "not all green 🧐"
  fi

  _dsbTfReturnCode=$returnCode
  _dsb_d "returning exit code in _dsbTfReturnCode=${_dsbTfReturnCode:-}"
  return 0
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
  caller=${FUNCNAME[1]}
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
    mv "${tmpFile}" ${outFile}

    replacements[${funcName}]="${newFuncName}" # record the replacement
  done

  # ignore uninteresting functions
  # shellcheck disable=SC2016
  local ignoreStatic='($unset.*|_dsb_[wedi](\(\))?|$_dsb_tf_error_.*|_dsb_tf_configure_shell(\(\))?|_dsb_tf_restore_shell.*(\(\))?|$_dsb_tf_help.*|_dsb_tf_completions(\(\))?|$_dsb_tf_register_.*|$_dsb_tf_debug_.*'

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
  rm ${outFile}
}

###################################################################################################
#
# Utility functions: error handling
#
###################################################################################################

_dsb_tf_error_handler() {
  # Remove error trapping to prevent the error handler from being triggered
  local returnCode=${1:-$?}

  _dsb_d "error handler input: $*"

  _dsbTfLogErrors=1
  _dsb_tf_error_stop_trapping

  if [ "${returnCode}" -ne 0 ]; then
    _dsb_e "Error occurred:"
    _dsb_e "  file      : dsb-tf-proj-helpers.sh" # hardcoded because file will be sourced by curl
    _dsb_e "  line      : ${BASH_LINENO[0]} (dsb-tf-proj-helpers.sh:${BASH_LINENO[0]})"
    _dsb_e "  function  : ${FUNCNAME[1]}"
    _dsb_e "  command   : ${BASH_COMMAND}"
    _dsb_e "  exit code : ${returnCode}"
    _dsb_e "Call stack:"
    for ((i = 1; i < ${#FUNCNAME[@]}; i++)); do
      _dsb_e "  ${FUNCNAME[$i]} called at (dsb-tf-proj-helpers.sh:${BASH_LINENO[$((i - 1))]})"
    done
    _dsb_e "Operation aborted."
  fi

  _dsb_tf_restore_shell

  _dsb_d "returning code: ${returnCode}"
  return "${returnCode}"
}

_dsb_tf_error_start_trapping() {
  # Enable strict mode with the following options:
  # -E: Inherit ERR trap in sub-shells
  # -o pipefail: Return the exit status of the last command in the pipeline that failed
  set -Eo pipefail

  # Signals:
  # - ERR: This signal is triggered when a command fails. It is useful for error handling in scripts.
  # - SIGHUP: This signal is sent to a process when its controlling terminal is closed. It is often used to reload configuration files.
  # - SIGINT: This signal is sent when an interrupt is generated (usually by pressing Ctrl+C). It is used to stop a process gracefully.
  trap '_dsb_tf_error_handler $?' ERR SIGHUP SIGINT

  _dsb_d "error trapping started from ${FUNCNAME[1]}"
}

_dsb_tf_error_stop_trapping() {
  set +Eo pipefail
  trap - ERR SIGHUP SIGINT
  _dsb_d "error trapping stopped ${FUNCNAME[1]}"
}

_dsb_tf_configure_shell() {
  _dsb_d "configuring shell"

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

  declare -ga _dsbTfFilesList=()
  declare -ga _dsbTfLintConfigFilesList=()
  declare -gA _dsbTfEnvsDirList=()
  declare -ga _dsbTfAvailableEnvs=()
  declare -gA _dsbTfModulesDirList=()
  unset _dsbTfReturnCode
}

_dsb_tf_restore_shell() {
  _dsb_d "restoring shell"

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
    "az-whoami"
    # checks
    "tf-check-dir"
    "tf-check-env"
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
    "tf-fmt"
    "tf-fmt-fix"
    "tf-validate"
    "tf-plan"
    "tf-apply"
    "tf-destroy"
    # upgrading
    "tf-upgrade"
    "tf-upgrade-env"
    "tf-upgrade-all"
    "tf-bump-cicd"
    "tf-bump-modules"
    "tf-bump-tflint-plugins"
    "tf-show-provider-upgrades"
    "tf-show-all-provider-upgrades"
    "tf-bump"
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
  )
  local -a validCommands
  mapfile -t validCommands < <(_dsb_tf_help_get_commands_supported_by_help)
  echo "${validGroups[@]}" "${validCommands[@]}"
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
  terraform)
    _dsb_tf_help_group_terraform
    ;;
  upgrading)
    _dsb_tf_help_group_upgrading
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
  _dsb_i "  A collection of functions to help working with DSB Terraform projects."
  _dsb_i "  All available commands are organized into groups."
  _dsb_i "  Below are commands for getting help with groups or specific commands."
  _dsb_i ""
  _dsb_i "General Help:"
  _dsb_i "  tf-help groups    -> show all command groups"
  _dsb_i "  tf-help [group]   -> show help for a specific command group"
  _dsb_i "  tf-help commands  -> show all commands, make sure to group and indent commands by group"
  _dsb_i "  tf-help [command] -> show help for a specific command"
  _dsb_i "  tf-help all       -> show all help"
  _dsb_i ""
  _dsb_i "Common Commands:"
  _dsb_i "  tf-status         -> Show status of tools, authentication, and environment"
  _dsb_i "  az-relog          -> Azure re-login"
  _dsb_i "  tf-set-env [env]  -> Set environment"
  _dsb_i "  tf-init           -> Initialize Terraform project"
  _dsb_i "  tf-upgrade        -> Upgrade Terraform dependencies (within existing version constraints)"
  _dsb_i "  tf-fmt-fix        -> Run syntax check and fix recursively from current directory"
  _dsb_i "  tf-validate       -> Make Terraform validate the project"
  _dsb_i "  tf-plan           -> Make Terraform create a plan"
  _dsb_i "  tf-apply          -> Make Terraform apply changes"
  _dsb_i "  tf-lint           -> Run tflint"
  _dsb_i ""
  _dsb_i "Note: "
  _dsb_i "  tf-help supports tab completion for available arguments,"
  _dsb_i "  simply add a space after the tf-help command and press tab."
}

_dsb_tf_help_groups() {
  _dsb_i "Help Groups:"
  _dsb_i "  environments  -> Environment related commands"
  _dsb_i "  terraform     -> Terraform related commands"
  _dsb_i "  upgrading     -> Upgrade related commands"
  _dsb_i "  checks        -> Check related commands"
  _dsb_i "  general       -> General help"
  _dsb_i "  azure         -> Azure related commands"
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
  _dsb_i "    tf-check-gh-auth      -> Check GitHub authentication"
}

_dsb_tf_help_group_general() {
  _dsb_i "  General Commands:"
  _dsb_i "    tf-status             -> Show status of tools, authentication, and environment"
  _dsb_i "    tf-lint [env]         -> Run tflint for the selected or given environment"
  _dsb_i "    tf-clean              -> Look for an delete '.terraform' directories"
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
}

_dsb_tf_help_group_terraform() {
  _dsb_i "  Terraform Commands:"
  _dsb_i "    tf-init [env]         -> Initialize selected or given environment (incl. main and local sub-modules)"
  _dsb_i "    tf-init-env [env]     -> Initialize selected or given environment (environment directory only)"
  _dsb_i "    tf-init-all           -> Initialize entire Terraform project, all environments"
  _dsb_i "    tf-init-main          -> Initialize Terraform project's main module"
  _dsb_i "    tf-init-modules       -> Initialize Terraform project's local sub-modules"
  _dsb_i "    tf-fmt                -> Run syntax check recursively from current directory"
  _dsb_i "    tf-fmt-fix            -> Run syntax check and fix recursively from current directory"
  _dsb_i "    tf-validate [env]     -> Make Terraform validate the project with selected or given environment"
  _dsb_i "    tf-plan [env]         -> Make Terraform create a plan for the selected or given environment"
  _dsb_i "    tf-apply [env]        -> Make Terraform apply changes for the selected or given environment"
  _dsb_i "    tf-destroy [env]      -> Show command to manually destroy the selected or given environment"
}

_dsb_tf_help_group_upgrading() {
  _dsb_i "  Upgrade Commands:"
  _dsb_i "    tf-bump [env]                   -> All-in-one bump function (modules, cicd, tflint plugins, provider upgrades) in selected or given environment"
  _dsb_i "    tf-upgrade [env]                -> Upgrade Terraform deps. for selected or given environment (also upgrades main and local sub-modules)"
  _dsb_i "    tf-upgrade-env [env]            -> Upgrade Terraform deps. for selected or given environment (environment directory only)"
  _dsb_i "    tf-upgrade-all                  -> Upgrade Terraform deps. in entire project, all environments"
  _dsb_i "    tf-bump-modules                 -> Bump module versions in .tf files (only applies to official registry modules)"
  _dsb_i "    tf-bump-cicd                    -> Bump versions in GitHub workflows"
  _dsb_i "    tf-bump-tflint-plugins          -> Bump tflint plugin versions in .tflint.hcl files"
  _dsb_i "    tf-show-provider-upgrades [env] -> Show available provider upgrades for selected or given environment"
  _dsb_i "    tf-show-all-provider-upgrades   -> Show all available provider upgrades for all environments"
}

_dsb_tf_help_commands() {
  _dsb_tf_help_help
  _dsb_i ""
  _dsb_i "Groups:"
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
  tf-lint)
    _dsb_i "tf-lint [env]:"
    _dsb_i "  Run tflint for the specified environment."
    _dsb_i "  If environment is not specified, the selected environment is used."
    _dsb_i ""
    _dsb_i "  Supports tab completion for environment."
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
    _dsb_i ""
    _dsb_i "  Related commands: az-whoami, az-relog."
    ;;
  az-relog)
    _dsb_i "az-relog:"
    _dsb_i "  re-login to Azure with the Azure CLI."
    _dsb_i ""
    _dsb_i "  Related commands: az-whoami."
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
    _dsb_i "  Related commands: az-login, az-whoami."
    ;;
  # terraform
  tf-init)
    _dsb_i "tf-init [env]:"
    _dsb_i "  Initialize the specified Terraform environment."
    _dsb_i "  If environment is not specified, the selected environment is used."
    _dsb_i ""
    _dsb_i "  This also initializes the main module and any local sub-modules."
    _dsb_i ""
    _dsb_i "  Note:"
    _dsb_i "    For a complete initialization of the entire project, use 'tf-init-all'."
    _dsb_i ""
    _dsb_i "  Supports tab completion for environment."
    _dsb_i ""
    _dsb_i "  Related commands: tf-init-all, tf-upgrade, tf-plan, tf-apply."
    ;;
  tf-init-env)
    _dsb_i "tf-init-env [env]:"
    _dsb_i "  Initialize the specified Terraform environment."
    _dsb_i "  If environment is not specified, the selected environment is used."
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
  tf-init-all)
    _dsb_i "tf-init-all"
    _dsb_i "  Initialize the entire Terraform project."
    _dsb_i ""
    _dsb_i "  This initializes the project completely, all environment directories, main module, and local sub-modules."
    _dsb_i ""
    _dsb_i "  Related commands: tf-upgrade, tf-plan, tf-apply."
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
    _dsb_i "  Related commands: tf-init, tf-plan, tf-apply."
    ;;
  tf-plan)
    _dsb_i "tf-plan [env]:"
    _dsb_i "  Make Terraform create a plan for the specified environment."
    _dsb_i "  If environment is not specified, the selected environment is used."
    _dsb_i ""
    _dsb_i "  Supports tab completion for environment."
    _dsb_i ""
    _dsb_i "  Related commands: tf-init, tf-validate, tf-apply."
    ;;
  tf-apply)
    _dsb_i "tf-apply [env]:"
    _dsb_i "  Make Terraform apply changes for the specified environment."
    _dsb_i "  If environment is not specified, the selected environment is used."
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
  tf-bump)
    _dsb_i "tf-bump [env]:"
    _dsb_i "  All-in-one bump function."
    _dsb_i "  Bump module versions, cicd versions, tflint plugins, and provider upgrades."
    _dsb_i "  If environment is not specified, the selected environment is used."
    _dsb_i ""
    _dsb_i "  Related commands: tf-upgrade, tf-bump-modules, tf-bump-cicd, tf-bump-tflint-plugins, tf-show-provider-upgrades."
    ;;
  tf-upgrade)
    _dsb_i "tf-upgrade [env]:"
    _dsb_i "  Upgrade Terraform dependencies for the specified environment."
    _dsb_i "  If environment is not specified, the selected environment is used."
    _dsb_i ""
    _dsb_i "  This also upgrades and initializes the main module and any local sub-modules."
    _dsb_i "  Upgrade is performed within the current version constraints, ie. no version constraints are changed."
    _dsb_i ""
    _dsb_i "  Note:"
    _dsb_i "    For a complete upgrade of the entire project, use 'tf-upgrade-all'."
    _dsb_i ""
    _dsb_i "  Supports tab completion for environment."
    _dsb_i ""
    _dsb_i "  Related commands: tf-init, tf-upgrade-all, tf-plan, tf-apply, tf-bump-modules, tf-bump."
    ;;
  tf-upgrade-env)
    _dsb_i "tf-upgrade-env [env]:"
    _dsb_i "  Upgrade Terraform dependencies and initialize the specified environment."
    _dsb_i "  If environment is not specified, the selected environment is used."
    _dsb_i ""
    _dsb_i "  Upgrade is performed within the current version constraints, ie. no version constraints are changed."
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
  tf-upgrade-all)
    _dsb_i "tf-upgrade-all:"
    _dsb_i "  Upgrade Terraform dependencies and initialize the entire project."
    _dsb_i ""
    _dsb_i "  This upgrades and initializes the project completely, environment directory, sub-modules and main."
    _dsb_i "  Upgrade is performed within the current version constraints, ie. no version constraints are changed."
    _dsb_i ""
    _dsb_i "  Related commands: tf-init, tf-plan, tf-apply, tf-bump-modules, tf-bump."
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
    _dsb_i "  Related commands: tf-upgrade-all, tf-bump-modules, tf-bump-tflint-plugins, tf-bump."
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
    _dsb_i "  Related commands: tf-upgrade-all, tf-bump-cicd, tf-bump-tflint-plugins, tf-bump."
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
    _dsb_i "  Related commands: tf-upgrade-all, tf-bump-cicd, tf-bump-modules, tf-bump."
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
    _dsb_i "  Related commands: tf-show-provider-upgrades, tf-bump."
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

  # only complete if _dsbTfAvailableEnvs is set
  if [[ -v _dsbTfAvailableEnvs ]]; then
    if [[ -n "${_dsbTfAvailableEnvs[*]}" ]]; then
      mapfile -t COMPREPLY < <(compgen -W "${_dsbTfAvailableEnvs[*]}" -- "${cur}")
    fi
  fi
}

_dsb_tf_register_completions_for_available_envs() {
  complete -F _dsb_tf_completions_for_available_envs tf-set-env
  complete -F _dsb_tf_completions_for_available_envs tf-check-env
  complete -F _dsb_tf_completions_for_available_envs tf-select-env
  complete -F _dsb_tf_completions_for_available_envs tf-init-env
  complete -F _dsb_tf_completions_for_available_envs tf-init
  complete -F _dsb_tf_completions_for_available_envs tf-upgrade-env
  complete -F _dsb_tf_completions_for_available_envs tf-upgrade
  complete -F _dsb_tf_completions_for_available_envs tf-validate
  complete -F _dsb_tf_completions_for_available_envs tf-plan
  complete -F _dsb_tf_completions_for_available_envs tf-apply
  complete -F _dsb_tf_completions_for_available_envs tf-destroy
  complete -F _dsb_tf_completions_for_available_envs tf-lint
  complete -F _dsb_tf_completions_for_available_envs tf-show-provider-upgrades
  complete -F _dsb_tf_completions_for_available_envs tf-bump-env
  complete -F _dsb_tf_completions_for_available_envs tf-bump
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
    _dsb_e "  or install it with: 'go install github.com/minamijoyo/hcledit@latest; export PATH=\$PATH:\$(go env GOPATH)/bin; echo \"export PATH=\$PATH:\$(go env GOPATH)/bin\" >> ~/.bashrc'"
    return 1
  fi
  return 0
}

# TODO: need this?
# what:
#   check if terraform-docs is available
# input:
#   none
# on info:
#   nothing
# returns:
#   exit code directly
# _dsb_tf_check_terraform_docs() {
#   if ! terraform-docs --version &>/dev/null; then
#     _dsb_e "terraform-docs not found."
#     _dsb_e "  checked with command: terraform-docs --version"
#     _dsb_e "  make sure terraform-docs is available in your PATH"
#     _dsb_e "  for installation instructions see: https://terraform-docs.io/user-guide/installation/"
#     _dsb_e "  or install it with: 'go install github.com/terraform-docs/terraform-docs@latest; export PATH=\$PATH:\$(go env GOPATH)/bin; echo \"export PATH=\$PATH:\$(go env GOPATH)/bin\" >> ~/.bashrc'"
#     return 1
#   fi
#   return 0
# }

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
    _dsb_e "  or install it with: 'go install github.com/hashicorp/terraform-config-inspect@latest; export PATH=\$PATH:\$(go env GOPATH)/bin; echo \"export PATH=\$PATH:\$(go env GOPATH)/bin\" >> ~/.bashrc'"
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

  # _dsb_i "Checking terraform-docs ..."
  # _dsb_tf_check_terraform_docs
  # local terraformDocsStatus=$?

  _dsb_i "Checking terraform-config-inspect ..."
  _dsb_tf_check_terraform_config_inspect
  local terraformConfigInspectStatus=$?

  _dsb_i "Checking realpath ..."
  _dsb_tf_check_realpath
  local realpathStatus=$?

  _dsb_i "Checking curl ..."
  _dsb_tf_check_curl
  local curlStatus=$?

  # local returnCode=$((azCliStatus + ghCliStatus + terraformStatus + jqStatus + yqStatus + golangStatus + hcleditStatus + terraformDocsStatus + terraformConfigInspectStatus + realpathStatus + curlStatus))
  local returnCode=$((azCliStatus + ghCliStatus + terraformStatus + jqStatus + yqStatus + golangStatus + hcleditStatus + terraformConfigInspectStatus + realpathStatus + curlStatus))

  _dsb_i ""
  _dsb_i "Tools check summary:"
  if [ ${azCliStatus} -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  Azure CLI check                : passed."
  else
    _dsb_i "  \e[31m☒\e[0m  Azure CLI check                : fails, see above for more information."
  fi
  if [ ${ghCliStatus} -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  GitHub CLI check               : passed."
  else
    _dsb_i "  \e[31m☒\e[0m  GitHub CLI check               : fails, see above for more information."
  fi
  if [ ${terraformStatus} -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  Terraform check                : passed."
  else
    _dsb_i "  \e[31m☒\e[0m  Terraform check                : fails, see above for more information."
  fi
  if [ ${jqStatus} -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  jq check                       : passed."
  else
    _dsb_i "  \e[31m☒\e[0m  jq check                       : fails, see above for more information."
  fi
  if [ ${yqStatus} -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  yq check                       : passed."
  else
    _dsb_i "  \e[31m☒\e[0m  yq check                       : fails, see above for more information."
  fi
  if [ ${golangStatus} -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  Go check                       : passed."
  else
    _dsb_i "  \e[31m☒\e[0m  Go check                       : fails, see above for more information."
  fi
  if [ ${hcleditStatus} -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  hcledit check                  : passed."
  else
    _dsb_i "  \e[31m☒\e[0m  hcledit check                  : fails, see above for more information."
  fi
  # if [ ${terraformDocsStatus} -eq 0 ]; then
  #   _dsb_i "  \e[32m☑\e[0m  terraform-docs check           : passed."
  # else
  #   _dsb_i "  \e[31m☒\e[0m  terraform-docs check           : fails, see above for more information."
  # fi
  if [ ${terraformConfigInspectStatus} -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  terraform-config-inspect check : passed."
  else
    _dsb_i "  \e[31m☒\e[0m  terraform-config-inspect check : fails, see above for more information."
  fi
  if [ ${realpathStatus} -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  realpath check                 : passed."
  else
    _dsb_i "  \e[31m☒\e[0m  realpath check                 : fails, see above for more information."
  fi
  if [ ${curlStatus} -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  curl check                     : passed."
  else
    _dsb_i "  \e[31m☒\e[0m  curl check                     : fails, see above for more information."
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
  local returnCode=0

  # check fails if gh cli is not installed
  if ! _dsbTfLogErrors=0 _dsb_tf_check_gh_cli; then
    return 1
  fi

  if ! gh auth status &>/dev/null; then
    _dsb_e "You are not authenticated with GitHub. Please run 'gh auth login' to authenticate."
    return 1
  fi
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
#   exit code in _dsbTfReturnCode
_dsb_tf_check_current_dir() {
  _dsb_d "checking current directory: ${PWD:-}"

  _dsb_tf_enumerate_directories

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

  _dsbTfReturnCode=$returnCode
  _dsb_d "returning exit code in _dsbTfReturnCode=${_dsbTfReturnCode:-}"
  return 0
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
#   exit code in _dsbTfReturnCode
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
  local workingDirStatus=${_dsbTfReturnCode}
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

  _dsb_i ""
  if [ ${returnCode} -eq 0 ]; then
    _dsb_i "\e[32mAll pre-reqs check passed.\e[0m"
    _dsb_i "  now try 'tf-select-env' to select an environment."
  else
    _dsb_e "\e[31mPre-reqs check failed, for more information see above.\e[0m"
  fi

  _dsb_d "returnCode: ${returnCode}"

  _dsbTfReturnCode=$returnCode
  _dsb_d "returning exit code in _dsbTfReturnCode=${_dsbTfReturnCode:-}"
  return 0
}

# what:
#   check if environment exists, either supplied or the currently selected environment
# input:
#   environment name (optional)
# on info:
#   continuous output with summary of the check results
# returns:
#   exit code in _dsbTfReturnCode
_dsb_tf_check_env() {
  local selectedEnv="${_dsbTfSelectedEnv:-}" # allowed to be empty
  local envToCheck="${1:-${selectedEnv}}"    # input with fallback to selected environment

  if [ -z "${envToCheck}" ]; then
    _dsb_e "No environment specified and no environment selected."
    _dsb_e "  either specify environment: tf-check-env [env]"
    _dsb_e "  or run one of the following: tf-select-env, tf-set-env [env], tf-list-envs"
    _dsbTfReturnCode=1
    return 0 # caller reads _dsbTfReturnCode
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
    _dsb_i "Checking lock file ..."
    if ! _dsb_tf_look_for_lock_file "${envToCheck}"; then
      lockFileStatus=1
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

  _dsbTfReturnCode=$returnCode
  _dsb_d "returning exit code in _dsbTfReturnCode=${_dsbTfReturnCode:-}"
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
  find "${_dsbTfRootDir}/.github/workflows" -name "*.yml" -type f
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
#   exit code in _dsbTfReturnCode
_dsb_tf_list_envs() {
  # enumerate directories with current directory as root and
  # check if the current root directory is a valid Terraform project
  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  local dirCheckStatus=${_dsbTfReturnCode}
  if [ "${dirCheckStatus}" -ne 0 ]; then
    _dsbTfLogErrors=1 _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
    _dsbTfReturnCode=1
    return 0 # caller reads _dsbTfReturnCode
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
    _dsbTfReturnCode=1
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

    _dsbTfReturnCode=0
    if [ -n "${selectedEnv}" ]; then
      _dsb_i ""
      _dsb_i " -> indicates the currently selected"
    fi
  fi

  _dsb_d "returning exit code in _dsbTfReturnCode=${_dsbTfReturnCode:-}"
  return 0 # caller reads _dsbTfReturnCode
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
#   exit code in _dsbTfReturnCode
#   several global variables are updated:
#     - _dsbTfSelectedEnv
#     - _dsbTfSelectedEnvDir
#     - _dsbTfSubscriptionId   (implicitly set by _dsb_tf_az_set_sub)
#     - _dsbTfSubscriptionName (implicitly set by _dsb_tf_az_set_sub)
_dsb_tf_set_env() {
  local envToSet="${1:-}"

  _dsb_d "envToSet: ${envToSet}"

  if [ -z "${envToSet}" ]; then
    _dsb_e "No environment specified."
    _dsb_e "  usage: tf-set-env <env>"
    _dsbTfReturnCode=1
    return 0 # caller reads _dsbTfReturnCode
  fi

  # check if the current root directory is a valid Terraform project
  # _dsb_tf_check_current_dir calls _dsb_tf_enumerate_directories, so we don't need to call it again in this function
  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  if [ "${_dsbTfReturnCode}" -ne 0 ]; then
    _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
    return 0 # caller reads _dsbTfReturnCode
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
    _dsbTfReturnCode=1
    return 0 # caller reads _dsbTfReturnCode
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
    _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_az_set_sub
    azSubStatus=${_dsbTfReturnCode}

    if [ "${azSubStatus}" -ne 0 ]; then
      _dsb_e "Failed to configure Azure subscription using subscription hint '${_dsbTfSelectedEnvSubscriptionHintContent}', please run 'az-set-sub'"
    else
      _dsb_i "  current upn       : ${_dsbTfAzureUpn:-}"
      _dsb_i "  subscription ID   : ${_dsbTfSubscriptionId:-}"
      _dsb_i "  subscription Name : ${_dsbTfSubscriptionName:-}"
    fi
  fi

  local lockFileStatus=0
  if ! _dsbTfLogErrors=0 _dsb_tf_look_for_lock_file; then
    lockFileStatus=1
    _dsb_e "Lock file check failed, please run 'tf-check-env ${_dsbTfSelectedEnv}'"
  fi

  _dsbTfReturnCode=$((lockFileStatus + subscriptionHintFileStatus + azSubStatus))

  _dsb_d "returning exit code in _dsbTfReturnCode=${_dsbTfReturnCode:-}"
  return 0 # caller reads _dsbTfReturnCode
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
#   exit code in _dsbTfReturnCode
_dsb_tf_select_env() {
  _dsbTfLogInfo=1 _dsbTfLogErrors=1 _dsb_tf_list_envs
  local listEnvsStatus=${_dsbTfReturnCode}

  _dsb_d "listEnvsStatus: ${listEnvsStatus}"

  if [ "${listEnvsStatus}" -ne 0 ]; then
    _dsb_e "Failed to list environments, please run 'tf-list-envs'"
    return 0 # caller reads _dsbTfReturnCode
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

  _dsb_d "returning exit code in _dsbTfReturnCode=${_dsbTfReturnCode:-}"
  return 0 # caller reads _dsbTfReturnCode
}

###################################################################################################
#
# Internal functions: azure CLI
#
###################################################################################################

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
    return 0
  fi

  local showOutput
  showOutput=$(az account show 2>&1)
  local showStatus=$?

  _dsb_d "showStatus: ${showStatus}"
  _dsb_d "showOutput: ${showOutput}"

  if [ "${showStatus}" -eq 0 ]; then
    local azUpn subId subName tenantDisplayName
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
#   exit code in _dsbTfReturnCode
_dsb_tf_az_whoami() {
  _dsbTfReturnCode=0
  if ! _dsb_tf_az_enumerate_account; then
    _dsbTfReturnCode=1
  fi
  _dsb_d "returning exit code in _dsbTfReturnCode=${_dsbTfReturnCode:-}"
  return 0 # caller reads _dsbTfReturnCode
}

# what:
#   if az cli is installed, log out the user
#   if az cli is not installed, do nothing
# input:
#   none
# on info:
#   status of operation is printed
# returns:
#   exit code in _dsbTfReturnCode
_dsb_tf_az_logout() {
  local azCliStatus=0
  if ! _dsb_tf_check_az_cli; then
    azCliStatus=1
  fi

  if [ "${azCliStatus}" -ne 0 ]; then
    _dsb_i "  💡 you can also check other prerequisites by running 'tf-check-prereqs'"
    _dsbTfReturnCode=1
    _dsb_d "returning exit code in _dsbTfReturnCode=${_dsbTfReturnCode:-}"
    return 0 # caller reads _dsbTfReturnCode
  fi

  local clearOutput
  if ! clearOutput=$(az account clear 2>&1); then
    _dsb_e "Failed to clear subscriptions from local cache."
    _dsb_e "  please run 'az account clear --debug' manually"
    _dsbTfReturnCode=1
  else
    _dsb_i "Logged out from Azure CLI."
    _dsbTfReturnCode=0
  fi

  _dsb_d "clearOutput: ${clearOutput}"

  # enumerate but ignore results
  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_az_enumerate_account || :

  _dsb_d "returning exit code in _dsbTfReturnCode=${_dsbTfReturnCode:-}"
  return 0 # caller reads _dsbTfReturnCode
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
#   exit code in _dsbTfReturnCode
#   several global variables are updated (implicitly by _dsb_tf_az_enumerate_account)
#     - _dsbTfAzureUpn
#     - _dsbTfSubscriptionId
#     - _dsbTfSubscriptionName
_dsb_tf_az_login() {

  local azCliStatus=0
  if ! _dsb_tf_check_az_cli; then
    _dsb_i "  💡 you can also check other prerequisites by running 'tf-check-prereqs'"
    _dsbTfReturnCode=1
    _dsb_d "returning exit code in _dsbTfReturnCode=${_dsbTfReturnCode:-}"
    return 0 # caller reads _dsbTfReturnCode
  fi

  if _dsbTfLogInfo=0 _dsb_tf_az_enumerate_account; then
    # already logged in?
    local azUpn="${_dsbTfAzureUpn:-}"
    if [ -n "${azUpn}" ]; then
      # logged in, do nothing except showing the UPN
      _dsbTfLogInfo=1 _dsb_tf_az_enumerate_account
      _dsbTfReturnCode=0
      _dsb_d "returning exit code in _dsbTfReturnCode=${_dsbTfReturnCode:-}"
      return 0 # caller reads _dsbTfReturnCode
    fi
  fi

  # make sure to clear any existing account
  az account clear &>/dev/null || :

  local loginOutput
  if ! loginOutput=$(az login --use-device-code); then
    _dsb_e "Failed to login with Azure CLI."
    _dsb_e "  please run 'az login --debug' manually"
    _dsbTfReturnCode=1
  else
    _dsb_tf_az_enumerate_account
    _dsbTfReturnCode=$? # caller reads _dsbTfReturnCode
  fi

  _dsb_d "loginOutput: ${loginOutput}"

  _dsb_d "returning exit code in _dsbTfReturnCode=${_dsbTfReturnCode:-}"
  return 0 # caller reads _dsbTfReturnCode
}

# what:
#   log out and log in the user
# input:
#   none
# on info:
#   status of operation is printed (implicitly by _dsb_tf_az_logout and _dsb_tf_az_login)
#   account subscription details are printed (implicitly by _dsb_tf_az_login -> _dsb_tf_az_enumerate_account)
# returns:
#   exit code in _dsbTfReturnCode
#   several global variables are updated (implicitly by _dsb_tf_az_login -> _dsb_tf_az_enumerate_account)
#     - _dsbTfAzureUpn
#     - _dsbTfSubscriptionId
#     - _dsbTfSubscriptionName
_dsb_tf_az_re-login() {
  _dsb_tf_az_logout
  local logoutStatus="${_dsbTfReturnCode}"
  _dsb_tf_az_login
  local loginStatus="${_dsbTfReturnCode}"
  _dsbTfReturnCode=$((logoutStatus + loginStatus)) # caller reads _dsbTfReturnCode

  _dsb_d "returning exit code in _dsbTfReturnCode=${_dsbTfReturnCode:-}"
  return 0 # caller reads _dsbTfReturnCode
}

# returns exit code in _dsbTfReturnCode
# sets the subscription to the selected environment subscription hint
# updates the selected subscription global variables
#   - _dsbTfSubscriptionId
#   - _dsbTfSubscriptionName
# what:
#   set the Azure subscription according to the selected environment's subscription hint
# input:
#   none
# on info:
#   subscription ID and name are printed (implicitly by _dsb_tf_az_enumerate_account)
# returns:
#   exit code in _dsbTfReturnCode
#   several global variables are updated (implicitly by _dsb_tf_az_enumerate_account):
#     - _dsbTfAzureUpn
#     - _dsbTfSubscriptionId
#     - _dsbTfSubscriptionName
_dsb_tf_az_set_sub() {
  local selectedEnv="${_dsbTfSelectedEnv:-}"
  _dsbTfReturnCode=1

  if [ -z "${selectedEnv}" ]; then
    _dsb_e "No environment selected, please run one of these commands":
    _dsb_e "  - 'tf-select-env'"
    _dsb_e "  - 'tf-set-env <env>'"
    return 0
  fi

  # enumerate the directories and validate the selected environment
  # populates _dsbTfSelectedEnvSubscriptionHintContent if successful
  if ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_env; then
    _dsb_e "Environment check failed, please run 'tf-check-env ${selectedEnv}'"
    return 0
  fi

  # need the cli
  if ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_az_cli; then
    _dsb_e "Azure CLI check failed, please run 'tf-check-prereqs'"
    return 0
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
    _dsbTfReturnCode=0
    _dsb_d "returning exit code in _dsbTfReturnCode=$_dsbTfReturnCode"
    return 0
  fi

  _dsb_d "current subscription name does not match subscription hint, proceed with checking login status"

  # check if user is logged in
  if ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_az_enumerate_account; then
    _dsb_e "Azure CLI account enumeration failed, please run 'az-whoami'"
    return 0
  fi

  # set the subscription
  if az account set --subscription "${_dsbTfSelectedEnvSubscriptionHintContent}"; then
    # updates the selected subscription global variable
    _dsb_tf_az_enumerate_account
    _dsb_d "Subscription ID set to: ${_dsbTfSubscriptionId:-}"
    _dsb_d "Subscription name set to: ${_dsbTfSubscriptionName:-}"
    _dsbTfReturnCode=0
  else
    _dsb_e "Failed to set subscription."
    _dsb_e "  subscription hint: ${_dsbTfSelectedEnvSubscriptionHintContent}"
  fi

  _dsb_d "returning exit code in _dsbTfReturnCode=$_dsbTfReturnCode"
  return 0 # caller reads _dsbTfReturnCode
}

###################################################################################################
#
# terraform operations functions
#
###################################################################################################

# what:
#   preflight checks for terraform operations functions
#   checks if terraform is installed
#   selects the given environment
#   checks if the selected environment is valid
#   sets the subscription to the selected environment
# input:
#   $1: environment name
# on info:
#   nothing
# returns:
#   exit code in _dsbTfReturnCode
_dsb_tf_terraform_preflight() {
  local selectedEnv="${1}"

  _dsb_d "called with: selectedEnv=${selectedEnv}"

  if [ -z "${selectedEnv}" ]; then
    _dsb_e "No environment selected, please run 'tf-select-env' or 'tf-set-env <env>'"
    _dsbTfReturnCode=1
    return 0
  fi

  # terraform must be installed
  if ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_terraform; then
    _dsb_e "Terraform check failed, please run 'tf-check-tools'"
    _dsbTfReturnCode=1
    return 0
  fi

  # leverage _dsb_tf_set_env, this validates the environment and sets the subscription
  _dsbTfLogInfo=1 _dsbTfLogErrors=0 _dsb_tf_set_env "${selectedEnv}"
  if [ "${_dsbTfReturnCode}" -ne 0 ]; then
    _dsb_e "Failed to set environment '${selectedEnv}'."
    _dsb_e "  please run 'tf-check-env ${selectedEnv}'"
    _dsbTfReturnCode=1
    return 0
  fi

  # should be set when _dsbTfSelectedEnv is set
  local envDir="${_dsbTfSelectedEnvDir:-}"
  if [ -z "${envDir}" ]; then
    _dsb_internal_error "Internal error: expected to find selected environment directory." \
      "  expected in: _dsbTfSelectedEnvDir"
    return 1
  fi

  # should be set when _dsb_tf_set_env was successful
  local subId="${_dsbTfSubscriptionId:-}"
  if [ -z "${subId}" ]; then
    _dsb_d "unset ARM_SUBSCRIPTION_ID"
    unset ARM_SUBSCRIPTION_ID
    _dsb_internal_error "Internal error: expected to find subscription ID." \
      "  expected in: _dsbTfSubscriptionId"
    return 1
  else
    # required by azurerm terraform provider
    export ARM_SUBSCRIPTION_ID="${subId}"
    _dsb_d "exported ARM_SUBSCRIPTION_ID: ${ARM_SUBSCRIPTION_ID}"
  fi

  return 0
}

# what:
#   the function that runs terraform init in selected environment
#   this function does not perform any pre flight checks
#   if $1 is set to 1 (do upgrade), it will run terraform init -upgrade
# input:
#   $1: do upgrade (optional)
# on info:
#   nothing
# returns:
#   no return, terraform will potentially return non-zero exit code
_dsb_tf_init_env_actual() {
  local doUpgrade="${1:-0}"

  local envDir="${_dsbTfSelectedEnvDir}"
  local subId="${_dsbTfSubscriptionId}"
  local extraInitArgs=""

  if [ "${doUpgrade}" -eq 1 ]; then
    extraInitArgs="-upgrade"
  fi

  _dsb_d "doUpgrade: ${doUpgrade}"
  _dsb_d "envDir: ${envDir}"
  _dsb_d "subId: ${subId}"
  _dsb_d "current ARM_SUBSCRIPTION_ID: ${ARM_SUBSCRIPTION_ID}"

  terraform -chdir="${envDir}" init -reconfigure ${extraInitArgs}
}

# what:
#   runs terraform init in the the given environment directory
#   if $2 is set to 1 (do upgrade), it will run terraform init -upgrade
# input:
#   $1: do upgrade
#   $2: environment directory (optional, defaults to selected environment directory)
# on info:
#   nothing
# returns:
#   exit code in _dsbTfReturnCode
_dsb_tf_init_env() {
  local doUpgrade="${1}"
  local selectedEnv="${2:-${_dsbTfSelectedEnv:-}}"

  declare -g _dsbTfReturnCode=0 # default return code

  _dsb_d "called with:"
  _dsb_d "  doUpgrade: ${doUpgrade}"
  _dsb_d "  selectedEnv: ${selectedEnv}"

  if ! _dsb_tf_terraform_preflight "${selectedEnv}"; then
    _dsbTfReturnCode=1
    _dsb_d "_dsb_tf_terraform_preflight failed with non-zero exit code"
    _dsb_d "  _dsbTfReturnCode: ${_dsbTfReturnCode}"
    return 0
  elif [ "${_dsbTfReturnCode}" -ne 0 ]; then
    _dsb_d "_dsb_tf_terraform_preflight failed with exit code 0, but _dsbTfReturnCode is non-zero"
    _dsb_d "  _dsbTfReturnCode: ${_dsbTfReturnCode}"
    return 0
  fi

  _dsb_i ""
  _dsb_i "Initializing environment: $(_dsb_tf_get_rel_dir "${_dsbTfSelectedEnvDir}")"
  if ! _dsb_tf_init_env_actual "${doUpgrade}"; then
    _dsb_e "init in ./$(_dsb_tf_get_rel_dir "${_dsbTfSelectedEnvDir:-}") failed"
    _dsbTfReturnCode=1
  fi

  return 0
}

# what:
#   runs terraform init in the given directory
#   uses lock file from the selected environment
#   uses .terraform/providers from the selected environment from plugin cache
#   NOTE:
#     this means init in the selected environment must have been run before this
#   ALSO NOTE:
#     function does not perform any pre flight checks
# input:
#   $1: directory path
# on info:
#   nothing
# returns:
#   no explicit return
_dsb_tf_init_dir() {
  local dirPath="${1}"
  local envDir="${_dsbTfSelectedEnvDir}"

  _dsb_d "dirPath: ${dirPath}"
  _dsb_d "envDir: ${envDir}"

  _dsb_d "copying from ${envDir}/.terraform.lock.hcl"
  _dsb_d "to ${dirPath}/.terraform.lock.hcl"
  cp -f "${envDir}/.terraform.lock.hcl" "${dirPath}/.terraform.lock.hcl"

  _dsb_d "removing ${dirPath}/.terraform"
  rm -rf "${dirPath}/.terraform"

  _dsb_d "init in ${dirPath}"
  _dsb_d "with plugin-dir: ${envDir}/.terraform/providers"

  TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE=true \
    terraform -chdir="${dirPath}" init -input=false -plugin-dir="${envDir}/.terraform/providers" -backend=false -reconfigure

  _dsb_d "removing ${dirPath}/.terraform.lock.hcl"
  rm "${dirPath}/.terraform.lock.hcl"
}

# what:
#   initializes all local sub-modules in the current directory / terraform project
# input:
#   $1: skip preflight checks (optional)
# on info:
#   status messages are printed
# returns:
#   exit code in _dsbTfReturnCode
_dsb_tf_init_modules() {
  local skipPreflight="${1:-0}"
  local selectedEnv="${_dsbTfSelectedEnv:-}"

  _dsb_d "skipPreflight: ${skipPreflight}"

  if [ "${skipPreflight}" -ne 1 ]; then
    if ! _dsb_tf_terraform_preflight "${selectedEnv}"; then
      _dsbTfReturnCode=1
      _dsb_d "_dsb_tf_terraform_preflight failed with non-zero exit code"
      _dsb_d "  _dsbTfReturnCode: ${_dsbTfReturnCode}"
      return 0
    elif [ "${_dsbTfReturnCode}" -ne 0 ]; then
      _dsb_d "_dsb_tf_terraform_preflight failed with exit code 0, but _dsbTfReturnCode is non-zero"
      _dsb_d "  _dsbTfReturnCode: ${_dsbTfReturnCode}"
      return 0
    fi
  fi

  # to able to init modules, we need to have the lock file and the providers directory
  # environment lock file's existence was checked implicitly by _dsb_tf_terraform_preflight -> _dsb_tf_set_env further up
  local envProvidersDir="${_dsbTfSelectedEnvDir:-}/.terraform/providers" # this exists when init has been run in the selected environment

  if [ ! -d "${envProvidersDir}" ]; then
    _dsb_e "Providers directory not found in selected environment."
    _dsb_e "  expected to find: ${envProvidersDir}"
    _dsb_e "  please run 'tf-init-env ${selectedEnv}' first"
    _dsbTfReturnCode=1
    return 0
  fi

  local -a moduleDirs
  mapfile -t moduleDirs < <(_dsb_tf_get_module_dirs)
  local moduleDirsCount=${#moduleDirs[@]}

  _dsb_d "moduleDirsCount: ${moduleDirsCount}"

  if [ "${moduleDirsCount}" -eq 0 ]; then
    _dsb_i "No modules found to init in: ${selectedEnv}"
    _dsbTfReturnCode=0
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
      _dsbTfReturnCode=1
      return 0
    fi
  done

  _dsbTfReturnCode=0
  _dsb_d "returning exit code in _dsbTfReturnCode=${_dsbTfReturnCode:-}"
  return 0
}

# what:
#   initializes the main directory of the terraform project
# input:
#   $1: skip preflight checks (optional)
#   $2: environment directory (optional, defaults to selected environment directory)
# on info:
#   status messages are printed
# returns:
#   exit code in _dsbTfReturnCode
_dsb_tf_init_main() {
  local skipPreflight="${1:-0}"
  local selectedEnv="${_dsbTfSelectedEnv:-}"

  _dsb_d "skipPreflight: ${skipPreflight}"

  if [ "${skipPreflight}" -ne 1 ]; then
    if ! _dsb_tf_terraform_preflight "${selectedEnv}"; then
      _dsbTfReturnCode=1
      _dsb_d "_dsb_tf_terraform_preflight failed with non-zero exit code"
      _dsb_d "  _dsbTfReturnCode: ${_dsbTfReturnCode}"
      return 0
    elif [ "${_dsbTfReturnCode}" -ne 0 ]; then
      _dsb_d "_dsb_tf_terraform_preflight failed with exit code 0, but _dsbTfReturnCode is non-zero"
      _dsb_d "  _dsbTfReturnCode: ${_dsbTfReturnCode}"
      return 0
    fi
  fi

  # to be able to init, we need to have the lock file and the providers directory
  # environment lock file's existence was checked implicitly by _dsb_tf_terraform_preflight -> _dsb_tf_set_env further up
  local envProvidersDir="${_dsbTfSelectedEnvDir:-}/.terraform/providers" # this exists when init has been run in the selected environment

  if [ ! -d "${envProvidersDir}" ]; then
    _dsb_e "Providers directory not found in selected environment."
    _dsb_e "  expected to find: ${envProvidersDir}"
    _dsb_e "  please run 'tf-init-env ${selectedEnv}' first"
    _dsbTfReturnCode=1
    return 0
  fi

  _dsb_d "Main dir: ${_dsbTfMainDir}"

  _dsb_i_append "" # newline without any prefix
  _dsb_i "Initializing dir : $(_dsb_tf_get_rel_dir "${_dsbTfMainDir}")"
  if ! _dsb_tf_init_dir "${_dsbTfMainDir}"; then
    _dsb_e "Failed to init directory: ${_dsbTfMainDir}"
    _dsb_e "  init operation not complete, consider enabling debug logging"
    _dsbTfReturnCode=1
    return 0
  fi

  _dsbTfReturnCode=0
  _dsb_d "returning exit code in _dsbTfReturnCode=${_dsbTfReturnCode:-}"
  return 0
}

# what:
#   initializes the terraform project
#   performs preflight checks
#   initializes the environment, modules and main directory
# input:
#   $1: do upgrade
#   $2: clear selected environment after (optional, defaults to 1)
#   $3: name of environment to init, if not provided all environments are checked
# on info:
#   status messages are printed
# returns:
#   exit code in _dsbTfReturnCode
_dsb_tf_init() {
  local doUpgrade="${1}"
  local clearSelectedEnvAfter="${2:-1}"
  local envToInit="${3:-}"

  _dsb_d "called with:"
  _dsb_d "  doUpgrade: ${doUpgrade}"
  _dsb_d "  clearSelectedEnvAfter: ${clearSelectedEnvAfter}"
  _dsb_d "  envToInit: ${envToInit}"

  declare -g _dsbTfReturnCode=0 # default return code

  local operationFriendlyName="Initialization"
  if [ "${doUpgrade}" -eq 1 ]; then
    operationFriendlyName="Upgrade"
  fi

  # check if the current root directory is a valid Terraform project
  # _dsb_tf_check_current_dir calls _dsb_tf_enumerate_directories, so we don't need to call it again in this function
  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  if [ "${_dsbTfReturnCode}" -ne 0 ]; then
    _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
    return 0 # caller reads _dsbTfReturnCode
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
    _dsbTfReturnCode=1
    return 0
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
    if ! _dsb_tf_terraform_preflight "${envName}"; then
      _dsb_d "_dsb_tf_terraform_preflight failed with non-zero exit code"
      _dsb_d "  _dsbTfReturnCode: ${_dsbTfReturnCode}"
      _dsb_e "  preflight checks failed for ${envName}"
      ((preflightStatus += 1))
    elif [ "${_dsbTfReturnCode}" -ne 0 ]; then
      _dsb_d "_dsb_tf_terraform_preflight failed with exit code 0, but _dsbTfReturnCode is non-zero"
      _dsb_d "  _dsbTfReturnCode: ${_dsbTfReturnCode}"
      _dsb_e "  preflight checks failed for ${envName}"
      ((preflightStatus += 1))
    else
      local envDir="${_dsbTfSelectedEnvDir}" # available thanks to _dsb_tf_terraform_preflight
      _dsb_d "    envDir: ${envDir}"
      _dsb_i "  dir: $(_dsb_tf_get_rel_dir "${envDir}")"

      if ! _dsb_tf_init_env_actual "${doUpgrade}"; then
        _dsb_e "  init in ./$(_dsb_tf_get_rel_dir "${envDir:-}") failed"
        ((initEnvStatus += 1))
      else
        _dsb_tf_init_modules 1 "${envName}" # $1 = 1 means skip preflight checks, $2 = envName
        if [ "${_dsbTfReturnCode}" -ne 0 ]; then
          _dsb_d "init modules failed for ${envName}"
          ((initModulesStatus += 1))
        fi

        _dsb_tf_init_main 1 "${envName}" # $1 = 1 means skip preflight checks, $2 = envName
        if [ "${_dsbTfReturnCode}" -ne 0 ]; then
          _dsb_d "init main failed for ${envName}"
          ((initMainStatus += 1))
        fi
      fi
    fi
  done # end of availableEnvs loop

  _dsbTfReturnCode=$((preflightStatus + initEnvStatus + initModulesStatus + initMainStatus))

  if [ "${_dsbTfReturnCode}" -ne 0 ]; then
    _dsb_e ""
    _dsb_e "Failures occurred during ${operationFriendlyName}."
    _dsb_e "  ${_dsbTfReturnCode} operation(s) failed:"
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

  _dsb_d "returning exit code in _dsbTfReturnCode=${_dsbTfReturnCode:-}"
  return 0 # caller reads _dsbTfReturnCode
}

# what:
#   this function is a wrapper of _dsb_tf_init
#   it allows to specify an environment to initialize
#   and if the not specified, it attempts to use the selected environment
# input:
#   $1: do upgrade
#   $2: optional, environment name to init, if not provided the selected environment is used
# on info:
#   nothing, status messages indirectly from _dsb_tf_init
# returns:
#   exit code in _dsbTfReturnCode
_dsb_tf_init_full_single_env() {
  local doUpgrade="${1}"
  local envToInit="${2:-}"

  _dsb_d "called with doUpgrade: ${doUpgrade}, envToInit: ${envToInit}"

  declare -g _dsbTfReturnCode=0 # default return code

  if [ -z "${envToInit}" ]; then
    envToInit=${_dsbTfSelectedEnv:-}
  fi

  if [ -z "${envToInit}" ]; then
    _dsb_e "No environment specified and no environment selected."
    _dsb_e "  either specify environment: 'tf-init <env>'"
    _dsb_e "  or run 'tf-set-env <env>' first"
    _dsbTfReturnCode=1
  else
    _dsb_tf_init "${doUpgrade}" 0 "${envToInit}" # $1 = 'init -upgrade', $2 = clearSelectedEnvAfter, $3 = envToInit
  fi

  _dsb_d "returning exit code in _dsbTfReturnCode=${_dsbTfReturnCode:-}"
  return 0 # caller reads _dsbTfReturnCode
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
#   exit code in _dsbTfReturnCode
_dsb_tf_fmt() {
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
    _dsbTfReturnCode=1
    return 0 # caller reads _dsbTfReturnCode
  fi

  # enumerate directories with current directory as root and
  # check if the current root directory is a valid Terraform project
  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  local dirCheckStatus=${_dsbTfReturnCode}
  if [ "${dirCheckStatus}" -ne 0 ]; then
    _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
    return 0 # caller reads _dsbTfReturnCode
  fi

  _dsb_i "Running terraform fmt recursively"
  _dsb_i "  directory ${_dsbTfRootDir}"

  if terraform fmt -recursive ${extraFmtArgs} "${_dsbTfRootDir}"; then
    _dsbTfReturnCode=0
    _dsb_i "Done."
  else
    _dsbTfReturnCode=1
    if [ "${performFix}" -eq 1 ]; then
      _dsb_e "Terraform fmt operation failed."
    else
      _dsb_e "Terraform fmt check failed, please review the output above."
    fi
  fi

  _dsb_d "returning exit code in _dsbTfReturnCode=${_dsbTfReturnCode:-}"
  return 0
}

# what:
#   runs terraform validate in the given environment directory
#   if environment is not supplied, uses the selected environment
# input:
#   $1: environment name (optional)
# on info:
#   status messages are printed
# returns:
#   exit code in _dsbTfReturnCode
_dsb_tf_validate_env() {
  local selectedEnv="${1:-${_dsbTfSelectedEnv:-}}"

  if ! _dsb_tf_terraform_preflight "${selectedEnv}"; then
    _dsbTfReturnCode=1
    _dsb_d "_dsb_tf_terraform_preflight failed with non-zero exit code"
    _dsb_d "  _dsbTfReturnCode: ${_dsbTfReturnCode}"
    return 0
  elif [ "${_dsbTfReturnCode}" -ne 0 ]; then
    _dsb_d "_dsb_tf_terraform_preflight failed with exit code 0, but _dsbTfReturnCode is non-zero"
    _dsb_d "  _dsbTfReturnCode: ${_dsbTfReturnCode}"
    return 0
  fi

  local envDir="${_dsbTfSelectedEnvDir}"
  _dsb_i ""
  _dsb_i "Validating environment: $(_dsb_tf_get_rel_dir "${envDir}")"

  _dsb_d "current ARM_SUBSCRIPTION_ID: ${ARM_SUBSCRIPTION_ID}"

  if ! terraform -chdir="${envDir}" validate; then
    _dsb_e "terraform validate in ./$(_dsb_tf_get_rel_dir "${envDir:-}") failed"
    _dsbTfReturnCode=1
  else
    _dsbTfReturnCode=0
  fi

  _dsb_d "returning exit code in _dsbTfReturnCode=${_dsbTfReturnCode:-}"
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
#   exit code in _dsbTfReturnCode
_dsb_tf_plan_env() {
  local selectedEnv="${1:-${_dsbTfSelectedEnv:-}}"

  if ! _dsb_tf_terraform_preflight "${selectedEnv}"; then
    _dsbTfReturnCode=1
    _dsb_d "_dsb_tf_terraform_preflight failed with non-zero exit code"
    _dsb_d "  _dsbTfReturnCode: ${_dsbTfReturnCode}"
    return 0
  elif [ "${_dsbTfReturnCode}" -ne 0 ]; then
    _dsb_d "_dsb_tf_terraform_preflight failed with exit code 0, but _dsbTfReturnCode is non-zero"
    _dsb_d "  _dsbTfReturnCode: ${_dsbTfReturnCode}"
    return 0
  fi

  local envDir="${_dsbTfSelectedEnvDir}"
  _dsb_i ""
  _dsb_i "Creating plan for environment: $(_dsb_tf_get_rel_dir "${envDir}")"

  _dsb_d "current ARM_SUBSCRIPTION_ID: ${ARM_SUBSCRIPTION_ID}"

  if ! terraform -chdir="${envDir}" plan; then
    _dsb_e "terraform plan in ./$(_dsb_tf_get_rel_dir "${envDir:-}") failed"
    _dsbTfReturnCode=1
  else
    _dsbTfReturnCode=0
  fi

  _dsb_d "returning exit code in _dsbTfReturnCode=${_dsbTfReturnCode:-}"
  return 0
}

# what:
#   runs terraform apply in the given environment directory
#   if environment is not supplied, uses the selected environment
# input:
#   $1: environment name (optional)
# on info:
#   status messages are printed
# returns:
#   exit code in _dsbTfReturnCode
_dsb_tf_apply_env() {
  local selectedEnv="${1:-${_dsbTfSelectedEnv:-}}"

  if ! _dsb_tf_terraform_preflight "${selectedEnv}"; then
    _dsbTfReturnCode=1
    _dsb_d "_dsb_tf_terraform_preflight failed with non-zero exit code"
    _dsb_d "  _dsbTfReturnCode: ${_dsbTfReturnCode}"
    return 0
  elif [ "${_dsbTfReturnCode}" -ne 0 ]; then
    _dsb_d "_dsb_tf_terraform_preflight failed with exit code 0, but _dsbTfReturnCode is non-zero"
    _dsb_d "  _dsbTfReturnCode: ${_dsbTfReturnCode}"
    return 0
  fi

  local envDir="${_dsbTfSelectedEnvDir}"
  _dsb_i ""
  _dsb_i "Running apply in environment: $(_dsb_tf_get_rel_dir "${envDir}")"

  _dsb_d "current ARM_SUBSCRIPTION_ID: ${ARM_SUBSCRIPTION_ID}"

  if ! terraform -chdir="${envDir}" apply; then
    _dsb_e "terraform apply in ./$(_dsb_tf_get_rel_dir "${envDir:-}") failed"
    _dsbTfReturnCode=1
  else
    _dsbTfReturnCode=0
  fi

  _dsb_d "returning exit code in _dsbTfReturnCode=${_dsbTfReturnCode:-}"
  return 0
}

# what:
#   echos the command to manually run terraform destroy in the given environment directory
#   if environment is not supplied, uses the selected environment
# input:
#   $1: environment name (optional)
# on info:
#   the information is printed
# returns:
#   exit code in _dsbTfReturnCode
_dsb_tf_destroy_env() {
  local selectedEnv="${1:-${_dsbTfSelectedEnv:-}}"

  if ! _dsb_tf_terraform_preflight "${selectedEnv}"; then
    _dsbTfReturnCode=1
    _dsb_d "_dsb_tf_terraform_preflight failed with non-zero exit code"
    _dsb_d "  _dsbTfReturnCode: ${_dsbTfReturnCode}"
    return 0
  elif [ "${_dsbTfReturnCode}" -ne 0 ]; then
    _dsb_d "_dsb_tf_terraform_preflight failed with exit code 0, but _dsbTfReturnCode is non-zero"
    _dsb_d "  _dsbTfReturnCode: ${_dsbTfReturnCode}"
    return 0
  fi

  _dsb_d "current ARM_SUBSCRIPTION_ID: ${ARM_SUBSCRIPTION_ID}"

  local envDir="${_dsbTfSelectedEnvDir}"
  _dsb_i ""
  _dsb_i "To run terraform destroy for environment: $(_dsb_tf_get_rel_dir "${envDir}"), run the following command manually:"
  _dsb_i "  terraform -chdir='${envDir}' destroy"

  return 0 # caller reads _dsbTfReturnCode
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

  if [ -z "${wrapperDir}" ] || [ -z "${wrapperPath}" ]; then
    _dsb_e "Internal error: expected to find tflint wrapper directory and path."
    _dsb_e "  expected in: _dsbTfTflintWrapperDir and _dsbTfTflintWrapperPath"
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

  gh api -H 'Accept: application/vnd.github.v3.raw' "${wrapperApiUrl}" >"${wrapperPath}"

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
#   exit code in _dsbTfReturnCode
_dsb_tf_run_tflint() {
  local selectedEnv="${1:-${_dsbTfSelectedEnv:-}}"

  if [ -z "${selectedEnv}" ]; then
    _dsb_e "No environment selected, please run 'tf-select-env' or 'tf-set-env <env>'"
    _dsbTfReturnCode=1
    return 0
  fi

  # check that gh cli is installed and user is logged in
  if ! _dsb_tf_check_gh_auth; then
    _dsbTfReturnCode=1
    return 0
  fi

  # leverage _dsb_tf_set_env, this enumerates directories and validates the environment
  _dsbTfLogInfo=1 _dsbTfLogErrors=0 _dsb_tf_set_env "${selectedEnv}"
  if [ "${_dsbTfReturnCode}" -ne 0 ]; then
    _dsb_e "Failed to set environment '${selectedEnv}'."
    _dsb_e "  please run 'tf-check-env ${selectedEnv}'"
    _dsbTfReturnCode=1
    return 0
  fi

  # make sure tflint is installed
  if ! _dsbTfLogErrors=0 _dsb_tf_install_tflint_wrapper; then
    _dsb_e "Failed to install tflint wrapper, consider enabling debug logging"
    _dsbTfReturnCode=1
    return 0
  fi

  # should be set when _dsbTfSelectedEnv is set
  local envDir="${_dsbTfSelectedEnvDir:-}"
  if [ -z "${envDir}" ]; then
    _dsb_internal_error "Internal error: expected to find selected environment directory." \
      "  expected in: _dsbTfSelectedEnvDir"
    return 1
  fi

  if ! pushd "${envDir}" >/dev/null; then
    _dsb_e "Failed to change to environment directory: ${envDir}"
    _dsbTfReturnCode=1
    return 0
  fi

  # invoke the tflint wrapper script
  if ! bash -s -- <"${_dsbTfTflintWrapperPath}"; then
    _dsb_i_append "" # newline without any prefix
    _dsb_w "tflint operation resulted in non-zero exit code."
    _dsbTfReturnCode=1
  else
    _dsbTfReturnCode=0
  fi

  if ! popd >/dev/null; then
    _dsb_w "Failed to change back to root directory after linting."
  fi

  _dsb_d "returning exit code in _dsbTfReturnCode=${_dsbTfReturnCode:-}"
  return 0
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
    local -a envDirs
    mapfile -t envDirs < <(_dsb_tf_get_env_dirs)
    local envDirsCount=${#envDirs[@]}

    local -a moduleDirs
    mapfile -t moduleDirs < <(_dsb_tf_get_module_dirs)
    local moduleDirsCount=${#moduleDirs[@]}

    local -a searchInDirs=()
    searchInDirs+=("${_dsbTfRootDir}")
    if [ "${envDirsCount}" -gt 0 ]; then
      searchInDirs+=("${envDirs[@]}")
    fi
    searchInDirs+=("${_dsbTfMainDir}")
    if [ "${moduleDirsCount}" -gt 0 ]; then
      searchInDirs+=("${moduleDirs[@]}")
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
#   exit code in _dsbTfReturnCode
_dsb_tf_clean_dot_directories() {
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
  if [ "${_dsbTfReturnCode}" -ne 0 ]; then
    _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
    _dsbTfReturnCode=1
    return 0 # caller reads _dsbTfReturnCode
  fi

  _dsb_d "start looking for '${searchForDirType}' directories"

  local -a dotDirs
  mapfile -t dotDirs < <(_dsb_tf_get_dot_dirs "${searchForDirType}")
  local dotDirsCount=${#dotDirs[@]}

  _dsb_d "dotDirsCount: ${dotDirsCount}"

  if [ "${dotDirsCount}" -eq 0 ]; then
    _dsb_i "No '${searchForDirType}' directories found."
    _dsb_i "  nothing to clean"
    _dsbTfReturnCode=0
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
      _dsbTfReturnCode=0
      return 0
    fi
  done

  _dsb_i "Deleting '${searchForDirType}' directories ..."

  _dsbTfReturnCode=0
  for idx in "${!dotDirs[@]}"; do
    local dotDir="${dotDirs[idx]}"
    if ! rm -rf "${dotDir}"; then
      _dsb_e "Failed to delete: $(_dsb_tf_get_rel_dir "${dotDir}")"
      _dsbTfReturnCode=1
    fi
  done

  if [ "${_dsbTfReturnCode}" -eq 0 ]; then
    _dsb_i "Done."
  else
    _dsb_e "Some delete operation(s) failed, please review the output above."
  fi

  _dsb_d "returning exit code in _dsbTfReturnCode=${_dsbTfReturnCode:-}"
  return 0
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
#   exit code in _dsbTfReturnCode
_dsb_tf_bump_tool_in_github_workflow_file() {
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
    _dsbTfReturnCode=1
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
    _dsbTfReturnCode=0
    return 0
  fi

  local fieldPath
  for fieldPath in "${fieldInstances[@]}"; do

    _dsb_d "checking fieldPath: ${fieldPath}"

    # read the current version from the workflow file
    local currentVersion
    currentVersion=$(FIELD_NAME="${fieldName}" yq eval ".${fieldPath}.[env(FIELD_NAME)]" "${workflowFile}")

    _dsb_d "currentVersion: ${currentVersion}"

    # test if the current version is a valid semver
    local currentVersionIsSemver=0
    if "${isSemverFunction}" "${currentVersion}"; then
      currentVersionIsSemver=1
    fi

    _dsb_d "currentVersionIsSemver: ${currentVersionIsSemver}"

    _dsbTfReturnCode=0

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
        _dsbTfReturnCode=1
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
          _dsbTfReturnCode=1
        fi
      fi
    fi
  done

  _dsb_d "returning exit code in _dsbTfReturnCode=${_dsbTfReturnCode:-}"
  return 0
}

# what:
#   this function bumps the versions of terraform and tflint in all GitHub workflow files in the .github/workflows directory
# input:
#   none
# on info:
#   status messages are printed
# returns:
#   exit code in _dsbTfReturnCode
_dsb_tf_bump_github() {

  # we need yq to read and modify yml files
  if ! _dsb_tf_check_yq; then
    _dsbTfLogErrors=1 _dsb_e "yq check failed, please run 'tf-check-prereqs'"
    _dsbTfReturnCode=1
    return 0 # caller reads _dsbTfReturnCode
  fi

  # check that gh cli is installed and user is logged in
  if ! _dsb_tf_check_gh_auth; then
    _dsbTfReturnCode=1
    return 0
  fi

  # enumerate directories with current directory as root and
  # check if the current root directory is a valid Terraform project
  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  local dirCheckStatus=${_dsbTfReturnCode}
  if [ "${dirCheckStatus}" -ne 0 ]; then
    _dsbTfLogErrors=1 _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
    _dsbTfReturnCode=1
    return 0 # caller reads _dsbTfReturnCode
  fi

  _dsb_i "Bump versions in GitHub workflow file(s):"

  # lookup all github workflow files in .github/workflows
  local -a workflowFiles
  mapfile -t workflowFiles < <(_dsb_tf_get_github_workflow_files)
  local workflowFilesCount=${#workflowFiles[@]}

  if [ "${workflowFilesCount}" -eq 0 ]; then
    _dsb_i "  no github workflow files found in .github/workflows, nothing to update"
    _dsbTfReturnCode=0
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
    returnCode=$((returnCode + _dsbTfReturnCode))

    _dsb_tf_bump_tool_in_github_workflow_file "tflint" "${workflowFile}" "${tflintLatestVersion}"
    returnCode=$((returnCode + _dsbTfReturnCode))
  done

  _dsb_i "Done."
  _dsbTfReturnCode="${returnCode}"

  _dsb_d "returning exit code in _dsbTfReturnCode=${_dsbTfReturnCode:-}"
  return 0
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
#   exit code in _dsbTfReturnCode
_dsb_tf_bump_registry_module_versions() {
  declare -g _dsbTfReturnCode=0 # default return code

  # check if the current root directory is a valid Terraform project
  # _dsb_tf_check_current_dir calls _dsb_tf_enumerate_directories, so we don't need to call it again in this function
  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  if [ "${_dsbTfReturnCode}" -ne 0 ]; then
    _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
    return 0 # caller reads _dsbTfReturnCode
  fi

  # we need several tools to be available: curl, jq, hcledit
  if ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_tools; then
    _dsb_e "Tools check failed, please run 'tf-check-tools'"
    _dsbTfReturnCode=1
    return 0 # caller reads _dsbTfReturnCode
  fi

  _dsb_i "Bump versions of registry modules in all tf files in the project:"

  # locate registry modules in the project
  _dsb_i "  Enumerating registry modules ..."
  if ! _dsb_tf_enumerate_registry_modules_meta; then
    _dsb_e "Failed to enumerate registry modules meta data, consider enabling debug logging"
    _dsbTfReturnCode=1
    return 0 # caller reads _dsbTfReturnCode
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
      _dsbTfReturnCode=1
      registryModulesLatestVersions["${moduleSource}"]="" # empty string to indicate failure
    else
      # _dsb_tf_get_latest_registry_module_version returns the latest version in _dsbTfLatestRegistryModuleVersion
      local moduleLatestVersion
      moduleLatestVersion="${_dsbTfLatestRegistryModuleVersion:-}"

      if [ -z "${moduleLatestVersion}" ]; then
        _dsb_internal_error "Internal error: expected to find a version string, but did not" \
          "  expected in: _dsbTfLatestRegistryModuleVersion" \
          "  moduleSource: ${moduleSource}"
        _dsbTfReturnCode=1
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
    moduleName=$(echo "${hclBlockAddress}" | awk -F. '{print $2}')                                           # block name is on the form 'module.my_module', we need just the name part
    moduleDeclaration="module \"${moduleName}\""                                                             # we search for 'module "my_module"'
    moduleDeclarationLineNumber=$(grep -n "${moduleDeclaration}" "${tfFile}" | cut -d: -f1 2>/dev/null || :) # extract line number
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
        _dsbTfReturnCode=1
      fi
    else
      _dsb_d "Not changing ${moduleSource} : ${latestVersion} in ${tfFile}"
    fi
  done # end of loop through all registry modules

  _dsb_i "Done."

  _dsb_d "returning exit code in _dsbTfReturnCode=${_dsbTfReturnCode:-}"
  return 0
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
#   exit code in _dsbTfReturnCode
_dsb_tf_bump_tflint_plugin_versions() {
  declare -g _dsbTfReturnCode=0 # default return code

  # check if the current root directory is a valid Terraform project
  # _dsb_tf_check_current_dir calls _dsb_tf_enumerate_directories, so we don't need to call it again in this function
  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  if [ "${_dsbTfReturnCode}" -ne 0 ]; then
    _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
    return 0 # caller reads _dsbTfReturnCode
  fi

  # we need several tools to be available: curl, jq, hcledit
  if ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_curl ||
    ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_jq ||
    ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_hcledit; then
    _dsb_e "Tools check failed, please run 'tf-check-tools'"
    _dsbTfReturnCode=1
    return 0 # caller reads _dsbTfReturnCode
  fi

  # check that gh cli is installed and user is logged in
  if ! _dsb_tf_check_gh_auth; then
    _dsb_e "GitHub cli check failed, please run 'tf-check-gh-auth'"
    _dsbTfReturnCode=1
    return 0
  fi

  _dsb_i "Bump versions of plugins in all tflint configuration files in the project:"

  # locate tflint plugins in the project
  _dsb_i "  Enumerating tflint plugins ..."
  if ! _dsb_tf_enumerate_hcl_blocks_meta "plugin" "_dsbTfLintConfigFilesList"; then # $1: hclBlockTypeToLookFor, $2: globalFileListVariableName
    _dsb_e "Failed to enumerate tflint plugins meta data, consider enabling debug logging"
    _dsbTfReturnCode=1
    return 0 # caller reads _dsbTfReturnCode
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
      _dsbTfReturnCode=1
      tflintPluginsLatestVersions["${pluginSource}"]="" # empty string to indicate failure
    else
      # _dsb_tf_get_latest_tflint_plugin_version returns the latest version in _dsbTfLatestTflintPluginVersion
      local pluginLatestVersion
      pluginLatestVersion="${_dsbTfLatestTflintPluginVersion:-}"

      if [ -z "${pluginLatestVersion}" ]; then
        _dsb_internal_error "Internal error: expected to find a version string, but did not" \
          "  expected in: _dsbTfLatestTflintPluginVersion" \
          "  pluginSource: ${pluginSource}"
        _dsbTfReturnCode=1
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
    pluginName=$(echo "${hclBlockAddress}" | awk -F. '{print $2}')                                            # block name is on the form 'plugin.my_plugin', we need just the name part
    pluginDeclaration="plugin \"${pluginName}\""                                                              # we search for 'plugin "my_plugin"'
    pluginDeclarationLineNumber=$(grep -n "${pluginDeclaration}" "${hclFile}" | cut -d: -f1 2>/dev/null || :) # extract line number
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
        _dsbTfReturnCode=1
      fi
    else
      _dsb_d "Not changing ${pluginSource} : ${latestVersion} in ${hclFile}"
    fi

  done # end of loop through all tflint plugins

  _dsb_i "Done."

  _dsb_d "returning exit code in _dsbTfReturnCode=${_dsbTfReturnCode:-}"
  return 0
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
#   exit code in _dsbTfReturnCode
_dsb_tf_list_available_terraform_provider_upgrades() {
  local envToCheck="${1:-}"

  declare -g _dsbTfReturnCode=0 # default return code

  # check if the current root directory is a valid Terraform project
  # _dsb_tf_check_current_dir calls _dsb_tf_enumerate_directories, so we don't need to call it again in this function
  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  if [ "${_dsbTfReturnCode}" -ne 0 ]; then
    _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
    return 0 # caller reads _dsbTfReturnCode
  fi

  # we need several tools to be available: curl, jq, terraform-config-inspect
  if ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_curl ||
    ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_jq ||
    ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_terraform_config_inspect ||
    ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_hcledit; then
    _dsb_e "Tools check failed, please run 'tf-check-tools'"
    _dsbTfReturnCode=1
    return 0 # caller reads _dsbTfReturnCode
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
    _dsbTfReturnCode=1
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
        _dsbTfReturnCode=1
        continue
      fi

      local providers provider
      providers=$(echo "${tfConfigJson}" | jq -r '.required_providers | keys[]')
      for provider in ${providers}; do
        local source version_constraints
        source=$(echo "${tfConfigJson}" | jq -r ".required_providers[\"${provider}\"].source // empty")
        version_constraints=$(echo "${tfConfigJson}" | jq -r ".required_providers[\"${provider}\"].version_constraints[] // empty")

        _dsb_d "    provider: ${provider}"
        _dsb_d "      source: ${source}"

        # if empty we assume hashicorp provider
        if [ -z "${source}" ]; then
          source="hashicorp/${provider}"
          _dsb_d "      source is empty, assuming hashicorp provider, changed to: ${source}"
        fi

        if ! _dsb_tf_get_latest_terraform_provider_version "${source}" "${ignoreProviderVersionCache}"; then
          _dsb_e "    Failed to get latest version for provider: ${source}"
          _dsbTfReturnCode=1
        fi

        if ! _dsb_tf_get_lockfile_provider_version "${envDir}" "${source}"; then
          _dsb_e "    Failed to get locked version for provider: ${provider}"
          _dsbTfReturnCode=1
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
      _dsb_i "    to investigate further use: terraform -chdir='$(_dsb_tf_get_rel_dir "${envDir}")' providers"

    done # end of loop through all environments
  fi

  _dsb_d "returning exit code in _dsbTfReturnCode=${_dsbTfReturnCode:-}"
  return 0 # caller reads _dsbTfReturnCode
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
#   exit code in _dsbTfReturnCode
_dsb_tf_list_available_terraform_provider_upgrades_for_env() {
  local envToCheck="${1:-}"
  declare -g _dsbTfReturnCode=0 # default return code

  _dsb_d "called with envToCheck: ${envToCheck}"

  if [ -z "${envToCheck}" ]; then
    envToCheck=${_dsbTfSelectedEnv:-}
  fi

  if [ -z "${envToCheck}" ]; then
    _dsb_e "No environment specified and no environment selected."
    _dsb_e "  either specify environment: 'tf-show-provider-upgrades <env>'"
    _dsb_e "  or run 'tf-set-env <env>' first"
    _dsbTfReturnCode=1
  else
    _dsb_tf_list_available_terraform_provider_upgrades "${envToCheck}"
  fi

  _dsb_d "returning exit code in _dsbTfReturnCode=${_dsbTfReturnCode:-}"
  return 0 # caller reads _dsbTfReturnCode
}

# what:
#   this function upgrades the Terraform dependencies for a given environment
#   it then lists the latest available provider versions and locked versions for the environment
# input:
#   $1: environment name to bump
# on info:
#   status messages are printed
# returns:
#   exit code in _dsbTfReturnCode
_dsb_tf_bump_an_env() {
  local givenEnv="${1}" # used when calling terraform init -upgrade

  declare -g _dsbTfReturnCode=0 # default return code

  _dsb_d "called with givenEnv: ${givenEnv}"

  # check if the current root directory is a valid Terraform project
  # _dsb_tf_check_current_dir calls _dsb_tf_enumerate_directories, so we don't need to call it again in this function
  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  if [ "${_dsbTfReturnCode}" -ne 0 ]; then
    _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
    return 0 # caller reads _dsbTfReturnCode
  fi

  local initStatus=0
  local listStatus=0

  # leverage _dsb_tf_set_env, this validates the environment and sets the subscription
  if ! _dsbTfLogInfo=0 _dsbTfLogErrors=1 _dsb_tf_set_env "${givenEnv}"; then
    _dsb_d "Failed to set environment '${givenEnv}' with non-zero exit code."
    _dsb_d "  _dsbTfReturnCode: ${_dsbTfReturnCode}"
    _dsb_e "  please run 'tf-check-env ${givenEnv}' for more information."
    _dsbTfReturnCode=1
  elif [ "${_dsbTfReturnCode}" -ne 0 ]; then
    _dsb_d "Failed to set environment '${givenEnv}' with exit code 0, but _dsbTfReturnCode is non-zero"
    _dsb_d "  _dsbTfReturnCode: ${_dsbTfReturnCode}"
    _dsb_e "  please run 'tf-check-env ${givenEnv}' for more information."
    _dsbTfReturnCode=1
  else
    local envDir="${_dsbTfSelectedEnvDir}" # available thanks to _dsb_tf_set_env
    _dsb_d "  dir: $(_dsb_tf_get_rel_dir "${envDir}")"

    # terraform init -upgrade the project
    if ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_init 1 0 "${givenEnv}"; then # $1 = 1 means do -upgrade, $2 = 0 means do not unset the selected environment
      _dsb_d "Failed to upgrade the environment '${givenEnv}' with non-zero exit code."
      initStatus=1
    elif [ "${_dsbTfReturnCode}" -ne 0 ]; then
      _dsb_d "Failed to upgrade the environment '${givenEnv}' with exit code 0, but _dsbTfReturnCode is non-zero"
      _dsb_d "  _dsbTfReturnCode: ${_dsbTfReturnCode}"
      initStatus=1
    fi

    # show latest available provider versions and locked versions in the project
    if ! _dsb_tf_list_available_terraform_provider_upgrades_for_env; then # uses the selected environment
      _dsb_d "Failed to list available provider upgrades for environment '${givenEnv}' with non-zero exit code."
      _dsb_d "  _dsbTfReturnCode: ${_dsbTfReturnCode}"
      listStatus=1
    elif [ "${_dsbTfReturnCode}" -ne 0 ]; then
      _dsb_d "Failed to list available provider upgrades for environment '${givenEnv}' with exit code 0, but _dsbTfReturnCode is non-zero"
      _dsb_d "  _dsbTfReturnCode: ${_dsbTfReturnCode}"
      listStatus=1
    fi
  fi

  _dsbTfReturnCode+=$((initStatus + listStatus)) || :

  if [ ${_dsbTfReturnCode} -ne 0 ]; then
    _dsb_e "Failures reported during bumping, please review the output further up"
  else
    _dsb_i ""
    _dsb_i "Done."
  fi

  _dsb_d "returning exit code in _dsbTfReturnCode=${_dsbTfReturnCode:-}"
  return 0
}

# what:
#   this function is an all-in-one function to bump the versions of all the things
#   it bumps the versions of all modules in the project, tflint plugins and CI/CD files
#   it also upgrades the terraform version and lists potential providers upgrades
#   either for a single environment, if specified
#   or for all environments in the project, when not specified
# input:
#   $1: optional, environment name to bump, if not provided all environments are bumped
#   $2: optional, set to 0 to skip bumping modules, tflint plugins and CI/CD files
# on info:
#   status messages are printed
# returns:
#   exit code in _dsbTfReturnCode
_dsb_tf_bump_the_project() {
  local givenEnv="${1:-}"                  # used when calling terraform init -upgrade
  local bumpModulesTfLintAndCicd="${2:-1}" #set to 0 to skip bumping modules, tflint plugins and CI/CD files

  declare -g _dsbTfReturnCode=0 # default return code

  _dsb_d "called with givenEnv: ${givenEnv}"

  # check if the current root directory is a valid Terraform project
  # _dsb_tf_check_current_dir calls _dsb_tf_enumerate_directories, so we don't need to call it again in this function
  _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_check_current_dir
  if [ "${_dsbTfReturnCode}" -ne 0 ]; then
    _dsb_e "Directory check(s) fails, please run 'tf-check-dir'"
    return 0 # caller reads _dsbTfReturnCode
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
    _dsbTfReturnCode=1
    return 0
  elif [ "${envCount}" -eq 1 ] && [ -n "${givenEnv}" ]; then # a single environment was explicitly specified

    # we set the supplied env early to catch any issues before we start bumping
    if ! _dsbTfLogInfo=0 _dsbTfLogErrors=1 _dsb_tf_set_env "${givenEnv}"; then
      _dsb_d "Failed to set environment '${givenEnv}' with non-zero exit code."
      _dsb_d "  _dsbTfReturnCode: ${_dsbTfReturnCode}"
      _dsb_e "  please run 'tf-check-env ${givenEnv}' for more information."
      _dsbTfReturnCode=1
      return 0
    elif [ "${_dsbTfReturnCode}" -ne 0 ]; then
      _dsb_d "Failed to set environment '${givenEnv}' with exit code 0, but _dsbTfReturnCode is non-zero"
      _dsb_d "  _dsbTfReturnCode: ${_dsbTfReturnCode}"
      _dsb_e "  please run 'tf-check-env ${givenEnv}' for more information."
      _dsbTfReturnCode=1
      return 0
    fi
  fi

  _dsb_i "Bump the project:"
  _dsb_i ""

  local moduleStatus=0
  local tflintPluginStatus=0
  local cicdStatus=0
  if [ "${bumpModulesTfLintAndCicd}" -ne 0 ]; then

    # bump the versions of all modules in the project
    if ! _dsb_tf_bump_registry_module_versions; then
      _dsb_e "Failed to bump module versions"
      moduleStatus=1
    else
      moduleStatus=${_dsbTfReturnCode}
    fi
    _dsb_i ""

    # bump the versions of all tflint plugins in the project
    if ! _dsb_tf_bump_tflint_plugin_versions; then
      _dsb_e "Failed to bump tflint plugin versions"
      tflintPluginStatus=1
    else
      tflintPluginStatus=${_dsbTfReturnCode}
    fi
    _dsb_i ""

    # bump tflint and terraform versions in the CI/CD pipeline files
    if ! _dsb_tf_bump_github; then
      _dsb_e "Failed to bump CI/CD versions"
      cicdStatus=1
    else
      cicdStatus=${_dsbTfReturnCode}
    fi
    _dsb_i ""

  fi

  local preflightStatus=0
  local terraformStatus=0
  local providerStatus=0
  local envName envDir
  for envName in "${availableEnvs[@]}"; do
    _dsb_i "Bump environment: ${envName}"
    _dsb_i ""

    # leverage _dsb_tf_set_env, this validates the environment and sets the subscription
    if ! _dsbTfLogInfo=0 _dsbTfLogErrors=1 _dsb_tf_set_env "${envName}"; then
      _dsb_d "Failed to set environment '${envName}' with non-zero exit code."
      _dsb_d "  _dsbTfReturnCode: ${_dsbTfReturnCode}"
      _dsb_e "  unable to set environment '${envName}', upgrade skipped."
      _dsb_e "  please run 'tf-check-env ${envName}' for more information."
      ((preflightStatus += 1))
    elif [ "${_dsbTfReturnCode}" -ne 0 ]; then
      _dsb_d "Failed to set environment '${envName}' with exit code 0, but _dsbTfReturnCode is non-zero"
      _dsb_d "  _dsbTfReturnCode: ${_dsbTfReturnCode}"
      _dsb_e "  unable to set environment '${envName}', upgrade skipped."
      _dsb_e "  please run 'tf-check-env ${envName}' for more information."
      ((preflightStatus += 1))
    else
      local envDir="${_dsbTfSelectedEnvDir}" # available thanks to _dsb_tf_set_env
      _dsb_i "  dir: $(_dsb_tf_get_rel_dir "${envDir}")"

      # terraform init -upgrade the project
      if ! _dsbTfLogInfo=0 _dsbTfLogErrors=0 _dsb_tf_init 1 1 "${envName}"; then # $1 = 1 means do -upgrade, $2 = 1 means unset the selected environment after the operation
        _dsb_d "Failed to upgrade the environment '${envName}' with non-zero exit code."
        _dsb_d "  _dsbTfReturnCode: ${_dsbTfReturnCode}"
        _dsb_e "  Failed to upgrade the environment '${envName}', please run 'tf-upgrade-env ${envName}' for more information."
        ((terraformStatus += 1))
      elif [ "${_dsbTfReturnCode}" -ne 0 ]; then
        _dsb_d "Failed to upgrade the environment '${envName}' with exit code 0, but _dsbTfReturnCode is non-zero"
        _dsb_d "  _dsbTfReturnCode: ${_dsbTfReturnCode}"
        _dsb_e "  Failed to upgrade the environment '${envName}', please run 'tf-upgrade-env ${envName}' for more information."
        ((terraformStatus += 1))
      fi

      # show latest available provider versions and locked versions in the project
      if ! _dsb_tf_list_available_terraform_provider_upgrades_for_env "${envName}"; then
        _dsb_d "Failed to list available provider upgrades for environment '${envName}' with non-zero exit code."
        _dsb_d "  _dsbTfReturnCode: ${_dsbTfReturnCode}"
        ((providerStatus += 1))
      elif [ "${_dsbTfReturnCode}" -ne 0 ]; then
        _dsb_d "Failed to list available provider upgrades for environment '${envName}' with exit code 0, but _dsbTfReturnCode is non-zero"
        _dsb_d "  _dsbTfReturnCode: ${_dsbTfReturnCode}"
        ((providerStatus += 1))
      fi
    fi

    _dsb_d "preflightStatus for env '${envName}': ${preflightStatus}"
    _dsb_d "terraformStatus for env '${envName}': ${terraformStatus}"
    _dsb_d "providerStatus for env '${envName}': ${providerStatus}"

    _dsb_i ""
  done

  # summarize the status of all bump operations
  _dsbTfReturnCode=$((preflightStatus + moduleStatus + tflintPluginStatus + cicdStatus + terraformStatus + providerStatus))

  if [ "${envCount}" -gt 1 ]; then
    _dsb_i "Bump summary:"
    if [ "${_dsbTfReturnCode}" -ne 0 ]; then
      _dsb_e "  Number of failures during bumping: ${_dsbTfReturnCode}"
    fi
    if [ "${bumpModulesTfLintAndCicd}" -ne 0 ]; then
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

  if [ ${_dsbTfReturnCode} -ne 0 ]; then
    _dsb_e ""
    _dsb_e "Failures reported during bumping, please review the output further up"
  else
    _dsb_i ""
    _dsb_i "Done."
    _dsb_i "  Now run: 'tf-validate && tf-plan'"
  fi

  _dsb_d "returning exit code in _dsbTfReturnCode=${_dsbTfReturnCode:-}"
  return 0
}

# what:
#   this function is a wrapper of _dsb_tf_bump_the_project
#   it allows to specify an environment to bump the versions for
#   and if the not specified, it attempts to use the selected environment
# input:
#   $1: optional, environment name to bump, if not provided the selected environment is used
#   $2: optional, set to 0 to skip bumping modules, tflint plugins and CI/CD files
# on info:
#   nothing, status messages indirectly from _dsb_tf_bump_the_project
# returns:
#   exit code in _dsbTfReturnCode
_dsb_tf_bump_the_project_single_env() {
  local givenEnv="${1:-}"
  local bumpModulesTfLintAndCicd="${2:-1}" #set to 0 to skip bumping modules, tflint plugins and CI/CD files

  declare -g _dsbTfReturnCode=0 # default return code

  _dsb_d "called with envToCheck: ${givenEnv}"

  if [ -z "${givenEnv}" ]; then
    givenEnv=${_dsbTfSelectedEnv:-}
  fi

  if [ -z "${givenEnv}" ]; then
    _dsb_e "No environment specified and no environment selected."
    _dsb_e "  either specify environment: 'tf-bump <env>'"
    _dsb_e "  or run 'tf-set-env <env>' first"
    _dsbTfReturnCode=1
  else
    _dsb_tf_bump_the_project "${givenEnv}" "${bumpModulesTfLintAndCicd}" # $1: envToBump, $2: set to 0 to skip bumping modules, tflint plugins and CI/CD files
  fi

  _dsb_d "returning exit code in _dsbTfReturnCode=${_dsbTfReturnCode:-}"
  return 0 # caller reads _dsbTfReturnCode
}

###################################################################################################
#
# Exposed functions
#
###################################################################################################

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
  _dsb_tf_check_prereqs
  returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-check-tools() {
  _dsb_tf_configure_shell
  _dsbTfLogErrors=1 #get rid of this
  _dsbTfLogInfo=1

  _dsb_tf_error_stop_trapping
  _dsb_tf_check_tools
  local returnCode=$?

  if [ "${returnCode}" -ne 0 ]; then
    _dsb_e "Tools check failed."
  else
    _dsb_i "Tools check passed."
  fi

  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-status() {
  _dsb_tf_configure_shell
  _dsb_tf_report_status
  local returnCode="${_dsbTfReturnCode:-1}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

# Environment functions
# ---------------------
tf-list-envs() {
  _dsb_tf_configure_shell
  _dsb_tf_list_envs
  local returnCode="${_dsbTfReturnCode}"
  if [ "${returnCode}" -eq 0 ]; then
    _dsb_i ""
    _dsb_i "To choose an environment, use either 'tf-set-env <env>' or 'tf-select-env'"
  fi
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

tf-unset-env() {
  _dsb_tf_configure_shell
  _dsb_tf_clear_env # has no return code
  _dsb_tf_restore_shell
}

tf-check-env() {
  local envToCheck="${1:-}"
  _dsb_tf_configure_shell
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
  _dsb_tf_az_re-login
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

# Terraform functions
# -------------------
tf-init-env() {
  local envName="${1:-}"
  _dsb_tf_configure_shell
  _dsb_tf_init_env 0 "${envName}" # $1 = 0 means do not -upgrade
  local returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-init-modules() {
  _dsb_tf_configure_shell
  _dsb_tf_init_modules
  local returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-init-main() {
  _dsb_tf_configure_shell
  _dsb_tf_init_main
  local returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-init() {
  local envName="${1:-}"
  _dsb_tf_configure_shell
  _dsb_tf_init_full_single_env 0 "${envName}" # $1 = 0 means do not -upgrade
  local returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-init-all() {
  _dsb_tf_configure_shell
  _dsb_tf_init 0 # $1 = 0 means do not -upgrade
  local returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-fmt() {
  _dsb_tf_configure_shell
  _dsb_tf_fmt 0 # $1 = 0 means perform check
  local returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-fmt-fix() {
  _dsb_tf_configure_shell
  _dsb_tf_fmt 1 # $1 = 1 means perform fix
  local returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-validate() {
  local envName="${1:-}"
  _dsb_tf_configure_shell
  _dsb_tf_validate_env "${envName}"
  local returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-plan() {
  local envName="${1:-}"
  _dsb_tf_configure_shell
  _dsb_tf_plan_env "${envName}"
  local returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-apply() {
  local envName="${1:-}"
  _dsb_tf_configure_shell
  _dsb_tf_apply_env "${envName}"
  local returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-destroy() {
  local envName="${1:-}"
  _dsb_tf_configure_shell
  _dsb_tf_destroy_env "${envName}"
  local returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

# Linting functions
# -----------------

tf-lint() {
  local envName="${1:-}"
  _dsb_tf_configure_shell
  _dsb_tf_run_tflint "${envName}"
  local returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

# Clean functions
# ---------------

tf-clean() {
  _dsb_tf_configure_shell
  _dsb_tf_clean_dot_directories "terraform"
  local returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-clean-tflint() {
  _dsb_tf_configure_shell
  _dsb_tf_clean_dot_directories "tflint"
  local returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-clean-all() {
  _dsb_tf_configure_shell
  _dsb_tf_clean_dot_directories "all"
  local returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

# Upgrade functions
# -----------------

tf-upgrade-env() {
  local envName="${1:-}"
  _dsb_tf_configure_shell
  _dsb_tf_init_env 1 "${envName}" # $1 = 1 means do -upgrade
  local returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-upgrade() {
  local envName="${1:-}"
  _dsb_tf_configure_shell
  _dsb_tf_init_full_single_env 1 "${envName}" # $1 = 1 means do -upgrade
  local returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-upgrade-all() {
  local envName="${1:-}"
  _dsb_tf_configure_shell
  _dsb_tf_init 1 "${envName}" # $1 = 1 means do -upgrade
  local returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-bump-cicd() {
  _dsb_tf_configure_shell
  _dsb_tf_bump_github
  local returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-bump-modules() {
  _dsb_tf_configure_shell
  _dsb_tf_bump_registry_module_versions
  local returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-bump-tflint-plugins() {
  _dsb_tf_configure_shell
  _dsb_tf_bump_tflint_plugin_versions
  local returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-show-provider-upgrades() {
  local envToCheck="${1:-}"
  _dsb_tf_configure_shell
  _dsb_tf_list_available_terraform_provider_upgrades_for_env "${envToCheck}"
  local returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-show-all-provider-upgrades() {
  _dsb_tf_configure_shell
  _dsb_tf_list_available_terraform_provider_upgrades
  local returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-bump-env() {
  local envName="${1:-}"
  _dsb_tf_configure_shell
  _dsb_tf_bump_an_env "${envName}"
  local returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-bump() {
  local envName="${1:-}"
  _dsb_tf_configure_shell
  _dsb_tf_bump_the_project_single_env "${envName}"
  local returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

tf-bump-all() {
  _dsb_tf_configure_shell
  _dsb_tf_bump_the_project
  local returnCode="${_dsbTfReturnCode}"
  _dsb_tf_restore_shell
  return "${returnCode}"
}

# Help functions
# --------------
tf-help() {
  local arg="${1:-}"
  _dsb_tf_configure_shell
  _dsb_tf_help "${arg}"
  _dsb_tf_restore_shell
}

###################################################################################################
#
# Init: final setup
#
###################################################################################################

# TODO: consider this scrolling other places as well
printf "\033[2J\033[H" # Scroll the shell output to hide previous output without clearing the buffer
_dsb_tf_enumerate_directories || :
_dsb_tf_register_all_completions || :
_dsb_i "DSB Terraform Project Helpers 🚀"
_dsb_i "  to get started, run 'tf-help' or 'tf-status'"
