---
description: 'Guidelines for building React applications with TypeScript, MUI, MSAL, and React Router'
applyTo: '**/Eklee.KeyVault.UI/**/*.ts, **/Eklee.KeyVault.UI/**/*.tsx'
---

## React Application Development

## React Instructions
- Target React 19 APIs and patterns.
- Prefer functional components, hooks, and TypeScript-first designs.
- Preserve the existing stack: Vite, MUI, React Router, MSAL, and axios.
- Explain non-obvious auth, async, and state-management decisions so the next
  maintainer understands why the pattern exists.

## General Instructions
- Make only high confidence suggestions when reviewing code changes.
- Keep components focused and compose behavior from hooks, providers, and
  service functions.
- Prefer changes that fit the existing architecture instead of introducing new
  libraries or parallel abstractions.
- Handle loading, error, empty, and access-denied states explicitly.
- Do not hardcode API endpoints, tenant identifiers, redirect URIs, or other
  environment-specific values.

## Project Setup and Structure

- Guide users through adding features within the existing
  `Eklee.KeyVault.UI/src` structure rather than inventing a parallel layout.
- Keep route-level pages in `src/pages`, shared layout and navigation in
  `src/components`, authentication concerns in `src/auth`, API wrappers in
  `src/services`, shared contracts in `src/types`, and runtime configuration in
  `src/config.ts`.
- Explain how `main.tsx` initializes MSAL and processes redirect responses
  before React renders.
- Explain how `App.tsx` composes MUI theme setup, routing, providers, and the
  app layout.

## Component Architecture

- Use functional components exclusively.
- Prefer named exports for components and hooks unless the surrounding file
  already uses a default export for framework integration.
- Keep components small enough that loading state, data fetching, and UI event
  handling remain understandable without excessive indirection.
- Extract repeated view logic into shared components or hooks when duplication
  is real, not hypothetical.
- Use JSDoc comments for exported components and helpers when the purpose is not
  obvious from the name alone.

## TypeScript and Type Safety

- Write React code in TypeScript and honor the strict compiler settings already
  enabled for the UI app.
- Prefer `import type` for type-only imports.
- Keep API contracts centralized in `src/types` and reuse those types across
  pages, components, and services.
- Avoid `any`, broad type assertions, and loosely typed event handlers.
- Type axios requests and responses explicitly with generics.
- Use discriminated unions, narrow helper functions, and precise nullable types
  instead of broad runtime checks.

## State Management and Context

- Use local component state for local UI behavior.
- Use Context only for cross-cutting state that must be shared broadly across
  the app, such as the current user's access information.
- Reuse the existing `UserProvider` and `useUser` pattern for role-aware UI and
  access checks.
- Do not introduce Redux, Zustand, MobX, or another global state library unless
  the user explicitly asks for that architectural shift.
- Prefer derived state over duplicated state whenever a value can be computed
  from existing props or state.

## Routing and Navigation

- Use React Router for all client-side navigation.
- Keep route definitions centralized in `App.tsx` unless a larger route module
  structure is clearly warranted.
- Gate routes with the existing role-aware and access-denied flow rather than
  duplicating authorization checks in multiple layers.
- Use `Navigate` for redirect behavior and prefer declarative routing over
  imperative navigation when either approach is equally clear.
- Keep unknown-route handling explicit.

## Authentication and Authorization

- Use the existing MSAL-based authentication flow.
- Initialize MSAL and await redirect handling before rendering the React tree so
  account and token state are ready on first render.
- Keep token acquisition inside the shared axios interceptor instead of adding
  ad hoc token logic to individual components.
- Use `AuthenticatedTemplate`, `UnauthenticatedTemplate`, `useIsAuthenticated`,
  and provider-based composition where appropriate.
- Do not store access tokens in local storage, session storage, or ad hoc custom
  caches.
- Explain why login redirect or silent token acquisition logic exists whenever
  the control flow is not obvious.

## API and Service Layer

- Keep HTTP calls in `src/services` instead of embedding fetch logic inside page
  components.
- Reuse the shared `apiClient` axios instance so authentication, headers, and
  base URL behavior stay consistent.
- Type every service response and request payload explicitly.
- URL-encode path parameters with `encodeURIComponent` before interpolating them
  into endpoint URLs.
- Keep service functions focused on transport and response typing. UI messaging,
  dialog state, and layout behavior belong in components.
