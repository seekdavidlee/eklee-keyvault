# Introduction

The solution uses a React (Vite) single-page application frontend with an ASP.NET backend API, both packaged into a single Docker container and deployed to Azure Container Apps. Azure Storage is used to store user-access configuration, and Azure Key Vault stores the secrets. The ASP.NET backend authenticates users via Microsoft Entra ID and accesses Key Vault and Storage using a user-assigned managed identity.

The Bicep templates ensure when creating Azure Key Vault, we are using Azure role-based access control for the permission model.

## Build Status

![Build status](https://github.com/seekdavidlee/Eklee-KeyVault/actions/workflows/cicd.yml/badge.svg)
![Infra](https://github.com/seekdavidlee/Eklee-KeyVault/actions/workflows/deploy-infra.yml/badge.svg)

### Cost

The primary costs are Azure Container Apps, Azure Storage, and Azure Key Vault. The Container App is configured to scale to zero when idle, so you are only charged for compute when the app is actively handling requests. Expect a cold-start delay of a few seconds when the app scales up from zero. Overall cost should be minimal for light usage.

## Prerequisites

- [Node.js](https://nodejs.org/) (LTS recommended)
- [.NET SDK](https://dotnet.microsoft.com/download)
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) (logged in with `az login`)
- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (for local Docker workflow)

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

### Running Locally with Docker

The `run-local.ps1` script builds and runs the full application (API + UI) in a single Docker container using your local Azure CLI credentials.

#### How It Works

1. Reads `ClientId` and `TenantId` from `Eklee.KeyVault.Api/appsettings.json`
2. Builds the Docker image with `--target local` (frontend + backend, no Azure CLI installed)
3. Pre-fetches access tokens for Key Vault and Storage from your host Azure CLI session
4. Mounts the token files read-only into the container
5. A lightweight `az` wrapper inside the container serves tokens to `AzureCliCredential`

#### Usage

```powershell
# Build and run (foreground with logs)
.\run-local.ps1

# Build and run in background
.\run-local.ps1 -Detached

# Skip rebuild, just refresh tokens and run
.\run-local.ps1 -NoBuild

# Custom port
.\run-local.ps1 -Port 9090
```

The container serves both the API and UI on the same port. After startup:

| Endpoint | URL |
| --- | --- |
| Application | `http://localhost:8080` |
| Swagger UI | `http://localhost:8080/swagger` |
| Health check | `http://localhost:8080/healthz` |

#### SPA Redirect URI

Ensure `http://localhost:8080` is registered as a SPA redirect URI in your Entra ID app registration. If not, run:

```powershell
az ad app update --id <your-client-id> --spa-redirect-uris http://localhost:8080 http://localhost:5173
```

#### Token Expiry

Pre-fetched tokens expire after approximately 1 hour. Re-run `.\run-local.ps1` (with or without `-NoBuild`) to refresh them.

#### Parameters

| Parameter | Default | Description |
| --- | --- | --- |
| `-Port` | `8080` | Host port mapped to the container |
| `-ImageName` | `eklee-keyvault-local` | Docker image name |
| `-Detached` | `$false` | Run container in background |
| `-NoBuild` | `$false` | Skip Docker build, use existing image |
| `-RedirectUri` | `http://localhost:<Port>` | MSAL redirect URI baked into the SPA |

## Automated Deployment

1. Fork this repo.
1. Create a single-tenant app registration in Entra ID (e.g. `Eklee.KeyVaultv2`). Run `setup-app-registration.ps1` or configure manually.
1. In API permissions, add `Azure Key Vault` > `user_impersonation` (Delegated) and grant admin consent.
1. Under GitHub repo settings, create environments `dev` and/or `prod` with the following variables:

| Variable | Description |
| --- | --- |
| `AZURE_CLIENT_ID` | Service principal client ID for OIDC login |
| `AZURE_TENANT_ID` | Azure AD tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Target subscription ID |
| `ACR_NAME` | Azure Container Registry name (without `.azurecr.io`) |
| `RESOURCE_GROUP` | Resource group for Container Apps deployment |
| `VITE_AZURE_AD_CLIENT_ID` | App registration client ID |
| `VITE_AZURE_AD_AUTHORITY` | `https://login.microsoftonline.com/<tenant-id>` |
| `VITE_AZURE_AD_REDIRECT_URI` | Redirect URI for the deployed app |

1. Deploy infrastructure by running the **Deploy Infrastructure** workflow (`deploy-infra.yml`).
1. Run `Deployment/assign-mi-rbac.ps1` to assign RBAC roles to the managed identity.
1. Push to any branch to trigger the **CI/CD** workflow (`cicd.yml`), which builds and deploys the container.
1. Register the Container App URL as a SPA redirect URI in the Entra ID app registration.
1. Perform user role assignments per [Post Deployment RBAC](#post-deployment-rbac).

## Custom Domain

Optionally, you can configure a custom domain for your Azure Container App. After the first deployment, add a CNAME record pointing your subdomain to the Container App's FQDN. Then configure the custom domain in the Azure portal under your Container App's settings. You will also need to update the SPA redirect URI in your Entra ID app registration to match the custom domain.

## Post Deployment RBAC

There are a few important roles to note:

- **Key Vault Secrets User** — "Read secret contents." Assigned to the managed identity by `assign-mi-rbac.ps1`.
- **Storage Blob Data Contributor** — Allows the managed identity to read/write user-access config in blob storage.
- **AcrPull** — Allows the managed identity to pull container images from Azure Container Registry.

For end-user access, assign users or Entra ID groups the appropriate roles on the Key Vault:

| Role | Purpose |
| --- | --- |
| **Key Vault Reader** | Read metadata of key vaults, certificates, keys, and secrets |
| **Key Vault Secrets User** | Read secret contents |

As a best practice, create Entra ID groups (e.g. `app-keyvault Secrets Admins` and `app-keyvault Secrets Users`) and assign the roles to those groups. Then add users to the appropriate group for access.

The managed identity RBAC is handled by the script in the Deployment folder:

```powershell
cd Deployment
.\assign-mi-rbac.ps1 -ResourceGroup <resource-group-name> -ContainerRegistryResourceGroup <acr-resource-group>
```

See [Deployment/README.md](Deployment/README.md) for detailed instructions.
