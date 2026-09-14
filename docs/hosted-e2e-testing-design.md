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
  - entra-id
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

Implemented as a separate hosted Playwright workflow. Successful `CI/CD` runs
for `release/**` branches run it automatically, and maintainers can run it
manually for any branch or release reference with a deployed Container App.

## Decision Summary

GitHub-hosted automation authenticates to Azure with the GitHub Actions OIDC
service principal, resolves the per-ref Container App, and runs the existing
Playwright suite against its HTTPS URL. The hosted workflow is separate from
deployment so branch deployments are not tested automatically on every commit.

The Container App's existing managed identity remains dedicated to the
application. It authenticates the application to Key Vault, Blob Storage, and
the container registry. It will not be used as the E2E caller identity.

## Identity Model

| Identity | Purpose |
| --- | --- |
| Container App managed identity | Outbound access to Key Vault, Blob Storage, and ACR |
| GitHub Actions OIDC service principal | Deploys resources, resolves the app, and acquires the hosted token |
| E2E application role | Maps the hosted caller to the API's read-only User role |

The Container App's managed identity is not the caller identity for the GitHub
runner. It remains responsible for outbound access to Key Vault and Blob
Storage.

## Required Setup

The API application registration must expose the application-only `E2E.Tester`
role. The GitHub OIDC service principal must be assigned that role.

Use [`setup-gh-deploy.ps1`](../Deployment/setup-gh-deploy.ps1) with
`-ApiClientId` to configure the GitHub client and assign the role:

```powershell
az login

$apiClientId = '<api-client-id>'

\.\Deployment\setup-gh-deploy.ps1 `
  -GitHubOrganization 'seekdavidlee' `
  -GitHubRepoName 'eklee-keyvault' `
  -ResourceGroupName 'rg-eklee-keyvault' `
  -ApiClientId $apiClientId
```

Run the script with an Entra identity that can update application roles and
application-role assignments. The assignment is the admin consent for this
application permission. The API service principal is created automatically when
it does not exist.

The hosted workflow acquires a token for:

```text
api://<api-client-id>/.default
```

The API maps `E2E.Tester` to its existing read-only `User` authorization role.
The hosted suite therefore runs the authenticated application test. The Admin-
only CRUD test remains available for local runs with a delegated Admin user.

The hosted Container App already uses external HTTPS ingress. If its ingress is
restricted to a private network later, the E2E compute resource must have
network access to that environment.

## Test Workflow

1. Build and deploy a branch or release image to its dedicated Container App.
2. Start the hosted workflow manually with the branch name, or let a successful
  `CI/CD` run for a `release/**` branch trigger it.
3. Log in to Azure from the GitHub runner with OIDC.
4. Resolve the same deterministic Container App name used by deployment.
5. Wait for `/healthz` to respond successfully.
6. Acquire an application token for `api://<api-client-id>/.default`.
7. Run the authenticated Playwright browser test against the resolved HTTPS URL
  and upload its report.

## Browser Test Boundary

The hosted token is an application token, not a delegated user session. The
API's `E2E.Tester` application role maps it to the read-only `User` role, which
is sufficient for the authenticated application test. The Admin-only CRUD test
must use a delegated Admin account and remains a local test until a dedicated
hosted Admin identity is provisioned.

The application continues to use its existing ASP.NET JWT validation. This
design does not require enabling Container Apps Easy Auth.

## References

* [Environment and Deployment Design](environment-deployment-design.md)
* [Hosted Playwright workflow](../.github/workflows/hosted-e2e.yml)
* [Container App cleanup workflow](../.github/workflows/cleanup-container-app.yml)
* [Azure Container Apps managed identities](https://learn.microsoft.com/azure/container-apps/managed-identity)
* [Container Apps application-to-application authentication](https://learn.microsoft.com/azure/container-apps/authentication-entra#configure-client-apps-to-access-your-container-app)
