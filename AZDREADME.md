---
title: Azure Developer CLI Deployment
description: Deploy Eklee KeyVault using the Azure Developer CLI and Bicep templates
post_title: Azure Developer CLI Deployment
author1: David Lee
post_slug: azure-developer-cli-deployment
featured_image: https://github.githubassets.com/images/modules/logos_page/GitHub-Mark.png
categories:
   - engineering
tags:
   - azure-developer-cli
   - azure-container-apps
   - entra-id
ai_note: Created with AI assistance and requires maintainer review
summary: Deploy Eklee KeyVault through Azure Developer CLI without provisioning a test service identity.
post_date: 2026-09-18
---

## Azure Developer CLI Deployment

This guide covers deploying the Eklee KeyVault application using the Azure Developer CLI (`azd`) with the
[azure.yaml](azure.yaml) configuration and [Deployment/azd.bicep](Deployment/azd.bicep) infrastructure template.

Use [Setup.ps1](Setup.ps1) for the first deployment of each target. It collects the target subscription,
location, prefix, and resource group name, stores those settings in the selected azd environment, and then
invokes `azd up`. The resource group name defaults to `<prefix>-rg` but can be changed during setup.

## Prerequisites

- [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) installed
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) installed and logged in (`az login`)
- An Azure subscription with permissions to create resources

## App Registration Setup

The `preprovision` hook in [azure.yaml](azure.yaml) automatically runs
[setup-azd-app-registration.ps1](Deployment/setup-azd-app-registration.ps1) before provisioning.
This script creates (or reuses) an Azure AD app registration named `<prefix>-app` and stores
`clientId` and `tenantId` in the azd environment.

During [Setup.ps1](Setup.ps1), [resolve-container-image.ps1](Deployment/resolve-container-image.ps1)
derives the public GHCR repository from this checkout's GitHub `origin`. It checks for the latest
published GitHub Release and offers its bare semantic version as the default. When the repository
has no published release, enter a stable version such as `1.0.0`. The script validates the selected
tag, resolves it to a `sha256` digest, and stores the immutable reference in `CONTAINER_IMAGE`
before `azd up` runs. It never accepts an arbitrary registry or repository image reference.

A direct `azd up` rerun of an environment configured by `Setup.ps1` reuses the stored digest. Run
`Setup.ps1` again when you intentionally want to select a different release image.

The script also resolves Azure location for provisioning. It first checks `AZURE_LOCATION`, then
`infra.parameters.location`, then process environment `AZURE_LOCATION`. If none are set, it prompts
for a location and stores it in the azd environment for future runs.

The customer application registration is for interactive users. It must contain the
`api://<clientId>` identifier URI, enabled `access_as_user` scope, Azure CLI
preauthorization, v2 access-token setting, and SPA redirect URIs. It must not
define the application-only `E2E.Tester` role or assign a service identity. This
keeps customer deployments isolated from the repository maintainer's hosted E2E
environment.

The maintainer-owned dev API registration used for repository-hosted E2E tests
is provisioned separately. A bare client-ID identifier URI or v1 access-token
policy is rejected for manual remediation. You can also run the script
manually:

```powershell
.\Deployment\setup-azd-app-registration.ps1 -Prefix "foobarkv1"
```

When using [Setup.ps1](Setup.ps1), do not configure an E2E role assignment for
a customer target profile. Customer `azd` deployments must not create, modify,
or assign a GitHub service identity. The maintainer-only dev E2E identity is
provisioned independently by [Setup-Dev.ps1](Setup-Dev.ps1) and is not an input
to customer setup.

At the end of `azd up`, the `postdeploy` hook runs
[update-app-registration-redirect-uri.ps1](Deployment/update-app-registration-redirect-uri.ps1)
to add the deployed Container App URL to the app registration SPA redirect URIs.

## Collected Parameters

`Setup.ps1` prompts for the following target settings and stores them before it invokes `azd up`:

| Parameter            | Description                                                                     | Example     |
|----------------------|---------------------------------------------------------------------------------|-------------|
| `location`           | Azure region used for deployment                                                | `centralus` |
| `prefix`             | Resource naming prefix (3-10 chars)                                             | `ekleekv`   |
| `resourceGroupName`  | Resource group to create or reuse                                               | `ekleekv-rg`|

Private networking is a `Y/N` choice that defaults to `N` and determines whether to deploy private
endpoints and disable Storage and Key Vault public access.

The release version defaults to the latest published release. When no release exists, enter a bare
stable version such as `1.0.0`.

`tenantId` and `clientId` are no longer prompted. The preprovision hook script populates both
values in the current azd environment by creating or reusing the app registration.

