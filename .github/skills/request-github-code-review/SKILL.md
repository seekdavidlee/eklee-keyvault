---
name: request-github-code-review
description: "Kick off GitHub Copilot code review on a verified existing PR after local review and PR creation. Use to request the remote code review agent, not the coding agent."
---

## Goal

Request code review on the verified PR returned by
[PR creation](../create-pull-request/SKILL.md), using
[Request-CopilotReview.ps1](scripts/Request-CopilotReview.ps1).

## Inputs And Invocation

Supply `Repository`, `Number`, `Source`, `Base`, and reviewed published `Head`
from the passing PR handoff. `RepoRoot` is optional. Run from the repository root:

```powershell
$Arguments = @{
    Repository = $Repository
    Number = $PrNumber
    Source = $Source
    Base = $Base
    Head = $ReviewedHead
}
$Preview = & ./.github/skills/request-github-code-review/scripts/Request-CopilotReview.ps1 @Arguments -WhatIf
```

With authorization to request remote review on this PR, rerun the same inputs
without `-WhatIf` and with `-Confirm:$false`. Add `-ReReview` only after
explicit approval to repeat a completed review of the same head.

## Outputs

* `Preview`: ready for an authorized request.
* `AlreadyPending`: no duplicate request was made.
* `ReReviewApprovalRequired`: report the existing review and ask before repeating.
* `Requested`: a pending request or new same-head review was observed.
* `Blocked` or error: report the evidence or cause without claiming success.

Return status, PR URL, branch pair, head, and observed evidence. Changed content
goes back through local review. On uncertainty, rerun the preview before any
write. Stop after kickoff, not review completion; acceptance is not approval.
Do not invoke the coding agent, merge, or auto-apply suggestions.

## Reference

The official [Copilot code review guide](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/request-a-code-review/use-code-review)
documents the remote code-review capability.