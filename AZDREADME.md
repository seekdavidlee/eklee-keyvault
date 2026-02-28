# Azure Developer CLI (azd) Deployment

This guide covers deploying the Eklee KeyVault application using the Azure Developer CLI (`azd`) with the
[azure.yaml](azure.yaml) configuration and [Deployment/azd.bicep](Deployment/azd.bicep) infrastructure template.

## Prerequisites

- [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) installed
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) installed and logged in (`az login`)
- An Azure subscription with permissions to create resources

## App Registration Setup

The `preprovision` hook in [azure.yaml](azure.yaml) automatically runs
[setup-azd-app-registration.ps1](Deployment/setup-azd-app-registration.ps1) before provisioning.
This script creates (or reuses) an Azure AD app registration named `<prefix>-app` and stores
`clientId` and `tenantId` in the azd environment.

The script also resolves Azure location for provisioning. It first checks `AZURE_LOCATION`, then
`infra.parameters.location`, then process environment `AZURE_LOCATION`. If none are set, it prompts
for a location and stores it in the azd environment for future runs.

If the app registration already exists, the script skips configuration and stores the existing
values. You can also run it manually:

```powershell
.\Deployment\setup-azd-app-registration.ps1 -Prefix "foobarkv1"
```

## Collected Parameters

`azd` prompts for the following parameters during provisioning (unless already stored):

| Parameter   | Description                                            | Example           |
|-------------|--------------------------------------------------------|-------------------|
| `location`  | Azure region used for deployment                       | `centralus`       |
| `prefix`    | Resource naming prefix (3-10 chars)                    | `ekleekv`         |

`tenantId` and `clientId` are no longer prompted. The preprovision hook script populates both
values in the current azd environment by creating or reusing the app registration.

## Provisioned Resources

The template deploys the following resources (no private networking, no ACR):

- **Log Analytics Workspace**: centralized logging for Container Apps
- **Storage Account**: with a `configs` blob container for application data
- **Key Vault**: RBAC-enabled secrets management
- **User-Assigned Managed Identity**: with two RBAC role assignments:
  - Key Vault Secrets Officer on the Key Vault
  - Storage Blob Data Contributor on the Storage Account
- **Container Apps Environment**: Consumption workload profile
- **Container App**: running `ghcr.io/seekdavidlee/eklee-keyvault:latest`

## Authentication

`azd` maintains its own authentication session separate from the Azure CLI (`az`). Log in before
deploying:

```bash
azd auth login --use-device-code
```

The device code flow displays a URL and a code. Open the URL in your preferred browser or profile,
then enter the code to complete authentication. This is recommended over `azd auth login` because
the default browser login may open in an unintended browser profile.

## Deployment Steps

1. Provision infrastructure and deploy:

   ```bash
   azd up
   ```

   Select an environment name when prompted (for example, `dev`), then enter values for `location`
   and `prefix`.

2. Note the outputs printed after deployment:

   ```text
   containerAppUrl = https://<prefix>-app.<region>.azurecontainerapps.io
   containerAppFqdn = <prefix>-app.<region>.azurecontainerapps.io
   ```

## Post-Deployment Configuration

After the first deployment, one manual step is required:

1. **Update the redirect URI**: Add the `containerAppUrl` output value as a redirect URI in your
   Azure AD app registration under **Authentication > Single-page application**.

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
