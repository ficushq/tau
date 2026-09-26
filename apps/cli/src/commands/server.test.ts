import { afterEach, beforeEach, describe, expect, it, mock } from 'bun:test'
import { Command } from 'commander'
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'fs'
import { homedir, tmpdir } from 'os'
import { join } from 'path'
import { isJsonMode, output, outputError, setOutputOptions } from '../output'
import { recordingRunner } from '../local-server/runner'
import { readRegistry, upsertInstance } from '../local-server/state'
import { registerServerCommands, type ServerDeps } from './server'

let root: string
let statePath: string
let savedExitCode: number | string | undefined
beforeEach(() => {
  root = realpathSync(mkdtempSync(join(tmpdir(), 'tau-server-')))
  mkdirSync(join(root, '.git'))
  writeFileSync(join(root, 'package.json'), JSON.stringify({ name: 'tau' }))
  writeFileSync(
    join(root, '.env'),
    'PORT=3000\nDATABASE_URL=postgres://postgres:postgres@localhost:5432/tau\nFICUS_SANDBOX_RUNTIME=host\n'
  )
  statePath = join(root, 'state.json')
  upsertInstance(
    'tau',
    { root, port: 3000, supervisor: 'pm2', createdAt: 't', updatedAt: 't' },
    { makeDefault: true },
    statePath
  )
  ;(output as ReturnType<typeof mock>).mockClear()
  ;(outputError as ReturnType<typeof mock>).mockClear()
  ;(setOutputOptions as ReturnType<typeof mock>).mockClear()
  // guarded() sets process.exitCode on error paths; save/reset so one test's
  // failure path doesn't leak into `bun test`'s own exit code.
  savedExitCode = process.exitCode
  process.exitCode = 0
})
afterEach(() => {
  rmSync(root, { recursive: true, force: true })
  process.exitCode = savedExitCode
})

function make(
  responses: Record<string, { code?: number; stdout?: string; stderr?: string }> = {},
  depsOverrides: Partial<ServerDeps> = {}
) {
  const rec = recordingRunner({ 'bunx pm2 jlist': { stdout: '[]' }, ...responses })
  const deps: ServerDeps = {
    runner: rec.runner,
    env: {},
    cwd: tmpdir(),
    statePath,
    fetch: async () => new Response('{"status":"ok"}', { status: 200 }),
    isTTY: false,
    prompter: { select: async () => 'host', confirm: async () => true },
    sleep: async () => {},
    which: (cmd) => (['git', 'bun'].includes(cmd) ? `/usr/bin/${cmd}` : null),
    ...depsOverrides,
  }
  async function run(args: string[]) {
    const program = new Command()
    program.exitOverride()
    registerServerCommands(program, deps)
    await program.parseAsync(args, { from: 'user' })
  }
  return { run, calls: rec.calls, deps }
}

const joined = (calls: { command: string[] }[]) => calls.map((c) => c.command.join(' '))

/** A recording runner whose `git clone` actually creates a fake checkout at `installRoot`. */
function cloningRunner(installRoot: string) {
  const rec = recordingRunner({ 'bun --version': { stdout: '1.3.8\n' } })
  const runner = async (
    command: string[],
    options?: { cwd?: string; env?: Record<string, string | undefined>; inherit?: boolean }
  ) => {
    const r = await rec.runner(command, options)
    if (command[0] === 'git' && command[1] === 'clone') {
      mkdirSync(join(installRoot, '.git'), { recursive: true })
      writeFileSync(join(installRoot, 'package.json'), JSON.stringify({ name: 'tau' }))
      writeFileSync(join(installRoot, '.bun-version'), '1.3.8\n')
    }
    return r
  }
  return { runner, calls: rec.calls }
}

