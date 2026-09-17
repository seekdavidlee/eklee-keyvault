#!/usr/bin/env bash
# Copyright (c) 2026 Microsoft Corporation. All rights reserved.
# SPDX-License-Identifier: MIT
#
# Resolve a Git ref to a bounded, collision-resistant container image tag.

set -euo pipefail

: "${REF_NAME:?REF_NAME is required}"

if [[ "$REF_NAME" == "main" ]]; then
  printf 'latest\n'
  exit 0
fi

if [[ "$REF_NAME" == release/* ]]; then
  prefix="release-"
  normalized=$(printf '%s' "${REF_NAME#release/}" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9.-]+/-/g; s/^[.-]+//; s/[.-]+$//')
else
  prefix="branch-"
  normalized=$(printf '%s' "$REF_NAME" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
fi

normalized=${normalized:-ref}
hash=$(printf '%s' "$REF_NAME" | sha256sum | cut -c1-12)
max_slug_length=$((128 - ${#prefix} - 1 - ${#hash}))
slug=${normalized:0:max_slug_length}
slug=$(printf '%s' "$slug" | sed -E 's/[-.]+$//')
slug=${slug:-ref}

printf '%s%s-%s\n' "$prefix" "$slug" "$hash"