import { readFileSync } from 'fs'
import { join } from 'path'
import { assertCheckoutEnvRenamable, migrateCheckoutEnv } from './env-prefix'
import { restartSupervisor, type SupervisorContext } from './supervisor'
import type { Runner } from './runner'

/**
 * Codes Bun's fetch()/socket layer (and Node-style net errors reaching us
 * through a `cause`) use for connection-level failures. Bun does NOT reject
 * with a Node-style TypeError carrying `.code = 'ECONNREFUSED'` — it rejects
 * with a plain Error whose `.code` is e.g. 'ConnectionRefused'. Mirrors
 * `isConnectionRefusedError` in apps/core/src/lib/infra/local-events.ts.
 */
const TRANSPORT_CODES = new Set([
  'ConnectionRefused',
  'ConnectionClosed',
  'FailedToOpenSocket',
  'ConnectionTimedOut',
  'ECONNREFUSED',
  'ECONNRESET',
  'ENOTFOUND',
  'EAI_AGAIN',
  'ETIMEDOUT',
  'ECONNABORTED',
  'EPIPE',
])

const MAX_CAUSE_DEPTH = 5

/**
 * Classify on error CODE/NAME, walking the `cause` chain — never on
 * free-text message content (messages are not a stable contract across
 * runtimes). The one message-based exception is the WHATWG fetch() TypeError,
 * whose spec-mandated message for a network failure is exactly 'fetch failed'.
 * HTTP errors arrive as plain Errors from client.ts with none of these shapes.
 */
export function isTransportError(err: unknown): boolean {
  let current: unknown = err
  for (let depth = 0; depth < MAX_CAUSE_DEPTH && current && typeof current === 'object'; depth++) {
    const value = current as { name?: unknown; code?: unknown; cause?: unknown; message?: unknown }
    if (typeof value.code === 'string' && TRANSPORT_CODES.has(value.code)) return true
    if (value.name === 'ConnectionRefused') return true
    if (current instanceof TypeError && value.message === 'fetch failed') return true
    current = value.cause
  }
  return false
}

