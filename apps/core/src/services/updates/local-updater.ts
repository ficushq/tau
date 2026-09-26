import { randomUUID } from 'crypto'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'fs'
import { dirname, join } from 'path'
import { SYSTEM_RECIPIENT_ID } from '@ficus/shared'
import { LEGACY_ENV_PREFIX } from '@ficus/shared/legacy-env'
import {
  checkoutEnvPrefix,
  migrateLocalInstallEnv,
  planLocalInstallEnvMigration,
  restoreLocalInstallEnv,
  type LocalInstallEnvMigration,
} from '@ficus/shared/node'
import { InboxMessage } from '../../entities/InboxMessage'
import { requireSandboxRuntime } from '../sandbox/runtime'
import { CommandRunner, isKilledByOwnRestart } from './command-runner'
import {
  commandsForTasks,
  detectUpdateTasks,
  isApiRestartCommand,
  isServiceRestartCommand,
  restartCommandsFor,
} from './change-detector'
import { detectDeploymentFlavor, resolveRepoRoot, supportsAutoUpdate } from './deployment-flavor'
import type { DeploymentFlavor, ProcessSupervisor } from './deployment-flavor'
import { acquireUpdateRunLock, type UpdateRunLock } from './run-lock'
import { DEFAULT_LOCAL_AUTO_UPDATE_SETTINGS, MANUAL_UPDATE_TARGETS } from './types'
import type { LocalAutoUpdateSettings, LocalUpdateRun, UpdateTask } from './types'

export class UpdateLockedError extends Error {
  constructor() {
    super('An update is already running')
  }
}
export class DirtyWorktreeError extends Error {
  constructor() {
    super('Worktree has uncommitted changes; commit or stash before updating')
  }
}
export class UnsupportedDeploymentError extends Error {
  constructor(reason: string) {
    super(reason)
  }
}

/**
 * Reads one KEY=VALUE out of an env file the way systemd's EnvironmentFile
 * does: last assignment wins, surrounding quotes are not part of the value.
 * Returns null when the file (or the key) is absent — the caller decides what
 * that means, because "not declared here" is not the same as "not set".
 */
function envFileValue(path: string, key: string): string | null {
  let contents: string
  try {
    contents = readFileSync(path, 'utf8')
  } catch {
    return null
  }
  let found: string | null = null
  for (const line of contents.split('\n')) {
    const trimmed = line.trim()
    if (!trimmed.startsWith(`${key}=`)) continue
    let value = trimmed.slice(key.length + 1).trim()
    if (value.length >= 2 && (value.startsWith('"') || value.startsWith("'")) && value.endsWith(value[0])) {
      value = value.slice(1, -1)
    }
    found = value
  }
  return found
}

/**
 * Decides whether it is safe to RESTART tau-api/tau-worker at the end of an
 * update, or returns the operator-facing reason it is not.
 *
 * An update rewrites no environment: it merges, builds, and restarts. Since
 * FICUS_SANDBOX_RUNTIME became mandatory and explicit, an install whose
 * environment never named a runtime (or still names a retired spelling) comes
 * back from that restart with BOTH services dead — with the new code already
 * checked out, which is the worst possible moment to find out.
 *
 * `envFilePath` is the file the restarted units read (`<dest>/.env`, the
 * EnvironmentFile in both systemd units, and the file bun auto-loads for a dev
 * checkout). When it does not declare the key, the RUNNING process's
 * environment is the fallback — that is the resolved product of the same unit,
 * the same drop-ins and /etc/tau/managed.env that the restarted services will
 * read, and this process is a service started from exactly that stack.
 *
 * Deliberately does NOT repair anything: choosing between docker-sysbox and
 * docker-socket is a security decision (socket mode hands agents the host's
 * docker socket), so the operator makes it.
 */