describe('tau server', () => {
  it('start brings up the managed postgres container and pm2 from the state-file root', async () => {
    const { run, calls } = make({ 'docker inspect': { stdout: 'true\n' } })
    await run(['server', 'start'])
    expect(joined(calls)).toEqual([
      'docker inspect -f {{.State.Running}} postgres-tau',
      'docker exec postgres-tau psql -h 127.0.0.1 -U postgres -tAc SELECT 1',
      'docker exec postgres-tau psql -h 127.0.0.1 -U postgres -tAc SELECT 1',
      'docker exec postgres-tau psql -h 127.0.0.1 -U postgres -tAc SELECT 1',
      'bunx pm2 start ecosystem.config.js --only tau-api,tau-worker --update-env',
    ])
    expect(calls.at(-1)?.options.cwd).toBe(root)
  })
  it('start creates the instance container, volume and port when it does not exist yet', async () => {
    writeFileSync(
      join(root, '.env'),
      'FICUS_INSTANCE=smoke\nPORT=3100\nDATABASE_URL=postgres://postgres:postgres@localhost:5433/tau\n'
    )
    const { run, calls } = make({ 'docker inspect': { code: 1, stderr: 'Error: No such object' } })
    await run(['server', 'start'])
    expect(joined(calls)).toEqual([
      'docker inspect -f {{.State.Running}} postgres-tau',
      'docker run -d --name postgres-tau --restart unless-stopped -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=tau -p 127.0.0.1:5433:5432 -v tau_postgres-data:/var/lib/postgresql paradedb/paradedb:latest',
      'docker exec postgres-tau psql -h 127.0.0.1 -U postgres -tAc SELECT 1',
      'docker exec postgres-tau psql -h 127.0.0.1 -U postgres -tAc SELECT 1',
      'docker exec postgres-tau psql -h 127.0.0.1 -U postgres -tAc SELECT 1',
      'bunx pm2 start ecosystem.config.js --only tau-api,tau-worker --update-env',
    ])
    // The pull's progress needs the terminal; the inspect it branches on must not have it.
    expect(calls.find((c) => c.command[1] === 'run')?.options.inherit).toBe(true)
    expect(calls.find((c) => c.command[1] === 'inspect')?.options.inherit).toBeFalsy()
  })
  it('narrates the container start, but not under --json', async () => {
    const capture = async (json: boolean) => {
      const { run } = make({ 'docker inspect': { stdout: 'true\n' } })
      const printed: string[] = []
      const realLog = console.log
      console.log = (line?: unknown) => void printed.push(String(line))
      ;(isJsonMode as ReturnType<typeof mock>).mockReturnValue(json)
      try {
        await run(['server', 'start'])
      } finally {
        console.log = realLog
        ;(isJsonMode as ReturnType<typeof mock>).mockReturnValue(false)
      }
      return printed.some((l) => l.includes('Starting PostgreSQL container postgres-tau'))
    }
    // A pull can take minutes, so say so — unless --json promised one
    // machine-readable document on stdout.
    expect(await capture(false)).toBe(true)
    expect(await capture(true)).toBe(false)
  })
  it('start touches no container for an external database', async () => {
    writeFileSync(join(root, '.env'), 'DATABASE_URL=postgres://u:p@db.example:5432/x\n')
    const { run, calls } = make()
    await run(['server', 'start'])
    expect(joined(calls)).toEqual(['bunx pm2 start ecosystem.config.js --only tau-api,tau-worker --update-env'])
  })
  it('start leaves a native loopback PostgreSQL alone and still starts pm2', async () => {
    // Loopback with the operator's own credentials is not our container (setup
    // treats it as external): a docker run on its port would only fail with
    // "port is already allocated" and pm2 would never be reached.
    writeFileSync(join(root, '.env'), 'DATABASE_URL=postgres://me:pw@localhost:5432/app\n')
    const { run, calls } = make()
    await run(['server', 'start'])
    expect(joined(calls)).toEqual(['bunx pm2 start ecosystem.config.js --only tau-api,tau-worker --update-env'])
  })
  it('stop and restart address the two apps', async () => {
    const { run, calls } = make()
    await run(['server', 'stop'])
    await run(['server', 'restart'])
    expect(joined(calls)).toEqual([
      'bunx pm2 stop tau-api tau-worker',
      'bunx pm2 restart tau-worker --update-env',
      'bunx pm2 restart tau-api --update-env',
    ])
  })
  describe('on a Ficus checkout whose .env predates the rename', () => {
    const legacy =
      'TAU_SANDBOX_RUNTIME=host\nTAU_PASSWORD=real-password\nDATABASE_URL=postgres://u:p@db.example:5432/x\n'
    const renamed =
      'FICUS_SANDBOX_RUNTIME=host\nFICUS_PASSWORD=real-password\nDATABASE_URL=postgres://u:p@db.example:5432/x\n'
    beforeEach(() => {
      writeFileSync(join(root, 'package.json'), JSON.stringify({ name: 'ficus' }))
      writeFileSync(join(root, '.env'), legacy)
    })
    /** A runner that remembers what .env said when the first supervisor command ran. */
    function watching() {
      const rec = recordingRunner({ 'bunx pm2 jlist': { stdout: '[]' } })
      const seen: { env?: string } = {}
      const runner: typeof rec.runner = async (command, options) => {
        if (command[0] === 'bunx' && seen.env === undefined) seen.env = readFileSync(join(root, '.env'), 'utf8')
        return rec.runner(command, options)
      }
      return { runner, seen, calls: rec.calls }
    }
    const backups = () => readdirSync(root).filter((name) => name.includes('.pre-ficus-'))

    for (const verb of ['start', 'restart']) {
      it(`${verb} renames TAU_ settings to FICUS_ before any process starts`, async () => {
        const { runner, seen } = watching()
        const { run } = make({}, { runner })
        await run(['server', verb])
        expect(outputError).not.toHaveBeenCalled()
        expect(seen.env).toBe(renamed)
        expect(backups()).toHaveLength(1)
        expect(readFileSync(join(root, backups()[0]), 'utf8')).toBe(legacy)
      })
      it(`${verb} stops on conflicting passwords without touching a file or starting anything`, async () => {
        const conflicting = 'TAU_PASSWORD=first-secret\nFICUS_PASSWORD=second-secret\n'
        writeFileSync(join(root, '.env'), conflicting)
        const { runner, calls } = watching()
        const { run } = make({}, { runner })
        await run(['server', verb])
        expect(calls).toEqual([])
        const [error] = (outputError as ReturnType<typeof mock>).mock.calls.at(-1) as [Error]
        expect(error.message).toContain('TAU_PASSWORD')
        expect(error.message).toContain('remove the wrong value, then re-run')
        expect(error.message).not.toContain('first-secret')
        expect(error.message).not.toContain('second-secret')
        expect(readFileSync(join(root, '.env'), 'utf8')).toBe(conflicting)
        expect(backups()).toEqual([])
      })
    }
    // M4. start/restart only reach a registered checkout (package.json "tau" or "ficus"), so the
    // warning a --json run must carry here is the rename's own: a PM2 name line it left alone.
    it('reports what the rename left alone in the --json document instead of on stdout', async () => {
      writeFileSync(
        join(root, 'ecosystem.config.js'),
        "module.exports = { apps: [{ env: {\n  TAU_PM2_API_NAME:\n    'x',\n} }] }\n"
      )
      const warning =
        "TAU_PM2_API_NAME in ecosystem.config.js was not renamed to FICUS_PM2_API_NAME: it is not a single `TAU_PM2_API_NAME: '<name>',` line; rename it by hand"
      for (const verb of ['start', 'restart']) {
        const { runner } = watching()
        const { run } = make({}, { runner })
        const printed: string[] = []
        const realLog = console.log
        console.log = (line?: unknown) => void printed.push(String(line))
        ;(isJsonMode as ReturnType<typeof mock>).mockReturnValue(true)
        try {
          await run(['server', verb])
        } finally {
          console.log = realLog
          ;(isJsonMode as ReturnType<typeof mock>).mockReturnValue(false)
        }
        const [data] = (output as ReturnType<typeof mock>).mock.calls.at(-1) as [Record<string, unknown>]
        expect(data.warnings).toEqual([warning])
        expect(printed.some((line) => line.includes('not renamed'))).toBe(false)
      }
    })
    it('start leaves a checkout that predates the rename alone: its code reads TAU_', async () => {
      writeFileSync(join(root, 'package.json'), JSON.stringify({ name: 'tau' }))
      const { runner } = watching()
      const { run } = make({}, { runner })
      await run(['server', 'start'])
      expect(readFileSync(join(root, '.env'), 'utf8')).toBe(legacy)
      expect(backups()).toEqual([])
    })
  })
  it('start and restart warn when the built web bundle was made for a different base path', async () => {
    writeFileSync(
      join(root, '.env'),
      'PORT=3000\nDATABASE_URL=postgres://user:pw@db.example.com:5432/tau\nAPP_BASE_PATH=/tau\n'
    )
    mkdirSync(join(root, 'apps', 'web', 'dist'), { recursive: true })
    writeFileSync(
      join(root, 'apps', 'web', 'dist', 'index.html'),
      '<script type="module" crossorigin src="/assets/index-abc.js"></script>'
    )
    const capture = async (args: string[], json: boolean) => {
      const { run } = make()
      const printed: string[] = []
      const realLog = console.log
      console.log = (line?: unknown) => void printed.push(String(line))
      ;(isJsonMode as ReturnType<typeof mock>).mockReturnValue(json)
      try {
        await run(args)
      } finally {
        console.log = realLog
        ;(isJsonMode as ReturnType<typeof mock>).mockReturnValue(false)
      }
      const [data] = (output as ReturnType<typeof mock>).mock.calls.at(-1) as [Record<string, unknown>]
      return { printed, data }
    }
    for (const verb of ['start', 'restart']) {
      const { printed, data } = await capture(['server', verb], false)
      const line = printed.find((l) => l.includes('warning:'))
      expect(line).toContain('built for base "/"')
      expect(line).toContain('APP_BASE_PATH=/tau')
      expect(line).toContain('bun run build:web')
      expect(data.warnings).toEqual([expect.stringContaining('built for base "/"')])
    }
    // --json promised one machine-readable document: the warning rides in it, not stdout.
    const { printed, data } = await capture(['server', 'restart'], true)
    expect(printed.some((l) => l.includes('warning:'))).toBe(false)
    expect(data.warnings).toEqual([expect.stringContaining('built for base "/"')])
  })
  it('start and restart stay quiet when the bundle matches the base path', async () => {
    writeFileSync(join(root, '.env'), 'PORT=3000\nAPP_BASE_PATH=/tau\n')
    mkdirSync(join(root, 'apps', 'web', 'dist'), { recursive: true })
    writeFileSync(
      join(root, 'apps', 'web', 'dist', 'index.html'),
      '<script type="module" crossorigin src="/tau/assets/index-abc.js"></script>'
    )
    const { run } = make()
    await run(['server', 'restart'])
    const [data] = (output as ReturnType<typeof mock>).mock.calls.at(-1) as [Record<string, unknown>]
    expect(data.warnings).toBeUndefined()
  })
  it('status reports root, processes and health', async () => {
    const { run } = make({
      'bunx pm2 jlist': {
        stdout: JSON.stringify([{ name: 'tau-api', pid: 5, pm2_env: { status: 'online', pm_cwd: root } }]),
      },
      'git rev-parse --short HEAD': { stdout: 'abc1234\n' },
    })
    await run(['server', 'status'])
    const [data] = (output as ReturnType<typeof mock>).mock.calls.at(-1) as [Record<string, unknown>]
    expect(data.root).toBe(root)
    expect(data.instance).toBe('tau')
    expect(data.port).toBe(3000)
    expect(data.runtime).toBe('host')
    expect(data.commit).toBe('abc1234')
    expect(data.health).toBe('ok')
    expect((data.processes as { name: string; status: string }[])[0]).toEqual({
      name: 'tau-api',
      status: 'online',
      pid: 5,
      cwd: root,
    })
  })
  it('status reports the instance label and its pm2 apps', async () => {
    writeFileSync(join(root, '.env'), 'FICUS_INSTANCE=smoke\nPORT=3100\n')
    const { run, calls } = make()
    await run(['server', 'status'])
    const [data, text] = (output as ReturnType<typeof mock>).mock.calls.at(-1) as [Record<string, unknown>, string]
    expect(data.instance).toBe('tau')
    expect(text).toContain('instance: tau')
    expect(text).toContain('tau-api: not registered')
    expect(joined(calls)).toContain('bunx pm2 jlist')
  })
  it('probes the public root /health route (/api/health is 401-only behind identity middleware)', async () => {
    const { run, deps } = make()
    const urls: string[] = []
    deps.fetch = async (input) => {
      urls.push(String(input))
      return new Response('{"status":"ok"}', { status: 200 })
    }
    await run(['server', 'status'])
    expect(urls).toEqual(['http://localhost:3000/health'])
  })
  it('status treats a 401 health probe as ok (auth-gated /api/*, not a downed API)', async () => {
    const { run, deps } = make()
    deps.fetch = async () => new Response('', { status: 401 })
    await run(['server', 'status'])
    const [data] = (output as ReturnType<typeof mock>).mock.calls.at(-1) as [Record<string, unknown>]
    expect(data.health).toBe('ok')
  })
  it('status reports a non-401 error status verbatim', async () => {
    const { run, deps } = make()
    deps.fetch = async () => new Response('', { status: 503 })
    await run(['server', 'status'])
    const [data] = (output as ReturnType<typeof mock>).mock.calls.at(-1) as [Record<string, unknown>]
    expect(data.health).toBe('http 503')
  })
  it('logs passes component and line count through to pm2', async () => {
    const { run, calls } = make()
    await run(['server', 'logs', '-c', 'worker', '-n', '20'])
    expect(joined(calls)).toEqual(['bunx pm2 logs tau-worker --lines 20 --nostream'])
    await run(['server', 'logs', '-f'])
    expect(joined(calls).at(-1)).toBe('bunx pm2 logs tau-api tau-worker --lines 100')
    expect(calls.at(-1)?.options.inherit).toBe(true)
  })
  it('logs reports a non-zero pm2 exit through outputError', async () => {
    const { run } = make({ 'bunx pm2 logs': { code: 1 } })
    await run(['server', 'logs'])
    expect(outputError).toHaveBeenCalled()
  })
  it('logs rejects a non-integer --lines without calling pm2', async () => {
    const { run, calls } = make()
    await run(['server', 'logs', '-n', 'abc'])
    expect(outputError).toHaveBeenCalled()
    expect(calls.some((c) => c.command.join(' ').startsWith('bunx pm2 logs'))).toBe(false)
  })
  it('uninstall deletes pm2 apps, saves, removes the state file and names the volume docker actually has', async () => {
    const { run, calls } = make({
      'docker inspect -f {{json .Mounts}}': {
        stdout: JSON.stringify([{ Type: 'volume', Name: 'taumain_postgres-data', Destination: '/var/lib/postgresql' }]),
      },
    })
    await run(['server', 'uninstall', '--yes'])
    expect(joined(calls)).toEqual([
      'bunx pm2 delete tau-api tau-worker',
      'bunx pm2 save',
      'docker inspect -f {{json .Mounts}} postgres-tau',
    ])
    expect(readRegistry(statePath).instances).toEqual({})
    const [data, message] = (output as ReturnType<typeof mock>).mock.calls.at(-1) as [Record<string, unknown>, string]
    expect(message).toContain(root)
    // The discovered compose project name, not the derived instance name.
    expect(message).toContain('docker rm -f postgres-tau && docker volume rm taumain_postgres-data')
    expect(data.kept).toContain('taumain_postgres-data')
    expect(message).toContain('~/.tau')
    expect(message).toContain('removed instance "tau"')
  })
  it('uninstall falls back to the derived volume name when docker cannot answer', async () => {
    const { run } = make({ 'docker inspect -f {{json .Mounts}}': { code: 1, stdout: '' } })
    await run(['server', 'uninstall', '--yes'])
    const message = (output as ReturnType<typeof mock>).mock.calls.at(-1)?.[1] as string
    expect(message).toContain('docker rm -f postgres-tau && docker volume rm tau_postgres-data')
  })
  it('uninstall names the labelled instance own container, volume and data directory', async () => {
    writeFileSync(join(root, '.env'), 'FICUS_INSTANCE=smoke\nHOME_DIR=~/.tau-smoke\n')
    const { run, calls } = make()
    await run(['server', 'uninstall', '--yes'])
    // The registry resolves the default instance's names; the volume probe
    // still runs (empty answer → derived-name fallback, asserted below).
    expect(joined(calls)).toEqual([
      'bunx pm2 delete tau-api tau-worker',
      'bunx pm2 save',
      'docker inspect -f {{json .Mounts}} postgres-tau',
    ])
    const message = (output as ReturnType<typeof mock>).mock.calls.at(-1)?.[1] as string
    expect(message).toContain('docker rm -f postgres-tau && docker volume rm tau_postgres-data')
    expect(message).toContain('~/.tau-smoke')
  })
  it('uninstall leaves the registry alone for a checkout nobody registered', async () => {
    const other = realpathSync(mkdtempSync(join(tmpdir(), 'tau-other-')))
    mkdirSync(join(other, '.git'))
    writeFileSync(join(other, 'package.json'), JSON.stringify({ name: 'tau' }))
    const { run, calls } = make()
    await run(['server', 'uninstall', '--root', other, '--yes'])
    expect(joined(calls)).toEqual([])
    expect(outputError).toHaveBeenCalled()
    // The registered instance (a different checkout) is untouched.
    expect(readRegistry(statePath).instances.tau?.root).toBe(root)
    const [error] = (outputError as ReturnType<typeof mock>).mock.calls.at(-1) as [Error]
    expect(error.message).toContain('not registered')
    rmSync(other, { recursive: true, force: true })
  })
  // A checkout deleted by hand (an old worktree, a scratch dir) leaves a
  // registry entry nothing can resolve; `--instance` must still be able to
  // retire it, cleaning the supervisor up as far as it can.
  it('uninstall --instance retires a registration whose checkout no longer exists', async () => {
    const gone = join(tmpdir(), `tau-gone-${process.pid}`)
    upsertInstance(
      'smoke',
      { root: gone, port: 3100, supervisor: 'pm2', createdAt: 't', updatedAt: 't' },
      {},
      statePath
    )
    const { run, calls } = make()
    await run(['server', 'uninstall', '--instance', 'smoke', '--yes'])
    expect(outputError).not.toHaveBeenCalled()
    expect(joined(calls)).toEqual(['bunx pm2 delete tau-smoke-api tau-smoke-worker', 'bunx pm2 save'])
    // pm2 ran somewhere that exists, not in the vanished checkout.
    expect(calls.every((c) => c.options.cwd !== gone)).toBe(true)
    expect(readRegistry(statePath).instances).toEqual({
      tau: expect.objectContaining({ root }),
    })
    const [data, message] = (output as ReturnType<typeof mock>).mock.calls.at(-1) as [Record<string, unknown>, string]
    expect(data.unregistered).toBe('smoke')
    expect(message).toContain(`removed instance "smoke"`)
    expect(message).toContain('no longer exists')
    expect(message).toContain('docker rm -f postgres-tau-smoke && docker volume rm tau-smoke_postgres-data')
    expect(message).toContain('~/.tau-smoke')
  })
  it('uninstall --instance of a vanished checkout still removes the registration when the supervisor cleanup fails', async () => {
    const gone = join(tmpdir(), `tau-gone-${process.pid}-b`)
    upsertInstance(
      'smoke',
      { root: gone, port: 3100, supervisor: 'pm2', createdAt: 't', updatedAt: 't' },
      {},
      statePath
    )
    const { run } = make({ 'bunx pm2 delete': { code: 1, stderr: 'pm2 is not running' } })
    await run(['server', 'uninstall', '--instance', 'smoke', '--yes'])
    expect(outputError).not.toHaveBeenCalled()
    expect(readRegistry(statePath).instances.smoke).toBeUndefined()
    const message = (output as ReturnType<typeof mock>).mock.calls.at(-1)?.[1] as string
    expect(message).toContain('supervisor cleanup failed')
  })
  it('uninstall refuses to prompt on a non-TTY without --yes', async () => {
    const { run, calls } = make()
    await run(['server', 'uninstall'])
    expect(outputError).toHaveBeenCalled()
    const [error] = (outputError as ReturnType<typeof mock>).mock.calls.at(-1) as [Error]
    expect(error.message).toBe('uninstall needs a terminal to confirm — pass --yes')
    expect(calls.some((c) => c.command[0] === 'bunx' && c.command[1] === 'pm2')).toBe(false)
  })
  it('bootstrap-sysbox runs the guarded plan on a capable host', async () => {
    const capable = {
      platform: 'linux' as NodeJS.Platform,
      arch: 'x64',
      kernelRelease: '6.8.0-40-generic',
      systemdActive: true,
      wsl: false,
      which: (cmd: string) => `/usr/bin/${cmd}`,
    }
    const { run, calls } = make(
      { 'docker ps': { stdout: 'web\n' }, 'docker info --format': { stdout: '{"sysbox-runc":{}}' } },
      { sysboxHost: capable }
    )
    await run(['server', 'bootstrap-sysbox', '--yes'])
    const joinedCalls = calls.map((c) => c.command.join(' '))
    expect(joinedCalls).toContain('docker rm -f web')
    expect(joinedCalls.some((c) => c.startsWith('sudo dpkg -i'))).toBe(true)
    expect(joinedCalls.at(-1)).toBe('docker info --format {{json .Runtimes}}')
  })
  it('bootstrap-sysbox refuses to run on a host that cannot, before touching docker', async () => {
    const { run, calls } = make(
      {},
      {
        sysboxHost: {
          platform: 'darwin' as NodeJS.Platform,
          arch: 'arm64',
          kernelRelease: '5.4.0',
          systemdActive: false,
          wsl: false,
          which: () => null,
        },
      }
    )
    await run(['server', 'bootstrap-sysbox', '--yes'])
    expect(outputError).toHaveBeenCalled()
    const [error] = (outputError as ReturnType<typeof mock>).mock.calls.at(-1) as [Error]
    expect(error.message).toMatch(/cannot run the sysbox bootstrap/)
    expect(calls).toEqual([])
  })
  it('bootstrap-sysbox dry-run changes nothing', async () => {
    const capable = {
      platform: 'linux' as NodeJS.Platform,
      arch: 'x64',
      kernelRelease: '6.8.0-40-generic',
      systemdActive: true,
      wsl: false,
      which: (cmd: string) => `/usr/bin/${cmd}`,
    }
    const { run, calls } = make({ 'docker ps': { stdout: 'web\n' } }, { sysboxHost: capable })
    await run(['server', 'bootstrap-sysbox', '--dry-run'])
    expect(calls.map((c) => c.command.join(' '))).toEqual(['docker ps -a --format {{.Names}}'])
  })
  it('honours --root over the state file', async () => {
    const other = realpathSync(mkdtempSync(join(tmpdir(), 'tau-other-')))
    mkdirSync(join(other, '.git'))
    writeFileSync(join(other, 'package.json'), JSON.stringify({ name: 'tau' }))
    const { run, calls } = make()
    await run(['server', 'stop', '--root', other])
    expect(calls).toEqual([])
    expect(outputError).toHaveBeenCalled()
    rmSync(other, { recursive: true, force: true })
  })
  it('reports a missing root through outputError', async () => {
    const { run, deps } = make()
    deps.statePath = join(root, 'missing.json')
    await run(['server', 'stop'])
    expect(outputError).toHaveBeenCalled()
    expect(outputError).toHaveBeenCalledWith(expect.any(Error), 1)
    expect(process.exitCode).toBe(1)
  })
  it('exits 2 (and tells outputError to exit 2) when a headless run has no runtime', async () => {
    const { run } = make()
    await run(['server', 'setup', '--root', root])
    expect(outputError).toHaveBeenCalledWith(expect.any(Error), 2)
    expect(process.exitCode).toBe(2)
  })
  it('use switches which instance a bare server command acts on', async () => {
    const other = realpathSync(mkdtempSync(join(tmpdir(), 'tau-other-')))
    mkdirSync(join(other, '.git'))
    writeFileSync(join(other, 'package.json'), JSON.stringify({ name: 'tau' }))
    // The pm2/container names come from the checkout's own FICUS_INSTANCE, so a
    // labelled instance has to look like one on disk too.
    writeFileSync(join(other, '.env'), 'FICUS_INSTANCE=lab\n')
    const { run, deps, calls } = make({ 'docker inspect': { stdout: 'true\n' } })
    upsertInstance(
      'lab',
      { root: other, port: 4100, supervisor: 'pm2', createdAt: 't', updatedAt: 't' },
      {},
      deps.statePath
    )

    await run(['server', 'use', 'lab'])
    expect(readRegistry(deps.statePath).default).toBe('lab')

    // The point of the default: a command that names no instance now acts on
    // `lab`, in lab's checkout and under lab's pm2 names.
    calls.length = 0
    await run(['server', 'start'])
    expect(calls.at(-1)?.command.join(' ')).toContain('tau-lab-api,tau-lab-worker')
    expect(calls.at(-1)?.options.cwd).toBe(other)

    // …and --instance still wins over it, for that command ONLY: an override
    // is not a selection, so it must leave the registry's default alone.
    // `use` is the only thing that moves it.
    calls.length = 0
    await run(['server', 'start', '--instance', 'tau'])
    expect(calls.at(-1)?.command.join(' ')).toContain('tau-api,tau-worker')
    expect(calls.at(-1)?.options.cwd).toBe(root)
    expect(readRegistry(deps.statePath).default).toBe('lab')

    // The next bare command is back on the default, unaffected by the override.
    calls.length = 0
    await run(['server', 'start'])
    expect(calls.at(-1)?.command.join(' ')).toContain('tau-lab-api,tau-lab-worker')
    rmSync(other, { recursive: true, force: true })
  })

  it('use refuses an unknown label, names the ones that exist, and changes nothing', async () => {
    const { run, deps } = make()
    await run(['server', 'use', 'nope'])
    expect(outputError).toHaveBeenCalled()
    const [error] = (outputError as ReturnType<typeof mock>).mock.calls.at(-1) as [Error]
    expect(error.message).toBe("No local instance named 'nope' — known instances: tau")
    expect(readRegistry(deps.statePath).default).toBe('tau')
  })

  it('install clones a fresh root, installs deps and hands off to bun run setup', async () => {
    const installTmp = realpathSync(mkdtempSync(join(tmpdir(), 'tau-install-')))
    const installRoot = join(installTmp, 'tau')
    const { runner, calls } = cloningRunner(installRoot)
    const { deps } = make()
    deps.runner = runner
    const program = new Command()
    program.exitOverride()
    registerServerCommands(program, deps)
    await program.parseAsync(
      ['server', 'install', '--root', installRoot, '--repo', 'x', '--ref', 'main', '--', '--runtime', 'host'],
      { from: 'user' }
    )
    expect(joined(calls)).toEqual([
      `git clone --recurse-submodules --branch main x ${installRoot}`,
      'bun --version',
      'bun install --frozen-lockfile',
      `bun run setup -- --root ${installRoot} --runtime host`,
    ])
    rmSync(installTmp, { recursive: true, force: true })
  })
  it('install refuses malformed registry state before clone or destination mutation', async () => {
    const installRoot = join(root, 'new-install')
    writeFileSync(statePath, JSON.stringify({ version: 3 }))
    const { run, calls } = make()

    await run(['server', 'install', '--root', installRoot, '--runtime', 'host', '--yes'])

    expect(calls).toEqual([])
    expect(outputError).toHaveBeenCalledWith(expect.objectContaining({ name: 'InvalidRegistryError' }), 1)
    expect(existsSync(installRoot)).toBe(false)
  })

  it('install forwards the multi-instance example from its own --help verbatim', async () => {
    // The help text tells operators to run exactly this to stand up a second
    // instance. If --instance stopped reaching setup, every labelled resource
    // would silently fall back to the default names and collide with the
    // existing install — so the documented line is pinned here.
    const installTmp = realpathSync(mkdtempSync(join(tmpdir(), 'tau-install-')))
    const installRoot = join(installTmp, 'lab')
    const { runner, calls } = cloningRunner(installRoot)
    const { deps } = make()
    deps.runner = runner
    const program = new Command()
    program.exitOverride()
    registerServerCommands(program, deps)
    await program.parseAsync(
      ['server', 'install', '--root', installRoot, '--instance', 'lab', '--runtime', 'host', '--yes'],
      { from: 'user' }
    )
    expect(joined(calls).at(-1)).toBe(`bun run setup -- --root ${installRoot} --instance lab --runtime host --yes`)

    // helpInformation() omits addHelpText, so render the way --help does.
    let help = ''
    const install = program.commands.find((c) => c.name() === 'server')!.commands.find((c) => c.name() === 'install')!
    install.configureOutput({ writeOut: (chunk) => (help += chunk) })
    install.outputHelp()
    expect(help).toContain('--root ~/.tau/instances/lab --instance lab --runtime host --yes')
    rmSync(installTmp, { recursive: true, force: true })
  })
  it('install parses the production form (no `--` separator) and still forwards the trailing flags to setup', async () => {
    const installTmp = realpathSync(mkdtempSync(join(tmpdir(), 'tau-install-')))
    const installRoot = join(installTmp, 'tau')
    const { runner, calls } = cloningRunner(installRoot)
    const { deps } = make()
    deps.runner = runner
    const program = new Command()
    program.exitOverride()
    registerServerCommands(program, deps)
    await program.parseAsync(
      ['server', 'install', '--root', installRoot, '--repo', 'x', '--ref', 'main', '--runtime', 'host', '--yes'],
      { from: 'user' }
    )
    expect(joined(calls)).toEqual([
      `git clone --recurse-submodules --branch main x ${installRoot}`,
      'bun --version',
      'bun install --frozen-lockfile',
      `bun run setup -- --root ${installRoot} --runtime host --yes`,
    ])
    rmSync(installTmp, { recursive: true, force: true })
  })
  it('update pulls (or checks out --ref), runs the offline update and restarts via pm2', async () => {
    const sha = 'a'.repeat(40)
    const { run, calls } = make({
      'git status --porcelain': { stdout: '' },
      'git rev-parse HEAD': { stdout: sha + '\n' },
      'git ls-remote --refs --exit-code origin refs/heads/v1 refs/tags/v1': {
        stdout: `${sha}\trefs/tags/v1\n`,
      },
    })
    await run(['server', 'update', '--ref', 'v1'])
    expect(joined(calls)).toEqual([
      'git status --porcelain',
      'git rev-parse HEAD',
      'git check-ref-format --branch v1',
      'git ls-remote --refs --exit-code origin refs/heads/v1 refs/tags/v1',
      'git fetch --no-tags origin refs/tags/v1:refs/tags/v1',
      // The install already reads FICUS_: resolve what checkout lands on, the way checkout does,
      // to make sure it does not predate the rename (nothing resolves in this fixture).
      'git rev-parse --verify --quiet refs/heads/v1^{commit}',
      'git rev-parse --verify --quiet v1^{commit}',
      'git rev-parse --verify --quiet refs/remotes/origin/v1^{commit}',
      'git checkout --recurse-submodules v1',
      'git rev-parse HEAD',
      'bun run update:offline -- --from ' + sha,
      'bunx pm2 restart tau-worker --update-env',
      'bunx pm2 restart tau-api --update-env',
    ])
    expect(calls.find((call) => call.command.includes('update:offline'))?.options.env?.FICUS_UPDATE_SUPERVISOR).toBe(
      'pm2'
    )
    expect(calls.every((c) => c.options.cwd === root)).toBe(true)
  })
  it('setup re-run keeps the checkout own instance label and port when no flag says otherwise', async () => {
    writeFileSync(join(root, '.env'), 'FICUS_INSTANCE=smoke\nPORT=3100\nFICUS_SANDBOX_RUNTIME=host\n')
    const seen: unknown[] = []
    const { run, deps } = make()
    deps.cwd = root
    deps.runSetup = async (opts) => {
      seen.push(opts)
      return { handoff: [] }
    }
    await run(['server', 'setup', '--runtime', 'host', '--no-start', '--yes'])
    expect(seen[0]).toMatchObject({ instance: 'smoke', port: 3100, apiUrl: 'http://localhost:3100' })
  })
  it('setup targets the checkout you are in, never the state file root', async () => {
    const other = realpathSync(mkdtempSync(join(tmpdir(), 'tau-cwd-')))
    mkdirSync(join(other, '.git'))
    writeFileSync(join(other, 'package.json'), JSON.stringify({ name: 'tau' }))
    const nested = join(other, 'apps', 'core')
    mkdirSync(nested, { recursive: true })
    const seen: unknown[] = []
    const { run, deps } = make()
    // state file still points at `root` (written in beforeEach)
    deps.cwd = nested
    deps.runSetup = async (opts) => {
      seen.push(opts)
      return { handoff: [] }
    }
    await run(['server', 'setup', '--runtime', 'host', '--no-start', '--yes'])
    expect((seen[0] as { root: string }).root).toBe(other)
    rmSync(other, { recursive: true, force: true })
  })
  it('setup wires options and deps through to runSetup', async () => {
    const seen: unknown[] = []
    const { run, deps } = make()
    deps.runSetup = async (opts) => {
      seen.push(opts)
      return { handoff: [] }
    }
    await run(['server', 'setup', '--root', root, '--runtime', 'host', '--port', '3100', '--no-start', '--yes'])
    expect(seen).toHaveLength(1)
    const opts = seen[0] as { root: string; runtime: string; port: number; start: boolean }
    expect(opts.root).toBe(root)
    expect(opts.runtime).toBe('host')
    expect(opts.port).toBe(3100)
    expect(opts.start).toBe(false)
  })
  it('setup honours --instance from argv', async () => {
    // Regression: a group-level --instance on `server` swallowed the flag here,
    // so `bun run setup -- --instance smoke` silently configured the tau instance.
    const seen: unknown[] = []
    const { run, deps } = make()
    deps.runSetup = async (opts) => {
      seen.push(opts)
      return { handoff: [] }
    }
    await run(['server', 'setup', '--root', root, '--instance', 'smoke', '--runtime', 'host', '--no-start', '--yes'])
    expect(seen[0]).toMatchObject({ instance: 'smoke' })
  })
})

