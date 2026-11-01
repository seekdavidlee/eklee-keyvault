---
name: create-release
description: "Create and push a version-specific release branch from main. Accepts a full version or major, minor, or patch increment. Use when preparing a GitHub release branch."
argument-hint: "<version|major|minor|patch>"
user-invocable: true
---

## Goal

Prepare a release branch and matching milestone using
[New-Release.ps1](scripts/New-Release.ps1).

## Inputs

* `Version`: bare `MAJOR.MINOR.PATCH`, `major`, `minor`, or `patch`.
* `RepoRoot`: optional checkout path.
* `Force`: explicit opt-in to include all current uncommitted changes in an
  automatic release commit. Confirm that scope with the user before using it.

## Invocation And Approval

Run from the repository root. Preview first, including `-Force` only when
approved:

```powershell
$Arguments = @{ Version = 'minor' }
$Preview = & ./.github/skills/create-release/scripts/New-Release.ps1 @Arguments -WhatIf
```

Show the resolved version, branch, milestone, target commit, and planned
mutations. An explicit request to create the release authorizes the live run
without an additional approval round:

```powershell
$Arguments.Version = $Preview.Version
$Result = & ./.github/skills/create-release/scripts/New-Release.ps1 @Arguments -Confirm:$false
```

## Outputs

Report the structured result, including mutation and local-change states.
Success leaves the checkout on the pushed release branch; this does not
publish a GitHub Release. On error, report the message and partial state;
do not automatically retry after mutations. Use the script's `Get-Help`
for implementation details instead of reproducing its checks here.