export function sandboxRuntimeRestartBlocker(
  envFilePath: string,
  env: Record<string, string | undefined> = process.env
): string | null {
  // The legacy spelling is read for one release (Ficus rename): the install's .env may predate it.
  const declared =
    envFileValue(envFilePath, 'FICUS_SANDBOX_RUNTIME') ?? envFileValue(envFilePath, 'TAU_SANDBOX_RUNTIME')
  const effective = declared ?? env.FICUS_SANDBOX_RUNTIME
  try {
    requireSandboxRuntime({ FICUS_SANDBOX_RUNTIME: effective })
    return null
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error)
    return (
      `${reason} Refusing to update: restarting tau-api and tau-worker with this configuration would bring them ` +
      `back down. Set FICUS_SANDBOX_RUNTIME in ${envFilePath} and retry.`
    )
  }
}

/**
 * Ficus rename: a local install's `.env` / `ecosystem.config.js` are hard-renamed TAU_ → FICUS_
 * (byte-for-byte backups) before the update's commands run, and restored from those backups when
 * the update fails, so the old processes restart on exactly the configuration they had.
 */
export interface LocalInstallEnvOps {
  /** Throws a protected TAU_/FICUS_ conflict (names only) before anything is changed. */
  preflight(root: string): void
  migrate(root: string): Promise<LocalInstallEnvMigration>
  restore(backups: string[]): Promise<void>
}

export const defaultLocalInstallEnv: LocalInstallEnvOps = {
  preflight: (root) => {
    planLocalInstallEnvMigration(root)
  },
  // A checkout whose code predates the rename (package.json `tau`) reads TAU_ only.
  migrate: async (root) =>
    checkoutEnvPrefix(root) === LEGACY_ENV_PREFIX ? { renamed: [], backups: [] } : migrateLocalInstallEnv(root),
  restore: (backups) => restoreLocalInstallEnv(backups),
}

/**
 * The supervisors of CLI-managed local installs (`tau server setup`). A `systemd` host is renamed
 * by the setup toolkit, which journals it together with the host's other env files.
 */
const LOCAL_INSTALL_SUPERVISORS: readonly ProcessSupervisor[] = ['pm2', 'launchd', 'systemd-user']

type GitRunner = (args: string[], options?: { env?: Record<string, string> }) => Promise<string>

/** Short form for operator-facing messages; comparisons always use the full sha. */
function short(sha: string): string {
  return sha.slice(0, 12)
}
type GhRunner = (args: string[]) => Promise<string>
type Runner = { runAll(commands: LocalUpdateRun['commands']): Promise<void> }

export class LocalUpdateManager {
  private latest: LocalUpdateRun | null = null
  private active = false
  private repoRoot: string
  private settings: LocalAutoUpdateSettings
  private gitRunner?: GitRunner
  private ghRunner?: GhRunner
  private commandRunner: Runner
  private flavor: () => DeploymentFlavor
  private statusPath: string
  private acquireRunLock: () => Promise<UpdateRunLock | null>
  private sandboxRuntimePreflight: () => void
  private localInstallEnv: LocalInstallEnvOps

  constructor(
    options: {
      repoRoot?: string
      settings?: Partial<LocalAutoUpdateSettings>
      git?: GitRunner
      gh?: GhRunner
      commandRunner?: Runner
      flavor?: () => DeploymentFlavor
      statusPath?: string
      runLock?: () => Promise<UpdateRunLock | null>
      /** Throws to abort an update that would restart the services into a bad runtime. */
      sandboxRuntimePreflight?: () => void
      /** The local-install env rename (Ficus); injectable for tests. */
      localInstallEnv?: LocalInstallEnvOps
    } = {}
  ) {
    // Resolve to the git checkout root (walking up from cwd) so builds/git/status
    // run from the repo root even when the process cwd is <dest>/apps/core, which
    // is where the setup toolkit's systemd units set WorkingDirectory.
    this.repoRoot = options.repoRoot ?? resolveRepoRoot()
    this.settings = { ...DEFAULT_LOCAL_AUTO_UPDATE_SETTINGS, ...options.settings }
    this.gitRunner = options.git
    this.ghRunner = options.gh
    this.commandRunner =
      options.commandRunner ?? new CommandRunner({ cwd: this.repoRoot, onUpdate: () => this.persistActiveRun() })
    this.statusPath = options.statusPath ?? join(this.repoRoot, '.tau', 'local-update-status.json')
    this.latest = this.readPersistedLatest()
    this.flavor = options.flavor ?? (() => detectDeploymentFlavor({ repoRoot: this.repoRoot }))
    this.acquireRunLock = options.runLock ?? acquireUpdateRunLock
    this.sandboxRuntimePreflight =
      options.sandboxRuntimePreflight ??
      (() => {
        // <repoRoot>/.env is what the restarted units read (EnvironmentFile in
        // both, and the file bun auto-loads for a dev checkout).
        const blocker = sandboxRuntimeRestartBlocker(join(this.repoRoot, '.env'))
        if (blocker) throw new Error(blocker)
      })
    this.localInstallEnv = options.localInstallEnv ?? defaultLocalInstallEnv
  }

