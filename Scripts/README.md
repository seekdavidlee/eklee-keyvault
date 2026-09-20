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
| [`copy-keyvault-secrets.ps1`](copy-keyvault-secrets.ps1) | Copies enabled secrets from an Azure Key Vault into the Eklee KeyVault API without overwriting existing secrets. |
| [`../Setup-Dev.ps1`](../Setup-Dev.ps1) | Deploys the single maintainer dev profile with `azd` and configures its dedicated API registration and Reader-scoped GitHub OIDC E2E identity. |
| [`Invoke-HostedE2E.ps1`](Invoke-HostedE2E.ps1) | Updates the permanent branch Container App from the checked-out feature or bugfix commit, then runs local Playwright tests. |
| [`setup-gh-deploy.ps1`](setup-gh-deploy.ps1) | Creates the GitHub Actions OIDC deployment identity, resource groups, role assignments, and environment variables. |
| [`Tag-ExistingStackResources.ps1`](Tag-ExistingStackResources.ps1) | Reports or applies stable `resource-id` tags to an existing Eklee KeyVault stack, including the three permanent development Container App targets. |

## Container App Resource Tags

The maintainer development environment can contain three permanent Container
Apps: the main/dev app, its `-release` app, and its `-branch` app. Each uses a
target-specific `resource-id` tag so `azd` can safely adopt it:

- `app-container-app` for the main/dev app
- `app-container-app-release`
- `app-container-app-branch`

`Deployment/resolve-resource-names.ps1` also recognizes the legacy shared
`app-container-app` tag only when it identifies either one main/dev app or the
exact three-app target set. It rejects partial, extra, duplicate, or wrong-type
matches rather than selecting an app heuristically.

For a valid legacy set, the next `azd` deployment retains the resolved names,
keeps `app-container-app` on the main/dev app, and replaces the release and
branch tags with their target-specific values.
Review the planned changes before applying them:

```powershell
azd provision --preview
azd up
```

For a pre-existing three-app stack, preview the explicit tag migration before
applying it:

```powershell
./Scripts/Tag-ExistingStackResources.ps1 -ResourceGroupName <resource-group>
./Scripts/Tag-ExistingStackResources.ps1 -ResourceGroupName <resource-group> -Apply
```

## Hosted E2E Tests

Run the local Playwright authentication test from a checked-out feature or
bugfix branch after its CI image has been published:

```powershell
./Scripts/Invoke-HostedE2E.ps1 -Current
```

The command reads the single maintainer profile at
`$HOME/.eklee-keyvault/setup-dev.json`, which is configured by
[`../Setup-Dev.ps1`](../Setup-Dev.ps1). Its `environmentName` identifies the
azd environment that supplies the resource group, API client ID, tenant, and
subscription. It verifies the approved GitHub origin and active subscription,
resolves the CI image tagged for the exact checked-out commit to an immutable
digest, updates only the permanent branch app, waits for `/healthz`, acquires
an API token through the signed-in Azure CLI identity, and runs `login.spec.ts`.
It rejects detached checkouts, `main`, and `release/*` before any Azure update.
The permanent redirects are registered by `Setup-Dev.ps1`; this command never
modifies Microsoft Entra redirect URIs.

Use `-Filter secrets-crud` for the Admin CRUD test or `-Headed` to show the
browser. Use `-NoDeps` when the UI dependencies and Chromium are already
installed.

## Dev E2E Identity

Use [`../Setup-Dev.ps1`](../Setup-Dev.ps1) only for the repository maintainer's
isolated dev environment. It reads one target from
`$HOME/.eklee-keyvault/setup-dev.json`, deploys it with `azd`, and requires its
`appRegistrationName` to differ from customer registrations in the same tenant.
On the first run after the permanent Container App targets are introduced, it
prompts for and persists the HTTPS hostnames for the main/dev, release, and
branch apps as `customDevDomainName`, `customReleaseDomainName`, and
`customBranchDomainName`. These fields are maintainer-only and are not part of
the customer `Setup.ps1` profile contract. It also records the approved GitHub
repository used by the local branch deployment command.
Supplying both `-LegacyApiClientId` and `-LegacyCallerAppId` inspects that exact
legacy role assignment without changing it. Removal requires
`-RemoveLegacyE2ERole` and `-ConfirmLegacyRemoval` in addition to both IDs.
