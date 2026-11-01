---
title: "Functional Review Criteria"
description: "Judgment criteria and report format for functional implementation review."
---

## Focus Areas

- Logic: control flow, boolean conditions, state transitions, return values,
  missing return paths, off-by-one errors, and arithmetic mistakes.
- Edge cases: null and empty values, boundaries, overflow, encoding, and
  timezone or locale assumptions.
- Error handling: uncaught or swallowed failures, cleanup, useful error
  context, and required retry or fallback behavior.
- Concurrency: races, deadlocks, shared mutable state, unsafe async patterns,
  and missing synchronization.
- Contracts: API usage, parameters, preconditions and postconditions,
  boundary types, interfaces, and schemas.
- Security: access control, secret handling, validation, injection, and
  applicable repository security requirements.
- Coverage: regression tests, failure paths, and evidence for each criterion.

## Scope And False Positives

Review proposed changes, not the entire codebase. Keep generated lockfiles,
minified bundles, source maps, binaries, and build outputs in the inventory,
but assess their dependency/security/runtime effects instead of reviewing
every generated line. Do not blanket-exclude authored configuration or docs.

Read enough callers, tests, comments, and configuration to establish intent.
Apply the narrowest applicable rule, including internal scope conditions;
a glob match alone does not establish a violation. Evaluate each file's role.
Flag style only when an explicit applicable standard is violated.

Require a concrete failure or violated contract: incorrect output, data loss,
crash, exposure, reliability failure, or an applicable explicit standard.
Keep cosmetic observations informational. Omit uncertain allegations; report
decision-critical missing evidence as a blocker. Batch large diffs without
omitting final proposed changes.

## Report

Lead with numbered findings ordered Critical, High, Medium, then Low. Each
includes a descriptive title, severity, category, file/line, concrete failure,
relevant current code, proposed replacement or patch, and an exposing test
where applicable. Explain the risk for security findings.

Then include:

- Total changed files and severity counts.
- Changed-files table: file, lines changed, risk, findings, and generated-file
  exclusions with their impact assessment. Authentication, security,
  persistence, and financial behavior are high risk; business logic and API
  boundaries are medium; cosmetic/utility changes are low unless impact
  warrants otherwise.
- Tests to add or update, executed results distinguished from supplied
  evidence, missing evidence, and useful positive observations.
- Snapshot identity and fingerprint, criterion coverage, finding dispositions,
  and verdict. State explicitly when no issues were found and disclose gaps.

If the user approves saving Markdown, include frontmatter with title,
description, date, branch, base, total findings, and severity counts.