  /** Whether this deployment is a CLI-managed local install whose env files the updater renames. */
  private renamesLocalInstallEnv(flavor: DeploymentFlavor): boolean {
    return LOCAL_INSTALL_SUPERVISORS.includes(flavor.supervisor)
  }

  /**
   * Runs `commands` with the install's env files renamed to FICUS_ first; when they fail, the
   * files are restored byte-for-byte before the failure propagates (the restart commands are the
   * last ones, so a failure means the old processes are still the ones that will run).
   */
  private async runWithRenamedEnv(flavor: DeploymentFlavor, commands: LocalUpdateRun['commands']): Promise<void> {
    const backups = this.renamesLocalInstallEnv(flavor)
      ? (await this.localInstallEnv.migrate(this.repoRoot)).backups
      : []
    try {
      await this.commandRunner.runAll(commands)
    } catch (err) {
      if (backups.length > 0) await this.localInstallEnv.restore(backups)
      throw err
    }
  }

  /**
   * Refuses an update that would restart the services into an environment
   * naming no supported FICUS_SANDBOX_RUNTIME — they would come back dead.
   *
   * `willRestart` is supplied by the caller because the two paths know it at
   * different times: runTargeted has its plan in hand, while runApply has to
   * decide BEFORE it merges (see its call site) and therefore asks the FLAVOR
   * whether an update on this deployment restarts anything at all. A run that
   * restarts nothing is never blocked: it cannot be broken by the runtime
   * setting, and blocking it would strand an instance on an unrelated
   * misconfiguration.
   */
  private assertSafeToRestart(willRestart: boolean): void {
    if (!willRestart) return
    this.sandboxRuntimePreflight()
  }

  /** Records flavor/support/localRuntime on the run and returns them for gating decisions. */
  private applyFlavor(run: LocalUpdateRun): { flavor: DeploymentFlavor; support: { ok: boolean; reason?: string } } {
    const flavor = this.flavor()
    const support = supportsAutoUpdate(flavor)
    run.flavor = flavor
    run.supported = support.ok
    run.supportReason = support.reason
    run.localRuntime = flavor.sandboxRuntime === 'k3d-local'
    return { flavor, support }
  }

  status() {
    if (!this.latest) this.latest = this.readPersistedLatest()
    return { active: this.active, latest: this.latest, flavor: this.flavor() }
  }

  async check(settings: Partial<LocalAutoUpdateSettings> = {}): Promise<LocalUpdateRun> {
    return this.withLock(async () => {
      const cfg = { ...this.settings, ...settings }
      const run = this.newRun('check', 'checking')
      this.applyFlavor(run)
      run.beforeSha = (await this.git(['rev-parse', 'HEAD'])).trim()
      run.afterSha = await this.remoteLatestSha(cfg)
      run.available = run.beforeSha !== run.afterSha
      run.status = 'skipped'
      run.message = run.available ? 'Update available' : 'Already up to date'
      run.completedAt = new Date().toISOString()
      this.persistLatest(run)
      return run
    })
  }

