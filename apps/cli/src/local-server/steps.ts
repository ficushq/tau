import { chmodSync, existsSync, readFileSync, writeFileSync, copyFileSync } from 'fs'
import { homedir } from 'os'
import { join } from 'path'
import { mergeEnvFile, parseEnvFile, renderEnvDiff, type EnvUpdate } from './env-file'
import { checkoutEnvRenamePlan, migrateCheckoutEnv, renamedEnvPreview } from './env-prefix'
import { DEFAULT_INSTANCE, derivePorts, generateEcosystem, instanceNames, normalizeLabel } from './instance'
import {
  ensureDatabase,
  ensurePostgresContainer,
  parseDatabaseUrl,
  POSTGRES_IMAGE,
  waitForPostgres,
  waitForTcp,
} from './postgres'
import { parseJlist, pm2Args, runPm2 } from './pm2'
import { makeSupervisorContext, startSupervisor } from './supervisor'
import { nativeLogPath } from './launchd'
import type { Runner } from './runner'
import { SetupFailure, type ExplicitKey, type SetupOptions, type Step } from './types'

export const SECRET_KEYS = ['FICUS_ENCRYPTION_KEY', 'FICUS_INTERNAL_EVENT_TOKEN', 'FICUS_PASSWORD']

export interface Secrets {
  hex32(): string
  token(): string
}

export interface StepDeps {
  runner: Runner
  secrets: Secrets
  fetch: typeof fetch
  sleep(ms: number): Promise<void>
  connect?: (host: string, port: number) => Promise<void>
  supervisorContext?: ReturnType<typeof makeSupervisorContext>
  log(line: string): void
}

export { SetupFailure }

/**
 * Said before `docker run`: pulling the ParadeDB image is minutes of silence
 * on a first install, and silence reads as a hang.
 */
export function startingPostgresLine(container: string): string {
  const image = POSTGRES_IMAGE.split(':')[0]
  return `Starting PostgreSQL container ${container} (a first run pulls ${image} — this can take a few minutes)`
}

/**
 * The managed .env keys for this install.
 *
 * `existingEnv` is the current .env text — both callers already hold it, so it
 * is passed in rather than re-read. `log` is optional so the dry-run plan
 * (which computes the same updates) stays silent; only the step that actually
 * writes .env passes deps.log.
 */
