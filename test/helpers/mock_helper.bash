#!/usr/bin/env bash
# mock_helper.bash -- mock definitions for all external tools
#
# Each tool has:
#   mock_<tool>               -- tool is available and returns canned responses
#   mock_<tool>_not_installed -- tool is not available (returns 1)
# Some tools have additional variants for specific states.

# ============================================================
# az (Azure CLI)
# ============================================================
mock_az() {
  az() {
    case "$1" in
      --version) echo "azure-cli 2.55.0 *" ; return 0 ;;
      account)
        shift
        case "$1" in
          show)
            cat <<'AZ_SHOW'
{"environmentName":"AzureCloud","id":"00000000-0000-0000-0000-000000000001","isDefault":true,"name":"mock-sub-dev","state":"Enabled","tenantDisplayName":"MockTenant","tenantId":"00000000-0000-0000-0000-000000000099","user":{"name":"test@example.com","type":"user"}}
AZ_SHOW
            return 0
            ;;
          clear) return 0 ;;
          list)
            shift
            cat <<'AZ_LIST'
[{"id":"00000000-0000-0000-0000-000000000001","isDefault":true,"name":"mock-sub-dev","tenantDisplayName":"Tenant1","state":"Enabled","user":{"name":"test@example.com"}},{"id":"00000000-0000-0000-0000-000000000002","isDefault":false,"name":"mock-sub-prod","tenantDisplayName":"Tenant1","state":"Enabled","user":{"name":"test@example.com"}}]
AZ_LIST
            return 0
            ;;
          set) return 0 ;;
        esac
        ;;
      login)
        # simulate successful login -- output JSON array
        echo '[{"cloudName":"AzureCloud","id":"00000000-0000-0000-0000-000000000001","name":"mock-sub-dev"}]'
        return 0
        ;;
    esac
    return 0
  }
  export -f az
}

mock_az_not_installed() {
  az() { echo "command not found: az" >&2; return 127; }
  export -f az
}

mock_az_not_logged_in() {
  az() {
    case "$1" in
      --version) echo "azure-cli 2.55.0 *"; return 0 ;;
      account)
        shift
        case "$1" in
          show) echo "Please run 'az login'" >&2; return 1 ;;
          clear) return 0 ;;
          *) return 1 ;;
        esac
        ;;
    esac
    return 0
  }
  export -f az
}