  applyInBackground(
    opts: { manual?: boolean; settings?: Partial<LocalAutoUpdateSettings>; tasks?: UpdateTask[] } = {}
  ): LocalUpdateRun {
    if (this.active) throw new UpdateLockedError()
    if (opts.tasks) this.validateTargets(opts.tasks, this.flavor())
    const run = this.newRun(opts.manual ? 'manual' : 'automatic', 'running')
    if (opts.manual) {
      const { support } = this.applyFlavor(run)
      if (!support.ok) {
        const reason = support.reason ?? 'Unsupported deployment flavor'
        run.status = 'failed'
        run.error = reason
        run.completedAt = new Date().toISOString()
        this.persistLatest(run)
        throw new UnsupportedDeploymentError(reason)
      }
    }
    // The returned run must reflect the requested tasks synchronously (the
    // background body below starts with an await; runTargeted re-sets these).
    if (opts.tasks) {
      run.targeted = true
      run.selectedTasks = [...opts.tasks]
    }
    this.active = true
    void (async () => {
      // Cross-process mutex (api + worker both run schedulers; `active` is
      // per-process). Acquired inside the background task so this method stays
      // synchronous for its callers; a cross-process conflict surfaces as the
      // run failing immediately with the lock message.
      let lock: UpdateRunLock | null
      try {
        lock = await this.acquireRunLock()
      } catch (err) {
        // Lock acquisition happens before runApply/runTargeted, so those methods
        // cannot record this failure. Persist it here to avoid leaving a run
        // permanently marked running when the database is temporarily unavailable.
        run.status = 'failed'
        run.error = err instanceof Error ? err.message : String(err)
        run.completedAt = new Date().toISOString()
        this.persistLatest(run)
        await this.notifyFailure(run)
        return
      }
      if (!lock) {
        run.status = 'failed'
        run.error = 'An update is already running in another process'
        run.completedAt = new Date().toISOString()
        this.persistLatest(run)
        return
      }
      try {
        await (opts.tasks ? this.runTargeted(run, opts.tasks) : this.runApply(run, opts))
      } finally {
        await lock.release()
      }
    })()
      .catch(() => {
        // runApply/runTargeted record failures on the run. Background updates must not
        // produce unhandled rejections, especially when reload:core restarts
        // this API process before the original request can observe completion.
      })
      .finally(() => {
        this.active = false
      })
    return run
  }

  async apply(opts: { manual?: boolean; settings?: Partial<LocalAutoUpdateSettings> } = {}): Promise<LocalUpdateRun> {
    if (this.active) throw new UpdateLockedError()
    // Claim the in-process slot SYNCHRONOUSLY (before any await) so two
    // same-process applies can't both pass the check, then take the
    // cross-process mutex — see run-lock.ts. Try-lock: an update running in
    // the other core process means this one must not start (not queue).
    this.active = true
    let lock: UpdateRunLock | null = null
    try {
      lock = await this.acquireRunLock()
      if (!lock) throw new UpdateLockedError()
      const run = this.newRun(opts.manual ? 'manual' : 'automatic', 'running')
      return await this.runApply(run, opts)
    } finally {
      this.active = false
      if (lock) await lock.release()
    }
  }