The app registration defaults to `<prefix>-app`. To use a different display name for a direct
`azd` deployment, set it in the active environment before running `azd up`:

```bash
azd env set APP_REGISTRATION_NAME "contoso-keyvault-app"
```

When `ENABLE_PRIVATE_NETWORKING` is not already set in the selected azd environment, the
preprovision hook asks `Enable private networking for Storage and Key Vault? (Y/N) [N]` and
stores the normalized result. `N` keeps the current public-network deployment. `Y` deploys the
VNet, private endpoints, private DNS links, and Container Apps VNet integration while disabling
public network access to the Storage Account and Key Vault.

To change an existing environment deliberately, set the value before running `azd up`:

```bash
azd env set ENABLE_PRIVATE_NETWORKING true
```

> [!IMPORTANT]
> Changing this value for an existing environment modifies network resources and access paths.
> Run a provisioning preview before applying the change.

## Custom Domain

If you have a custom domain for the Container App, set `CUSTOM_DOMAIN_NAME` in the azd
environment before running `azd up`:

```bash
azd env set CUSTOM_DOMAIN_NAME "mydomain.com"
```

The `postprovision` hook runs
[apply-custom-domain.ps1](Deployment/apply-custom-domain.ps1) automatically after
each provisioning to:

1. Add the custom hostname to the Container App
2. Bind a managed certificate (CNAME validation)
3. Update `VITE_AZURE_AD_REDIRECT_URI` and `VITE_API_BASE_URL` environment
   variables on the Container App to use the custom domain

The `postdeploy` hook also adds `https://<custom-domain>` to the app registration
SPA redirect URIs.

> [!NOTE]
> Your DNS must have a CNAME record pointing the custom domain to the Container
> App FQDN before the managed certificate can be provisioned.

## Provisioned Resources

The template deploys the following resources:

- **Log Analytics Workspace**: centralized logging for Container Apps
- **Storage Account**: with a `configs` blob container for application data
- **Key Vault**: RBAC-enabled secrets management
- **User-Assigned Managed Identity**: with two RBAC role assignments:
  - Key Vault Secrets Officer on the Key Vault
  - Storage Blob Data Contributor on the Storage Account
- **Container Apps Environment**: Consumption workload profile
- **Container App**: running the selected release image from this repository's GHCR package (pinned by digest)
- **Optional MISE sidecar**: a private token-validation container when explicitly enabled
- **Private networking when selected**: VNet integration for Container Apps, private endpoints
   for the Storage Account and Key Vault, and linked private DNS zones

## Authentication

`azd` maintains its own authentication session separate from the Azure CLI (`az`). Log in before
deploying:

```bash
azd auth login --use-device-code
```

The device code flow displays a URL and a code. Open the URL in your preferred browser or profile,
then enter the code to complete authentication. This is recommended over `azd auth login` because
the default browser login may open in an unintended browser profile.

## Optional MISE Sidecar

The default deployment does not use a Microsoft Entra ID Auth SDK (MISE) sidecar. It deploys the
public GHCR application image and uses the API's built-in Microsoft.Identity.Web JWT validation.
The preprovision hook persists `ENABLE_MISE_SIDECAR=false` when the setting is absent.

To opt in, set both of the following values before provisioning. The MISE container validates
bearer tokens on `http://localhost:5000/Validate`; it has no external ingress, while the application
continues to expose port 8080. The sidecar image is deliberately not embedded in source.

```bash
azd env set ENABLE_MISE_SIDECAR true
azd env set MISE_SIDECAR_IMAGE "<approved-registry>/<approved-image>@sha256:<digest>"
```

To return to the default path, set the flag to `false`; the image value is then ignored and no
sidecar container is deployed. The preprovision hook supplies a non-image placeholder when the
sidecar image value is absent, so azd can resolve its parameter file:

```bash
azd env set ENABLE_MISE_SIDECAR false
```

Before a separately authorized production deployment, complete the following preflight. When MISE
is enabled, the Bicep template rejects sidecar image values without `@sha256:`.

```bash
dotnet build Eklee.KeyVault.sln
dotnet test Eklee.KeyVault.sln
az bicep build --file Deployment/azd.bicep
azd provision --preview
```

After an authorized MISE-enabled deployment, verify that each revision contains both
`eklee-keyvault` and `mise-sidecar`, then collect sidecar telemetry from the Container Apps Log
Analytics workspace:

```bash
az containerapp revision list --name <container-app> --resource-group <resource-group> --query "[].properties.template.containers[].{name:name,image:image}" --output table
az monitor log-analytics query --workspace <workspace-id> --analytics-query "ContainerAppConsoleLogs_CL | where TimeGenerated > ago(30m) | where ContainerName_s == 'mise-sidecar' | project TimeGenerated, Log_s | order by TimeGenerated desc" --output table
```

