import { realpathSync } from 'fs'
import { basename, relative } from 'path'
import { ENV_PREFIX, LEGACY_ENV_PREFIX, renameEnvPrefix } from '@ficus/shared/legacy-env'
import {
  checkoutEnvPrefix,
  checkoutPackageName,
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
  rejectAfterRestoring,
  renameEcosystemPm2Names,
  restoreLocalInstallEnv,
  type LocalInstallEnvMigration,
} from '@ficus/shared/node'

/**
 * Whether `root`'s code reads FICUS_: its root package.json is named exactly `ficus`. Fail closed:
 * a checkout that predates the rename (`tau`) reads TAU_ only, and one whose name is anything else
 * or cannot be read is never renamed.
 */
export function checkoutReadsFicusEnv(root: string): boolean {
  return checkoutEnvPrefix(root) === ENV_PREFIX
}

/** "is named "x"" / "could not be read", for messages about a checkout's package.json. */
export function describeCheckoutPackage(root: string): string {
  const name = checkoutPackageName(root)
  return name === null ? 'could not be read' : `is named ${JSON.stringify(name)}`
}

/** Whether the install's files still carry TAU_ keys a rename would move (a conflict counts). */
function hasLegacyKeys(root: string): boolean {
  try {
    return planLocalInstallEnvMigration(root).length > 0
  } catch {
    return true
  }
}

/** A checkout rename: what moved, and the warnings (also logged) about what deliberately did not. */
export interface CheckoutEnvMigration extends LocalInstallEnvMigration {
  warnings: string[]
}

/**
 * Rename `root`'s install files when its code reads FICUS_, and say what moved. A checkout that
 * predates the rename is left alone silently (its code reads TAU_); one whose package name is
 * unknown is left alone with a warning, because its TAU_ settings then stay unrenamed.
 * A protected TAU_/FICUS_ conflict rejects with LocalInstallEnvConflictError (an
 * EnvPrefixConflictError) naming the file and keys, never a value, with nothing written.
 */
export async function migrateCheckoutEnv(
  root: string,
  options: { log?: (line: string) => void; now?: Date } = {}
): Promise<CheckoutEnvMigration> {
  const warnings: string[] = []
  const warn = (line: string) => {
    warnings.push(line)
    options.log?.(`warning: ${line}`)
  }
  if (!checkoutReadsFicusEnv(root)) {
    if (checkoutEnvPrefix(root) !== LEGACY_ENV_PREFIX && hasLegacyKeys(root)) {
      warn(
        `TAU_ settings in ${root} were not renamed to FICUS_: its package.json ${describeCheckoutPackage(root)}, not "ficus"`
      )
    }
    return { renamed: [], backups: [], warnings }
  }
  const result = await migrateLocalInstallEnv(root, options.now, { warn })
  if (result.renamed.length > 0) {
    const files = result.renamed.map((path) => basename(path)).join(' and ')
    // Backups sit next to the real files: relative to the real root (macOS /var is /private/var).
    const base = realpathSync(root)
    const backups = result.backups.map((path) => relative(base, path)).join(', ')
    options.log?.(
      `Renamed TAU_ settings to FICUS_ in ${files} (backup${result.backups.length > 1 ? 's' : ''}: ${backups})`
    )
  }
  return { ...result, warnings }
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
  if (!checkoutReadsFicusEnv(root)) return null
  const files = planLocalInstallEnvMigration(root).map((change) => basename(change.path))
  if (files.length === 0) return null
  return `rename TAU_ settings to FICUS_ in ${files.join(' and ')} (byte-for-byte backup${files.length > 1 ? 's' : ''} ${files.map((file) => `${file}.pre-ficus-<UTC time>`).join(', ')})`
}

/** `.env` text as it will read after the rename, for planning; unchanged when it cannot be renamed. */
export function renamedEnvPreview(root: string, text: string): string {
  if (!checkoutReadsFicusEnv(root)) return text
  try {
    return renameEnvPrefix(text, LEGACY_ENV_PREFIX, ENV_PREFIX).content
  } catch {
    return text
  }
}
