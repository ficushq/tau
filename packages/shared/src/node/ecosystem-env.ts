/**
 * The pm2 `ecosystem.config.js` half of the local-install env rename: `TAU_X:` object keys become
 * `FICUS_X:` under the same rules `renameEnvPrefix` applies to a dotenv file, per object (each app's
 * `env: { … }` is its own scope):
 *
 * - a TAU_X with no FICUS_X in its object is renamed in place;
 * - a TAU_X beside a FICUS_X with the identical value is dropped;
 * - a differing value for a protected suffix (`*ENCRYPTION_KEY*`, `*PASSWORD*`) throws
 *   EnvPrefixConflictError (names only) before anything is returned;
 * - a differing unprotected value keeps FICUS_X and drops TAU_X (FICUS_ is what the process reads).
 *
 * A commented-out `// TAU_X:` line is renamed only when its object has no FICUS_X, live or
 * commented; it never takes part in a conflict. Only one key per line, at the start of the line,
 * is recognised: a one-line object (`env: { TAU_X: 1 }`) is left as it is. The file is scanned with
 * a small tokenizer (strings, comments, brackets); anything it cannot follow, or a duplicate it
 * cannot resolve line by line, throws EcosystemEnvRenameError rather than guessing.
 */
import { ENV_PREFIX, EnvPrefixConflictError, isProtectedEnvSuffix, LEGACY_ENV_PREFIX } from '../legacy-env'

/** The ecosystem file cannot be renamed safely by machine. The message names no value. */
export class EcosystemEnvRenameError extends Error {
  constructor(reason: string) {
    super(`${reason}; rename its TAU_ keys to FICUS_ by hand, then re-run`)
    this.name = 'EcosystemEnvRenameError'
  }
}

interface LineScan {
  /** The line starts outside any string or block comment. */
  startsInCode: boolean
  /** The id of the innermost open `{` at the start of the line, or -1. */
  object: number
  /** The innermost open bracket at the start of the line is a `{`. */
  inObject: boolean
  /** The line opens nothing it does not close, closes nothing it did not open, and ends in code. */
  selfContained: boolean
  /** Where a trailing `//` comment starts (the line's length when there is none). */
  codeEnd: number
}

const CLOSERS: Record<string, string> = { '{': '}', '[': ']', '(': ')' }

/** Follow strings, comments and brackets line by line; null when the text does not balance. */
function scan(lines: string[]): LineScan[] | null {
  const stack: { open: string; id: number }[] = []
  let nextId = 0
  let mode: 'code' | 'block' | "'" | '"' | '`' = 'code'
  const scans: LineScan[] = []
  for (const line of lines) {
    const top = stack.at(-1)
    let object = -1
    for (let index = stack.length - 1; index >= 0; index--) {
      if (stack[index].open === '{') {
        object = stack[index].id
        break
      }
    }
    const startDepth = stack.length
    const startsInCode = mode === 'code'
    let minDepth = startDepth
    let codeEnd = line.length
    for (let index = 0; index < line.length; index++) {
      const char = line[index]
      if (mode === 'block') {
        if (char === '*' && line[index + 1] === '/') {
          mode = 'code'
          index++
        }
        continue
      }
      if (mode !== 'code') {
        if (char === '\\') index++
        else if (char === mode) mode = 'code'
        continue
      }
      if (char === '/' && line[index + 1] === '/') {
        codeEnd = index
        break
      }
      if (char === '/' && line[index + 1] === '*') {
        mode = 'block'
        index++
      } else if (char === "'" || char === '"' || char === '`') {
        mode = char
      } else if (char in CLOSERS) {
        stack.push({ open: char, id: nextId++ })
      } else if (char === '}' || char === ']' || char === ')') {
        const open = stack.pop()
        if (!open || CLOSERS[open.open] !== char) return null
        minDepth = Math.min(minDepth, stack.length)
      }
    }
    // Only a template literal or a block comment may span lines.
    if (mode === "'" || mode === '"') return null
    scans.push({
      startsInCode,
      object,
      inObject: top?.open === '{',
      selfContained: startsInCode && mode === 'code' && stack.length === startDepth && minDepth === startDepth,
      codeEnd,
    })
  }
  return mode === 'code' && stack.length === 0 ? scans : null
}

