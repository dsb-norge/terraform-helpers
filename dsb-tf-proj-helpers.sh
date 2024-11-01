#!/usr/bin/env bash
#
# Developer notes
#
#   types of functions in this file:
#     "exposed" functions
#       are those prefixed with 'tf-' and 'az-'
#       these are the functions that are intended to be called by the user from the command line
#       these are suported by tf-help
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
#   maintainance and development
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
#
#   other
#     tf-test         -> terraform test in chosen env, use poc from lock module
#     tf-* functions for _terraform-state env
#
#   upgrading
#    look into:
#     tfupdate :
#       install  : go install github.com/minamijoyo/tfupdate@latest
#       providers:
#         - read 'version' from lock file
#         - use tfupdate: tfupdate release latest --source-type tfregistryProvider 'hashicorp/azurerm'
#         - show possible upgrades
#       modules  :
#         - read 'source' from tf files
#         - use tfupdate: tfupdate release latest --source-type tfregistryModule "Azure/naming/azurerm"
#         - show possible upgrades
#       note: there is also a list command: fupdate release list --source-type tfregistryModule --max-length 3 "Azure/naming/azurerm"
#    proposed commands:
#     tf-bump-tflint-plugins  -> tflint-plugins in chosen env
#     tf-bump-modules         -> upgrade modules in code everywhere
#     tf-bump-providers       -> find latest version of providers and modify versions.tf (tf-upgrade after?)
#     tf-bump                 -> providers og tflint-plugins in chosen env
#     tf-bump-all             -> providers og tflint-plugins in alle env + terraform and tflint in GitHub workflows
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
# Init: global variables
#
###################################################################################################

declare -g _dsbTfShellOldOpts=""      # used for persisting original shell options, and restoring them on exit
declare -g _dsbTfShellHistoryState="" # used for persisting original shell history state, and restoring it on exit

declare -g _dsbTfRootDir=""      # root directory of the project, ie. the current directory when a function is called
declare -g _dsbTfEnvsDir=""      # environments directory of the project
declare -g _dsbTfMainDir=""      # main directory of the project
declare -g _dsbTfModulesDir=""   # modules directory of the project
declare -gA _dsbTfEnvsDirList    # Associative array, key is environment name, value is directory
declare -ga _dsbTfAvailableEnvs  # Indexed array, list of available environment names in the project
declare -gA _dsbTfModulesDirList # Associative array, key is module name, value is directory

declare -g _dsbTfTflintWrapperDir=""    # directory where the tflint wrapper script will be placed
declare -g _dsbTfTflintWrapperScript="" # full path to the tflint wrapper script

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
# Utility functions: general
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
    local tmpFile=$(mktemp)
    sed "s/${funcName}/${newFuncName}/g" ${outFile} >"${tmpFile}"
    mv "${tmpFile}" ${outFile}

    replacements[${funcName}]="${newFuncName}" # record the replacement
  done

  # ignore unintresting functions
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
    _dsb_e "Error occured:"
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
  # -E: Inherit ERR trap in subshells
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
    "tf-bump-cicd"
  )
  echo "${commands[@]}"
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
    "terraform"
    "upgrading"
  )
  local -a validCommands
  mapfile -t validCommands < <(_dsb_tf_help_get_commands_supported_by_help)
  echo "${validgroups[@]}" "${validCommands[@]}"
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
  _dsb_i "  az-relog          -> Azure relogin"
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
  _dsb_i "    az-relog              -> Azure relogin"
  _dsb_i "    az-whoami             -> Show Azure account information"
  _dsb_i "    az-set-sub            -> Set Azure subscription from current env hint file"
}

_dsb_tf_help_group_terraform() {
  _dsb_i "  Terraform Commands:"
  _dsb_i "    tf-init [env]         -> Initialize entire Terraform project with selected or given environment"
  _dsb_i "    tf-init-env [env]     -> Initialize selected or given environment (environment directory only)"
  _dsb_i "    tf-init-main          -> Initialize Terraform project's main module"
  _dsb_i "    tf-init-modules       -> Initialize Terraform project's local sub modules"
  _dsb_i "    tf-fmt                -> Run syntax check recursively from current directory"
  _dsb_i "    tf-fmt-fix            -> Run syntax check and fix recursively from current directory"
  _dsb_i "    tf-validate [env]     -> Make Terraform validate the project with selected or given environment"
  _dsb_i "    tf-plan [env]         -> Make Terraform create a plan for the selected or given environment"
  _dsb_i "    tf-apply [env]        -> Make Terraform apply changes forthe selected or given environment"
  _dsb_i "    tf-destroy [env]      -> Show command to manually destroy the selected or given environment"
}

