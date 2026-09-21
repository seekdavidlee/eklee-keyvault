#!/usr/bin/env bash
set -euo pipefail

: "${BRANCH_NAME:?BRANCH_NAME is required}"

if [[ "$BRANCH_NAME" == "main" ]]; then
  : "${DEV_CONTAINER_APP_NAME:?DEV_CONTAINER_APP_NAME is required for main}"
  echo "$DEV_CONTAINER_APP_NAME"
  exit 0
fi

if [[ "$BRANCH_NAME" == release/* ]]; then
  : "${RELEASE_CONTAINER_APP_NAME:?RELEASE_CONTAINER_APP_NAME is required for release branches}"
  echo "$RELEASE_CONTAINER_APP_NAME"
else
  : "${BRANCH_CONTAINER_APP_NAME:?BRANCH_CONTAINER_APP_NAME is required for feature and bugfix branches}"
  echo "$BRANCH_CONTAINER_APP_NAME"
fi
