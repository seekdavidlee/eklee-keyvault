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
APIs, or secrets. Add and configure tooling required for frontend unit tests
automatically when missing, keeping dependency and configuration changes scoped
to those tests. Broader refactors still require approval. Consult current API
documentation before adding tooling.

Use the UI's configured approved package sources without asking for source
approval again. Verify the effective registry, including applicable scoped
overrides, matches that configuration before installing packages. If it differs
or required packages are unavailable there, report `Blocked`; never change
registries or fall back to another source.
Playwright is not a unit-test substitute.

## Invocation

Run [Invoke-FrontendUnitTests.ps1](scripts/Invoke-FrontendUnitTests.ps1) from the
repository root. `TestFiles` are required UI-relative existing unit-test paths.
`Build` adds the configured build/type check, `Lint` adds lint, and `RepoRoot`
is optional. `-WhatIf` previews supported commands.

```powershell
$Result = & ./.github/skills/unit-test-frontend/scripts/Invoke-FrontendUnitTests.ps1 -TestFiles src/example.test.tsx -Build -Lint
```

## Outputs And Boundaries

`Passed` includes executed commands and counts. `Blocked` reports missing or
unsupported tooling. `Preview` is not execution evidence. Errors block the gate.

Return test files, covered behavior, exact commands/results, and remaining
gaps. Run affected type/lint checks and broaden test selection for shared
changes. Explain justified non-applicability separately from missing tools.
Repair only in-scope failures; do not commit, publish, deploy, or substitute
integration/E2E results for unit tests.