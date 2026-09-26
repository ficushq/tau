import { randomUUID } from 'crypto'
import { mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { afterEach, beforeEach, describe, expect, it, mock } from 'bun:test'
import { localProcessNames } from '@ficus/shared'
import { CommandRunner } from './command-runner'
import {
  LocalUpdateManager,
  UpdateLockedError,
  DirtyWorktreeError,
  UnsupportedDeploymentError,
  defaultLocalInstallEnv,
  sandboxRuntimeRestartBlocker,
} from './local-updater'
import { acquireUpdateRunLock } from './run-lock'
import { MANUAL_UPDATE_TARGETS } from './types'

const LOCAL_FLAVOR = { source: 'git-checkout', supervisor: 'pm2', sandboxRuntime: 'k3d-local' } as const
const SYSTEMD_FLAVOR = { source: 'git-checkout', supervisor: 'systemd', sandboxRuntime: 'docker-socket' } as const
const UNKNOWN_FLAVOR = { source: 'git-checkout', supervisor: 'unknown', sandboxRuntime: 'other' } as const

type TestOptions = Partial<ConstructorParameters<typeof LocalUpdateManager>[0]> & {
  gitResponses?: Record<string, string>
  ghResponses?: Record<string, string>
}
async function waitUntilInactive(updater: LocalUpdateManager, timeoutMs = 2_000) {
  const deadline = Date.now() + timeoutMs
  while (updater.status().active) {
    if (Date.now() >= deadline) throw new Error('Timed out waiting for background update to finish')
    await Bun.sleep(1)
  }
}
function manager(opts: TestOptions = {}) {
  const calls: string[][] = []
  const ghCalls: string[][] = []
  const responses = opts.gitResponses ?? {}
  const ghResponses: Record<string, string> = {
    'auth token': 'test-token',
    'repo view --json owner,name --jq .owner.login + "/" + .name': 'tau/tau',
    ...(opts.ghResponses ?? {}),
  }
  return {
    calls,
    ghCalls,
    updater: new LocalUpdateManager({
      repoRoot: '/repo',
      flavor: () => LOCAL_FLAVOR,
      git: async (cmd: string[]) => {
        calls.push(cmd)
        if (responses[cmd.join(' ')] !== undefined) return responses[cmd.join(' ')]
        if (cmd.join(' ') === 'rev-parse FETCH_HEAD') return responses['rev-parse origin/main'] ?? ''
        // Ancestry defaults to fast-forwardable: the merge base IS the local
        // sha. That is the shape these cases exercised before the updater
        // classified divergence, so the default keeps them about what they
        // were about. The ancestry cases build a real git graph instead
        // (local-updater.ancestry.test.ts) rather than asserting against a
        // mock that could be taught to agree with anything.
        if (cmd[0] === 'merge-base') return cmd[1] ?? ''
        return ''
      },
      gh: async (cmd: string[]) => {
        ghCalls.push(cmd)
        return ghResponses[cmd.join(' ')] ?? ''
      },
      commandRunner: { runAll: async () => {} },
      // Hermetic: repoRoot '/repo' has no .env, so the real preflight would fall
      // back to the ambient process env (test-setup.ts pins docker-socket) and
      // these tests would silently depend on the preload for their outcome.
      // The preflight has its own tests below, including ones that drive the
      // DEFAULT implementation against a real .env file.
      sandboxRuntimePreflight: () => {},
      // Hermetic default: the cross-process advisory lock has its own real-DB
      // tests below (which inject the real acquireUpdateRunLock on a
      // test-scoped key).
      runLock: async () => ({ release: async () => {} }),
      ...opts,
    } as any),
  }
}

describe('LocalUpdateManager', () => {
  it('rejects concurrent apply runs', async () => {
    let release!: () => void
    const { updater } = manager({
      commandRunner: { runAll: () => new Promise<void>((r) => (release = r)) },
      gitResponses: {
        'status --porcelain': '',
        'rev-parse HEAD': 'a',
        'rev-parse origin/main': 'b',
        'diff --name-only a b': 'apps/web/x.ts',
      },
    })
    const first = updater.apply({ manual: true })
    await expect(updater.apply({ manual: true })).rejects.toBeInstanceOf(UpdateLockedError)
    while (!release) await Bun.sleep(1)
    release()
    await first
  })

  it('skips automatic apply when worktree is dirty', async () => {
    const { updater } = manager({ gitResponses: { 'status --porcelain': ' M file' } })
    const run = await updater.apply({ manual: false })
    expect(run.status).toBe('skipped')
    expect(run.dirty).toBe(true)
  })

  it('throws dirty error for manual apply when worktree is dirty', async () => {
    const { updater } = manager({ gitResponses: { 'status --porcelain': ' M file' } })
    await expect(updater.apply({ manual: true })).rejects.toBeInstanceOf(DirtyWorktreeError)
  })

  it('checks availability with gh and local sha comparison without git fetch', async () => {
    const { updater, calls, ghCalls } = manager({
      gitResponses: { 'rev-parse HEAD': 'a' },
      ghResponses: { 'api repos/tau/tau/commits/main --jq .sha': 'a' },
      settings: { githubOwner: 'tau', githubRepo: 'tau' },
    })
    const result = await updater.check()
    expect(result.available).toBe(false)
    expect(calls).toEqual([['rev-parse', 'HEAD']])
    expect(ghCalls).toEqual([['api', 'repos/tau/tau/commits/main', '--jq', '.sha']])
  })

  it('reports an available update when gh remote sha differs from local sha', async () => {
    const { updater } = manager({
      gitResponses: { 'rev-parse HEAD': 'local' },
      ghResponses: { 'api repos/tau/tau/commits/main --jq .sha': 'remote' },
      settings: { githubOwner: 'tau', githubRepo: 'tau' },
    })
    const result = await updater.check()
    expect(result.available).toBe(true)
    expect(result.beforeSha).toBe('local')
    expect(result.afterSha).toBe('remote')
    expect(result.message).toBe('Update available')
  })

  it('surfaces gh failures with a clear settings check error', async () => {
    const { updater } = manager({
      gitResponses: { 'rev-parse HEAD': 'local' },
      gh: async () => {
        throw new Error('gh api failed: authentication required')
      },
      settings: { githubOwner: 'tau', githubRepo: 'tau' },
    })
    await expect(updater.check()).rejects.toThrow(
      'Unable to check GitHub for updates with the gh CLI. Connect GitHub in Integrations and select githubConnectionId in update settings when multiple accounts are connected.'
    )
  })

  it('persists latest run status for a restarted API process', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'tau-update-status-'))
    try {
      const statusPath = join(dir, 'status.json')
      let release!: () => void
      const first = manager({
        repoRoot: dir,
        statusPath,
        commandRunner: { runAll: () => new Promise<void>((r) => (release = r)) },
        gitResponses: {
          'status --porcelain': '',
          'rev-parse HEAD': 'a',
          'rev-parse origin/main': 'b',
          'diff --name-only a b': 'apps/web/x.ts',
        },
      })
      first.updater.applyInBackground({ manual: true })
      while (!release) await Bun.sleep(1)

      const second = manager({ repoRoot: dir, statusPath })

      expect(second.updater.status().latest?.status).toBe('running')
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  it('marks an interrupted reload:core run succeeded after API restart', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'tau-update-status-'))
    try {
      const statusPath = join(dir, 'status.json')
      const first = manager({ repoRoot: dir, statusPath })
      const run = first.updater.applyInBackground({ manual: true })
      run.changedFiles = ['apps/core/src/index.ts']
      run.selectedTasks = ['core']
      run.commands = [
        { task: 'core', command: ['bun', 'run', 'build:core'], status: 'succeeded' },
        { task: 'core', command: ['bun', 'run', 'reload:core'], status: 'running' },
      ]
      ;(first.updater as any).persistLatest(run)

      const second = manager({ repoRoot: dir, statusPath })

      expect(second.updater.status().latest?.status).toBe('succeeded')
      expect(second.updater.status().latest?.commands.at(-1)?.status).toBe('succeeded')
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  it('marks an old persisted reload:core run with pending commands succeeded after API restart', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'tau-update-status-'))
    try {
      const statusPath = join(dir, 'status.json')
      const first = manager({ repoRoot: dir, statusPath })
      const run = first.updater.applyInBackground({ manual: true })
      run.changedFiles = ['apps/core/src/index.ts']
      run.selectedTasks = ['core']
      run.commands = [
        { task: 'core', command: ['bun', 'run', 'build:core'], status: 'pending' },
        { task: 'core', command: ['bun', 'run', 'reload:core'], status: 'pending' },
      ]
      ;(first.updater as any).persistLatest(run)

      const second = manager({ repoRoot: dir, statusPath })

      expect(second.updater.status().latest?.status).toBe('succeeded')
      expect(second.updater.status().latest?.commands.map((cmd) => cmd.status)).toEqual(['succeeded', 'succeeded'])
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  it('marks an unobserved systemd API restart run failed after API restart', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'tau-update-status-'))
    try {
      const statusPath = join(dir, 'status.json')
      const first = manager({ repoRoot: dir, statusPath })
      const run = first.updater.applyInBackground({ manual: true })
      run.changedFiles = ['apps/core/src/index.ts']
      run.selectedTasks = ['core']
      run.commands = [
        { task: 'core', command: ['bun', 'run', 'build:core'], status: 'succeeded' },
        { task: 'core', command: ['sudo', '-n', 'systemctl', 'restart', 'tau-api'], status: 'running' },
      ]
      ;(first.updater as any).persistLatest(run)

      const second = manager({ repoRoot: dir, statusPath })

      expect(second.updater.status().latest?.status).toBe('failed')
      expect(second.updater.status().latest?.error).toContain('API restart outcome was not observed')
      expect(second.updater.status().latest?.commands.at(-1)?.status).toBe('failed')
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  it('marks a persisted pre-restart systemd success succeeded after the API was restarted', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'tau-update-status-'))
    try {
      const statusPath = join(dir, 'status.json')
      const first = manager({ repoRoot: dir, statusPath })
      const run = first.updater.applyInBackground({ manual: true })
      run.changedFiles = ['apps/core/src/index.ts']
      run.selectedTasks = ['core']
      run.commands = [
        { task: 'core', command: ['bun', 'run', 'build:core'], status: 'succeeded' },
        {
          task: 'core',
          command: ['systemctl', '--user', '--no-block', 'restart', 'tau-api.service'],
          status: 'succeeded',
          exitCode: 0,
        },
      ]
      ;(first.updater as any).persistLatest(run)

      const second = manager({ repoRoot: dir, statusPath })

      expect(second.updater.status().latest?.status).toBe('succeeded')
      expect(second.updater.status().latest?.message).toContain('Update completed; API restarted')
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  it('marks a persisted systemd restart whose child was killed by SIGTERM succeeded after the API restarted', async () => {
    // Older cores recorded the SIGTERM as a failed command and died before the run status
    // was persisted; the reconciler must still recognise that shape as a completed restart.
    const dir = mkdtempSync(join(tmpdir(), 'tau-update-status-'))
    try {
      const statusPath = join(dir, 'status.json')
      const first = manager({ repoRoot: dir, statusPath })
      const run = first.updater.applyInBackground({ manual: true })
      run.changedFiles = ['apps/core/src/index.ts']
      run.selectedTasks = ['core']
      run.commands = [
        { task: 'core', command: ['bun', 'run', 'build:core'], status: 'succeeded' },
        {
          task: 'core',
          command: ['systemctl', '--user', '--no-block', 'restart', 'tau-api.service'],
          status: 'failed',
          exitCode: 143,
          outputTail: '',
        },
      ]
      ;(first.updater as any).persistLatest(run)

      const second = manager({ repoRoot: dir, statusPath })

      expect(second.updater.status().latest?.status).toBe('succeeded')
      expect(second.updater.status().latest?.message).toContain('Update completed; API restarted')
      expect(second.updater.status().latest?.commands.at(-1)?.status).toBe('succeeded')
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  it('does not mark a run succeeded when it was interrupted mid-build before the restart command ran', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'tau-update-status-'))
    try {
      const statusPath = join(dir, 'status.json')
      const first = manager({ repoRoot: dir, statusPath })
      const run = first.updater.applyInBackground({ manual: true })
      run.changedFiles = ['apps/core/src/index.ts']
      run.selectedTasks = ['core']
      run.commands = [
        { task: 'core', command: ['bun', 'run', 'build:core'], status: 'running' },
        { task: 'core', command: ['sudo', '-n', 'systemctl', 'restart', 'tau-worker'], status: 'pending' },
        { task: 'core', command: ['sudo', '-n', 'systemctl', 'restart', 'tau-api'], status: 'pending' },
      ]
      ;(first.updater as any).persistLatest(run)

      const second = manager({ repoRoot: dir, statusPath })

      expect(second.updater.status().latest?.status).not.toBe('succeeded')
      expect(second.updater.status().latest?.status).toBe('failed')
      expect(second.updater.status().latest?.error).toContain('Interrupted before the restart command ran')
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  it('marks a genuinely self-restarted run succeeded when persisted mid-dispatch', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'tau-update-status-'))
    try {
      const statusPath = join(dir, 'status.json')
      const first = manager({ repoRoot: dir, statusPath })
      const run = first.updater.applyInBackground({ manual: true })
      run.changedFiles = ['apps/core/src/index.ts']
      run.selectedTasks = ['core']
      run.commands = [
        { task: 'core', command: ['bun', 'run', 'build:core'], status: 'succeeded' },
        { task: 'core', command: ['sudo', '-n', 'systemctl', 'restart', 'tau-worker'], status: 'succeeded' },
        // The command runner marks the API-restart command 'succeeded' before dispatching it,
        // so a genuine self-restart always persists with this final status, never 'pending'.
        { task: 'core', command: ['sudo', '-n', 'systemctl', 'restart', 'tau-api'], status: 'succeeded' },
      ]
      ;(first.updater as any).persistLatest(run)

      const second = manager({ repoRoot: dir, statusPath })

      expect(second.updater.status().latest?.status).toBe('succeeded')
      expect(second.updater.status().latest?.commands.at(-1)?.status).toBe('succeeded')
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  it('fetches and fast-forwards with gh-backed non-interactive https auth', async () => {
    let commandNames: string[][] = []
    const gitCalls: Array<{ args: string[]; env?: Record<string, string> }> = []
    const updater = new LocalUpdateManager({
      repoRoot: '/repo',
      flavor: () => LOCAL_FLAVOR,
      settings: { githubOwner: 'tau', githubRepo: 'tau' },
      git: async (args: string[], options?: { env?: Record<string, string> }) => {
        gitCalls.push({ args, env: options?.env })
        return (
          {
            'status --porcelain': '',
            'rev-parse HEAD': 'a',
            'rev-parse FETCH_HEAD': 'b',
            // 'a' is the merge base, i.e. the checkout is an ancestor of the
            // target — which is what "fast-forwards" in this test's name means.
            'merge-base a b': 'a',
            'diff --name-only a b': 'apps/web/src/App.tsx',
          }[args.join(' ')] ?? ''
        )
      },
      gh: async (args: string[]) => ({ 'auth token': 'secret-token' })[args.join(' ')] ?? '',
      commandRunner: {
        runAll: async (commands: any[]) => {
          commandNames = commands.map((c) => c.command)
        },
      },
    } as any)

    const run = await updater.apply({ manual: true })

    expect(run.selectedTasks).toEqual(['web'])
    expect(commandNames).toEqual([['bun', 'run', 'build:web']])
    expect(gitCalls.map((call) => call.args)).toContainEqual([
      'fetch',
      '--no-tags',
      'https://github.com/tau/tau.git',
      'main',
    ])
    expect(gitCalls.map((call) => call.args)).toContainEqual(['merge', '--ff-only', 'FETCH_HEAD'])
    expect(gitCalls.flatMap((call) => call.args).join(' ')).not.toContain('secret-token')
    const fetchCall = gitCalls.find((call) => call.args[0] === 'fetch')
    expect(fetchCall?.env?.GIT_TERMINAL_PROMPT).toBe('0')
    expect(fetchCall?.env?.GIT_SSH_COMMAND).toContain('BatchMode=yes')
    expect(fetchCall?.env?.GIT_CONFIG_KEY_0).toBe('http.https://github.com/.extraheader')
    expect(fetchCall?.env?.GIT_CONFIG_VALUE_0).toBe('AUTHORIZATION: basic eC1hY2Nlc3MtdG9rZW46c2VjcmV0LXRva2Vu')
  })

  it('surfaces git fetch failures without misdiagnosing gh auth after token lookup succeeds', async () => {
    const { updater } = manager({
      gitResponses: { 'status --porcelain': '', 'rev-parse HEAD': 'a' },
      git: async (args: string[]) => {
        if (args.join(' ') === 'status --porcelain') return ''
        if (args.join(' ') === 'rev-parse HEAD') return 'a'
        if (args[0] === 'fetch') throw new Error('git fetch failed: repository not found')
        return ''
      },
      ghResponses: { 'auth token': 'secret-token' },
      settings: { githubOwner: 'tau', githubRepo: 'tau' },
    })

    try {
      await updater.apply({ manual: true })
      throw new Error('expected apply to fail')
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      expect(message).toContain(
        'Unable to fetch GitHub update from tau/tau main: git fetch failed: repository not found'
      )
      expect(message).not.toContain('Run gh auth login')
    }
  })

  it('fails apply with a clear gh auth error when token lookup fails', async () => {
    const { updater } = manager({
      gitResponses: { 'status --porcelain': '', 'rev-parse HEAD': 'a' },
      gh: async () => {
        throw new Error('not logged in')
      },
      settings: { githubOwner: 'tau', githubRepo: 'tau' },
    })

    await expect(updater.apply({ manual: true })).rejects.toThrow(
      'Unable to apply GitHub update with the gh CLI. Connect GitHub in Integrations and select githubConnectionId in update settings when multiple accounts are connected.'
    )
  })

  it('does not leak gh tokens in apply errors', async () => {
    const token = 'secret-token'
    const encodedAuth = 'eC1hY2Nlc3MtdG9rZW46c2VjcmV0LXRva2Vu'
    const updater = new LocalUpdateManager({
      repoRoot: '/repo',
      flavor: () => LOCAL_FLAVOR,
      settings: { githubOwner: 'tau', githubRepo: 'tau' },
      git: async (args: string[]) => {
        if (args.join(' ') === 'status --porcelain') return ''
        if (args.join(' ') === 'rev-parse HEAD') return 'a'
        throw new Error(`fetch failed for token ${token} and basic auth ${encodedAuth}`)
      },
      gh: async (args: string[]) => ({ 'auth token': token })[args.join(' ')] ?? '',
      commandRunner: { runAll: async () => {} },
    } as any)

    try {
      await updater.apply({ manual: true })
      throw new Error('expected apply to fail')
    } catch (err) {
      expect(err instanceof Error ? err.message : String(err)).not.toContain(token)
      expect(err instanceof Error ? err.message : String(err)).not.toContain(encodedAuth)
      expect(err instanceof Error ? err.message : String(err)).toContain('[redacted]')
    }
  })

  it('persists a failed systemd API restart as a terminal failed run', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'tau-systemd-restart-failure-'))
    try {
      const { updater } = manager({
        flavor: () => SYSTEMD_FLAVOR,
        statusPath: join(dir, 'status.json'),
        commandRunner: new CommandRunner({
          cwd: '/repo',
          runProcess: async (command) => ({
            exitCode: command.includes('tau-api') ? 1 : 0,
            output: command.includes('tau-api') ? 'sudo: a password is required' : '',
          }),
        }),
      })
      const run = updater.applyInBackground({ manual: true, tasks: ['core'] })
      await waitUntilInactive(updater)
      const failedCommand = run.commands.at(-1)!.command.join(' ')

      expect(updater.status().latest).toMatchObject({
        id: run.id,
        status: 'failed',
        error: `Update command failed: ${failedCommand}`,
      })
      expect(updater.status().latest?.completedAt).toBeDefined()
      expect(updater.status().latest?.commands.at(-1)).toMatchObject({
        status: 'failed',
        exitCode: 1,
        outputTail: 'sudo: a password is required',
      })
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  describe('deployment flavor gating', () => {
    it('records flavor + support on runs and skips automatic apply on unsupported flavors', async () => {
      const { updater } = manager({ flavor: () => UNKNOWN_FLAVOR })
      const run = await updater.apply({ manual: false })
      expect(run.status).toBe('skipped')
      expect(run.supported).toBe(false)
      expect(run.supportReason).toContain('FICUS_UPDATE_SUPERVISOR')
      expect(run.flavor).toEqual(UNKNOWN_FLAVOR)
    })

    it('fails manual apply on unsupported flavors with UnsupportedDeploymentError', async () => {
      const { updater } = manager({ flavor: () => UNKNOWN_FLAVOR })
      await expect(updater.apply({ manual: true })).rejects.toBeInstanceOf(UnsupportedDeploymentError)
    })

    it('fails manual applyInBackground synchronously on unsupported flavors', () => {
      const { updater } = manager({ flavor: () => UNKNOWN_FLAVOR })
      expect(() => updater.applyInBackground({ manual: true })).toThrow(UnsupportedDeploymentError)
      expect(updater.status().latest?.status).toBe('failed')
      expect(updater.status().latest?.flavor).toEqual(UNKNOWN_FLAVOR)
      expect(updater.status().active).toBe(false)
    })

    it('rejects the sandbox manual target on non-k3d runtimes', () => {
      const { updater } = manager({ flavor: () => SYSTEMD_FLAVOR })
      expect(() => updater.applyInBackground({ manual: true, tasks: ['sandbox'] })).toThrow(
        /only automated for local k3d/
      )
    })

    it('plans systemctl restarts for the systemd flavor on targeted core rebuilds', async () => {
      const { updater } = manager({ flavor: () => SYSTEMD_FLAVOR })
      const run = updater.applyInBackground({ manual: true, tasks: ['core'] })
      await waitUntilInactive(updater)
      const planned = run.commands.map((c) => c.command.join(' '))
      expect(planned.some((c) => c.includes('systemctl restart tau-worker'))).toBe(true)
      expect(planned.some((c) => c.includes('reload:'))).toBe(false)
    })
  })

  describe('targeted manual update', () => {
    function makeTargetedManager() {
      const ran: string[][] = []
      const git = mock(async () => '')
      const commandRunner = {
        runAll: async (cmds: any[]) => {
          for (const c of cmds) {
            ran.push(c.command)
            c.status = 'succeeded'
          }
        },
      }
      const updater = new LocalUpdateManager({
        repoRoot: '/tmp/tau-targeted-test',
        git,
        commandRunner,
        statusPath: `/tmp/tau-targeted-test-${randomUUID()}.json`,
        flavor: () => LOCAL_FLAVOR,
      })
      return { updater, ran, git }
    }

    async function waitUntilDone(updater: LocalUpdateManager) {
      for (let i = 0; i < 100; i++) {
        if (!updater.status().active) return
        await Bun.sleep(1)
      }
      throw new Error('Timed out waiting for targeted update to finish')
    }

    it('runs only the requested task commands and skips git', async () => {
      const { updater, ran, git } = makeTargetedManager()
      const run = updater.applyInBackground({ manual: true, tasks: ['web'] })
      expect(run.mode).toBe('manual')
      expect(run.selectedTasks).toEqual(['web'])
      await waitUntilDone(updater)
      expect(ran).toEqual([['bun', 'run', 'build:web']])
      expect(git).not.toHaveBeenCalled()
      expect(updater.status().latest?.status).toBe('succeeded')
      expect(updater.status().latest?.selectedTasks).toEqual(['web'])
      expect(updater.status().latest?.targeted).toBe(true)
    })

    it('rejects empty or unknown targets', () => {
      const { updater } = makeTargetedManager()
      expect(() => updater.applyInBackground({ manual: true, tasks: [] })).toThrow(/at least one/i)
      expect(() => updater.applyInBackground({ manual: true, tasks: ['install'] as never })).toThrow(/unsupported/i)
    })

    it('honors the active lock', () => {
      const { updater } = makeTargetedManager()
      updater.applyInBackground({ manual: true, tasks: ['web'] })
      expect(() => updater.applyInBackground({ manual: true, tasks: ['core'] })).toThrow(/already running/i)
    })

    it('MANUAL_UPDATE_TARGETS is the closed allowed set', () => {
      expect(MANUAL_UPDATE_TARGETS).toEqual(['cli', 'sandbox', 'core', 'web'])
    })
  })
})

describe('cross-process update run lock (real advisory lock)', () => {
  // Test-scoped advisory key: the real production key is shared with any
  // background runs other test files leave in flight; a private key keeps
  // these tests hermetic while still exercising the real pg lock mechanics.
  const TEST_LOCK_KEY = 500_000 + Math.floor(Math.random() * 100_000)
  const testRunLock = () => acquireUpdateRunLock(TEST_LOCK_KEY)
  const CLEAN_GIT = {
    'status --porcelain': '',
    'rev-parse HEAD': 'a',
    'rev-parse origin/main': 'b',
    'diff --name-only a b': 'apps/web/x.ts',
  }

  it('apply throws UpdateLockedError while another process holds the lock, succeeds after release', async () => {
    const held = await acquireUpdateRunLock(TEST_LOCK_KEY)
    expect(held).not.toBeNull()
    const dir = mkdtempSync(join(tmpdir(), 'tau-updater-lock-'))
    try {
      const { updater } = manager({
        runLock: testRunLock,
        statusPath: join(dir, 'status.json'),
        gitResponses: CLEAN_GIT,
      })
      await expect(updater.apply({ manual: true })).rejects.toBeInstanceOf(UpdateLockedError)

      await held!.release()
      const run = await updater.apply({ manual: true })
      expect(run.status).not.toBe('failed')
    } finally {
      await held?.release().catch(() => {})
      rmSync(dir, { recursive: true, force: true })
    }
  })

  it('applyInBackground records a terminal failure when lock acquisition rejects', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'tau-updater-lock-error-'))
    try {
      const { updater } = manager({
        runLock: async () => {
          throw new Error('database temporarily unavailable')
        },
        statusPath: join(dir, 'status.json'),
      })
      const run = updater.applyInBackground({ manual: true })
      // Wait on `active`, NOT on the run status. applyInBackground persists the
      // terminal run BEFORE it awaits notifyFailure and clears the in-process
      // slot in a trailing `.finally()`, so `latest.status === 'failed'` is
      // reached strictly earlier than `active === false`. Polling the run
      // status let the loop exit mid-teardown whenever notifyFailure took
      // longer than the 1ms tick — rare on a laptop, near-certain on CI.
      await waitUntilInactive(updater)

      expect(updater.status().active).toBe(false)
      expect(updater.status().latest).toMatchObject({
        id: run.id,
        status: 'failed',
        error: 'database temporarily unavailable',
      })
      expect(updater.status().latest?.completedAt).toBeDefined()
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  it('applyInBackground fails the run with a clear message when another process holds the lock', async () => {
    const held = await acquireUpdateRunLock(TEST_LOCK_KEY)
    expect(held).not.toBeNull()
    const dir = mkdtempSync(join(tmpdir(), 'tau-updater-lock-bg-'))
    try {
      const { updater } = manager({
        runLock: testRunLock,
        statusPath: join(dir, 'status.json'),
        gitResponses: CLEAN_GIT,
      })
      const run = updater.applyInBackground({ manual: true })
      expect(run.status).toBe('running')
      for (let i = 0; i < 200 && updater.status().latest?.status === 'running'; i++) await Bun.sleep(5)
      const latest = updater.status().latest
      expect(latest?.status).toBe('failed')
      expect(latest?.error).toContain('another process')
    } finally {
      await held!.release()
      rmSync(dir, { recursive: true, force: true })
    }
  })
})

// The last thing an update does is restart tau-api and tau-worker, and it
// rewrites no .env. Since FICUS_SANDBOX_RUNTIME became mandatory and explicit,
// an install whose environment never named one comes back from that restart
// with both services DEAD — after the merge and the build already landed.
describe('sandboxRuntimeRestartBlocker', () => {
  const LIST = 'FICUS_SANDBOX_RUNTIME must be one of docker-sysbox, docker-socket, k8s, vm, host'
  let dir: string
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'tau-update-runtime-'))
  })
  afterEach(() => {
    rmSync(dir, { recursive: true, force: true })
  })

  it('allows the restart when the env file names a supported runtime', () => {
    writeFileSync(join(dir, '.env'), 'DATABASE_URL=postgres://x\nFICUS_SANDBOX_RUNTIME=vm\n')
    expect(sandboxRuntimeRestartBlocker(join(dir, '.env'), {})).toBeNull()
  })

  it('reads a pre-rename TAU_SANDBOX_RUNTIME line for one release', () => {
    writeFileSync(join(dir, '.env'), 'DATABASE_URL=postgres://x\nTAU_SANDBOX_RUNTIME=vm\n')
    expect(sandboxRuntimeRestartBlocker(join(dir, '.env'), {})).toBeNull()
  })

  it('blocks a legacy spelling, quoting the value and naming the file', () => {
    writeFileSync(join(dir, '.env'), 'FICUS_SANDBOX_RUNTIME=sysbox\n')
    const blocker = sandboxRuntimeRestartBlocker(join(dir, '.env'), {})
    expect(blocker).toContain(LIST)
    expect(blocker).toContain('(got "sysbox")')
    expect(blocker).toContain(join(dir, '.env'))
  })

  it('blocks when nothing names a runtime at all', () => {
    writeFileSync(join(dir, '.env'), 'DATABASE_URL=postgres://x\n')
    expect(sandboxRuntimeRestartBlocker(join(dir, '.env'), {})).toContain('(is unset)')
    // ...and when there is no env file either.
    expect(sandboxRuntimeRestartBlocker(join(dir, 'absent.env'), {})).toContain('(is unset)')
  })

  // systemd's EnvironmentFile strips quotes, and a value can reach the services
  // from the unit/managed.env instead of the file — so the file wins only when
  // it actually declares the key.
  it('tolerates quotes and falls back to the running process environment', () => {
    writeFileSync(join(dir, '.env'), 'FICUS_SANDBOX_RUNTIME="docker-socket"\n')
    expect(sandboxRuntimeRestartBlocker(join(dir, '.env'), { FICUS_SANDBOX_RUNTIME: 'auto' })).toBeNull()
    writeFileSync(join(dir, '.env'), 'DATABASE_URL=postgres://x\n')
    expect(sandboxRuntimeRestartBlocker(join(dir, '.env'), { FICUS_SANDBOX_RUNTIME: 'k8s' })).toBeNull()
    expect(sandboxRuntimeRestartBlocker(join(dir, '.env'), { FICUS_SANDBOX_RUNTIME: 'auto' })).toContain('(got "auto")')
  })
})