/** The install already uses FICUS_ settings: in its `.env`, or as keys of its `ecosystem.config.js`. */
function installUsesFicusEnv(root: string): boolean {
  const matches = (name: string, pattern: RegExp) => {
    try {
      return pattern.test(readFileSync(join(root, name), 'utf8'))
    } catch {
      return false
    }
  }
  return (
    matches('.env', /^\s*(?:export\s+)?FICUS_[A-Za-z0-9_]*=/m) ||
    matches('ecosystem.config.js', /^\s*['"]?FICUS_[A-Z0-9_]+['"]?\s*:/m)
  )
}

/**
 * The commit `git checkout <ref>` lands on, resolved the way checkout resolves it: an existing
 * local branch first, then anything `<ref>` names as it is (a tag, a commit, FETCH_HEAD), and only
 * then the remote-tracking branch checkout would create a local branch from. Null when none does.
 */
async function checkoutCommit(runGit: (argv: string[]) => ReturnType<Runner>, ref: string): Promise<string | null> {
  for (const rev of [`refs/heads/${ref}`, ref, `refs/remotes/origin/${ref}`]) {
    const resolved = await runGit(['rev-parse', '--verify', '--quiet', `${rev}^{commit}`])
    const sha = resolved.stdout.trim()
    if (resolved.code === 0 && /^[0-9a-f]{40,64}$/.test(sha)) return sha
  }
  return null
}

/**
 * `server update --ref <ref>` onto code that predates the Ficus rename would run it on settings it
 * cannot read (it reads TAU_ only). Refuse before the checkout, and name the way back: the
 * byte-for-byte backups the rename took. `rev` is what is checked out (`FETCH_HEAD` for a sha).
 */
async function refuseDowngradePastRename(
  root: string,
  runGit: (argv: string[]) => ReturnType<Runner>,
  ref: string,
  rev: string
): Promise<void> {
  if (!installUsesFicusEnv(root)) return
  const commit = await checkoutCommit(runGit, rev)
  if (!commit) return
  const shown = await runGit(['show', `${commit}:package.json`])
  if (shown.code !== 0) return
  let name: unknown
  try {
    name = (JSON.parse(shown.stdout) as { name?: unknown }).name
  } catch {
    return
  }
  if (name !== 'tau') return
  throw new Error(
    `refusing to check out ${ref}: it predates the Ficus rename (its package.json is named "tau") and reads only TAU_ settings, ` +
      `but ${join(root, '.env')} already uses FICUS_ ones. The way back is the backups the rename took: restore ` +
      `${join(root, '.env.pre-ficus-*')} (and ecosystem.config.js.pre-ficus-*, the newest of each) over the files, then re-run this update`
  )
}

export interface OfflineUpdateArgs {
  root: string
  ref?: string
  runner: Runner
  log(line: string): void
  context: SupervisorContext
}

/**
 * Fast-forward the current branch, or narrowly fetch and check out one explicit
 * branch/tag/commit, then run the CHECKOUT's own `bun run update:offline` and
 * restart the supervisor recorded for the instance, worker first and API last.
 */
export async function runOfflineUpdate(
  args: OfflineUpdateArgs
): Promise<{ before: string; after: string; warnings?: string[] }> {
  const { root, runner, log } = args
  // A TAU_/FICUS_ secret conflict would stop the rename below after the pull and the build:
  // refuse it now, while the checkout is still where it was.
  assertCheckoutEnvRenamable(root)
  const runGit = (argv: string[]) => runner(['git', ...argv], { cwd: root })
  const git = async (argv: string[]) => {
    const r = await runGit(argv)
    if (r.code !== 0) throw new Error(`git ${argv.join(' ')} failed: ${r.stderr || r.stdout}`)
    return r.stdout
  }
  if ((await git(['status', '--porcelain'])).trim() !== '') {
    throw new Error(`${root} has uncommitted changes — commit or discard them before updating`)
  }
  const before = (await git(['rev-parse', 'HEAD'])).trim()
  if (!args.ref) {
    const branch = (await git(['rev-parse', '--abbrev-ref', 'HEAD'])).trim()
    if (branch === 'HEAD')
      throw new Error(`${root} is on a detached HEAD — pass --ref <branch> or check out a branch first`)
  }
  log(`Fetching (${root})`)
  if (!args.ref) {
    // Pull only the current branch's configured upstream. Tags are not needed
    // for a branch update, and following them makes moving channel tags able
    // to break otherwise unrelated updates.
    await git(['pull', '--ff-only', '--no-tags'])
  } else if (/^[0-9a-f]{40,64}$/i.test(args.ref)) {
    // CI and operators may pin an exact commit. FETCH_HEAD avoids inventing a
    // persistent local ref for it.
    await git(['fetch', '--no-tags', 'origin', args.ref])
    await refuseDowngradePastRename(root, runGit, args.ref, 'FETCH_HEAD')
    await git(['checkout', '--recurse-submodules', 'FETCH_HEAD'])
  } else {
    const validation = await runGit(['check-ref-format', '--branch', args.ref])
    if (validation.code !== 0) throw new Error(`invalid update ref: ${args.ref}`)

    const branchRef = `refs/heads/${args.ref}`
    const tagRef = `refs/tags/${args.ref}`
    const remote = await runGit(['ls-remote', '--refs', '--exit-code', 'origin', branchRef, tagRef])
    if (remote.code === 2) throw new Error(`ref ${args.ref} was not found on origin`)
    if (remote.code !== 0) {
      throw new Error(
        `git ls-remote --refs --exit-code origin ${branchRef} ${tagRef} failed: ${remote.stderr || remote.stdout}`
      )
    }

    const refs = new Set(
      remote.stdout
        .split('\n')
        .map((line) => line.split('\t')[1])
        .filter(Boolean)
    )
    if (refs.has(branchRef) && refs.has(tagRef)) {
      throw new Error(`ref ${args.ref} is both a branch and a tag on origin; pass an unambiguous ref`)
    }
    if (refs.has(tagRef)) {
      // nightly is the one documented moving channel tag. Force only its
      // exact destination; immutable release tags still reject disagreement.
      const refspec = `${args.ref === 'nightly' ? '+' : ''}${tagRef}:${tagRef}`
      await git(['fetch', '--no-tags', 'origin', refspec])
    } else if (refs.has(branchRef)) {
      await git(['fetch', '--no-tags', 'origin', `${branchRef}:refs/remotes/origin/${args.ref}`])
    } else {
      throw new Error(`ref ${args.ref} was not found on origin`)
    }
    await refuseDowngradePastRename(root, runGit, args.ref, args.ref)
    await git(['checkout', '--recurse-submodules', args.ref])
  }
  const after = (await git(['rev-parse', 'HEAD'])).trim()
  log(before === after ? `Already at ${after.slice(0, 9)}` : `${before.slice(0, 9)} → ${after.slice(0, 9)}`)

  const update = await runner(['bun', 'run', 'update:offline', '--', '--from', before], {
    cwd: root,
    inherit: true,
    // Both spellings for one release (Ficus rename): the checked-out ref may predate the rename.
    env: { FICUS_UPDATE_SUPERVISOR: args.context.supervisor, TAU_UPDATE_SUPERVISOR: args.context.supervisor },
  })
  if (update.code !== 0) throw new Error(`bun run update:offline exited with ${update.code}`)

  // Ficus rename, after the build and before the restart: the checkout's package name (now the
  // updated one) says whether its code reads FICUS_. The build and migration read the file as it
  // was (the new code bridges TAU_ in-process), so a failed update never leaves it renamed.
  const { warnings } = await migrateCheckoutEnv(root, { log })

  log(`Restarting under ${args.context.supervisor}`)
  await restartSupervisor(args.context)
  // The warnings also ride in the --json document (applyUpdate spreads this result into it).
  return warnings.length > 0 ? { before, after, warnings } : { before, after }
}
