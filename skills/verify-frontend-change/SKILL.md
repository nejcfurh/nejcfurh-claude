---
name: verify-frontend-change
description: Verify a UI change end-to-end in a running app before declaring it done. Use after implementing or modifying any user-facing UI (React/Next.js components, pages, styles, animations, React Native screens), or when the user asks whether a UI change actually works. Passing typecheck and tests alone is NOT verification for UI work.
---

Never report a UI change as complete based on a successful edit, typecheck, or test run alone. Verify it the way a human reviewer would — in the running app.

## First: is in-app verification reachable?

Before starting a dev server or writing any workaround, check whether the app can actually be driven here. It **cannot** when the affected surface is auth-gated (or behind a flag/paywall), **and** no local backend is running to authenticate against, **and** no browser tool is available. When that is the case, stop — do not engineer your way in:

- **Never fabricate access.** Do not edit auth guards, redirects, route protection, or feature flags to reach a screenshot (e.g. adding `&& false` to a `!user` redirect), and do not stub out data loading. A view reached by altering the code under test verifies nothing, and the bypass can leak into the commit.
- **Prefer the preview deployment.** If the branch gets a preview/staging deploy (Vercel, Netlify, a review app), that is where to eyeball an auth-gated surface — record it as the verification path.
- **Otherwise report and defer.** State exactly which steps you could and could not verify (see Rules) and ask the user to confirm visually. A deferred visual check is fine; a fabricated one is not.

## Web (React / Next.js)

1. **Run it**: start the dev server (project's package manager) and open the affected page in the browser. If a browser tool is available (Chrome DevTools MCP, Playwright), drive it directly; otherwise ask the user to open the page and confirm.
2. **Interact with the change directly**: for a new or changed control (button, input, toggle, dialog), actually use it — click, type, submit — and confirm the expected state change. Capture before/after screenshots when the change is visual.
   - **Read each changed region cropped at native size**, not the full-page capture scaled to fit: a few pixels of misalignment, a wrap or a clipped edge disappear at thumbnail scale and are obvious to a reader at 1:1.
   - **Where a row mixes type sizes** (a large letter or number beside smaller text, an icon beside a label), check that the text baselines line up. A flex row aligns top edges unless told to align baselines, so the larger text sits visibly low. Measure it when in doubt: a zero-height inline-block appended at the start of each text element reports its first-line baseline.
3. **Console must be clean**: zero new errors or warnings (hydration warnings count). Check the network tab for failed or duplicate requests introduced by the change.
4. **States, not just the happy path**: loading, empty, error, and disabled states of the changed surface; keyboard focus reaches and operates the control.
5. **Responsive check**: verify at a mobile viewport and desktop width — layout must not break or overflow at either.
6. **Theme check**: if the app supports dark mode (a theme toggle, `darkMode: 'class'`, or `prefers-color-scheme` styles), verify the change in BOTH themes — projects with custom palettes can make standard utility classes render pale-on-pale. Treat low-contrast or "washed out" text in your own screenshots as a failing finding, never as rendering noise to gloss over.
7. **Animations**: if the change animates, watch it at 6x slowdown (DevTools) for jank, and confirm `prefers-reduced-motion` still yields a usable result.
8. **Performance (when perf-relevant)**: for changes touching page load, images, fonts, or large lists, run a performance trace / Lighthouse pass and check Core Web Vitals (LCP, CLS, INP) did not regress.

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