# ============================================================
# gh (GitHub CLI)
# ============================================================
mock_gh() {
  gh() {
    case "$1" in
      --version) echo "gh version 2.40.0 (2024-01-01)"; return 0 ;;
      auth)
        shift
        case "$1" in
          status)
            echo "github.com"
            echo "  Logged in to github.com account testuser (keyring)"
            return 0
            ;;
          token) echo "gho_mocktoken123"; return 0 ;;
        esac
        ;;
      api)
        # $2 is typically -H, $3 is the header, then we might have more flags
        # find the API path -- scan args for something starting with / or repos/
        local api_path=""
        local jq_filter=""
        local accept_header=""
        local i=1
        while [[ $i -le $# ]]; do
          local arg="${!i}"
          case "${arg}" in
            -H) ((i++)) ; accept_header="${!i}" ;;
            --jq) ((i++)) ; jq_filter="${!i}" ;;
            /repos/*|repos/*) api_path="${arg}" ;;
          esac
          ((i++))
        done

        case "${api_path}" in
          */hashicorp/terraform/releases/latest)
            local json='{"tag_name":"v1.7.0"}'
            if [[ -n "${jq_filter}" ]]; then
              echo "${json}" | command jq -r "${jq_filter}" 2>/dev/null || echo "v1.7.0"
            else
              echo "${json}"
            fi
            ;;
          */terraform-linters/tflint/releases/latest)
            local json='{"tag_name":"v0.55.0"}'
            if [[ -n "${jq_filter}" ]]; then
              echo "${json}" | command jq -r "${jq_filter}" 2>/dev/null || echo "v0.55.0"
            else
              echo "${json}"
            fi
            ;;
          */tflint-ruleset-*/releases/latest)
            local json='{"tag_name":"v0.30.0"}'
            if [[ -n "${jq_filter}" ]]; then
              echo "${json}" | command jq -r "${jq_filter}" 2>/dev/null || echo "v0.30.0"
            else
              echo "${json}"
            fi
            ;;
          */terraform-helpers/contents/*)
            # tflint wrapper script download
            if [[ "${accept_header}" == *"raw"* ]]; then
              echo '#!/usr/bin/env bash'
              echo 'echo "mock tflint wrapper"'
            fi
            ;;
        esac
        return 0
        ;;
    esac
    return 0
  }
  export -f gh
}

mock_gh_not_installed() {
  gh() { echo "command not found: gh" >&2; return 127; }
  export -f gh
}

mock_gh_not_authenticated() {
  gh() {
    case "$1" in
      --version) echo "gh version 2.40.0 (2024-01-01)"; return 0 ;;
      auth)
        shift
        case "$1" in
          status) return 1 ;;
          token) return 1 ;;
        esac
        ;;
    esac
    return 0
  }
  export -f gh
}

# ============================================================
# terraform
# ============================================================
mock_terraform() {
  # Track calls for verification
  declare -ga _MOCK_TERRAFORM_CALLS=()

  terraform() {
    _MOCK_TERRAFORM_CALLS+=("$*")

    case "$1" in
      -version|--version) echo "Terraform v1.7.0 on linux_amd64"; return 0 ;;
      -chdir=*)
        local chdir_dir="${1#-chdir=}"
        shift
        case "$1" in
          init)
            echo ""
            echo "Initializing the backend..."
            echo "Initializing provider plugins..."
            echo ""
            echo "Terraform has been successfully initialized!"
            return 0
            ;;
          validate)
            echo "Success! The configuration is valid."
            return 0
            ;;
          plan)
            echo "No changes. Your infrastructure matches the configuration."
            return 0
            ;;
          apply)
            echo "Apply complete! Resources: 0 added, 0 changed, 0 destroyed."
            return 0
            ;;
          providers)
            shift
            case "$1" in
              lock) return 0 ;;
            esac
            ;;
        esac
        ;;
      fmt)
        # Returns list of files that were changed (empty = no changes)
        return 0
        ;;
    esac
    return 0
  }
  export -f terraform
}

mock_terraform_not_installed() {
  terraform() { echo "command not found: terraform" >&2; return 127; }
  export -f terraform
}

mock_terraform_init_fails() {
  terraform() {
    case "$1" in
      -version|--version) echo "Terraform v1.7.0"; return 0 ;;
      -chdir=*)
        shift
        case "$1" in
          init)
            echo "Error: Failed to install provider" >&2
            return 1
            ;;
          *) return 0 ;;
        esac
        ;;
      *) return 0 ;;
    esac
  }
  export -f terraform
}

# ============================================================
# jq -- we use the real jq if available, mock if not
# ============================================================
mock_jq() {
  if ! command -v jq &>/dev/null; then
    jq() {
      # Minimal jq mock for common patterns
      case "$1" in
        -r)
          shift
          case "$1" in
            '.tag_name') grep -o '"tag_name":"[^"]*"' | head -1 | cut -d'"' -f4 ;;
            '.version') grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4 ;;
            '.user.name') grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4 ;;
            '.id') grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 ;;
            '.name') grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4 ;;
            '.tenantDisplayName') grep -o '"tenantDisplayName":"[^"]*"' | head -1 | cut -d'"' -f4 ;;
            *) cat ;; # passthrough
          esac
          ;;
        --version) echo "jq-mock-1.7" ;;
        *) cat ;;
      esac
    }
    export -f jq
  fi
  # If real jq is available, we don't override it -- it works on mock data just fine
}

mock_jq_not_installed() {
  jq() { echo "command not found: jq" >&2; return 127; }
  export -f jq
}

# ============================================================
# yq
# ============================================================
mock_yq() {
  yq() {
    case "$1" in
      --version) echo "yq (https://github.com/mikefarah/yq/) version v4.40.5" ; return 0 ;;
      eval)
        shift
        # For reading: just return a canned value
        if [[ "$*" == *"-i"* ]]; then
          # write mode -- do nothing
          return 0
        fi
        echo "1.6.5"
        return 0
        ;;
      *) return 0 ;;
    esac
  }
  export -f yq
}

mock_yq_not_installed() {
  yq() { echo "command not found: yq" >&2; return 127; }
  export -f yq
}

# ============================================================
# hcledit
# ============================================================
mock_hcledit() {
  hcledit() {
    case "$1" in
      version) echo "0.2.10" ; return 0 ;;
      block)
        shift
        case "$1" in
          list)
            # return some blocks based on file content context
            echo "module.main"
            return 0
            ;;
        esac
        ;;
      attribute)
        shift
        case "$1" in
          get)
            echo '"mock-value"'
            return 0
            ;;
          set)
            return 0
            ;;
        esac
        ;;
    esac
    return 0
  }
  export -f hcledit
}

mock_hcledit_not_installed() {
  hcledit() { echo "command not found: hcledit" >&2; return 127; }
  export -f hcledit
}

# ============================================================
# terraform-config-inspect
# ============================================================
mock_terraform_config_inspect() {
  terraform-config-inspect() {
    cat <<'INSPECT_JSON'
{"path":".","required_providers":{"azurerm":{"source":"hashicorp/azurerm","version_constraints":["~> 3.0"]}}}
INSPECT_JSON
  }
  export -f terraform-config-inspect
}

mock_terraform_config_inspect_not_installed() {
  terraform-config-inspect() { echo "command not found" >&2; return 127; }
  export -f terraform-config-inspect
}

# ============================================================
# curl
# ============================================================
mock_curl() {
  curl() {
    # find the URL in args
    local url="" output_file=""
    local i=1
    while [[ $i -le $# ]]; do
      local arg="${!i}"
      case "${arg}" in
        -o) ((i++)); output_file="${!i}" ;;
        http*) url="${arg}" ;;
      esac
      ((i++))
    done

    local response=""
    case "${url}" in
      *registry.terraform.io/v1/modules/*)
        response='{"version":"5.0.0"}'
        ;;
      *registry.terraform.io/v1/providers/*)
        response='{"version":"3.90.0"}'
        ;;
      *raw.githubusercontent.com*tflint*)
        response='#!/usr/bin/env bash
echo "mock tflint wrapper"'
        ;;
      *)
        response="mock-curl-response"
        ;;
    esac

    if [[ -n "${output_file}" ]]; then
      echo "${response}" > "${output_file}"
    else
      echo "${response}"
    fi
    return 0
  }
  export -f curl
}

mock_curl_not_installed() {
  curl() { echo "command not found: curl" >&2; return 127; }
  export -f curl
}

# ============================================================
# go
# ============================================================
mock_go() {
  go() {
    case "$1" in
      version) echo "go version go1.21.5 linux/amd64"; return 0 ;;
      env)
        case "$2" in
          GOPATH) echo "/home/mock/go" ;;
        esac
        ;;
    esac
    return 0
  }
  export -f go
}

mock_go_not_installed() {
  go() { echo "command not found: go" >&2; return 127; }
  export -f go
}

# ============================================================
# realpath -- lightweight mock
# ============================================================
mock_realpath() {
  realpath() {
    if [[ "$1" == "--relative-to="* ]]; then
      local base="${1#--relative-to=}"
      local target="$2"
      # Use python for reliable relative path, or fallback
      if command -v python3 &>/dev/null; then
        python3 -c "import os.path; print(os.path.relpath('$target', '$base'))"
      else
        # Rough fallback: strip common prefix
        echo "${target#${base}/}"
      fi
    else
      # Just resolve the path
      if [[ "$1" == /* ]]; then
        echo "$1"
      else
        echo "$(pwd)/$1"
      fi
    fi
  }
  export -f realpath
}

# ============================================================
# uname -- mock for platform detection
# ============================================================
mock_uname_linux_x86() {
  uname() {
    case "$1" in
      -m) echo "x86_64" ;;
      -s) echo "Linux" ;;
      *) command uname "$@" ;;
    esac
  }
  export -f uname
}

mock_uname_unsupported() {
  uname() {
    case "$1" in
      -m) echo "sparc64" ;;
      -s) echo "SunOS" ;;
      *) echo "unknown" ;;
    esac
  }
  export -f uname
}

# ============================================================
# Aggregate helpers
# ============================================================

# Apply all standard mocks -- tools are available and working
mock_standard_tools() {
  mock_az
  mock_gh
  mock_terraform
  mock_jq
  mock_yq
  mock_hcledit
  mock_terraform_config_inspect
  mock_curl
  mock_go
  mock_realpath
}

# Remove all mock function overrides
unmock_all() {
  local cmds=(
    az gh terraform jq yq hcledit terraform-config-inspect
    curl go realpath uname
  )
  for cmd in "${cmds[@]}"; do
    unset -f "${cmd}" 2>/dev/null || true
  done
}
