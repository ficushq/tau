import { describe, expect, it } from 'bun:test'
import { copyFileSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { EnvPrefixConflictError } from '@ficus/shared/legacy-env'
import { mergeEnvFile, parseEnvFile } from './env-file'
import { generateEcosystem, instanceNames } from './instance'
import { recordingRunner } from './runner'
import { buildSteps, computeEnvUpdates, SetupFailure, type StepDeps } from './steps'
import type { SetupOptions } from './types'

const REPO_ROOT = join(__dirname, '../../../../')

const secrets = { hex32: () => 'aa'.repeat(32), token: () => 'tok' }
function opts(partial: Partial<SetupOptions> = {}): SetupOptions {
  return {
    root: '/r',
    runtime: 'host',
    supervisor: 'pm2',
    port: 3000,
    apiUrl: 'http://localhost:3000',
    appUrl: 'http://localhost:3000',
    databaseMode: 'compose',
    databaseUrl: 'postgres://postgres:postgres@localhost:5432/tau',
    dbName: 'tau',
    instance: 'tau',
    makeDefault: false,
    start: true,
    dryRun: false,
    yes: false,
    rebuildImage: false,
    explicit: new Set(),
    ...partial,
  }
}

describe('computeEnvUpdates', () => {
  it('maps host options onto the managed keys with explicit flags only where the operator chose', () => {
    const updates = computeEnvUpdates(opts({ explicit: new Set(['runtime', 'port']) }), secrets)
    const byKey = Object.fromEntries(updates.map((u) => [u.key, u]))
    expect(byKey.FICUS_SANDBOX_RUNTIME).toEqual({ key: 'FICUS_SANDBOX_RUNTIME', value: 'host', explicit: true })
    expect(byKey.PORT).toEqual({ key: 'PORT', value: '3000', explicit: true })
    expect(byKey.FICUS_API_URL.explicit).toBe(true)
    expect(byKey.APP_URL.explicit).toBe(true)
    expect(byKey.FICUS_WEB_ORIGIN.value).toBe('http://localhost:3000')
    expect(byKey.FICUS_ENCRYPTION_KEY).toEqual({ key: 'FICUS_ENCRYPTION_KEY', value: 'aa'.repeat(32), explicit: false })
    expect(byKey.FICUS_INTERNAL_EVENT_TOKEN.explicit).toBe(false)
    expect(byKey.FICUS_PASSWORD).toEqual({ key: 'FICUS_PASSWORD', value: 'tok', explicit: false })
    expect(byKey.FICUS_SERVE_WEB.value).toBe('1')
    expect(byKey.FICUS_SYSTEM_LOG_PROVIDER.value).toBe('pm2')
    expect(byKey.DATABASE_URL.explicit).toBe(false)
    expect(byKey.HOME_DIR).toBeUndefined()
    expect(byKey.FICUS_K8S_LOCAL).toBeUndefined()
  })
  it('writes the k3d block for the k3d runtime', () => {
    const byKey = Object.fromEntries(computeEnvUpdates(opts({ runtime: 'k3d' }), secrets).map((u) => [u.key, u]))
    expect(byKey.FICUS_SANDBOX_RUNTIME.value).toBe('k8s')
    expect(byKey.FICUS_K8S_LOCAL.value).toBe('true')
    expect(byKey.FICUS_K8S_NAMESPACE.value).toBe('tau-sandboxes-dev')
    expect(byKey.FICUS_K8S_RUNTIME_CLASS.value).toBe('')
  })

  // FICUS_K8S_LOCAL only means anything under the k8s runtime, and a checkout
  // that moves off k3d keeps the line: leaving it in place used to make the
  // in-app updater treat a host install as local k3d forever.
  it('blanks a stale FICUS_K8S_LOCAL when the chosen runtime is not k3d', () => {
    const before = 'FICUS_SANDBOX_RUNTIME=k8s\nFICUS_K8S_LOCAL=true\nFICUS_K8S_NAMESPACE=tau-sandboxes-dev\n'
    const logged: string[] = []
    const updates = computeEnvUpdates(opts({ runtime: 'host' }), secrets, {
      existingEnv: before,
      log: (line) => logged.push(line),
    })
    const byKey = Object.fromEntries(updates.map((u) => [u.key, u]))
    expect(byKey.FICUS_K8S_LOCAL).toEqual({ key: 'FICUS_K8S_LOCAL', value: '', explicit: true })
    // Explicit, so the merge actually rewrites the line rather than keeping
    // the existing non-empty value.
    expect(parseEnvFile(mergeEnvFile(before, updates)).FICUS_K8S_LOCAL).toBe('')
    // The other two keys are harmless once the runtime gates them.
    expect(byKey.FICUS_K8S_NAMESPACE).toBeUndefined()
    expect(byKey.FICUS_K8S_RUNTIME_CLASS).toBeUndefined()
    expect(logged).toEqual(['warning: clearing stale FICUS_K8S_LOCAL from .env (it applies only to the k8s runtime)'])
  })

  it('leaves a FICUS_K8S_LOCAL that is not "true" alone — only the stale k3d value is cleared', () => {
    const logged: string[] = []
    const byKey = Object.fromEntries(
      computeEnvUpdates(opts({ runtime: 'host' }), secrets, {
        existingEnv: 'FICUS_K8S_LOCAL=false\n',
        log: (line) => logged.push(line),
      }).map((u) => [u.key, u])
    )
    expect(byKey.FICUS_K8S_LOCAL).toBeUndefined()
    expect(logged).toEqual([])
  })

  it('leaves the k3d block alone when k3d is chosen on a checkout that already has it', () => {
    const logged: string[] = []
    const byKey = Object.fromEntries(
      computeEnvUpdates(opts({ runtime: 'k3d' }), secrets, {
        existingEnv: 'FICUS_K8S_LOCAL=true\n',
        log: (line) => logged.push(line),
      }).map((u) => [u.key, u])
    )
    expect(byKey.FICUS_K8S_LOCAL.value).toBe('true')
    expect(byKey.FICUS_K8S_NAMESPACE.value).toBe('tau-sandboxes-dev')
    expect(logged).toEqual([])
  })

  it('proposes no FICUS_K8S_LOCAL update on a checkout with no .env', () => {
    const logged: string[] = []
    const byKey = Object.fromEntries(
      computeEnvUpdates(opts({ runtime: 'host' }), secrets, { log: (line) => logged.push(line) }).map((u) => [u.key, u])
    )
    expect(byKey.FICUS_K8S_LOCAL).toBeUndefined()
    expect(logged).toEqual([])
  })

  it('includes HOME_DIR only when given, and marks db keys explicit when chosen', () => {
    const byKey = Object.fromEntries(
      computeEnvUpdates(
        opts({
          homeDir: '~/.tau2',
          dbName: 'tau2',
          databaseUrl: 'postgres://postgres:postgres@localhost:5432/tau2',
          explicit: new Set(['homeDir', 'dbName']),
        }),
        secrets
      ).map((u) => [u.key, u])
    )
    expect(byKey.HOME_DIR).toEqual({ key: 'HOME_DIR', value: '~/.tau2', explicit: true })
    expect(byKey.DATABASE_URL).toEqual({
      key: 'DATABASE_URL',
      value: 'postgres://postgres:postgres@localhost:5432/tau2',
      explicit: true,
    })
  })
})

describe('computeEnvUpdates (instances)', () => {
  it('derives the worker ports and leaves HOME_DIR unset for the default instance', () => {
    const byKey = Object.fromEntries(computeEnvUpdates(opts(), secrets).map((u) => [u.key, u]))
    // Not explicit: a re-run without --instance must never relabel a checkout.
    expect(byKey.FICUS_INSTANCE).toEqual({ key: 'FICUS_INSTANCE', value: 'tau', explicit: false })
    expect(byKey.WORKER_PORT.value).toBe('3002')
    expect(byKey.FICUS_WORKER_EVENT_PORT.value).toBe('3003')
    expect(byKey.FICUS_PM2_API_NAME.value).toBe('tau-api')
    expect(byKey.FICUS_PM2_WORKER_NAME.value).toBe('tau-worker')
    expect(byKey.HOME_DIR).toBeUndefined()
    expect(byKey.DATABASE_URL.value).toBe('postgres://postgres:postgres@localhost:5432/tau')
  })
  it('names, numbers and homes a labelled instance off its label and port', () => {
    const byKey = Object.fromEntries(
      computeEnvUpdates(
        opts({
          instance: 'smoke',
          port: 3100,
          apiUrl: 'http://localhost:3100',
          appUrl: 'http://localhost:3100',
          dbPort: 5433,
          databaseUrl: 'postgres://postgres:postgres@localhost:5433/tau',
          explicit: new Set(['runtime', 'port', 'instance', 'dbPort']),
        }),
        secrets
      ).map((u) => [u.key, u])
    )
    expect(byKey.FICUS_INSTANCE.value).toBe('smoke')
    expect(byKey.PORT.value).toBe('3100')
    expect(byKey.WORKER_PORT).toEqual({ key: 'WORKER_PORT', value: '3102', explicit: true })
    expect(byKey.FICUS_WORKER_EVENT_PORT).toEqual({ key: 'FICUS_WORKER_EVENT_PORT', value: '3103', explicit: true })
    expect(byKey.FICUS_PM2_API_NAME).toEqual({ key: 'FICUS_PM2_API_NAME', value: 'tau-smoke-api', explicit: true })
    expect(byKey.FICUS_PM2_WORKER_NAME).toEqual({
      key: 'FICUS_PM2_WORKER_NAME',
      value: 'tau-smoke-worker',
      explicit: true,
    })
    expect(byKey.HOME_DIR.value).toBe('~/.tau-smoke')
    expect(byKey.DATABASE_URL.value).toBe('postgres://postgres:postgres@localhost:5433/tau')
  })
  it('leaves an existing label alone when the operator did not pass --instance', () => {
    const merged = mergeEnvFile(
      'FICUS_INSTANCE=smoke\nFICUS_PM2_API_NAME=tau-smoke-api\n',
      computeEnvUpdates(opts(), secrets)
    )
    expect(parseEnvFile(merged).FICUS_INSTANCE).toBe('smoke')
    expect(parseEnvFile(merged).FICUS_PM2_API_NAME).toBe('tau-api')
  })
  it('keeps an explicit --home-dir over the label default', () => {
    const byKey = Object.fromEntries(
      computeEnvUpdates(
        opts({ instance: 'smoke', homeDir: '~/elsewhere', explicit: new Set(['homeDir', 'instance']) }),
        secrets
      ).map((u) => [u.key, u])
    )
    expect(byKey.HOME_DIR).toEqual({ key: 'HOME_DIR', value: '~/elsewhere', explicit: true })
  })
  it('leaves an external database url alone', () => {
    const byKey = Object.fromEntries(
      computeEnvUpdates(
        opts({
          databaseMode: 'external',
          databaseUrl: 'postgres://u:p@db.example:5432/x',
          explicit: new Set(['databaseUrl']),
        }),
        secrets
      ).map((u) => [u.key, u])
    )
    expect(byKey.DATABASE_URL.value).toBe('postgres://u:p@db.example:5432/x')
  })
})

describe('the config-files step', () => {
  function fixture(): { root: string; deps: StepDeps; logs: string[] } {
    const root = mkdtempSync(join(tmpdir(), 'tau-steps-'))
    writeFileSync(join(root, '.env.example'), 'FICUS_SANDBOX_RUNTIME=\n')
    copyFileSync(join(REPO_ROOT, 'ecosystem.config.example.js'), join(root, 'ecosystem.config.example.js'))
    const logs: string[] = []
    const deps: StepDeps = {
      runner: recordingRunner().runner,
      secrets,
      fetch: (async () => new Response('')) as unknown as typeof fetch,
      sleep: async () => {},
      log: (line) => logs.push(line),
    }
    return { root, deps, logs }
  }
  const exampleText = () => readFileSync(join(REPO_ROOT, 'ecosystem.config.example.js'), 'utf8')
  const stepOf = (o: SetupOptions, deps: StepDeps) => buildSteps(o, deps).find((s) => s.id === 'config-files')!

  it('generates an ecosystem naming this instance apps', async () => {
    const { root, deps } = fixture()
    try {
      await stepOf(opts({ root, instance: 'smoke', explicit: new Set(['instance']) }), deps).run()
      const generated = readFileSync(join(root, 'ecosystem.config.js'), 'utf8')
      expect(generated).toContain("name: 'tau-smoke-api',")
      expect(generated).toContain("FICUS_PM2_WORKER_NAME: 'tau-smoke-worker',")
      expect(generated).not.toContain("'tau-api'")
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
  it('keeps an existing ecosystem.config.js, hand edits included, when its app names already match', async () => {
    const { root, deps, logs } = fixture()
    try {
      const mine = generateEcosystem(exampleText(), instanceNames('smoke')) + '\n// hand edit\n'
      writeFileSync(join(root, 'ecosystem.config.js'), mine)
      await stepOf(opts({ root, instance: 'smoke', explicit: new Set(['instance']) }), deps).run()
      expect(readFileSync(join(root, 'ecosystem.config.js'), 'utf8')).toBe(mine)
      expect(logs.join('\n')).not.toContain('regenerated')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
  it('refuses to relabel a checkout that already belongs to another instance', async () => {
    const { root, deps } = fixture()
    try {
      writeFileSync(join(root, '.env'), 'FICUS_INSTANCE=smoke\n')
      const step = stepOf(opts({ root, instance: 'other', explicit: new Set(['instance']) }), deps)
      await expect(step.run()).rejects.toThrow(SetupFailure)
      // The message must be the recipe: uninstall alone does not clear the label.
      await expect(step.run()).rejects.toThrow(
        `this checkout is instance "smoke"; to relabel it, remove FICUS_INSTANCE from .env (after unregistering its supervisor with tau server uninstall --root ${root}) — or set up a fresh checkout`
      )
      // A re-run without --instance is not a relabel attempt: it must go through.
      await stepOf(opts({ root, instance: 'tau', explicit: new Set() }), deps).run()
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
  it('labels an unlabelled checkout and regenerates its default-named ecosystem, with a warning', async () => {
    const { root, deps, logs } = fixture()
    try {
      // A hand-copied .env (or an install predating labels): no FICUS_INSTANCE.
      writeFileSync(join(root, '.env'), 'PORT=3000\n')
      writeFileSync(join(root, 'ecosystem.config.js'), exampleText())
      await stepOf(opts({ root, instance: 'smoke', explicit: new Set(['instance']) }), deps).run()
      const generated = readFileSync(join(root, 'ecosystem.config.js'), 'utf8')
      expect(generated).toContain("name: 'tau-smoke-api',")
      expect(generated).toContain("FICUS_PM2_WORKER_NAME: 'tau-smoke-worker',")
      expect(generated).not.toContain("'tau-api'")
      expect(logs).toContain(
        'warning: regenerated ecosystem.config.js for instance "smoke" (hand edits were discarded)'
      )
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})

describe('the env step', () => {
  function fixture(): { root: string; deps: StepDeps; logs: string[] } {
    const root = mkdtempSync(join(tmpdir(), 'tau-steps-env-'))
    writeFileSync(join(root, '.env.example'), 'FICUS_SANDBOX_RUNTIME=\n')
    copyFileSync(join(REPO_ROOT, 'ecosystem.config.example.js'), join(root, 'ecosystem.config.example.js'))
    const logs: string[] = []
    const deps: StepDeps = {
      runner: recordingRunner().runner,
      secrets,
      fetch: (async () => new Response('')) as unknown as typeof fetch,
      sleep: async () => {},
      log: (line) => logs.push(line),
    }
    return { root, deps, logs }
  }
  const stepOf = (o: SetupOptions, deps: StepDeps) => buildSteps(o, deps).find((s) => s.id === 'env')!

  it('warns that a relabelled install now has a different HOME_DIR but the same database', async () => {
    const { root, deps, logs } = fixture()
    try {
      // An install made before labels existed: a .env and an ecosystem, no FICUS_INSTANCE.
      writeFileSync(join(root, '.env'), 'PORT=3000\nDATABASE_URL=postgres://postgres:postgres@localhost:5432/tau\n')
      writeFileSync(join(root, 'ecosystem.config.js'), readFileSync(join(REPO_ROOT, 'ecosystem.config.example.js')))
      await stepOf(opts({ root, instance: 'smoke', explicit: new Set(['instance']) }), deps).run()
      expect(logs).toContain(
        'warning: HOME_DIR now points at ~/.tau-smoke; DATABASE_URL is unchanged (postgres://postgres:postgres@localhost:5432/tau)'
      )
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
  it('says the database MOVED when the relabel also repointed DATABASE_URL', async () => {
    const { root, deps, logs } = fixture()
    try {
      writeFileSync(join(root, '.env'), 'PORT=3000\nDATABASE_URL=postgres://postgres:postgres@localhost:5432/tau\n')
      writeFileSync(join(root, 'ecosystem.config.js'), readFileSync(join(REPO_ROOT, 'ecosystem.config.example.js')))
      // What setup passes once it has resolved a port of its own for this label.
      await stepOf(
        opts({
          root,
          instance: 'smoke',
          dbPort: 5433,
          databaseUrl: 'postgres://postgres:postgres@localhost:5433/tau',
          explicit: new Set(['instance', 'dbPort']),
        }),
        deps
      ).run()
      expect(logs).toContain(
        'warning: HOME_DIR now points at ~/.tau-smoke; DATABASE_URL now points at postgres://postgres:postgres@localhost:5433/tau'
      )
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
  it('says nothing when the checkout is not an existing install', async () => {
    const { root, deps, logs } = fixture()
    try {
      writeFileSync(join(root, '.env'), 'PORT=3000\n')
      await stepOf(opts({ root, instance: 'smoke', explicit: new Set(['instance']) }), deps).run()
      expect(logs.join('\n')).not.toContain('HOME_DIR now points at')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
  // Task 8 review carry: the TAU_ → FICUS_ rename must happen BEFORE the merge
  // writes .env. Merged first, a regenerated FICUS_PASSWORD would be appended
  // beside the real TAU_PASSWORD and win over it.
  describe('on a .env that predates the Ficus rename', () => {
    const legacy =
      'TAU_ENCRYPTION_KEY=' +
      'cd'.repeat(32) +
      '\nTAU_INTERNAL_EVENT_TOKEN=event-token\nTAU_PASSWORD=real-password\nTAU_SANDBOX_RUNTIME=host\nPORT=3000\n'
    const fresh = { hex32: () => 'ee'.repeat(32), token: () => 'regenerated-password' }

    it('renames it before merging, so the existing secrets survive and no FICUS_ twin is appended', async () => {
      const { root, deps } = fixture()
      try {
        writeFileSync(join(root, '.env'), legacy)
        await stepOf(opts({ root }), { ...deps, secrets: fresh }).run()
        const after = readFileSync(join(root, '.env'), 'utf8')
        expect(after).not.toMatch(/^TAU_/m)
        expect(after.match(/^FICUS_PASSWORD=.*$/gm)).toEqual(['FICUS_PASSWORD=real-password'])
        expect(after.match(/^FICUS_ENCRYPTION_KEY=.*$/gm)).toEqual([`FICUS_ENCRYPTION_KEY=${'cd'.repeat(32)}`])
        expect(after.match(/^FICUS_INTERNAL_EVENT_TOKEN=.*$/gm)).toEqual(['FICUS_INTERNAL_EVENT_TOKEN=event-token'])
        expect(after).not.toContain('regenerated-password')
        expect(after).not.toContain('ee'.repeat(32))
        const backups = readdirSync(root).filter((name) => name.startsWith('.env.pre-ficus-'))
        expect(backups).toHaveLength(1)
        expect(readFileSync(join(root, backups[0]), 'utf8')).toBe(legacy)
      } finally {
        rmSync(root, { recursive: true, force: true })
      }
    })

    it('plans against the renamed text: no generated secret, and the rename is announced', () => {
      const { root, deps } = fixture()
      try {
        writeFileSync(join(root, '.env'), legacy)
        const plan = stepOf(opts({ root }), deps).plan()
        expect(plan[0]).toBe('rename TAU_ settings to FICUS_ in .env (byte-for-byte backup .env.pre-ficus-<UTC time>)')
        expect(plan.join('\n')).not.toContain('FICUS_PASSWORD')
        expect(plan.join('\n')).not.toContain('FICUS_ENCRYPTION_KEY')
        // Planning writes nothing.
        expect(readFileSync(join(root, '.env'), 'utf8')).toBe(legacy)
        expect(readdirSync(root).some((name) => name.includes('.pre-ficus-'))).toBe(false)
      } finally {
        rmSync(root, { recursive: true, force: true })
      }
    })

    it('stops on conflicting passwords before writing anything, naming the key and not the values', async () => {
      const { root, deps } = fixture()
      try {
        const conflicting = 'TAU_PASSWORD=first-secret\nFICUS_PASSWORD=second-secret\n'
        writeFileSync(join(root, '.env'), conflicting)
        const error = (await stepOf(opts({ root }), deps)
          .run()
          .catch((e: unknown) => e)) as Error
        expect(error).toBeInstanceOf(EnvPrefixConflictError)
        expect(error.message).toContain('TAU_PASSWORD')
        expect(error.message).toContain('remove the wrong value, then re-run')
        expect(error.message).not.toContain('first-secret')
        expect(error.message).not.toContain('second-secret')
        expect(readFileSync(join(root, '.env'), 'utf8')).toBe(conflicting)
        expect(readdirSync(root).some((name) => name.includes('.pre-ficus-'))).toBe(false)
      } finally {
        rmSync(root, { recursive: true, force: true })
      }
    })

    it('renames the ecosystem.config.js env keys of an existing pm2 install too', async () => {
      const { root, deps } = fixture()
      try {
        writeFileSync(join(root, '.env'), legacy)
        const oldEcosystem = readFileSync(join(REPO_ROOT, 'ecosystem.config.example.js'), 'utf8').replace(
          /\bFICUS_/g,
          'TAU_'
        )
        writeFileSync(join(root, 'ecosystem.config.js'), oldEcosystem)
        await stepOf(opts({ root }), deps).run()
        const ecosystem = readFileSync(join(root, 'ecosystem.config.js'), 'utf8')
        expect(ecosystem).toContain(`FICUS_PM2_API_NAME: '${instanceNames('tau').api}',`)
        expect(ecosystem).not.toMatch(/\bTAU_/)
      } finally {
        rmSync(root, { recursive: true, force: true })
      }
    })
  })

  it('says nothing when the checkout already carries its label', async () => {
    const { root, deps, logs } = fixture()
    try {
      writeFileSync(join(root, '.env'), 'FICUS_INSTANCE=smoke\nHOME_DIR=~/.tau-smoke\n')
      writeFileSync(join(root, 'ecosystem.config.js'), readFileSync(join(REPO_ROOT, 'ecosystem.config.example.js')))
      await stepOf(opts({ root, instance: 'smoke', explicit: new Set(['instance']) }), deps).run()
      expect(logs.join('\n')).not.toContain('HOME_DIR now points at')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})

describe('root pm2 scripts', () => {
  it('read the app names from the environment so a labelled instance restarts its own apps', () => {
    const scripts = (
      JSON.parse(readFileSync(join(REPO_ROOT, 'package.json'), 'utf8')) as { scripts: Record<string, string> }
    ).scripts
    // $(bun scripts/pm2-name.ts …), NOT ${FICUS_PM2_API_NAME:-…}: bun does not
    // export the checkout's .env into the script shell, so a plain shell
    // expansion would silently address the default instance's apps.
    expect(scripts['start:core']).toContain('--only $(bun scripts/pm2-name.ts api),$(bun scripts/pm2-name.ts worker)')
    expect(scripts['stop:core']).toContain('pm2 stop $(bun scripts/pm2-name.ts api) $(bun scripts/pm2-name.ts worker)')
    expect(scripts['reload:api']).toContain('--only $(bun scripts/pm2-name.ts api)')
    expect(scripts['reload:worker']).toContain('--only $(bun scripts/pm2-name.ts worker)')
    for (const name of ['start:core', 'stop:core', 'reload:api', 'reload:worker']) {
      expect(scripts[name]).not.toMatch(/FICUS_PM2_(API|WORKER)_NAME/)
    }
  })
})

describe('ecosystem.config.example.js', () => {
  it('does not hardcode PORT — pm2 app env beats the shared .env, which would pin every checkout to the same port', () => {
    const text = readFileSync(join(REPO_ROOT, 'ecosystem.config.example.js'), 'utf8')
    expect(text).not.toMatch(/^\s*PORT:/m)
  })
  it('does not hardcode WORKER_PORT either — it is derived per instance and written to .env', () => {
    const text = readFileSync(join(REPO_ROOT, 'ecosystem.config.example.js'), 'utf8')
    expect(text).not.toMatch(/^\s*WORKER_PORT:/m)
  })
})

describe('native supervisor config', () => {
  it('selects file logs and reconciles supervisor-owned environment keys', () => {
    for (const supervisor of ['launchd', 'systemd-user'] as const) {
      const byKey = Object.fromEntries(
        computeEnvUpdates(opts({ supervisor, instance: 'smoke' }), secrets).map((u) => [u.key, u])
      )
      expect(byKey.FICUS_UPDATE_SUPERVISOR).toEqual({
        key: 'FICUS_UPDATE_SUPERVISOR',
        value: supervisor,
        explicit: true,
      })
      expect(byKey.FICUS_SYSTEM_LOG_PROVIDER.value).toBe('file')
      expect(byKey.FICUS_LOG_FILE_API.value).toEndWith('/.tau/logs/tau-smoke-api.log')
      expect(byKey.FICUS_LOG_FILE_WORKER.value).toEndWith('/.tau/logs/tau-smoke-worker.log')
      expect(byKey.FICUS_PM2_API_NAME.value).toBe('')
    }
  })

  it('does not create or replace an ecosystem for native supervisors', async () => {
    const root = mkdtempSync(join(tmpdir(), 'tau-native-config-'))
    const deps: StepDeps = {
      runner: recordingRunner().runner,
      secrets,
      fetch: async () => new Response(''),
      sleep: async () => {},
      log: () => {},
    }
    writeFileSync(join(root, '.env.example'), 'PORT=3000\n')
    copyFileSync(join(REPO_ROOT, 'ecosystem.config.example.js'), join(root, 'ecosystem.config.example.js'))
    const step = () =>
      buildSteps(opts({ root, supervisor: 'systemd-user' }), deps).find((s) => s.id === 'config-files')!
    try {
      await step().run()
      expect(() => readFileSync(join(root, 'ecosystem.config.js'), 'utf8')).toThrow()
      writeFileSync(join(root, 'ecosystem.config.js'), 'custom\n')
      await step().run()
      expect(readFileSync(join(root, 'ecosystem.config.js'), 'utf8')).toBe('custom\n')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})
