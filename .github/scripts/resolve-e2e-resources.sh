#!/usr/bin/env bash
#
# resolve-e2e-resources.sh
# Resolve the Key Vault and Storage Account used by GitHub Actions E2E tests.

set -euo pipefail

## Required Environment Variables:
# RESOURCE_GROUP          - Azure resource group containing the deployment
# DEPLOYMENT_ENVIRONMENT  - Deployment environment, such as dev or prod
# GITHUB_OUTPUT           - GitHub Actions output file
## Optional Environment Variables:
# KEYVAULT_URI_OVERRIDE   - Explicit Key Vault URI override
# STORAGE_URI_OVERRIDE    - Explicit Storage Account blob URI override

err() {
  printf '::error::%s\n' "$1" >&2
  exit 1
}

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" &>/dev/null; then
    err "Required command '$command_name' is not installed."
  fi
}

require_environment_variable() {
  local variable_name="$1"

  if [[ -z "${!variable_name:-}" ]]; then
    err "Required environment variable '$variable_name' is not set."
  fi
}

get_name_from_uri() {
  local uri="$1"
  local resource_type="$2"
  local name=""

  if [[ "$resource_type" == "keyvault" && "$uri" =~ ^https://([a-zA-Z0-9-]+)\.vault\.azure\.net/?$ ]]; then
    name="${BASH_REMATCH[1]}"
  elif [[ "$resource_type" == "storage" && "$uri" =~ ^https://([a-zA-Z0-9-]+)\.blob\.core\.windows\.net/?$ ]]; then
    name="${BASH_REMATCH[1]}"
  else
    err "Invalid $resource_type URI override. Expected an Azure resource URI."
  fi

  printf '%s' "$name"
}

select_tagged_resource() {
  local resource_label="$1"
  local resource_json="$2"
  local candidates
  local candidate_count
  local candidate_names

  candidates=$(printf '%s' "$resource_json" | jq \
    --arg application "Eklee-KeyVault" \
    --arg environment "$DEPLOYMENT_ENVIRONMENT" \
    '[.[] | select(.tags.Application == $application and .tags.Environment == $environment)]')
  candidate_count=$(printf '%s' "$candidates" | jq 'length')

  if [[ "$candidate_count" -ne 1 ]]; then
    candidate_names=$(printf '%s' "$candidates" | jq -r 'map(.name) | join(", ")')
    err "Expected exactly one tagged $resource_label in resource group \
'${RESOURCE_GROUP}' for environment '${DEPLOYMENT_ENVIRONMENT}'; found \
${candidate_count}${candidate_names:+ (${candidate_names})}. Required tags: \
Application=Eklee-KeyVault and Environment=${DEPLOYMENT_ENVIRONMENT}"
  fi

  printf '%s' "$candidates" | jq -r '.[0].name'
}

write_output() {
  local name="$1"
  local value="$2"

  printf '%s=%s\n' "$name" "$value" >> "$GITHUB_OUTPUT"
}

main() {
  local kv_json
  local sa_json
  local kv_name
  local kv_uri
  local sa_name
  local storage_uri
  local e2e_container

  require_command az
  require_command jq

  require_environment_variable "RESOURCE_GROUP"
  require_environment_variable "DEPLOYMENT_ENVIRONMENT"
  require_environment_variable "GITHUB_OUTPUT"

  kv_json=$(az keyvault list \
    --resource-group "$RESOURCE_GROUP" \
    --output json)
  sa_json=$(az storage account list \
    --resource-group "$RESOURCE_GROUP" \
    --output json)

  if [[ -n "${KEYVAULT_URI_OVERRIDE:-}" ]]; then
    kv_uri="$KEYVAULT_URI_OVERRIDE"
    kv_name=$(get_name_from_uri "$kv_uri" keyvault)
    az keyvault show \
      --name "$kv_name" \
      --resource-group "$RESOURCE_GROUP" \
      --query name \
      --output tsv >/dev/null
    printf "Using E2E_KEYVAULT_URI override for Key Vault '%s'.\n" "$kv_name"
  else
    kv_name=$(select_tagged_resource "Key Vault" "$kv_json")
    kv_uri=$(printf '%s' "$kv_json" | jq -r \
      --arg name "$kv_name" \
      '.[] | select(.name == $name) | .properties.vaultUri')
    printf "Discovered Key Vault '%s' from resource group and deployment tags.\n" \
      "$kv_name"
  fi

  if [[ -n "${STORAGE_URI_OVERRIDE:-}" ]]; then
    storage_uri="$STORAGE_URI_OVERRIDE"
    sa_name=$(get_name_from_uri "$storage_uri" storage)
    az storage account show \
      --name "$sa_name" \
      --resource-group "$RESOURCE_GROUP" \
      --query name \
      --output tsv >/dev/null
    printf "Using E2E_STORAGE_URI override for Storage Account '%s'.\n" "$sa_name"
  else
    sa_name=$(select_tagged_resource "Storage Account" "$sa_json")
    storage_uri=$(printf '%s' "$sa_json" | jq -r \
      --arg name "$sa_name" \
      '.[] | select(.name == $name) | .primaryEndpoints.blob')
    printf "Discovered Storage Account '%s' from resource group and deployment tags.\n" \
      "$sa_name"
  fi

  if [[ -z "$kv_uri" || "$kv_uri" == "null" || \
    -z "$storage_uri" || "$storage_uri" == "null" ]]; then
    err "Resolved resource properties did not contain both required endpoint URIs."
  fi

  write_output "kv_name" "$kv_name"
  write_output "keyvault_uri" "$kv_uri"
  write_output "sa_name" "$sa_name"
  write_output "storage_uri" "$storage_uri"

  e2e_container="e2e-$(date +%s)"
  write_output "e2e_container" "$e2e_container"

  printf 'Key Vault name: %s\n' "$kv_name"
  printf 'Storage Account name: %s\n' "$sa_name"
  printf 'Key Vault URI: %s\n' "$kv_uri"
  printf 'Storage Blob URI: %s\n' "$storage_uri"
  printf 'E2E container name: %s\n' "$e2e_container"
}

main "$@"