describe('tau server list', () => {
  /** A second registered instance, in its own checkout. */
  function secondInstance() {
    const other = realpathSync(mkdtempSync(join(tmpdir(), 'tau-smoke-')))
    mkdirSync(join(other, '.git'))
    writeFileSync(join(other, 'package.json'), JSON.stringify({ name: 'tau' }))
    writeFileSync(join(other, '.env'), 'FICUS_INSTANCE=smoke\nPORT=3100\n')
    upsertInstance(
      'smoke',
      { root: other, port: 3100, supervisor: 'pm2', createdAt: 't', updatedAt: 't' },
      {},
      statePath
    )
    return other
  }

  it('lists every instance by querying its recorded supervisor', async () => {
    const other = secondInstance()
    const { run, calls } = make({
      'bunx pm2 jlist': {
        stdout: JSON.stringify([
          { name: 'tau-api', pid: 5, pm2_env: { status: 'online', pm_cwd: root } },
          { name: 'tau-smoke-worker', pid: 6, pm2_env: { status: 'stopped', pm_cwd: other } },
        ]),
      },
    })
    await run(['server', 'list'])
    // Mixed supervisors cannot share one global query; each record is dispatched independently.
    expect(joined(calls)).toEqual(['bunx pm2 jlist', 'bunx pm2 jlist'])
    expect(calls[0].options.cwd).toBe(root)
    const text = (output as ReturnType<typeof mock>).mock.calls.at(-1)?.[1] as string
    expect(text).toContain(`* tau`)
    expect(text).toContain(root)
    expect(text).toContain('http://localhost:3000')
    expect(text).toContain('api: online')
    expect(text).toContain('smoke')
    expect(text).toContain(other)
    expect(text).toContain('http://localhost:3100')
    expect(text).toContain('worker: stopped')
    expect(text).toContain('api: not registered')
    // Only the default carries the marker.
    expect(
      text
        .split('\n')
        .find((l) => l.includes('smoke'))
        ?.startsWith('*')
    ).toBe(false)
    rmSync(other, { recursive: true, force: true })
  })
  it('--json emits the machine-readable listing', async () => {
    const other = secondInstance()
    const { run } = make({
      'bunx pm2 jlist': {
        stdout: JSON.stringify([{ name: 'tau-api', pid: 5, pm2_env: { status: 'online', pm_cwd: root } }]),
      },
    })
    await run(['server', 'list', '--json'])
    expect(setOutputOptions).toHaveBeenCalledWith({ json: true })
    const [data] = (output as ReturnType<typeof mock>).mock.calls.at(-1) as [
      { default?: string; instances: Record<string, unknown>[] },
    ]
    expect(data.default).toBe('tau')
    expect(data.instances).toEqual([
      {
        label: 'tau',
        root,
        port: 3000,
        url: 'http://localhost:3000',
        default: true,
        supervisor: 'pm2',
        processes: [{ name: 'tau-api', status: 'online', pid: 5, cwd: root }],
      },
      {
        label: 'smoke',
        root: other,
        port: 3100,
        url: 'http://localhost:3100',
        default: false,
        supervisor: 'pm2',
        processes: [],
      },
    ])
    rmSync(other, { recursive: true, force: true })
  })
  it('marks the instance a bare command would act on when the file names no default', async () => {
    const other = secondInstance()
    // A registry that lost its `default` line: resolveRoot falls back to the
    // first label, so the marker has to agree with it.
    writeFileSync(
      statePath,
      JSON.stringify({
        version: 2,
        instances: {
          tau: { root, port: 3000, supervisor: 'pm2', createdAt: 't', updatedAt: 't' },
          smoke: { root: other, port: 3100, supervisor: 'pm2', createdAt: 't', updatedAt: 't' },
        },
      })
    )
    const { run } = make()
    await run(['server', 'list'])
    const [data, text] = (output as ReturnType<typeof mock>).mock.calls.at(-1) as [{ default?: string }, string]
    expect(data.default).toBe('smoke')
    expect(
      text
        .split('\n')
        .find((l) => l.includes('smoke'))
        ?.startsWith('*')
    ).toBe(true)
    expect(
      text
        .split('\n')
        .find((l) => l.includes(' tau '))
        ?.startsWith('*')
    ).toBe(false)
    rmSync(other, { recursive: true, force: true })
  })
  it('says (none) and asks pm2 nothing when no instance is registered', async () => {
    rmSync(statePath, { force: true })
    const { run, calls } = make()
    await run(['server', 'list'])
    const [data, text] = (output as ReturnType<typeof mock>).mock.calls.at(-1) as [{ instances: unknown[] }, string]
    expect(text).toContain('(none)')
    expect(data.instances).toEqual([])
    expect(calls).toEqual([])
  })
})