  private async runApply(
    run: LocalUpdateRun,
    opts: { manual?: boolean; settings?: Partial<LocalAutoUpdateSettings> } = {}
  ): Promise<LocalUpdateRun> {
    const cfg = { ...this.settings, ...opts.settings }
    const { flavor, support } = this.applyFlavor(run)
    if (!support.ok) {
      const reason = support.reason ?? 'Unsupported deployment flavor'
      if (opts.manual) {
        run.status = 'failed'
        run.error = reason
        run.completedAt = new Date().toISOString()
        this.persistLatest(run)
        throw new UnsupportedDeploymentError(reason)
      }
      run.status = 'skipped'
      run.message = reason
      run.completedAt = new Date().toISOString()
      this.persistLatest(run)
      return run
    }
    const dirty = (await this.git(['status', '--porcelain'])).trim().length > 0
    if (dirty) {
      run.dirty = true
      if (opts.manual) {
        run.status = 'failed'
        run.error = 'Worktree has uncommitted changes'
        run.completedAt = new Date().toISOString()
        this.persistLatest(run)
        throw new DirtyWorktreeError()
      }
      run.status = 'skipped'
      run.message = 'Skipped because worktree has uncommitted changes'
      run.completedAt = new Date().toISOString()
      this.persistLatest(run)
      return run
    }
    // BEFORE the merge, deliberately: a refusal has to leave the checkout
    // exactly where it was. That means asking the FLAVOR ("does an update on
    // this deployment restart the services at all?") rather than the plan,
    // which does not exist until the merge and diff have happened.
    try {
      this.assertSafeToRestart(restartCommandsFor(flavor.supervisor).length > 0)
      if (this.renamesLocalInstallEnv(flavor)) this.localInstallEnv.preflight(this.repoRoot)
    } catch (err) {
      run.status = 'failed'
      run.error = err instanceof Error ? err.message : String(err)
      run.completedAt = new Date().toISOString()
      this.persistLatest(run)
      await this.notifyFailure(run)
      throw err
    }
    try {
      run.beforeSha = (await this.git(['rev-parse', 'HEAD'])).trim()
      const remoteSha = await this.fetchLatestWithGithubAuth(cfg)
      // Classify by ANCESTRY before merging. `git merge --ff-only` fails with a
      // bare `fatal: Not possible to fast-forward, aborting.` whenever the
      // checkout and the fetched target have diverged, which says nothing about
      // which of them moved or what to do. The condition is ancestry at fetch
      // time — not the workflow event, not the branch name — so it is decided
      // here rather than inferred from a git failure downstream.
      const relation = await this.classifyUpdateRelation(run.beforeSha, remoteSha)
      if (relation.kind === 'up-to-date') {
        run.afterSha = remoteSha
        run.status = 'skipped'
        run.available = false
        run.message = 'Already up to date'
        run.completedAt = new Date().toISOString()
        this.persistLatest(run)
        return run
      }
      if (relation.kind === 'diverged') {
        run.afterSha = remoteSha
        run.status = 'failed'
        run.available = false
        run.error =
          `Cannot fast-forward: the checkout (${short(run.beforeSha)}) and ${cfg.branch} ` +
          `(${short(remoteSha)}) have diverged from a common ancestor (${short(relation.mergeBase)}). ` +
          'Neither is an ancestor of the other, so no update can be applied without choosing what to keep. ' +
          'Reset the checkout onto the branch, or apply the update on a checkout that has not diverged.'
        run.completedAt = new Date().toISOString()
        this.persistLatest(run)
        await this.notifyFailure(run)
        throw new Error(run.error)
      }
      await this.git(['merge', '--ff-only', 'FETCH_HEAD'], { env: this.nonInteractiveGitEnv() })
      run.afterSha = remoteSha
      run.changedFiles = (await this.git(['diff', '--name-only', run.beforeSha, run.afterSha]))
        .split('\n')
        .map((s) => s.trim())
        .filter(Boolean)
      run.selectedTasks = detectUpdateTasks(run.changedFiles, flavor)
      run.commands = commandsForTasks(run.selectedTasks, run.changedFiles, flavor)
      this.persistLatest(run)
    } catch (err) {
      run.status = 'failed'
      run.error = err instanceof Error ? err.message : String(err)
      run.completedAt = new Date().toISOString()
      this.persistLatest(run)
      await this.notifyFailure(run)
      throw err
    }
    try {
      await this.runWithRenamedEnv(flavor, run.commands)
      run.status = 'succeeded'
    } catch (err) {
      run.status = 'failed'
      run.error = err instanceof Error ? err.message : String(err)
      await this.notifyFailure(run)
      throw err
    } finally {
      run.completedAt = new Date().toISOString()
      this.persistLatest(run)
    }
    return run
  }

