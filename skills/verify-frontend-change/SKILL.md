---
name: verify-frontend-change
description: Verify a UI change end-to-end in a running app before declaring it done. Use after implementing or modifying any user-facing UI (React/Next.js components, pages, styles, animations, React Native screens), or when the user asks whether a UI change actually works. Passing typecheck and tests alone is NOT verification for UI work.
---

Never report a UI change as complete based on a successful edit, typecheck, or test run alone. Verify it the way a human reviewer would — in the running app.

## Web (React / Next.js)

1. **Run it**: start the dev server (project's package manager) and open the affected page in the browser. If a browser tool is available (Chrome DevTools MCP, Playwright), drive it directly; otherwise ask the user to open the page and confirm.
2. **Interact with the change directly**: for a new or changed control (button, input, toggle, dialog), actually use it — click, type, submit — and confirm the expected state change. Capture before/after screenshots when the change is visual.
3. **Console must be clean**: zero new errors or warnings (hydration warnings count). Check the network tab for failed or duplicate requests introduced by the change.
4. **States, not just the happy path**: loading, empty, error, and disabled states of the changed surface; keyboard focus reaches and operates the control.
5. **Responsive check**: verify at a mobile viewport and desktop width — layout must not break or overflow at either.
6. **Animations**: if the change animates, watch it at 6x slowdown (DevTools) for jank, and confirm `prefers-reduced-motion` still yields a usable result.
7. **Performance (when perf-relevant)**: for changes touching page load, images, fonts, or large lists, run a performance trace / Lighthouse pass and check Core Web Vitals (LCP, CLS, INP) did not regress.

## React Native

Browser steps don't apply — verify in the iOS Simulator / Android emulator (or Expo Go):

1. Build/reload the app and navigate to the affected screen.
2. Interact with the change; confirm expected behavior and navigation.
3. Metro/console output clean — no new warnings (especially `key`, unhandled promise, or re-render warnings).
4. Check both platforms when the change touches platform-sensitive code (gestures, safe areas, keyboard handling).

## Rules

- If any step fails, fix the issue and rerun **from step 1** — do not hand back partially verified work.
- If the environment makes a step impossible (no simulator, no browser access), say exactly which steps were verified and which were not — never imply full verification.
- Quantify what you can: screenshot diffs, console error counts, CWV numbers. Quantitative checks make self-verification and `/goal` stop-conditions reliable.
