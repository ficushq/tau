import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { createHash, randomUUID } from 'crypto'
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'fs'
import { join } from 'path'
import { tmpdir } from 'os'
import type { Machine } from './queries'
import {
  bootstrapMachine,
  computeBootstrapVersion,
  currentBootstrapVersion,
  parseCapabilities,
  waitForSshReady,
} from './bootstrap'
import { buildBoxProvisionArtifact } from './box-provision-artifact'
import { tarCodecFlag } from './box-manager'
import { devboxInstallCommand } from './devbox-seed'
import type { SshResult, SshRunner } from './ssh'

const repoRoot = join(import.meta.dir, '../../../../../')
const bootstrapSh = readFileSync(join(repoRoot, 'scripts/machine/bootstrap.sh'), 'utf8')
const boxProvisionSh = readFileSync(join(repoRoot, 'scripts/machine/box-provision.sh'), 'utf8')
// The drift hash covers BOTH scripts (fixed order: bootstrap.sh then
// box-provision.sh), so a change to either re-triggers a push.
const expectedVersion = createHash('sha256').update(bootstrapSh).update(boxProvisionSh).digest('hex')

function makeMachine(overrides: Partial<Machine> = {}): Machine {
  return {
    id: '22222222-2222-2222-2222-222222222222',
    name: 'boot-test',
    provider: 'ssh',
    providerRef: null,
    sshHost: '10.0.0.9',
    sshPort: 22,
    sshUser: 'tau',
    sshKeyId: 'secret-key',
    sshPublicKey: 'ssh-ed25519 AAAA test',
    status: 'registered',
    capabilities: {},
    scope: 'shared',
    egressPolicy: false,
    bootstrapVersion: null,
    lastError: null,
    lastSeenAt: null,
    createdAt: new Date(),
    ...overrides,
  } as Machine
}

interface RecordedCall {
  command: string
  stdin?: string
}

/**
 * Fake runner that records every command (pushes are `install ...` commands,
 * runs are `bash ...`) and delegates the reply to a handler. Push commands
 * default to exit 0 with empty output.
 */
function makeFakeRunner(handler: (command: string, stdin: string | undefined) => SshResult | Error): {
  runner: SshRunner
  calls: RecordedCall[]
} {
  const calls: RecordedCall[] = []
  const runner: SshRunner = {
    async run(_machine, command, opts): Promise<SshResult> {
      const stdin = opts?.stdin === undefined ? undefined : String(opts.stdin)
      calls.push({ command, stdin })
      const reply = handler(command, stdin)
      if (reply instanceof Error) throw reply
      return reply
    },
  }
  return { runner, calls }
}

const CAPS_LINE =
  'FICUS_CAPS_JSON: {"arch":"aarch64","cpus":8,"memMb":16000,"diskGb":100,"kernel":"6.8.0-generic","docker":"none"}'

describe('parseCapabilities', () => {
  it('parses the final FICUS_CAPS_JSON line into typed capabilities', () => {
    const caps = parseCapabilities(`some noise\n${CAPS_LINE}\n`)
    expect(caps).toEqual({
      arch: 'aarch64',
      cpus: 8,
      memMb: 16000,
      diskGb: 100,
      kernel: '6.8.0-generic',
      docker: 'none',
    })
  })

  it('also parses the legacy TAU_CAPS_JSON marker that bootstrap.sh still prints (one release)', () => {
    const caps = parseCapabilities(`some noise\n${CAPS_LINE.replace(/^FICUS_/, 'TAU_')}\n`)
    expect(caps.arch).toBe('aarch64')
    expect(caps.cpus).toBe(8)
  })

  it('ignores garbage before the line and apt/install chatter', () => {
    const stdout = [
      'Reading package lists...',
      'Setting up jq (1.7) ...',
      'FICUS_CAPS_JSON: not-json-here',
      'more chatter',
      CAPS_LINE,
    ].join('\n')
    const caps = parseCapabilities(stdout)
    expect(caps.arch).toBe('aarch64')
    expect(caps.docker).toBe('none')
  })

  it('picks the LAST valid caps line when several are present', () => {
    const stdout = [
      'FICUS_CAPS_JSON: {"arch":"x86_64","cpus":2,"memMb":2000,"diskGb":20,"kernel":"5.x","docker":"none"}',
      CAPS_LINE,
    ].join('\n')
    expect(parseCapabilities(stdout).arch).toBe('aarch64')
  })

  it('throws when no caps line is present', () => {
    expect(() => parseCapabilities('nothing to see here')).toThrow(/FICUS_CAPS_JSON/)
  })

  it("parses docker:'rootless' (the capability bootstrap reports once the engine is installed)", () => {
    const line =
      'FICUS_CAPS_JSON: {"arch":"aarch64","cpus":8,"memMb":16000,"diskGb":100,"kernel":"6.8","docker":"rootless","forwarding":"yes"}'
    expect(parseCapabilities(line).docker).toBe('rootless')
  })

  // The softened browser gate reports availability to the control plane through
  // capabilities.browser (+ a reason token when unavailable). This is the CP
  // channel a misconfigured host surfaces on.
  it("parses browser:'available' (happy path)", () => {
    const line =
      'FICUS_CAPS_JSON: {"arch":"x86_64","cpus":2,"memMb":2000,"diskGb":20,"kernel":"6.8","docker":"rootless","forwarding":"yes","browser":"available"}'
    const caps = parseCapabilities(line)
    expect(caps.browser).toBe('available')
    expect(caps.browserReason).toBeUndefined()
  })

  it("parses browser:'unavailable' with its reason token (softened gate)", () => {
    const line =
      'FICUS_CAPS_JSON: {"arch":"x86_64","cpus":2,"memMb":2000,"diskGb":20,"kernel":"6.8","docker":"rootless","forwarding":"yes","browser":"unavailable","browserReason":"sandbox_check_failed"}'
    const caps = parseCapabilities(line)
    expect(caps.browser).toBe('unavailable')
    expect(caps.browserReason).toBe('sandbox_check_failed')
  })

  it('leaves browser undefined on a caps line from a pre-browser machine', () => {
    expect(parseCapabilities(CAPS_LINE).browser).toBeUndefined()
  })
})

// The box-manager <-> box-provision.sh contract (and the bootstrap docker
// capability) is a cross-file seam the fake-runner unit tests cannot exercise;
// lock its shape here so a script edit that breaks it fails loudly.
describe('machine script docker contract', () => {
  it('bootstrap.sh installs the rootless engine, masks the shared rootful daemon, and reports the docker capability', () => {
    expect(bootstrapSh).toContain('docker-ce-rootless-extras')
    expect(bootstrapSh).toContain('fuse-overlayfs')
    // The shared rootful daemon is the hole being closed — it must be masked.
    expect(bootstrapSh).toContain('systemctl mask docker.service docker.socket')
    // Capability is probed, not hard-coded to "none".
    expect(bootstrapSh).toContain('detect_docker')
    expect(bootstrapSh).not.toContain('"docker":"none"')
  })

  it('box-provision.sh locks the box HOME to 0700 (idempotent, applies to existing boxes on re-provision)', () => {
    // Ubuntu useradd leaves the home 0755, which would let co-located box
    // users read a sibling's ~/memory, ~/.tau/skills, ~/bin. ensure_dirs runs
    // on EVERY provision (check-then-act elsewhere, plain chmod here), so a
    // re-provision tightens pre-hardening boxes too.
    expect(boxProvisionSh).toContain('chmod 700 "${home}"')
  })

  it('box-provision.sh gates rootless docker behind --with-docker and reports the box uid', () => {
    expect(boxProvisionSh).toContain('--with-docker')
    expect(boxProvisionSh).toContain('dockerd-rootless-setuptool.sh install')
    // The uid marker box-manager parses to bake DOCKER_HOST.
    expect(boxProvisionSh).toContain("printf 'FICUS_BOX_UID=%s\\n'")
    // Docker provisioning must be conditional (agent light boxes skip it).
    expect(boxProvisionSh).toContain('if [ "${WITH_DOCKER}" = true ]; then')
  })

  it('box-provision.sh survives kernels whose nf_tables is built-in-but-unlisted (exe.dev) without losing container egress', () => {
    // The setuptool's iptables pre-flight greps /proc/modules + modules.builtin
    // for nf_tables; on exe's kernel both miss even though iptables works via
    // the nft backend, and install aborts with no unit written. --skip-iptables
    // gets past that false negative (observed live on exe, 2026-07-14).
    expect(boxProvisionSh).toContain('dockerd-rootless-setuptool.sh install --skip-iptables')
    // ...but when the check trips, the setuptool bakes --iptables=false into
    // ExecStart, which kills the container bridge's NAT (containers get a route
    // but no egress). The script must strip it back out via a systemd drop-in
    // (survives the setuptool rewriting docker.service on re-provision)...
    expect(boxProvisionSh).toContain('--iptables=false')
    expect(boxProvisionSh).toContain('docker.service.d')
    // ...and RESTART (the setuptool auto-starts the daemon with the bad flag
    // during install; a plain `start` would no-op against it).
    expect(boxProvisionSh).toContain('sysu restart docker.service')
    // run_as_box must work under BOTH privilege modes: as root, empty-SUDO
    // expansion would exec `-u` as a command (live bug) — runuser covers root,
    // sudo covers the passwordless-sudoer admin.
    expect(boxProvisionSh).toContain('runuser -u')
  })

  it('box-provision.sh --restore extracts the archive and re-owns/locks EVERY member (workspace 0755, private 0700)', () => {
    // The restorePrivateArchive <-> box-provision.sh seam (reverse of the state
    // archive pull): the pushed tar's top members are the box's state dirs
    // (`.private` for agent/system-manager boxes, `workspace` alongside
    // `.private` for a SQUAD box), so it extracts with -C into the HOME, then
    // ownership/mode are re-stamped per member — root extracted it, so without
    // the chown the box user could not read (or, for ~/workspace, write) its own
    // restored tree. Modes mirror ensure_dirs: ~/workspace 0755, private 0700.
    expect(boxProvisionSh).toContain('--restore')
    expect(boxProvisionSh).toContain('tar xzf "${RESTORE_TAR}" -C "${home}"')
    // Members are read from the tar itself (not hardcoded to .private) and
    // re-owned in a loop, so a squad ~/workspace is never left root-owned.
    expect(boxProvisionSh).toContain('tar tzf "${RESTORE_TAR}"')
    expect(boxProvisionSh).toContain('chown -R "${UNIX_USER}:${UNIX_USER}" "${home}/${m}"')
    expect(boxProvisionSh).toContain('chmod 755 "${home}/${m}"')
    expect(boxProvisionSh).toContain('chmod 700 "${home}/${m}"')
    // ~/.private is always ensured to exist (an EMPTY archive carries no member).
    expect(boxProvisionSh).toContain('install -d "${home}/.private"')
  })

  it('documents that restore-only modes omit --port', () => {
    expect(boxProvisionSh).toContain('Restore/remove (port unused and optional):')
    expect(boxProvisionSh).toContain('--port is required for provisioning only')

    const restoreStreamUsage = boxProvisionSh.match(
      /box-provision\.sh --unix-user <user> --restore-stream \\\n#\s+--codec <gzip\|zstd> --state-dirs "<dirs>"/
    )
    expect(restoreStreamUsage).not.toBeNull()
    expect(restoreStreamUsage?.[0]).not.toContain('--port')
  })

  it('box-provision.sh --restore-stream extracts from STDIN into operation staging and shares the re-own logic', () => {
    // The migration transport pipes the source machine's `tar c` straight into
    // this mode's stdin (`-f -`), so no archive FILE is ever staged on the
    // destination's disk. The extracted TREE lands in per-operation staging
    // (~/.tau-migrate/<id>) and box-migrate promotes it into HOME (an mv/rename
    // within the same home filesystem — space-neutral) only after verifying the
    // manifest, so a partial or tampered stream never overwrites the live roots.
    expect(boxProvisionSh).toContain('--restore-stream')
    expect(boxProvisionSh).toContain('--restore-stream requires a UUID --staging-id')
    expect(boxProvisionSh).toContain(
      'tar -x "$(tar_codec_flag)" --no-same-owner --no-overwrite-dir -f - -C "${staging}"'
    )
    // Ownership/modes are NOT re-implemented for the streaming path: both
    // restore modes call the SAME re-own helper, so a streamed restore can
    // never drift from the file restore's `workspace 0755 / private 0700`
    // guarantee (a root-owned ~/workspace is a dead squad box).
    expect(boxProvisionSh).toContain('reown_members()')
    expect(boxProvisionSh).toContain('reown_members "${staging}" ${STATE_DIRS}')
    expect(boxProvisionSh).toContain('reown_members "${home}" "${members}"')
    // The READ codec comes from the caller (--codec), which is the SAME value
    // the source wrote with — a stream can only be read once, so it cannot be
    // sniffed from the archive the way the file path re-reads its members.
    expect(boxProvisionSh).toContain('--codec')
    expect(boxProvisionSh).toContain('--state-dirs')
  })

  it('bootstrap.sh probes forwarding definitively: sshd -T, then empirical loopback, then config-file default', () => {
    // Ladder step 1: effective config via sshd -T (privileged).
    expect(bootstrapSh).toContain('sshd -T')
    // Ladder step 2: when sshd -T is unavailable (e.g. exe's exeuntu sshd),
    // an empirical loopback self-test replaces the old blanket "unknown".
    expect(bootstrapSh).toContain('forwarding_selftest')
    expect(bootstrapSh).toContain('ExitOnForwardFailure')
    // Ladder step 3: explicit "AllowTcpForwarding no" in the config files → no;
    // otherwise OpenSSH's compiled-in default (yes) applies.
    expect(bootstrapSh).toContain('/etc/ssh/sshd_config.d')
    expect(bootstrapSh).toContain('allowtcpforwarding[[:space:]]+no')
  })

  it("bootstrap.sh uses a prebaked image's baked tooling (skips installs) whether or not versions match, and never claims a self-heal", () => {
    // The marker the ficus-machine image bakes (packages/machine-image/Dockerfile).
    expect(bootstrapSh).toContain('/opt/tau/prebaked')
    // The install block is gated on marker PRESENCE (the source of truth for
    // baked tooling); a drift only warns via the decision logger — it never
    // re-runs the installs over a prebaked image (a nix reinstall would brick).
    expect(bootstrapSh).toContain('log_prebaked_decision')
    expect(bootstrapSh).toContain('bunVersion')
    // Honest wording: a drift warns + recommends a rebake, it does NOT self-heal.
    expect(bootstrapSh).not.toContain('self-heal')
    expect(bootstrapSh).toContain('using baked tooling')
    // The genuinely per-boot work still runs regardless of the prebaked branch:
    // the manifest with the caller's --version hash, and the caps probe for THIS VM.
    expect(bootstrapSh).toContain('write_manifest')
    expect(bootstrapSh).toContain('print_capabilities')
  })

  it('bootstrap.sh pre-creates every artifact destination dir (/opt/tau/cli next to /opt/tau/server)', () => {
    // Pushed machine-artifacts land under root-owned /opt/tau trees; make_dirs
    // pre-creates them (ensureArtifact's `install -D` also creates parents —
    // belt and braces, and the dir exists even before the first push).
    expect(bootstrapSh).toContain('/opt/tau/cli')
    expect(bootstrapSh).toContain('"${FICUS_ROOT}/cli"')
    expect(bootstrapSh).toContain('"${FICUS_ROOT}/server"')
  })

  it('bootstrap.sh installs the pinned nix + devbox toolchain box users need for devbox install', () => {
    // Pinned versions live in top-of-file variables (bump = new bootstrap hash).
    expect(bootstrapSh).toContain('NIX_VERSION=')
    expect(bootstrapSh).toContain('DEVBOX_VERSION=')
    // nix is installed MULTI-USER (daemon) so many unprivileged box users can
    // realize store paths; a single-user store could not serve them all.
    expect(bootstrapSh).toContain('install_nix')
    expect(bootstrapSh).toContain('--daemon')
    expect(bootstrapSh).toContain('install_devbox')
    // Both land on the standard PATH the non-login box shell uses.
    expect(bootstrapSh).toContain('/usr/local/bin/nix')
    expect(bootstrapSh).toContain('/usr/local/bin/devbox')
  })
})