export function computeEnvUpdates(
  opts: SetupOptions,
  secrets: Secrets,
  ctx: { existingEnv?: string; log?: (line: string) => void } = {}
): EnvUpdate[] {
  const ex = (k: ExplicitKey) => opts.explicit.has(k)
  const urlExplicit = ex('port') || ex('appUrl')
  const names = instanceNames(opts.instance)
  const { workerPort, eventPort } = derivePorts(opts.port)
  const updates: EnvUpdate[] = [
    { key: 'FICUS_SANDBOX_RUNTIME', value: opts.runtime === 'k3d' ? 'k8s' : opts.runtime, explicit: ex('runtime') },
  ]
  if (opts.runtime === 'k3d') {
    updates.push(
      { key: 'FICUS_K8S_LOCAL', value: 'true', explicit: ex('runtime') },
      { key: 'FICUS_K8S_NAMESPACE', value: 'tau-sandboxes-dev', explicit: ex('runtime') },
      { key: 'FICUS_K8S_RUNTIME_CLASS', value: '', explicit: ex('runtime') }
    )
  } else if (parseEnvFile(ctx.existingEnv ?? '').FICUS_K8S_LOCAL?.trim() === 'true') {
    // A checkout that used to be local k3d keeps FICUS_K8S_LOCAL=true in .env.
    // The core now ignores it under any other runtime, but leaving the line
    // there reads as live configuration — blank it explicitly (an explicit
    // update is what makes mergeEnvFile overwrite a non-empty value). Only
    // `true` is stale: FICUS_K8S_LOCAL=false already says what it does, and
    // rewriting it would announce a change nobody needs.
    // FICUS_K8S_NAMESPACE / FICUS_K8S_RUNTIME_CLASS are left alone: they are inert
    // once the runtime gates them, and they carry no misleading meaning.
    updates.push({ key: 'FICUS_K8S_LOCAL', value: '', explicit: true })
    ctx.log?.('warning: clearing stale FICUS_K8S_LOCAL from .env (it applies only to the k8s runtime)')
  }
  updates.push(
    { key: 'FICUS_ENCRYPTION_KEY', value: secrets.hex32(), explicit: false },
    { key: 'FICUS_INTERNAL_EVENT_TOKEN', value: secrets.hex32(), explicit: false },
    { key: 'FICUS_PASSWORD', value: secrets.token(), explicit: false },
    { key: 'FICUS_SERVE_WEB', value: '1', explicit: false },
    { key: 'FICUS_INSTANCE', value: opts.instance, explicit: ex('instance') },
    { key: 'PORT', value: String(opts.port), explicit: ex('port') },
    { key: 'WORKER_PORT', value: String(workerPort), explicit: ex('port') },
    { key: 'FICUS_WORKER_EVENT_PORT', value: String(eventPort), explicit: ex('port') },
    { key: 'FICUS_API_URL', value: opts.apiUrl, explicit: ex('port') },
    { key: 'APP_URL', value: opts.appUrl, explicit: urlExplicit },
    { key: 'FICUS_WEB_ORIGIN', value: opts.appUrl, explicit: urlExplicit },
    { key: 'DATABASE_URL', value: opts.databaseUrl, explicit: ex('databaseUrl') || ex('dbName') || ex('dbPort') },
    { key: 'FICUS_UPDATE_SUPERVISOR', value: opts.supervisor, explicit: true },
    { key: 'FICUS_SYSTEM_LOG_PROVIDER', value: opts.supervisor === 'pm2' ? 'pm2' : 'file', explicit: true },
    { key: 'FICUS_PM2_API_NAME', value: opts.supervisor === 'pm2' ? names.api : '', explicit: true },
    { key: 'FICUS_PM2_WORKER_NAME', value: opts.supervisor === 'pm2' ? names.worker : '', explicit: true }
  )
  if (opts.supervisor !== 'pm2') {
    const context = { home: process.env.HOME ?? homedir(), label: opts.instance }
    updates.push(
      { key: 'FICUS_LOG_FILE_API', value: nativeLogPath(context, 'api'), explicit: true },
      { key: 'FICUS_LOG_FILE_WORKER', value: nativeLogPath(context, 'worker'), explicit: true }
    )
  } else {
    updates.push(
      { key: 'FICUS_LOG_FILE_API', value: '', explicit: true },
      { key: 'FICUS_LOG_FILE_WORKER', value: '', explicit: true }
    )
  }
  if (opts.homeDir) updates.push({ key: 'HOME_DIR', value: opts.homeDir, explicit: ex('homeDir') })
  else if (names.homeDir) updates.push({ key: 'HOME_DIR', value: names.homeDir, explicit: ex('instance') })
  return updates
}

function run(deps: StepDeps, root: string, command: string[], env?: Record<string, string>) {
  return deps.runner(command, { cwd: root, env, inherit: true }).then((r) => {
    if (r.code !== 0) throw new SetupFailure(`${command.join(' ')} exited with ${r.code}`)
  })
}

