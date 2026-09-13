---
title: GitHub Branch and Release Image Versioning Design
description: High-level design for branch-specific GHCR image tags, release branches, and release cleanup automation
post_title: GitHub Branch and Release Image Versioning Design
author1: David Lee
post_slug: github-branch-image-versioning-design
featured_image: https://github.githubassets.com/images/modules/logos_page/GitHub-Mark.png
categories:
  - engineering
tags:
  - github-actions
  - ghcr
  - branch-management
  - release-automation
ai_note: Created with AI assistance and requires maintainer review
summary: Defines simple mutable image tags for development branches and immutable version tags for releases.
post_date: 2026-09-13
author: Eklee KeyVault maintainers
ms.date: 2026-09-13
ms.topic: design
keywords:
  - branch image tags
  - GitHub Container Registry
  - release branches
  - semantic versioning
estimated_reading_time: 5
---

## Status

Proposed

## Relationship to release versioning

This proposal updates the initial tag-only release model described in the
[GitHub Release and Container Versioning Design](release-versioning-design.md).
If this proposal is approved, its release-branch lifecycle and image-tag rules
take precedence for future workflow implementation.

## Decision summary

GitHub Actions will publish a mutable GHCR image tag for each development branch.
The tag is derived from the branch name and is overwritten whenever that branch
changes.

Release branches will use the `release/<version>` naming convention. Their image
tag will be normalized to `release-<version>`, because container image tags cannot
contain `/`. This tag is also mutable while the release branch is being stabilized.

When a release branch is merged into `main`, release automation will publish the
final image with the bare semantic version, such as `1.2.3`. The final version tag
will not be silently overwritten by later workflow runs.

Merged development branches and merged release branches will be deleted by GitHub
Actions after their pull requests are merged.

## Goals

* Make development images easy to identify by branch.
* Allow a branch image tag to follow the latest commit on that branch.
* Provide a clear release-candidate tag while a release is being stabilized.
* Publish a simple semantic version tag for each completed release.
* Delete branches that have been merged and no longer require maintenance.
* Keep the workflow and naming rules small enough to understand at a glance.

## Non-goals

* Maintaining multiple release versions from the same branch.
* Treating mutable branch tags as deployment or audit identities.
* Automatically deleting protected branches such as `main`.
* Reusing a published semantic version for different source code.
* Adding a separate versioning scheme for Azure infrastructure.

## Naming model

Git branch names and container image tags use related but distinct formats.

| Source | Example branch or tag | GHCR image tag | Behavior |
| --- | --- | --- | --- |
| Development branch | `feat/24-self-discover-storage` | `branch-feat-24-self-discover-storage` | Mutable |
| Release branch | `release/1.2.3` | `release-1.2.3` | Mutable |
| Completed release | Git tag `1.2.3` | `1.2.3` | Immutable |

Branch names are normalized by converting them to lowercase, replacing `/` and
other unsupported characters with `-`, and limiting the result to a safe image-tag
length. The normalized tag is an alias for the branch's latest successful build.

The commit SHA remains available as a separate image tag or digest for precise
identification. Consumers that need reproducibility should use the digest rather
than a branch tag.

## Release lifecycle

1. A development branch is pushed.
2. GitHub Actions builds the image and updates its branch-specific GHCR tag.
3. A `release/<version>` branch is created when release stabilization begins.
4. GitHub Actions builds the release candidate and updates `release-<version>`.
5. Fixes merged into the release branch rebuild and overwrite that candidate tag.
6. The release branch is merged into `main`.
7. Release automation creates the bare version tag, such as `1.2.3`, and publishes
   the final image tag.
8. The merged release branch is deleted.

The release version should follow the existing `MAJOR.MINOR.PATCH` convention. A
release tag is created once and must continue to identify the same source commit.

## Branch cleanup automation

One GitHub Actions workflow will handle merged-branch cleanup. It will run when a
pull request is closed and will continue only when all of these conditions hold:

* The pull request was merged.
* The source branch is in the same repository.
* The source branch is not protected.
* The target branch is an allowed release or development branch.

The workflow will delete:

* A normal source branch after it is merged into a release branch.
* A normal source branch after it is merged into `main`.
* A `release/<version>` branch after it is merged into `main`.

The cleanup action will use narrowly scoped repository write permission and will not
delete a branch when the pull request was closed without merging.

## Overwrite policy

Mutable aliases can be overwritten by design:

* Development branch tags follow the latest successful commit on the branch.
* `release-<version>` follows the latest successful commit on the release branch.

Semantic version tags are different. A workflow rerun for the same source commit
may be treated as idempotent, but a workflow must fail if the version already
points to a different commit. A corrected release should use a new patch version
instead of silently changing an existing release.

This policy keeps branch testing convenient without weakening the meaning of a
published release.

## Workflow boundaries

The implementation should use separate workflow responsibilities:

* Build and publish branch images for non-release branches.
* Build and publish the release-candidate image for `release/<version>` branches.
* Create the semantic Git tag and publish the final image after the release branch
  is merged into `main`.
* Delete merged branches in a small, independently auditable cleanup workflow.

All released deployments should use a digest or an immutable semantic version tag.
Branch and release-candidate tags are intended for testing and validation only.

## Trade-offs

Branch-specific mutable tags are simple and make the current build easy to find,
but the tag can change after a deployment or test has started. Commit tags and
digests provide the precise fallback when that distinction matters.

Automatically deleting merged branches keeps the repository tidy and prevents
stale development branches from accumulating. It also removes a convenient place
to inspect old branch-only commits, so the pull request and its commits remain the
durable review record.

Using the same version in the release branch name, Git tag, and final image tag
reduces translation between GitHub and GHCR. The restriction against overwriting a
published version adds a small amount of release discipline and prevents an old
deployment reference from silently changing meaning.

## Follow-up implementation

The implementation should add the branch normalization, release-merge detection,
semantic tag creation, GHCR publication, and merged-branch deletion workflows. It
should also document the supported branch and image tag formats in the repository
deployment guidance.