describe('bootstrapMachine', () => {
  it('pushes the script, runs it, pushes box-provision, and stamps ready', async () => {
    const { runner, calls } = makeFakeRunner((command) => {
      if (command.startsWith('install ')) return { exitCode: 0, stdout: '', stderr: '' }
      // The bootstrap run.
      return { exitCode: 0, stdout: `apt noise\n${CAPS_LINE}\n`, stderr: '' }
    })

    const updates: Array<{ id: string; updates: Partial<Machine> }> = []
    const machine = makeMachine()
    const caps = await bootstrapMachine(machine, {
      waitForSshReady: async () => {},
      runner,
      updateMachine: async (id, u) => {
        updates.push({ id, updates: u as Partial<Machine> })
        return { ...machine, ...(u as Partial<Machine>) }
      },
    })

    // Order: push bootstrap.sh, run bootstrap.sh, push box-provision.sh.
    expect(calls.length).toBe(3)
    expect(calls[0].command).toContain('install ')
    expect(calls[0].command).toContain('/tmp/tau-bootstrap.sh')
    expect(calls[0].stdin).toBe(bootstrapSh)

    expect(calls[1].command).toContain('bash ')
    expect(calls[1].command).toContain('/tmp/tau-bootstrap.sh')
    expect(calls[1].command).toContain('--version')
    expect(calls[1].command).toContain(expectedVersion)

    // box-provision.sh lands in root-owned /opt/tau/bin, so its push is
    // privileged (sudo install), unlike the world-writable /tmp bootstrap push.
    expect(calls[2].command).toContain('sudo install ')
    expect(calls[2].command).toContain('/opt/tau/bin/box-provision.sh')

    // Return value + stamped row.
    expect(caps.arch).toBe('aarch64')
    expect(updates.length).toBe(1)
    expect(updates[0].id).toBe(machine.id)
    expect(updates[0].updates.status).toBe('ready')
    expect(updates[0].updates.bootstrapVersion).toBe(expectedVersion)
    expect(updates[0].updates.capabilities).toEqual(caps)
    // A successful bootstrap clears any stale error from a prior failed run.
    expect(updates[0].updates.lastError).toBeNull()
  })

  it('clears a stale lastError on a successful bootstrap of a previously-failed machine', async () => {
    const { runner } = makeFakeRunner((command) => {
      if (command.startsWith('install ') || command.startsWith('sudo install ')) {
        return { exitCode: 0, stdout: '', stderr: '' }
      }
      return { exitCode: 0, stdout: `${CAPS_LINE}\n`, stderr: '' }
    })
    const updates: Array<Partial<Machine>> = []
    const machine = makeMachine({ status: 'unreachable', lastError: 'bootstrap.sh failed on x (exit 1): old boom' })

    await bootstrapMachine(machine, {
      waitForSshReady: async () => {},
      runner,
      updateMachine: async (_id, u) => {
        updates.push(u as Partial<Machine>)
        return machine
      },
    })

    expect(updates.length).toBe(1)
    expect(updates[0].status).toBe('ready')
    expect(updates[0].lastError).toBeNull()
  })

  it('passes --egress-lockdown + a --core-cidr per configured CIDR when machine.egressPolicy is true', async () => {
    const { runner, calls } = makeFakeRunner((command) => {
      if (command.startsWith('install ') || command.startsWith('sudo install ')) {
        return { exitCode: 0, stdout: '', stderr: '' }
      }
      return { exitCode: 0, stdout: `${CAPS_LINE}\n`, stderr: '' }
    })
    const machine = makeMachine({ egressPolicy: true })
    await bootstrapMachine(machine, {
      waitForSshReady: async () => {},
      runner,
      updateMachine: async () => machine,
      coreEgressCidrs: ['10.8.0.0/24', '203.0.113.7/32'],
    })

    const run = calls.find((c) => c.command.includes('bash ') && c.command.includes('--version'))!
    expect(run.command).toContain('--egress-lockdown')
    expect(run.command).toContain('--core-cidr')
    expect(run.command).toContain('10.8.0.0/24')
    expect(run.command).toContain('203.0.113.7/32')
  })

  it('omits the egress flags entirely when machine.egressPolicy is false', async () => {
    const { runner, calls } = makeFakeRunner((command) => {
      if (command.startsWith('install ') || command.startsWith('sudo install ')) {
        return { exitCode: 0, stdout: '', stderr: '' }
      }
      return { exitCode: 0, stdout: `${CAPS_LINE}\n`, stderr: '' }
    })
    const machine = makeMachine({ egressPolicy: false })
    await bootstrapMachine(machine, {
      waitForSshReady: async () => {},
      runner,
      updateMachine: async () => machine,
      coreEgressCidrs: ['10.8.0.0/24'],
    })

    const run = calls.find((c) => c.command.includes('bash ') && c.command.includes('--version'))!
    expect(run.command).not.toContain('--egress-lockdown')
    expect(run.command).not.toContain('--core-cidr')
  })

  it('derives the core CIDRs from FICUS_CORE_EGRESS_CIDR (comma/space separated) when not injected', async () => {
    const prior = process.env.FICUS_CORE_EGRESS_CIDR
    process.env.FICUS_CORE_EGRESS_CIDR = '10.20.0.0/16, 198.51.100.9/32'
    try {
      const { runner, calls } = makeFakeRunner((command) => {
        if (command.startsWith('install ') || command.startsWith('sudo install ')) {
          return { exitCode: 0, stdout: '', stderr: '' }
        }
        return { exitCode: 0, stdout: `${CAPS_LINE}\n`, stderr: '' }
      })
      const machine = makeMachine({ egressPolicy: true })
      await bootstrapMachine(machine, {
        waitForSshReady: async () => {},
        runner,
        updateMachine: async () => machine,
      })

      const run = calls.find((c) => c.command.includes('bash ') && c.command.includes('--version'))!
      expect(run.command).toContain('10.20.0.0/16')
      expect(run.command).toContain('198.51.100.9/32')
    } finally {
      if (prior === undefined) delete process.env.FICUS_CORE_EGRESS_CIDR
      else process.env.FICUS_CORE_EGRESS_CIDR = prior
    }
  })

  it('marks the machine unreachable and rethrows when the run exits non-zero', async () => {
    const { runner } = makeFakeRunner((command) => {
      if (command.startsWith('install ')) return { exitCode: 0, stdout: '', stderr: '' }
      return { exitCode: 1, stdout: '', stderr: 'apt-get: boom' }
    })
    const updates: Array<Partial<Machine>> = []
    const machine = makeMachine()

    await expect(
      bootstrapMachine(machine, {
        waitForSshReady: async () => {},
        runner,
        updateMachine: async (_id, u) => {
          updates.push(u as Partial<Machine>)
          return machine
        },
      })
    ).rejects.toThrow(/boom/)

    expect(updates.length).toBe(1)
    expect(updates[0].status).toBe('unreachable')
    // The persisted lastError is the SAME stderr-tail string that was thrown —
    // an operator (or platform provisioning, which only polls the row) reads it
    // off the row instead of a log they may not have access to.
    expect(updates[0].lastError).toContain('boom')
    expect(updates[0].lastError).toContain('bootstrap.sh failed on')
  })

  it('caps the persisted lastError to ~4KB (keeping the tail) without truncating the rethrown error', async () => {
    // An unbounded apt/nix stderr blob shouldn't bloat a row that's now
    // returned on every machines list fetch. The tail (not the head) is kept:
    // it's the most diagnostic part of a build log.
    const hugeStderr = 'x'.repeat(10_000) + 'DISTINCTIVE_TAIL_MARKER'
    const { runner } = makeFakeRunner((command) => {
      if (command.startsWith('install ')) return { exitCode: 0, stdout: '', stderr: '' }
      return { exitCode: 1, stdout: '', stderr: hugeStderr }
    })
    const updates: Array<Partial<Machine>> = []
    const machine = makeMachine()

    let thrown: Error | undefined
    await bootstrapMachine(machine, {
      waitForSshReady: async () => {},
      runner,
      updateMachine: async (_id, u) => {
        updates.push(u as Partial<Machine>)
        return machine
      },
    }).catch((err: Error) => {
      thrown = err
    })

    expect(updates.length).toBe(1)
    const persisted = updates[0].lastError as string
    // Comfortably under the 10KB+ input, and keeps the diagnostic tail.
    expect(persisted.length).toBeLessThan(5000)
    expect(persisted).toContain('DISTINCTIVE_TAIL_MARKER')
    // The rethrown error (logs, non-persisted) is the FULL, uncapped message.
    expect(thrown?.message.length).toBeGreaterThan(10_000)
  })

  it('marks the machine unreachable and rethrows when a push fails', async () => {
    const { runner } = makeFakeRunner(() => new Error('ssh connection refused'))
    const updates: Array<Partial<Machine>> = []
    const machine = makeMachine()

    await expect(
      bootstrapMachine(machine, {
        waitForSshReady: async () => {},
        runner,
        updateMachine: async (_id, u) => {
          updates.push(u as Partial<Machine>)
          return machine
        },
      })
    ).rejects.toThrow(/connection refused/)

    expect(updates.length).toBe(1)
    expect(updates[0].status).toBe('unreachable')
    expect(updates[0].lastError).toContain('connection refused')
  })

  it('kicks a background devbox pre-warm with the machine id AFTER stamping ready', async () => {
    const { runner } = makeFakeRunner((command) => {
      if (command.startsWith('install ') || command.startsWith('sudo install ')) {
        return { exitCode: 0, stdout: '', stderr: '' }
      }
      return { exitCode: 0, stdout: `${CAPS_LINE}\n`, stderr: '' }
    })
    const events: string[] = []
    const machine = makeMachine()

    await bootstrapMachine(machine, {
      waitForSshReady: async () => {},
      runner,
      updateMachine: async (_id, u) => {
        if ((u as Partial<Machine>).status) events.push(`update:${(u as Partial<Machine>).status}`)
        return machine
      },
      prewarmDevbox: (machineId) => {
        events.push(`prewarm:${machineId}`)
      },
    })

    // Fired exactly once, with the machine id, strictly AFTER the ready stamp.
    expect(events).toEqual(['update:ready', `prewarm:${machine.id}`])
  })

  it('a devbox pre-warm kick failure does NOT fail bootstrap or mark the machine unreachable', async () => {
    const { runner } = makeFakeRunner((command) => {
      if (command.startsWith('install ') || command.startsWith('sudo install ')) {
        return { exitCode: 0, stdout: '', stderr: '' }
      }
      return { exitCode: 0, stdout: `${CAPS_LINE}\n`, stderr: '' }
    })
    const updates: Array<Partial<Machine>> = []
    const machine = makeMachine()

    const caps = await bootstrapMachine(machine, {
      waitForSshReady: async () => {},
      runner,
      updateMachine: async (_id, u) => {
        updates.push(u as Partial<Machine>)
        return machine
      },
      // A synchronous throw out of the kick must be swallowed at the call site —
      // it must never reach bootstrap's outer catch (which would mark unreachable).
      prewarmDevbox: () => {
        throw new Error('prewarm kick boom')
      },
    })

    expect(caps.arch).toBe('aarch64')
    // Exactly one row write — the ready stamp. No unreachable write.
    expect(updates.length).toBe(1)
    expect(updates[0].status).toBe('ready')
    expect(updates.some((u) => u.status === 'unreachable')).toBe(false)
  })
})