  private validateTargets(tasks: UpdateTask[], flavor: DeploymentFlavor): void {
    if (tasks.length === 0) throw new Error('Manual update requires at least one target')
    for (const task of tasks) {
      if (!(MANUAL_UPDATE_TARGETS as readonly string[]).includes(task)) {
        throw new Error(`Unsupported manual update target: ${task}`)
      }
      if (task === 'sandbox' && flavor.sandboxRuntime !== 'k3d-local') {
        throw new UnsupportedDeploymentError('Sandbox image rebuild is only automated for local k3d installs')
      }
    }
  }

  private async runTargeted(run: LocalUpdateRun, tasks: UpdateTask[]): Promise<LocalUpdateRun> {
    const { flavor, support } = this.applyFlavor(run)
    run.targeted = true
    if (!support.ok) {
      const reason = support.reason ?? 'Unsupported deployment flavor'
      run.status = 'failed'
      run.error = reason
      run.completedAt = new Date().toISOString()
      this.persistLatest(run)
      throw new UnsupportedDeploymentError(reason)
    }
    run.selectedTasks = [...tasks]
    run.changedFiles = []
    run.commands = commandsForTasks(tasks, [], flavor)
    this.persistLatest(run)
    try {
      // Targeted rebuilds have their plan already, so this is the precise
      // question: does THIS plan restart anything?
      this.assertSafeToRestart(run.commands.some((planned) => isServiceRestartCommand(planned.command)))
      await this.runWithRenamedEnv(flavor, run.commands)
      run.status = 'succeeded'
      run.message = `Rebuilt: ${tasks.join(', ')}`
    } catch (err) {
      run.status = 'failed'
      run.error = err instanceof Error ? err.message : String(err)
      await this.notifyFailure(run)
      throw err
    } finally {
      run.completedAt = new Date().toISOString()
      this.persistLatest(run)
    }
    return run
  }

  private async withLock<T>(fn: () => Promise<T>): Promise<T> {
    if (this.active) throw new UpdateLockedError()
    this.active = true
    try {
      return await fn()
    } finally {
      this.active = false
    }
  }

  private newRun(mode: LocalUpdateRun['mode'], status: LocalUpdateRun['status']): LocalUpdateRun {
    const run: LocalUpdateRun = {
      id: randomUUID(),
      mode,
      status,
      startedAt: new Date().toISOString(),
      changedFiles: [],
      selectedTasks: [],
      commands: [],
    }
    this.persistLatest(run)
    return run
  }

  private persistActiveRun(): void {
    if (this.latest) this.persistLatest(this.latest)
  }

  private persistLatest(run: LocalUpdateRun): void {
    this.latest = run
    try {
      mkdirSync(dirname(this.statusPath), { recursive: true })
      writeFileSync(this.statusPath, JSON.stringify(run))
    } catch {
      // Status persistence is best effort; in-memory status still works.
    }
  }

  private readPersistedLatest(): LocalUpdateRun | null {
    try {
      if (!existsSync(this.statusPath)) return null
      const run = JSON.parse(readFileSync(this.statusPath, 'utf8')) as LocalUpdateRun
      return this.reconcilePersistedRun(run)
    } catch {
      return null
    }
  }

