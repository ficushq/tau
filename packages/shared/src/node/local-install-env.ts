/**
 * Local-install env hard rename (Tau → Ficus): the CLI's `server setup` / `start` / `restart` /
 * `update` and Core's local updater rewrite a local install's `TAU_*` settings to `FICUS_*` once,
 * with byte-for-byte backups. Host installs are renamed by the setup toolkit instead.
 *
 * Nothing here ever logs or throws a value: errors carry key names and file paths only.
 */
import { randomBytes } from 'crypto'
import {
  chmodSync,
  closeSync,
  existsSync,
  fsyncSync,
  openSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  statSync,
  writeSync,
} from 'fs'
import { basename, dirname, join } from 'path'
import { ENV_PREFIX, EnvPrefixConflictError, LEGACY_ENV_PREFIX, renameEnvPrefix, type EnvPrefix } from '../legacy-env'

/** The files of a local install that carry env names: the dotenv file and the pm2 ecosystem. */
export const LOCAL_INSTALL_ENV_FILES = ['.env', 'ecosystem.config.js'] as const

const BACKUP_MARKER = '.pre-ficus-'

export interface LocalInstallEnvMigration {
  /** The files rewritten, in LOCAL_INSTALL_ENV_FILES order (a symlink's target, not the link). */
  renamed: string[]
  /** One byte-for-byte backup per rewritten file, same order; pass them to restoreLocalInstallEnv. */
  backups: string[]
}

export interface LocalInstallEnvChange {
  /** The file that would be rewritten (a symlink's target, not the link). */
  path: string
  /** Its text after the rename. */
  content: string
}

/** A protected TAU_/FICUS_ conflict in one file of a local install. The message names the file and the keys. */
export class LocalInstallEnvConflictError extends EnvPrefixConflictError {
  readonly file: string

  constructor(file: string, keys: string[]) {
    super(keys)
    this.name = 'LocalInstallEnvConflictError'
    this.file = file
    this.message = `${file}: ${this.message}`
  }
}

/**
 * The env prefix a checkout's code reads, from its root `package.json` name: `ficus` → FICUS_,
 * `tau` (a checkout that predates the rename) → TAU_, anything else or unreadable → null. The same
 * direction key the setup toolkit uses for git checkouts.
 */
export function checkoutEnvPrefix(root: string): EnvPrefix | null {
  try {
    const name = (JSON.parse(readFileSync(join(root, 'package.json'), 'utf8')) as { name?: unknown }).name
    if (name === 'ficus') return ENV_PREFIX
    if (name === 'tau') return LEGACY_ENV_PREFIX
    return null
  } catch {
    return null
  }
}

/**
 * Rename the `TAU_X:` env keys of a pm2 ecosystem file to `FICUS_X:`. Only object keys move (one per
 * line, optionally quoted or commented out, as the example file writes them); values, such as the
 * pm2 process names, are never touched.
 */
