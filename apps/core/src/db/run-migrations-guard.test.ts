import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'fs'
import { join } from 'path'
import { MONOREPO_ROOT } from '../lib/paths'
import { checkMigrationSafety, normalizeDatabaseUrl, runGuardedMigration } from './run-migrations-guard'

const CREDENTIAL_SENTINEL = 'migration-credential-sentinel-9f2a'
const ROOT_URL = `postgres://root:${CREDENTIAL_SENTINEL}@db.example.com:5432/tau`
const TEST_URL = 'postgres://test:scratch-credential@127.0.0.1:5433/tau_test'

function check(
  overrides: Partial<Parameters<typeof checkMigrationSafety>[0]> = {}
): ReturnType<typeof checkMigrationSafety> {
  return checkMigrationSafety({
    explicitDatabaseUrl: TEST_URL,
    resolvedDatabaseUrl: TEST_URL,
    rootDatabaseUrl: ROOT_URL,
    liveEnvValue: undefined,
    argv: ['bun', 'run-migrations.ts'],
    ...overrides,
  })
}

describe('checkMigrationSafety', () => {
  test('refuses a database URL inherited from the root environment', () => {
    expect(() =>
      check({
        explicitDatabaseUrl: undefined,
        resolvedDatabaseUrl: ROOT_URL,
      })
    ).toThrow('explicit DATABASE_URL override')
  })

  test('refuses an explicit URL that identifies the root database', () => {
    expect(() => check({ explicitDatabaseUrl: ROOT_URL, resolvedDatabaseUrl: ROOT_URL })).toThrow(
      'FICUS_MIGRATE_LIVE=1 or pass --live'
    )
  })

  test('uses normalized database identity at the guard comparison seam', () => {
    expect(() =>
      check({
        rootDatabaseUrl: 'postgres://root:pw@DB.EXAMPLE.COM:5432/tau?b=2&a=1',
        explicitDatabaseUrl: 'postgresql://other:pw@db.example.com/tau?a=9',
        resolvedDatabaseUrl: 'postgresql://other:pw@db.example.com/tau?a=9',
      })
    ).toThrow('repository root database')
  })

  test.each([
    'postgres://db.example.com/tau',
    'postgres://another:different@db.example.com/tau',
    'postgres://another:p%40ssword@db.example.com/tau',
  ])('refuses the root database regardless of credential representation: %s', (variant) => {
    expect(() => check({ explicitDatabaseUrl: variant, resolvedDatabaseUrl: variant })).toThrow(
      'repository root database'
    )
  })

  test('folds localhost and IPv4 loopback when comparing database identity', () => {
    const root = 'postgres://root:pw@localhost:5432/tau'
    const explicit = 'postgres://other:pw@127.0.0.1/tau'
    expect(() =>
      check({ rootDatabaseUrl: root, explicitDatabaseUrl: explicit, resolvedDatabaseUrl: explicit })
    ).toThrow('repository root database')
  })

  test('does not weaken database-name identity', () => {
    const root = 'postgres://root:pw@localhost/tau'
    const scratch = 'postgres://root:pw@127.0.0.1/tau_scratch'
    expect(check({ rootDatabaseUrl: root, explicitDatabaseUrl: scratch, resolvedDatabaseUrl: scratch }).argv).toEqual([
      'bun',
      'run-migrations.ts',
    ])
  })

  test.each(['not a URL', 'mysql://root:pw@db.example.com/tau'])(
    'allows a valid scratch target when the root URL cannot identify PostgreSQL: %s',
    (rootDatabaseUrl) => {
      expect(check({ rootDatabaseUrl }).argv).toEqual(['bun', 'run-migrations.ts'])
    }
  )

  test('allows an explicitly supplied non-root database URL', () => {
    expect(check().argv).toEqual(['bun', 'run-migrations.ts'])
  })

  test('allows deliberate live migration with FICUS_MIGRATE_LIVE=1', () => {
    expect(check({ explicitDatabaseUrl: undefined, resolvedDatabaseUrl: ROOT_URL, liveEnvValue: '1' }).argv).toEqual([
      'bun',
      'run-migrations.ts',
    ])
  })

  test('allows deliberate live migration with --live and strips the flag', () => {
    expect(
      check({
        explicitDatabaseUrl: undefined,
        resolvedDatabaseUrl: ROOT_URL,
        argv: ['bun', 'run-migrations.ts', '--live', '--verbose'],
      }).argv
    ).toEqual(['bun', 'run-migrations.ts', '--verbose'])
  })

  test.each(['', '0', 'true', 'yes', '2'])('rejects invalid FICUS_MIGRATE_LIVE value %p', (value) => {
    expect(() => check({ liveEnvValue: value })).toThrow('FICUS_MIGRATE_LIVE must be exactly 1')
  })

  test('refuses before loading database and migration side effects', async () => {
    let sideEffectsLoaded = false

    await expect(
      runGuardedMigration(
        {
          explicitDatabaseUrl: undefined,
          resolvedDatabaseUrl: ROOT_URL,
          rootDatabaseUrl: ROOT_URL,
          liveEnvValue: undefined,
          argv: ['bun', 'run-migrations.ts'],
        },
        async () => {
          sideEffectsLoaded = true
        }
      )
    ).rejects.toThrow('explicit DATABASE_URL override')
    expect(sideEffectsLoaded).toBe(false)
  })

  test('strips --live before loading canonical migration execution', async () => {
    const argv = ['bun', 'run-migrations.ts', '--live', '--verbose']
    let downstreamArgv: string[] = []

    await runGuardedMigration(
      {
        explicitDatabaseUrl: undefined,
        resolvedDatabaseUrl: ROOT_URL,
        rootDatabaseUrl: ROOT_URL,
        liveEnvValue: undefined,
        argv,
      },
      async () => {
        downstreamArgv = [...argv]
      }
    )

    expect(downstreamArgv).toEqual(['bun', 'run-migrations.ts', '--verbose'])
  })

  test('discloses only the sanitized target identity in refusal errors', () => {
    let message = ''
    try {
      check({ explicitDatabaseUrl: ROOT_URL, resolvedDatabaseUrl: ROOT_URL })
    } catch (error) {
      message = String(error)
    }
    expect(message).toContain('db.example.com:5432/tau')
    expect(message).not.toContain(ROOT_URL)
    expect(message).not.toContain(CREDENTIAL_SENTINEL)
    expect(message).not.toContain('root:')
  })

  test('the production setup toolkit explicitly authorizes its deliberate live migration', () => {
    const setupLibrary = readFileSync(join(MONOREPO_ROOT, 'scripts/setup/lib.sh'), 'utf8')
    const migrationFunction = setupLibrary.match(/run_db_migrations\(\)[\s\S]*?^}/m)?.[0]

    expect(migrationFunction).toContain('FICUS_MIGRATE_LIVE=1 bun run db:migrate')
  })
})

describe('normalizeDatabaseUrl', () => {
  test('normalizes harmless PostgreSQL URL representation differences', () => {
    expect(normalizeDatabaseUrl('POSTGRESQL://user:pass@DB.EXAMPLE.COM:5432/tau?b=2&a=1')).toBe(
      normalizeDatabaseUrl('postgres://user:pass@db.example.com/tau?a=1&b=2')
    )
  })

  test('ignores credentials while preserving database identity', () => {
    expect(normalizeDatabaseUrl('postgres://user:one@db/tau')).toBe(normalizeDatabaseUrl('postgres://other:two@db/tau'))
    expect(normalizeDatabaseUrl('postgres://user:one@db/tau')).not.toBe(
      normalizeDatabaseUrl('postgres://user:one@db/other')
    )
  })
})
