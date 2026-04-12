#!/usr/bin/env bash
# Run bats tests with GNU parallel for parallel execution.
# Usage: bash test/run.sh [extra bats args...]

# Install GNU parallel if not available
if ! command -v parallel &>/dev/null; then
  if [ ! -x /tmp/parallel ]; then
    curl -s https://raw.githubusercontent.com/martinda/gnu-parallel/master/src/parallel > /tmp/parallel
    chmod +x /tmp/parallel
  fi
  export PATH="/tmp:$PATH"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

exec npx bats --jobs "$(nproc)" "$@" "${PROJECT_DIR}"/test/*.bats
