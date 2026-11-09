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
summary: Local setup, customer and maintainer deployment, application access, and category-based secret management with import/export and startup migration.
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

### Export and Import

Open a category and choose **Export category**. Confirm the warning before
downloading `secrets-export.json`; only that category's secrets are included.
Admin and User accounts can export. Only Admin accounts can import.

> [!WARNING]
> Exported JSON is unencrypted and contains actual secret values and all tags.
> Store it securely, do not commit it or attach it to issues, and delete it when
> no longer needed. Export responses are marked `Cache-Control: no-store`.

Choose **Import secrets**, select an application-generated JSON file, and select
a destination category. No destination is selected automatically. You can enter
a unique **New category name** and choose **Create destination category**;
creation selects the new category without importing anything yet. Import assigns
all new secrets to that destination. Original vault names, values, display names,
and all Key Vault tag keys and values are preserved, including tags named
`category`. Category associations live in blob metadata, not in user-defined tags.

The format is versioned and includes empty tag objects for secrets without tags:

```json
{
  "formatVersion": 1,
  "secrets": [
    {
      "name": "example-secret",
      "value": "example-value-not-a-real-secret",
      "tags": { "environment": "test", "category": "user-defined" },
      "displayName": "Example"
    }
  ]
}
```

Files are limited to 10 MiB and 1000 entries. Names require 1-127 ASCII letters,
digits, or hyphens; values allow up to 25 KiB in UTF-8. Tags allow at most 15
string pairs per secret, with keys of 1-512 characters and values of 0-256
characters. Display names are preserved without truncation within the file-size
limit. Outgoing records must satisfy the same constraints as imports. Unknown fields,
duplicate JSON properties, unsupported versions, invalid types, and invalid
entries reject the entire file before any secret or association writes. Errors
never echo secret values or SDK response bodies.

Duplicate names are compared without regard to case across the entire vault,
including enabled and disabled secrets in other categories. They are skipped
without changing values, tags, or associations. Within a file, the first entry
is attempted and later case-insensitive matches are skipped. Nonduplicates
continue importing. The result lists each name as `imported`, `skipped`, `failed`,
or `notAttempted`, without values or tags.

Operational failures after validation can leave partial results; import is not a
transaction across Key Vault and blob storage. Ordinary storage/category failures
are reported per entry and later entries continue. Storage access denial stops
remaining writes and returns 403 with partial results. Check every failed entry
before retrying: its value or category reservation may already have been saved.
Check `notAttempted` entries too: their values were not written, but the current
batch may already have reserved their categories and display names.
Lease release can fail after a successful write or duplicate check; each input
still has exactly one result. Recover a failed lease using the procedure below
before retrying that name. Access denial from either the secret operation or
lease cleanup stops remaining writes, even when the other operation also fails.
If only a reservation exists, retry in the same category or delete the absent
name to clear it. If a value exists, a retry skips it; inspect the value, tags,
and display metadata, then repair through the existing secret/metadata APIs.

Exports and imports use the same per-secret operation leases as normal
create/delete, holding at most 100 leases per batch. Export reloads category
membership under those leases before reading values, so a reassigned name cannot
export another category's value. Import checks vault-wide duplicates under the
leases and reserves each batch's categories and display names in one
ETag-protected metadata update before writing values. A 1000-entry import of new
names needs 10 metadata uploads without contention, rather than two per secret.
An access denial stops later value writes and prevents subsequent batches from
acquiring leases or reserving metadata.

The leases prevent competing application imports and writes from overwriting
existing secrets. Direct vault writers outside this application do not honor
those leases; pause them during transfers. Soft-deleted names can fail creation
until recovered or purged through existing vault administration procedures.
Import does neither.

### API Contracts

