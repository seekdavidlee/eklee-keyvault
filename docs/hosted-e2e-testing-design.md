---
title: Hosted E2E Testing Design
description: Design for running Playwright E2E tests against a deployed Azure Container App
post_title: Hosted E2E Testing Design
author1: David Lee
post_slug: hosted-e2e-testing-design
featured_image: https://github.githubassets.com/images/modules/logos_page/GitHub-Mark.png
categories:
  - engineering
tags:
  - playwright
  - github-actions
  - azure-container-apps
  - managed-identity
ai_note: Created with AI assistance and requires maintainer review
summary: Defines the identity and workflow needed to run Playwright tests against a hosted development Container App.
post_date: 2026-09-13
author: Eklee KeyVault maintainers
ms.date: 2026-09-13
ms.topic: design
keywords:
  - end-to-end testing
  - Playwright
  - managed identity
  - Azure Container Apps
estimated_reading_time: 4
---

## Status

Proposed. This design covers hosted E2E testing for the development
environment. Local E2E testing remains supported.

## Decision Summary

Playwright tests will run against the deployed development Container App rather
than a locally started copy of the API. The tests will use a dedicated
user-assigned managed identity to call the API.

The Container App's existing managed identity remains dedicated to the
application. It authenticates the application to Key Vault, Blob Storage, and
the container registry. It will not be used as the E2E caller identity.

## Identity Model

| Identity | Purpose |
| --- | --- |
| Container App managed identity | Outbound access to Key Vault, Blob Storage, and ACR |
| E2E managed identity | Acquires an app-only token and calls the hosted API |
| GitHub Actions OIDC identity | Deploys resources and starts the E2E job |

The E2E managed identity must run on Azure-hosted compute, such as an Azure
Container Apps Job, virtual machine, or self-hosted GitHub runner. A
GitHub-hosted runner cannot directly use an Azure managed identity.

## Required Setup

The API application registration must expose an application role such as
`E2E.Tester`. The E2E managed identity's service principal must be assigned
that role with admin consent.

Use [`assign-e2e-app-role.ps1`](../Deployment/assign-e2e-app-role.ps1) to assign
the `E2E.Tester` application role to the E2E managed identity:

```powershell
az login

az identity create `
  --name eklee-keyvault-dev-e2e `
  --resource-group eklee-keyvault-dev `
  --location eastus2

$apiClientId = (az ad app show `
  --id <api-client-id> `
  --query appId `
  --output tsv).Trim()

.\Deployment\assign-e2e-app-role.ps1 `
  -ApiClientId $apiClientId `
  -ManagedIdentityName eklee-keyvault-dev-e2e `
  -ResourceGroup eklee-keyvault-dev
```

Run the script with an Entra identity that can update application roles and
application-role assignments. The assignment is the admin consent for this
application permission. Allow time for managed-identity token caches to expire
before validating a newly assigned role.

The E2E job acquires a token for:

```text
api://<api-client-id>/.default
```

The API must authorize that role for the operations covered by the tests. The
hosted environment must not depend on `ALLOW_ACL_AUTH=true`, and the E2E role
should not grant unrelated administrative operations.

The hosted Container App already uses external HTTPS ingress. If its ingress is
restricted to a private network later, the E2E compute resource must have
network access to that environment.

## Test Workflow

1. Build and deploy the branch image to the development Container App.
2. Capture the deployed app URL.
3. Start the Azure-hosted E2E job with the dedicated E2E managed identity.
4. Acquire an app-only API token and set `E2E_BASE_URL` to the deployed URL.
5. Run the Playwright suite against the hosted app.
6. Remove test data and allow the normal branch cleanup to remove the temporary
   Container App.

## Current Gap

The current [`cicd.yml`](../.github/workflows/cicd.yml) E2E job starts the API
locally on `localhost:8080`. It uses the GitHub Actions OIDC identity for Azure
resource checks and does not test the deployed Container App. Implementing this
design requires a hosted E2E runner, API application-role configuration, and a
workflow dependency from deployment to hosted E2E.

The application continues to use its existing ASP.NET JWT validation. This
design does not require enabling Container Apps Easy Auth.

## References

* [Environment and Deployment Design](environment-deployment-design.md)
* [Azure Container Apps managed identities](https://learn.microsoft.com/azure/container-apps/managed-identity)
* [Container Apps application-to-application authentication](https://learn.microsoft.com/azure/container-apps/authentication-entra#configure-client-apps-to-access-your-container-app)
