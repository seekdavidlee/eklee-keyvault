---
name: create-pull-request
description: "Create a release-aware GitHub PR. Use when creating pull requests or resolving their base: feature branches target the active release; release branches target main."
---

## Goal

Create or reuse one PR using
[Invoke-PullRequest.ps1](scripts/Invoke-PullRequest.ps1).

## Inputs

* `Action`: `Resolve` (default), `Preview`, or `Create`.
* `Base`: optional explicit remote branch.
* `RepoRoot`: optional checkout path.
* `Title`, `BodyFile`, `ReviewedFingerprint`: required for Preview/Create.
  The fingerprint must come from passing
  [functional review](../functional-implementation-code-review/SKILL.md) and
  [security review](../security-implementation-code-review/SKILL.md) plus
  [performance review](../performance-implementation-code-review/SKILL.md) of the
  same complete snapshot. Security and performance reviews may only be skipped
  for verified documentation-only changes, each with a `SkippedDocumentationOnly`
  disposition, file inventory, and rationale; functional review still applies.
  Mixed or uncertain changes require both reviews. The script verifies content
  identity, not review verdicts; the calling workflow must verify all three
  review dispositions before Preview/Create.
* `TaskFiles`: same optional working-file selection used for local review.

## Invocation And Approval

Run from the repository root:

```powershell
$Routing = & ./.github/skills/create-pull-request/scripts/Invoke-PullRequest.ps1 -Action Resolve
```

Confirm the returned repository, source/base, and routing reason with the user.
`BaseSelectionRequired` requires a user-selected `Base`; it is not permission
to invent a fallback. Resolve routing before local review.

Draft a body from the reviewed snapshot and commit history: issue linkage,
changes, actual validation, and limitations, without secrets or local tracking
artifacts. Preview title/body for approval. Obtain separate commit approval
and named-branch ordinary-push approval, following repository conventions and
staging only reviewed task files. No force-push or implicit publication.

After the reviewed content is published:

```powershell
$Arguments = @{
    Base = $ResolvedBase
    Title = $ApprovedTitle
    BodyFile = $ApprovedBodyFile
    ReviewedFingerprint = $PassingReviewFingerprint
}
$Preview = & ./.github/skills/create-pull-request/scripts/Invoke-PullRequest.ps1 @Arguments -Action Preview
```

Only with PR-write approval, run the same inputs with `-Action Create
-Confirm:$false`. `-WhatIf` previews Create without a GitHub write.

## Outputs

`Resolved` returns context and routing. `Preview` returns title/body and the
verified branch pair. `Created` or `Reused` additionally returns `PullRequest`
(number and `html_url`) and published `Head`; hand these to
[remote review](../request-github-code-review/SKILL.md).

`PullRequestSelectionRequired` requires a user decision about the returned
PRs. Errors block publication. Changed content/routing requires fresh affected
functional, security, and performance review, including reclassification of any
documentation exception. An uncertain creation result requires `Preview` to
inspect server state before any retry. Do not merge, close issues, or request
remote review here.