  private reconcilePersistedRun(run: LocalUpdateRun): LocalUpdateRun {
    if (run.status !== 'running') return run

    const lastCommand = run.commands.at(-1)
    if (!lastCommand || !isApiRestartCommand(lastCommand.command)) return run
    // A systemd restart child killed by the restart it requested (SIGTERM, 143) is the
    // restart working. Older cores recorded it as a failed command and died before the run
    // status was persisted; heal that record here so the run does not stay "running" forever.
    if (
      lastCommand.command.includes('systemctl') &&
      lastCommand.status === 'failed' &&
      isKilledByOwnRestart(lastCommand.exitCode ?? 0)
    ) {
      lastCommand.status = 'succeeded'
    }
    if (run.commands.some((cmd) => cmd.status === 'failed')) return run

    // An observed supervisor restart can stop this process before its child result is persisted.
    // `running` therefore proves only that the command started, not that systemd accepted
    // the restart. Keep that outcome truthful rather than letting boot reconciliation turn
    // an unobserved failure into success.
    if (lastCommand.command.includes('systemctl') && lastCommand.status === 'running') {
      lastCommand.status = 'failed'
      run.status = 'failed'
      run.error = 'API restart outcome was not observed'
      run.completedAt = new Date().toISOString()
      this.persistLatest(run)
      return run
    }

    // PM2/launchd handoffs persist the API-restart command as 'succeeded' before dispatching
    // it. The legacy `bun run reload:core` command is the one exception: it was never planned
    // as a distinct restart step, so its status was left 'running'/'pending' when the process
    // restarted itself. Anything else still 'pending' means the run was interrupted before it
    // ever reached the restart command (e.g. killed mid-build) and must not be reported as
    // succeeded.
    const isLegacyReload = lastCommand.command.join(' ').includes('reload:core')
    if (lastCommand.status !== 'pending' || isLegacyReload) {
      for (const command of run.commands) {
        if (command.status === 'pending' || command.status === 'running') command.status = 'succeeded'
      }
      run.status = 'succeeded'
      run.completedAt = new Date().toISOString()
      run.message = 'Update completed; API restarted'
    } else {
      run.status = 'failed'
      run.error = 'Interrupted before the restart command ran'
      run.completedAt = new Date().toISOString()
    }
    this.persistLatest(run)
    return run
  }

  private async notifyFailure(run: LocalUpdateRun): Promise<void> {
    try {
      await InboxMessage.send({
        recipientType: 'system',
        recipientId: SYSTEM_RECIPIENT_ID,
        senderType: 'system',
        wakeEligible: false,
        subject: 'Local Tau update failed',
        content: `Local Tau update ${run.id} failed: ${run.error ?? 'unknown error'}`,
        metadata: { runId: run.id, source: 'local-updater' },
      })
    } catch {
      // Best-effort notification only; the failure remains visible through updater status.
    }
  }

  private async remoteLatestSha(cfg: LocalAutoUpdateSettings): Promise<string> {
    try {
      const repoSlug = await this.githubRepoSlug(cfg)
      return (await this.gh(['api', `repos/${repoSlug}/commits/${cfg.branch}`, '--jq', '.sha'], cfg)).trim()
    } catch {
      throw new Error(
        'Unable to check GitHub for updates with the gh CLI. Connect GitHub in Integrations and select githubConnectionId in update settings when multiple accounts are connected.'
      )
    }
  }

  private async githubRepoSlug(cfg: LocalAutoUpdateSettings): Promise<string> {
    if (cfg.githubOwner && cfg.githubRepo) return `${cfg.githubOwner}/${cfg.githubRepo}`
    return (await this.gh(['repo', 'view', '--json', 'owner,name', '--jq', '.owner.login + "/" + .name'], cfg)).trim()
  }

  private async fetchLatestWithGithubAuth(cfg: LocalAutoUpdateSettings): Promise<string> {
    let repoSlug: string
    try {
      repoSlug = await this.githubRepoSlug(cfg)
    } catch (err) {
      throw new Error(`Unable to resolve GitHub repository for update: ${this.errorMessage(err)}`)
    }

    let token: string
    try {
      token = (await this.gh(['auth', 'token'], cfg)).trim()
      if (!token) throw new Error('gh auth token returned no token')
    } catch {
      throw new Error(
        'Unable to apply GitHub update with the gh CLI. Connect GitHub in Integrations and select githubConnectionId in update settings when multiple accounts are connected.'
      )
    }

    try {
      await this.git(['fetch', '--no-tags', `https://github.com/${repoSlug}.git`, cfg.branch], {
        env: this.githubAuthGitEnv(token),
      })
      return (await this.git(['rev-parse', 'FETCH_HEAD'], { env: this.nonInteractiveGitEnv() })).trim()
    } catch (err) {
      throw new Error(
        `Unable to fetch GitHub update from ${repoSlug} ${cfg.branch}: ${this.sanitizeErrorMessage(err, token)}`
      )
    }
  }

