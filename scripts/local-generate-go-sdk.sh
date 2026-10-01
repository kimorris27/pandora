#!/usr/bin/env bash
# Copyright IBM Corp. 2023, 2026
# SPDX-License-Identifier: MPL-2.0

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<EOF
Usage: $(basename "$0") <resource-manager|data-plane>

Imports Pandora's configured azure-rest-api-specs submodule, then generates the
selected SDK into an existing local hashicorp/go-azure-sdk checkout.

Required environment variables:
  GO_AZURE_SDK_DIR  Absolute path to your hashicorp/go-azure-sdk checkout.

Optional environment variables:
  SERVICES                  Comma-separated Pandora service names to import.
                            Example: SERVICES=Compute,Network
  GOBIN                     Directory for locally built tools.
                            Default: ${DIR}/.bin
  SKIP_IMPORT               Set to 1 to generate from the existing api-definitions.
  SKIP_PREPARE              Set to 1 to skip 'make prepare' in go-azure-sdk.
  SKIP_TESTS                Set to 1 to skip 'go mod tidy' and 'go test ./...'.
  LOG_LEVEL                 Pandora tool log level, such as DEBUG or TRACE.

Examples:
  export GO_AZURE_SDK_DIR="\$HOME/src/go-azure-sdk"

  $(basename "$0") resource-manager
  SERVICES=Compute $(basename "$0") resource-manager
  $(basename "$0") data-plane
  SKIP_IMPORT=1 SKIP_PREPARE=1 SKIP_TESTS=1 \\
    $(basename "$0") resource-manager

Notes:
  - This script modifies Pandora's api-definitions and the SDK checkout.
  - The configured submodule URL is synchronized from .gitmodules before import.
  - The specs submodule is checked out at the commit recorded by Pandora, not
    automatically advanced to the fork's default branch.
  - The script may clone the specs submodule when it is not initialized.
  - The script does not clone or delete the SDK checkout, commit, or push.
EOF
}

fail() {
  echo "Error: $*" >&2
  echo >&2
  usage >&2
  exit 1
}

require_directory() {
  local variable_name=$1
  local directory=$2

  if [[ ! -d "$directory" ]]; then
    fail "$variable_name does not point to a directory: $directory"
  fi
}

update_specs_submodule() {
  local submodule_path="submodules/rest-api-specs"

  if [[ -L "${DIR}/${submodule_path}" ]]; then
    fail "${DIR}/${submodule_path} is a symlink; remove the legacy local-checkout symlink before continuing"
  fi

  echo "Synchronizing and initializing the azure-rest-api-specs submodule..."
  git -C "$DIR" submodule sync -- "$submodule_path"
  git -C "$DIR" submodule update --init -- "$submodule_path"
}

import_api_definitions() {
  if [[ "${SKIP_IMPORT:-0}" == "1" ]]; then
    echo "Skipping REST API specs import."
    return
  fi

  update_specs_submodule

  echo "Importing ${sdk_to_generate} API definitions..."
  cd "${DIR}/tools/importer-rest-api-specs"
  make tools

  case "$sdk_to_generate" in
    resource-manager)
      make import SERVICES="${SERVICES:-}"
      ;;
    data-plane)
      make import-data-plane SERVICES="${SERVICES:-}"
      ;;
  esac
}

build_tools() {
  echo "Using $(go version)"
  mkdir -p "$GOBIN"

  echo "Installing the Data API..."
  cd "${DIR}/tools/data-api"
  go install .

  echo "Installing the Go SDK generator..."
  cd "${DIR}/tools/generator-go-sdk"
  go install .

  echo "Building the automation wrapper..."
  cd "${DIR}/tools/wrapper-automation"
  go build -o "${GOBIN}/wrapper-automation" .
}

prepare_sdk() {
  if [[ "${SKIP_PREPARE:-0}" == "1" ]]; then
    echo "Skipping SDK preparation."
    return
  fi

  echo "Preparing the go-azure-sdk checkout..."
  cd "$GO_AZURE_SDK_DIR"
  make prepare
}

generate_sdk() {
  echo "Generating ${sdk_to_generate} into $GO_AZURE_SDK_DIR..."
  "${GOBIN}/wrapper-automation" "$sdk_to_generate" go-sdk \
    --api-definitions-dir="${DIR}/api-definitions" \
    --output-dir="$GO_AZURE_SDK_DIR"

  echo "Formatting generated SDK code..."
  cd "$GO_AZURE_SDK_DIR"
  make tools
  make fmt
  make imports
}

test_sdk() {
  if [[ "${SKIP_TESTS:-0}" == "1" ]]; then
    echo "Skipping SDK tests."
    return
  fi

  echo "Tidying and testing the ${sdk_to_generate} module..."
  cd "${GO_AZURE_SDK_DIR}/${sdk_to_generate}"
  go mod tidy
  go test ./...
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -ne 1 ]]; then
  fail "exactly one SDK type must be specified"
fi

sdk_to_generate=$1
case "$sdk_to_generate" in
  resource-manager | data-plane)
    ;;
  *)
    fail "unsupported SDK type: $sdk_to_generate"
    ;;
esac

if [[ -z "${GO_AZURE_SDK_DIR:-}" ]]; then
  fail "GO_AZURE_SDK_DIR must be set"
fi

require_directory "GO_AZURE_SDK_DIR" "$GO_AZURE_SDK_DIR"

GO_AZURE_SDK_DIR="$(cd "$GO_AZURE_SDK_DIR" && pwd -P)"
GOBIN="${GOBIN:-${DIR}/.bin}"
export GOBIN
export PATH="${GOBIN}:${PATH}"

import_api_definitions
build_tools
prepare_sdk
generate_sdk
test_sdk

echo "Local ${sdk_to_generate} SDK generation completed successfully."
