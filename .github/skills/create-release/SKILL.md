---
name: create-release
description: "Create and push a version-specific release branch from main. Accepts a full version or major, minor, or patch increment. Use when preparing a GitHub release branch."
argument-hint: "<version|major|minor|patch>"
user-invocable: true
---

## Goal

Use the bundled PowerShell script to prepare a release branch and its matching
GitHub milestone. The script is the source of truth for validation, mutation
ordering, safeguards, and the structured result.

## Workflow

1. From the repository root, preview the requested release. Replace `<value>`
  with a bare `MAJOR.MINOR.PATCH` version, `major`, `minor`, or `patch`.

   ```powershell
  .\.github\skills\create-release\scripts\New-Release.ps1 -Version <value> -WhatIf
   ```

   If the worktree is intentionally dirty, include `-Force` in the preview.

   ```powershell
  .\.github\skills\create-release\scripts\New-Release.ps1 -Version <value> -Force -WhatIf
   ```

2. Show the preview's resolved version, branch, milestone state, target commit,
  and planned mutations. When the user explicitly requests release creation,
  proceed to the live run without asking for a second approval. The command
  still performs all script preflight checks before mutating GitHub or Git.

3. Run the same command without `-WhatIf`.

   ```powershell
  .\.github\skills\create-release\scripts\New-Release.ps1 -Version <value> -Confirm:$false
   ```

   When retaining uncommitted changes is intentional, run:

   ```powershell
  .\.github\skills\create-release\scripts\New-Release.ps1 -Version <value> -Force -Confirm:$false
   ```

4. Report the returned structured object. On failure, report the script's
  message and any state it identifies; do not retry automatically after a
  milestone or branch mutation.

## Script contract

Read the script's comment-based help with `Get-Help` when details are needed.
It owns the following behavior:

* Full-version validation and increment calculation from the highest release
  branch
* Git and GitHub preflight, including ancestry, branch, milestone, auth, and
  write-access checks
* Milestone creation, branch creation from local `main`, inclusion of local
  changes when `-Force` is specified, and pushing only the release branch
* `-WhatIf`, `-Force`, `ShouldProcess`, failure reporting, and structured output

The script does not check out branches, create tags, publish GitHub Releases,
or modify the current worktree during normal operation. With `-Force`, local
changes are included in the release branch automatically after preflight.
