import { generateKeyPairSync } from 'node:crypto'
import { chmod, mkdir, mkdtemp, readdir, readFile, rm, stat, symlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { describe, expect, it } from 'bun:test'
import { Hono } from 'hono'
import { CORE_ROOT_PACKAGE_NAMES } from '@ficus/shared/identity'
import { mountCoreDocs } from '../../lib/docs-serve'
import { resolveCoreDocsDist } from '../../lib/web-dist'
import {
  assembleCoreArtifact,
  defaultRun,
  formatTrailer,
  GENERATED_ROOT_MARKER,
  type Run,
  type RunResult,
} from '../../../../../scripts/artifact/lib/assemble-core-artifact'
import {
  artifactPlatform,
  computeDigest,
  computeFilesMap,
  verifyManifestSignature,
} from '../../../../../scripts/artifact/lib/manifest'

const COMMIT = '0123456789abcdef0123456789abcdef01234567'
const COMMIT_DATE = '2026-08-25T12:00:00+00:00'

async function pathExists(path: string): Promise<boolean> {
  try {
    await stat(path)
    return true
  } catch {
    return false
  }
}

async function write(path: string, contents: string): Promise<void> {
  await mkdir(dirname(path), { recursive: true })
  await writeFile(path, contents)
}

/**
 * A fixture that stands in for a fully built checkout: every path the layout
 * names, plus decoys that must NOT end up in the artifact (`src/`, `.git/`,
 * `bun.lock`, `patches/`, sibling files inside directories we copy
 * selectively, and a `.DS_Store`).
 */
async function makeCheckout(): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), 'assemble-core-artifact-checkout-'))
  await write(join(root, '.bun-version'), '1.3.8\n')

  await write(join(root, 'apps/core/dist/index.js'), 'core index bundle\n')
  await write(join(root, 'apps/core/dist/worker.js'), 'core worker bundle\n')
  await write(join(root, 'apps/core/dist/migrate.js'), 'core migrate bundle\n')
  await write(join(root, 'apps/core/dist/smoke-configured-extensions.js'), 'configured extension smoke bundle\n')
  await write(join(root, 'apps/core/dist/box-control.js'), 'operator box control bundle\n')
  // Not part of the layout: dist holds build detritus that must not ship.
  await write(join(root, 'apps/core/dist/tsconfig.tsbuildinfo'), '{"detritus":true}\n')

  await write(join(root, 'apps/core/drizzle/0000_init.sql'), 'CREATE TABLE a();\n')
  await write(join(root, 'apps/core/drizzle/meta/_journal.json'), '{"entries":[]}\n')

  await write(join(root, 'apps/core/docker-sandbox/devbox.json'), '{"packages":[]}\n')
  await write(join(root, 'apps/core/docker-sandbox/git-credential-github-token'), '#!/bin/sh\n')
  await write(join(root, 'apps/core/docker-sandbox/command-identity.json'), '{"commands":[]}\n')
  // Siblings in the same directory that the layout does not name.
  await write(join(root, 'apps/core/docker-sandbox/Dockerfile'), 'FROM scratch\n')
  await write(join(root, 'apps/core/docker-sandbox/startup.sh'), 'echo hi\n')

  await write(join(root, 'apps/core/docs-dist/index.html'), 'docs home')
  await write(join(root, 'apps/core/docs-dist/404.html'), 'docs missing')
  await write(join(root, 'apps/core/docs-dist/pagefind/pagefind.js'), 'search')
  await write(join(root, 'apps/web/dist/index.html'), '<!doctype html>\n')
  await write(join(root, 'apps/web/dist/assets/app.js'), 'console.log(1)\n')
  await write(join(root, 'apps/web/dist/.DS_Store'), 'finder junk')

  await write(join(root, 'apps/cli/dist/tau.js'), '#!/usr/bin/env bun\n')
  await chmod(join(root, 'apps/cli/dist/tau.js'), 0o755)
  await write(join(root, 'apps/cli/dist/skills/tau-memory/SKILL.md'), '# memory\n')

  await write(join(root, 'config/agent/agent.md'), '# agent\n')
  await write(
    join(root, 'config/agent/extensions/code-ast/package.json'),
    '{"name":"code-ast","pi":{"extensions":["./index.ts"]}}\n'
  )
  await write(join(root, 'config/agent/extensions/code-ast/index.ts'), 'export default function () {}\n')
  await write(join(root, 'config/agent/extensions/code-ast/node_modules/typescript/package.json'), '{"name":"ts"}\n')
  await mkdir(join(root, 'config/agent/extensions/code-ast/node_modules/.bin'), { recursive: true })
  await symlink('../typescript/package.json', join(root, 'config/agent/extensions/code-ast/node_modules/.bin/tsc-link'))

  for (const name of ['server.js', 'librust_pty.so', 'tau.js', 'bootstrap.sh', 'box-provision.sh']) {
    await write(join(root, 'machine', name), `machine ${name}\n`)
  }

  await write(
    join(root, 'node_modules/playwright-core/package.json'),
    '{"name":"playwright-core","version":"1.58.2"}\n'
  )
  await write(join(root, 'node_modules/bun-pty/package.json'), '{"name":"bun-pty","version":"0.4.8"}\n')
  await write(join(root, 'node_modules/jsdom/package.json'), '{"name":"jsdom","version":"26.0.0"}\n')
  await write(
    join(root, 'node_modules/@silvia-odwyer/photon-node/package.json'),
    '{"name":"@silvia-odwyer/photon-node","version":"0.3.3"}\n'
  )
  await write(
    join(root, 'node_modules/@google-cloud/text-to-speech/package.json'),
    '{"name":"@google-cloud/text-to-speech","version":"6.4.0"}\n'
  )
  await write(
    join(root, 'node_modules/@aws-sdk/client-ses/package.json'),
    '{"name":"@aws-sdk/client-ses","version":"3.1005.0"}\n'
  )
  await write(
    join(root, 'node_modules/@aws-sdk/client-s3/package.json'),
    '{"name":"@aws-sdk/client-s3","version":"3.999.0"}\n'
  )
  await write(join(root, 'node_modules/typescript/package.json'), '{"name":"typescript","version":"5.7.0"}\n')

  // Decoys: none of these may appear inside the artifact.
  // The repo's own root package.json in particular: the artifact carries a
  // GENERATED marker instead, never this one.
  await write(join(root, 'package.json'), '{"name":"tau","workspaces":["apps/*"],"devDependencies":{"eslint":"^9"}}\n')
  await write(join(root, 'src/index.ts'), 'export const x = 1\n')
  await write(join(root, 'apps/core/src/index.ts'), 'export const y = 1\n')
  await write(join(root, '.git/HEAD'), 'ref: refs/heads/main\n')
  await write(join(root, 'bun.lock'), '{}\n')
  await write(join(root, 'patches/thing.patch'), 'diff\n')
  return root
}

