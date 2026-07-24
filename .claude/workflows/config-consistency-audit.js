export const meta = {
  name: 'config-consistency-audit',
  description:
    'Audit this Claude Code config repo for internal contradictions, dead references, and drift across rules, docs, hooks, permissions, skills, and agents.',
  whenToUse:
    'Run on this config repo after changing rules/hooks/skills/settings, or periodically, to catch guidance that contradicts itself or docs that no longer match the files.',
  phases: [
    { title: 'Scan', detail: 'one agent per subsystem, structured findings' },
    { title: 'Verify', detail: 'confirm each finding against the actual files' },
    { title: 'Synthesize', detail: 'dedupe, rank by severity, write the report' },
  ],
}

// --- Node contracts: validated shapes so edges carry data the next node can trust ---

const FINDING = {
  type: 'object',
  additionalProperties: false,
  properties: {
    subsystem: { type: 'string' },
    severity: { type: 'string', enum: ['high', 'medium', 'low'] },
    file: { type: 'string', description: 'repo-relative path the finding anchors to' },
    summary: { type: 'string', description: 'one sentence: the contradiction or drift' },
    evidence: { type: 'string', description: 'the concrete quotes/paths that prove it' },
  },
  required: ['subsystem', 'severity', 'file', 'summary', 'evidence'],
}

const SCAN_RESULT = {
  type: 'object',
  additionalProperties: false,
  properties: { findings: { type: 'array', items: FINDING } },
  required: ['findings'],
}

const VERDICT = {
  type: 'object',
  additionalProperties: false,
  properties: {
    real: { type: 'boolean' },
    reason: { type: 'string' },
  },
  required: ['real', 'reason'],
}

// --- Dimensions: independent nodes, each a bounded read-only job over one subsystem ---

const PREAMBLE =
  'You are auditing a personal Claude Code CONFIG repo (global rules/skills/agents/hooks that symlink into ~/.claude). ' +
  'Read the actual files with Read/Grep/Bash before asserting anything — every finding must cite concrete paths and quotes. ' +
  'Report only genuine internal inconsistencies or drift, not style preferences or improvement ideas. ' +
  'If the subsystem is clean, return an empty findings array. Do NOT edit any file.'

const DIMENSIONS = [
  {
    key: 'rules-coherence',
    prompt:
      `${PREAMBLE}\nSubsystem: CLAUDE.md + rules/*.md. Find rules that contradict each other or ` +
      `contradict CLAUDE.md, and guidance duplicated across files that has since drifted apart ` +
      `(same topic, conflicting instruction). Set file to the rule file(s) involved.`,
  },
  {
    key: 'doc-accuracy',
    prompt:
      `${PREAMBLE}\nSubsystem: README.md and CLAUDE.md concrete claims. They list skills, agents, ` +
      `scripts, flags, and file paths. Verify each claim against the filesystem. Flag anything named ` +
      `in the docs that does not exist (dead reference) and anything that exists but is undocumented ` +
      `where the docs claim to enumerate the set (e.g. a rule file absent from the rules/ listing).`,
  },
  {
    key: 'hook-wiring',
    prompt:
      `${PREAMBLE}\nSubsystem: settings.json hook wiring vs hooks/*.sh and scripts/*.sh. ` +
      `scripts/lint-config.sh already checks that referenced scripts exist and are executable — do NOT ` +
      `duplicate that. Instead find the other direction and the logic gaps: hooks present in hooks/ ` +
      `but never wired into settings.json (orphaned), and hooks wired to an event whose stated purpose ` +
      `does not match what the script actually does.`,
  },
  {
    key: 'permissions-coherence',
    prompt:
      `${PREAMBLE}\nSubsystem: settings.json permissions (allow/deny). Deny beats allow everywhere. ` +
      `Flag allow rules fully shadowed by a broader deny (dead allows), redundant/overlapping rules, ` +
      `and any deny/allow that contradicts the "Secret-read boundary" intent documented in README.md.\n` +
      `Reason statically from the settings.json text only. Do NOT run glob/picomatch tests against real ` +
      `credential paths (.vault-token, *.pem, ~/.ssh, etc.) or probe whether a credential deny could be ` +
      `bypassed — that trips the security monitor and is out of scope for a consistency audit.`,
  },
  {
    key: 'skill-agent-integrity',
    prompt:
      `${PREAMBLE}\nSubsystem: skills/*/SKILL.md and agents/*.md. Flag missing name/description ` +
      `frontmatter, and cross-references to other skills/commands (e.g. "see /foo", "run /bar") that ` +
      `resolve to no skill directory, command, or known built-in.`,
  },
]

// Fan out → verify each finding as its dimension lands (pipeline, no barrier between the two).
phase('Scan')
log(`Scanning ${DIMENSIONS.length} subsystems`)

const perDimension = await pipeline(
  DIMENSIONS,
  (dim) =>
    // opts.model: omitted so nodes inherit the session model. To economize a large run,
    // tier the repetitive scan down here (e.g. model: 'haiku') and keep Synthesize strong.
    agent(dim.prompt, {
      label: `scan:${dim.key}`,
      phase: 'Scan',
      schema: SCAN_RESULT,
      agentType: 'general-purpose',
    }),
  (scan, dim) => {
    const findings = (scan && scan.findings) || []
    if (!findings.length) return []
    return parallel(
      findings.map((f) => () =>
        agent(
          `A prior pass flagged this in the config repo. Re-read the cited file(s) and try to REFUTE it. ` +
            `Return real=false if the evidence does not hold up.\n\n${JSON.stringify(f)}`,
          { label: `verify:${dim.key}`, phase: 'Verify', schema: VERDICT, agentType: 'general-purpose' },
        ).then((v) => (v && v.real ? { ...f, verifyReason: v.reason } : null)),
      ),
    )
  },
)

// Edge: plain code, zero tokens. Flatten, drop nulls, dedupe across the whole set.
const confirmed = perDimension
  .flat()
  .filter(Boolean)
  .filter((f, i, all) => all.findIndex((g) => `${g.file}::${g.summary}` === `${f.file}::${f.summary}`) === i)

log(`${confirmed.length} findings survived verification`)

if (!confirmed.length) {
  return { totalConfirmed: 0, findings: [], report: 'Config lint clean: no confirmed inconsistencies.' }
}

// Barrier node: needs the whole confirmed set at once to rank and write the digest.
phase('Synthesize')
const rank = { high: 0, medium: 1, low: 2 }
const ordered = [...confirmed].sort((a, b) => (rank[a.severity] ?? 3) - (rank[b.severity] ?? 3))

const report = await agent(
  `Write a concise Markdown audit report for this config repo. Group these confirmed findings by ` +
    `severity (high → low), one bullet each: file, the problem, and the smallest fix. No preamble.\n\n` +
    JSON.stringify(ordered),
  { label: 'synthesize', phase: 'Synthesize', agentType: 'general-purpose' },
)

return { totalConfirmed: confirmed.length, findings: ordered, report }