describe('LocalUpdateManager sandbox-runtime preflight', () => {
  const CORE_CHANGE = {
    'status --porcelain': '',
    'rev-parse HEAD': 'a',
    'rev-parse origin/main': 'b',
    'diff --name-only a b': 'apps/core/src/index.ts',
  }

  // The env file names a runtime the new build rejects (this box predates the
  // rename), so the declared value decides. The refusal must land BEFORE the
  // merge: leaving the checkout moved forward onto code the services cannot
  // start is strictly worse than not updating at all.
  it('aborts before the merge when the env file names a retired runtime', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'tau-update-preflight-'))
    try {
      writeFileSync(join(dir, '.env'), 'DATABASE_URL=postgres://x\nFICUS_SANDBOX_RUNTIME=auto\n')
      let ran = false
      const { updater, calls } = manager({
        repoRoot: dir,
        statusPath: join(dir, 'status.json'),
        flavor: () => SYSTEMD_FLAVOR,
        commandRunner: {
          runAll: async () => {
            ran = true
          },
        },
        // Use the REAL preflight (the shared helper stubs it out).
        sandboxRuntimePreflight: undefined,
        gitResponses: CORE_CHANGE,
      })
      await expect(updater.apply({ manual: true })).rejects.toThrow(
        'FICUS_SANDBOX_RUNTIME must be one of docker-sysbox, docker-socket, k8s, vm, host (got "auto")'
      )
      expect(ran).toBe(false)
      // The checkout is untouched: no merge, and no diff against a new head.
      expect(calls.some((cmd) => cmd.includes('merge'))).toBe(false)
      const latest = updater.status().latest
      expect(latest?.status).toBe('failed')
      expect(latest?.error).toContain('restarting')
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  it('runs the update when the env file names a supported runtime', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'tau-update-preflight-ok-'))
    try {
      writeFileSync(join(dir, '.env'), 'FICUS_SANDBOX_RUNTIME=docker-socket\n')
      let ran = false
      const { updater } = manager({
        repoRoot: dir,
        statusPath: join(dir, 'status.json'),
        flavor: () => SYSTEMD_FLAVOR,
        commandRunner: {
          runAll: async () => {
            ran = true
          },
        },
        sandboxRuntimePreflight: undefined,
        gitResponses: CORE_CHANGE,
      })
      const run = await updater.apply({ manual: true })
      expect(run.status).toBe('succeeded')
      expect(ran).toBe(true)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  // A run that restarts nothing cannot be broken by the runtime setting, and
  // blocking it would strand a fleet on an unrelated misconfiguration. A
  // TARGETED rebuild is where that is observable: it has its plan up front, so
  // it asks the precise question instead of the flavor-level one runApply must
  // use before it merges.
  it('does not block a targeted rebuild whose plan restarts nothing', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'tau-update-preflight-norestart-'))
    try {
      // Same broken .env as the aborting case above — the ONLY difference is
      // that a web-only rebuild restarts nothing.
      writeFileSync(join(dir, '.env'), 'DATABASE_URL=postgres://x\nFICUS_SANDBOX_RUNTIME=auto\n')
      let ran = false
      const { updater } = manager({
        repoRoot: dir,
        statusPath: join(dir, 'status.json'),
        flavor: () => SYSTEMD_FLAVOR,
        commandRunner: {
          runAll: async () => {
            ran = true
          },
        },
        sandboxRuntimePreflight: undefined,
        gitResponses: CORE_CHANGE,
      })
      updater.applyInBackground({ manual: true, tasks: ['web'] })
      await waitUntilInactive(updater)
      expect(updater.status().latest?.status).toBe('succeeded')
      expect(ran).toBe(true)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  // ...and the mirror image: a targeted rebuild that DOES restart is blocked.
  it('blocks a targeted rebuild whose plan restarts the services', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'tau-update-preflight-targeted-'))
    try {
      writeFileSync(join(dir, '.env'), 'DATABASE_URL=postgres://x\nFICUS_SANDBOX_RUNTIME=auto\n')
      let ran = false
      const { updater } = manager({
        repoRoot: dir,
        statusPath: join(dir, 'status.json'),
        flavor: () => SYSTEMD_FLAVOR,
        commandRunner: {
          runAll: async () => {
            ran = true
          },
        },
        sandboxRuntimePreflight: undefined,
        gitResponses: CORE_CHANGE,
      })
      updater.applyInBackground({ manual: true, tasks: ['core'] })
      await waitUntilInactive(updater)
      const latest = updater.status().latest
      expect(latest?.status).toBe('failed')
      expect(latest?.error).toContain('(got "auto")')
      expect(ran).toBe(false)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })
})