describe('computeBootstrapVersion', () => {
  it('changes when EITHER script content changes (hashes both, fixed order)', () => {
    const base = computeBootstrapVersion('boot-A', 'box-A')
    // A change to bootstrap.sh alone re-triggers.
    expect(computeBootstrapVersion('boot-B', 'box-A')).not.toBe(base)
    // A change to box-provision.sh alone re-triggers (M2: the bug being fixed).
    expect(computeBootstrapVersion('boot-A', 'box-B')).not.toBe(base)
    // Order is fixed — swapping the two contents yields a different hash.
    expect(computeBootstrapVersion('box-A', 'boot-A')).not.toBe(base)
  })

  it('currentBootstrapVersion is a stable 64-hex sha the drift reconciler diffs against', () => {
    const v = currentBootstrapVersion()
    expect(v).toMatch(/^[0-9a-f]{64}$/)
    // Deterministic for the running build (no wall-clock / randomness).
    expect(currentBootstrapVersion()).toBe(v)
  })
})

describe('bootstrap.sh --core-cidr validation + egress ruleset rendering', () => {
  const bootstrapPath = join(repoRoot, 'scripts/machine/bootstrap.sh')
  const networkPolicy = readFileSync(join(repoRoot, 'k8s/network-policy.yaml'), 'utf8')

  // `--print-egress-ruleset` is a side-effect-free dry-run: it validates the
  // supplied --core-cidr(s) then prints the exact `table inet tau_egress`
  // ruleset apply_egress_lockdown would load — NO apt, NO nft, NO sudo. That
  // lets these run fast + unprivileged in CI and lets us syntax-check the real
  // rules. An invalid --core-cidr must still exit 2 (validation runs first).
  async function runBootstrap(args: string[]): Promise<{ exitCode: number; stdout: string; stderr: string }> {
    const proc = Bun.spawn(['bash', bootstrapPath, ...args], {
      stdin: 'ignore',
      stdout: 'pipe',
      stderr: 'pipe',
    })
    const [stdout, stderr, exitCode] = await Promise.all([
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
      proc.exited,
    ])
    return { exitCode, stdout, stderr }
  }

  // --- validation (SECURITY-CRITICAL: --core-cidr is interpolated into root nft) ---
  it('rejects a --core-cidr with a prefix > 32 (exit 2, before any nft/apt)', async () => {
    const { exitCode } = await runBootstrap(['--print-egress-ruleset', '--core-cidr', '10.0.0.0/33'])
    expect(exitCode).toBe(2)
  })

  it('rejects a --core-cidr with an octet > 255 (exit 2)', async () => {
    const { exitCode } = await runBootstrap(['--print-egress-ruleset', '--core-cidr', '192.168.300.0/24'])
    expect(exitCode).toBe(2)
  })

  it('rejects a --core-cidr with prefix /0 (would allow the whole internet — exit 2)', async () => {
    // 0.0.0.0/0 as an allow-exception would punch the entire egress lockdown open,
    // silently disabling it — reject the operator error before nft sees it.
    const { exitCode } = await runBootstrap(['--print-egress-ruleset', '--core-cidr', '0.0.0.0/0'])
    expect(exitCode).toBe(2)
  })

  it('rejects a --core-cidr with a leading-zero octet (010.0.0.0 → exit 2, nonstandard/ambiguous)', async () => {
    const { exitCode } = await runBootstrap(['--print-egress-ruleset', '--core-cidr', '010.0.0.0/24'])
    expect(exitCode).toBe(2)
  })

  it('rejects a --core-cidr with no prefix (exit 2)', async () => {
    const { exitCode } = await runBootstrap(['--print-egress-ruleset', '--core-cidr', '10.0.0.0'])
    expect(exitCode).toBe(2)
  })

  it('rejects a shell/nft-injection --core-cidr (exit 2)', async () => {
    const { exitCode } = await runBootstrap(['--print-egress-ruleset', '--core-cidr', '10.0.0.0/8; rm -rf /'])
    expect(exitCode).toBe(2)
  })

  it('rejects a newline-injected --core-cidr (exit 2)', async () => {
    const { exitCode } = await runBootstrap([
      '--print-egress-ruleset',
      '--core-cidr',
      '10.0.0.0/8\nelements = { evil }',
    ])
    expect(exitCode).toBe(2)
  })

  // --- rendering (the exact ruleset the root nft -f load receives) ---
  it('renders the v4 deny-list byte-identical to k8s/network-policy.yaml egress', async () => {
    const { exitCode, stdout } = await runBootstrap(['--print-egress-ruleset'])
    expect(exitCode).toBe(0)
    // Every `except:` CIDR in the network policy must appear in the rendered set.
    const policyCidrs = [...networkPolicy.matchAll(/- (\d+\.\d+\.\d+\.\d+\/\d+)/g)].map((m) => m[1])
    expect(policyCidrs.length).toBeGreaterThan(10)
    for (const cidr of policyCidrs) expect(stdout).toContain(cidr)
    // And the chain shape: loopback + established/related + DNS accepted before drop.
    expect(stdout).toContain('table inet tau_egress {')
    expect(stdout).toContain('oif "lo" accept')
    expect(stdout).toContain('ct state established,related accept')
    expect(stdout).toContain('udp dport 53 accept')
    expect(stdout).toContain('tcp dport 53 accept')
    expect(stdout).toContain('ip daddr @denied4 drop')
  })

  it('renders IPv6 drops (fc00::/7 ULA + fe80::/10 link-local) closing the dual-stack leak', async () => {
    const { exitCode, stdout } = await runBootstrap(['--print-egress-ruleset'])
    expect(exitCode).toBe(0)
    expect(stdout).toContain('type ipv6_addr')
    expect(stdout).toContain('fc00::/7')
    expect(stdout).toContain('fe80::/10')
    expect(stdout).toContain('ip6 daddr @denied6 drop')
  })

  it('accepts repeatable valid --core-cidr(s) and interpolates them into an allow rule', async () => {
    const { exitCode, stdout } = await runBootstrap([
      '--print-egress-ruleset',
      '--core-cidr',
      '10.1.2.0/24',
      '--core-cidr',
      '203.0.113.5/32',
    ])
    expect(exitCode).toBe(0)
    expect(stdout).toContain('ip daddr { 10.1.2.0/24, 203.0.113.5/32 } accept')
  })

  // GATED (nft + passwordless sudo available): prove the rendered ruleset is
  // syntactically valid nftables. `nft -c -f` type-checks + parses WITHOUT loading,
  // but still initializes its netlink cache and therefore needs privilege on CI.
  // nft 1.1 rejects pipe-backed /dev/stdin, so use a temporary regular file,
  // matching how a ruleset is installed on a host. Skip only hosts that cannot
  // actually run the privileged validator (e.g. macOS dev hosts).
  const canValidateNft =
    Bun.which('nft') !== null && Bun.which('sudo') !== null && Bun.spawnSync(['sudo', '-n', 'true']).exitCode === 0
  it.skipIf(!canValidateNft)('the rendered ruleset passes nft validation (syntax valid)', async () => {
    const { stdout } = await runBootstrap(['--print-egress-ruleset', '--core-cidr', '10.9.9.0/24'])
    const rulesetPath = join(tmpdir(), `tau-egress-ruleset-${randomUUID()}.nft`)
    writeFileSync(rulesetPath, stdout)
    try {
      const proc = Bun.spawn(['sudo', '-n', 'nft', '-c', '-f', rulesetPath], { stdout: 'pipe', stderr: 'pipe' })
      const [stderr, exitCode] = await Promise.all([new Response(proc.stderr).text(), proc.exited])
      expect({ exitCode, stderr }).toEqual({ exitCode: 0, stderr: '' })
    } finally {
      rmSync(rulesetPath, { force: true })
    }
  })
})

// The prebaked-image branch is exercised through the side-effect-free
// `--print-prebaked-decision` dry run (mirrors --print-egress-ruleset /
// --print-subid-start): it reads the marker at `--marker-file`, prints the
// decision (`skip` = use baked tooling / `install` = full BYO path) on stdout,
// and logs any drift WARNING on stderr — with NO apt/nix/install side effects.
// This proves a prebaked image ALWAYS uses its baked tooling (a drift warns but
// never triggers a bricking reinstall over the baked /nix).
describe('bootstrap.sh prebaked-image decision (--print-prebaked-decision dry run)', () => {
  const bootstrapPath = join(repoRoot, 'scripts/machine/bootstrap.sh')

  // Read a pinned version straight out of the script so the "match" marker is
  // always in lockstep with the current pins.
  function pin(name: string): string {
    const m = bootstrapSh.match(new RegExp(`^${name}="([^"]+)"`, 'm'))
    if (!m) throw new Error(`could not read ${name} from bootstrap.sh`)
    return m[1]
  }
  const BUN = pin('BUN_VERSION')
  const NIX = pin('NIX_VERSION')
  const DEVBOX = pin('DEVBOX_VERSION')
  const PLAYWRIGHT = pin('PLAYWRIGHT_VERSION')

  function tmpMarker(json: string): string {
    const p = join(tmpdir(), `prebaked-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`)
    writeFileSync(p, json)
    return p
  }

  async function decide(markerPath: string): Promise<{ exitCode: number; stdout: string; stderr: string }> {
    const proc = Bun.spawn(['bash', bootstrapPath, '--print-prebaked-decision', '--marker-file', markerPath], {
      stdin: 'ignore',
      stdout: 'pipe',
      stderr: 'pipe',
    })
    const [stdout, stderr, exitCode] = await Promise.all([
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
      proc.exited,
    ])
    return { exitCode, stdout, stderr }
  }

  it('no marker present → full install path (unchanged BYO behavior), no warning', async () => {
    const missing = join(tmpdir(), `prebaked-absent-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`)
    const { exitCode, stdout, stderr } = await decide(missing)
    expect(exitCode).toBe(0)
    expect(stdout.trim()).toBe('install')
    expect(stderr).not.toContain('WARNING')
  })

  it('marker present + all versions match → skip installs (use baked tooling), no drift warning', async () => {
    const marker = tmpMarker(
      JSON.stringify({ bunVersion: BUN, nixVersion: NIX, devboxVersion: DEVBOX, playwrightVersion: PLAYWRIGHT })
    )
    const { exitCode, stdout, stderr } = await decide(marker)
    expect(exitCode).toBe(0)
    expect(stdout.trim()).toBe('skip')
    // A clean match logs the fast-path notice but NEVER a drift warning.
    expect(stderr).not.toContain('WARNING')
    expect(stderr).toContain('skipping install steps')
  })

  it('marker present + a version DRIFTS → STILL skip installs (never reinstall over a prebaked image) + honest drift WARNING', async () => {
    // A nix bump the image has not been rebaked for. Reinstalling over the baked
    // /nix would brick provisioning (the official installer refuses to run over an
    // existing /nix), so bootstrap keeps using the baked tooling and only warns.
    const marker = tmpMarker(
      JSON.stringify({ bunVersion: BUN, nixVersion: '9.9.9', devboxVersion: DEVBOX, playwrightVersion: PLAYWRIGHT })
    )
    const { exitCode, stdout, stderr } = await decide(marker)
    expect(exitCode).toBe(0)
    // The prebaked image never falls back to the (bricking) install path on drift.
    expect(stdout.trim()).toBe('skip')
    // The warning names the drift, says it is using the baked tooling, and
    // recommends a rebake — it does NOT claim a self-heal / auto-upgrade.
    expect(stderr).toContain('WARNING')
    expect(stderr).toContain('nix 9.9.9')
    expect(stderr).toContain(`script ${NIX}`)
    expect(stderr).toContain('using baked tooling')
    expect(stderr).toContain('rebake')
    expect(stderr).not.toContain('self-heal')
  })
})

