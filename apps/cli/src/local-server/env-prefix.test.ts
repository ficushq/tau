import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import {
  chmodSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { EnvPrefixConflictError } from '@ficus/shared/legacy-env'
import {
  checkoutEnvPrefix,
  migrateCheckoutEnv,
  migrateLocalInstallEnv,
  planLocalInstallEnvMigration,
  rejectAfterRestoring,
  renameEcosystemPm2Names,
  restoreLocalInstallEnv,
} from './env-prefix'
import { generateEcosystem, instanceNames } from './instance'
import { defaultRunner } from './runner'

// The default instance's pm2 names ('tau-' + api/worker): phase-5 identity, unchanged by this rename.
const { api: API, worker: WORKER } = instanceNames('tau')
const KEY = 'ab'.repeat(32)
const ENV = `TAU_ENCRYPTION_KEY=${KEY}\nTAU_SANDBOX_RUNTIME=host\n`
const ECOSYSTEM = [
  'module.exports = {',
  '  apps: [',
  '    {',
  `      name: '${API}',`,
  '      env: {',
  "        // TAU_SERVE_WEB: '1',",
  "        TAU_SYSTEM_LOG_PROVIDER: 'pm2',",
  `        TAU_PM2_API_NAME: '${API}',`,
  `        TAU_PM2_WORKER_NAME: '${WORKER}',`,
  '      },',
  '    },',
  '  ],',
  '}',
  '',
].join('\n')
const NOW = new Date('2026-09-26T10:15:00.123Z')
const STAMP = '20260926T101500Z'

let root: string
beforeEach(() => {
  root = realpathSync(mkdtempSync(join(tmpdir(), 'ficus-env-prefix-')))
})
afterEach(() => {
  rmSync(root, { recursive: true, force: true })
})

const read = (name: string) => readFileSync(join(root, name))
const backupsIn = (dir = root) => readdirSync(dir).filter((name) => name.includes('.pre-ficus-'))

describe('migrateLocalInstallEnv', () => {
  it('renames .env and the ecosystem PM2 name keys to FICUS_, keeping every value and byte-identical backups', async () => {
    writeFileSync(join(root, '.env'), ENV)
    writeFileSync(join(root, 'ecosystem.config.js'), ECOSYSTEM)
    chmodSync(join(root, '.env'), 0o600)
    chmodSync(join(root, 'ecosystem.config.js'), 0o644)

    const result = await migrateLocalInstallEnv(root, NOW)

    expect(read('.env').toString()).toBe(`FICUS_ENCRYPTION_KEY=${KEY}\nFICUS_SANDBOX_RUNTIME=host\n`)
    const ecosystem = read('ecosystem.config.js').toString()
    expect(ecosystem).toContain(`        FICUS_PM2_API_NAME: '${API}',\n`)
    expect(ecosystem).toContain(`        FICUS_PM2_WORKER_NAME: '${WORKER}',\n`)
    // Ruling 28: only the generated PM2 name keys move; the bridge reads the rest.
    expect(ecosystem).toBe(
      ECOSYSTEM.replace('TAU_PM2_API_NAME', 'FICUS_PM2_API_NAME').replace(
        'TAU_PM2_WORKER_NAME',
        'FICUS_PM2_WORKER_NAME'
      )
    )
    // The process names are phase-5 identity: only the keys move.
    expect(ecosystem).toContain(`      name: '${API}',\n`)

    expect(result.renamed).toEqual([join(root, '.env'), join(root, 'ecosystem.config.js')])
    expect(result.backups).toEqual([
      join(root, `.env.pre-ficus-${STAMP}`),
      join(root, `ecosystem.config.js.pre-ficus-${STAMP}`),
    ])
    expect(backupsIn().sort()).toEqual([`.env.pre-ficus-${STAMP}`, `ecosystem.config.js.pre-ficus-${STAMP}`])
    expect(read(`.env.pre-ficus-${STAMP}`).equals(Buffer.from(ENV))).toBe(true)
    expect(read(`ecosystem.config.js.pre-ficus-${STAMP}`).equals(Buffer.from(ECOSYSTEM))).toBe(true)
  })

  it('keeps each file mode on the rewritten file and on its backup, and leaves no temp file behind', async () => {
    writeFileSync(join(root, '.env'), ENV)
    writeFileSync(join(root, 'ecosystem.config.js'), ECOSYSTEM)
    chmodSync(join(root, '.env'), 0o600)
    chmodSync(join(root, 'ecosystem.config.js'), 0o640)

    await migrateLocalInstallEnv(root, NOW)

    const mode = (name: string) => statSync(join(root, name)).mode & 0o777
    expect(mode('.env')).toBe(0o600)
    expect(mode(`.env.pre-ficus-${STAMP}`)).toBe(0o600)
    expect(mode('ecosystem.config.js')).toBe(0o640)
    expect(mode(`ecosystem.config.js.pre-ficus-${STAMP}`)).toBe(0o640)
    expect(readdirSync(root).sort()).toEqual([
      '.env',
      `.env.pre-ficus-${STAMP}`,
      'ecosystem.config.js',
      `ecosystem.config.js.pre-ficus-${STAMP}`,
    ])
  })

  it('is idempotent: a second run renames nothing and takes no backup', async () => {
    writeFileSync(join(root, '.env'), ENV)
    writeFileSync(join(root, 'ecosystem.config.js'), ECOSYSTEM)
    await migrateLocalInstallEnv(root, NOW)
    const env = read('.env')
    const ecosystem = read('ecosystem.config.js')

    expect(await migrateLocalInstallEnv(root, new Date('2026-09-26T11:00:00Z'))).toEqual({ renamed: [], backups: [] })
    expect(read('.env').equals(env)).toBe(true)
    expect(read('ecosystem.config.js').equals(ecosystem)).toBe(true)
    expect(backupsIn()).toHaveLength(2)
  })

  it('is a no-op on an install that has no TAU_ line, or no files at all', async () => {
    expect(await migrateLocalInstallEnv(root, NOW)).toEqual({ renamed: [], backups: [] })
    writeFileSync(join(root, '.env'), 'FICUS_PASSWORD=p\nPORT=3000\n')
    expect(await migrateLocalInstallEnv(root, NOW)).toEqual({ renamed: [], backups: [] })
    expect(readdirSync(root)).toEqual(['.env'])
  })

  it('refuses conflicting protected values before any backup or write, naming the keys and never the values', async () => {
    const env = 'TAU_ENCRYPTION_KEY=a\nFICUS_ENCRYPTION_KEY=b\n'
    writeFileSync(join(root, '.env'), env)
    writeFileSync(join(root, 'ecosystem.config.js'), ECOSYSTEM)

    const error = await migrateLocalInstallEnv(root, NOW).then(
      () => null,
      (e: unknown) => e
    )
    expect(error).toBeInstanceOf(EnvPrefixConflictError)
    expect((error as EnvPrefixConflictError).keys).toEqual(['TAU_ENCRYPTION_KEY'])
    const message = (error as Error).message
    expect(message).toContain(join(root, '.env'))
    expect(message).toContain('TAU_ENCRYPTION_KEY')
    expect(message).toContain('remove the wrong value, then re-run')

    expect(read('.env').equals(Buffer.from(env))).toBe(true)
    expect(read('ecosystem.config.js').equals(Buffer.from(ECOSYSTEM))).toBe(true)
    expect(backupsIn()).toEqual([])
  })

  it('names every conflicting key and neither value', async () => {
    writeFileSync(join(root, '.env'), 'TAU_PASSWORD=secret-one\nFICUS_PASSWORD=secret-two\nTAU_PORT_X=1\n')
    const error = (await migrateLocalInstallEnv(root, NOW).catch((e: unknown) => e)) as EnvPrefixConflictError
    expect(error.keys).toEqual(['TAU_PASSWORD'])
    expect(error.message).not.toContain('secret-one')
    expect(error.message).not.toContain('secret-two')
    expect(read('.env').toString()).toBe('TAU_PASSWORD=secret-one\nFICUS_PASSWORD=secret-two\nTAU_PORT_X=1\n')
  })

  it('de-duplicates identical protected values silently', async () => {
    writeFileSync(join(root, '.env'), 'TAU_PASSWORD=same\nFICUS_PASSWORD=same\n')
    const result = await migrateLocalInstallEnv(root, NOW)
    expect(read('.env').toString()).toBe('FICUS_PASSWORD=same\n')
    expect(result.renamed).toEqual([join(root, '.env')])
    expect(result.backups).toEqual([join(root, `.env.pre-ficus-${STAMP}`)])
  })

  it('keeps CRLF line endings and never rewrites a TAU_ line inside a multi-line value', async () => {
    const env = 'TAU_SANDBOX_RUNTIME=host\r\nTAU_KEY_PEM="-----BEGIN-----\r\nTAU_INNER=1\r\n-----END-----"\r\n'
    writeFileSync(join(root, '.env'), env)
    await migrateLocalInstallEnv(root, NOW)
    expect(read('.env').toString()).toBe(
      'FICUS_SANDBOX_RUNTIME=host\r\nFICUS_KEY_PEM="-----BEGIN-----\r\nTAU_INNER=1\r\n-----END-----"\r\n'
    )
  })

  it('rewrites the target of a symlinked .env and keeps the link', async () => {
    mkdirSync(join(root, 'real'))
    writeFileSync(join(root, 'real', 'env'), ENV)
    symlinkSync(join(root, 'real', 'env'), join(root, '.env'))

    const result = await migrateLocalInstallEnv(root, NOW)

    expect(lstatSync(join(root, '.env')).isSymbolicLink()).toBe(true)
    expect(readFileSync(join(root, 'real', 'env'), 'utf8')).toBe(
      `FICUS_ENCRYPTION_KEY=${KEY}\nFICUS_SANDBOX_RUNTIME=host\n`
    )
    expect(result.backups).toEqual([join(root, 'real', `env.pre-ficus-${STAMP}`)])
    expect(readFileSync(result.backups[0], 'utf8')).toBe(ENV)
  })

  it('never overwrites an existing backup of the same second', async () => {
    writeFileSync(join(root, '.env'), ENV)
    writeFileSync(join(root, `.env.pre-ficus-${STAMP}`), 'older backup\n')
    const result = await migrateLocalInstallEnv(root, NOW)
    expect(result.backups).toEqual([join(root, `.env.pre-ficus-${STAMP}-1`)])
    expect(read(`.env.pre-ficus-${STAMP}`).toString()).toBe('older backup\n')
    expect(read(`.env.pre-ficus-${STAMP}-1`).toString()).toBe(ENV)
  })
})

describe('restoreLocalInstallEnv', () => {
  it('puts every file back byte-for-byte with its mode', async () => {
    writeFileSync(join(root, '.env'), ENV)
    writeFileSync(join(root, 'ecosystem.config.js'), ECOSYSTEM)
    chmodSync(join(root, '.env'), 0o600)
    const { backups } = await migrateLocalInstallEnv(root, NOW)

    await restoreLocalInstallEnv(backups)

    expect(read('.env').equals(Buffer.from(ENV))).toBe(true)
    expect(read('ecosystem.config.js').equals(Buffer.from(ECOSYSTEM))).toBe(true)
    expect(statSync(join(root, '.env')).mode & 0o777).toBe(0o600)
  })

  it('does nothing for an empty list', async () => {
    await restoreLocalInstallEnv([])
  })

  it('rejects a path that is not a pre-ficus backup', async () => {
    writeFileSync(join(root, '.env'), ENV)
    await expect(restoreLocalInstallEnv([join(root, '.env')])).rejects.toThrow('not a .pre-ficus- backup')
    expect(read('.env').toString()).toBe(ENV)
  })
})

describe('planLocalInstallEnvMigration', () => {
  it('lists only the files that would change, with their new text, and writes nothing', () => {
    writeFileSync(join(root, '.env'), ENV)
    writeFileSync(join(root, 'ecosystem.config.js'), `FICUS_PM2_API_NAME: '${API}',\n`)
    const plan = planLocalInstallEnvMigration(root)
    expect(plan).toEqual([
      {
        path: join(root, '.env'),
        content: `FICUS_ENCRYPTION_KEY=${KEY}\nFICUS_SANDBOX_RUNTIME=host\n`,
      },
    ])
    expect(read('.env').toString()).toBe(ENV)
  })
})

// Controller Ruling 28: only the two generated PM2 name lines are renamed, and only in their
// generated shape. Every other TAU_ key is left to the in-process bridge, and no line is ever
// added, dropped or merged, so the file is byte-identical apart from those lines.
describe('renameEcosystemPm2Names', () => {
  /** The reviewer's probe wrapper: one app whose env body is `body`. */
  const wrap = (body: string, crlf = false) => {
    const text = `const KEY = 'from-var'\nmodule.exports = {\n  apps: [\n    {\n      name: '${API}',\n      env: {\n${body}\n      },\n    },\n  ],\n}\n`
    return crlf ? text.replaceAll('\n', '\r\n') : text
  }
  let probe = 0
  /** Load an ecosystem file the way pm2 does (node `require`) and return its env blocks as JSON. */
  const load = (text: string): string => {
    const file = join(root, `ecosystem-probe-${probe++}.js`)
    writeFileSync(file, text)
    const script = `const m = require(${JSON.stringify(file)}); process.stdout.write(JSON.stringify(m.apps.map((a) => [a.env, a.env_production])))`
    const result = Bun.spawnSync([Bun.which('node') ?? process.execPath, '-e', script])
    return result.exitCode === 0 ? result.stdout.toString() : `LOAD-ERROR ${result.stderr.toString()}`
  }
  const envOf = (text: string) => (JSON.parse(load(text)) as [Record<string, unknown>][])[0][0]

  it('renames a generated PM2 name line, keeping its value and the rest of the file byte for byte', () => {
    const before = wrap(`        TAU_PM2_API_NAME: '${API}',\n        TAU_SYSTEM_LOG_PROVIDER: 'pm2',`)
    const { content, warnings } = renameEcosystemPm2Names(before)
    expect(content).toBe(before.replace('TAU_PM2_API_NAME', 'FICUS_PM2_API_NAME'))
    expect(warnings).toEqual([])
    expect(envOf(content)).toEqual({ FICUS_PM2_API_NAME: API, TAU_SYSTEM_LOG_PROVIDER: 'pm2' })
  })

  it('leaves every other TAU_ key alone, commented, quoted or not', () => {
    const before = wrap(
      [
        "        TAU_SYSTEM_LOG_PROVIDER: 'pm2',",
        "        // TAU_SERVE_WEB: '1',",
        "        'TAU_QUOTED': 'x',",
        "        TAU_ENCRYPTION_KEY: 'aaa',",
        "        FICUS_ENCRYPTION_KEY: 'bbb',",
      ].join('\n')
    )
    expect(renameEcosystemPm2Names(before)).toEqual({ content: before, warnings: [] })
  })

  it('keeps CRLF line endings on a renamed line', () => {
    const before = wrap(`        TAU_PM2_WORKER_NAME: '${WORKER}',`, true)
    expect(renameEcosystemPm2Names(before).content).toBe(before.replace('TAU_PM2_WORKER_NAME', 'FICUS_PM2_WORKER_NAME'))
  })

  it('does nothing, silently, when the FICUS_ twin already names the same process', () => {
    const before = wrap(`        TAU_PM2_API_NAME: '${API}',\n        FICUS_PM2_API_NAME: "${API}",`)
    expect(renameEcosystemPm2Names(before)).toEqual({ content: before, warnings: [] })
  })

  const notRenamed = (key: string) =>
    `${key} in ecosystem.config.js was not renamed to ${key.replace('TAU_', 'FICUS_')}: it is not a single \`${key}: '<name>',\` line; rename it by hand`
  const twinDiffers = (key: string) =>
    `${key} and ${key.replace('TAU_', 'FICUS_')} in ecosystem.config.js name different processes (or ${key.replace('TAU_', 'FICUS_')} is not a plain \`${key.replace('TAU_', 'FICUS_')}: '<name>',\` line); both were left as they are — remove the wrong one`

  // Each leaves the file byte-identical, says which key it left, and the file still loads.
  const unrenamed: [string, string, string][] = [
    [
      'a value on the next line (what Prettier writes for a long one)',
      `        TAU_PM2_API_NAME:\n          '${API}',`,
      notRenamed('TAU_PM2_API_NAME'),
    ],
    ['a continued value', "        TAU_PM2_API_NAME: 'tau'\n          + '-api',", notRenamed('TAU_PM2_API_NAME')],
    ['a second key on the same line', "        TAU_PM2_API_NAME: 'a', OTHER: 1,", notRenamed('TAU_PM2_API_NAME')],
    ['no trailing comma', "        OTHER: 1,\n        TAU_PM2_API_NAME: 'a'", notRenamed('TAU_PM2_API_NAME')],
    ['an expression value', '        TAU_PM2_API_NAME: KEY,', notRenamed('TAU_PM2_API_NAME')],
    ['a template literal', '        TAU_PM2_API_NAME: `a`,', notRenamed('TAU_PM2_API_NAME')],
    ['an escaped quote', "        TAU_PM2_API_NAME: 'it\\'s',", notRenamed('TAU_PM2_API_NAME')],
    ['the key twice', "        TAU_PM2_API_NAME: 'a',\n        TAU_PM2_API_NAME: 'b',", notRenamed('TAU_PM2_API_NAME')],
    [
      'a twin naming another process',
      "        TAU_PM2_WORKER_NAME: 'a',\n        FICUS_PM2_WORKER_NAME: 'b',",
      twinDiffers('TAU_PM2_WORKER_NAME'),
    ],
    [
      'a one-side-quoted twin',
      "        TAU_PM2_API_NAME: 'KEY',\n        FICUS_PM2_API_NAME: KEY,",
      twinDiffers('TAU_PM2_API_NAME'),
    ],
  ]
  for (const [label, body, warning] of unrenamed) {
    it(`leaves ${label} alone, with a warning naming the key`, () => {
      const before = wrap(body)
      const { content, warnings } = renameEcosystemPm2Names(before)
      expect(content).toBe(before)
      expect(warnings).toEqual([warning])
      expect(warnings.join('\n')).not.toContain("'a'")
      expect(load(content)).not.toStartWith('LOAD-ERROR')
    })
  }

  it('never warns about a commented-out PM2 name line', () => {
    const before = wrap(`        // TAU_PM2_API_NAME: '${API}',`)
    expect(renameEcosystemPm2Names(before)).toEqual({ content: before, warnings: [] })
  })

  // The reviewer's probes (t10-review-r1/adv.ts) against the parser this replaces: none names a
  // PM2 key, so each must come back byte-identical, the encryption-key cases included.
  const probes: [string, string][] = [
    ['protected differ', `        TAU_ENCRYPTION_KEY: 'aaa',\n        FICUS_ENCRYPTION_KEY: 'bbb',`],
    ['protected same, quote styles', `        TAU_ENCRYPTION_KEY: 'aaa',\n        FICUS_ENCRYPTION_KEY: "aaa", // c`],
    ['unprotected differ', `        TAU_X: 'a',\n        FICUS_X: 'b',`],
    ['commented TAU beside live FICUS', `        // TAU_ENCRYPTION_KEY: 'aaa',\n        FICUS_ENCRYPTION_KEY: 'bbb',`],
    ['live TAU beside commented FICUS', `        TAU_ENCRYPTION_KEY: 'aaa',\n        // FICUS_ENCRYPTION_KEY: 'bbb',`],
    ['literal vs identifier', `        TAU_ENCRYPTION_KEY: 'KEY',\n        FICUS_ENCRYPTION_KEY: KEY,`],
    [
      'encryption key continuation on the FICUS twin',
      `        TAU_ENCRYPTION_KEY: 'k1',\n        FICUS_ENCRYPTION_KEY: 'k1'\n          + 'k2',`,
    ],
    [
      'encryption key continuation on TAU',
      `        FICUS_ENCRYPTION_KEY: 'k1',\n        TAU_ENCRYPTION_KEY: 'k1'\n          + 'k2',`,
    ],
    [
      'value on the next line, protected',
      `        TAU_ENCRYPTION_KEY:\n          'aaaa',\n        FICUS_ENCRYPTION_KEY:\n          'bbbb',`,
    ],
    ['value on the next line, unprotected', `        TAU_X:\n          'aaaa',\n        FICUS_X: 'bbbb',`],
    ['ternary continuation', `        FICUS_X: 'b',\n        TAU_X: process.env.A\n          ? 'x'\n          : 'y',`],
    ['template twin', "        TAU_ENCRYPTION_KEY: `k`,\n        FICUS_ENCRYPTION_KEY: 'k',"],
    ['template with ${}', '        TAU_URL: `${process.env.HOME}/x // not a comment`,\n        OTHER: 1,'],
    ['multi-line template holding a key', "        NOTE: `\nTAU_ENCRYPTION_KEY: 'x'\n`,\n        TAU_Y: 1,"],
    ['escaped quotes', `        TAU_ENCRYPTION_KEY: 'it\\'s',\n        FICUS_ENCRYPTION_KEY: "it's",`],
    ['// in a string', `        TAU_URL: 'http://x/y', // real comment\n        FICUS_URL: "http://x/y",`],
    ['two keys on one line', `        TAU_ENCRYPTION_KEY: 'a', FICUS_ENCRYPTION_KEY: 'b',`],
    ['empty FICUS twin', `        TAU_ENCRYPTION_KEY: 'real',\n        FICUS_ENCRYPTION_KEY: '',`],
    ['regex with a quote', `        TAU_X: 'a'.replace(/'/g, ''),`],
    [
      'nested twin',
      `        FICUS_ENCRYPTION_KEY: 'a',\n        inner: {\n          TAU_ENCRYPTION_KEY: 'b',\n        },`,
    ],
    ['block comment holding a key', `        /*\n        TAU_X: 'a',\n        */\n        TAU_Y: 1,`],
  ]
  for (const [label, body] of probes) {
    it(`leaves probe "${label}" byte-identical and loadable`, () => {
      const before = wrap(body)
      expect(renameEcosystemPm2Names(before)).toEqual({ content: before, warnings: [] })
      expect(load(before)).not.toStartWith('LOAD-ERROR')
    })
  }

  it('turns a file generated from the pre-rename example into the new generator output for the PM2 names', () => {
    const names = instanceNames('smoke')
    const example = readFileSync(join(__dirname, '../../../../ecosystem.config.example.js'), 'utf8')
    const generated = generateEcosystem(example, names)
    // The pre-rename example spelled every key TAU_; so did the file generated from it.
    const legacy = generated.replace(/\bFICUS_/g, 'TAU_')
    const { content, warnings } = renameEcosystemPm2Names(legacy)
    expect(warnings).toEqual([])
    const [renamedLines, legacyLines, newLines] = [content, legacy, generated].map((text) => text.split('\n'))
    expect(renamedLines).toHaveLength(legacyLines.length)
    for (const [index, line] of renamedLines.entries()) {
      expect(line).toBe(/FICUS_PM2_(API|WORKER)_NAME/.test(newLines[index]) ? newLines[index] : legacyLines[index])
    }
    expect(content).toContain(`FICUS_PM2_API_NAME: '${names.api}',`)
    expect(content).toContain(`FICUS_PM2_WORKER_NAME: '${names.worker}',`)
    expect(load(content)).not.toStartWith('LOAD-ERROR')
  })
})

describe('migrateLocalInstallEnv and ecosystem.config.js', () => {
  it('never touches an ecosystem encryption key, even beside a differing FICUS_ twin', async () => {
    const ecosystem = [
      'module.exports = {',
      '  apps: [{',
      `    name: '${API}',`,
      '    env: {',
      `      TAU_PM2_API_NAME: '${API}',`,
      "      TAU_ENCRYPTION_KEY: 'old-key-value',",
      "      FICUS_ENCRYPTION_KEY: 'new-key-value',",
      '    },',
      '  }],',
      '}',
      '',
    ].join('\n')
    writeFileSync(join(root, '.env'), ENV)
    writeFileSync(join(root, 'ecosystem.config.js'), ecosystem)
    const warnings: string[] = []
    await migrateLocalInstallEnv(root, NOW, { warn: (line) => warnings.push(line) })
    expect(read('ecosystem.config.js').toString()).toBe(ecosystem.replace('TAU_PM2_API_NAME', 'FICUS_PM2_API_NAME'))
    expect(warnings).toEqual([])
  })

  it('passes a PM2 name warning on, and takes no ecosystem backup when nothing there changes', async () => {
    writeFileSync(join(root, 'ecosystem.config.js'), `module.exports = {\n  TAU_PM2_API_NAME:\n    '${API}',\n}\n`)
    const warnings: string[] = []
    expect(await migrateLocalInstallEnv(root, NOW, { warn: (line) => warnings.push(line) })).toEqual({
      renamed: [],
      backups: [],
    })
    expect(warnings).toEqual([expect.stringContaining('TAU_PM2_API_NAME in ecosystem.config.js was not renamed')])
    expect(backupsIn()).toEqual([])
  })
})

describe('rejectAfterRestoring', () => {
  it('rejects with the original error once the backups are restored', async () => {
    const original = new Error('replace failed')
    await expect(rejectAfterRestoring(original, [])).rejects.toBe(original)
  })

  it('keeps both errors when the restore fails too, the original first', async () => {
    const original = new Error('replace failed')
    const error = (await rejectAfterRestoring(original, [join(root, 'missing.pre-ficus-1')]).catch(
      (e: unknown) => e
    )) as AggregateError
    expect(error).toBeInstanceOf(AggregateError)
    expect(error.errors[0]).toBe(original)
    expect(error.errors).toHaveLength(2)
    expect(error.message).toContain('replace failed')
    expect(error.message).toContain('restoring the backups')
  })
})

describe('checkoutEnvPrefix / migrateCheckoutEnv', () => {
  it('reads the direction from the checkout root package.json name', () => {
    expect(checkoutEnvPrefix(root)).toBeNull()
    writeFileSync(join(root, 'package.json'), JSON.stringify({ name: 'ficus' }))
    expect(checkoutEnvPrefix(root)).toBe('FICUS_')
    writeFileSync(join(root, 'package.json'), JSON.stringify({ name: 'tau' }))
    expect(checkoutEnvPrefix(root)).toBe('TAU_')
    writeFileSync(join(root, 'package.json'), '{not json')
    expect(checkoutEnvPrefix(root)).toBeNull()
  })

  it('leaves a checkout that predates the rename alone: its code reads TAU_', async () => {
    writeFileSync(join(root, 'package.json'), JSON.stringify({ name: 'tau' }))
    writeFileSync(join(root, '.env'), ENV)
    expect(await migrateCheckoutEnv(root, { log: () => {}, now: NOW })).toEqual({
      renamed: [],
      backups: [],
      warnings: [],
    })
    expect(read('.env').toString()).toBe(ENV)
  })

  it('renames a Ficus checkout and says which files moved and where the backups are', async () => {
    writeFileSync(join(root, 'package.json'), JSON.stringify({ name: 'ficus' }))
    writeFileSync(join(root, '.env'), ENV)
    const logs: string[] = []
    const result = await migrateCheckoutEnv(root, { log: (line) => logs.push(line), now: NOW })
    expect(result.backups).toEqual([join(root, `.env.pre-ficus-${STAMP}`)])
    expect(logs).toEqual([`Renamed TAU_ settings to FICUS_ in .env (backup: .env.pre-ficus-${STAMP})`])
  })

  it('fails closed on a missing or unknown package name, with a warning when TAU_ settings stay', async () => {
    writeFileSync(join(root, '.env'), ENV)
    const logs: string[] = []
    expect(await migrateCheckoutEnv(root, { log: (line) => logs.push(line), now: NOW })).toEqual({
      renamed: [],
      backups: [],
      warnings: [
        `TAU_ settings in ${root} were not renamed to FICUS_: its package.json could not be read, not "ficus"`,
      ],
    })
    writeFileSync(join(root, 'package.json'), JSON.stringify({ name: 'fork' }))
    await migrateCheckoutEnv(root, { log: (line) => logs.push(line), now: NOW })
    expect(read('.env').toString()).toBe(ENV)
    expect(backupsIn()).toEqual([])
    expect(logs).toEqual([
      `warning: TAU_ settings in ${root} were not renamed to FICUS_: its package.json could not be read, not "ficus"`,
      `warning: TAU_ settings in ${root} were not renamed to FICUS_: its package.json is named "fork", not "ficus"`,
    ])
  })

  it('stays silent on a checkout that predates the rename, and on one with nothing to rename', async () => {
    const logs: string[] = []
    writeFileSync(join(root, 'package.json'), JSON.stringify({ name: 'tau' }))
    writeFileSync(join(root, '.env'), ENV)
    await migrateCheckoutEnv(root, { log: (line) => logs.push(line) })
    writeFileSync(join(root, 'package.json'), JSON.stringify({ name: 'fork' }))
    writeFileSync(join(root, '.env'), 'FICUS_PASSWORD=p\n')
    await migrateCheckoutEnv(root, { log: (line) => logs.push(line) })
    expect(logs).toEqual([])
  })

  it('says nothing when there is nothing to rename', async () => {
    writeFileSync(join(root, 'package.json'), JSON.stringify({ name: 'ficus' }))
    writeFileSync(join(root, '.env'), 'FICUS_PASSWORD=p\n')
    const logs: string[] = []
    await migrateCheckoutEnv(root, { log: (line) => logs.push(line), now: NOW })
    expect(logs).toEqual([])
  })
})

describe('the checkout .gitignore', () => {
  // An untracked backup would make the tree dirty, and `server update` and the
  // in-app updater both refuse (or skip) a dirty checkout.
  it('ignores the rename backups and an interrupted rename temp file', async () => {
    const repoRoot = join(__dirname, '../../../../')
    for (const path of [
      `.env.pre-ficus-${STAMP}`,
      `ecosystem.config.js.pre-ficus-${STAMP}`,
      `ecosystem.config.js.pre-ficus-${STAMP}-1`,
      '..env.ficus-tmp-123-abcd',
      '.ecosystem.config.js.ficus-tmp-123-abcd',
    ]) {
      const result = await defaultRunner(['git', 'check-ignore', '-q', '--no-index', path], { cwd: repoRoot })
      expect({ path, ignored: result.code === 0 }).toEqual({ path, ignored: true })
    }
  })
})