// Ficus rename (Task 10): the updater hard-renames a local install's TAU_
// settings to FICUS_ before its restart commands run, and puts the files back
// byte-for-byte when the update fails, so the old processes restart on exactly
// the configuration they had.
describe('LocalUpdateManager local-install env rename', () => {
  const CORE_CHANGE = {
    'status --porcelain': '',
    'rev-parse HEAD': 'a',
    'rev-parse origin/main': 'b',
    'diff --name-only a b': 'apps/core/src/index.ts',
  }
  const LEGACY_ENV = 'TAU_ENCRYPTION_KEY=' + 'ab'.repeat(32) + '\nTAU_SANDBOX_RUNTIME=host\nTAU_PASSWORD=real\n'
  const RENAMED_ENV = 'FICUS_ENCRYPTION_KEY=' + 'ab'.repeat(32) + '\nFICUS_SANDBOX_RUNTIME=host\nFICUS_PASSWORD=real\n'
  // The default instance's pm2 name: phase-5 identity, unchanged by the rename.
  const API = localProcessNames('tau').api
  const LEGACY_ECOSYSTEM = `module.exports = { apps: [{ name: '${API}', env: {\n  TAU_PM2_API_NAME: '${API}',\n} }] }\n`
  let dir: string
  beforeEach(() => {
    dir = realpathSync(mkdtempSync(join(tmpdir(), 'ficus-update-env-')))
    writeFileSync(join(dir, 'package.json'), JSON.stringify({ name: 'ficus' }))
    writeFileSync(join(dir, '.env'), LEGACY_ENV)
    writeFileSync(join(dir, 'ecosystem.config.js'), LEGACY_ECOSYSTEM)
  })
  afterEach(() => rmSync(dir, { recursive: true, force: true }))
  const backups = () => readdirSync(dir).filter((name) => name.includes('.pre-ficus-'))

  it('renames .env and ecosystem.config.js before the build and restart commands run', async () => {
    const seen: string[] = []
    const { updater } = manager({
      repoRoot: dir,
      statusPath: join(dir, 'status.json'),
      commandRunner: {
        runAll: async () => {
          seen.push(readFileSync(join(dir, '.env'), 'utf8'))
        },
      },
      gitResponses: CORE_CHANGE,
    })
    const run = await updater.apply({ manual: true })
    expect(run.status).toBe('succeeded')
    expect(seen).toEqual([RENAMED_ENV])
    expect(readFileSync(join(dir, 'ecosystem.config.js'), 'utf8')).toContain(`FICUS_PM2_API_NAME: '${API}',`)
    expect(backups()).toHaveLength(2)
  })

  it('a failed update calls restoreLocalInstallEnv and leaves .env byte-identical to before', async () => {
    const before = readFileSync(join(dir, '.env'))
    const ecosystemBefore = readFileSync(join(dir, 'ecosystem.config.js'))
    const restored: string[][] = []
    const { updater } = manager({
      repoRoot: dir,
      statusPath: join(dir, 'status.json'),
      commandRunner: {
        runAll: async () => {
          // The build ran against the renamed files, then failed.
          expect(readFileSync(join(dir, '.env'), 'utf8')).toBe(RENAMED_ENV)
          throw new Error('bun run build:core exited with 1')
        },
      },
      localInstallEnv: {
        ...defaultLocalInstallEnv,
        restore: async (paths: string[]) => {
          restored.push(paths)
          await defaultLocalInstallEnv.restore(paths)
        },
      },
      gitResponses: CORE_CHANGE,
    })
    await expect(updater.apply({ manual: true })).rejects.toThrow('build:core')
    expect(restored).toEqual([
      [
        join(dir, backups().find((b) => b.startsWith('.env.'))!),
        join(dir, backups().find((b) => b.startsWith('ecosystem.'))!),
      ],
    ])
    expect(readFileSync(join(dir, '.env')).equals(before)).toBe(true)
    expect(readFileSync(join(dir, 'ecosystem.config.js')).equals(ecosystemBefore)).toBe(true)
    expect(updater.status().latest?.status).toBe('failed')
  })

  it('a failed targeted rebuild restores the files too', async () => {
    const before = readFileSync(join(dir, '.env'))
    const { updater } = manager({
      repoRoot: dir,
      statusPath: join(dir, 'status.json'),
      commandRunner: {
        runAll: async () => {
          throw new Error('bun run build:core exited with 1')
        },
      },
      gitResponses: CORE_CHANGE,
    })
    updater.applyInBackground({ manual: true, tasks: ['core'] })
    await waitUntilInactive(updater)
    expect(updater.status().latest?.status).toBe('failed')
    expect(readFileSync(join(dir, '.env')).equals(before)).toBe(true)
  })

  it('refuses conflicting protected values before the merge, naming the key and not the values', async () => {
    const conflicting = 'TAU_PASSWORD=first-secret\nFICUS_PASSWORD=second-secret\n'
    writeFileSync(join(dir, '.env'), conflicting)
    let ran = false
    const { updater, calls } = manager({
      repoRoot: dir,
      statusPath: join(dir, 'status.json'),
      commandRunner: {
        runAll: async () => {
          ran = true
        },
      },
      gitResponses: CORE_CHANGE,
    })
    const error = (await updater.apply({ manual: true }).catch((e: unknown) => e)) as Error
    expect(error.message).toContain('TAU_PASSWORD')
    expect(error.message).toContain('remove the wrong value, then re-run')
    expect(error.message).not.toContain('first-secret')
    expect(error.message).not.toContain('second-secret')
    expect(ran).toBe(false)
    expect(calls.some((cmd) => cmd.includes('merge'))).toBe(false)
    expect(readFileSync(join(dir, '.env'), 'utf8')).toBe(conflicting)
    expect(backups()).toEqual([])
    expect(updater.status().latest?.status).toBe('failed')
  })

  it('leaves a systemd host alone: the setup toolkit owns that rename', async () => {
    const { updater } = manager({
      repoRoot: dir,
      statusPath: join(dir, 'status.json'),
      flavor: () => SYSTEMD_FLAVOR,
      gitResponses: CORE_CHANGE,
    })
    expect((await updater.apply({ manual: true })).status).toBe('succeeded')
    expect(readFileSync(join(dir, '.env'), 'utf8')).toBe(LEGACY_ENV)
    expect(backups()).toEqual([])
  })

  it('keeps both errors when restoring after a failed update fails too', async () => {
    const { updater } = manager({
      repoRoot: dir,
      statusPath: join(dir, 'status.json'),
      commandRunner: {
        runAll: async () => {
          throw new Error('bun run build:core exited with 1')
        },
      },
      localInstallEnv: {
        ...defaultLocalInstallEnv,
        restore: async () => {
          throw new Error('EACCES: permission denied')
        },
      },
      gitResponses: CORE_CHANGE,
    })
    const error = (await updater.apply({ manual: true }).catch((e: unknown) => e)) as AggregateError
    expect(error).toBeInstanceOf(AggregateError)
    expect((error.errors[0] as Error).message).toBe('bun run build:core exited with 1')
    expect((error.errors[1] as Error).message).toBe('EACCES: permission denied')
    expect(updater.status().latest?.error).toContain('bun run build:core exited with 1')
    expect(updater.status().latest?.error).toContain('EACCES: permission denied')
  })

  it('fails closed on a checkout whose package name it cannot read', async () => {
    rmSync(join(dir, 'package.json'))
    const { updater } = manager({ repoRoot: dir, statusPath: join(dir, 'status.json'), gitResponses: CORE_CHANGE })
    expect((await updater.apply({ manual: true })).status).toBe('succeeded')
    expect(readFileSync(join(dir, '.env'), 'utf8')).toBe(LEGACY_ENV)
    expect(backups()).toEqual([])
  })

  it('leaves a checkout that still predates the rename alone after the merge', async () => {
    writeFileSync(join(dir, 'package.json'), JSON.stringify({ name: 'tau' }))
    const { updater } = manager({ repoRoot: dir, statusPath: join(dir, 'status.json'), gitResponses: CORE_CHANGE })
    expect((await updater.apply({ manual: true })).status).toBe('succeeded')
    expect(readFileSync(join(dir, '.env'), 'utf8')).toBe(LEGACY_ENV)
    expect(backups()).toEqual([])
  })
})
