---
title: Eklee KeyVault
description: Development, deployment, and category-first secret management
post_title: Eklee KeyVault
author1: David Lee
post_slug: eklee-keyvault
featured_image: https://github.githubassets.com/images/modules/logos_page/GitHub-Mark.png
categories:
  - engineering
tags:
  - keyvault
  - development
ai_note: Updated with AI assistance and requires maintainer review
summary: Setup and operations for the KeyVault client, including shared categories and startup migration.
post_date: 2026-11-01
---

## Introduction

The solution uses a React (Vite) frontend with an ASP.NET backend API, packaged
into one Docker container and deployed to Azure Container Apps. Azure Storage
stores user-access configuration and shared category/display metadata. Azure Key
Vault stores secret values. The backend authenticates users via Microsoft Entra
ID and accesses Key Vault and Storage using a user-assigned managed identity.

The Bicep templates ensure when creating Azure Key Vault, we are using Azure role-based access control for the permission model.

## Categories and Secrets

The dashboard opens with shared categories. Select one to view only its secrets;
use **Back to categories** to switch. Empty categories remain visible. Categories
organize secrets but do not grant access or introduce new authorization rules.

Admin users can open **Category Management** to create, rename, or delete a
category. Names are trimmed, must contain 1 to 30 characters, and must be unique
without regard to case. Exactly 30 characters and case-only renames are allowed.
The internally designated default category can be renamed, but not deleted.
Nonempty categories cannot be deleted. Deleting an empty category never deletes
or reassigns secrets.

**Create Secret** requires a category, initially selected from the current view.
Existing value updates, secret generation, reveal/copy, display-name editing, and
soft deletion remain available under the existing roles. Moving an existing
secret to another category is not supported. User-role accounts can browse
categories and read secrets, but cannot manage categories or modify secrets.

### API Contracts

| Endpoint | Role | Contract |
| --- | --- | --- |
| `GET /api/categories` | Admin or User | Shared category IDs, names, and `isDefault` |
| `POST /api/categories` | Admin | `{ "name": "Finance" }`; returns the new category |
| `PUT /api/categories/{id}` | Admin | Renames using `{ "name": "Finance" }`, preserving identity |
| `DELETE /api/categories/{id}` | Admin | Deletes only an empty, nondefault category |
| `GET /api/secrets?categoryId={id}` | Admin or User | Only secrets associated with that category; unknown ID returns 404 |
| `PUT /api/secrets/{name}` | Admin | New secrets require `{ "value": "...", "categoryId": "..." }` |

Existing secret value updates can omit `categoryId`; supplying another category
returns 409 rather than moving the secret. Invalid names or creation categories
return 400. Category uniqueness, nonempty/default deletion, and exhausted
concurrent-write retries return actionable 409 problem details.

`GET /api/metadata` returns the complete metadata inventory and its ETag. Its
Admin-only PUT saves display-name changes with that `If-Match` ETag; it rejects
inventory or association changes. Do not submit just a filtered category's
rows. Preserve all categories and associations in the full document. Concurrent
writes return 409; reload before retrying.

### Startup Migration

Categories and associations are persisted together in `secrets-meta.json` in
the configured Storage container, using blob ETags for conditional writes.
Startup creates one internally designated default category, initially named
`Default`, and associates every uncategorized Key Vault secret with it. Secrets
without display metadata receive an entry using their Key Vault name. Existing
display names and category associations are preserved; values and user-access
permissions are not changed.

The persisted default ID and designation survive renaming. Later startups do not
recreate a category literally named `Default`, duplicate the default, or rewrite
already categorized metadata. Interrupted migration can be retried by restarting
the API; conflicting writes reload and revalidate the metadata, with at most five
attempts per operation.

- Before upgrading, back up the metadata blob and stop older API versions that
  share it. Older versions can overwrite the new category fields.
- The configured API identity must be able to list Key Vault secrets and read
  and write the metadata blob. Existing Key Vault Secrets Officer and Storage
  Blob Data Contributor assignments provide these operations; local development
  uses the configured Azure CLI identity instead.
- Migration completes before requests are served. If permissions, connectivity,
  or persistent write conflicts prevent it, startup fails. Correct the cause
  and restart; do not remove category fields to bypass the failure.
- New-secret association is reserved before its value is written, preventing
  concurrent category deletion. A per-secret blob lease covers both the value
  operation and association cleanup across API replicas; a competing set/delete
  returns 409 without modifying either. If the Key Vault write fails, retry
  creation in the same category, or delete that name to clear the reservation.
- If deletion reports a metadata conflict, retry deletion of the same name.
  A 404 on that retry can still mean the absent secret's association was cleaned
  up. Category deletion never performs this cleanup on your behalf.

Operation locks are empty blobs under `secret-operation-locks/` in the same
configured container. Their names are the uppercase SHA-256 hex digest of the
UTF-8 uppercase-invariant secret name, followed by `.lock`. Unleased lock blobs
are retained for reuse; they contain no secret values. Storage Blob Data
Contributor also permits lease operations.