describe('tau server <cmd> --instance', () => {
  /** A second registered instance in its own checkout, labelled smoke. */
  function smokeCheckout(): string {
    const other = realpathSync(mkdtempSync(join(tmpdir(), 'tau-smoke-')))
    mkdirSync(join(other, '.git'))
    writeFileSync(join(other, 'package.json'), JSON.stringify({ name: 'tau' }))
    writeFileSync(join(other, '.env'), 'FICUS_INSTANCE=smoke\nPORT=3100\n')
    upsertInstance(
      'smoke',
      { root: other, port: 3100, supervisor: 'pm2', createdAt: 't', updatedAt: 't' },
      {},
      statePath
    )
    return other
  }
  it('acts on the named instance instead of the registry default', async () => {
    const other = smokeCheckout()
    const { run, calls } = make()
    await run(['server', 'stop', '--instance', 'smoke'])
    expect(joined(calls)).toEqual(['bunx pm2 stop tau-smoke-api tau-smoke-worker'])
    expect(calls[0].options.cwd).toBe(other)
    rmSync(other, { recursive: true, force: true })
  })
  it('status --instance reports the named instance, not the default', async () => {
    const other = smokeCheckout()
    const { run } = make()
    await run(['server', 'status', '--instance', 'smoke'])
    const [data] = (output as ReturnType<typeof mock>).mock.calls.at(-1) as [{ root: string; instance: string }]
    expect(data).toMatchObject({ root: other, instance: 'smoke', port: 3100 })
    rmSync(other, { recursive: true, force: true })
  })
  it('rejects the old group-level form (the option is per-subcommand now)', async () => {
    const other = smokeCheckout()
    const { run, calls } = make()
    await expect(run(['server', '--instance', 'smoke', 'status'])).rejects.toThrow(/unknown option .--instance./)
    expect(calls).toEqual([])
    rmSync(other, { recursive: true, force: true })
  })
  it('reports an unknown instance with the labels it does know', async () => {
    const { run, calls } = make()
    await run(['server', 'stop', '--instance', 'nope'])
    const [error] = (outputError as ReturnType<typeof mock>).mock.calls.at(-1) as [Error]
    expect(error.message).toContain('unknown instance "nope"')
    expect(error.message).toContain('known instances: tau')
    expect(calls).toEqual([])
  })
  it('uninstall drops the entry and hands the default to a remaining instance', async () => {
    const other = realpathSync(mkdtempSync(join(tmpdir(), 'tau-smoke-')))
    mkdirSync(join(other, '.git'))
    writeFileSync(join(other, 'package.json'), JSON.stringify({ name: 'tau' }))
    upsertInstance(
      'smoke',
      { root: other, port: 3100, supervisor: 'pm2', createdAt: 't', updatedAt: 't' },
      {},
      statePath
    )
    const { run } = make()
    await run(['server', 'uninstall', '--yes'])
    const registry = readRegistry(statePath)
    expect(Object.keys(registry.instances)).toEqual(['smoke'])
    expect(registry.default).toBe('smoke')
    rmSync(other, { recursive: true, force: true })
  })
})