interface FakeRun {
  run: Run
  calls: string[][]
}

/**
 * Wraps {@link defaultRun}: `bun install` is faked (it would otherwise hit the
 * network) by writing a marker `node_modules` — including a symlink, so the
 * staging copy's symlink materialization is exercised on the pruned tree too.
 * `tar` (and anything else) runs for real. `migrateResult` overrides what the
 * smoke run's `bun …/migrate.js` reports.
 */
function makeRun(opts: { migrateResult?: RunResult; extensionResult?: RunResult } = {}): FakeRun {
  const calls: string[][] = []
  const run: Run = async (cmd, runOpts) => {
    calls.push(cmd)
    if (cmd[0] === 'bun' && cmd[1] === 'install') {
      const nodeModules = join(runOpts.cwd!, 'node_modules')
      await write(join(nodeModules, 'bun-pty', 'index.js'), 'pruned bun-pty\n')
      await mkdir(join(nodeModules, '.bin'), { recursive: true })
      await symlink('../bun-pty/index.js', join(nodeModules, '.bin', 'pty-link'))
      return { exitCode: 0, stdout: '4 packages installed\n', stderr: '' }
    }
    if (cmd[0] === 'bun' && cmd[1]?.endsWith('migrate.js')) {
      return (
        opts.migrateResult ?? { exitCode: 1, stdout: '', stderr: 'Error: Migration refused because no explicit…\n' }
      )
    }
    if (cmd[0] === 'bun' && cmd[1]?.endsWith('smoke-configured-extensions.js')) {
      return (
        opts.extensionResult ?? {
          exitCode: 0,
          stdout: 'configured extension smoke: PASS (code-ast)\n',
          stderr: '',
        }
      )
    }
    return defaultRun(cmd, runOpts)
  }
  return { run, calls }
}

