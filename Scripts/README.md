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
| [`assign-mi-rbac.ps1`](assign-mi-rbac.ps1) | Assigns the deployed managed identity its Key Vault and Storage RBAC roles. |
| [`copy-keyvault-secrets.ps1`](copy-keyvault-secrets.ps1) | Copies enabled secrets from an Azure Key Vault into the Eklee KeyVault API without overwriting existing secrets. |
| [`../Setup-Dev.ps1`](../Setup-Dev.ps1) | Deploys the single maintainer dev profile with `azd` and configures its dedicated API registration and Reader-scoped GitHub OIDC E2E identity. |
| [`Update-BranchRedirectUri.ps1`](Update-BranchRedirectUri.ps1) | Registers a deployed branch Container App URL in the Microsoft Entra SPA app registration and configures the Container App runtime redirect URI. |
| [`Invoke-HostedE2E.ps1`](Invoke-HostedE2E.ps1) | Runs local Playwright tests against the checked-out branch or release Container App using the signed-in Azure CLI identity. |
| [`setup-gh-deploy.ps1`](setup-gh-deploy.ps1) | Creates the GitHub Actions OIDC deployment identity, resource groups, role assignments, and environment variables. |
| [`Tag-ExistingStackResources.ps1`](Tag-ExistingStackResources.ps1) | Reports or applies stable `resource-id` tags to an existing Eklee KeyVault stack. |

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
./Scripts/Invoke-HostedE2E.ps1 -Current
```

To test the checked-out release branch, use:

```powershell
./Scripts/Invoke-HostedE2E.ps1 -Release
```

Both commands read the single maintainer profile at
`$HOME/.eklee-keyvault/setup-dev.json`, which is configured by
[`../Setup-Dev.ps1`](../Setup-Dev.ps1). Its `environmentName` identifies the
azd environment that supplies the resource group, API client ID, tenant, and
subscription. The script derives the deployed Container App name from the
checked-out branch using the same convention as CI, resolves its live HTTPS
ingress URL, waits for `/healthz`, acquires an API token through the signed-in
Azure CLI identity, and runs `login.spec.ts`.

`-Current` accepts a checked-out non-`main` branch. `-Release` requires a
checked-out `release/MAJOR.MINOR.PATCH` branch. Detached checkouts and `main`
are rejected before the script contacts Azure.

Use `-Filter secrets-crud` for the Admin CRUD test or `-Headed` to show the
browser. Use `-NoDeps` when the UI dependencies and Chromium are already
installed.

## Dev E2E Identity

Use [`../Setup-Dev.ps1`](../Setup-Dev.ps1) only for the repository maintainer's
isolated dev environment. It reads one target from
`$HOME/.eklee-keyvault/setup-dev.json`, deploys it with `azd`, and requires its
`appRegistrationName` to differ from customer registrations in the same tenant.
Supplying both `-LegacyApiClientId` and `-LegacyCallerAppId` inspects that exact
legacy role assignment without changing it. Removal requires
`-RemoveLegacyE2ERole` and `-ConfirmLegacyRemoval` in addition to both IDs.