Leases have infinite duration and are released when the request finishes. A
process crash or failed release leaves a fail-closed lock on that name; it does
not block browsing or startup migration. Before recovering it, stop **every API
replica** sharing the metadata and ensure no earlier value request can still
complete. In the Storage portal, break the affected lock blob's lease, then
restart and retry creation/deletion in its original category. Do not break a
live request's lease or implement timed automatic expiry: an earlier value
write could otherwise complete after its association was removed.

## Build Status

![Build status](https://github.com/seekdavidlee/Eklee-KeyVault/actions/workflows/cicd.yml/badge.svg)

## Cost

The primary costs are Azure Container Apps, Azure Storage, and Azure Key Vault. The Container App is configured to scale to zero when idle, so you are only charged for compute when the app is actively handling requests. Expect a cold-start delay of a few seconds when the app scales up from zero. Overall cost should be minimal for light usage.

## Prerequisites

- [Node.js](https://nodejs.org/) (LTS recommended)
- [.NET SDK](https://dotnet.microsoft.com/download)
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) (logged in with `az login`)
- [GitHub CLI](https://cli.github.com/) (optional; needed only for GitHub workflow administration)

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
npm ci --include=dev --ignore-scripts --engine-strict --no-audit --no-fund
npm run dev
```

The Vite dev server starts on **port 5173** and proxies `/api` requests to `http://localhost:5000` (the ASP.NET backend).

The UI's checked-in `.npmrc` uses the approved Microsoft 1ES npm feed at
`https://ms-feed-25.pkgs.visualstudio.com/1es-public/_packaging/npm-public/npm/registry/`.
Keep the lockfile's integrity hashes and approved download URLs. If the feed is
unavailable, stop instead of switching to a public registry.

#### Available npm Scripts

| Command | Description |
| --- | --- |
| `npm run dev` | Start dev server with hot reload |
| `npm run build` | TypeScript compile + Vite production build |
| `npm run preview` | Preview the production build locally |
| `npm run lint` | Run ESLint |
| `npm run test:unit` | Run isolated Vitest/Testing Library tests |

From the repository root, run the focused test wrappers without live identities
or APIs:

```powershell
./.github/skills/unit-test-backend/scripts/Invoke-BackendUnitTests.ps1 -Filter 'FullyQualifiedName~Category'
./.github/skills/unit-test-frontend/scripts/Invoke-FrontendUnitTests.ps1 -TestFiles src/services/categoriesService.test.ts,src/pages/CategoryManagement.test.tsx,src/pages/Dashboard.test.tsx -Build -Lint
```

These checks do not run hosted E2E. The existing hosted CRUD test enters the
internally designated default category before creating its temporary secret.

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
1. Run `Eklee.KeyVault.Api/setup-app-registration.ps1` with the
  `-GitHubOrganization`, `-GitHubRepoName`, and `-AzureAdRedirectUriDev`
  parameters to create the maintainer dev app registration and set the
  SPA-related GitHub environment variables (`VITE_AZURE_AD_CLIENT_ID`,
  `VITE_AZURE_AD_AUTHORITY`, `VITE_AZURE_AD_REDIRECT_URI`). Customer production
  registrations are configured by the customer deployment process.

1. Provision infrastructure locally using the [development infrastructure deployment instructions](Deployment/README.md#development-environment), including the required [managed identity RBAC script](Deployment/assign-mi-rbac.ps1). Infrastructure provisioning is separate from application CI/CD.
1. Run `Setup-Dev.ps1` for the repository maintainer dev environment. It provisions the permanent main, release, and branch Container Apps; binds their custom HTTPS domains; and reconciles the three SPA redirect URLs locally.
1. Push to `main` or `release/*` to trigger **CI/CD** deployment and hosted E2E for the matching permanent target. Other branches publish a commit-addressable GHCR image but do not deploy automatically. To deploy and test a feature or bugfix commit, run `./Scripts/Invoke-HostedE2E.ps1 -Current` from that checkout.

1. Perform user role assignments per [Post Deployment RBAC](#post-deployment-rbac).

When a same-repository pull request is merged into a `release/*` branch, the
cleanup workflow deletes the matching `branch-<normalized-branch>` GHCR image.
After a release branch merge has passed the queued main deployment and E2E run,
release promotion publishes the semantic release artifacts and deletes the
matching `release-<normalized-version>` GHCR image. No workflow deletes a
permanent Container App.

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

### Container App Prerequisites

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

## Post-Deployment RBAC

There are a few important roles to note:

- **Key Vault Secrets Officer** — Allows the managed identity to read, write, and delete secrets. Assigned by `Deployment/assign-mi-rbac.ps1`.
- **Storage Blob Data Contributor** — Allows the managed identity to read/write user-access config in blob storage.

`azd provision` and `azd up` run the managed identity RBAC script automatically from
the post-provision hook after Bicep provisioning. No separate command is required for
those workflows. GitHub Actions infrastructure deployment uses Azure CLI directly, so it
continues to require the same script after infrastructure deployment:

```powershell
cd Deployment
.\assign-mi-rbac.ps1 -ResourceGroup <resource-group-name> -SubscriptionId <subscription-id>
```

See [Deployment/README.md](Deployment/README.md) for detailed instructions.
