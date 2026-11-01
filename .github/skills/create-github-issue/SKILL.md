---
name: create-github-issue
description: "Create one detailed GitHub enhancement, bug, or documentation issue with the bundled PowerShell script. Use when a contributor wants to file a repository issue and supply its requirements."
argument-hint: "<enhancement|bug|documentation> <title and detailed requirements>"
user-invocable: true
---

## Goal

Create one implementation-ready issue using
[New-GitHubIssue.ps1](scripts/New-GitHubIssue.ps1).

## Inputs

* `Title`: action-oriented issue title.
* `IssueType`: `feature`, `enhancement`, `bug`, or `documentation`.
* `Requirements`: non-empty Markdown body; alternatively supply an existing
  `RequirementsFile`.
  Read the matching outline in [issue templates](references/issue-templates.md).
* `Milestone`: optional exact open milestone title.
* `Repository`: optional `owner/name`; defaults to the current repository.

Ask for missing requirements, preserve the user's meaning, and leave unknowns
explicit. Exclude secrets and request sanitized replacements.

## Invocation

Run from the repository root:

```powershell
$Arguments = @{
    Title = $Title
    IssueType = $IssueType
    Requirements = $DraftBody
}
$Preview = & ./.github/skills/create-github-issue/scripts/New-GitHubIssue.ps1 @Arguments -WhatIf
```

## Outputs And Approval

* `MilestoneSelectionRequired`: ask the user to select from `OpenMilestones`,
  add that exact `Milestone` to the arguments, and preview again.
* `Preview`: show the resolved repository, type, milestone, and proposed body.
* `Created`: report `IssueUrl`, repository, type label, and milestone.
* Error: report the cause and stop; do not create missing metadata or substitute
  different inputs.

Only after explicit approval following a successful preview, rerun the same
arguments with the returned repository and milestone, without `-WhatIf`:

```powershell
$Arguments.Repository = $Preview.Repository
$Arguments.Milestone = $Preview.Milestone
$Created = & ./.github/skills/create-github-issue/scripts/New-GitHubIssue.ps1 @Arguments -Confirm:$false
```