// The shared per-machine browser (browser-tools-in-sandbox spec §4.1) pins
// Playwright in THREE places that MUST agree: scripts/machine/bootstrap.sh
// (install_browser), packages/machine-image/Dockerfile (the baked RUN layer),
// and apps/core/docker-sandbox/Dockerfile (dev parity). apps/core itself no
// longer depends on playwright at all — browsing lives entirely in the
// machine's tau-browser service — so the lockstep is enforced purely across
// these three install sites, which must all drive the exact same Chromium
// build. A drift silently ships a machine whose Chromium does not match what
// the other two sites expect. This gate fails closed the moment they diverge.
// It also asserts the Phase-1 wiring is real (install_browser + verify_browser
// are actually invoked, and playwrightVersion feeds the manifest/prebaked
// marker) so the bootstrap hash genuinely reflects the change.
describe('browser tools Phase 1 — Playwright pin lockstep + wiring', () => {
  const machineImageDockerfile = readFileSync(join(repoRoot, 'packages/machine-image/Dockerfile'), 'utf8')
  const dockerSandboxDockerfile = readFileSync(join(repoRoot, 'apps/core/docker-sandbox/Dockerfile'), 'utf8')

  function bootstrapPin(name: string): string {
    const m = bootstrapSh.match(new RegExp(`^${name}="([^"]+)"`, 'm'))
    if (!m) throw new Error(`could not read ${name} from bootstrap.sh`)
    return m[1]
  }
  function dockerfileArg(dockerfile: string, name: string): string {
    const m = dockerfile.match(new RegExp(`^ARG ${name}=(\\S+)`, 'm'))
    if (!m) throw new Error(`could not read ARG ${name} from Dockerfile`)
    return m[1]
  }

  const pin = bootstrapPin('PLAYWRIGHT_VERSION')

  it('bootstrap.sh, machine-image, and docker-sandbox pin the SAME Playwright version', () => {
    expect(dockerfileArg(machineImageDockerfile, 'PLAYWRIGHT_VERSION')).toBe(pin)
    expect(dockerfileArg(dockerSandboxDockerfile, 'PLAYWRIGHT_VERSION')).toBe(pin)
  })

  it('all three pins are an explicit x.y.z version, not a range (regex-extracted, independent of any npm dependency)', () => {
    // apps/core no longer has its own `playwright` dependency to cross-check
    // against (browsing lives in the machine's tau-browser service now), so
    // this asserts the lockstep purely from the three install-site sources:
    // each PLAYWRIGHT_VERSION/ARG is pinned to an exact version, and (per the
    // test above) all three already agree with one another.
    const versionRe = /^\d+\.\d+\.\d+$/
    expect(pin, 'bootstrap.sh PLAYWRIGHT_VERSION must be an exact x.y.z version').toMatch(versionRe)
    expect(
      dockerfileArg(machineImageDockerfile, 'PLAYWRIGHT_VERSION'),
      'machine-image Dockerfile ARG PLAYWRIGHT_VERSION must be an exact x.y.z version'
    ).toMatch(versionRe)
    expect(
      dockerfileArg(dockerSandboxDockerfile, 'PLAYWRIGHT_VERSION'),
      'docker-sandbox Dockerfile ARG PLAYWRIGHT_VERSION must be an exact x.y.z version'
    ).toMatch(versionRe)
  })

  it('drives the Playwright CLI through bun, never its #!/usr/bin/env node .bin shim', () => {
    // Machine hosts install bun and NOT node (bootstrap.sh install_bun; there is
    // no install_node). The node_modules/.bin/playwright shim is `#!/usr/bin/env
    // node`, so invoking it exits 127 ("node: not found") — the original cause of
    // chromium_download_failed on every do_droplet host. Both the SSH-bootstrap
    // path and the baked image must therefore run cli.js under bun.
    // The docker-sandbox image is Alpine/musl and installs Chromium's runtime
    // libs via apk (NOT Playwright's Debian --with-deps), but it must STILL drive
    // the CLI through bun, never the #!/usr/bin/env node .bin shim (same #1168
    // rule; the container has bun but no guaranteed node on PATH for this step).
    for (const [name, src] of [
      ['bootstrap.sh', bootstrapSh],
      ['machine-image Dockerfile', machineImageDockerfile],
      ['docker-sandbox Dockerfile', dockerSandboxDockerfile],
    ] as const) {
      expect(src, `${name} must not invoke the node-shim`).not.toContain('.bin/playwright')
      expect(src, `${name} must run playwright cli.js (not the shim)`).toMatch(
        /node_modules\/playwright\/cli\.js"? install/
      )
    }
    // Each source invokes cli.js under bun via its own stable bun path.
    expect(bootstrapSh).toContain(
      '"${BUN_BIN_LINK}" "${FICUS_BROWSER_ROOT}/node_modules/playwright/cli.js" install --with-deps chromium'
    )
    expect(machineImageDockerfile).toContain(
      '/opt/tau/bin/bun /opt/tau/browser/node_modules/playwright/cli.js install --with-deps chromium'
    )
    // Alpine: no --with-deps (apk supplies the runtime libs above), bun on PATH.
    expect(dockerSandboxDockerfile).toContain('bun /opt/tau/browser/node_modules/playwright/cli.js install chromium')
  })

  it('locates Chromium with a chrome-linux* glob (playwright renamed chrome-linux -> chrome-linux64)', () => {
    // Playwright's chromium build dir moved from chrome-linux to chrome-linux64
    // (chromium >=138 / PLAYWRIGHT 1.58.2 = build 1208). A bare "chrome-linux/"
    // matches neither the idempotency fast-path nor the AppArmor attach path, so
    // both must glob. (chromium.launch() resolves the runtime binary itself, so
    // the launcher is unaffected — only these two literal paths.)
    const apparmor = readFileSync(join(repoRoot, 'scripts/machine/browser/tau-browser-chromium.apparmor'), 'utf8')
    // Idempotency presence check globs the build-dir suffix.
    expect(bootstrapSh).toContain('chromium-*/chrome-linux*/chrome')
    // AppArmor attach path globs it too, in BOTH copies (kept byte-identical).
    for (const [name, src] of [
      ['bootstrap.sh (inline)', bootstrapSh],
      ['tau-browser-chromium.apparmor', apparmor],
    ] as const) {
      expect(src, `${name} AppArmor path must glob chrome-linux*`).toContain(
        'chromium*/chrome-linux*/{chrome,headless_shell}'
      )
      expect(src, `${name} must not pin the stale bare chrome-linux dir`).not.toMatch(/chrome-linux\/\{chrome/)
    }
    // The stale idempotency path is gone.
    expect(bootstrapSh).not.toContain('chromium-*/chrome-linux/chrome')
  })

  it('bounds the Chromium download, retries a stall, and never trusts a partial extraction', () => {
    // Playwright's forked extractor intermittently stalls forever mid-extract
    // under bun, leaving a truncated chrome binary. Unbounded, that holds
    // bootstrap until Core's 15-minute SSH deadline marks the machine
    // unreachable; and a bare chrome-binary presence check would then skip the
    // re-download forever. timeout sits INSIDE sudo so its process-group kill
    // reaches the extractor.
    expect(bootstrapSh).toContain(
      'DEBIAN_FRONTEND=noninteractive \\\n        timeout -k 30 "${BROWSER_DOWNLOAD_TIMEOUT_SECS}" \\\n        "${BUN_BIN_LINK}" "${FICUS_BROWSER_ROOT}/node_modules/playwright/cli.js" install --with-deps chromium \\\n        && break'
    )
    expect(bootstrapSh).toContain('for attempt in $(seq 1 "${BROWSER_DOWNLOAD_ATTEMPTS}"); do')
    // Every attempt together must leave room inside Core's 15-minute bootstrap run.
    const perAttempt = Number(/^BROWSER_DOWNLOAD_TIMEOUT_SECS=(\d+)$/m.exec(bootstrapSh)?.[1])
    const attempts = Number(/^BROWSER_DOWNLOAD_ATTEMPTS=(\d+)$/m.exec(bootstrapSh)?.[1])
    expect(attempts).toBeGreaterThan(1)
    expect(perAttempt * attempts).toBeLessThanOrEqual(600)
    // Presence requires Playwright's own completion marker, not just the binary.
    expect(bootstrapSh).toContain('chromium-*/INSTALLATION_COMPLETE')
  })

  it('install_browser + verify_browser are wired into the install/boot flow (the bump is real)', () => {
    // install_browser runs in the non-prebaked branch (after install_devbox), and
    // verify_browser unconditionally in main() — both as `... || true` standalone
    // lines so a browser failure can never set -e-abort bootstrap.
    expect(bootstrapSh).toContain('install_devbox')
    expect(bootstrapSh).toMatch(/^\s*install_browser \|\| true$/m)
    expect(bootstrapSh).toMatch(/^\s*verify_browser \|\| true$/m)
    // The Chromium sandbox is never downgraded: no chromium.launch passes a
    // no-sandbox arg (comments mentioning "--no-sandbox" are fine; an actual
    // `args: [..., '--no-sandbox']` on a launch call is not).
    expect(bootstrapSh).not.toMatch(/args:\s*\[[^\]]*no-sandbox/)
  })

  it('playwrightVersion feeds the manifest + prebaked marker (both bootstrap.sh and the image)', () => {
    // bootstrap.sh writes it into the per-machine manifest…
    expect(bootstrapSh).toContain('"playwrightVersion":"%s"')
    // …and the machine image bakes it into /opt/tau/prebaked (drift-warned by
    // log_prebaked_decision).
    expect(machineImageDockerfile).toContain('playwrightVersion')
  })

  // The browser assets (service stub, sandbox-verification program, AppArmor
  // profile, SYSTEM unit) live once under scripts/machine/browser/ — the machine
  // image COPYs them, and bootstrap.sh embeds them inline (it is streamed
  // standalone over SSH and cannot COPY siblings). If the two copies drift, a VM
  // built from the image and a VM bootstrapped over SSH would run DIFFERENT
  // browser code. These assert byte-identity + that the image COPYs each asset.
  const browserAssets: ReadonlyArray<{ file: string; dest: string }> = [
    { file: 'tau-browser.js', dest: '/opt/tau/browser/service/tau-browser.js' },
    { file: 'verify-sandbox.js', dest: '/opt/tau/browser/service/verify-sandbox.js' },
    { file: 'tau-browser-chromium.apparmor', dest: '/etc/apparmor.d/tau-browser-chromium' },
    { file: 'tau-browser.service', dest: '/etc/systemd/system/tau-browser.service' },
  ]

  for (const { file, dest } of browserAssets) {
    it(`bootstrap.sh embeds scripts/machine/browser/${file} byte-for-byte, and the image COPYs it`, () => {
      const content = readFileSync(join(repoRoot, 'scripts/machine/browser', file), 'utf8')
      // Embedded verbatim in a bootstrap.sh heredoc → the whole file is a substring.
      expect(bootstrapSh.includes(content)).toBe(true)
      // The machine image COPYs the same file to its final path.
      expect(machineImageDockerfile).toContain(`COPY scripts/machine/browser/${file} ${dest}`)
    })
  }
})

// The sandbox gate was softened (2026-08-24): an un-sandboxable host must NOT
// fail bootstrap — the machine comes up with browsing marked unavailable
// (durable marker + capabilities.browser + LOUD ERROR log + a stopped/disabled
// unit), and NEVER downgrades to --no-sandbox. These assert that contract on the
// bootstrap.sh source (the failure paths need root + a real Chromium + systemd,
// so they cannot be executed in CI; the CP-facing parse is covered by the
// parseCapabilities tests above).
describe('browser tools Phase 1 — softened sandbox gate (never fails bootstrap)', () => {
  // Extract a shell function body (no nested braces in these functions) so we can
  // assert on it in isolation.
  function funcBody(name: string): string {
    const m = bootstrapSh.match(new RegExp(`\\n${name}\\(\\) \\{\\n([\\s\\S]*?)\\n\\}\\n`))
    if (!m) throw new Error(`could not extract ${name}() from bootstrap.sh`)
    return m[1]
  }

  it('verify_browser never exits non-zero — a broken browser must not fail bootstrap', () => {
    const body = funcBody('verify_browser')
    // No `exit` anywhere in the gate: every failure path returns 0 after marking
    // the browser unavailable (previously these were `exit 1`).
    expect(body).not.toMatch(/\bexit\b/)
    expect(body).toContain('return 0')
    // Happy path marks READY; failure branches mark unavailable.
    expect(body).toContain('browser_mark_ready')
    expect(body).toContain('browser_mark_unavailable')
  })

  it('the unavailable path writes a durable marker (reason + timestamp), is LOUD, and never uses --no-sandbox', () => {
    const body = funcBody('browser_mark_unavailable')
    expect(body).toContain('${FICUS_BROWSER_UNAVAILABLE_MARKER}')
    expect(body).toContain('reason=%s')
    expect(body).toContain('timestamp=%s')
    // Refuses to leave a stale "available" marker.
    expect(body).toMatch(/rm -f "\$\{FICUS_BROWSER_READY_MARKER\}"/)
    // LOUD + control-plane observable (journald): an ERROR-level line.
    expect(body).toContain('ERROR browser unavailable')
    // Never downgrades to an unsafe browser.
    expect(bootstrapSh).not.toMatch(/args:\s*\[[^\]]*no-sandbox/)
  })

  it('the unavailable path stops AND disables the unit so a sandbox-broken service does not flap', () => {
    expect(funcBody('browser_mark_unavailable')).toContain('systemctl disable --now tau-browser.service')
  })

  it('the ready path writes READY and clears any stale UNAVAILABLE', () => {
    const body = funcBody('browser_mark_ready')
    expect(body).toContain('${FICUS_BROWSER_READY_MARKER}')
    expect(body).toMatch(/rm -f "\$\{FICUS_BROWSER_UNAVAILABLE_MARKER\}"/)
  })

  it('print_capabilities reports browser availability to the control plane in both states', () => {
    // The caps line the control plane parses carries browser=available…
    expect(bootstrapSh).toContain('"browser":"available"')
    // …or browser=unavailable with a reason token.
    expect(bootstrapSh).toContain('"browser":"unavailable","browserReason":"%s"')
  })

  // The install/setup steps run under `set -euo pipefail` too — the Chromium
  // download (~350 MB + apt libs) is the single likeliest real-world failure and
  // must NOT brick provisioning. install_browser is fail-open: it marks the
  // browser unavailable with a distinct reason token and returns 0.
  it('_browser_install_steps guards every fallible step with a reason token and never exits', () => {
    const body = funcBody('_browser_install_steps')
    // No `exit` — the machine must still come up.
    expect(body).not.toMatch(/\bexit\b/)
    // Distinct tokens for the likely failures, each paired with `return 1`.
    for (const token of [
      'playwright_install_failed',
      'chromium_download_failed',
      'user_setup_failed',
      'setup_failed',
    ]) {
      expect(body).toContain(`BROWSER_INSTALL_REASON=${token}`)
    }
    // Each guard returns 1 so the first failure stops the flow (set -e is off in
    // this tested context, so a bare failure would otherwise run on).
    expect(body).toMatch(/BROWSER_INSTALL_REASON=chromium_download_failed; return 1/)
  })

  it('install_browser is fail-open: a failed install routes to browser_mark_unavailable and returns 0', () => {
    const body = funcBody('install_browser')
    expect(body).not.toMatch(/\bexit\b/)
    expect(body).toContain('browser_mark_unavailable')
    expect(body).toContain('return 0')
    // Falls back to a generic token if the step forgot to set one.
    expect(body).toContain('${BROWSER_INSTALL_REASON:-install_failed}')
  })

  it('main invokes install_browser AND verify_browser so neither can set -e-abort bootstrap', () => {
    // Both are fail-open internally; `|| true` is the belt-and-braces guarantee.
    expect(bootstrapSh).toContain('install_browser || true')
    expect(bootstrapSh).toContain('verify_browser || true')
  })

  it('verify_browser preserves an install-time reason rather than overwriting it', () => {
    const body = funcBody('verify_browser')
    // Early return when install already marked unavailable with a real reason.
    expect(body).toMatch(/BROWSER_STATUS.*=.*unavailable.*BROWSER_REASON.*!=.*not_verified/s)
    expect(body).toContain('return 0')
  })

  it('runs the tau-browser sandbox check from an accessible CWD (bun yields an empty env otherwise)', () => {
    // bun started in a directory the target user cannot stat silently produces
    // an EMPTY process.env, dropping PLAYWRIGHT_BROWSERS_PATH -> Playwright looks
    // in $HOME/.cache -> "Chromium not found" -> a misleading sandbox_check_failed
    // even though the browser is installed and the userns sandbox works. bootstrap
    // runs as root from /root (0700), which tau-browser cannot enter, and runuser
    // keeps the caller's CWD — so the check MUST cd into an accessible dir first.
    const body = funcBody('verify_browser')
    // The runuser/bun sandbox check is wrapped in a `cd "${FICUS_BROWSER_ROOT}"`
    // subshell (${FICUS_BROWSER_ROOT} is chmod a+rX, so the tau-browser user can
    // stat it) rather than inheriting bootstrap's inaccessible CWD.
    expect(body).toMatch(
      /\(\s*cd "\$\{FICUS_BROWSER_ROOT\}" &&\s*"\$\{SUDO\[@\]\}" runuser -u "\$\{FICUS_BROWSER_USER\}"[\s\S]*?FICUS_BROWSER_VERIFY_JS\}"\s*\)/
    )
    // The bare, CWD-inheriting form (runuser at the start of the `if !`) is gone.
    expect(body).not.toMatch(/if ! "\$\{SUDO\[@\]\}" runuser -u "\$\{FICUS_BROWSER_USER\}"/)
  })

  it('the new install/setup reason tokens are part of the surfaced vocabulary', () => {
    for (const token of [
      'playwright_install_failed',
      'chromium_download_failed',
      'user_setup_failed',
      'setup_failed',
      'install_failed',
    ]) {
      expect(bootstrapSh).toContain(token)
    }
  })
})

describe('browser tools Phase 2 — machine plumbing (group membership, socket env, memory-cap env)', () => {
  // Same extraction idiom as the Phase 1 describe above, generalized to work
  // against either script's source text.
  function funcBodyIn(src: string, name: string): string {
    const m = src.match(new RegExp(`\\n${name}\\(\\) \\{\\n([\\s\\S]*?)\\n\\}\\n`))
    if (!m) throw new Error(`could not extract ${name}() from script`)
    return m[1]
  }

  it('ensure_user (box-provision.sh) joins the box user to the tau-browser group when it exists, fail-open otherwise', () => {
    const body = funcBodyIn(boxProvisionSh, 'ensure_user')
    // Guarded by getent so a pre-browser machine (no tau-browser group) does
    // not fail provisioning.
    expect(body).toMatch(/getent group tau-browser/)
    expect(body).toMatch(/usermod -aG tau-browser/)
    // Fail-open: the missing-group branch logs a warning and does not exit.
    expect(body).not.toMatch(/\bexit\b/)
  })

  it('render_unit (box-provision.sh) carries FICUS_BROWSER_SOCK in BOTH unit modes so the box server can reach the socket', () => {
    const body = funcBodyIn(boxProvisionSh, 'render_unit')
    // One occurrence per unit-mode branch (system + user): a box must reach the
    // browser socket no matter which manager runs its server.
    expect(body.match(/Environment=FICUS_BROWSER_SOCK=\/run\/tau-browser\/sock/g)).toHaveLength(2)
  })

  it('write_browser_memory_dropin (bootstrap.sh) writes BOTH MemoryHigh and FICUS_BROWSER_MEMORY_HIGH_MB from the same computed cap', () => {
    const body = funcBodyIn(bootstrapSh, 'write_browser_memory_dropin')
    expect(body).toMatch(/MemoryHigh=%sM/)
    expect(body).toMatch(/Environment=FICUS_BROWSER_MEMORY_HIGH_MB=%s/)
    // Both format placeholders are fed from the same computed mem_high_mb
    // variable (the printf call passes it at least twice).
    const printfCall = body.match(/printf '[^']*'\s*((?:"\$\{mem_high_mb\}"\s*)+)/)
    if (!printfCall) throw new Error('could not find the printf call writing memory.conf')
    const argCount = (printfCall[1].match(/\$\{mem_high_mb\}/g) || []).length
    expect(argCount).toBeGreaterThanOrEqual(2)
  })
})

describe('box-provision.sh validation (unprivileged — must exit BEFORE any sudo call)', () => {
  const boxProvisionPath = join(repoRoot, 'scripts/machine/box-provision.sh')

  // These run the real script on real bash as the (non-root) test user. Every
  // case below must decide its fate purely from arg validation, so no sudo /
  // privileged command is ever reached — hence they are safe (and fast) in CI.
  async function runBoxProvision(
    args: string[],
    options: { env?: Record<string, string> } = {}
  ): Promise<{ exitCode: number; stderr: string }> {
    const proc = Bun.spawn(['bash', boxProvisionPath, ...args], {
      stdin: 'ignore',
      stdout: 'pipe',
      stderr: 'pipe',
      ...(options.env ? { env: { ...process.env, ...options.env } } : {}),
    })
    const [stderr, exitCode] = await Promise.all([new Response(proc.stderr).text(), proc.exited])
    return { exitCode, stderr }
  }

  /**
   * A PATH whose `sudo` refuses every call with a marker and exit 77. The
   * "gets past validation" case must stop at the FIRST privileged call, but
   * that only happens naturally where sudo prompts; on hosts with passwordless
   * sudo (GitHub-hosted runners, most dev boxes) the script would really start
   * provisioning a box user and overrun the test timeout instead.
   */
  function refusingSudoPath(): string {
    const dir = mkdtempSync(join(tmpdir(), 'tau-refusing-sudo-'))
    writeFileSync(join(dir, 'sudo'), '#!/bin/sh\necho "tau-test: sudo refused: $*" >&2\nexit 77\n', { mode: 0o755 })
    return `${dir}:${process.env.PATH ?? ''}`
  }

  it('rejects an invalid --unix-user charset (exit 2)', async () => {
    const { exitCode } = await runBoxProvision(['--sandbox-id', 'x', '--unix-user', 'bad;name', '--port', '50100'])
    expect(exitCode).toBe(2)
  })

  it('refuses to remove a non-box user like root (exit 2)', async () => {
    // `root` passes the general charset but fails the box_<hash> removal guard.
    const { exitCode } = await runBoxProvision(['--unix-user', 'root', '--remove'])
    expect(exitCode).toBe(2)
  })

  it('rejects a non-numeric --port (exit 2)', async () => {
    const { exitCode } = await runBoxProvision([
      '--sandbox-id',
      'x',
      '--unix-user',
      'box_0123456789ab',
      '--port',
      'abc',
    ])
    expect(exitCode).toBe(2)
  })

  it('rejects a newline-injected --port (exit 2)', async () => {
    const { exitCode } = await runBoxProvision([
      '--sandbox-id',
      'x',
      '--unix-user',
      'box_0123456789ab',
      '--port',
      '50100\nExecStart=evil',
    ])
    expect(exitCode).toBe(2)
  })

  it('requires --port on the provision path (exit 2 when omitted)', async () => {
    // No --remove → provisioning → an empty port would otherwise bake
    // `Environment=FICUS_BOX_PORT=` into the unit. The script must refuse it
    // BEFORE any privileged call.
    const { exitCode } = await runBoxProvision(['--sandbox-id', 'x', '--unix-user', 'box_0123456789ab'])
    expect(exitCode).toBe(2)
  })

  it('ignores a missing --port on the --remove path (never the validation exit 2)', async () => {
    // --remove does not use the port; omitting it must not trip port validation.
    // (root fails the box_<hash> removal guard with exit 2, so use a box user and
    // assert it gets PAST port validation to the privileged teardown.)
    const { exitCode } = await runBoxProvision(['--unix-user', 'box_0123456789ab', '--remove'])
    expect(exitCode).not.toBe(2)
  })

  // --restore-stream carries two caller-supplied values that are interpolated
  // into privileged commands, so both are validated BEFORE any sudo call.
  it('rejects an unknown --codec on the stream-restore path (exit 2)', async () => {
    const { exitCode, stderr } = await runBoxProvision([
      '--unix-user',
      'box_0123456789ab',
      '--restore-stream',
      '--codec',
      'xz',
      '--state-dirs',
      'workspace .private',
    ])
    expect(exitCode).toBe(2)
    // Rejected BY the codec check — not incidentally by an unknown-argument bail.
    expect(stderr).toContain('--codec')
    expect(stderr).not.toContain('unknown argument')
  })

  it('rejects a --state-dirs entry that is not a plain path segment (exit 2)', async () => {
    for (const dirs of ['workspace ../etc', 'workspace $(id)', '..']) {
      const { exitCode, stderr } = await runBoxProvision([
        '--unix-user',
        'box_0123456789ab',
        '--restore-stream',
        '--codec',
        'gzip',
        '--state-dirs',
        dirs,
      ])
      expect(exitCode).toBe(2)
      expect(stderr).toContain('--state-dirs')
    }
  })

  it('rejects an EMPTY or omitted --state-dirs on the stream-restore path (exit 2)', async () => {
    // An empty list passed the per-entry loop vacuously, and the restore then
    // re-owned only `.private` (reown_members' fallback) while exiting 0 — so a
    // streamed ~/workspace would be left ROOT-OWNED on a box reported healthy.
    // Validate it the way --codec is validated: before any privileged call.
    for (const args of [
      ['--unix-user', 'box_0123456789ab', '--restore-stream', '--codec', 'gzip', '--state-dirs', ''],
      ['--unix-user', 'box_0123456789ab', '--restore-stream', '--codec', 'gzip', '--state-dirs', '   '],
      ['--unix-user', 'box_0123456789ab', '--restore-stream', '--codec', 'gzip'],
    ]) {
      const { exitCode, stderr } = await runBoxProvision(args)
      expect(exitCode).toBe(2)
      expect(stderr).toContain('--state-dirs')
      expect(stderr).not.toContain('unknown argument')
    }
  })

  it('refuses to stream-restore into a non-box user like root (exit 2)', async () => {
    const { exitCode, stderr } = await runBoxProvision([
      '--unix-user',
      'root',
      '--restore-stream',
      '--codec',
      'gzip',
      '--state-dirs',
      '.private',
    ])
    expect(exitCode).toBe(2)
    expect(stderr).toContain('non-box user')
  })

  const restoreValidationUser = 'box_ffffeeee1111'

  it('ignores an omitted --port on the --restore-stream path', async () => {
    expect(Bun.spawnSync(['id', '-u', restoreValidationUser]).exitCode).not.toBe(0)
    const { stderr } = await runBoxProvision([
      '--unix-user',
      restoreValidationUser,
      '--restore-stream',
      '--codec',
      'gzip',
      '--state-dirs',
      'workspace .private',
    ])
    // The fixture user is deliberately absent, so this message proves parsing
    // reached the restore branch without relying on tar or host state.
    expect(stderr).toContain('cannot restore')
    expect(stderr).not.toContain('--port')
  })

  it('does not consume the next option when --port has no value', async () => {
    const { exitCode, stderr } = await runBoxProvision([
      '--unix-user',
      restoreValidationUser,
      '--restore-stream',
      '--port',
      '--codec',
      'gzip',
      '--state-dirs',
      'workspace .private',
    ])
    expect(exitCode).toBe(2)
    expect(stderr).toContain('--port requires a value')
    expect(stderr).not.toContain('--state-dirs')
  })

  it.each([
    ['', 'empty'],
    ['abc', 'nonnumeric'],
    ['0', 'zero'],
    ['-1', 'negative'],
    ['1023', 'below range'],
    ['65536', 'above range'],
  ])('rejects a supplied %s --port during stream restore (%s)', async (port) => {
    const { exitCode, stderr } = await runBoxProvision([
      '--unix-user',
      restoreValidationUser,
      '--restore-stream',
      '--codec',
      'gzip',
      '--state-dirs',
      'workspace .private',
      '--port',
      port,
    ])
    expect(exitCode).toBe(2)
    expect(stderr).toContain('invalid --port')
  })

  it('uses the last repeated --port and accepts ordering independent valid ports', async () => {
    for (const args of [
      ['--port', '1024', '--port', '65535', '--restore-stream'],
      ['--restore-stream', '--port', '50100'],
    ]) {
      const { stderr } = await runBoxProvision([
        '--unix-user',
        restoreValidationUser,
        ...args,
        '--codec',
        'gzip',
        '--state-dirs',
        'workspace .private',
      ])
      expect(stderr).toContain('cannot restore')
      expect(stderr).not.toContain('invalid --port')
    }
  })

  it('rejects unsupported --port=value syntax without treating it as a port', async () => {
    const { exitCode, stderr } = await runBoxProvision([
      '--unix-user',
      restoreValidationUser,
      '--restore-stream',
      '--port=50100',
      '--codec',
      'gzip',
      '--state-dirs',
      'workspace .private',
    ])
    expect(exitCode).toBe(2)
    expect(stderr).toContain('unknown argument: --port=50100')
  })

  it('lets a valid box user + port PAST validation (fails later at the first privileged call, never with the validation exit 2)', async () => {
    const { exitCode, stderr } = await runBoxProvision(
      ['--sandbox-id', 'x', '--unix-user', 'box_0123456789ab', '--port', '50100'],
      { env: { PATH: refusingSudoPath() } }
    )
    // It gets past validation and then trips on the first privileged call —
    // anything but the validation exit code proves validation passed. As a
    // non-root user that call goes through the refusing sudo above, which is
    // the proof it got that far rather than dying somewhere else.
    expect(exitCode).not.toBe(2)
    // Only Linux hosts get as far as sudo: elsewhere the script stops at its
    // systemd preflight (still not exit 2, which is all the assertion above
    // needs). Root has no sudo call to refuse.
    if (process.platform === 'linux' && process.getuid?.() !== 0) {
      expect(exitCode).toBe(77)
      expect(stderr).toContain('tau-test: sudo refused')
    }
  }, 30_000)
})

// The subuid/subgid overlap-scan allocation (Fix 3) is exercised through the
// side-effect-free --print-subid-start dry run (mirrors bootstrap's
// --print-egress-ruleset): it scans fixture maps and prints the start
// ensure_subid_range would append, with NO useradd/tee/sudo.
describe('box-provision.sh subuid overlap scan (--print-subid-start dry run)', () => {
  const boxProvisionPath = join(repoRoot, 'scripts/machine/box-provision.sh')

  async function printSubidStart(subuid: string, subgid: string): Promise<string> {
    const proc = Bun.spawn(
      ['bash', boxProvisionPath, '--print-subid-start', '--subuid-file', subuid, '--subgid-file', subgid],
      { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' }
    )
    const [stdout, exitCode] = await Promise.all([new Response(proc.stdout).text(), proc.exited])
    expect(exitCode).toBe(0)
    return stdout.trim()
  }

  function tmpMap(lines: string): string {
    const p = join(tmpdir(), `subid-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`)
    writeFileSync(p, lines)
    return p
  }

  it('starts at the conventional base (100000) when both maps are empty', async () => {
    const start = await printSubidStart(tmpMap(''), tmpMap(''))
    expect(start).toBe('100000')
  })

  it('picks the next block ABOVE the highest existing end — no overlap with a reused-uid peer', async () => {
    // A peer already holds [165536, 231072); the OLD keyed formula could hand a
    // recycled uid a start inside that live range. The scan must jump past it.
    const subuid = tmpMap('alice:100000:65536\nbob:165536:65536\n')
    const subgid = tmpMap('alice:100000:65536\n')
    const start = await printSubidStart(subuid, subgid)
    expect(start).toBe('231072')
  })

  it('takes the MAX end across BOTH maps so neither map collides', async () => {
    const subuid = tmpMap('alice:100000:65536\n')
    const subgid = tmpMap('carol:900000:65536\n')
    const start = await printSubidStart(subuid, subgid)
    expect(start).toBe('965536')
  })

  it('skips malformed lines defensively (a garbage row cannot poison the scan)', async () => {
    const subuid = tmpMap('garbage-line-no-colons\nalice:100000:65536\n')
    const subgid = tmpMap('')
    const start = await printSubidStart(subuid, subgid)
    expect(start).toBe('165536')
  })
})

describe('waitForSshReady', () => {
  const machine = { name: 'wsr-test' } as unknown as Parameters<typeof waitForSshReady>[1]

  it('returns once SSH answers (retries past connection-closed)', async () => {
    let calls = 0
    const runner = {
      run: async () => {
        calls++
        // exit 255 (connection closed) twice, then success
        return { exitCode: calls < 3 ? 255 : 0, stdout: '', stderr: 'closed' }
      },
    } as unknown as Parameters<typeof waitForSshReady>[0]
    await waitForSshReady(runner, machine, { attempts: 5, intervalMs: 1 })
    expect(calls).toBe(3)
  })

  it('gives up after the attempt budget with a clear error', async () => {
    const runner = {
      run: async () => ({ exitCode: 255, stdout: '', stderr: 'closed' }),
    } as unknown as Parameters<typeof waitForSshReady>[0]
    await expect(waitForSshReady(runner, machine, { attempts: 3, intervalMs: 1 })).rejects.toThrow(
      /did not become ready/
    )
  })
})

// ---------------------------------------------------------------------------
// box-provision.sh --restore-stream, RUN FOR REAL
//
// The unprivileged tests above only prove argument validation. This block runs
// the actual stream-restore against real tar, on real files, and asserts the
// OUTCOME — because this is the data-loss-adjacent path: a restore that
// "succeeds" while delivering an empty or partial ~/workspace, or one that
// leaves it root-owned, destroys a squad's authoritative work.
//
// The script's privileged calls are satisfied by a PATH shim (`sudo` execs its
// arguments, `id`/`getent` answer for a fake box user, `chown` records and
// no-ops) so no root is needed. Extraction, member selection, and the 0755/0700
// locks are therefore exercised for real; only the chown's EFFECT is simulated
// (its arguments are asserted instead) — that part needs a live smoke.
// ---------------------------------------------------------------------------
// box-provision.sh's restore-stream extraction uses GNU-tar-only flags
// (--no-overwrite-dir); production box hosts are Linux (GNU tar) and so is CI,
// but a macOS dev's bare `tar` is bsdtar. Prefer whichever of `tar`/`gtar`
// reports "GNU tar"; skip the block entirely (rather than fail) when neither is.
function findGnuTar(): string | null {
  for (const cand of ['tar', 'gtar']) {
    // Resolve to an ABSOLUTE path: the fixture shims a `tar` first on PATH, so a
    // bare name here would make that shim exec itself (fork bomb).
    const abs = Bun.which(cand)
    if (!abs) continue
    try {
      const r = Bun.spawnSync([abs, '--version'])
      if (r.exitCode === 0 && r.stdout.toString().includes('GNU tar')) return abs
    } catch {
      // candidate not runnable — try the next
    }
  }
  return null
}
const GNU_TAR = findGnuTar()

describe.skipIf(!GNU_TAR)('box-provision.sh --restore-stream (real tar, shimmed privilege)', () => {
  const boxProvisionPath = join(repoRoot, 'scripts/machine/box-provision.sh')
  const BOX_USER = 'box_0123456789ab'

  function makeFixture(): { root: string; home: string; shim: string; chownLog: string } {
    const root = join(tmpdir(), `tau-restore-stream-${randomUUID()}`)
    const home = join(root, 'home')
    const shim = join(root, 'shim')
    const chownLog = join(root, 'chown.log')
    mkdirSync(join(home, 'workspace'), { recursive: true })
    mkdirSync(join(home, '.private'), { recursive: true })
    mkdirSync(shim, { recursive: true })
    // The source box's state, as the migration's source-side tar would carry it.
    mkdirSync(join(root, 'src', 'workspace', 'nested'), { recursive: true })
    mkdirSync(join(root, 'src', '.private'), { recursive: true })
    writeFileSync(join(root, 'src', 'workspace', 'authoritative.txt'), 'squad work')
    writeFileSync(join(root, 'src', 'workspace', 'nested', 'deep.txt'), 'deep work')
    writeFileSync(join(root, 'src', '.private', 'secret.txt'), 'private scratch')

    const write = (name: string, body: string) => {
      const path = join(shim, name)
      writeFileSync(path, `#!/usr/bin/env bash\n${body}\n`)
      chmodSync(path, 0o755)
    }
    write('sudo', 'exec "$@"')
    write('id', `if [ "$1" = "-u" ] && [ -n "\${2:-}" ]; then echo 1000; else echo 1000; fi`)
    write('getent', `echo "${BOX_USER}:x:1000:1000::${home}:/bin/bash"`)
    write('chown', `echo "$@" >> ${chownLog}`)
    write('install', 'dest="${!#}"; mkdir -p "$dest"; chmod 700 "$dest"')
    // The script calls bare `tar`, whose extract needs GNU-tar flags. Pin it to
    // the GNU tar this block gated on so a macOS bsdtar can't reach the script.
    write('tar', `exec ${GNU_TAR} "$@"`)
    return { root, home, shim, chownLog }
  }

  async function runRestoreStream(
    fixture: ReturnType<typeof makeFixture>,
    opts: { codec: 'gzip' | 'zstd'; stateDirs: string; truncateTo?: number; stagingId?: string }
  ): Promise<{ exitCode: number; stderr: string }> {
    const flag = opts.codec === 'zstd' ? '--zstd' : '-z'
    const cut = opts.truncateTo === undefined ? '' : ` | head -c ${opts.truncateTo}`
    const script =
      `export PATH="${fixture.shim}:$PATH"; ` +
      `(tar -c ${flag} -f - -C ${fixture.root}/src workspace .private${cut}) | ` +
      `bash ${boxProvisionPath} --unix-user ${BOX_USER} --restore-stream ` +
      `--codec ${opts.codec} --state-dirs '${opts.stateDirs}' --staging-id ${opts.stagingId === undefined ? '11111111-1111-4111-8111-111111111111' : opts.stagingId}`
    const proc = Bun.spawn(['bash', '-c', script], { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' })
    const [stderr, exitCode] = await Promise.all([new Response(proc.stderr).text(), proc.exited])
    return { exitCode, stderr }
  }

  it('extracts the piped tar into operation staging, leaving HOME untouched until promotion', async () => {
    const fixture = makeFixture()
    try {
      const { exitCode, stderr } = await runRestoreStream(fixture, {
        codec: 'gzip',
        stateDirs: 'workspace .private',
      })

      expect(exitCode).toBe(0)
      // The whole tree landed — not just the top-level dir entries.
      expect(
        readFileSync(
          join(fixture.home, '.tau-migrate', '11111111-1111-4111-8111-111111111111', 'workspace', 'authoritative.txt'),
          'utf8'
        )
      ).toBe('squad work')
      expect(
        readFileSync(
          join(fixture.home, '.tau-migrate', '11111111-1111-4111-8111-111111111111', 'workspace', 'nested', 'deep.txt'),
          'utf8'
        )
      ).toBe('deep work')
      expect(
        readFileSync(
          join(fixture.home, '.tau-migrate', '11111111-1111-4111-8111-111111111111', '.private', 'secret.txt'),
          'utf8'
        )
      ).toBe('private scratch')
      // ...with the modes a squad box needs to function (a 0700 ~/workspace or a
      // world-readable ~/.private is a broken box, not a restored one).
      expect(
        statSync(join(fixture.home, '.tau-migrate', '11111111-1111-4111-8111-111111111111', 'workspace')).mode & 0o777
      ).toBe(0o755)
      expect(
        statSync(join(fixture.home, '.tau-migrate', '11111111-1111-4111-8111-111111111111', '.private')).mode & 0o777
      ).toBe(0o700)
      // Every restored member is handed back to the box user recursively — the
      // trap this path exists to avoid is a root-owned ~/workspace.
      const chowns = readFileSync(fixture.chownLog, 'utf8')
      expect(chowns).toContain(
        `-R ${BOX_USER}:${BOX_USER} ${join(fixture.home, '.tau-migrate', '11111111-1111-4111-8111-111111111111', 'workspace')}`
      )
      expect(chowns).toContain(
        `-R ${BOX_USER}:${BOX_USER} ${join(fixture.home, '.tau-migrate', '11111111-1111-4111-8111-111111111111', '.private')}`
      )
      expect(stderr).toContain('restored streamed archive')
    } finally {
      rmSync(fixture.root, { recursive: true, force: true })
    }
  })

  it('requires operation staging and never falls back to extracting into HOME', async () => {
    const fixture = makeFixture()
    try {
      const { exitCode, stderr } = await runRestoreStream(fixture, {
        codec: 'gzip',
        stateDirs: 'workspace .private',
        stagingId: '',
      })
      expect(exitCode).not.toBe(0)
      expect(existsSync(join(fixture.home, 'workspace', 'authoritative.txt'))).toBe(false)
      expect(existsSync(join(fixture.home, '.private', 'secret.txt'))).toBe(false)
    } finally {
      rmSync(fixture.root, { recursive: true, force: true })
    }
  })

  it('FAILS CLOSED on a truncated stream — non-zero exit, and never claims a restore', async () => {
    const fixture = makeFixture()
    try {
      const { exitCode, stderr } = await runRestoreStream(fixture, {
        codec: 'gzip',
        stateDirs: 'workspace .private',
        truncateTo: 200,
      })

      expect(exitCode).not.toBe(0)
      expect(stderr).not.toContain('restored streamed archive')
      // And nothing past the failed extraction ran: no ownership was stamped, so
      // the caller can never mistake a half-extracted home for a restored one.
      expect(existsSync(fixture.chownLog)).toBe(false)
    } finally {
      rmSync(fixture.root, { recursive: true, force: true })
    }
  })

  it('still locks ~/.private for a box whose archive carried nothing (the empty-archive case)', async () => {
    const fixture = makeFixture()
    try {
      // An agent box carries only `.private`; its ~/workspace must still end up
      // owned + moded correctly rather than being skipped.
      const { exitCode } = await runRestoreStream(fixture, { codec: 'gzip', stateDirs: '.private' })

      expect(exitCode).toBe(0)
      expect(
        statSync(join(fixture.home, '.tau-migrate', '11111111-1111-4111-8111-111111111111', '.private')).mode & 0o777
      ).toBe(0o700)
      const chowns = readFileSync(fixture.chownLog, 'utf8')
      expect(chowns).toContain(
        `-R ${BOX_USER}:${BOX_USER} ${join(fixture.home, '.tau-migrate', '11111111-1111-4111-8111-111111111111', '.private')}`
      )
    } finally {
      rmSync(fixture.root, { recursive: true, force: true })
    }
  })
})

describe('tar codec flag: the TS mapping and the bash mapping are the SAME mapping', () => {
  // box-manager WRITES the archive on the source with `tarCodecFlag(codec)` and
  // box-provision.sh READS it on the destination with `tar_codec_flag`. Nothing
  // structurally forces those two to agree — they are two hand-written mappings
  // in two languages — and a disagreement is not a crash but a corrupted
  // restore: the destination would feed a zstd stream to gzip (or worse, ship a
  // partial tree). This runs the CHECKED-IN bash function body and compares it
  // to the TS one, per codec.
  const fnMatch = boxProvisionSh.match(/^tar_codec_flag\(\) \{\n[\s\S]*?\n\}$/m)

  async function bashFlag(codec: string): Promise<string> {
    const proc = Bun.spawn(['bash', '-c', `CODEC='${codec}'\n${fnMatch?.[0]}\ntar_codec_flag`], {
      stdin: 'ignore',
      stdout: 'pipe',
      stderr: 'pipe',
    })
    const [stdout] = await Promise.all([new Response(proc.stdout).text(), proc.exited])
    return stdout
  }

  it('extracts a tar_codec_flag definition from box-provision.sh (the test is not vacuous)', () => {
    expect(fnMatch).not.toBeNull()
  })

  it('agrees on --zstd and -z, in both directions', async () => {
    expect(tarCodecFlag('zstd')).toBe('--zstd')
    expect(tarCodecFlag('gzip')).toBe('-z')
    expect(await bashFlag('zstd')).toBe(tarCodecFlag('zstd'))
    expect(await bashFlag('gzip')).toBe(tarCodecFlag('gzip'))
  })

  it('the bash side treats any non-zstd codec as gzip (matching the TS fallback)', async () => {
    // Both sides key on `zstd` exactly and fall through to gzip otherwise, so
    // an unexpected value can never be read with a flag nothing wrote.
    expect(await bashFlag('something-else')).toBe(tarCodecFlag('gzip'))
  })
})

// ---------------------------------------------------------------------------
// The re-bootstrap-storm regression (#1155 x #1163).
//
// bootstrapMachine (the stamper), currentBootstrapVersion (the boot reconciler's
// yardstick) and boxProvisionArtifact (the steady-state pusher) MUST derive the
// scripts from one resolution. Two independent derivations disagree permanently
// in artifact mode: every worker boot sees drift and re-bootstraps the whole
// fleet, and the artifact push overwrites the release's own box-provision bytes.
// ---------------------------------------------------------------------------
describe('one prebuilt-preferring source: stamp == reconciler target == pushed bytes', () => {
  const SENTINEL_BOOTSTRAP = `#!/bin/bash\n# SENTINEL-BOOTSTRAP-FROM-ARTIFACT\necho '${CAPS_LINE}'\n`
  const SENTINEL_BOX_PROVISION = '#!/bin/bash\n# SENTINEL-BOX-PROVISION-FROM-ARTIFACT\n'
  let artifactRoot: string

  beforeEach(() => {
    artifactRoot = mkdtempSync(join(tmpdir(), 'bootstrap-prebuilt-'))
    writeFileSync(join(artifactRoot, 'artifact.json'), '{}')
    mkdirSync(join(artifactRoot, 'machine'), { recursive: true })
    writeFileSync(join(artifactRoot, 'machine', 'bootstrap.sh'), SENTINEL_BOOTSTRAP)
    writeFileSync(join(artifactRoot, 'machine', 'box-provision.sh'), SENTINEL_BOX_PROVISION)
  })

  afterEach(() => {
    rmSync(artifactRoot, { recursive: true, force: true })
  })

  function okRunner() {
    return makeFakeRunner((command) => {
      if (command.includes('install ')) return { exitCode: 0, stdout: '', stderr: '' }
      return { exitCode: 0, stdout: `${CAPS_LINE}\n`, stderr: '' }
    })
  }

  it('currentBootstrapVersion(opts) hashes the PREBUILT scripts, not the inlined ones', () => {
    const expected = computeBootstrapVersion(SENTINEL_BOOTSTRAP, SENTINEL_BOX_PROVISION)
    expect(currentBootstrapVersion({ root: artifactRoot })).toBe(expected)
    // Not the git-checkout value — the injection actually changed the answer.
    expect(currentBootstrapVersion({ root: artifactRoot })).not.toBe(expectedVersion)
  })

  it('currentBootstrapVersion() still works with zero args (the worker call site)', () => {
    expect(currentBootstrapVersion()).toBe(expectedVersion)
  })

  it('bootstrapMachine stamps the SAME hash the reconciler targets and pushes the prebuilt bytes', async () => {
    const { runner, calls } = okRunner()
    const updates: Array<Partial<Machine>> = []
    const machine = makeMachine()

    await bootstrapMachine(machine, {
      waitForSshReady: async () => {},
      runner,
      updateMachine: async (_id, u) => {
        updates.push(u as Partial<Machine>)
        return machine
      },
      prebuilt: { root: artifactRoot },
    })

    const target = currentBootstrapVersion({ root: artifactRoot })
    expect(updates.length).toBe(1)
    // The storm: a stamp that never equals the reconciler's target re-bootstraps
    // the fleet on every single worker boot.
    expect(updates[0].bootstrapVersion).toBe(target)

    // The pushed bootstrap.sh content is the prebuilt one (it is also what the
    // stamp hashed), and the --version flag carries the same hash.
    expect(calls[0].stdin).toBe(SENTINEL_BOOTSTRAP)
    expect(calls[1].command).toContain(target)
    expect(calls[2].stdin).toBe(SENTINEL_BOX_PROVISION)
  })

  it('an artifact missing machine/box-provision.sh throws BEFORE any row write (no bogus "unreachable" stamp)', async () => {
    // Fail-loud, fail-early: the scripts are resolved ahead of bootstrapMachine's
    // try/catch precisely so an INCOMPLETE RELEASE ARTIFACT (a packaging bug, not
    // a machine fault) cannot be misdiagnosed as an unreachable machine — a stamp
    // that would park a perfectly healthy machine and hide the real cause.
    rmSync(join(artifactRoot, 'machine', 'box-provision.sh'))
    const { runner } = okRunner()
    const updates: Array<Partial<Machine>> = []
    const machine = makeMachine()

    await expect(
      bootstrapMachine(machine, {
        waitForSshReady: async () => {},
        runner,
        updateMachine: async (_id, u) => {
          updates.push(u as Partial<Machine>)
          return machine
        },
        prebuilt: { root: artifactRoot },
      })
    ).rejects.toThrow(/artifact/)

    expect(updates).toEqual([])
  })

  it('bootstrapMachine and buildBoxProvisionArtifact push IDENTICAL box-provision bytes', async () => {
    const { runner, calls } = okRunner()
    const machine = makeMachine()
    await bootstrapMachine(machine, {
      waitForSshReady: async () => {},
      runner,
      updateMachine: async () => machine,
      prebuilt: { root: artifactRoot },
    })

    const pushedByBootstrap = calls.find((c) => c.command.includes('box-provision.sh'))?.stdin
    if (pushedByBootstrap === undefined) throw new Error('bootstrapMachine never pushed box-provision.sh')
    const { files } = await buildBoxProvisionArtifact({ root: artifactRoot })
    const pushedByArtifact = new TextDecoder().decode(files[0].bytes)

    // Disagreement here means the artifact ensure silently reverts the release's
    // box-provision.sh to the bundle's inlined copy on every machine.
    expect(pushedByArtifact).toBe(pushedByBootstrap)
    expect(pushedByArtifact).toBe(SENTINEL_BOX_PROVISION)
  })
})

// box-provision.sh per-box slice limits (--print-slice-limits dry run): the
// values the provisioner writes into /etc/systemd/system/user-<uid>.slice.d so
// one box's build cannot starve every co-located sandbox-server of memory.
describe('box-provision.sh per-box slice limits (--print-slice-limits dry run)', () => {
  const boxProvisionPath = join(repoRoot, 'scripts/machine/box-provision.sh')

  async function printSliceLimits(memtotalKb: string, nproc = '4'): Promise<{ stdout: string; exitCode: number }> {
    const proc = Bun.spawn(
      ['bash', boxProvisionPath, '--print-slice-limits', '--memtotal-kb', memtotalKb, '--nproc', nproc],
      {
        stdin: 'ignore',
        stdout: 'pipe',
        stderr: 'pipe',
      }
    )
    const [stdout, exitCode] = await Promise.all([new Response(proc.stdout).text(), proc.exited])
    return { stdout: stdout.trim(), exitCode }
  }

  it('scales MemoryHigh (35%) and MemoryMax (50%) from host RAM in bytes and bounds tasks', async () => {
    // An 8GB DigitalOcean host reports MemTotal ≈ 8131584 kB.
    const { stdout, exitCode } = await printSliceLimits('8131584')
    expect(exitCode).toBe(0)
    expect(stdout.split('\n')).toEqual([
      `MemoryHigh=${Math.floor((8131584 * 35) / 100) * 1024}`,
      `MemoryMax=${Math.floor((8131584 * 50) / 100) * 1024}`,
      'TasksMax=8192',
      'CPUQuota=200%',
    ])
  })

  it('caps CPU at half the host cores but never below one full core', async () => {
    expect((await printSliceLimits('8131584', '8')).stdout).toContain('CPUQuota=400%')
    expect((await printSliceLimits('8131584', '1')).stdout).toContain('CPUQuota=100%')
    expect((await printSliceLimits('8131584', 'bogus')).exitCode).not.toBe(0)
  })

  it('fails loudly rather than installing garbage when MemTotal is unreadable', async () => {
    const { exitCode } = await printSliceLimits('bogus')
    expect(exitCode).not.toBe(0)
  })
})

// box-provision.sh unit modes (--print-units dry run): the EXACT unit file each
// mode installs. Light (`agent_*`) boxes moved to a per-box SYSTEM unit so they
// stop paying for a `systemd --user` manager + dbus (~13 MB per box; 45 managers
// on the noah host); docker-bearing (`squad_*` / `system_manager_*`) boxes keep
// the user unit byte-for-byte, because rootless dockerd IS a user service.
describe('box-provision.sh unit modes (--print-units dry run)', () => {
  const boxProvisionPath = join(repoRoot, 'scripts/machine/box-provision.sh')

  async function run(args: string[]): Promise<{ stdout: string; stderr: string; exitCode: number }> {
    const proc = Bun.spawn(['bash', boxProvisionPath, ...args], {
      stdin: 'ignore',
      stdout: 'pipe',
      stderr: 'pipe',
    })
    const [stdout, stderr, exitCode] = await Promise.all([
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
      proc.exited,
    ])
    return { stdout, stderr, exitCode }
  }

  async function printUnits(args: string[]): Promise<string> {
    const { stdout, stderr, exitCode } = await run(['--print-units', ...args])
    expect(`${exitCode} ${stderr}`).toBe('0 ')
    return stdout
  }

  it('prints all three per-box SYSTEM units for system mode', async () => {
    const stdout = await printUnits([
      '--unit-mode',
      'system',
      '--unix-user',
      'box_abc123abc123',
      '--port',
      '50100',
      '--sandbox-id',
      'agent_a1',
    ])
    // Byte-exact: this text IS what lands on the machine. Note the two
    // EnvironmentFile lines in host.env→server.env order (Core's pushed
    // server.env must win on conflict) and the ABSOLUTE paths — `%h` in a
    // system unit resolves to the manager's home (/root), not to `User=`.
    //
    // The service-cgroup marker rides the ExecStart switch, NOT an
    // `Environment=` line: EnvironmentFile content overrides `Environment=`
    // regardless of unit order (systemd.exec(5)), so a configurable
    // host.env/server.env value must not be able to defeat the census.
    //
    // The SOCKET owns 127.0.0.1:<port> forever and is the only always-on unit;
    // the proxy is what the socket activates (hence `Service=`), and it
    // `Requires=` the server. The server binds EXECUTOR_SOCKET, not the port.
    expect(stdout).toBe(
      [
        '# path: /etc/systemd/system/tau-box-box_abc123abc123.service',
        '[Unit]',
        'Description=tau sandbox server',
        'After=network-online.target',
        'Wants=network-online.target',
        '',
        '[Service]',
        'Type=simple',
        'User=box_abc123abc123',
        'Group=box_abc123abc123',
        'WorkingDirectory=/home/box_abc123abc123',
        'RuntimeDirectory=tau-box-box_abc123abc123',
        'Environment=FICUS_BOX_PORT=50100',
        'Environment=FICUS_BROWSER_SOCK=/run/tau-browser/sock',
        'Environment=EXECUTOR_SOCKET=/run/tau-box-box_abc123abc123/server.sock',
        'Environment=EXECUTOR_IDLE_EXIT_MS=600000',
        'EnvironmentFile=-/home/box_abc123abc123/.tau/host.env',
        'EnvironmentFile=-/home/box_abc123abc123/.tau/server.env',
        'ExecStartPre=-/bin/bash /opt/tau/bin/box-provision.sh --unix-user box_abc123abc123 --prepare-nix-cache',
        'ExecStart=/opt/tau/bin/bun /opt/tau/server/server.js --service-cgroup',
        'Delegate=no',
        'ExitType=main',
        'KillMode=control-group',
        'Restart=on-failure',
        'RestartSec=2',
        'Slice=tau-box-box_abc123abc123.slice',
        '',
        '[Install]',
        'WantedBy=multi-user.target',
        '# path: /etc/systemd/system/tau-box-box_abc123abc123.socket',
        '[Unit]',
        'Description=tau sandbox server socket',
        '',
        '[Socket]',
        'ListenStream=127.0.0.1:50100',
        'NoDelay=true',
        'Service=tau-box-box_abc123abc123-proxy.service',
        '',
        '[Install]',
        'WantedBy=sockets.target',
        '# path: /etc/systemd/system/tau-box-box_abc123abc123-proxy.service',
        '[Unit]',
        'Description=tau sandbox server socket proxy',
        'Requires=tau-box-box_abc123abc123.service',
        'After=tau-box-box_abc123abc123.service',
        '',
        '[Service]',
        'Type=simple',
        'User=box_abc123abc123',
        'Group=box_abc123abc123',
        'PrivateTmp=no',
        "ExecStartPre=/bin/sh -c 'n=0; while [ ! -S /run/tau-box-box_abc123abc123/server.sock ] && [ $$n -lt 300 ]; do sleep 0.1; n=$$((n+1)); done; test -S /run/tau-box-box_abc123abc123/server.sock'",
        'ExecStart=/usr/lib/systemd/systemd-socket-proxyd --exit-idle-time=30s /run/tau-box-box_abc123abc123/server.sock',
        '',
      ].join('\n')
    )
  })

  it('prints all three systemd --user units for user mode', async () => {
    const stdout = await printUnits([
      '--unit-mode',
      'user',
      '--unix-user',
      'box_abc123abc123',
      '--port',
      '50100',
      '--sandbox-id',
      'squad_s1',
    ])
    // `%h`/`%t` are kept as specifiers: both units run under the SAME user
    // manager, so `%t` resolves to the same /run/user/<uid> in each — no uid
    // lookup is needed to make the server and the proxy agree on the socket.
    expect(stdout).toBe(
      [
        '# path: /home/box_abc123abc123/.config/systemd/user/tau-sandbox-server.service',
        '[Unit]',
        'Description=tau sandbox server',
        'After=network-online.target',
        'Wants=network-online.target',
        '',
        '[Service]',
        'Type=simple',
        'RuntimeDirectory=tau-sandbox',
        'Environment=FICUS_BOX_PORT=50100',
        'Environment=FICUS_BROWSER_SOCK=/run/tau-browser/sock',
        'Environment=EXECUTOR_SOCKET=%t/tau-sandbox/server.sock',
        'Environment=EXECUTOR_IDLE_EXIT_MS=600000',
        'EnvironmentFile=-%h/.tau/host.env',
        'EnvironmentFile=-%h/.tau/server.env',
        'ExecStartPre=-/bin/bash /opt/tau/bin/box-provision.sh --unix-user box_abc123abc123 --prepare-nix-cache',
        'ExecStart=/opt/tau/bin/bun /opt/tau/server/server.js --service-cgroup',
        'Delegate=no',
        'ExitType=main',
        'KillMode=control-group',
        'Restart=on-failure',
        'RestartSec=2',
        '',
        '[Install]',
        'WantedBy=default.target',
        '# path: /home/box_abc123abc123/.config/systemd/user/tau-sandbox-server.socket',
        '[Unit]',
        'Description=tau sandbox server socket',
        '',
        '[Socket]',
        'ListenStream=127.0.0.1:50100',
        'NoDelay=true',
        'Service=tau-sandbox-server-proxy.service',
        '',
        '[Install]',
        'WantedBy=sockets.target',
        '# path: /home/box_abc123abc123/.config/systemd/user/tau-sandbox-server-proxy.service',
        '[Unit]',
        'Description=tau sandbox server socket proxy',
        'Requires=tau-sandbox-server.service',
        'After=tau-sandbox-server.service',
        '',
        '[Service]',
        'Type=simple',
        'PrivateTmp=no',
        "ExecStartPre=/bin/sh -c 'n=0; while [ ! -S %t/tau-sandbox/server.sock ] && [ $$n -lt 300 ]; do sleep 0.1; n=$$((n+1)); done; test -S %t/tau-sandbox/server.sock'",
        'ExecStart=/usr/lib/systemd/systemd-socket-proxyd --exit-idle-time=30s %t/tau-sandbox/server.sock',
        '',
      ].join('\n')
    )
  })

  it('derives the mode from the sandboxId prefix when --unit-mode is omitted', async () => {
    const base = ['--unix-user', 'box_abc123abc123', '--port', '50100', '--sandbox-id']
    // agent_* → system; squad_* / system_manager_* (and any unknown legacy id,
    // which must never be silently moved onto a different unit) → user.
    expect(await printUnits([...base, 'agent_a1'])).toContain('# path: /etc/systemd/system/')
    expect(await printUnits([...base, 'squad_s1'])).toContain('# path: /home/box_abc123abc123/.config/')
    expect(await printUnits([...base, 'system_manager_u1'])).toContain('# path: /home/box_abc123abc123/.config/')
    expect(await printUnits([...base, 'sb-legacy'])).toContain('# path: /home/box_abc123abc123/.config/')
  })

  it('refuses --with-docker in system mode (rootless docker needs the user manager)', async () => {
    const { exitCode, stderr } = await run([
      '--sandbox-id',
      'agent_a1',
      '--unix-user',
      'box_abc123abc123',
      '--port',
      '50100',
      '--with-docker',
    ])
    expect(exitCode).toBe(2)
    expect(stderr).toContain('--with-docker requires --unit-mode user')
  })

  it('fails loudly when systemd-socket-proxyd is missing rather than installing the old single-unit layout', () => {
    // An older machine image has no systemd-socket-proxyd; installing the
    // socket + proxy units there would leave the box's port owned by a socket
    // whose activated service can never start. Provisioning must refuse.
    const body = readFileSync(join(repoRoot, 'scripts/machine/box-provision.sh'), 'utf8')
    const guard = body.slice(body.indexOf('assert_socket_proxyd() {'))
    expect(guard.indexOf('assert_socket_proxyd() {')).toBe(0)
    const end = guard.indexOf('\n}\n')
    expect(end).toBeGreaterThan(0)
    expect(guard.slice(0, end)).toMatch(/exit 1/)
    // ...and it is actually called on the provisioning path.
    expect(body).toMatch(/\n {2}assert_socket_proxyd\n/)
  })

  it('rejects an unknown --unit-mode instead of guessing', async () => {
    const { exitCode } = await run([
      '--print-units',
      '--unit-mode',
      'sysstem',
      '--unix-user',
      'box_abc123abc123',
      '--port',
      '50100',
    ])
    expect(exitCode).toBe(2)
  })

  // The merged #1363 defect, provisioning side: the service-cgroup marker used
  // to ride `Environment=EXECUTOR_SERVICE_CGROUP=1` ahead of the
  // `EnvironmentFile=` lines. systemd applies EnvironmentFile content OVER
  // `Environment=` values regardless of unit order (systemd.exec(5)), so any
  // host.env/server.env value could silently disable the server's residual-
  // child census while `KillMode=control-group` still killed those children at
  // service exit. The corrected contract carries the marker on the ONE channel
  // those configurable files cannot touch — the unit's own ExecStart argv —
  // and keeps every other unit line (EnvironmentFiles, socket, ownership,
  // restart semantics) intact, so a re-provision of an affected box installs
  // the authoritative marker without disturbing anything else.
  it('marks the service cgroup ONLY through the ExecStart switch in BOTH unit modes (not the EnvironmentFile-overridable channel)', async () => {
    for (const mode of ['system', 'user'] as const) {
      const stdout = await printUnits([
        '--unit-mode',
        mode,
        '--unix-user',
        'box_abc123abc123',
        '--port',
        '50100',
        '--sandbox-id',
        mode === 'system' ? 'agent_a1' : 'squad_s1',
      ])
      const service = stdout.slice(
        stdout.indexOf('# path:') + 1,
        stdout.indexOf('# path:', stdout.indexOf('# path:') + 1)
      )
      // The authoritative marker: argv the root-installed unit owns.
      expect(service).toMatch(/^ExecStart=\/opt\/tau\/bin\/bun \/opt\/tau\/server\/server\.js --service-cgroup$/m)
      // The defeatable channel is gone: no `Environment=` value for the marker
      // that host.env/server.env content could replace.
      expect(service).not.toContain('EXECUTOR_SERVICE_CGROUP')
      // The pinned #1363 lifecycle lines stay byte-identical alongside it.
      expect(service).toContain('Delegate=no')
      expect(service).toContain('ExitType=main')
      expect(service).toContain('KillMode=control-group')
      expect(service).toMatch(/^EnvironmentFile=-.*\.tau\/host\.env$/m)
      expect(service).toMatch(/^EnvironmentFile=-.*\.tau\/server\.env$/m)
    }
  })
})

describe('shared machine Nix cache', () => {
  it('cleans successful and failed installs without changing their exit status', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'tau-nix-install-'))
    try {
      const maintenance = join(dir, 'maintenance.sh')
      const marker = join(dir, 'cleaned')
      writeFileSync(maintenance, '#!/bin/bash\nprintf cleaned > "$CACHE_TEST_MARKER"\nexit 23\n')
      // Portable timeout stand-in: the Linux fixture separately exercises a
      // timed-out maintenance pass. These commands have no external work.
      writeFileSync(join(dir, 'timeout'), '#!/bin/bash\nshift\nexec "$@"\n', { mode: 0o755 })
      for (const status of [0, 7]) {
        writeFileSync(join(dir, 'devbox'), `#!/bin/bash\nexit ${status}\n`, { mode: 0o755 })
        rmSync(marker, { force: true })
        const command = devboxInstallCommand(dir).replaceAll('/opt/tau/bin/box-provision.sh', maintenance)
        const proc = Bun.spawn(['bash', '-c', command], {
          env: { ...process.env, PATH: `${dir}:${process.env.PATH}`, CACHE_TEST_MARKER: marker },
          stdout: 'pipe',
          stderr: 'pipe',
          stdin: 'ignore',
        })
        const [, stderr, code] = await Promise.all([
          new Response(proc.stdout).text(),
          new Response(proc.stderr).text(),
          proc.exited,
        ])
        expect({ code, stderr }).toEqual({ code: status, stderr: '' })
        expect(readFileSync(marker, 'utf8')).toBe('cleaned')
      }
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  it.skipIf(process.platform !== 'linux')('reuses public objects while preserving private cache state', async () => {
    const proc = Bun.spawn(['bash', join(repoRoot, 'scripts/machine/nix-cache.test.sh')], {
      stdout: 'pipe',
      stderr: 'pipe',
      stdin: 'ignore',
    })
    const [stdout, stderr, code] = await Promise.all([
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
      proc.exited,
    ])
    expect({ code, stderr }).toEqual({ code: 0, stderr: '' })
    expect(stdout).toContain('6 cache integration checks passed')
  })
})
