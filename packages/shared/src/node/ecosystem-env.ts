/**
 * The `ecosystem.config.js` half of the local-install env rename (Controller Ruling 28): only the
 * two keys the installer generates, `TAU_PM2_API_NAME:` and `TAU_PM2_WORKER_NAME:`, are renamed to
 * `FICUS_…`, and only on a line of exactly the generated shape
 *
 *     <indent>TAU_PM2_API_NAME: '<name>',
 *
 * (one key, a plain single- or double-quoted string with no escapes, a trailing comma, nothing
 * else). Only the key text changes; no line is ever added, dropped or merged. Every other `TAU_`
 * key in the file is left as it is: the in-process bridge reads them (and keeps TAU_ on an
 * encryption-key conflict). A PM2 name key in any other shape is left alone with a warning, and so
 * is one whose FICUS_ twin already exists with a different value; an identical twin means there is
 * nothing to do.
 */
import { ENV_PREFIX, LEGACY_ENV_PREFIX } from '../legacy-env'

const PM2_NAME_SUFFIXES = ['PM2_API_NAME', 'PM2_WORKER_NAME'] as const

/** The generated line: indentation, the key, `: `, one plain string literal, a comma. */
function simpleLine(prefix: string, suffix: string): RegExp {
  return new RegExp(`^(\\s*)${prefix}${suffix}(\\s*:\\s*)('[^'\\\\\\n]*'|"[^"\\\\\\n]*")(\\s*,\\s*)$`)
}

/** A line that mentions the key outside a `//` comment. */
function mentions(line: string, key: string): boolean {
  const code = line.trimStart().startsWith('//') || line.trimStart().startsWith('*') ? '' : line
  return new RegExp(`\\b${key}\\b`).test(code)
}

export interface EcosystemRename {
  content: string
  /** One line per key left unrenamed on purpose, naming the key (never a value). */
  warnings: string[]
}

export function renameEcosystemPm2Names(text: string): EcosystemRename {
  const lines = text.split('\n')
  const bodies = lines.map((line) => (line.endsWith('\r') ? line.slice(0, -1) : line))
  const warnings: string[] = []
  const renameAt = new Set<number>()

  for (const suffix of PM2_NAME_SUFFIXES) {
    const legacy = `${LEGACY_ENV_PREFIX}${suffix}`
    const current = `${ENV_PREFIX}${suffix}`
    const legacyLines = bodies.flatMap((body, index) => (mentions(body, legacy) ? [index] : []))
    if (legacyLines.length === 0) continue
    const simple = legacyLines.filter((index) => simpleLine(LEGACY_ENV_PREFIX, suffix).test(bodies[index]))
    if (simple.length !== legacyLines.length || simple.length > 1) {
      warnings.push(
        `${legacy} in ecosystem.config.js was not renamed to ${current}: it is not a single \`${legacy}: '<name>',\` line; rename it by hand`
      )
      continue
    }
    const twins = bodies.flatMap((body, index) => (mentions(body, current) ? [index] : []))
    if (twins.length === 0) {
      renameAt.add(simple[0])
      continue
    }
    const value = (index: number, prefix: string) => simpleLine(prefix, suffix).exec(bodies[index])?.[3].slice(1, -1)
    const legacyValue = value(simple[0], LEGACY_ENV_PREFIX)
    const same = twins.every((index) => value(index, ENV_PREFIX) === legacyValue)
    if (!same) {
      warnings.push(
        `${legacy} and ${current} in ecosystem.config.js name different processes (or ${current} is not a plain \`${current}: '<name>',\` line); both were left as they are — remove the wrong one`
      )
    }
  }

  if (renameAt.size === 0) return { content: text, warnings }
  const content = lines
    .map((line, index) => (renameAt.has(index) ? line.replace(LEGACY_ENV_PREFIX, ENV_PREFIX) : line))
    .join('\n')
  return { content, warnings }
}
