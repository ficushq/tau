import { realpathSync } from 'fs'
import { basename, relative } from 'path'
import { ENV_PREFIX, LEGACY_ENV_PREFIX, renameEnvPrefix } from '@ficus/shared/legacy-env'
import {
  checkoutEnvPrefix,
  migrateLocalInstallEnv,
  planLocalInstallEnvMigration,
  type LocalInstallEnvMigration,
} from '@ficus/shared/node'

/*
 * Ficus rename: a local install's `.env` and `ecosystem.config.js` are hard-renamed TAU_ → FICUS_
 * (with byte-for-byte `.pre-ficus-<UTC>` backups) by `server setup`, `start`, `restart` and
 * `update`, before any process starts and before setup merges its own FICUS_ keys into `.env`.
 * The implementation is shared with Core's local updater (`@ficus/shared/node`).
 */
export {
  checkoutEnvPrefix,
  LocalInstallEnvConflictError,
  migrateLocalInstallEnv,
  planLocalInstallEnvMigration,
  renameEcosystemEnvKeys,
  restoreLocalInstallEnv,
  type LocalInstallEnvMigration,
} from '@ficus/shared/node'

/**
 * A checkout whose code predates the rename (root package.json named `tau`) reads TAU_ only:
 * renaming its files would break it. Every other checkout is renamed.
 */
export function checkoutPredatesRename(root: string): boolean {
  return checkoutEnvPrefix(root) === LEGACY_ENV_PREFIX
}

/**
 * Rename `root`'s install files unless the checkout predates the rename, and say what moved.
 * A protected TAU_/FICUS_ conflict rejects with LocalInstallEnvConflictError (an
 * EnvPrefixConflictError) naming the file and keys, never a value, with nothing written.
 */
export async function migrateCheckoutEnv(
  root: string,
  options: { log?: (line: string) => void; now?: Date } = {}
): Promise<LocalInstallEnvMigration> {
  if (checkoutPredatesRename(root)) return { renamed: [], backups: [] }
  const result = await migrateLocalInstallEnv(root, options.now)
  if (result.renamed.length > 0) {
    const files = result.renamed.map((path) => basename(path)).join(' and ')
    // Backups sit next to the real files: relative to the real root (macOS /var is /private/var).
    const base = realpathSync(root)
    const backups = result.backups.map((path) => relative(base, path)).join(', ')
    options.log?.(
      `Renamed TAU_ settings to FICUS_ in ${files} (backup${result.backups.length > 1 ? 's' : ''}: ${backups})`
    )
  }
  return result
}

/**
 * Throws the conflict a later rename would hit, before anything is changed. Checked whatever the
 * checkout's code is today: an update moves a checkout that predates the rename onto code that
 * renames, so its conflict has to be settled first too.
 */
export function assertCheckoutEnvRenamable(root: string): void {
  planLocalInstallEnvMigration(root)
}

/** The plan line for a rename setup would make, or null when there is nothing to rename. */
export function checkoutEnvRenamePlan(root: string): string | null {
  if (checkoutPredatesRename(root)) return null
  const files = planLocalInstallEnvMigration(root).map((change) => basename(change.path))
  if (files.length === 0) return null
  return `rename TAU_ settings to FICUS_ in ${files.join(' and ')} (byte-for-byte backup${files.length > 1 ? 's' : ''} ${files.map((file) => `${file}.pre-ficus-<UTC time>`).join(', ')})`
}

/** `.env` text as it will read after the rename, for planning; unchanged when it cannot be renamed. */
export function renamedEnvPreview(root: string, text: string): string {
  if (checkoutPredatesRename(root)) return text
  try {
    return renameEnvPrefix(text, LEGACY_ENV_PREFIX, ENV_PREFIX).content
  } catch {
    return text
  }
}
