---
name: unit-test-backend
description: "Write and run backend unit tests for C# API changes using the repository's xUnit setup. Use for service, controller, validation, and authorization decision logic; not hosted E2E tests."
---

## Goal

Cover changed backend behavior with isolated, deterministic unit tests.
Success means relevant tests pass and the handoff identifies coverage,
executed checks, and any unverified behavior.

## Inputs And Test Authoring

Receive changed files, behavior, and criteria. Under applicable C# and test
instructions, reuse the existing test project, xUnit conventions, and helpers.
Cover changed public contracts, boundaries, failure/permission decisions, and
regressions. Direct controller tests do not prove endpoint authorization.

Keep tests isolated from live services, credentials, production secrets, and
shared state. Assert generated-secret invariants, not random values; await
async work without sleeps. New dependencies or broader testability refactors
require approval and approved package sources.

## Invocation

Run [Invoke-BackendUnitTests.ps1](scripts/Invoke-BackendUnitTests.ps1) from the
repository root with a required `Filter` selecting isolated tests. `RepoRoot`
is optional; `-WhatIf` previews the command.

```powershell
$Result = & ./.github/skills/unit-test-backend/scripts/Invoke-BackendUnitTests.ps1 -Filter 'FullyQualifiedName~SecretGenerationServiceTests'
```

Select by actual behavior, not filenames. Broaden the filter when shared
behavior changes. For unsupported test platforms, use `run-tests` to update
the referenced runner rather than bypass it.

## Outputs And Boundaries

`Passed` includes command arguments and test counts. `Preview` is not executed
evidence; errors block the gate.
Return test files, covered behavior, exact commands/results, and remaining gaps.
Explain justified non-applicability without manufacturing tests for docs.

Repair only in-scope failures. Integration/hosted tests require separate
authorization and prerequisites. This skill does not authorize commits,
publication, deployment, or broader production changes.