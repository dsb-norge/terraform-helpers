#!/bin/env bash

set -eo pipefail
shopt -s extglob # enable extended globbing

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
  echo -e "\e[34mINFO   : $1\e[0m"
}

_dsb-ok() {
  echo -e "\e[32mSUCCESS: $1\e[0m"
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
    _dsb-err "hcledit is not installed. Please install it with: 'go install github.com/minamijoyo/hcledit@latest; export PATH=\$PATH:$(go env GOPATH)/bin'"
    return 1
  fi
}

_dsb-tf-check-terraform-docs() {
  if ! terraform-docs --version &>/dev/null; then
    _dsb-err "terraform-docs is not installed. Please install it with: 'go install github.com/terraform-docs/terraform-docs@v0.19.0; export PATH=\$PATH:$(go env GOPATH)/bin'"
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

  if ! gh auth status &>/dev/null; then
    _dsb-err "You are not authenticated with GitHub. Please run 'gh auth login' to authenticate."
    return 1
  fi
}

_dsb-tf-resolve-root-directories() {
  _dsbTfRootDir="$(realpath .)"
  _dsbTfModulesDir="${_dsbTfRootDir}/modules"
  _dsbTfMainDir="${_dsbTfRootDir}/main"
  _dsbTfEnvsDir="${_dsbTfRootDir}/envs"
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

  if [ $returnCode -eq 0 ]; then
    _dsb-ok "Valid Terraform project structure."
  else
    _dsb-err "Not a valid Terraform project structure."
  fi

  return $returnCode
}

_dsb-tf-check-prereqs() {
  local logVerbose=${_dsbTfLogVerbose:-0}

  if [ "$logVerbose" -eq 1 ]; then _dsb-i "Checking tools ..."; fi
  if ! _dsb-tf-check-tools; then
    _dsb-err "Tools check failed."
  else
    if [ "$logVerbose" -eq 1 ]; then _dsb-ok "All required tools are installed."; fi
  fi
  if [ "$logVerbose" -eq 1 ]; then _dsb-i "Checking GitHub authentication ..."; fi
  if ! _dsb-tf-check-gh-auth; then
    _dsb-err "GitHub authentication check failed."
  else
    if [ "$logVerbose" -eq 1 ]; then _dsb-ok "Authenticated with GitHub."; fi
  fi
  if [ "$logVerbose" -eq 1 ]; then _dsb-i "Checking working directory ..."; fi
  if ! _dsb-tf-check-working-dir; then
    _dsb-err "Working directory check failed."
  else
    if [ "$logVerbose" -eq 1 ]; then _dsb-ok "Valid Terraform project structure."; fi
  fi
}

tf-check-prereqs() {
  _dsbTfLogVerbose=1
  _dsb-tf-resolve-root-directories
  _dsb-tf-check-prereqs
  unset _dsbTfLogVerbose
}
