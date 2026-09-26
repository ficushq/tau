import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { isTransportError, runOfflineUpdate, type OfflineUpdateArgs } from './offline-update'
import { defaultRunner, recordingRunner, type Runner } from './runner'
import { makeSupervisorContext, type SupervisorContext } from './supervisor'

const context = (root: string, runner: Runner, label = 'tau') =>
  makeSupervisorContext({
    supervisor: 'pm2',
    root,
    label,
    runner,
    log: () => {},
    home: '/home/me',
    bunPath: '/bin/bun',
    username: 'me',
    uid: 1000,
    platform: 'linux',
    arch: 'x64',
  })

type TestOfflineUpdateArgs = Omit<OfflineUpdateArgs, 'context'> & { context?: SupervisorContext }
const runTestOfflineUpdate = (args: TestOfflineUpdateArgs) =>
  runOfflineUpdate({ ...args, context: args.context ?? context(args.root, args.runner) })

describe('isTransportError', () => {
  it('matches Bun-shaped connection errors by code, including through a cause chain', () => {
    const bunRefused = Object.assign(new Error('Unable to connect. Is the computer able to access the url?'), {
      code: 'ConnectionRefused',
    })
    expect(isTransportError(bunRefused)).toBe(true)
    const wrapped = new Error('request failed', {
      cause: Object.assign(new Error('econnrefused'), { code: 'ECONNREFUSED' }),
    })
    expect(isTransportError(wrapped)).toBe(true)
  })
  it('matches the WHATWG fetch() TypeError only on its exact spec message', () => {
    expect(isTransportError(new TypeError('fetch failed'))).toBe(true)
    expect(isTransportError(new TypeError('x is not a function'))).toBe(false)
  })
  it('does not match on free-text message content', () => {
    expect(isTransportError(new Error('update timed out'))).toBe(false)
    expect(isTransportError(new Error('Unauthorized'))).toBe(false)
    expect(isTransportError(new Error('Update is not supported on this deployment'))).toBe(false)
  })
})