async function assemble(
  overrides: Partial<Parameters<typeof assembleCoreArtifact>[0]> = {},
  fake: FakeRun = makeRun()
): Promise<{ checkoutRoot: string; outDir: string; result: Awaited<ReturnType<typeof assembleCoreArtifact>> }> {
  const checkoutRoot = (overrides.checkoutRoot as string | undefined) ?? (await makeCheckout())
  const outDir = (overrides.outDir as string | undefined) ?? (await mkdtemp(join(tmpdir(), 'assemble-out-')))
  const result = await assembleCoreArtifact({
    checkoutRoot,
    outDir,
    commit: COMMIT,
    commitDate: COMMIT_DATE,
    builder: 'test:builder',
    run: fake.run,
    log: () => {},
    ...overrides,
  })
  return { checkoutRoot, outDir, result }
}

/** Extract the produced tarball and return the path of its single root dir. */
async function extract(tarballPath: string): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), 'assemble-extract-'))
  const res = await defaultRun(['tar', '-xzf', tarballPath, '-C', dir], {})
  expect(res.exitCode).toBe(0)
  return join(dir, `tau-core-${COMMIT}`)
}

describe('assembleCoreArtifact', () => {
  it('stages exactly the spec layout, honouring exclusions, and tars it under tau-core-<sha>/', async () => {
    const { result } = await assemble()
    const tree = await extract(result.tarballPath)

    const files = Object.keys(await computeFilesMap(tree)).sort()
    expect(files).toEqual(
      [
        'apps/cli/dist/skills/tau-memory/SKILL.md',
        'apps/cli/dist/tau.js',
        'apps/core/dist/box-control.js',
        'apps/core/dist/index.js',
        'apps/core/dist/migrate.js',
        'apps/core/dist/smoke-configured-extensions.js',
        'apps/core/dist/worker.js',
        'apps/core/docker-sandbox/command-identity.json',
        'apps/core/docker-sandbox/devbox.json',
        'apps/core/docker-sandbox/git-credential-github-token',
        'apps/core/docs-dist/index.html',
        'apps/core/docs-dist/404.html',
        'apps/core/docs-dist/pagefind/pagefind.js',
        'apps/core/drizzle/0000_init.sql',
        'apps/core/drizzle/meta/_journal.json',
        'apps/web/dist/assets/app.js',
        'apps/web/dist/index.html',
        'config/agent/agent.md',
        'config/agent/extensions/code-ast/index.ts',
        'config/agent/extensions/code-ast/package.json',
        'config/agent/extensions/code-ast/node_modules/typescript/package.json',
        'machine/bootstrap.sh',
        'machine/box-provision.sh',
        'machine/librust_pty.so',
        'machine/server.js',
        'machine/tau.js',
        'node_modules/bun-pty/index.js',
        'package.json',
      ].sort()
    )
    // Resolve from the extracted release, never the builder checkout.
    const app = new Hono()
    mountCoreDocs(app, resolveCoreDocsDist(join(tree, 'apps/core/dist')))
    expect(await (await app.request('/docs/')).text()).toBe('docs home')
    expect(await (await app.request('/docs/pagefind/pagefind.js')).text()).toBe('search')
    expect((await app.request('/docs/unknown/')).status).toBe(404)
    // The executable bit survives the copy (tau.js is exec'd on the box).
    expect((await stat(join(tree, 'apps/cli/dist/tau.js'))).mode & 0o111).not.toBe(0)
  })

  it('names the tarball for the native build target and returns the trailer values', async () => {
    const { outDir, result } = await assemble()
    expect(result.sha).toBe(COMMIT)
    expect(result.tarballPath).toBe(join(outDir, `tau-core-${COMMIT}-${artifactPlatform()}.tar.gz`))
    expect((await stat(result.tarballPath)).size).toBeGreaterThan(0)
    expect(result.digest).toMatch(/^sha256:[0-9a-f]{64}$/)
    expect((await readdir(outDir)).sort()).toEqual(['artifact.json', `tau-core-${COMMIT}-${artifactPlatform()}.tar.gz`])
  })

  it('writes an artifact.json whose digest matches a recomputation over the extracted tree', async () => {
    const { outDir, result } = await assemble()
    const tree = await extract(result.tarballPath)

    const manifest = JSON.parse(await readFile(join(outDir, 'artifact.json'), 'utf8'))
    const recomputed = await computeFilesMap(tree)
    expect(manifest.files).toEqual(recomputed)
    expect(manifest.digest).toBe(computeDigest(recomputed))
    expect(manifest.digest).toBe(result.digest)
    expect(manifest.schema).toBe(1)
    expect(manifest.commit).toBe(COMMIT)
    expect(manifest.commitDate).toBe(COMMIT_DATE)
    expect(manifest.bun).toBe('1.3.8')
    expect(manifest.platform).toBe(artifactPlatform())
    expect(manifest.builder).toBe('test:builder')
    // The in-tree copy is byte-identical to the one beside the tarball.
    expect(await readFile(join(tree, 'artifact.json'), 'utf8')).toBe(
      await readFile(join(outDir, 'artifact.json'), 'utf8')
    )
  })

  it('emits a lexicographically key-sorted files map', async () => {
    const { outDir } = await assemble()
    const manifest = JSON.parse(await readFile(join(outDir, 'artifact.json'), 'utf8'))
    const keys = Object.keys(manifest.files)
    expect(keys).toEqual([...keys].sort())
    expect(keys.length).toBeGreaterThan(1)
  })

  it('writes an artifact.sig over the artifact.json bytes that verifies with the public key', async () => {
    const { publicKey, privateKey } = generateKeyPairSync('ed25519')
    const keyDir = await mkdtemp(join(tmpdir(), 'assemble-key-'))
    const signKeyPath = join(keyDir, 'artifact.key')
    await writeFile(signKeyPath, privateKey.export({ type: 'pkcs8', format: 'pem' }) as string)

    const { outDir, result } = await assemble({ signKeyPath })

    expect(result.sigPath).toBe(join(outDir, 'artifact.sig'))
    const sig = (await readFile(join(outDir, 'artifact.sig'), 'utf8')).trim()
    expect(sig.split('\n')).toHaveLength(1)
    const manifestBytes = await readFile(join(outDir, 'artifact.json'))
    const publicKeyPem = publicKey.export({ type: 'spki', format: 'pem' }) as string
    expect(verifyManifestSignature(manifestBytes, sig, publicKeyPem)).toBe(true)
  })

  it('prunes node_modules from a scratch manifest pinning exactly the runtime externals', async () => {
    const fake = makeRun()
    let scratchPackageJson = ''
    const wrapped: FakeRun = {
      calls: fake.calls,
      run: async (cmd, opts) => {
        if (cmd[0] === 'bun' && cmd[1] === 'install') {
          scratchPackageJson = await readFile(join(opts.cwd!, 'package.json'), 'utf8')
        }
        return fake.run(cmd, opts)
      },
    }
    await assemble({}, wrapped)

    expect(JSON.parse(scratchPackageJson).dependencies).toEqual({
      'bun-pty': '0.4.8',
      'playwright-core': '1.58.2',
      jsdom: '26.0.0',
      '@silvia-odwyer/photon-node': '0.3.3',
      '@google-cloud/text-to-speech': '6.4.0',
      '@aws-sdk/client-ses': '3.1005.0',
      '@aws-sdk/client-s3': '3.999.0',
    })
    const install = fake.calls.find((c) => c[0] === 'bun' && c[1] === 'install')
    expect(install).toEqual(['bun', 'install', '--production', '--ignore-scripts'])
  })

  it('fails, naming the path, when a layout directory is missing from the checkout', async () => {
    const checkoutRoot = await makeCheckout()
    await rm(join(checkoutRoot, 'apps/web/dist'), { recursive: true })
    await expect(assemble({ checkoutRoot })).rejects.toThrow(/apps\/web\/dist/)
  })

  it('fails, naming the package, when an external is not installed in the checkout', async () => {
    const checkoutRoot = await makeCheckout()
    await rm(join(checkoutRoot, 'node_modules/bun-pty'), { recursive: true })
    await expect(assemble({ checkoutRoot })).rejects.toThrow(/bun-pty/)
  })

  it('generates a root package.json marker so the shipped web UI resolver finds the artifact root', async () => {
    const { result } = await assemble()
    const tree = await extract(result.tarballPath)

    // Generated, NOT copied: the fixture checkout's own root package.json has
    // devDependencies and a real workspaces list.
    const marker = await readFile(join(tree, 'package.json'), 'utf8')
    expect(marker.trim()).toBe('{"name":"ficus","private":true,"workspaces":[]}')

    // apps/core/src/lib/web-dist.ts walks UP from the running bundle's
    // directory looking for a package.json named "ficus" or "tau" (or carrying
    // a workspaces array) and then expects <root>/apps/web/dist. Without the
    // marker the search falls off the top of the tree and the API mounts no
    // web UI at all. This mirrors that walk.
    let dir = join(tree, 'apps/core/dist')
    let found: string | undefined
    for (let i = 0; i < 10 && found === undefined; i++) {
      const candidate = join(dir, 'package.json')
      if (await pathExists(candidate)) {
        const json = JSON.parse(await readFile(candidate, 'utf8'))
        if (CORE_ROOT_PACKAGE_NAMES.includes(json.name) || Array.isArray(json.workspaces)) found = dir
      }
      const parent = dirname(dir)
      if (parent === dir) break
      dir = parent
    }
    expect(found).toBe(tree)
    expect(await pathExists(join(found!, 'apps/web/dist/index.html'))).toBe(true)
  })

  it('marks the artifact as a Ficus release (the toolkit keys the env rename on it)', async () => {
    const rootPackage = JSON.parse(await readFile(join(import.meta.dir, '../../../../../package.json'), 'utf8'))
    expect(JSON.parse(GENERATED_ROOT_MARKER).name).toBe(rootPackage.name)
    const { result } = await assemble()
    const tree = await extract(result.tarballPath)
    expect(JSON.parse(await readFile(join(tree, 'package.json'), 'utf8')).name).toBe('ficus')
    expect(JSON.parse(await readFile(result.manifestPath, 'utf8')).envPrefix).toBe('FICUS')
    expect(JSON.parse(await readFile(join(tree, 'artifact.json'), 'utf8')).envPrefix).toBe('FICUS')
  })

  it('drops node_modules/.bin directories, whose shims cannot survive materialization', async () => {
    const { result } = await assemble()
    const tree = await extract(result.tarballPath)

    expect(await pathExists(join(tree, 'node_modules/.bin'))).toBe(false)
    expect(await pathExists(join(tree, 'config/agent/extensions/code-ast/node_modules/.bin'))).toBe(false)
    // The packages themselves still ship.
    expect(await pathExists(join(tree, 'node_modules/bun-pty/index.js'))).toBe(true)
    expect(await pathExists(join(tree, 'config/agent/extensions/code-ast/node_modules/typescript/package.json'))).toBe(
      true
    )
  })

  it('fails, naming the extension, when a config extension has no installed node_modules', async () => {
    const checkoutRoot = await makeCheckout()
    await rm(join(checkoutRoot, 'config/agent/extensions/code-ast/node_modules'), { recursive: true })
    await expect(assemble({ checkoutRoot })).rejects.toThrow(/code-ast/)
  })

  it('fails, naming the file, when apps/core/dist holds a .js output the layout does not carry', async () => {
    const checkoutRoot = await makeCheckout()
    await write(join(checkoutRoot, 'apps/core/dist/fourth.js'), 'a new entrypoint nobody told us about\n')
    await expect(assemble({ checkoutRoot })).rejects.toThrow(/fourth\.js/)
  })

  it('smoke: loads configured extensions through the bundled production loader', async () => {
    const fake = makeRun()
    const { result } = await assemble({ smoke: true }, fake)

    expect(result.smoke).toEqual({ migrateExitCode: 1, verifiedFiles: 28 })
    expect(fake.calls).toContainEqual([
      'bun',
      expect.stringMatching(/apps\/core\/dist\/smoke-configured-extensions\.js$/),
      expect.stringMatching(/config\/agent\/extensions$/),
      expect.stringMatching(/apps\/core$/),
    ])
  })

  it('smoke: fails with the extension name and root resolution error when a host dependency is absent', async () => {
    const fake = makeRun({
      extensionResult: {
        exitCode: 1,
        stdout: '',
        stderr:
          "Error: configured extension code-ast failed to load: Cannot find package 'typebox' from root node_modules\n",
      },
    })

    await expect(assemble({ smoke: true }, fake)).rejects.toThrow(/code-ast.*Cannot find package 'typebox'/s)
  })

  it('smoke: fails when the extracted migrate bundle exits zero (the guard did not refuse)', async () => {
    const fake = makeRun({ migrateResult: { exitCode: 0, stdout: 'migrated!\n', stderr: '' } })
    await expect(assemble({ smoke: true }, fake)).rejects.toThrow(/migrate/i)
  })

  it('smoke: refuses a dist file that embeds the builder checkout path (a baked __dirname)', async () => {
    // The live shape: bun inlined the BUILDER's absolute node_modules path
    // into the bundle (jsdom's boot-time stylesheet read), which works on the
    // builder — where the path exists — and crashes on every box.
    const checkoutRoot = await makeCheckout()
    await write(
      join(checkoutRoot, 'apps/core/dist/index.js'),
      `var css = readFileSync("${checkoutRoot}/node_modules/jsdom/lib/jsdom/browser/default-stylesheet.css")\n`
    )
    await expect(assemble({ checkoutRoot, smoke: true })).rejects.toThrow(/builder checkout path/)
  })
})

