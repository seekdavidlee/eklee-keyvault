---
title: Direct User Scripts
description: Utilities intended to be run directly by developers or operators.
ms.date: 2026-09-15
ms.topic: reference
---

## Purpose

The `Scripts` folder contains utilities that developers or operators run directly
from a local terminal. These scripts support operational tasks that require an
interactive, already-authorized user identity.

Scripts in this folder are distinct from the [`Deployment`](../Deployment/)
folder, which contains infrastructure-as-code and CI/CD deployment helpers.

## Scripts

| Script | Purpose |
| --- | --- |
| [`Update-BranchRedirectUri.ps1`](Update-BranchRedirectUri.ps1) | Registers a deployed branch Container App URL in the Microsoft Entra SPA app registration and configures the Container App runtime redirect URI. |
| [`Invoke-HostedE2E.ps1`](Invoke-HostedE2E.ps1) | Runs local Playwright tests against a deployed Container App using the signed-in Azure CLI identity. |

## Update Branch Redirect URI

Run this script after the CI/CD workflow deploys a branch Container App. It
lists local azd environments and prompts for the environment to use:

```powershell
./Scripts/Update-BranchRedirectUri.ps1
```

The script reads `resourceGroupName` and `APP_CLIENT_ID` from the selected azd
environment and derives the branch Container App name from the checked-out Git
branch using the same convention as CI. Use `-EnvironmentName <name>` to avoid
the prompt. For a detached checkout or recovery scenario, pass
`-ResourceGroupName`, `-ContainerAppName`, and `-SpaAppClientId` explicitly.

Before running it:

1. Install the Azure CLI.
2. Sign in with `az login` and select the subscription containing the Container App.
3. Confirm that your user can update the Container App and the Microsoft Entra SPA app registration.

The script uses the signed-in Azure CLI user identity. It does not require GitHub
Actions to have Microsoft Graph application-management permissions and does not
store or print access tokens.

## Hosted E2E Tests

Run the local Playwright authentication test against a deployed environment:

```powershell
./Scripts/Invoke-HostedE2E.ps1 -EnvironmentName dev
```

The script reads the resource group, Container App name, API client ID, tenant,
and subscription from the selected azd environment. It resolves the live HTTPS
ingress URL, waits for `/healthz`, acquires an API token through the signed-in
Azure CLI identity, and runs `login.spec.ts`.

Use `-Filter secrets-crud` for the Admin CRUD test or `-Headed` to show the
browser. Use `-NoDeps` when the UI dependencies and Chromium are already
installed.
