import { Command } from 'commander'
import { existsSync, readFileSync } from 'fs'
import { join } from 'path'
import { apiGet, apiPatch, apiPost } from '../client'
import { isTransportError, runOfflineUpdate as defaultOfflineUpdate } from '../local-server/offline-update'
import { defaultRunner } from '../local-server/runner'
import { findInstanceByRoot, getStatePath, resolveRoot } from '../local-server/state'
import { parseEnvFile } from '../local-server/env-file'
import { config } from '../config'
import { output, outputError } from '../output'
import { narrate } from '../local-server/log'
import { makeSupervisorContext } from '../local-server/supervisor'

export interface UpdateDeps {
  resolveRoot(): string
  /** The API the CLI is pointed at (--backend, active backend, FICUS_API_URL, root .env). */
  apiUrl(): string
  /** The port the local checkout serves on (its registry entry, else its .env PORT), if known. */
  localPort(root: string): number | undefined
  offlineUpdate(args: {
    root: string
    ref?: string
    log(line: string): void
  }): Promise<{ before: string; after: string; warnings?: string[] }>
  log(line: string): void
}

export function defaultUpdateDeps(): UpdateDeps {
  return {
    resolveRoot: () => resolveRoot({ env: process.env, statePath: getStatePath(), cwd: process.cwd() }),
    apiUrl: () => config.apiUrl,
    localPort: (root) => {
      // Whichever instance owns this checkout — the default instance is a
      // different checkout as soon as a second one is installed.
      const registered = findInstanceByRoot(root, getStatePath())
      if (registered) return registered.record.port
      const envPath = join(root, '.env')
      if (!existsSync(envPath)) return undefined
      const port = Number(parseEnvFile(readFileSync(envPath, 'utf8')).PORT)
      return Number.isInteger(port) && port > 0 ? port : undefined
    },
    offlineUpdate: (args) => {
      const registered = findInstanceByRoot(args.root, getStatePath())
      if (!registered)
        throw new Error(`checkout ${args.root} is not registered; run tau server setup --root ${args.root}`)
      const context = makeSupervisorContext({
        supervisor: registered.record.supervisor,
        root: args.root,
        label: registered.label,
        runner: defaultRunner,
        log: args.log,
      })
      return defaultOfflineUpdate({ ...args, runner: defaultRunner, context })
    },
    log: narrate,
  }
}

const LOOPBACK_HOSTS = new Set(['localhost', '127.0.0.1', '[::1]'])

/**
 * True when the API the CLI targets is the local checkout's own instance:
 * a loopback host on the port that checkout serves. Only then may a
 * transport failure fall back to updating the checkout offline — a cloud
 * backend that is briefly unreachable must never turn into a git pull on
 * this machine.
 */
export function isLocalTarget(apiUrl: string, localPort: number | undefined): boolean {
  let url: URL
  try {
    url = new URL(apiUrl)
  } catch {
    return false
  }
  if (!LOOPBACK_HOSTS.has(url.hostname === '::1' ? '[::1]' : url.hostname)) return false
  const port = url.port ? Number(url.port) : url.protocol === 'https:' ? 443 : 80
  return localPort !== undefined && port === localPort
}

export async function applyUpdate(opts: { offline?: boolean; ref?: string }, deps: UpdateDeps): Promise<void> {
  if (opts.ref && !opts.offline) throw new Error('--ref only applies to the offline path — pass --offline')
  let root: string | undefined
  if (!opts.offline) {
    const target = deps.apiUrl()
    deps.log(`Updating ${target} via the API`)
    try {
      output(await apiPost('/api/updates/apply'))
      return
    } catch (error) {
      if (!isTransportError(error)) throw error
      // Fall back only when the unreachable API *is* the local checkout's instance.
      let localRoot: string | undefined
      try {
        localRoot = deps.resolveRoot()
      } catch {
        localRoot = undefined
      }
      if (!localRoot || !isLocalTarget(target, deps.localPort(localRoot))) {
        throw new Error(
          `${target} is unreachable (${(error as Error).message}). To update the checkout on this machine instead, run \`tau server update\` (or \`tau update apply --offline\`).`
        )
      }
      deps.log(`${target} is unreachable (${(error as Error).message}) — updating its checkout offline`)
      root = localRoot
    }
  }
  root ??= deps.resolveRoot()
  deps.log(`Updating the local checkout ${root} (offline)`)
  const result = await deps.offlineUpdate({ root, ref: opts.ref, log: deps.log })
  output(
    { ...result, root, offline: true },
    `Updated ${root}: ${result.before.slice(0, 9)} → ${result.after.slice(0, 9)}`
  )
}

export function registerUpdateCommands(program: Command, deps: UpdateDeps = defaultUpdateDeps()) {
  const update = program.command('update').description('Update this tau instance (API first, offline fallback)')
  update
    .command('check')
    .description('Check for updates (needs the API)')
    .action(async () => {
      try {
        output(await apiPost('/api/updates/check'))
      } catch (error) {
        outputError(error as Error)
      }
    })
  update
    .command('apply')
    .description('Apply updates via the API, or offline in the local checkout when the API is down')
    .option('--offline', 'Skip the API: git pull + build in the local checkout, then restart its recorded supervisor')
    .option('--ref <ref>', 'Offline only: check out this branch, tag, or commit instead of fast-forwarding')
    .action(async (opts: { offline?: boolean; ref?: string }) => {
      try {
        await applyUpdate(opts, deps)
      } catch (error) {
        outputError(error as Error)
      }
    })
  update
    .command('status')
    .description('Show the latest update run')
    .option('--offline', 'Read the local checkout status file instead of the API')
    .action(async (opts: { offline?: boolean }) => {
      try {
        if (!opts.offline) {
          try {
            output(await apiGet('/api/updates/status'))
            return
          } catch (error) {
            if (!isTransportError(error)) throw error
            deps.log('API unreachable — reading the local status file')
          }
        }
        const path = join(deps.resolveRoot(), '.tau', 'local-update-status.json')
        const latest = existsSync(path) ? JSON.parse(readFileSync(path, 'utf8')) : null
        output(
          { active: false, latest, source: path },
          latest ? `${latest.status} (${latest.mode}) ${latest.afterSha ?? ''}` : 'no update has run yet'
        )
      } catch (error) {
        outputError(error as Error)
      }
    })
  update
    .command('toggle <state>')
    .description('Turn local auto updates on or off (needs the API)')
    .action(async (state: string) => {
      try {
        if (!['on', 'off'].includes(state)) throw new Error('state must be on or off')
        output(await apiPatch('/api/updates/settings', { enabled: state === 'on' }))
      } catch (error) {
        outputError(error as Error)
      }
    })
}