  private githubAuthGitEnv(token: string): Record<string, string> {
    return {
      ...this.nonInteractiveGitEnv(),
      GIT_CONFIG_COUNT: '1',
      GIT_CONFIG_KEY_0: 'http.https://github.com/.extraheader',
      GIT_CONFIG_VALUE_0: `AUTHORIZATION: basic ${Buffer.from(`x-access-token:${token}`).toString('base64')}`,
    }
  }

  private errorMessage(err: unknown): string {
    return err instanceof Error ? err.message : String(err)
  }

  private sanitizeErrorMessage(err: unknown, token: string): string {
    const basicAuthValue = Buffer.from(`x-access-token:${token}`).toString('base64')
    return this.errorMessage(err).split(token).join('[redacted]').split(basicAuthValue).join('[redacted]')
  }

  private nonInteractiveGitEnv(): Record<string, string> {
    return { GIT_TERMINAL_PROMPT: '0', GIT_SSH_COMMAND: 'ssh -o BatchMode=yes' }
  }

  /**
   * How the fetched target relates to the checkout.
   *
   * Uses the merge base rather than two `--is-ancestor` probes: `--is-ancestor`
   * signals its answer through the exit status, so a genuine git failure and a
   * "no, it is not an ancestor" are the same rejected promise, and a broken
   * repository would be reported as divergence.
   */
  private async classifyUpdateRelation(
    localSha: string,
    remoteSha: string
  ): Promise<{ kind: 'fast-forward' | 'up-to-date' | 'diverged'; mergeBase: string }> {
    if (localSha === remoteSha) return { kind: 'up-to-date', mergeBase: localSha }
    const mergeBase = (await this.git(['merge-base', localSha, remoteSha], { env: this.nonInteractiveGitEnv() })).trim()
    // The checkout is an ancestor of the target: a fast-forward applies cleanly.
    if (mergeBase === localSha) return { kind: 'fast-forward', mergeBase }
    // The target is an ancestor of the checkout: the checkout is already ahead.
    if (mergeBase === remoteSha) return { kind: 'up-to-date', mergeBase }
    return { kind: 'diverged', mergeBase }
  }

  private async git(args: string[], options: { env?: Record<string, string> } = {}): Promise<string> {
    if (this.gitRunner) return this.gitRunner(args, options)
    const proc = Bun.spawn(['git', ...args], {
      cwd: this.repoRoot,
      stdout: 'pipe',
      stderr: 'pipe',
      env: { ...process.env, ...options.env },
    })
    const [stdout, stderr, code] = await Promise.all([
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
      proc.exited,
    ])
    if (code !== 0) throw new Error(`git ${args.join(' ')} failed: ${stderr || stdout}`)
    return stdout
  }

  private async gh(args: string[], cfg: LocalAutoUpdateSettings): Promise<string> {
    if (this.ghRunner) return this.ghRunner(args)
    const { resolveInstanceGitHubConnection } = await import('../integrations/github/resolve-connection')
    const connection = await resolveInstanceGitHubConnection(cfg.githubConnectionId)
    if (!connection) throw new Error('A usable GitHub integration connection is required')
    const proc = Bun.spawn(['gh', ...args], {
      cwd: this.repoRoot,
      stdout: 'pipe',
      stderr: 'pipe',
      env: {
        ...process.env,
        GH_TOKEN: connection.credential.accessToken,
        GITHUB_TOKEN: connection.credential.accessToken,
      },
    })
    const [stdout, stderr, code] = await Promise.all([
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
      proc.exited,
    ])
    if (code !== 0) throw new Error(`gh ${args.join(' ')} failed: ${stderr || stdout}`)
    return stdout
  }
}

export const localUpdateManager = new LocalUpdateManager()
