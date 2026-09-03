#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v pwsh >/dev/null 2>&1; then
  echo "PowerShell 7 (pwsh) is required to run the shared Terraform test workflow." >&2
  exit 1
fi

exec pwsh -NoProfile -File "$script_dir/test-resources.ps1" "$@"
