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

At the end of the preprovision hook, [resolve-container-image.ps1](Deployment/resolve-container-image.ps1)
queries the public `ghcr.io` registry for the latest digest of the `seekdavidlee/eklee-keyvault:latest`
tag and stores the full image reference (with `@sha256:...` digest) in the `CONTAINER_IMAGE` azd
environment variable. This ensures every `azd up` deploys the most recent container image by
forcing a new Container App revision whenever the digest changes.

The script also resolves Azure location for provisioning. It first checks `AZURE_LOCATION`, then
`infra.parameters.location`, then process environment `AZURE_LOCATION`. If none are set, it prompts
for a location and stores it in the azd environment for future runs.

If the app registration already exists, the script skips configuration and stores the existing
values. You can also run it manually:

```powershell
.\Deployment\setup-azd-app-registration.ps1 -Prefix "foobarkv1"
```

At the end of `azd up`, the `postdeploy` hook runs
[update-app-registration-redirect-uri.ps1](Deployment/update-app-registration-redirect-uri.ps1)
to add the deployed Container App URL to the app registration SPA redirect URIs.

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
- **Container App**: running the image resolved from `ghcr.io/seekdavidlee/eklee-keyvault` (pinned by digest)

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

Redirect URI update is automatic during `azd up`. The `postdeploy` hook appends the current
`containerAppUrl` to SPA redirect URIs while retaining existing redirect URIs.

`VITE_AZURE_AD_REDIRECT_URI` and `VITE_API_BASE_URL` are automatically set during provisioning
using the Container App's inferred FQDN.

## Custom Domain Name

To use a custom domain instead of the auto-generated Container App FQDN for
`VITE_AZURE_AD_REDIRECT_URI` and `VITE_API_BASE_URL`, follow the steps below.

### Step 1: Deploy without a custom domain

Run `azd up` first to provision the Container App and obtain its FQDN:

```bash
azd up
```

Note the `containerAppFqdn` output (e.g. `<prefix>-app.<hash>.<region>.azurecontainerapps.io`).

### Step 2: Configure DNS records

At your DNS provider, create the following records for your custom domain
(e.g. `pwm.example.com`):

| Type  | Host                      | Value                                            |
|-------|---------------------------|--------------------------------------------------|
| CNAME | `www` or `{subdomain}`    | `<containerAppFqdn>` (from step 1)              |
| TXT   | `asuid.{subdomain}`      | Domain verification token from the Azure portal  |

To find the TXT verification token, open the Container App in the Azure portal and
navigate to **Custom domains > Add custom domain**. The token is displayed in the
**Domain validation** section.

### Step 3: Set the environment variable and redeploy

```powershell
azd env set CUSTOM_DOMAIN_NAME "pwm.example.com"
azd up
```

This value is persisted in the azd environment (`.azure/<env-name>/.env`) so you only
need to set it once. All subsequent `azd up` runs will use it automatically.

When `CUSTOM_DOMAIN_NAME` is set:

- A managed TLS certificate is provisioned on the Container Apps Environment.
  Certificate provisioning may take several minutes while Azure validates DNS.
- The Container App's ingress is configured with a `customDomains` binding using that
  certificate, so the custom domain is preserved across deployments.
- `VITE_AZURE_AD_REDIRECT_URI` and `VITE_API_BASE_URL` are set to
  `https://<custom-domain>` instead of the default Container App FQDN.
- The `postdeploy` hook registers `https://<custom-domain>` as an additional SPA redirect
  URI on the app registration (alongside the Container App URL and `http://localhost:5173`).

When `CUSTOM_DOMAIN_NAME` is empty or not set, the default Container App FQDN behavior
is preserved and no managed certificate is deployed.

To remove a previously set custom domain, clear the variable:

```powershell
azd env set CUSTOM_DOMAIN_NAME ""
```

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