Do not treat a successful provisioning operation as authentication evidence. Record the revision
container output and corresponding MISE telemetry with the production change approval.

## Deployment Steps

1. Configure the target and provision infrastructure:

   ```powershell
   .\Setup.ps1
   ```

   Select or create a target, then provide its resource group name and release image version when
   prompted. `Setup.ps1` checks the latest published release first, configures the azd environment,
   resolves the selected image to a digest, and invokes `azd up`. The first deployment also asks
   whether private networking is required and retains that choice in the azd environment.

   To rerun an already configured target without using the setup flow, select its environment and
   run `azd up`; it reuses the selected image digest. Do not use a bare `azd up` to initialize a
   new target because it does not collect the required resource group name or release image.

2. Note the outputs printed after deployment:

   ```text
   containerAppUrl = https://<prefix>-app.<region>.azurecontainerapps.io
   containerAppFqdn = <prefix>-app.<region>.azurecontainerapps.io
   ```

### Target-Catalog Deployment

Use the customer setup script when one repository is deployed to multiple tenants or subscriptions:

```powershell
.\Setup.ps1
```

The script reads and updates `$HOME\.eklee-keyvault\setup.json`. New targets
include an `Enable private networking (Y/N)` question. The answer is stored as
non-secret target metadata and set as `ENABLE_PRIVATE_NETWORKING` before `azd
up`. Existing targets are prompted once when selected and default to public
networking when no answer exists.

Set `appRegistrationName` in a target profile to choose the Microsoft Entra application display
name. It is set as `APP_REGISTRATION_NAME` before the preprovision hook looks up or creates the
application. Existing targets without this key are prompted once and default to `<prefix>-app`.

After selecting a target, the script checks for the latest published GitHub Release. Press Enter to
use that version, or enter a bare stable version such as `1.0.0`. If no release exists, a version is
required. The selected GHCR tag must resolve successfully before the script stores the digest and
continues to `azd up`.

### Maintainer Dev Setup

Repository maintainers deploy the hosted E2E target through a separate, single
profile and registration:

```powershell
.\Setup-Dev.ps1
```

`Setup-Dev.ps1` reads `$HOME\.eklee-keyvault\setup-dev.json`, runs `azd up` for
that one target, then provisions the isolated dev E2E identity. Its
`appRegistrationName` must differ from every customer registration in the same
Microsoft Entra tenant. The script rejects a duplicate name found in
`$HOME\.eklee-keyvault\setup.json` and must never be used for a customer or
production target. It derives the GitHub owner and repository from the local
`origin` remote; pass `-GitHubOrganization` and `-GitHubRepoName` together only
when the remote cannot be used.

## Post-Deployment Configuration

Redirect URI update is automatic during `azd up`. The `postdeploy` hook appends the current
`containerAppUrl` to SPA redirect URIs while retaining existing redirect URIs.

`VITE_AZURE_AD_REDIRECT_URI` and `VITE_API_BASE_URL` are automatically set during provisioning
using the Container App's inferred FQDN.

## Outputs Reference

| Output                          | Description                                        |
|---------------------------------|----------------------------------------------------|
| `storageAccountName`            | Name of the deployed Storage Account               |
| `keyVaultName`                  | Name of the deployed Key Vault                     |
| `keyVaultUri`                   | URI of the Key Vault                               |
| `containerAppEnvironmentName`   | Name of the Container Apps Environment             |
| `managedIdentityName`           | Name of the user-assigned managed identity         |
| `managedIdentityPrincipalId`    | Principal ID of the managed identity               |
| `managedIdentityClientId`       | Client ID of the managed identity                  |
| `containerAppName`              | Name of the Container App                          |
| `containerAppFqdn`              | FQDN of the Container App                          |
| `containerAppUrl`               | Full HTTPS URL of the Container App                |

## Tearing Down

To remove all provisioned resources:

```bash
azd down --purge
```

The `--purge` flag also purges soft-deleted Key Vault instances.

> [!IMPORTANT]
> `azd down` only removes Azure Resource Manager resources. The Entra ID app registration
> (`<prefix>-app`) created during provisioning is **not** deleted automatically. Remove it
> manually:
>
> ```powershell
> $appId = az ad app list --display-name "<prefix>-app" --query "[0].appId" -o tsv
> az ad app delete --id $appId
> ```

## Troubleshooting

If `azd up` fails in the `preprovision` hook with:

```text
Could not determine Azure location. Ensure the 'location' parameter is set.
```

set location in the current environment and rerun:

```bash
azd env config set infra.parameters.location centralus
azd env set AZURE_LOCATION centralus
azd up
```
