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
import { EcosystemEnvRenameError } from '@ficus/shared/node'
import {
  checkoutEnvPrefix,
  migrateCheckoutEnv,
  migrateLocalInstallEnv,
  planLocalInstallEnvMigration,
  rejectAfterRestoring,
  renameEcosystemEnvKeys,
  restoreLocalInstallEnv,
} from './env-prefix'
import { instanceNames } from './instance'
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
  it('renames .env and the ecosystem env keys to FICUS_, keeping every value and byte-identical backups', async () => {
    writeFileSync(join(root, '.env'), ENV)
    writeFileSync(join(root, 'ecosystem.config.js'), ECOSYSTEM)
    chmodSync(join(root, '.env'), 0o600)
    chmodSync(join(root, 'ecosystem.config.js'), 0o644)

    const result = await migrateLocalInstallEnv(root, NOW)

    expect(read('.env').toString()).toBe(`FICUS_ENCRYPTION_KEY=${KEY}\nFICUS_SANDBOX_RUNTIME=host\n`)
    const ecosystem = read('ecosystem.config.js').toString()
    expect(ecosystem).toContain(`        FICUS_PM2_API_NAME: '${API}',\n`)
    expect(ecosystem).toContain(`        FICUS_PM2_WORKER_NAME: '${WORKER}',\n`)
    expect(ecosystem).toContain("        FICUS_SYSTEM_LOG_PROVIDER: 'pm2',\n")
    expect(ecosystem).toContain("        // FICUS_SERVE_WEB: '1',\n")
    // The process names are phase-5 identity: only the keys move.
    expect(ecosystem).toContain(`      name: '${API}',\n`)
    expect(ecosystem).not.toMatch(/\bTAU_/)

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

describe('renameEcosystemEnvKeys', () => {
  /** An ecosystem file with one app per env body. */
  const apps = (...envs: string[][]) =>
    [
      'module.exports = {',
      '  apps: [',
      ...envs.flatMap((env, index) => [
        '    {',
        `      name: '${index === 0 ? API : WORKER}',`,
        '      env: {',
        ...env.map((line) => `        ${line}`),
        '      },',
        '    },',
      ]),
      '  ],',
      '}',
      '',
    ].join('\n')

  it('renames TAU_ object keys (commented or quoted) and leaves values and other text alone', () => {
    const before = apps([
      `TAU_PM2_API_NAME: '${API}',`,
      "// TAU_SERVE_WEB: '1',",
      "'TAU_QUOTED': 'x',",
      "script: 'TAU_NOT_A_KEY',",
    ])
    expect(renameEcosystemEnvKeys(before)).toBe(
      apps([
        `FICUS_PM2_API_NAME: '${API}',`,
        "// FICUS_SERVE_WEB: '1',",
        "'FICUS_QUOTED': 'x',",
        "script: 'TAU_NOT_A_KEY',",
      ])
    )
  })

  it('collapses a TAU_ key whose FICUS_ twin in the same object holds the identical value', () => {
    expect(renameEcosystemEnvKeys(apps(["TAU_PASSWORD: 'same',", 'FICUS_PASSWORD: "same",']))).toBe(
      apps(['FICUS_PASSWORD: "same",'])
    )
  })

  it('keeps FICUS_ for a differing unprotected duplicate: it is what the process reads', () => {
    expect(renameEcosystemEnvKeys(apps(["TAU_PM2_API_NAME: 'old',", "FICUS_PM2_API_NAME: 'new',"]))).toBe(
      apps(["FICUS_PM2_API_NAME: 'new',"])
    )
  })

  it('refuses a differing protected duplicate, naming the key and neither value', () => {
    const run = () =>
      renameEcosystemEnvKeys(apps(["TAU_ENCRYPTION_KEY: 'old-key-value',", "FICUS_ENCRYPTION_KEY: 'new-key-value',"]))
    expect(run).toThrow(EnvPrefixConflictError)
    try {
      run()
    } catch (error) {
      expect((error as EnvPrefixConflictError).keys).toEqual(['TAU_ENCRYPTION_KEY'])
      expect((error as Error).message).not.toContain('key-value')
    }
  })

  it('scopes duplicates to one object: a FICUS_ key in another app does not shadow it', () => {
    expect(renameEcosystemEnvKeys(apps(["TAU_PASSWORD: 'a',"], ["FICUS_PASSWORD: 'b',"]))).toBe(
      apps(["FICUS_PASSWORD: 'a',"], ["FICUS_PASSWORD: 'b',"])
    )
  })

  it('never adds a commented-out key that already exists as FICUS_', () => {
    expect(renameEcosystemEnvKeys(apps(["// TAU_SERVE_WEB: '1',", "FICUS_SERVE_WEB: '1',"]))).toBe(
      apps(["// TAU_SERVE_WEB: '1',", "FICUS_SERVE_WEB: '1',"])
    )
  })

  it('leaves a one-line object and text inside strings or comments alone', () => {
    const text = [
      'module.exports = {',
      "  apps: [{ name: 'x', env: { TAU_ONE_LINE: 1 } }],",
      '  note: `',
      '  TAU_IN_TEMPLATE: 1,',
      '  `,',
      '  /*',
      '  TAU_IN_BLOCK: 1,',
      '  */',
      '}',
    ].join('\n')
    expect(renameEcosystemEnvKeys(text)).toBe(text)
  })

  it('refuses a file it cannot follow, and a multi-line duplicate it cannot drop line by line', () => {
    expect(() => renameEcosystemEnvKeys("module.exports = {\n  TAU_X: 'a',\n")).toThrow(EcosystemEnvRenameError)
    expect(() => renameEcosystemEnvKeys("module.exports = {\n  TAU_X: 'it's',\n}\n")).toThrow(EcosystemEnvRenameError)
    expect(() => renameEcosystemEnvKeys(apps(['TAU_LIST: [', "  'a',", '],', "FICUS_LIST: ['b'],"]))).toThrow(
      'TAU_LIST spans several lines next to FICUS_LIST; rename its TAU_ keys to FICUS_ by hand, then re-run'
    )
  })
})

describe('migrateLocalInstallEnv on ecosystem.config.js duplicates', () => {
  it('refuses a protected conflict before any backup or write, naming the file and key only', async () => {
    const ecosystem = [
      'module.exports = {',
      '  apps: [{',
      `    name: '${API}',`,
      '    env: {',
      "      TAU_ENCRYPTION_KEY: 'old-key-value',",
      "      FICUS_ENCRYPTION_KEY: 'new-key-value',",
      '    },',
      '  }],',
      '}',
      '',
    ].join('\n')
    writeFileSync(join(root, '.env'), ENV)
    writeFileSync(join(root, 'ecosystem.config.js'), ecosystem)

    const error = (await migrateLocalInstallEnv(root, NOW).catch((e: unknown) => e)) as EnvPrefixConflictError
    expect(error).toBeInstanceOf(EnvPrefixConflictError)
    expect(error.keys).toEqual(['TAU_ENCRYPTION_KEY'])
    expect(error.message).toContain(join(root, 'ecosystem.config.js'))
    expect(error.message).toContain('remove the wrong value, then re-run')
    expect(error.message).not.toContain('key-value')
    // Nothing moved, .env included: every file is planned before any is written.
    expect(read('.env').equals(Buffer.from(ENV))).toBe(true)
    expect(read('ecosystem.config.js').equals(Buffer.from(ecosystem))).toBe(true)
    expect(backupsIn()).toEqual([])
  })

  it('refuses an ecosystem file it cannot follow, naming it, with nothing written', async () => {
    writeFileSync(join(root, '.env'), ENV)
    writeFileSync(join(root, 'ecosystem.config.js'), "module.exports = {\n  TAU_X: 'a',\n")
    await expect(migrateLocalInstallEnv(root, NOW)).rejects.toThrow(
      `${join(root, 'ecosystem.config.js')}: its quotes, comments or brackets do not balance`
    )
    expect(read('.env').toString()).toBe(ENV)
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
    expect(await migrateCheckoutEnv(root, { log: () => {}, now: NOW })).toEqual({ renamed: [], backups: [] })
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