/** `  // 'TAU_X': value,` → lead, comment marker, quote, prefix, suffix, and where the value starts. */
const KEY_LINE = /^(\s*)(\/\/\s*)?(['"]?)(TAU|FICUS)_([A-Z0-9_]+)\3\s*:/

interface KeyLine {
  index: number
  object: number
  prefix: 'TAU_' | 'FICUS_'
  suffix: string
  commented: boolean
  /** Offset of `TAU_` / `FICUS_` in the line. */
  keyAt: number
  /** The value as written (trailing comma and comment removed), for comparing two keys. */
  value: string
  selfContained: boolean
}

/** A value as JS reads it, for comparing two keys: one level of simple quotes removed. */
function normalizedValue(raw: string): string {
  const value = raw.trim().replace(/,$/, '').trim()
  const quote = value[0]
  if ((quote === "'" || quote === '"') && value.length >= 2 && value.endsWith(quote)) {
    const inner = value.slice(1, -1)
    if (!inner.includes(quote) && !inner.includes('\\')) return inner
  }
  return value
}

export function renameEcosystemEnvKeys(text: string): string {
  const lines = text.split('\n')
  const bodies = lines.map((line) => (line.endsWith('\r') ? line.slice(0, -1) : line))
  if (!bodies.some((body) => KEY_LINE.exec(body)?.[4] === 'TAU')) return text

  const scans = scan(bodies)
  if (!scans) throw new EcosystemEnvRenameError('its quotes, comments or brackets do not balance')

  const keys: KeyLine[] = []
  for (const [index, body] of bodies.entries()) {
    const match = KEY_LINE.exec(body)
    const info = scans[index]
    if (!match || !info.startsInCode || !info.inObject) continue
    const keyAt = match[1].length + (match[2]?.length ?? 0) + match[3].length
    const commented = match[2] !== undefined
    keys.push({
      index,
      object: info.object,
      prefix: match[4] === 'TAU' ? LEGACY_ENV_PREFIX : ENV_PREFIX,
      suffix: match[5],
      commented,
      keyAt,
      value: commented ? '' : normalizedValue(body.slice(match[0].length, info.codeEnd)),
      selfContained: info.selfContained,
    })
  }

  const drop = new Set<number>()
  const rename = new Set<number>()
  const conflicts: string[] = []
  for (const key of keys) {
    if (key.prefix !== LEGACY_ENV_PREFIX) continue
    const twins = keys.filter(
      (other) => other.object === key.object && other.prefix === ENV_PREFIX && other.suffix === key.suffix
    )
    const name = `${LEGACY_ENV_PREFIX}${key.suffix}`
    if (key.commented) {
      if (twins.length === 0) rename.add(key.index)
      continue
    }
    // JS keeps the last assignment of a key: that is the FICUS_ value the process reads.
    const target = twins.filter((twin) => !twin.commented).at(-1)
    if (!target) {
      rename.add(key.index)
      continue
    }
    const comparable = key.selfContained && target.selfContained
    if (comparable && key.value === target.value) {
      drop.add(key.index)
    } else if (isProtectedEnvSuffix(key.suffix)) {
      if (!conflicts.includes(name)) conflicts.push(name)
    } else if (key.selfContained) {
      drop.add(key.index)
    } else {
      throw new EcosystemEnvRenameError(`${name} spans several lines next to ${ENV_PREFIX}${key.suffix}`)
    }
  }
  if (conflicts.length > 0) throw new EnvPrefixConflictError(conflicts)

  const out: string[] = []
  for (const [index, line] of lines.entries()) {
    if (drop.has(index)) continue
    if (!rename.has(index)) {
      out.push(line)
      continue
    }
    const key = keys.find((candidate) => candidate.index === index)!
    out.push(`${line.slice(0, key.keyAt)}${ENV_PREFIX}${line.slice(key.keyAt + LEGACY_ENV_PREFIX.length)}`)
  }
  return out.join('\n')
}
