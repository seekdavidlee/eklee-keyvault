---
title: Design Documents
description: Index of Eklee KeyVault design documents
post_title: Design Documents
author1: David Lee
post_slug: design-documents
microsoft_alias: leedavid
featured_image: https://github.githubassets.com/images/modules/logos_page/GitHub-Mark.png
categories:
  - engineering
tags:
  - design
  - architecture
ai_note: Created with AI assistance and requires maintainer review
summary: Index of the repository's design documents and their current proposals.
post_date: 2026-09-13
---

## Design Documents

- [Environment and Deployment Design](environment-deployment-design.md) - Defines
  branch-based GitHub Environment selection, Azure deployment routing, and the
  separation between deployments and public GitHub releases.
- [GitHub Branch and Release Image Versioning Design](github-branch-image-versioning-design.md)
  - Defines branch-specific GHCR image tags, release-branch tags, immutable
  release version tags, and merged-branch cleanup.
- [GitHub Release and Container Versioning Design](release-versioning-design.md) -
  Defines semantic versioning, GitHub Releases, immutable GHCR release images,
  and release workflow ownership of the `latest` tag.
- [Hosted E2E Testing Design](hosted-e2e-testing-design.md) - Defines the
  managed identity and workflow required to test a deployed development
  Container App.

## Adding a Design

Add every new design document to the list above with a relative link and a brief
description.