describe('registry-backed supervisor dispatch', () => {
  it('dispatches a systemd-user stop without touching pm2', async () => {
    upsertInstance(
      'tau',
      { root, port: 3000, supervisor: 'systemd-user', createdAt: 't', updatedAt: 'u' },
      {},
      statePath
    )
    const { run, calls } = make()
    await run(['server', 'stop'])
    expect(joined(calls)).toEqual([
      'systemctl --user show-environment',
      'systemctl --user stop tau-api.service',
      'systemctl --user stop tau-worker.service',
    ])
  })

  it('does not dispatch lifecycle work for a broken registered root', async () => {
    const broken = join(root, '..', `tau-broken-${Date.now()}`)
    symlinkSync(join(root, '..', 'missing-checkout'), broken)
    upsertInstance(
      'tau',
      { root: broken, port: 3000, supervisor: 'pm2', createdAt: 't', updatedAt: 'u' },
      {},
      statePath
    )
    try {
      const { run, calls } = make()
      await run(['server', 'stop', '--instance', 'tau'])
      expect(calls).toEqual([])
      expect(outputError).toHaveBeenCalled()
    } finally {
      rmSync(broken, { force: true })
    }
  })

  it('uses the canonical registry root when lifecycle is selected through a symlink alias', async () => {
    const alias = join(root, '..', `tau-server-alias-${Date.now()}`)
    symlinkSync(root, alias)
    try {
      const { run, calls } = make()
      await run(['server', 'stop', '--root', alias])
      const pm2 = calls.find((call) => call.command[0] === 'bunx' && call.command[1] === 'pm2')
      expect(pm2?.options.cwd).toBe(realpathSync(root))
    } finally {
      rmSync(alias, { force: true })
    }
  })

  it('dispatches launchd restart worker first and API last', async () => {
    upsertInstance('tau', { root, port: 3000, supervisor: 'launchd', createdAt: 't', updatedAt: 'u' }, {}, statePath)
    const uid = process.getuid?.() ?? 0
    const home = process.env.HOME ?? homedir()
    const printOf = (component: 'api' | 'worker') =>
      `program arguments = {\n\t/usr/bin/bun\n}\n\tworking directory = ${realpathSync(root)}\n\tstderr path = ${join(home, '.tau', 'logs', `tau-${component}.log`)}\n`
    const { run, calls } = make({
      [`launchctl print gui/${uid}/ai.hiretau.tau-worker`]: { stdout: printOf('worker') },
      [`launchctl print gui/${uid}/ai.hiretau.tau-api`]: { stdout: printOf('api') },
    })
    await run(['server', 'restart'])
    const commands = joined(calls)
    const worker = commands.findIndex((line) => line.includes('kickstart -k') && line.endsWith('tau-worker'))
    const api = commands.findIndex((line) => line.includes('kickstart -k') && line.endsWith('tau-api'))
    expect(worker).toBeGreaterThan(-1)
    expect(api).toBeGreaterThan(worker)
    expect(commands.some((line) => line.includes('pm2'))).toBe(false)
  })
})
