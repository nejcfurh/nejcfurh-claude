import { describe, expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { ACTIVE } from './register'

const NO_MODES = { modes: [] }

const stub = (on: On, run: { exitCode: number; stdout: string } | Error): void => {
  mock.env(on, { HOME: '/home/u' })
  on('process.run', ($, e) => {
    if (run instanceof Error) return { deny: run.message }
    expect(e.argv).toEqual(['bash', '/home/u/.claude/hooks/symlink-check.sh'])
    return { value: { ...run, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
}

describe('the config line in the desktop prompt footer', () => {
  test('says active, centred, when symlink-check reports nothing', async ($, on) => {
    stub(on, { exitCode: 0, stdout: '' })
    const ui = await $.ui.mount({ plugin: 'config-status', surface: 'desktop', component: 'SessionMode', props: NO_MODES })
    expect((await ui.find({ type: 'Text' }))?.text).toBe(ACTIVE)
    expect((await ui.find({ type: 'Box' }))?.props).toMatchObject({ justifyContent: 'center' })
  })

  test('keeps the mode labels the engine would show after the line', async ($, on) => {
    stub(on, { exitCode: 0, stdout: '' })
    const ui = await $.ui.mount({ plugin: 'config-status', surface: 'desktop', component: 'SessionMode', props: { modes: ['focus'] } })
    expect((await ui.find({ type: 'Text' }))?.text).toBe(`${ACTIVE} · focus`)
  })

  test('shows the drift symlink-check reports instead of the check mark', async ($, on) => {
    const drift = '[symlink-check] ~/.claude entries drifted or missing: hooks'
    stub(on, { exitCode: 0, stdout: `${drift}\n` })
    const ui = await $.ui.mount({ plugin: 'config-status', surface: 'desktop', component: 'SessionMode', props: NO_MODES })
    expect((await ui.find({ type: 'Text' }))?.text).toBe(`⚠ ${drift}`)
  })

  test('warns when symlink-check cannot run', async ($, on) => {
    stub(on, new Error('ENOENT'))
    const ui = await $.ui.mount({ plugin: 'config-status', surface: 'desktop', component: 'SessionMode', props: NO_MODES })
    expect((await ui.find({ type: 'Text' }))?.text).toBe('⚠ symlink-check.sh could not run: config links not verified')
  })
})