export function renameEcosystemEnvKeys(text: string): string {
  return text.replace(
    /^(\s*(?:\/\/\s*)?['"]?)TAU_([A-Z0-9_]+)(['"]?\s*:)/gm,
    (_match, lead: string, suffix: string, tail: string) => `${lead}${ENV_PREFIX}${suffix}${tail}`
  )
}

function renameFile(name: string, path: string, text: string): string {
  if (name === '.env') {
    try {
      return renameEnvPrefix(text, LEGACY_ENV_PREFIX, ENV_PREFIX).content
    } catch (error) {
      if (error instanceof EnvPrefixConflictError) throw new LocalInstallEnvConflictError(path, error.keys)
      throw error
    }
  }
  return renameEcosystemEnvKeys(text)
}

/**
 * What migrateLocalInstallEnv would rewrite, computed for every file before anything is written.
 * Pure: reads only. Throws LocalInstallEnvConflictError on a protected conflict (Ruling 24).
 */
export function planLocalInstallEnvMigration(root: string): LocalInstallEnvChange[] {
  const changes: LocalInstallEnvChange[] = []
  for (const name of LOCAL_INSTALL_ENV_FILES) {
    const link = join(root, name)
    if (!existsSync(link)) continue
    // A symlinked file keeps its link: the target is what gets rewritten.
    const path = realpathSync(link)
    const text = readFileSync(path, 'utf8')
    const content = renameFile(name, link, text)
    if (content !== text) changes.push({ path, content })
  }
  return changes
}

/** `2026-09-26T10:15:00.123Z` → `20260926T101500Z`. */
function utcStamp(now: Date): string {
  return now
    .toISOString()
    .replace(/\.\d+Z$/, 'Z')
    .replace(/[-:]/g, '')
}

/** Write `data` to a new file created with `mode` (never replacing one), synced to disk. */
function writeNewFile(path: string, data: Buffer | string, mode: number): void {
  const fd = openSync(path, 'wx', mode)
  try {
    const bytes = typeof data === 'string' ? Buffer.from(data, 'utf8') : data
    let offset = 0
    while (offset < bytes.length) offset += writeSync(fd, bytes, offset, bytes.length - offset)
    fsyncSync(fd)
  } finally {
    closeSync(fd)
  }
  // openSync's mode is filtered through the umask.
  chmodSync(path, mode)
}

/** Replace `path` atomically: a temp file in the same directory, then rename over it. */
function replaceAtomically(path: string, data: Buffer | string, mode: number): void {
  const temp = join(dirname(path), `.${basename(path)}.ficus-tmp-${process.pid}-${randomBytes(4).toString('hex')}`)
  try {
    writeNewFile(temp, data, mode)
    renameSync(temp, path)
  } catch (error) {
    rmSync(temp, { force: true })
    throw error
  }
}

/** Copy `path` byte-for-byte to `<path>.pre-ficus-<stamp>` (or `-1`, `-2`, … if taken), same mode. */
function backUp(path: string, stamp: string): string {
  const bytes = readFileSync(path)
  const mode = statSync(path).mode & 0o7777
  for (let attempt = 0; ; attempt++) {
    const backup = `${path}${BACKUP_MARKER}${stamp}${attempt === 0 ? '' : `-${attempt}`}`
    try {
      writeNewFile(backup, bytes, mode)
      return backup
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error
    }
  }
}

/**
 * Hard-rename a local install's `<root>/.env` and `<root>/ecosystem.config.js` from TAU_ to FICUS_.
 *
 * Every file's rename is computed before anything is written, so a protected conflict
 * (LocalInstallEnvConflictError, an EnvPrefixConflictError) leaves every file untouched with no
 * backup. Each changed file is then copied byte-for-byte to `<file>.pre-ficus-<UTC stamp>` with its
 * mode, and replaced atomically (temp file in the same directory, then rename), keeping its mode.
 * If a replace fails, the files already replaced are restored before the error propagates.
 * Idempotent: with nothing to rename it returns `{ renamed: [], backups: [] }` and writes nothing.
 */
export async function migrateLocalInstallEnv(root: string, now: Date = new Date()): Promise<LocalInstallEnvMigration> {
  const changes = planLocalInstallEnvMigration(root)
  const result: LocalInstallEnvMigration = { renamed: [], backups: [] }
  if (changes.length === 0) return result
  const stamp = utcStamp(now)
  const backups = changes.map((change) => backUp(change.path, stamp))
  try {
    for (const [index, change] of changes.entries()) {
      replaceAtomically(change.path, change.content, statSync(backups[index]).mode & 0o7777)
      result.renamed.push(change.path)
      result.backups.push(backups[index])
    }
  } catch (error) {
    await restoreLocalInstallEnv(result.backups)
    throw error
  }
  return result
}

/**
 * Put back the files migrateLocalInstallEnv rewrote, byte-for-byte with their modes, from its
 * backups (each `<file>.pre-ficus-<stamp>` restores `<file>`). Atomic per file. The backups stay.
 */
export async function restoreLocalInstallEnv(backups: string[]): Promise<void> {
  for (const backup of backups) {
    const name = basename(backup)
    const at = name.lastIndexOf(BACKUP_MARKER)
    if (at <= 0) throw new Error(`${backup} is not a ${BACKUP_MARKER} backup`)
    const original = join(dirname(backup), name.slice(0, at))
    replaceAtomically(original, readFileSync(backup), statSync(backup).mode & 0o7777)
  }
}