describe('formatTrailer', () => {
  it('prints the three machine-readable keys with an absolute tarball path', () => {
    const lines = formatTrailer({
      sha: COMMIT,
      digest: 'sha256:abc',
      tarballPath: '/out/tau-core-x-linux-x64.tar.gz',
      manifestPath: '/out/artifact.json',
    }).split('\n')
    expect(lines).toEqual([
      `CORE_ARTIFACT_SHA=${COMMIT}`,
      'CORE_ARTIFACT_DIGEST=sha256:abc',
      'CORE_ARTIFACT_TARBALL=/out/tau-core-x-linux-x64.tar.gz',
    ])
  })
})

describe('build-core-artifact.sh', () => {
  const scriptPath = join(import.meta.dir, '../../../../../scripts/artifact/build-core-artifact.sh')

  it('sets a headless build environment the caller cannot be trusted to provide', async () => {
    const script = await readFile(scriptPath, 'utf8')
    // localhost, so a build that somehow reaches the DB fails fast instead of
    // hanging on an unroutable host.
    expect(script).toContain('postgres://build:build@localhost:5432/build')
    expect(script).toContain('unset FICUS_TEST_MODE')
    expect(script).toContain('unset FICUS_ROOT')
    expect(script).toContain('unset FICUS_REPO_ROOT')
  })

  it('installs reproducibly and prebuilds the machine bundles as a subprocess', async () => {
    const script = await readFile(scriptPath, 'utf8')
    expect(script).toContain('--frozen-lockfile')
    expect(script).toContain('extensions:install')
    expect(script).toMatch(/rm -rf "\$REPO_ROOT\/machine"/)
    expect(script).toMatch(/bun\s+scripts\/artifact\/build-machine-bundles\.ts/)
  })

  it('fails the build when the assembler does not emit all three trailer keys', async () => {
    const script = await readFile(scriptPath, 'utf8')
    // Pin the VERIFICATION LOOP, not the header comment (which also lists the
    // three keys and would keep a deleted check looking present).
    const loop = script.slice(script.indexOf('the assembler did not emit') - 400)
    expect(loop).toContain("for key in 'CORE_ARTIFACT_SHA=' 'CORE_ARTIFACT_DIGEST=' 'CORE_ARTIFACT_TARBALL='")
    expect(loop).toMatch(/grep -q "\^\$\{key\}" "\$TRAILER_FILE"/)
    expect(loop).toContain('the assembler did not emit')
  })

  it('installs config extensions from their committed lockfiles', async () => {
    const rootPackage = JSON.parse(await readFile(join(import.meta.dir, '../../../../../package.json'), 'utf8'))
    expect(rootPackage.scripts['extensions:install']).toContain('bun install --frozen-lockfile')
  })

  it('always installs the config extensions, even with --skip-install', async () => {
    const script = await readFile(scriptPath, 'utf8')
    // extensions:install must NOT sit inside the `if SKIP_INSTALL` block: CI
    // skips the root install, and its cached --ignore-scripts install never
    // populated config/agent/extensions/*/node_modules.
    const skipBlock = script.slice(script.indexOf('if [[ "$SKIP_INSTALL" -eq 0 ]]; then'))
    const blockEnd = skipBlock.indexOf('\nfi\n')
    expect(skipBlock.slice(0, blockEnd)).not.toContain('extensions:install')
    expect(script).toContain('extensions:install')
  })
})
