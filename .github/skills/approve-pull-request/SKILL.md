---
name: approve-pull-request
description: "Approve PR completion for the current branch. Use when asked to approve a PR, squash merge a PR, delete its remote branch, switch to the release branch, and delete the local source branch using gh CLI and deterministic scripts."
user-invocable: true
---

## Goal

Squash merge the current branch's PR and clean up through
[Complete-PullRequest.ps1](scripts/Complete-PullRequest.ps1).
This approves the completion workflow, not a GitHub review submission.
Do not run `gh pr review --approve`, bypass protections, or enable auto-merge.

## Inputs

- `Action`: `Preview` (default) or `Complete`
- `PullRequest`: optional PR number, required when discovery is ambiguous
- `ExpectedHead`: previewed head SHA, required for Complete
- `RepoRoot`: optional checkout path

## Invocation And Approval

Run from the repository root:

```powershell
$Preview = & ./.github/skills/approve-pull-request/scripts/Complete-PullRequest.ps1
```

Show repository, PR number/URL, source, release base, head SHA, and all four
mutations. Obtain approval for this exact PR and branch pair before Complete.
An explicit request covering squash merge and both branch deletions authorizes
completion once the preview matches the request; otherwise ask for approval.

```powershell
$Result = & ./.github/skills/approve-pull-request/scripts/Complete-PullRequest.ps1 `
    -Action Complete -PullRequest $Preview.PullRequest `
    -ExpectedHead $Preview.Head -Confirm:$false
```

`-WhatIf` validates and previews without merging or cleaning up. The script
requires a clean worktree, a same-repository PR targeting `release/*`, and a
local HEAD identical to the published PR head. Drafts, ambiguous PRs, blocked
checks, changes requested, and non-mergeable PRs stop completion. GitHub remains
the authority for required reviews and branch protections.

## Results And Recovery

Report the structured result and the final branch. Cleanup deletes only the
verified source ref, switches to the PR's release base, updates it by fast-forward,
and deletes the local source. Local force deletion is necessary after squash
merge and is allowed only after GitHub confirms the exact head was merged.

On failure, report the error and inspect GitHub and Git state before retrying.
Never blindly retry writes, stash changes, reset branches, or force-push.
For partial cleanup while still on the source branch, preview with the original
PR number; the script accepts that exact merged PR and skips merging again.
If already on the release branch, stop and explain the remaining cleanup rather
than treating it as a new source PR. Do not close issues separately.