| Endpoint | Role | Contract |
| --- | --- | --- |
| `GET /api/categories` | Admin or User | Shared category IDs, names, and `isDefault` |
| `POST /api/categories` | Admin | `{ "name": "Finance" }`; returns the new category |
| `PUT /api/categories/{id}` | Admin | Renames using `{ "name": "Finance" }`, preserving identity |
| `DELETE /api/categories/{id}` | Admin | Deletes only an empty, nondefault category |
| `GET /api/secrets` | Admin or User | Lists all secrets; categories do not restrict authorization |
| `GET /api/secrets?categoryId={id}` | Admin or User | Only secrets associated with that category; unknown ID returns 404 |
| `GET /api/secrets/{name}/value` | Admin or User | Returns `{ "value": "..." }`; missing secret returns 404 |
| `PUT /api/secrets/{name}` | Admin | New secrets require `{ "value": "...", "categoryId": "..." }` |
| `POST /api/secrets/generate` | Admin | Validates a generation policy and returns an unsaved candidate; does not create or update a secret |
| `DELETE /api/secrets/{name}` | Admin | Soft-deletes the secret and removes its association; success returns 204 |
| `GET /api/metadata` | Admin | Complete metadata inventory with its ETag response header |
| `PUT /api/metadata` | Admin | Complete document with display-name edits and matching `If-Match`; association changes are rejected |
| `GET /api/secret-transfers/export?categoryId={id}` | Admin or User | Downloads unencrypted version-1 JSON from an existing category; no-store |
| `POST /api/secret-transfers/import?categoryId={id}` | Admin | Export JSON body with `Content-Type: application/json`; required existing destination; value-free per-entry results |
| `GET /api/useraccess/me` | Authenticated user | Current access record; bootstraps Admin only while the access list is empty; unregistered users otherwise receive 403 |
| `GET /api/useraccess/users` | Admin | Complete user list and ETag for editing |
| `PUT /api/useraccess/users` | Admin | Replaces the complete user list with matching `If-Match`; at least one Admin must remain |

Transfer validation and missing categories return 400. Unauthorized roles return
401/403; storage access denial returns 403, and preflight storage unavailability
returns 503. Requests above 10 MiB return 413. A validated import may return 200
with per-entry failures; always inspect every result rather than only HTTP status.

Existing secret value updates can omit `categoryId`; supplying another category
returns 409 rather than moving the secret. Invalid names or creation categories
return 400. Category uniqueness, nonempty/default deletion, and exhausted
concurrent-write retries return actionable 409 problem details.

The Admin-only `GET /api/metadata` returns the complete metadata inventory and
its ETag response header. Its PUT saves display-name changes with that
`If-Match` ETag; it rejects inventory or association changes. Do not submit just a filtered category's
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

Costs include Azure Container Apps, Azure Storage, Azure Key Vault, and Log
Analytics, plus any optional private-network resources. CI/CD sets each permanent
maintainer target to one minimum and one maximum replica; these apps do not scale
to zero. The manual container example below uses zero minimum replicas, which
allows scale-to-zero and introduces cold starts. Storage, logging, and networking
can still incur charges while compute is idle. Estimate costs for your selected
region and configuration rather than assuming all deployments are nearly free.

## Which Setup Should I Use

