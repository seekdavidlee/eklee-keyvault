---
name: create-github-issue
description: "Create one detailed GitHub enhancement, bug, or documentation issue with the bundled PowerShell script. Use when a contributor wants to file a repository issue and supply its requirements."
argument-hint: "<enhancement|bug|documentation> <title and detailed requirements>"
user-invocable: true
---

## Goal

Create one implementation-ready GitHub issue from the user's detailed
requirements. The bundled script is the source of truth for GitHub CLI
preflight, repository resolution, label validation, milestone selection, and
issue creation.

## Required Input

Obtain these values before previewing:

* Issue type: exactly `enhancement`, `bug`, or `documentation`.
* Title: a clear, action-oriented issue title.
* Detailed requirements: enough information to state the problem or objective,
  scope, required behavior, acceptance criteria, dependencies, and relevant
  context.
* Milestone: optional only for the first preview. The script selects the sole
  open milestone automatically and reports choices when more than one is open.
* Repository: optional `owner/name`; omit it to use the current repository.

Ask only for information that is missing or ambiguous. Preserve the user's
meaning, mark any assumptions clearly, and do not include passwords, tokens,
keys, or other secrets in the issue body.

## Issue Body

Turn the detailed requirements into Markdown using the appropriate sections:

### For an enhancement or general issue

```markdown
## Problem or Use Case

## Proposed Solution

## Alternatives Considered

## Acceptance Criteria

## Additional Context
```

### For a bug

```markdown
## Bug Description

## Expected Behavior

## Steps to Reproduce

## Environment

## Logs or Screenshots

## Additional Context
```

### For documentation

```markdown
## Objective

## Problem or User Need

## Scope

## Requirements

## Acceptance Criteria

## Dependencies

## Additional Context
```

Do not invent technical requirements, acceptance criteria, or dependencies
that the user did not provide; keep unanswered items explicit.

## Workflow

1. Write the generated Markdown to a uniquely named temporary file. Keep it
   outside the repository and remove it after the workflow finishes.

2. From the repository root, preview the request with the bundled script.
   Build the argument array so `-Milestone` and `-Repository` are included only
   when the user supplied them.

   ```powershell
   $ScriptPath = '.\.github\skills\create-github-issue\scripts\New-GitHubIssue.ps1'
   $Arguments = @(
       '-Title', $Title,
       '-IssueType', $IssueType,
       '-RequirementsFile', $RequirementsFile,
       '-WhatIf'
   )

   if ($Milestone) {
       $Arguments += @('-Milestone', $Milestone)
   }

   if ($Repository) {
       $Arguments += @('-Repository', $Repository)
   }

   $Preview = & $ScriptPath @Arguments
   ```

3. Handle the preview result:

   * `MilestoneSelectionRequired`: Present only the returned `OpenMilestones`
     values, collect one exact title, and rerun the preview with that value.
   * `Preview`: Present the resolved `Repository`, `IssueType`, and
     `Milestone`. Do not create the issue yet.
   * An error: Report its actionable cause. Do not retry with different labels,
     milestones, or repository values unless the user changes the input.

4. Create the issue only after the user explicitly asks to do so after seeing a
   successful preview. Reuse the preview arguments without `-WhatIf` and add
   `-Confirm:$false`; the explicit user request is required before this call.

   ```powershell
   $CreateArguments = $Arguments | Where-Object { $_ -ne '-WhatIf' }
   $Created = & $ScriptPath @CreateArguments -Confirm:$false
   ```

5. Report the returned `IssueUrl`, repository, label, and milestone. Clean up
   the temporary requirements file whether previewing succeeds or fails.

## Script Contract

`New-GitHubIssue.ps1` accepts:

```powershell
New-GitHubIssue.ps1 -Title <string> -IssueType <enhancement|bug|documentation> `
    -RequirementsFile <path> [-Milestone <open milestone title>] `
    [-Repository <owner/repo>] [-WhatIf]
```

It checks GitHub CLI availability and authentication, validates a non-empty
requirements file and the requested repository label, lists open milestones,
and passes the canonical repository and selected milestone to `gh issue
create`. It creates no issue when `-WhatIf` is present.

## Stop Rules

Stop and report the result when:

* The user cannot provide a supported type, a title, or sufficiently detailed
  requirements.
* The supplied requirements contain a secret. Exclude it from the temporary
  body and ask for a sanitized replacement before continuing.
* There is no open milestone, the selected label is absent, or an explicitly
  named milestone is not open.
* GitHub CLI authentication or repository permissions fail.
* The user has not explicitly asked for the live creation after the preview.

Do not create labels, milestones, projects, or additional issues as a
workaround.

## Success Criteria

The completed workflow returns one GitHub issue URL with exactly one requested
type label, a validated open milestone, and an issue body that reflects the
user's detailed requirements.