export function buildSteps(opts: SetupOptions, deps: StepDeps): Step[] {
  const root = opts.root
  const envPath = join(root, '.env')
  const names = instanceNames(opts.instance)
  const ecosystemPath = join(root, 'ecosystem.config.js')
  /** The label this checkout is already committed to, if it has one. */
  const persistedLabel = (): string | undefined => {
    if (!existsSync(envPath)) return undefined
    const raw = parseEnvFile(readFileSync(envPath, 'utf8')).FICUS_INSTANCE?.trim()
    return raw ? normalizeLabel(raw) : undefined
  }
  /** An ecosystem written for another instance registers the wrong pm2 apps. */
  const ecosystemMatches = () => {
    if (!existsSync(ecosystemPath)) return false
    const text = readFileSync(ecosystemPath, 'utf8')
    return text.includes(`name: '${names.api}',`) && text.includes(`name: '${names.worker}',`)
  }
  const steps: Step[] = []

  steps.push({
    id: 'config-files',
    title: 'Config files',
    plan: () => [
      existsSync(envPath) ? '.env exists — keep' : 'create .env from .env.example',
      opts.supervisor !== 'pm2'
        ? 'native supervisor selected — leave ecosystem.config.js untouched'
        : !existsSync(ecosystemPath)
          ? `generate ecosystem.config.js for ${names.api} / ${names.worker}`
          : ecosystemMatches()
            ? 'ecosystem.config.js exists — keep'
            : `regenerate ecosystem.config.js for ${names.api} / ${names.worker} (hand edits discarded)`,
    ],
    run: async () => {
      // A checkout that already carries a label belongs to that instance:
      // relabelling it would orphan the pm2 apps, container and data directory
      // the old label owns. A checkout with no label yet (hand-copied .env, or
      // an install made before labels existed) may take one.
      const current = persistedLabel()
      if (current && opts.explicit.has('instance') && current !== opts.instance) {
        // `tau server uninstall` drops the registry entry and the pm2 apps but
        // leaves FICUS_INSTANCE in place, so it cannot relabel a checkout on its own.
        throw new SetupFailure(
          `this checkout is instance "${current}"; to relabel it, remove FICUS_INSTANCE from .env (after unregistering its supervisor with tau server uninstall --root ${root}) — or set up a fresh checkout`
        )
      }
      if (!existsSync(envPath)) copyFileSync(join(root, '.env.example'), envPath)
      if (opts.supervisor !== 'pm2') return
      if (!existsSync(ecosystemPath)) {
        const example = readFileSync(join(root, 'ecosystem.config.example.js'), 'utf8')
        writeFileSync(ecosystemPath, generateEcosystem(example, names))
      } else if (!ecosystemMatches()) {
        // It names another instance's apps: pm2 would start the wrong ones.
        const example = readFileSync(join(root, 'ecosystem.config.example.js'), 'utf8')
        writeFileSync(ecosystemPath, generateEcosystem(example, names))
        deps.log(`warning: regenerated ecosystem.config.js for instance "${opts.instance}" (hand edits were discarded)`)
      }
    },
  })

  const currentEnvText = () =>
    existsSync(envPath) ? readFileSync(envPath, 'utf8') : readFileSync(join(root, '.env.example'), 'utf8')
  // Captured before any step runs: config-files creates both files, so asking
  // afterwards can no longer tell an existing install from a fresh checkout.
  const wasUnlabelledInstall = persistedLabel() === undefined && existsSync(ecosystemPath)
  steps.push({
    id: 'env',
    title: 'Write .env',
    plan: () => {
      // The merge runs on the renamed text (below), so plan against it: planned against the
      // TAU_ text, every managed secret would read as newly generated.
      const rename = checkoutEnvRenamePlan(root)
      const before = renamedEnvPreview(root, currentEnvText())
      const placeholder: Secrets = { hex32: () => '<generated>', token: () => '<generated>' }
      return [
        ...(rename ? [rename] : []),
        ...renderEnvDiff(
          before,
          mergeEnvFile(before, computeEnvUpdates(opts, placeholder, { existingEnv: before })),
          SECRET_KEYS
        ),
      ]
    },
    run: async () => {
      // Ficus rename, BEFORE the merge: merged first, a regenerated FICUS_PASSWORD would be
      // appended beside the install's real TAU_PASSWORD and win over it. A protected conflict
      // stops here with nothing written. Also renames ecosystem.config.js's env keys.
      await migrateCheckoutEnv(root, { log: deps.log })
      const before = readFileSync(envPath, 'utf8')
      const after = mergeEnvFile(before, computeEnvUpdates(opts, deps.secrets, { existingEnv: before, log: deps.log }))
      writeFileSync(envPath, after)
      chmodSync(envPath, 0o600)
      // Labelling an install that had no label moves its data directory. Its
      // database usually stays put — say which of the two happened, or a
      // half-migrated instance looks fine.
      const written = parseEnvFile(after)
      if (wasUnlabelledInstall && opts.instance !== DEFAULT_INSTANCE && written.HOME_DIR) {
        const url = written.DATABASE_URL
        const database =
          parseEnvFile(before).DATABASE_URL === url
            ? `DATABASE_URL is unchanged (${url})`
            : `DATABASE_URL now points at ${url}`
        deps.log(`warning: HOME_DIR now points at ${written.HOME_DIR}; ${database}`)
      }
    },
  })

  if (opts.databaseMode === 'compose') {
    // runSetup resolves the port before building the steps; 5432 is only the
    // fallback for a buildSteps() call that did not go through it.
    const dbPort = opts.dbPort ?? 5432
    steps.push({
      id: 'postgres',
      title: `PostgreSQL (container ${names.container})`,
      plan: () => [
        `docker run ${POSTGRES_IMAGE} as ${names.container} on 127.0.0.1:${dbPort} (or start the existing container)`,
        'wait until stably ready (3 consecutive OK)',
        `create database ${opts.dbName} if missing`,
      ],
      run: async () => {
        deps.log(startingPostgresLine(names.container))
        await ensurePostgresContainer(
          deps.runner,
          { container: names.container, volume: names.volume, port: dbPort },
          { inherit: true }
        )
        await waitForPostgres(deps.runner, names.container, { sleep: deps.sleep })
        await ensureDatabase(deps.runner, names.container, opts.dbName)
      },
    })
  } else {
    const { host, port } = parseDatabaseUrl(opts.databaseUrl)
    steps.push({
      id: 'postgres',
      title: 'PostgreSQL (external)',
      plan: () => [`wait for tcp ${host}:${port}`],
      run: () => waitForTcp(host, port, { sleep: deps.sleep, connect: deps.connect }),
    })
  }

  steps.push({
    id: 'migrate',
    title: 'Database migrations',
    plan: () => ['bun run db:migrate (FICUS_MIGRATE_LIVE=1, DATABASE_URL explicit)'],
    run: () =>
      run(deps, root, ['bun', 'run', 'db:migrate'], {
        DATABASE_URL: opts.databaseUrl,
        FICUS_MIGRATE_LIVE: '1',
        // One release (Ficus rename): a checkout that predates the rename reads TAU_MIGRATE_LIVE.
        TAU_MIGRATE_LIVE: '1',
      }),
  })

  steps.push({
    id: 'build',
    title: 'Build',
    plan: () => ['bun run build:core', 'bun run build:cli', 'bun run build:web'],
    run: async () => {
      for (const script of ['build:core', 'build:cli', 'build:web']) await run(deps, root, ['bun', 'run', script])
    },
  })

  if (opts.runtime === 'docker-socket' || opts.runtime === 'docker-sysbox') {
    steps.push({
      id: 'runtime',
      title: `Sandbox image (${opts.runtime})`,
      plan: () => [
        opts.rebuildImage
          ? 'bun run sandbox:build:docker (forced)'
          : 'bun run sandbox:build:docker unless tau-sandbox:latest exists',
      ],
      run: async () => {
        const present = (await deps.runner(['docker', 'image', 'inspect', 'tau-sandbox:latest'])).code === 0
        if (present && !opts.rebuildImage)
          return deps.log('tau-sandbox:latest exists — skipping build (use --rebuild-image to force)')
        await run(deps, root, ['bun', 'run', 'sandbox:build:docker'])
      },
    })
  } else if (opts.runtime === 'k3d') {
    steps.push({
      id: 'runtime',
      title: 'Local k3d cluster',
      plan: () => ['bun run k3d:setup unless cluster tau-dev exists'],
      run: async () => {
        const list = await deps.runner(['k3d', 'cluster', 'list'])
        if (list.stdout.includes('tau-dev')) return deps.log('k3d cluster tau-dev exists — skipping k3d:setup')
        await run(deps, root, ['bun', 'run', 'k3d:setup'])
      },
    })
  }

  if (opts.start) {
    steps.push({
      id: 'start',
      title: `Start under ${opts.supervisor}`,
      plan: () => [
        `start ${names.worker}, then ${names.api} under ${opts.supervisor}`,
        `wait for ${opts.apiUrl}/health`,
        ...(opts.supervisor === 'pm2' ? ['bunx pm2 save'] : []),
      ],
      run: async () => {
        const context =
          deps.supervisorContext ??
          makeSupervisorContext({
            supervisor: opts.supervisor,
            root,
            label: opts.instance,
            runner: deps.runner,
            log: deps.log,
          })
        if (opts.supervisor === 'pm2') {
          const procs = parseJlist((await runPm2(deps.runner, root, pm2Args('jlist', names))).stdout, names)
          const foreign = procs.find(
            (p) => p.cwd && p.cwd !== root && (p.status === 'online' || p.status === 'launching')
          )
          if (foreign)
            throw new SetupFailure(
              `pm2 already runs ${foreign.name} for instance "${opts.instance}" from another checkout (${foreign.cwd}). Give this checkout its own label with --instance <other-label>, or tau server uninstall --root ${foreign.cwd} the other one`
            )
        }
        await startSupervisor(context)
        for (let i = 0; i < 31; i++) {
          try {
            const res = await deps.fetch(`${opts.apiUrl}/health`)
            if (res.status === 200 || res.status === 401) break
          } catch {
            /* not up yet */
          }
          if (i === 30)
            throw new SetupFailure(`the API did not answer ${opts.apiUrl}/health within 60s — see \`tau server logs\``)
          await deps.sleep(2000)
        }
        if (opts.supervisor === 'pm2') {
          const saved = await runPm2(deps.runner, root, pm2Args('save', names))
          if (saved.code !== 0) throw new SetupFailure('pm2 save failed')
        }
      },
    })
  }

  return steps
}
