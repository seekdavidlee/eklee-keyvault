---
name: unit-test-frontend
description: "Write and run frontend unit tests for React and TypeScript changes. Use when implementing or fixing UI components, hooks, utilities, or services; not for Playwright E2E testing."
---

## Goal

Cover changed frontend behavior with isolated, deterministic unit tests.
Success means relevant tests pass and the handoff identifies coverage,
executed checks, and any unverified behavior.

## Inputs And Test Authoring

Receive changed files, behavior, and criteria. Read applicable instructions,
nearby code/tests, and existing helpers. Cover relevant success, boundary,
validation, error/loading/empty/access-denied states, and regressions.
Assert observable behavior using accessible roles and realistic interactions,
not MUI internals, broad snapshots, or exact generated secrets.

Isolate HTTP, MSAL, browser APIs, and other services. Use minimal providers,
restore mocks/timers, and await async work without sleeps. No live identities,
APIs, or secrets. Playwright is not a unit-test substitute.

## Missing Tooling

Run [Initialize-FrontendUnitTests.ps1](scripts/Initialize-FrontendUnitTests.ps1)
when tooling is missing. It owns dependency/configuration setup and approved-source
checks; `-WhatIf` previews changes. Stop on `Blocked`; do not bypass source checks.
`Ready` or `Configured` permits test authoring/execution, not a passing test claim.
Broader refactors require approval.

```powershell
$Setup = & ./.github/skills/unit-test-frontend/scripts/Initialize-FrontendUnitTests.ps1
```

## Invocation

Run [Invoke-FrontendUnitTests.ps1](scripts/Invoke-FrontendUnitTests.ps1) from the
repository root with UI-relative test paths. The script owns path/tooling
validation, execution, and result checks; its parameter help defines options.

```powershell
$Result = & ./.github/skills/unit-test-frontend/scripts/Invoke-FrontendUnitTests.ps1 -TestFiles src/example.test.tsx -Build -Lint
```

## Handoff

Run affected type/lint checks and broaden test selection for shared changes.
Return test files, covered behavior, the script's status/commands/counts, and
remaining gaps. Only an executed `Passed` result satisfies the gate; distinguish
non-applicability from blocked setup. Repair only in-scope failures; do not
commit, publish, or deploy.