import { describe, expect, test } from 'bun:test'
import { readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'

// `.bun-version` is the runtime advertised to developer tooling, Bun version
// managers, and tau's own sandbox images ("install whatever .bun-version
// says"). CI, however, ignores `.bun-version` entirely — every workflow pins
// `oven-sh/setup-bun` explicitly. If the two drift, `.bun-version` names a
// runtime CI never validates. That is exactly how Bun 1.3.11 — which segfaults
// loading this repo's test graph before any test runs (the AMTP
// node-conformance suite is the canary) — sat in `.bun-version` while CI only
// ever ran 1.3.8. This gate fails closed the moment they diverge, so any future
// bump has to move both sides together.

interface Step {
  uses?: string
  with?: Record<string, unknown>
}

interface Workflow {
  jobs?: Record<string, { steps?: Step[] }>
}

export interface SetupBunPin {
  file: string
  job: string
  version: string
}

const repoRoot = join(import.meta.dir, '..')
const workflowsDir = join(import.meta.dir, 'workflows')

function readBunVersion(): string {
  return readFileSync(join(repoRoot, '.bun-version'), 'utf8').trim()
}

function collectSetupBunPins(dir: string = workflowsDir): SetupBunPin[] {
  const pins: SetupBunPin[] = []
  for (const entry of readdirSync(dir).sort()) {
    if (!entry.endsWith('.yml') && !entry.endsWith('.yaml')) continue
    const workflow = Bun.YAML.parse(readFileSync(join(dir, entry), 'utf8')) as Workflow
    for (const [job, definition] of Object.entries(workflow.jobs ?? {})) {
      for (const step of definition.steps ?? []) {
        if (!step.uses?.startsWith('oven-sh/setup-bun')) continue
        // A setup-bun step with no explicit `bun-version` silently tracks
        // whatever "latest" the action ships — an unpinned runtime CI never
        // decided on. Record it as an empty pin so the gate flags it.
        pins.push({ file: entry, job, version: String(step.with?.['bun-version'] ?? '') })
      }
    }
  }
  return pins
}

function validateBunVersionAlignment(bunVersion: string, pins: SetupBunPin[]): string[] {
  const errors: string[] = []
  // No pins means the action was renamed or the parser stopped matching, which
  // would let this gate pass vacuously. Fail instead.
  if (pins.length === 0) {
    errors.push('no oven-sh/setup-bun pins found — the gate cannot vacuously pass')
    return errors
  }
  for (const pin of pins) {
    if (pin.version !== bunVersion) {
      errors.push(
        `${pin.file} job "${pin.job}" pins bun-version ${JSON.stringify(pin.version)}, ` +
          `but .bun-version is ${JSON.stringify(bunVersion)} — keep them in lockstep`
      )
    }
  }
  return errors
}

// The setup toolkit installs bun on hosts the repo checkout does not exist on
// yet (tenant VMs, the control plane), so each script carries a literal
// FICUS_BUN_VERSION pin instead of reading .bun-version. Literals drift — an
// UNPINNED `curl | bash` install in these very scripts took down provisioning
// for every new tenant on 2026-08-13 when bun released 1.3.14 (broken .env
// loading for `bun run db:migrate`). This gate makes the literals unable to
// drift silently.
const SETUP_SCRIPTS_WITH_BUN_PIN = ['scripts/setup/setup-host.sh']

export function collectSetupScriptPins(): SetupBunPin[] {
  const pins: SetupBunPin[] = []
  for (const script of SETUP_SCRIPTS_WITH_BUN_PIN) {
    const source = readFileSync(join(repoRoot, script), 'utf8')
    const matches = [...source.matchAll(/^\s*FICUS_BUN_VERSION="([^"]*)"/gm)]
    // A script with no pin at all means the literal was deleted (or renamed) —
    // which is indistinguishable from reverting to the unpinned install. Fail.
    if (matches.length === 0) {
      pins.push({ file: script, job: 'FICUS_BUN_VERSION (missing)', version: '' })
      continue
    }
    for (const match of matches) {
      pins.push({ file: script, job: 'FICUS_BUN_VERSION', version: match[1] })
    }
    // The pin is only load-bearing if the installer actually consumes it.
    if (!source.includes('bash -s "bun-v${FICUS_BUN_VERSION}"')) {
      pins.push({ file: script, job: 'installer does not consume FICUS_BUN_VERSION', version: '' })
    }
  }
  return pins
}

function bareBunTestPaths(command: string): string[] {
  const matches = command.matchAll(/(?:^|[;&|]\s*)bun\s+test\s+((?:apps|packages|\.github)\/\S+)/gm)
  return [...matches].map((match) => match[1])
}

describe('bun direct test paths', () => {
  test('requires explicit relative paths for scripted root test commands', () => {
    expect(bareBunTestPaths('bun test apps/core/src/example.test.ts')).toEqual(['apps/core/src/example.test.ts'])
    expect(bareBunTestPaths('bun test ./apps/core/src/example.test.ts')).toEqual([])
    expect(bareBunTestPaths('cd apps/core && bun test src/example.test.ts')).toEqual([])
    expect(bareBunTestPaths('echo ready\nbun test apps/core/src/known-bad.test.ts')).toEqual([
      'apps/core/src/known-bad.test.ts',
    ])
  })

  test('repository scripts do not use Bun 1.3.8-ambiguous root direct paths', () => {
    const packageJson = readFileSync(join(repoRoot, 'package.json'), 'utf8')
    const workflowSources = readdirSync(workflowsDir)
      .filter((entry) => entry.endsWith('.yml') || entry.endsWith('.yaml'))
      .map((entry) => readFileSync(join(workflowsDir, entry), 'utf8'))
    expect(bareBunTestPaths([packageJson, ...workflowSources].join('\n'))).toEqual([])
  })
})

describe('bun version pin', () => {
  test('every workflow pins the exact version .bun-version advertises', () => {
    expect(validateBunVersionAlignment(readBunVersion(), collectSetupBunPins())).toEqual([])
  })

  test('every setup-toolkit script pins the exact version .bun-version advertises', () => {
    expect(validateBunVersionAlignment(readBunVersion(), collectSetupScriptPins())).toEqual([])
  })

  test('flags a setup script whose pin was deleted', () => {
    // collectSetupScriptPins represents a missing literal as an empty-version
    // pin, which the validator rejects — proven by the flags-an-unpinned case
    // below. This pins the *representation* so a refactor cannot quietly turn
    // "pin deleted" into "script skipped".
    const errors = validateBunVersionAlignment('1.3.8', [
      { file: 'scripts/setup/setup-host.sh', job: 'FICUS_BUN_VERSION (missing)', version: '' },
    ])
    expect(errors).toHaveLength(1)
    expect(errors[0]).toContain('setup-host.sh')
  })

  test('at least one workflow actually pins setup-bun', () => {
    expect(collectSetupBunPins().length).toBeGreaterThan(0)
  })

  test('flags a workflow pinned to a different version', () => {
    const errors = validateBunVersionAlignment('1.3.8', [
      { file: 'ci.yml', job: 'test', version: '1.3.8' },
      { file: 'lint.yml', job: 'lint', version: '1.3.11' },
    ])
    expect(errors).toHaveLength(1)
    expect(errors[0]).toContain('lint.yml')
    expect(errors[0]).toContain('1.3.11')
  })

  test('flags .bun-version drifting ahead of the pins', () => {
    const errors = validateBunVersionAlignment('1.3.11', [{ file: 'ci.yml', job: 'test', version: '1.3.8' }])
    expect(errors).toHaveLength(1)
    expect(errors[0]).toContain('.bun-version is "1.3.11"')
  })

  test('flags an unpinned setup-bun step', () => {
    const errors = validateBunVersionAlignment('1.3.8', [{ file: 'ci.yml', job: 'test', version: '' }])
    expect(errors).toHaveLength(1)
  })

  test('fails closed when no setup-bun pins are discovered', () => {
    expect(validateBunVersionAlignment('1.3.8', [])).toEqual([
      'no oven-sh/setup-bun pins found — the gate cannot vacuously pass',
    ])
  })
})

// Bun invokes Node-shebang tools during installs and builds (Astro, Expo, Pi).
// A job without setup-node silently inherits the runner's version: local-setup
// inherited Node 20 and failed as soon as Core began building embedded docs.
test('every Bun CI job selects Node 24 before dependency scripts can run', () => {
  let checked = 0
  for (const file of readdirSync(workflowsDir).filter((name) => /\.ya?ml$/.test(name))) {
    const workflow = Bun.YAML.parse(readFileSync(join(workflowsDir, file), 'utf8')) as Workflow
    for (const [job, definition] of Object.entries(workflow.jobs ?? {})) {
      const steps = definition.steps ?? []
      const bun = steps.findIndex((step) => step.uses?.startsWith('oven-sh/setup-bun'))
      if (bun < 0) continue
      checked++
      const node = steps.findIndex((step) => step.uses?.startsWith('actions/setup-node'))
      expect(node, `${file}: ${job} needs an explicit Node runtime`).toBeGreaterThanOrEqual(0)
      expect(node, `${file}: ${job} must select Node before Bun dependency scripts`).toBeLessThan(bun)
      expect(String(steps[node]?.with?.['node-version']), `${file}: ${job}`).toBe('24')
    }
  }
  expect(checked).toBeGreaterThan(0)
})