describe('runOfflineUpdate', () => {
  const base = {
    'git status --porcelain': { stdout: '' },
    'git rev-parse HEAD': { stdout: 'a'.repeat(40) + '\n' },
    'git rev-parse --abbrev-ref HEAD': { stdout: 'main\n' },
  }
  it('fetches, fast-forwards the current branch, runs the checkout update and restarts via pm2', async () => {
    let calls = 0
    const rec = recordingRunner(base)
    const runner: typeof rec.runner = async (cmd, opts) => {
      calls++
      if (cmd.join(' ') === 'git rev-parse HEAD' && calls > 4)
        return { code: 0, stdout: 'b'.repeat(40) + '\n', stderr: '' }
      return rec.runner(cmd, opts)
    }
    const result = await runTestOfflineUpdate({ root: '/r', runner, log: () => {} })
    expect(rec.calls.map((c) => c.command.join(' '))).toEqual([
      'git status --porcelain',
      'git rev-parse HEAD',
      'git rev-parse --abbrev-ref HEAD',
      'git pull --ff-only --no-tags',
      'bun run update:offline -- --from ' + 'a'.repeat(40),
      'bunx pm2 restart tau-worker --update-env',
      'bunx pm2 restart tau-api --update-env',
    ])
    expect(result.before).toBe('a'.repeat(40))
    expect(result.after).toBe('b'.repeat(40))
    expect(rec.calls.every((c) => c.options.cwd === '/r')).toBe(true)
  })
  it('restarts the apps of the instance the checkout belongs to, not the default ones', async () => {
    const root = mkdtempSync(join(tmpdir(), 'tau-offline-'))
    try {
      writeFileSync(join(root, '.env'), 'FICUS_INSTANCE=smoke\n')
      const rec = recordingRunner(base)
      await runTestOfflineUpdate({
        root,
        runner: rec.runner,
        log: () => {},
        context: context(root, rec.runner, 'smoke'),
      })
      expect(rec.calls.at(-1)?.command.join(' ')).toBe('bunx pm2 restart tau-smoke-api --update-env')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
  it('fetches only an explicit immutable tag without following unrelated tags', async () => {
    const sha = 'c'.repeat(40)
    const rec = recordingRunner({
      ...base,
      'git check-ref-format --branch v1.2.3': {},
      'git ls-remote --refs --exit-code origin refs/heads/v1.2.3 refs/tags/v1.2.3': {
        stdout: `${sha}\trefs/tags/v1.2.3\n`,
      },
    })
    await runTestOfflineUpdate({ root: '/r', ref: 'v1.2.3', runner: rec.runner, log: () => {} })
    const joined = rec.calls.map((c) => c.command.join(' '))
    expect(joined).toContain('git fetch --no-tags origin refs/tags/v1.2.3:refs/tags/v1.2.3')
    expect(joined).toContain('git checkout --recurse-submodules v1.2.3')
    expect(joined.some((command) => command.includes('fetch --tags'))).toBe(false)
    expect(joined).not.toContain('git pull --ff-only --no-tags')
  })
  it('force-updates only the explicitly requested moving nightly tag', async () => {
    const sha = 'c'.repeat(40)
    const rec = recordingRunner({
      ...base,
      'git check-ref-format --branch nightly': {},
      'git ls-remote --refs --exit-code origin refs/heads/nightly refs/tags/nightly': {
        stdout: `${sha}\trefs/tags/nightly\n`,
      },
    })
    await runTestOfflineUpdate({ root: '/r', ref: 'nightly', runner: rec.runner, log: () => {} })
    expect(rec.calls.map((c) => c.command.join(' '))).toContain(
      'git fetch --no-tags origin +refs/tags/nightly:refs/tags/nightly'
    )
  })
  it('fetches only the requested branch into its remote-tracking ref', async () => {
    const sha = 'c'.repeat(40)
    const rec = recordingRunner({
      ...base,
      'git check-ref-format --branch next': {},
      'git ls-remote --refs --exit-code origin refs/heads/next refs/tags/next': {
        stdout: `${sha}\trefs/heads/next\n`,
      },
    })
    await runTestOfflineUpdate({ root: '/r', ref: 'next', runner: rec.runner, log: () => {} })
    expect(rec.calls.map((c) => c.command.join(' '))).toContain(
      'git fetch --no-tags origin refs/heads/next:refs/remotes/origin/next'
    )
  })
  it('rejects a missing or ambiguous named ref before checkout', async () => {
    const missing = recordingRunner({
      ...base,
      'git check-ref-format --branch missing': {},
      'git ls-remote --refs --exit-code origin refs/heads/missing refs/tags/missing': { code: 2 },
    })
    await expect(
      runTestOfflineUpdate({ root: '/r', ref: 'missing', runner: missing.runner, log: () => {} })
    ).rejects.toThrow(/ref missing was not found/)

    const sha = 'c'.repeat(40)
    const ambiguous = recordingRunner({
      ...base,
      'git check-ref-format --branch same': {},
      'git ls-remote --refs --exit-code origin refs/heads/same refs/tags/same': {
        stdout: `${sha}\trefs/heads/same\n${sha}\trefs/tags/same\n`,
      },
    })
    await expect(
      runTestOfflineUpdate({ root: '/r', ref: 'same', runner: ambiguous.runner, log: () => {} })
    ).rejects.toThrow(/both a branch and a tag/)
  })
  it('fetches an explicit commit without interpreting it as a ref name', async () => {
    const sha = 'c'.repeat(40)
    const rec = recordingRunner(base)
    await runTestOfflineUpdate({ root: '/r', ref: sha, runner: rec.runner, log: () => {} })
    const joined = rec.calls.map((c) => c.command.join(' '))
    expect(joined).toContain(`git fetch --no-tags origin ${sha}`)
    expect(joined).toContain('git checkout --recurse-submodules FETCH_HEAD')
    expect(joined.some((command) => command.includes('ls-remote'))).toBe(false)
  })
  it('refuses a dirty tree', async () => {
    const rec = recordingRunner({ ...base, 'git status --porcelain': { stdout: ' M apps/core/x.ts\n' } })
    await expect(runTestOfflineUpdate({ root: '/r', runner: rec.runner, log: () => {} })).rejects.toThrow(
      /uncommitted changes/
    )
  })
  it('refuses a detached HEAD when no --ref is given', async () => {
    const rec = recordingRunner({ ...base, 'git rev-parse --abbrev-ref HEAD': { stdout: 'HEAD\n' } })
    await expect(runTestOfflineUpdate({ root: '/r', runner: rec.runner, log: () => {} })).rejects.toThrow(
      /detached HEAD/
    )
  })
  it('does not restart when the checkout update fails', async () => {
    const rec = recordingRunner({ ...base, 'bun run update:offline': { code: 1 } })
    await expect(runTestOfflineUpdate({ root: '/r', runner: rec.runner, log: () => {} })).rejects.toThrow(
      /update:offline/
    )
    expect(rec.calls.some((c) => c.command[1] === 'pm2')).toBe(false)
  })

  describe('--ref onto code that predates the Ficus rename', () => {
    let root: string
    beforeEach(() => {
      root = mkdtempSync(join(tmpdir(), 'ficus-offline-downgrade-'))
      writeFileSync(join(root, '.env'), 'FICUS_SANDBOX_RUNTIME=host\nFICUS_PASSWORD=p\n')
    })
    afterEach(() => rmSync(root, { recursive: true, force: true }))
    const tauPackage = { stdout: JSON.stringify({ name: 'tau' }) }
    const sha = 'c'.repeat(40)
    const tag = {
      'git check-ref-format --branch v0.1.0': {},
      'git ls-remote --refs --exit-code origin refs/heads/v0.1.0 refs/tags/v0.1.0': {
        stdout: `${sha}\trefs/tags/v0.1.0\n`,
      },
    }

    it('refuses a tag whose package.json is named "tau" on a renamed install, pointing at the backups', async () => {
      const rec = recordingRunner({ ...base, ...tag, 'git show refs/tags/v0.1.0:package.json': tauPackage })
      const error = (await runTestOfflineUpdate({ root, ref: 'v0.1.0', runner: rec.runner, log: () => {} }).catch(
        (e: unknown) => e
      )) as Error
      expect(error.message).toContain('refusing to check out v0.1.0: it predates the Ficus rename')
      expect(error.message).toContain(`restore ${join(root, '.env.pre-ficus-*')}`)
      expect(error.message).toContain('ecosystem.config.js.pre-ficus-*')
      const joined = rec.calls.map((c) => c.command.join(' '))
      expect(joined).toContain('git fetch --no-tags origin refs/tags/v0.1.0:refs/tags/v0.1.0')
      expect(joined.some((command) => command.startsWith('git checkout'))).toBe(false)
      expect(joined.some((command) => command.includes('update:offline'))).toBe(false)
    })
    it('checks the fetched commit for an explicit sha', async () => {
      const rec = recordingRunner({ ...base, 'git show FETCH_HEAD:package.json': tauPackage })
      await expect(runTestOfflineUpdate({ root, ref: sha, runner: rec.runner, log: () => {} })).rejects.toThrow(
        `refusing to check out ${sha}`
      )
      expect(rec.calls.some((c) => c.command[1] === 'checkout')).toBe(false)
    })
    it('checks the branch git checkout would use: the local one when it exists, else the fetched one', async () => {
      const branch = {
        'git check-ref-format --branch old': {},
        'git ls-remote --refs --exit-code origin refs/heads/old refs/tags/old': { stdout: `${sha}\trefs/heads/old\n` },
      }
      const fetched = recordingRunner({
        ...base,
        ...branch,
        'git show-ref --verify --quiet refs/heads/old': { code: 1 },
        'git show refs/remotes/origin/old:package.json': tauPackage,
      })
      await expect(runTestOfflineUpdate({ root, ref: 'old', runner: fetched.runner, log: () => {} })).rejects.toThrow(
        'refusing to check out old'
      )
      const local = recordingRunner({ ...base, ...branch, 'git show refs/heads/old:package.json': tauPackage })
      await expect(runTestOfflineUpdate({ root, ref: 'old', runner: local.runner, log: () => {} })).rejects.toThrow(
        'refusing to check out old'
      )
    })
    it('allows a ref that is already a Ficus release', async () => {
      const rec = recordingRunner({
        ...base,
        ...tag,
        'git show refs/tags/v0.1.0:package.json': { stdout: JSON.stringify({ name: 'ficus' }) },
      })
      await runTestOfflineUpdate({ root, ref: 'v0.1.0', runner: rec.runner, log: () => {} })
      expect(rec.calls.map((c) => c.command.join(' '))).toContain('git checkout --recurse-submodules v0.1.0')
    })
    it('does not look when the install has not been renamed yet', async () => {
      writeFileSync(join(root, '.env'), 'TAU_PASSWORD=p\n')
      const rec = recordingRunner({ ...base, ...tag, 'git show refs/tags/v0.1.0:package.json': tauPackage })
      await runTestOfflineUpdate({ root, ref: 'v0.1.0', runner: rec.runner, log: () => {} })
      expect(rec.calls.some((c) => c.command[1] === 'show')).toBe(false)
    })
  })

  describe('a local install whose .env predates the Ficus rename', () => {
    const legacy = 'TAU_SANDBOX_RUNTIME=host\nTAU_PASSWORD=real-password\n'
    const renamed = 'FICUS_SANDBOX_RUNTIME=host\nFICUS_PASSWORD=real-password\n'
    let root: string
    beforeEach(() => {
      root = mkdtempSync(join(tmpdir(), 'ficus-offline-env-'))
      // The package name after the pull decides: a Ficus checkout reads FICUS_.
      writeFileSync(join(root, 'package.json'), JSON.stringify({ name: 'ficus' }))
      writeFileSync(join(root, '.env'), legacy)
    })
    afterEach(() => rmSync(root, { recursive: true, force: true }))
    const backups = () => readdirSync(root).filter((name) => name.includes('.pre-ficus-'))
    /** Records what .env said when the checkout update and the first restart ran. */
    function watching(responses: Record<string, { code?: number; stdout?: string }> = {}) {
      const rec = recordingRunner({ ...base, ...responses })
      const seen: Record<string, string> = {}
      const runner: Runner = async (command, options) => {
        const key = command.join(' ').startsWith('bun run update:offline')
          ? 'update'
          : command[1] === 'pm2'
            ? 'restart'
            : ''
        if (key && seen[key] === undefined) seen[key] = readFileSync(join(root, '.env'), 'utf8')
        return rec.runner(command, options)
      }
      return { runner, seen, calls: rec.calls }
    }

    it('is renamed after the checkout update succeeds and before the restart, with a backup', async () => {
      const { runner, seen } = watching()
      const logs: string[] = []
      await runTestOfflineUpdate({ root, runner, log: (line) => logs.push(line) })
      // The build and migration run on the untouched file; the restart reads the renamed one.
      expect(seen.update).toBe(legacy)
      expect(seen.restart).toBe(renamed)
      expect(backups()).toHaveLength(1)
      expect(readFileSync(join(root, backups()[0]), 'utf8')).toBe(legacy)
      expect(logs).toContain(`Renamed TAU_ settings to FICUS_ in .env (backup: ${backups()[0]})`)
    })
    it('is left alone when the checkout update fails', async () => {
      const { runner } = watching({ 'bun run update:offline': { code: 1 } })
      await expect(runTestOfflineUpdate({ root, runner, log: () => {} })).rejects.toThrow(/update:offline/)
      expect(readFileSync(join(root, '.env'), 'utf8')).toBe(legacy)
      expect(backups()).toEqual([])
    })
    it('is left alone when the updated checkout still predates the rename', async () => {
      writeFileSync(join(root, 'package.json'), JSON.stringify({ name: 'tau' }))
      const { runner, calls } = watching()
      await runTestOfflineUpdate({ root, runner, log: () => {} })
      expect(calls.some((c) => c.command[1] === 'pm2')).toBe(true)
      expect(readFileSync(join(root, '.env'), 'utf8')).toBe(legacy)
      expect(backups()).toEqual([])
    })
    it('stops a conflicting password before pulling, building or restarting anything', async () => {
      const conflicting = 'TAU_PASSWORD=first-secret\nFICUS_PASSWORD=second-secret\n'
      writeFileSync(join(root, '.env'), conflicting)
      const { runner, calls } = watching()
      const error = (await runTestOfflineUpdate({ root, runner, log: () => {} }).catch((e: unknown) => e)) as Error
      expect(error.message).toContain('TAU_PASSWORD')
      expect(error.message).toContain('remove the wrong value, then re-run')
      expect(error.message).not.toContain('first-secret')
      expect(error.message).not.toContain('second-secret')
      expect(calls.map((c) => c.command.join(' '))).toEqual([])
      expect(readFileSync(join(root, '.env'), 'utf8')).toBe(conflicting)
      expect(backups()).toEqual([])
    })
    it('stops a conflicting password before pulling even while the checkout still predates the rename', async () => {
      // R6: the pull is what moves the checkout onto code that renames.
      writeFileSync(join(root, 'package.json'), JSON.stringify({ name: 'tau' }))
      writeFileSync(join(root, '.env'), 'TAU_PASSWORD=first-secret\nFICUS_PASSWORD=second-secret\n')
      const { runner, calls } = watching()
      await expect(runTestOfflineUpdate({ root, runner, log: () => {} })).rejects.toThrow('TAU_PASSWORD')
      expect(calls).toEqual([])
    })
  })
})

async function git(cwd: string, ...args: string[]): Promise<string> {
  const result = await defaultRunner(['git', ...args], { cwd })
  if (result.code !== 0) throw new Error(`git ${args.join(' ')} failed: ${result.stderr || result.stdout}`)
  return result.stdout.trim()
}

async function createGitFixture(tags: string[] = []) {
  const root = mkdtempSync(join(tmpdir(), 'tau-offline-git-'))
  const remote = join(root, 'remote.git')
  const source = join(root, 'source')
  const checkout = join(root, 'checkout')
  await git(root, 'init', '--bare', remote)
  await git(root, 'init', '--initial-branch=main', source)
  await git(source, 'config', 'user.email', 'test@example.com')
  await git(source, 'config', 'user.name', 'Tau Test')
  writeFileSync(join(source, 'version.txt'), 'one\n')
  await git(source, 'add', 'version.txt')
  await git(source, 'commit', '-m', 'one')
  for (const tag of tags) await git(source, 'tag', tag)
  await git(source, 'remote', 'add', 'origin', remote)
  await git(source, 'push', '--set-upstream', 'origin', 'main', '--tags')
  await git(remote, 'symbolic-ref', 'HEAD', 'refs/heads/main')
  await git(root, 'clone', remote, checkout)

  const runner: Runner = async (command, options = {}) => {
    if (command[0] === 'git') return defaultRunner(command, options)
    return { code: 0, stdout: '', stderr: '' }
  }
  const advance = async (...movedTags: string[]) => {
    writeFileSync(join(source, 'version.txt'), 'two\n')
    await git(source, 'add', 'version.txt')
    await git(source, 'commit', '-m', 'two')
    await git(source, 'push', 'origin', 'main')
    for (const tag of movedTags) {
      await git(source, 'tag', '--force', tag)
      await git(source, 'push', '--force', 'origin', `refs/tags/${tag}`)
    }
    return git(source, 'rev-parse', 'HEAD')
  }
  return { root, remote, source, checkout, runner, advance }
}

describe('runOfflineUpdate git integration', () => {
  it('accepts an unchanged nightly tag and is repeatable', async () => {
    const fixture = await createGitFixture(['nightly'])
    try {
      const expected = await git(fixture.checkout, 'rev-parse', 'refs/tags/nightly')
      const first = await runTestOfflineUpdate({
        root: fixture.checkout,
        ref: 'nightly',
        runner: fixture.runner,
        log: () => {},
      })
      const second = await runTestOfflineUpdate({
        root: fixture.checkout,
        ref: 'nightly',
        runner: fixture.runner,
        log: () => {},
      })
      expect(first.after).toBe(expected)
      expect(second).toEqual({ before: expected, after: expected })
    } finally {
      rmSync(fixture.root, { recursive: true, force: true })
    }
  })

  it('updates a moved nightly tag without touching an unrelated conflicting tag', async () => {
    const fixture = await createGitFixture(['nightly', 'unrelated'])
    try {
      const oldUnrelated = await git(fixture.checkout, 'rev-parse', 'refs/tags/unrelated')
      const expected = await fixture.advance('nightly', 'unrelated')
      const result = await runTestOfflineUpdate({
        root: fixture.checkout,
        ref: 'nightly',
        runner: fixture.runner,
        log: () => {},
      })
      expect(result.after).toBe(expected)
      expect(await git(fixture.checkout, 'rev-parse', 'refs/tags/nightly')).toBe(expected)
      expect(await git(fixture.checkout, 'rev-parse', 'refs/tags/unrelated')).toBe(oldUnrelated)
    } finally {
      rmSync(fixture.root, { recursive: true, force: true })
    }
  })

  it('fetches and checks out a release tag that is not yet local', async () => {
    const fixture = await createGitFixture()
    try {
      await git(fixture.source, 'tag', 'v1.2.3')
      await git(fixture.source, 'push', 'origin', 'refs/tags/v1.2.3')
      const expected = await git(fixture.source, 'rev-parse', 'HEAD')
      const result = await runTestOfflineUpdate({
        root: fixture.checkout,
        ref: 'v1.2.3',
        runner: fixture.runner,
        log: () => {},
      })
      expect(result.after).toBe(expected)
      expect(await git(fixture.checkout, 'rev-parse', 'refs/tags/v1.2.3')).toBe(expected)
    } finally {
      rmSync(fixture.root, { recursive: true, force: true })
    }
  })

  it('does not rewrite a disagreeing immutable release tag', async () => {
    const fixture = await createGitFixture(['v1.2.3'])
    try {
      const pinned = await git(fixture.checkout, 'rev-parse', 'refs/tags/v1.2.3')
      await fixture.advance('v1.2.3')
      await expect(
        runTestOfflineUpdate({ root: fixture.checkout, ref: 'v1.2.3', runner: fixture.runner, log: () => {} })
      ).rejects.toThrow(/would clobber existing tag/)
      expect(await git(fixture.checkout, 'rev-parse', 'refs/tags/v1.2.3')).toBe(pinned)
    } finally {
      rmSync(fixture.root, { recursive: true, force: true })
    }
  })

  it('fails clearly for a missing ref and for a genuine fetch failure', async () => {
    const fixture = await createGitFixture()
    try {
      await expect(
        runTestOfflineUpdate({ root: fixture.checkout, ref: 'missing', runner: fixture.runner, log: () => {} })
      ).rejects.toThrow(/ref missing was not found/)
      await git(fixture.checkout, 'remote', 'set-url', 'origin', join(fixture.root, 'does-not-exist.git'))
      await expect(
        runTestOfflineUpdate({ root: fixture.checkout, runner: fixture.runner, log: () => {} })
      ).rejects.toThrow(/git pull --ff-only --no-tags failed/)
    } finally {
      rmSync(fixture.root, { recursive: true, force: true })
    }
  })

  it('fast-forwards a branch without following a moved tag', async () => {
    const fixture = await createGitFixture(['nightly'])
    try {
      const oldNightly = await git(fixture.checkout, 'rev-parse', 'refs/tags/nightly')
      const expected = await fixture.advance('nightly')
      const result = await runTestOfflineUpdate({ root: fixture.checkout, runner: fixture.runner, log: () => {} })
      expect(result.after).toBe(expected)
      expect(await git(fixture.checkout, 'rev-parse', 'refs/tags/nightly')).toBe(oldNightly)
    } finally {
      rmSync(fixture.root, { recursive: true, force: true })
    }
  })
})
