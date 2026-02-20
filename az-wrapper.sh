#!/bin/bash
# Lightweight az CLI wrapper for local Docker development.
# AzureCliCredential shells out to `az account get-access-token`.
# This script intercepts that call and returns pre-fetched tokens
# mounted from the host at /tmp/az-tokens/<resource>.json.
#
# Token files are created by run-local.ps1 using the host's az CLI
# (where the user is already authenticated).

set -e

# Only handle the command AzureCliCredential actually calls
if [[ "$*" == *"account get-access-token"* ]]; then
    resource=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --resource) resource="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [ -z "$resource" ]; then
        echo "ERROR: --resource not specified" >&2
        exit 1
    fi

    # Normalize resource URL to filename: strip scheme and trailing slash
    filename=$(echo "$resource" | sed 's|https://||;s|/$||;s|/|_|g')
    tokenfile="/tmp/az-tokens/${filename}.json"

    if [ -f "$tokenfile" ]; then
        cat "$tokenfile"
        exit 0
    else
        echo "ERROR: No cached token for resource '$resource'. Re-run run-local.ps1 to refresh." >&2
        exit 1
    fi
else
    echo "ERROR: This is a lightweight az wrapper for Docker dev. Only 'account get-access-token' is supported." >&2
    echo "       If you need the full az CLI, install it with: curl -sL https://aka.ms/InstallAzureCLIDeb | bash" >&2
    exit 1
fi
