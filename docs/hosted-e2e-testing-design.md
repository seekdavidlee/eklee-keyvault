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
post_date: 2026-09-18
author: Eklee KeyVault maintainers
ms.date: 2026-09-18
ms.topic: design
keywords:
  - end-to-end testing
  - Playwright
  - managed identity
  - Azure Container Apps
estimated_reading_time: 4
---

## Status

Partially implemented. Successful `CI/CD` runs for `main` and `release/**`
deploy their matching permanent Container App and run hosted E2E under the same
target-scoped FIFO queue. Ordinary feature and bugfix branch CI completions
publish an immutable image but do not deploy or run hosted E2E automatically.

The repository implementation enforces the dev-only application identity
boundary described below. GitHub Environment protection and Microsoft Entra
assignments remain maintainer-operated controls that must be verified before
the hosted identity is used.

## Decision Summary

GitHub-hosted automation uses the maintainer-owned `dev` deployment GitHub
Actions OIDC service principal to update the fixed main or release Container App
with an immutable image and run the hosted Playwright suite against that target's
configured HTTPS URL. It receives `E2E.Tester` only for the isolated dev API
registration. Feature and bugfix branch deployment remains a local maintainer
operation against the fixed branch target.

The Container App's existing managed identity remains dedicated to the
application. It authenticates the application to Key Vault, Blob Storage, and
the public GHCR image. It will not be used as the E2E caller identity.

## Identity Model

| Identity | Scope and purpose |
| --- | --- |
| Container App managed identity | Outbound access to its environment's Key Vault and Blob Storage |
| Customer API application registration | Customer-owned. Exposes only delegated user access and never defines an E2E application role or service identity permission. |
| Dev API application registration | Maintainer-owned. Used only by the repository's dev Container Apps and exposes the application-only `E2E.Tester` role. |
| Dev GitHub Actions deployment OIDC service principal | Maintainer-owned. Deploys dev resources, reads the dev test target, and acquires an `E2E.Tester` token for the dev API only. |
| `E2E.Tester` application role | Maps the dev hosted caller to the API's Admin authorization role without creating or persisting a user-access record. |

The Container App's managed identity is not the caller identity for the GitHub
runner. It remains responsible for outbound access to Key Vault and Blob
Storage. The dev deployment principal is not assigned `E2E.Tester` in customer
or production API registrations, and production API registrations do not expose
that role.

## Required Setup

Only the maintainer-owned dev API application registration may expose the
application-only `E2E.Tester` role. `Setup-Dev.ps1` assigns that role to the
existing `dev` GitHub Environment deployment principal. The role is never added
to a customer-created or production API registration.

The shared principal retains its existing deployment permissions, including its
dev Contributor assignment. Protect the `dev` environment and its release
branches because hosted E2E runs can exercise the dev API's administrative test
surface. The maintainer-only provisioning path is intentionally excluded from
customer setup and `azd` deployment workflows.

Deploy the maintainer development target with `azd` and reconcile its identities
with:

```powershell
./Setup-Dev.ps1
```

The script reads exactly one target from
`$HOME/.eklee-keyvault/setup-dev.json`. Its `appRegistrationName` is the
dedicated dev API registration and must differ from customer registrations in
the same Microsoft Entra tenant; the script rejects a duplicate listed in
`setup.json`. It updates the normal `dev` deployment environment with the dev
API audience used by Container Apps, resolves its existing `AZURE_CLIENT_ID`,
and assigns that deployment principal `E2E.Tester` on the dedicated dev API.
It does not create a separate environment or E2E-prefixed Azure variables.
Before a hosted run, maintainers must protect `dev` for this repository and
release branches and require the intended reviewers. The script uses the local
Git `origin` remote to identify the GitHub repository unless both GitHub
parameters are explicitly supplied.

The hosted workflow acquires a token for:

```text
api://<api-client-id>/.default
```

The API maps `E2E.Tester` to its existing `Admin` authorization role in the dev
environment. The hosted suite can therefore exercise all supported operations,
including the Admin-only CRUD path. A request from this application identity
must receive an ephemeral E2E user response from `GET /api/useraccess/me`; it
must never be bootstrapped or persisted as the first Admin in user access data.

The hosted Container App already uses external HTTPS ingress. If its ingress is
restricted to a private network later, the E2E compute resource must have
network access to that environment.

## Test Workflow

1. Build and publish an immutable commit image for every pushed branch.
2. For `main` and `release/**`, update the matching pre-provisioned Container
  App with that image and retain its target-scoped queue through testing.
3. Wait for `/healthz` at the configured custom HTTPS domain.
4. Log in to Azure from the GitHub runner with the dedicated dev E2E OIDC
  identity.
5. Acquire an application token for `api://<dev-api-client-id>/.default`.
6. Run the authenticated Playwright browser test against the configured HTTPS URL
  and upload a report that does not contain bearer tokens.
7. When the successful `main` deployment SHA is the merge commit of a
  `release/MAJOR.MINOR.PATCH` pull request, promote the exact merge SHA to a
  semantic image tag, Git tag, and GitHub Release.

## Browser Test Boundary

The hosted token is an application token, not a delegated user session. The
dev API's `E2E.Tester` application role maps it to `Admin`, which authorizes the
full hosted test suite without granting access in customer or production
environments. The E2E token is a dev credential: traces, screenshots, reports,
and logs must not retain it.

The application continues to use its existing ASP.NET JWT validation. This
design does not require enabling Container Apps Easy Auth.

## References

* [Environment and Deployment Design](environment-deployment-design.md)
* [CI/CD workflow](../.github/workflows/cicd.yml)
* [Release promotion workflow](../.github/workflows/release-promotion.yml)
* [GHCR image cleanup workflow](../.github/workflows/cleanup-container-app.yml)
* [Azure Container Apps managed identities](https://learn.microsoft.com/azure/container-apps/managed-identity)
* [Container Apps application-to-application authentication](https://learn.microsoft.com/azure/container-apps/authentication-entra#configure-client-apps-to-access-your-container-app)