| Audience           | Entry Point                                                | Purpose                                                         |
| ------------------ | ---------------------------------------------------------- | --------------------------------------------------------------- |
| App consumers      | [Setup.ps1](Setup.ps1)                                     | Deploy or update a published release in your Azure environment. |
| Maintainers        | [Setup-Maintainer.ps1](Deployment/Setup-Maintainer.ps1)    | Configure non-production CI/CD deployment and hosted E2E.       |
| Local contributors | [Local Development](#local-development)                    | Run the frontend and API locally without maintainer setup.      |

Run either deployment script from the repository root. Both use the shared
[azure.yaml](azure.yaml) project configuration at the root; infrastructure and
deployment helpers live under [Deployment](Deployment/README.md). Maintainer
setup is not required for local development and must not target customer or
production resources.

## Prerequisites

- [Node.js](https://nodejs.org/) 22.22.2 or later on the Node 22 line (matching CI and the lockfile's engine requirements)
- [.NET SDK](https://dotnet.microsoft.com/download) 10, matching the API's `net10.0` target
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) (logged in with `az login`)
- [PowerShell](https://learn.microsoft.com/powershell/scripting/install/installing-powershell) 7.4 or later for the deployment scripts
- [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) for [Setup.ps1](Setup.ps1) and [Setup-Maintainer.ps1](Deployment/Setup-Maintainer.ps1)
- [GitHub CLI](https://cli.github.com/) (authenticated with `gh auth login`) for [maintainer setup](Deployment/Setup-Maintainer.ps1) and GitHub workflow administration; not required for [customer setup](Setup.ps1)
- [Git](https://git-scm.com/) for cloning the repository and resolving its `origin` during scripted setup

## Local Development

### App Registration Setup

For local development, run the setup script to create (or look up) a Microsoft
Entra ID app registration and update the API `appsettings.json`. It registers
`http://localhost:5173` as a SPA redirect URI.

```powershell
cd Eklee.KeyVault.Api
.\setup-app-registration.ps1 -AppName "eklee-keyvault-local"
```

The script does not create the UI `.env` file. In an existing file it replaces
only existing `VITE_AZURE_AD_CLIENT_ID` and `VITE_AZURE_AD_AUTHORITY` lines; it
does not add missing lines or set `VITE_AZURE_AD_REDIRECT_URI`. Configure all
three values as shown below, using the client and tenant IDs printed by setup.

> [!WARNING]
> This local helper replaces the registration's SPA redirect URI list with
> localhost and any explicitly supplied dev/prod URLs. Use a separate local
> registration, or supply all required URLs to avoid removing deployed redirects.
> Use [Setup-Maintainer.ps1](Deployment/Setup-Maintainer.ps1) for maintainer
> deployment rather than this helper's optional GitHub-variable configuration.

### Running the React (Vite) Frontend

1. Navigate to the UI project directory:

```sh
cd Eklee.KeyVault.UI
```

1. Create or update `.env` with all required Microsoft Entra ID configuration:

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
./.github/skills/unit-test-backend/scripts/Invoke-BackendUnitTests.ps1 -Filter 'FullyQualifiedName~Category|FullyQualifiedName~SecretTransferTests'
./.github/skills/unit-test-frontend/scripts/Invoke-FrontendUnitTests.ps1 -TestFiles src/services/categoriesService.test.ts,src/pages/CategoryManagement.test.tsx,src/pages/Dashboard.test.tsx,src/services/secretsService.test.ts -Build -Lint
```

These checks do not run hosted E2E. The existing hosted CRUD test enters the
internally designated default category before creating its temporary secret.

### Running the ASP.NET Backend

Configure your own Key Vault and Storage endpoints; the checked-in
`appsettings.json` contains maintainer-specific resource values, not reusable
defaults. The `configs` blob container must already exist. Local development
uses `AuthenticationMode=azcli` (also the default) and therefore needs a signed-in
Azure CLI user with Key Vault Secrets Officer and Storage Blob Data Contributor
on the selected resources. If public network access is disabled, run from a
network that can reach their private endpoints.

From the repository root, set process-local configuration overrides and start
the API on the port expected by the frontend proxy:

```powershell
$env:KeyVaultUri = "https://<your-keyvault-name>.vault.azure.net/"
$env:StorageUri = "https://<your-storage-account>.blob.core.windows.net/"
$env:StorageContainerName = "configs"
$env:AuthenticationMode = "azcli"
$env:ASPNETCORE_ENVIRONMENT = "Development"
cd Eklee.KeyVault.Api
dotnet run --urls http://localhost:5000
```

Startup migration must succeed before the API serves requests. In development
mode, Swagger is available at `/swagger`; `/healthz` is the health-check endpoint.

### Application User Access

Azure resource RBAC controls the backend identity's access to Key Vault and
Storage. Interactive users receive separate application roles stored in
`configs/user_access.json`; signing in through Entra ID alone does not grant
access to secrets.

> [!IMPORTANT]
> When the user-access list is empty, the first authenticated user to request
> `GET /api/useraccess/me` becomes Admin automatically. Sign in as the intended
> administrator before opening a new deployment to other users. Do not delete
> or empty the user-access blob to reset access, as this reopens Admin bootstrap.

After bootstrap, an Admin uses **User Management** to add users and assign
`Admin` or `User`. Unregistered users receive 403. At least one Admin must remain.

## Maintainer Deployment

These steps configure the repository maintainer's non-production CI/CD and hosted
E2E environment. Customers should use [Customer Deployment](#customer-deployment)
instead; do not run maintainer E2E setup against a customer or production vault.

1. Fork if needed, clone the repository, and authenticate Azure CLI and GitHub CLI
  to the intended subscription and repository.
1. Create `$HOME\.eklee-keyvault\setup-dev.json` with exactly one target object,
  using the example below. It is not the customer `targets` catalog. The
  `appRegistrationName` must be distinct from customer registrations in the same
  tenant. Configure three distinct custom hostnames and their DNS records for
  managed-certificate validation; setup prompts for missing hostnames.
1. From the repository root, run `./Deployment/Setup-Maintainer.ps1`. It runs
  `azd up` to provision infrastructure and the permanent main, release, and branch Container Apps,
  applies managed-identity RBAC, binds custom HTTPS domains, and reconciles all
  three SPA redirect URLs. A separate Azure CLI infrastructure deployment is not
  required. It also creates or reuses the deployment identity, reconciles its
  GitHub `dev` OIDC credential, assigns Contributor on the profile's exact resource
  group, and sets deployment variables. An existing `AZURE_CLIENT_ID` is reused.
1. Verify the GitHub `dev` environment's branch restrictions and required reviewers
  before running deployments or hosted E2E. Allow the branch types you intend to
  deploy. Setup does not configure these protections. The setup account needs
  permission to provision resources, manage Entra applications/service principals,
  and assign Azure roles on the development resource group.
1. Push changes matching the [CI/CD path filters](.github/workflows/cicd.yml)
  to trigger image publication, deployment, and hosted E2E. `main` selects the
  permanent main/dev target, `release/*` selects the release target, and other
  branches select the shared branch target. Documentation-only pushes do not
  trigger this workflow. Branch deployments share one permanent Container App;
  a later qualifying branch push can replace its deployed image. Review the
  corresponding GitHub Actions run for deployment and hosted E2E results.

1. Bootstrap the intended Admin and configure users as described in
  [Application User Access](#application-user-access).

Example maintainer profile (replace the IDs and hostnames with your own):

```json
{
  "displayName": "Maintainer development",
  "tenantId": "<your-tenant-id>",
  "subscriptionId": "<your-subscription-id>",
  "environmentName": "maintainer-dev",
  "location": "eastus",
  "prefix": "eklkvdev",
  "resourceGroupName": "eklee-keyvault-dev-rg",
  "appRegistrationName": "eklee-keyvault-maintainer-dev",
  "enablePrivateNetworking": false,
  "customDevDomainName": "keyvault-main.example.com",
  "customReleaseDomainName": "keyvault-release.example.com",
  "customBranchDomainName": "keyvault-branch.example.com"
}
```

The three maintainer targets reuse the same managed identity, Key Vault, and
Storage resources; they are not isolated data environments. Setup assigns the
deployment principal the dedicated dev API's application-only `E2E.Tester` role
for hosted API and browser tests. Keep test data separate from production and
never assign that role to customer registrations. CI/CD deploys by immutable
image digest and runs hosted E2E inside the same target-scoped FIFO deployment
queue, including for `main` and ordinary branches.

When a same-repository pull request is merged into a `release/*` branch, the
cleanup workflow deletes the matching
`branch-<normalized-branch>-<12-char-ref-hash>` GHCR image.
After a release branch merge has passed the queued main deployment and E2E run,
release promotion publishes the semantic release artifacts and deletes the
matching `release-<normalized-version>-<12-char-ref-hash>` GHCR image. No workflow
deletes a permanent Container App.

The [maintainer setup script](Deployment/Setup-Maintainer.ps1) configures the
following GitHub environment variables in `dev`:

| Variable                     | Set By                                                  |
| ---------------------------- | ------------------------------------------------------- |
| `AZURE_CLIENT_ID`            | [Setup-Maintainer.ps1](Deployment/Setup-Maintainer.ps1) |
| `AZURE_TENANT_ID`            | [Setup-Maintainer.ps1](Deployment/Setup-Maintainer.ps1) |
| `AZURE_SUBSCRIPTION_ID`      | [Setup-Maintainer.ps1](Deployment/Setup-Maintainer.ps1) |
| `RESOURCE_GROUP`             | [Setup-Maintainer.ps1](Deployment/Setup-Maintainer.ps1) |
| `VITE_AZURE_AD_CLIENT_ID`    | [Setup-Maintainer.ps1](Deployment/Setup-Maintainer.ps1) |
| `VITE_AZURE_AD_AUTHORITY`    | [Setup-Maintainer.ps1](Deployment/Setup-Maintainer.ps1) |
| `DEV_CONTAINER_APP_NAME`     | [Setup-Maintainer.ps1](Deployment/Setup-Maintainer.ps1) |
| `DEV_E2E_BASE_URL`           | [Setup-Maintainer.ps1](Deployment/Setup-Maintainer.ps1) |
| `RELEASE_CONTAINER_APP_NAME` | [Setup-Maintainer.ps1](Deployment/Setup-Maintainer.ps1) |
| `RELEASE_E2E_BASE_URL`       | [Setup-Maintainer.ps1](Deployment/Setup-Maintainer.ps1) |
| `BRANCH_CONTAINER_APP_NAME`  | [Setup-Maintainer.ps1](Deployment/Setup-Maintainer.ps1) |
| `BRANCH_E2E_BASE_URL`        | [Setup-Maintainer.ps1](Deployment/Setup-Maintainer.ps1) |

CI/CD selects the SPA redirect URI from the target's E2E base URL; it does not
use a shared `VITE_AZURE_AD_REDIRECT_URI` GitHub environment variable.

## Customer Deployment

From a cloned checkout, run `./Setup.ps1` and choose full setup for the first
deployment. It collects a customer target, stores non-secret settings in
`$HOME\.eklee-keyvault\setup.json`, resolves a selected published stable release
to an immutable GHCR digest, and runs `azd up`. App registration, infrastructure,
managed-identity RBAC, and SPA redirect registration are handled by setup hooks.
Node.js and the .NET SDK are not required to deploy a published image.

For an existing environment, choose the script's version-only option to change
only the application image without reprovisioning infrastructure. Customer
registrations expose delegated user access, not the maintainer `E2E.Tester` role,
and customer setup does not require GitHub CLI. See
[Azure Developer CLI Deployment](AZDREADME.md) for detailed setup and update steps.
Complete [Application User Access](#application-user-access) after deployment.

## Custom Domain

Customer custom domains are optional; maintainer setup requires the three target
hostnames above. For customer azd deployments, configure `CUSTOM_DOMAIN_NAME` in
the selected azd environment and create the required CNAME record. Setup hooks
bind the managed certificate, update the runtime frontend URLs, and append the
custom HTTPS URL to the registration's SPA redirect URIs.

For a manually created Container App, bind the domain in Azure and update both
`VITE_AZURE_AD_REDIRECT_URI` and `VITE_API_BASE_URL` to its HTTPS URL. Add that URL
as a SPA redirect URI in Entra ID while retaining required existing redirects.

## Deploy from GitHub Container Registry

You can create an Azure Container App directly from the public GHCR image without
building the Docker image yourself. This is useful for quick deployments or
manually managed deployments.

The public image is available at:

```text
ghcr.io/seekdavidlee/eklee-keyvault:latest
```

`latest` is updated by qualifying pushes to `main`; it is not a pinned semantic
release and may precede release promotion. Prefer a published stable version tag
or immutable digest for customer deployments. Forks publish under their own
`ghcr.io/<owner>/<repository>` path; verify package visibility before assuming
anonymous image pulls will work. The following shell examples use Bash syntax.

### Container App Prerequisites

Before you begin, ensure you have the following Azure resources already provisioned
(for example, via the Bicep templates in the `Deployment/` folder):

- A resource group
- A Container Apps environment
- A user-assigned managed identity (with Key Vault and Storage RBAC roles assigned)
- An Azure Key Vault
- An Azure Storage account with a `configs` blob container
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
IMAGE="ghcr.io/seekdavidlee/eklee-keyvault:<published-release-version>"

az containerapp create \
  --name eklee-keyvault \
  --resource-group "$RESOURCE_GROUP" \
  --environment "$ENV_NAME" \
  --image "$IMAGE" \
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

After the container app is created, retrieve the FQDN:

```sh
FQDN=$(az containerapp show \
  --name eklee-keyvault \
  --resource-group "$RESOURCE_GROUP" \
  --query "properties.configuration.ingress.fqdn" -o tsv)

echo "App URL: https://$FQDN"
```

In the Entra admin center, open the application's **Authentication** settings
and add `https://<your-container-app-fqdn>` under **Single-page application**.
Retain any existing required redirect URIs. Set the Container App's
`VITE_AZURE_AD_REDIRECT_URI` to this same HTTPS URL if the creation command used
a placeholder. Redirect registration is automatic in the recommended `Setup.ps1`
flow.

### Update an Existing Container App

To update the container app to a selected published release:

```sh
az containerapp update \
  --name eklee-keyvault \
  --resource-group "$RESOURCE_GROUP" \
  --image "ghcr.io/seekdavidlee/eklee-keyvault:<published-release-version>"
```

## Post-Deployment RBAC

There are a few important roles to note:

- Key Vault Secrets Officer allows the managed identity to read, write, and delete secrets. Assigned by `Deployment/assign-mi-rbac.ps1`.
- Storage Blob Data Contributor allows the managed identity to read/write user-access configuration, category/display metadata, and operation-lock blobs and leases. Assigned by the same script.

`azd provision` and `azd up` run the managed identity RBAC script automatically from
the post-provision hook after Bicep provisioning. No separate command is required for
those workflows. Direct Azure CLI infrastructure deployments do not run azd hooks,
so run the same script explicitly afterward. Application CI/CD reuses already
provisioned infrastructure; it does not provision resources or assign these roles:

```powershell
cd Deployment
.\assign-mi-rbac.ps1 -ResourceGroup "<resource-group-name>" -SubscriptionId "<subscription-id>"
```

See [Deployment/README.md](Deployment/README.md) for detailed instructions.