- When the backend exposes optimistic concurrency data such as ETags, preserve
  that contract rather than bypassing it.

## Async Effects and Data Fetching

- Keep asynchronous logic predictable and explicit.
- When a component fetches data inside `useEffect`, clean up with a cancellation
  guard so state is not updated after unmount.
- Represent loading, success, and failure states explicitly in component state.
- Prefer small helper functions and service calls over large inline async blocks
  in JSX-heavy files.
- Handle expected authorization failures, such as HTTP 403, with typed guards or
  narrow helper functions instead of generic error text.

## MUI, Layout, and Responsive Design

- Use MUI components and theming patterns that match the existing app.
- Keep the shared theme in one place and apply it through `ThemeProvider`.
- Prefer `useTheme` and `useMediaQuery` for responsive behavior.
- Use `AppLayout`, `Sidebar`, and `MobileNav` patterns to keep navigation and
  layout behavior consistent across pages.
- Prefer MUI dialogs, alerts, snackbars, and data display components over ad
  hoc markup when the project already has a matching component pattern.
- Keep mobile and desktop behavior intentionally designed rather than relying on
  accidental layout wrapping.

## Forms and User Feedback

- Keep form state local to the feature unless it must be shared across screens.
- Prefer dialog-based editing flows when working inside the existing CRUD pages.
- Validate user input before submitting requests and surface actionable error
  messages.
- Use `Snackbar` and `Alert` patterns for transient success or failure feedback.
- Reset stale success and error messages when a new interaction begins.

## Error Handling and Resilience

- Handle expected error cases explicitly and keep fallback UI understandable.
- Use narrow error helpers when distinguishing between authorization failures,
  validation errors, and unexpected API failures.
- Avoid swallowing exceptions silently.
- Preserve user progress where practical instead of resetting the full screen for
  recoverable errors.
- When a failure path depends on authentication state, explain the behavior in
  comments so future changes do not reintroduce login races.

## Configuration and Environment Management

- Read frontend configuration through `src/config.ts`.
- Prefer runtime configuration from `window.__RUNTIME_CONFIG__` in deployed
  environments and `import.meta.env` for local development.
- Do not hardcode backend URLs, Entra application identifiers, or redirect URIs
  inside components or services.
- Keep configuration keys aligned with the existing `VITE_*` and runtime config
  naming conventions.
- Explain how runtime configuration supports deploying the same built artifact to
  multiple environments.

## Security

- Treat all data from APIs and user input as untrusted.
- Prefer React's default escaped rendering and avoid
  `dangerouslySetInnerHTML` unless the user explicitly requires sanitized HTML.
- Keep authentication and authorization logic centralized in the existing MSAL
  and API layers.
- Never hardcode secrets, tokens, or confidential environment values in the UI.
- Use HTTPS endpoints in configuration and preserve secure redirect flows.
- When rendering links or URLs derived from data, validate intent and avoid
  introducing open redirect or script injection behavior.

## Testing

- Include test coverage for critical user flows when a frontend test harness is
  present or when adding one is part of the requested work.
- Prioritize tests around authentication boundaries, role-gated routes, form
  submission behavior, service integration boundaries, and error states.
- Prefer component and behavior-focused tests over implementation-detail tests.
- When proposing a new test stack for the UI, favor tools that fit the Vite and
  React ecosystem, such as Vitest and React Testing Library.
- Keep mocks narrow and realistic, especially around MSAL and API responses.

## Performance Optimization

- Keep renders cheap by colocating state, avoiding unnecessary shared state, and
  only memoizing when there is a clear benefit.
- Do not add `useMemo` or `useCallback` by default. Use them when referential
  stability or measured rendering cost justifies the extra complexity.
- Use `useCallback` for handlers that are passed deeply or relied upon by child
  optimizations.
- Consider `startTransition` or `useDeferredValue` when a user interaction must
  stay responsive during expensive UI updates.
- Keep large table and list views efficient by reusing MUI DataGrid patterns and
  avoiding repeated data reshaping during render.

## Documentation and Maintainability

- Explain architectural decisions alongside code examples so users understand why
  a pattern is preferred.
- Write comments that explain intent, race-condition avoidance, or security
  constraints rather than narrating obvious syntax.
- Keep naming clear and domain-oriented across pages, services, hooks, and
  types.
- When introducing a new pattern, show how it fits with the existing app instead
  of presenting it in isolation.