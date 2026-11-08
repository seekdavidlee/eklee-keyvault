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
| [`../Setup-Dev.ps1`](../Setup-Dev.ps1) | Deploys the single maintainer dev profile with `azd` and configures its dedicated API registration and Reader-scoped GitHub OIDC E2E identity. |
| [`setup-gh-deploy.ps1`](setup-gh-deploy.ps1) | Creates the GitHub Actions OIDC deployment identity, resource groups, role assignments, and environment variables. |

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

Use the same provisioning preview for a pre-existing valid three-app stack.
If resource-name resolution rejects the existing tags, resolve the reported
ambiguity before provisioning; do not select or retag an app heuristically.

## Hosted E2E Tests

Push changes matching the path filters in the
[CI/CD workflow](../.github/workflows/cicd.yml) to publish an immutable image,
deploy it, and run hosted Playwright tests. `main` uses the permanent main/dev
app, `release/*` uses the release app, and other branches use the shared branch
app. Documentation-only pushes do not trigger this workflow.

Review the corresponding GitHub Actions run for test results and Playwright
artifacts. A later qualifying branch push can replace the shared branch app's
deployed image. Permanent redirects are registered by
[`../Setup-Dev.ps1`](../Setup-Dev.ps1).

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
repository used by the maintainer setup process.
Supplying both `-LegacyApiClientId` and `-LegacyCallerAppId` inspects that exact
legacy role assignment without changing it. Removal requires
`-RemoveLegacyE2ERole` and `-ConfirmLegacyRemoval` in addition to both IDs.
