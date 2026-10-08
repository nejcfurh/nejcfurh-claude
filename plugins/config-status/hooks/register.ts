import type { EngineInterface, Register, RenderElement } from 'claude-code'

export const ACTIVE = "⚡ Nejc's config initiated ✓"

// symlink-check.sh prints nothing when every ~/.claude link points into the
// config repo, so empty output is the only state that earns the check mark.
const check = async ($: EngineInterface): Promise<string> => {
  const home = await $.env.get('HOME')
  if (!home) return '⚠ HOME is unset: config links not verified'

  try {
    const { exitCode, stdout } = await $.process.run(['bash', `${home}/.claude/hooks/symlink-check.sh`])
    const problem = stdout.trim()
    if (exitCode === 0 && problem === '') return ACTIVE
    return `⚠ ${problem || `symlink-check.sh exited ${exitCode}`}`
  } catch {
    return '⚠ symlink-check.sh could not run: config links not verified'
  }
}

const isElement = (node: unknown): node is RenderElement =>
  typeof node === 'object' && node !== null && !Array.isArray(node)

export const register: Register = on => {
  // Drawn in the footer's mode-label slot rather than $.ui.status, whose row
  // the desktop app leads with the plugin name and does not centre; the
  // desktop app does not draw PromptHint at all.
  let line: Promise<string> | undefined

  on('ui.render', { component: 'SessionMode' }, async ($, e, next) => {
    if (e.surface !== 'desktop') return next(e)

    line ??= check($)
    const { Box, Text } = $.ui.resolve(e)
    const text = [await line, ...e.props.modes].join(' · ')

    const tree = h(Box, { width: '100%', justifyContent: 'center' }, h(Text, { dimColor: true }, text))
    return isElement(tree) ? tree : next(e)
  })
}
