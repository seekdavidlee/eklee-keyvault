#!/usr/bin/env bash
set -euo pipefail

: "${BRANCH_NAME:?BRANCH_NAME is required}"

if [[ "$BRANCH_NAME" == "main" ]]; then
  echo "eklee-keyvault"
  exit 0
fi

if [[ "$BRANCH_NAME" == release/* ]]; then
  kind="release"
else
  kind="branch"
fi

normalized=$(printf '%s' "$BRANCH_NAME" \
  | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
hash=$(printf '%s' "$BRANCH_NAME" | sha256sum | cut -c1-7)

# Container App names are limited to 32 characters. Keep the hash so that
# distinct long branch names cannot resolve to the same app.
slug=$(printf '%s' "$normalized" | cut -c1-12 | sed -E 's/-+$//')
container_app_name="ekv-${kind}-${slug}-${hash}"

if [[ ${#container_app_name} -gt 32 ]]; then
  echo "::error::Derived Container App name exceeds Azure's 32-character limit: $container_app_name" >&2
  exit 1
fi

echo "$container_app_name"