_dsb_tf_help_group_upgrading() {
  _dsb_i "  Upgrade Commands:"
  _dsb_i "    tf-upgrade [env]      -> Upgrade Terraform dependencies for entire project with selected or given environment"
  _dsb_i "    tf-upgrade-env [env]  -> Upgrade Terraform dependencies of selected or given environment (environment directory only)"
  _dsb_i "    tf-bump-cicd          -> Bump versions in GitHub workflows"
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
    _dsb_i "  Tab completion is supportd for specifying environment."
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
    _dsb_i "  Relogin to Azure with the Azure CLI."
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
    _dsb_i "  Initialize the entire Terraform project with the specified environment."
    _dsb_i "  If environment is not specified, the selected environment is used."
    _dsb_i ""
    _dsb_i "  This initializes the project completely, environment directory sub modules and main."
    _dsb_i ""
    _dsb_i "  Supports tab completion for environment."
    _dsb_i ""
    _dsb_i "  Related commands: tf-upgrade, tf-plan, tf-apply."
    ;;
  tf-init-env)
    _dsb_i "tf-init-env [env]:"
    _dsb_i "  Initialize the specified Terraform environment."
    _dsb_i "  If environment is not specified, the selected environment is used."
    _dsb_i ""
    _dsb_i "  Note:"
    _dsb_i "    This initializes just the environment directory, not sub modules and main."
    _dsb_i "    Use 'tf-init' for a complete initialization of the project."
    _dsb_i ""
    _dsb_i "  Supports tab completion for environment."
    _dsb_i ""
    _dsb_i "  Related commands: tf-init-main, tf-init-modules, tf-init."
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
    _dsb_i "    This initializes just the main directory, not sub modules."
    _dsb_i "    Use 'tf-init' for a complete initialization of the project."
    _dsb_i ""
    _dsb_i ""
    _dsb_i "  Related commands: tf-init-env, tf-init."
    ;;
  tf-init-modules)
    _dsb_i "tf-init-modules:"
    _dsb_i "  Initialize Terraform project's local sub modules."
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
    _dsb_i "  Related commands: tf-init-env, tf-init"
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
  tf-upgrade)
    _dsb_i "tf-upgrade [env]:"
    _dsb_i "  Upgrade Terraform dependencies and initialize the entire project."
    _dsb_i "  If environment is not specified, the selected environment is used."
    _dsb_i ""
    _dsb_i "  This upgrades and initializes the project completely, environment directory sub modules and main."
    _dsb_i "  Upgrade is performed within the current version constraints, ie. no version constraints are changed."
    _dsb_i ""
    _dsb_i ""
    _dsb_i "  Supports tab completion for environment."
    _dsb_i ""
    _dsb_i "  Related commands: tf-init, tf-plan, tf-apply."
    ;;
  tf-upgrade-env)
    _dsb_i "tf-upgrade-env [env]:"
    _dsb_i "  Upgrade Terraform dependencies and initialize the specified environment."
    _dsb_i "  If environment is not specified, the selected environment is used."
    _dsb_i ""
    _dsb_i "  Upgrade is performed within the current version constraints, ie. no version constraints are changed."
    _dsb_i ""
    _dsb_i "  Note:"
    _dsb_i "    This upgrades and initializes just the environment directory, not sub modules and main."
    _dsb_i "    Use 'tf-upgrade' for a complete depenedency upgrade and initialization of the entire project."
    _dsb_i ""
    _dsb_i "  Supports tab completion for environment."
    _dsb_i ""
    _dsb_i "  Related commands: tf-init-main, tf-init-modules, tf-upgrade."
    ;;
  tf-bump-cicd)
    _dsb_i "tf-bump-cicd:"
    _dsb_i "  Bump versions in GitHub workflows."
    _dsb_i "  Currently supports bumping Terraform and tflint versions."
    _dsb_i ""
    _dsb_i "  Retreives the latest versions from GitHub and updates all workflow files in .github/workflows."
    _dsb_i "  If a tool is configured with 'latest' it will not be updated."
    _dsb_i ""
    _dsb_i "  If a tool is configured with partial semver version or x as wildcard, the syntax is preserved and versions updated as needed."
    _dsb_i "  Examples where latest version is 'v1.13.7':"
    _dsb_i "    - \e[90m'v1.12.2'\e[0m becomes \e[32m'v1.13.7'\e[0m"
    _dsb_i "    - \e[90m'v1.12.x'\e[0m becomes \e[32m'v1.13.x'\e[0m"
    _dsb_i "    - \e[90m'v1.12'\e[0m becomes \e[32m'v1.13'\e[0m"
    _dsb_i "    - \e[90m'v0'\e[0m becomes \e[32m'v1'\e[0m"
    _dsb_i ""
    _dsb_i "  Related commands: tf-upgrade."
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
_dsb_tf_completions_for_avalable_envs() {
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
  complete -F _dsb_tf_completions_for_avalable_envs tf-set-env
  complete -F _dsb_tf_completions_for_avalable_envs tf-check-env
  complete -F _dsb_tf_completions_for_avalable_envs tf-select-env
  complete -F _dsb_tf_completions_for_avalable_envs tf-init-env
  complete -F _dsb_tf_completions_for_avalable_envs tf-init
  complete -F _dsb_tf_completions_for_avalable_envs tf-upgrade-env
  complete -F _dsb_tf_completions_for_avalable_envs tf-upgrade
  complete -F _dsb_tf_completions_for_avalable_envs tf-validate
  complete -F _dsb_tf_completions_for_avalable_envs tf-plan
  complete -F _dsb_tf_completions_for_avalable_envs tf-apply
  complete -F _dsb_tf_completions_for_avalable_envs tf-destroy
  complete -F _dsb_tf_completions_for_avalable_envs tf-lint
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

# TODO: need this?
# what:
#   check if yq is available
# input:
#   none
# on info:
#   nothing
# returns:
#   exit code directly
# _dsb_tf_check_yq() {
#   if ! yq --version &>/dev/null; then
#     _dsb_e "yq not found."
#     _dsb_e "  checked with command: yq --version"
#     _dsb_e "  make sure yq is available in your PATH"
#     _dsb_e "  for installation instructions see: https://mikefarah.gitbook.io/yq#install"
#     return 1
#   fi
#   return 0
# }

# TODO: enable when needed
# what:
#   check if Go is available
# input:
#   none
# on info:
#   nothing
# returns:
#   exit code directly
# _dsb_tf_check_golang() {
#   if ! go version &>/dev/null; then
#     _dsb_e "Go not found."
#     _dsb_e "  checked with command: go version"
#     _dsb_e "  make sure go is available in your PATH"
#     _dsb_e "  for installation instructions see: https://go.dev/doc/install"
#     return 1
#   fi
#   return 0
# }

# TODO: enable when needed
# what:
#   check if hcledit is available
# input:
#   none
# on info:
#   nothing
# returns:
#   exit code directly
# _dsb_tf_check_hcledit() {
#   if ! hcledit version &>/dev/null; then
#     _dsb_e "hcledit not found."
#     _dsb_e "  checked with command: hcledit version"
#     _dsb_e "  make sure hcledit is available in your PATH"
#     _dsb_e "  for installation instructions see: https://github.com/minamijoyo/hcledit?tab=readme-ov-file#install"
#     _dsb_e "  or install it with: 'go install github.com/minamijoyo/hcledit@latest; export PATH=\$PATH:\$(go env GOPATH)/bin; echo \"export PATH=\$PATH:\$(go env GOPATH)/bin\" >> ~/.bashrc'"
#     return 1
#   fi
#   return 0
# }

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
#   check if realpath is available
# input:
#   none
# on info:
#   nothing
# returns:
#   exit code directly
_dsb_tf_check_realpath() {
  if ! realpath --version &>/dev/null; then
    _dsb_e "realpath not found."
    _dsb_e "  checked with command: realpath --version"
    _dsb_e "  make sure realpath is available in your PATH"
    _dsb_e "  install it with one of:"
    _dsb_e "    - Ubuntu: 'sudo apt-get install coreutils'"
    _dsb_e "    - OS X  : 'brew install coreutils'"
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

  # _dsb_i "Checking yq ..."
  # _dsb_tf_check_yq
  # local yqStatus=$?

  # _dsb_i "Checking Go ..."
  # _dsb_tf_check_golang
  # local golangStatus=$?

  # _dsb_i "Checking hcledit ..."
  # _dsb_tf_check_hcledit
  # local hcleditStatus=$?

  # _dsb_i "Checking terraform-docs ..."
  # _dsb_tf_check_terraform_docs
  # local terraformDocsStatus=$?

  _dsb_i "Checking realpath ..."
  _dsb_tf_check_realpath
  local realpathStatus=$?

  # local returnCode=$((azCliStatus + ghCliStatus + terraformStatus + jqStatus + yqStatus + golangStatus + hcleditStatus + terraformDocsStatus + realpathStatus))
  local returnCode=$((azCliStatus + ghCliStatus + terraformStatus + jqStatus + realpathStatus))

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
  # if [ ${yqStatus} -eq 0 ]; then
  #   _dsb_i "  \e[32m☑\e[0m  yq check             : passed."
  # else
  #   _dsb_i "  \e[31m☒\e[0m  yq check             : fails, see above for more information."
  # fi
  # if [ ${golangStatus} -eq 0 ]; then
  #   _dsb_i "  \e[32m☑\e[0m  Go check             : passed."
  # else
  #   _dsb_i "  \e[31m☒\e[0m  Go check             : fails, see above for more information."
  # fi
  # if [ ${hcleditStatus} -eq 0 ]; then
  #   _dsb_i "  \e[32m☑\e[0m  hcledit check        : passed."
  # else
  #   _dsb_i "  \e[31m☒\e[0m  hcledit check        : fails, see above for more information."
  # fi
  # if [ ${terraformDocsStatus} -eq 0 ]; then
  #   _dsb_i "  \e[32m☑\e[0m  terraform-docs check : passed."
  # else
  #   _dsb_i "  \e[31m☒\e[0m  terraform-docs check : fails, see above for more information."
  # fi
  if [ ${realpathStatus} -eq 0 ]; then
    _dsb_i "  \e[32m☑\e[0m  realpath check       : passed."
  else
    _dsb_i "  \e[31m☒\e[0m  realpath check       : fails, see above for more information."
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
    _dsb_e "\e[31mPre-reqs check failed, for more information see above.\e[0m"
  fi

  _dsb_d "returnCode: ${returnCode}"

  _dsbTfReturnCode=$returnCode
  _dsb_d "returning exit code in _dsbTfReturnCode=${_dsbTfReturnCode:-}"
  return 0
}

# what:
#   check if environment exists, either supplied or the currenlty selected environment
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
  realpath --relative-to="${_dsbTfRootDir:-.}" "${dirName}"
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
  _dsbTfRootDir="$(realpath .)"
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
  if [ ! -f "${selectedEnvDir}/${lookForFilename}" ]; then
    _dsb_e "File not found in selected environment. A '${suppliedFileType}' file is required for an environment to be considered valid."
    _dsb_e "  selected environment: ${selectedEnv}"
    _dsb_e "  expected ${suppliedFileType} file: ${selectedEnvDir}/${lookForFilename}"
    return 1
  fi

  declare -g "${suppliedGlobalToSavePathTo}=${selectedEnvDir}/${lookForFilename}"
  _dsb_d "global variable ${suppliedGlobalToSavePathTo} has been set to ${selectedEnvDir}/${lookForFilename}"
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
    return 1
  fi

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
#   avaiable environment names (implicitly by _dsb_tf_list_envs)
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
  local clearStatus=0
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
_dsb_tf_az_relogin() {
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
#   set the Azure subscription accoring to the selected environment's subscription hint
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

  _dsb_d "current subscription name does not match subscription hint, proceed with cheking login status"

  # chek if user is logged in
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
#   checks if an environment is selected
#   checks if terraform is installed
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
#   initializes all local sub modules in the current directory / terraform project
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
      _dsb_e "  init operation not complete, consider enabling debug mode"
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

  # to able to init naib, we need to have the lock file and the providers directory
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
    _dsb_e "Failed to init directory: ${moduleDir_dsbTfMainDir}"
    _dsb_e "  init operation not complete, consider enabling debug mode"
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
#   $2: environment directory (optional, defaults to selected environment directory)
# on info:
#   status messages are printed
# returns:
#   exit code in _dsbTfReturnCode
_dsb_tf_init() {
  local doUpgrade="${1}"
  local selectedEnv="${2:-${_dsbTfSelectedEnv:-}}"

  _dsb_tf_init_env "${doUpgrade}" "${selectedEnv}"
  local initEnvStatus=${_dsbTfReturnCode}
  if [ "${initEnvStatus}" -ne 0 ]; then
    return 0 # caller reads _dsbTfReturnCode
  fi

  _dsb_tf_init_modules 1 # $1 = 1 means skip preflight checks
  local initModulesStatus=${_dsbTfReturnCode}
  if [ "${initModulesStatus}" -ne 0 ]; then
    return 0 # caller reads _dsbTfReturnCode
  fi

  _dsb_tf_init_main 1 # $1 = 1 means skip preflight checks
  local initMainStatus=${_dsbTfReturnCode}

  _dsbTfReturnCode=$((initEnvStatus + initModulesStatus + initMainStatus))

  _dsb_d "returning exit code in _dsbTfReturnCode=${_dsbTfReturnCode:-}"
  return 0
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

  # leverage _dsb_tf_set_env, this enumerates diresctories and validates the environment
  _dsbTfLogInfo=1 _dsbTfLogErrors=0 _dsb_tf_set_env "${selectedEnv}"
  if [ "${_dsbTfReturnCode}" -ne 0 ]; then
    _dsb_e "Failed to set environment '${selectedEnv}'."
    _dsb_e "  please run 'tf-check-env ${selectedEnv}'"
    _dsbTfReturnCode=1
    return 0
  fi

  # make sure tflint is installed
  if ! _dsbTfLogErrors=0 _dsb_tf_install_tflint_wrapper; then
    _dsb_e "Failed to install tflint wrapper, consider enabling debug mode"
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
    # incepetion
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
  _dsb_tf_init 0 "${envName}" # $1 = 0 means do not -upgrade
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
