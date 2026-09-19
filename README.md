# Introduction

The solution uses a React (Vite) single-page application frontend with an ASP.NET backend API, both packaged into a single Docker container and deployed to Azure Container Apps. Azure Storage is used to store user-access configuration, and Azure Key Vault stores the secrets. The ASP.NET backend authenticates users via Microsoft Entra ID and accesses Key Vault and Storage using a user-assigned managed identity.

The Bicep templates ensure when creating Azure Key Vault, we are using Azure role-based access control for the permission model.

## Build Status

![Build status](https://github.com/seekdavidlee/Eklee-KeyVault/actions/workflows/cicd.yml/badge.svg)
![Infra](https://github.com/seekdavidlee/Eklee-KeyVault/actions/workflows/deploy-infra.yml/badge.svg)

## Cost

The primary costs are Azure Container Apps, Azure Storage, and Azure Key Vault. The Container App is configured to scale to zero when idle, so you are only charged for compute when the app is actively handling requests. Expect a cold-start delay of a few seconds when the app scales up from zero. Overall cost should be minimal for light usage.

## Prerequisites

- [Node.js](https://nodejs.org/) (LTS recommended)
- [.NET SDK](https://dotnet.microsoft.com/download)
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) (logged in with `az login`)
- [GitHub CLI](https://cli.github.com/) (authenticated with `gh auth login`)

## Local Development

### App Registration Setup

Run the setup script to create (or look up) the Azure AD app registration and update both the API `appsettings.json` and the UI `.env` file automatically:

```powershell
cd Eklee.KeyVault.Api
.\setup-app-registration.ps1
```

### Running the React (Vite) Frontend

1. Navigate to the UI project directory:

```sh
cd Eklee.KeyVault.UI
```

1. Create a `.env` file with the required Azure AD configuration (if not already created by the setup script):

```txt
VITE_AZURE_AD_CLIENT_ID=<your-client-id>
VITE_AZURE_AD_AUTHORITY=https://login.microsoftonline.com/<your-tenant-id>
VITE_AZURE_AD_REDIRECT_URI=http://localhost:5173
```

1. Install dependencies and start the dev server:

```sh
npm install
npm run dev
```

The Vite dev server starts on **port 5173** and proxies `/api` requests to `http://localhost:5000` (the ASP.NET backend).

#### Available npm Scripts

| Command           | Description                              |
| ----------------- | ---------------------------------------- |
| `npm run dev`     | Start dev server with hot reload         |
| `npm run build`   | TypeScript compile + Vite production build |
| `npm run preview` | Preview the production build locally     |
| `npm run lint`    | Run ESLint                               |

### Running the ASP.NET Backend

Start the API so the frontend proxy works:

```sh
cd Eklee.KeyVault.Api
dotnet run
```

The API listens on `http://localhost:5000` by default.

### Updating NuGet Packages

Run the update script from the repo root to update all NuGet packages in the API project to their latest stable versions:

```powershell
.\UpdateNuget.ps1
```

To target a different project file:

```powershell
.\UpdateNuget.ps1 -ProjectPath "path/to/Project.csproj"
```

## Automated Deployment

1. Fork this repo.
1. Run `Scripts/setup-gh-deploy.ps1` to create the deployment service principal, resource groups, RBAC assignments, and set the deployment-related GitHub environment variables (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `RESOURCE_GROUP`).
1. Run `Eklee.KeyVault.Api/setup-app-registration.ps1` with the `-GitHubOrganization`, `-GitHubRepoName`, and `-AzureAdRedirectUriDev` parameters to create the maintainer dev app registration and set the SPA-related GitHub environment variables (`VITE_AZURE_AD_CLIENT_ID`, `VITE_AZURE_AD_AUTHORITY`, `VITE_AZURE_AD_REDIRECT_URI`). Customer production registrations are configured by the customer deployment process.

1. Deploy infrastructure by running `gh workflow run deploy-infra.yml -f environment=dev`

1. Run `Scripts/assign-mi-rbac.ps1` to assign RBAC roles to the managed identity.
1. Push to a non-`main` branch to trigger the **CI/CD** workflow (`cicd.yml`), which builds and deploys a temporary dev Container App. A push to `main` builds and publishes the `latest` image and a short-SHA image tag without deploying to Azure; the customer deployment process performs production updates.
1. After CI deploys a branch Container App, run
  `./Scripts/Update-BranchRedirectUri.ps1` as a user who can update the
  resource group and the SPA app registration.

  The script prompts for an azd environment, reads its resource group and SPA
  client ID, and derives the branch Container App name from the checked-out
  Git branch. It discovers the deployed FQDN, adds its URL to the SPA redirect
  URI list without removing existing entries, and configures the Container App
  to use that URL at runtime. Pass `-EnvironmentName <name>` to avoid the
  prompt, or pass `-ResourceGroupName`, `-ContainerAppName`, and
  `-SpaAppClientId` explicitly for recovery scenarios.

1. Perform user role assignments per [Post Deployment RBAC](#post-deployment-rbac).

When a same-repository pull request is merged into a `release/*` branch, the cleanup workflow deletes the matching temporary Container App and `branch-<normalized-branch>` GHCR image. When a release branch is merged into `main`, it deletes the release Container App and `release-<normalized-version>` GHCR image. The cleanup workflow does not delete the long-lived `main` Container App or `main` image tags.

The two setup scripts configure the following GitHub environment variables in `dev`:

| Variable | Set by |
| --- | --- |
| `AZURE_CLIENT_ID` | `setup-gh-deploy.ps1` |
| `AZURE_TENANT_ID` | `setup-gh-deploy.ps1` |
| `AZURE_SUBSCRIPTION_ID` | `setup-gh-deploy.ps1` |
| `RESOURCE_GROUP` | `setup-gh-deploy.ps1` |
| `VITE_AZURE_AD_CLIENT_ID` | `setup-app-registration.ps1` |
| `VITE_AZURE_AD_AUTHORITY` | `setup-app-registration.ps1` |
| `VITE_AZURE_AD_REDIRECT_URI` | `setup-app-registration.ps1` |

## Custom Domain

Optionally, you can configure a custom domain for your Azure Container App. After the first deployment, add a CNAME record pointing your subdomain to the Container App's FQDN. Then configure the custom domain in the Azure portal under your Container App's settings. You will also need to update the SPA redirect URI in your Entra ID app registration to match the custom domain.

## Deploy from GitHub Container Registry

You can create an Azure Container App directly from the public GHCR image without
building the Docker image yourself. This is useful for quick deployments or
deployments that use the public GHCR release image.

The public image is available at:

```text
ghcr.io/seekdavidlee/eklee-keyvault:latest
```

### Prerequisites

Before you begin, ensure you have the following Azure resources already provisioned
(for example, via the Bicep templates in the `Deployment/` folder):

- A resource group
- A Container Apps environment
- A user-assigned managed identity (with Key Vault and Storage RBAC roles assigned)
- An Azure Key Vault
- An Azure Storage account
- An Entra ID app registration (see [App Registration Setup](#app-registration-setup))

### Create the Container App

```sh
# Set your variables
RESOURCE_GROUP="<resource-group>"
ENV_NAME="<container-apps-environment-name>"
IDENTITY_ID="<managed-identity-resource-id>"
IDENTITY_CLIENT_ID="<managed-identity-client-id>"
KEYVAULT_URI="https://<your-keyvault-name>.vault.azure.net/"
STORAGE_BLOB_URI="https://<your-storage-account>.blob.core.windows.net/"
TENANT_ID="<your-tenant-id>"
APP_CLIENT_ID="<your-app-registration-client-id>"

az containerapp create \
  --name eklee-keyvault \
  --resource-group "$RESOURCE_GROUP" \
  --environment "$ENV_NAME" \
  --image ghcr.io/seekdavidlee/eklee-keyvault:latest \
  --target-port 8080 \
  --ingress external \
  --user-assigned "$IDENTITY_ID" \
  --cpu 0.5 \
  --memory 1.0Gi \
  --min-replicas 0 \
  --max-replicas 1 \
  --env-vars \
    AZURE_CLIENT_ID="$IDENTITY_CLIENT_ID" \
    StorageUri="$STORAGE_BLOB_URI" \
    StorageContainerName=configs \
    KeyVaultUri="$KEYVAULT_URI" \
    AuthenticationMode=mi \
    AzureAd__Instance=https://login.microsoftonline.com/ \
    AzureAd__TenantId="$TENANT_ID" \
    AzureAd__ClientId="$APP_CLIENT_ID" \
    AzureAd__Audience="api://$APP_CLIENT_ID" \
    VITE_AZURE_AD_CLIENT_ID="$APP_CLIENT_ID" \
    VITE_AZURE_AD_AUTHORITY="https://login.microsoftonline.com/$TENANT_ID" \
    VITE_AZURE_AD_REDIRECT_URI="https://<your-container-app-fqdn>"
```

Because the GHCR package is public, no `--registry-server` or `--registry-identity`
flags are required — Azure Container Apps pulls the image anonymously.

After the container app is created, retrieve the FQDN and register it as a SPA
redirect URI in your Entra ID app registration:

```sh
FQDN=$(az containerapp show \
  --name eklee-keyvault \
  --resource-group "$RESOURCE_GROUP" \
  --query "properties.configuration.ingress.fqdn" -o tsv)

echo "App URL: https://$FQDN"

az ad app update --id "$APP_CLIENT_ID" \
  --spa-redirect-uris "https://$FQDN"
```

### Update an Existing Container App

To update the container app to the latest image:

```sh
az containerapp update \
  --name eklee-keyvault \
  --resource-group "$RESOURCE_GROUP" \
  --image ghcr.io/seekdavidlee/eklee-keyvault:latest
```

## Post Deployment RBAC

There are a few important roles to note:

- **Key Vault Secrets User** — "Read secret contents." Assigned to the managed identity by `assign-mi-rbac.ps1`.
- **Storage Blob Data Contributor** — Allows the managed identity to read/write user-access config in blob storage.

The managed identity RBAC is handled by the script in the Deployment folder:

```powershell
cd Deployment
..\Scripts\assign-mi-rbac.ps1 -ResourceGroup <resource-group-name>
```

See [Deployment/README.md](Deployment/README.md) for detailed instructions.
