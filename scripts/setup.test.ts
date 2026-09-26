import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

const script = join(import.meta.dir, 'setup.sh')
// Resolved once against the *test runner's* PATH (unaffected by the
// deliberately restricted PATH we give the script under test below).
const SH = Bun.which('sh')
if (!SH) throw new Error('test environment has no `sh` on PATH')

let tmp: string
let log: string
beforeEach(() => {
  tmp = mkdtempSync(join(tmpdir(), 'tau-setup-sh-'))
  log = join(tmp, 'log')
  mkdirSync(join(tmp, 'bin'))
  // PATH for `run()` below is ONLY tmp/bin — no /usr/bin, no /bin — so a
  // "without git" test can't be fooled by a system git (present at /usr/bin/git
  // on macOS, and reachable via /bin on Linux distros where /bin is itself a
  // symlink into /usr/bin — excluding /usr/bin alone doesn't hide it there).
  // setup.sh invokes bare `sh` twice (`sh -c "curl | sh"`), and the fake
  // installer below needs `cat`/`mkdir`/`chmod` to build the fake tau binary,
  // so the stub dir must provide those too — symlink the real ones in.
  for (const cmd of ['sh', 'cat', 'mkdir', 'chmod']) {
    const real = Bun.which(cmd)
    if (!real) throw new Error(`test environment is missing ${cmd}`)
    symlinkSync(real, join(tmp, 'bin', cmd))
  }
  // The installer body goes through two nested shells (the outer `sh -c "curl
  // | sh"` and the piped-into `sh`), each of which is a fresh, argument-less
  // shell — so a `$*` embedded via nested echo/printf quoting gets prematurely
  // expanded to empty before it ever reaches the fake tau script. Write the
  // installer body to a file instead and have the curl stub `cat` it; the
  // heredoc that creates the fake tau uses a quoted delimiter so `$*` survives
  // into the fake tau's own source, to be expanded only when tau itself runs.
  const installer = join(tmp, 'installer.sh')
  writeFileSync(
    installer,
    `#!/bin/sh\nmkdir -p "$HOME/.tau/bin"\ncat > "$HOME/.tau/bin/tau" <<'TAUEOF'\n#!/bin/sh\necho "tau $*" >> ${log}\nTAUEOF\nchmod +x "$HOME/.tau/bin/tau"\n`
  )
  // stub curl: record argv, then hand the installer body to the `| sh` pipe
  // FICUS_INSTALL_AUTH is logged too: setup.sh must install the CLI without the
  // installer's auth prompt (it runs unattended under `curl | bash`).
  writeFileSync(
    join(tmp, 'bin', 'curl'),
    `#!/bin/sh\necho "curl $* FICUS_INSTALL_AUTH=$FICUS_INSTALL_AUTH" >> "${log}"\ncat "${installer}"\n`
  )
  writeFileSync(join(tmp, 'bin', 'git'), `#!/bin/sh\nexit 0\n`)
  chmodSync(join(tmp, 'bin', 'curl'), 0o755)
  chmodSync(join(tmp, 'bin', 'git'), 0o755)
})
afterEach(() => rmSync(tmp, { recursive: true, force: true }))

function run(args: string[], env: Record<string, string> = {}) {
  return Bun.spawnSync([SH as string, script, ...args], {
    env: { PATH: join(tmp, 'bin'), HOME: tmp, ...env },
    stdout: 'pipe',
    stderr: 'pipe',
    stdin: 'ignore',
  })
}

describe('scripts/setup.sh', () => {
  it('installs the CLI without auth prompts, then runs tau server install with pass-through args', () => {
    const r = run(['--runtime', 'host', '--yes'])
    expect(r.exitCode).toBe(0)
    const lines = readFileSync(log, 'utf8').trim().split('\n')
    expect(lines[0]).toBe('curl -fsSL https://ficus.sh/cli/install.sh FICUS_INSTALL_AUTH=0')
    expect(lines[1]).toBe('tau server install --runtime host --yes')
  })
  it('honours FICUS_INSTALL_URL', () => {
    const r = run([], { FICUS_INSTALL_URL: 'https://example/i.sh' })
    expect(r.exitCode).toBe(0)
    expect(readFileSync(log, 'utf8')).toContain('curl -fsSL https://example/i.sh')
  })
  it('skips the CLI install when the binary exists and FICUS_SETUP_SKIP_CLI_INSTALL=1', () => {
    mkdirSync(join(tmp, '.tau', 'bin'), { recursive: true })
    writeFileSync(join(tmp, '.tau', 'bin', 'tau'), `#!/bin/sh\necho "tau $*" >> "${log}"\n`)
    chmodSync(join(tmp, '.tau', 'bin', 'tau'), 0o755)
    const r = run(['--dry-run'], { FICUS_SETUP_SKIP_CLI_INSTALL: '1' })
    expect(r.exitCode).toBe(0)
    expect(readFileSync(log, 'utf8').trim()).toBe('tau server install --dry-run')
  })
  it('fails clearly without git', () => {
    rmSync(join(tmp, 'bin', 'git'))
    const r = run([])
    expect(r.exitCode).not.toBe(0)
    expect(new TextDecoder().decode(r.stderr)).toMatch(/git/)
  })
})
