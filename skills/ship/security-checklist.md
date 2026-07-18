# Pre-ship security checklist

Check each item against the diff being shipped. Mark N/A only when the item genuinely doesn't apply to the change.

## Input & data

- [ ] Every external input (request body, query params, headers, webhooks, env) is validated at the boundary — schema-validated, not just typed.
- [ ] Database access uses parameterized queries / ORM bindings only — no string-built SQL anywhere in the diff.
- [ ] No unsafe deserialization of untrusted data (eval, Function, unvalidated JSON.parse into trusted paths).
- [ ] File uploads validate type, size, AND content (magic bytes, not just extension or Content-Type).

## Auth

- [ ] Every new endpoint/route verifies authentication.
- [ ] Every new endpoint/route verifies authorization — the caller may act on THIS resource, not just "is logged in".
- [ ] Session cookies set HttpOnly, Secure, and an appropriate SameSite.
- [ ] State-changing routes are protected against CSRF (token, SameSite strategy, or verified non-cookie auth).

## Secrets & leakage

- [ ] No secrets, tokens, or credentials in code, config files, or committed .env files.
- [ ] Nothing sensitive written to logs (passwords, tokens, PII, full request bodies on auth routes).
- [ ] Error responses don't leak internals — no stack traces, SQL, or file paths to clients.
- [ ] No sensitive data stored client-side (localStorage/sessionStorage tokens, secrets in bundle or public env vars).

## Surface hardening

- [ ] Dependencies added/updated in this change have been audited (`npm audit` / `yarn npm audit` / `pnpm audit` / `bun audit` per project).
- [ ] Rate limiting exists on expensive or abusable endpoints (auth, search, email/SMS senders, exports).
- [ ] Security headers in place where this change serves responses (CSP, X-Content-Type-Options, frame protections).
- [ ] Redirect targets are validated against an allowlist — no open redirects from user-supplied URLs.
