#!/usr/bin/env bash
# Run bats tests, in parallel when GNU parallel is installed.
# Usage: bash test/run.sh [extra bats args...]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if ! command -v parallel &>/dev/null; then
  echo "GNU parallel not found, running the tests one file at a time." >&2
  echo "  install it to run them in parallel, ex. 'sudo apt-get install parallel' or 'brew install parallel'" >&2
  exec npx bats "$@" "${PROJECT_DIR}"/test/*.bats
fi

exec npx bats --jobs "$(nproc)" "$@" "${PROJECT_DIR}"/test/*.bats
