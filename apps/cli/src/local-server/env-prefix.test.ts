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
  it('renames TAU_ object keys (commented or quoted) and leaves values and other text alone', () => {
    const text = [
      `  TAU_PM2_API_NAME: '${API}',`,
      "  // TAU_SERVE_WEB: '1',",
      "  'TAU_QUOTED': 'x',",
      "  script: 'TAU_NOT_A_KEY',",
      `  name: '${WORKER}',`,
    ].join('\n')
    expect(renameEcosystemEnvKeys(text)).toBe(
      [
        `  FICUS_PM2_API_NAME: '${API}',`,
        "  // FICUS_SERVE_WEB: '1',",
        "  'FICUS_QUOTED': 'x',",
        "  script: 'TAU_NOT_A_KEY',",
        `  name: '${WORKER}',`,
      ].join('\n')
    )
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
