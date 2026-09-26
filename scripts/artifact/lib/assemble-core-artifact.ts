#!/usr/bin/env bun
/**
 * Assemble a core release artifact from an already-built checkout.
 *
 * This is the second half of `scripts/artifact/build-core-artifact.sh`: the
 * shell script owns the environment, the prerequisite checks and the three
 * builds; everything structural — staging, copying, pruning `node_modules`,
 * the manifest, the signature, the tarball and the optional smoke — lives
 * here, where it is testable.
 *
 * Layout produced (spec §3/§4.1,
 * `docs/history/superpowers/specs/2026-08-20-prebuilt-core-artifacts-design.md`):
 *
 *   tau-core-<sha>/
 *     artifact.json
 *     apps/core/dist/{index,worker,migrate}.js
 *     apps/core/drizzle/…
 *     apps/core/docker-sandbox/{devbox.json,git-credential-github-token,command-identity.json}
 *     apps/web/dist/…   apps/cli/dist/…   config/…   machine/…
 *     node_modules/…    (pruned: the runtime externals + their deps)
 *
 * Two ruled deviations from the spec text:
 *  - **gzip, not zstd.** The spec names `.tar.zst`; `zstd` is not present on
 *    every builder or tenant box, while gzip is in every base image and in
 *    bsdtar/GNU tar alike. The compression codec is not part of the artifact's
 *    identity (the digest is over the extracted files), so this costs a few MB
 *    of transfer and nothing else.
 *  - **`node_modules/.bin` is dropped.** Those entries are symlinks to CLI
 *    shims that resolve `require`/imports relative to their own path, so a
 *    materialized copy is a broken program pretending to be a working one.
 *    Nothing in a running core invokes a `.bin` shim (the runtime externals
 *    are imported as modules), so the honest move is to omit them.
 *  - **Symlinks that remain are materialized**, not preserved. `bun install` and
 *    `extensions:install` leave `node_modules/.bin/*` symlinks behind, and the
 *    manifest walker refuses symlinks on purpose (a link's target can drift
 *    without the digest changing). Each link is copied as a regular file with
 *    its target's bytes and mode, so the tree stays fully content-addressed.
 */
import { chmod, copyFile, mkdir, mkdtemp, readdir, readFile, rm, stat, writeFile } from 'node:fs/promises'
import { hostname, tmpdir } from 'node:os'
import { dirname, isAbsolute, join, resolve } from 'node:path'
import { artifactPlatform, buildManifest, computeFilesMap, signManifest, type CoreArtifactManifest } from './manifest'

export interface RunResult {
  exitCode: number
  stdout: string
  stderr: string
}

export interface RunOptions {
  cwd?: string
  /** Merged over `process.env`; an explicit `undefined` deletes the variable. */
  env?: Record<string, string | undefined>
}

/** Subprocess runner, injected so tests can stub `bun install` and the smoke run. */
export type Run = (cmd: string[], opts: RunOptions) => Promise<RunResult>

/** The real runner: spawn, capture both streams, never inherit stdio. */
export const defaultRun: Run = async (cmd, opts) => {
  const env: Record<string, string> = {}
  for (const [key, value] of Object.entries({ ...process.env, ...(opts.env ?? {}) })) {
    if (value !== undefined) env[key] = value
  }
  const proc = Bun.spawn(cmd, { cwd: opts.cwd, env, stdout: 'pipe', stderr: 'pipe' })
  const [stdout, stderr] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text()])
  return { exitCode: await proc.exited, stdout, stderr }
}

/**
 * The runtime externals `apps/core`'s build marks `--external`: they are not
 * bundled into `dist/`, so the artifact must carry them (spec §7.4). Pinned to
 * whatever the checkout resolved, never to a range.
 */
export const RUNTIME_EXTERNALS = [
  'bun-pty',
  'playwright-core',
  // Everything below is external because bundling it bakes the BUILDER's
  // absolute node_modules path into the bundle (bun inlines CJS __dirname),
  // and these packages read real files through that path at runtime — jsdom
  // its default stylesheet at boot (the crash that took down the first
  // artifact canary), photon its wasm, text-to-speech (google-gax/grpc) its
  // protos, the AWS SDKs their version metadata. The smoke's baked-path scan
  // enforces that this list stays sufficient.
  'jsdom',
  '@silvia-odwyer/photon-node',
  '@google-cloud/text-to-speech',
  '@aws-sdk/client-ses',
  '@aws-sdk/client-s3',
] as const

/**
 * The artifact's root `package.json`, generated rather than copied. It names the
 * tree `ficus` — the checkout root's own package name — so the release is
 * recognizably a post-rename Ficus build to anything that keys on the root
 * name (the web UI resolver, the host toolkit's env-prefix fallback).
 */
export const GENERATED_ROOT_MARKER = '{"name":"ficus","private":true,"workspaces":[]}\n'

/**
 * Everything copied out of the checkout, in artifact-relative order. `file`
 * entries are copied individually because their directory holds things the
 * artifact must not carry (`dist/tsconfig.tsbuildinfo`, the sandbox
 * `Dockerfile`); `dir` entries are copied whole.
 */
const LAYOUT: { path: string; kind: 'file' | 'dir' | 'generated'; contents?: string }[] = [
  // GENERATED, never copied from the checkout. `apps/core/src/lib/web-dist.ts`
  // finds the web UI by walking up from the running bundle until it hits a
  // package.json named "ficus" or "tau" (`CORE_ROOT_PACKAGE_NAMES`, or one
  // carrying a `workspaces` array) and then looking for <root>/apps/web/dist.
  // An artifact with no package.json anywhere fails that walk, `maybeMountWebUi` mounts nothing, and the box
  // comes up with a healthy API and a 404 for every page. The marker is
  // deliberately minimal — it is a root anchor, not a manifest of anything.
  { path: 'package.json', kind: 'generated', contents: GENERATED_ROOT_MARKER },
  { path: 'apps/core/dist/index.js', kind: 'file' },
  { path: 'apps/core/dist/worker.js', kind: 'file' },
  { path: 'apps/core/dist/migrate.js', kind: 'file' },
  { path: 'apps/core/dist/smoke-configured-extensions.js', kind: 'file' },
  // Operator box control (platform scripts/box-control.ts runs it on the tenant VM).
  { path: 'apps/core/dist/box-control.js', kind: 'file' },
  { path: 'apps/core/drizzle', kind: 'dir' },
  { path: 'apps/core/docker-sandbox/devbox.json', kind: 'file' },
  { path: 'apps/core/docker-sandbox/git-credential-github-token', kind: 'file' },
  { path: 'apps/core/docker-sandbox/command-identity.json', kind: 'file' },
  { path: 'apps/core/docs-dist', kind: 'dir' },
  { path: 'apps/web/dist', kind: 'dir' },
  { path: 'apps/cli/dist', kind: 'dir' },
  // The WHOLE config tree, including `agent/extensions/*/node_modules` from
  // `extensions:install` — it is code, and the box never installs anything.
  { path: 'config', kind: 'dir' },
  // Prebuilt machine-host bundles (build-machine-bundles.ts wrote these).
  { path: 'machine', kind: 'dir' },
]

/** Junk the host filesystem sprinkles in that must never reach the digest. */
const EXCLUDED_NAMES = new Set(['.DS_Store'])

export interface AssembleCoreArtifactOptions {
  /** Repository root of a BUILT checkout. */
  checkoutRoot: string
  /** Where the tarball, `artifact.json` and `artifact.sig` are written. */
  outDir: string
  /** Full 40-hex commit the checkout is at. */
  commit: string
  /** ISO commit date; read from `git show -s --format=%cI <commit>` when omitted. */
  commitDate?: string
  /** Bun version to record; read from `<checkoutRoot>/.bun-version` when omitted. */
  bunVersion?: string
  /** Manifest `builder` label; defaults to `local:<hostname>`. */
  builder?: string
  /** Ed25519 PKCS8 PEM private key; when given, `artifact.sig` is written. */
  signKeyPath?: string
  /** Extract the tarball and prove the bundle runs (see {@link runSmoke}). */
  smoke?: boolean
  run?: Run
  log?: (message: string) => void
}

export interface SmokeResult {
  /** Exit code of the extracted `dist/migrate.js` (must be non-zero: it refuses). */
  migrateExitCode: number
  /** Number of manifest entries re-hashed against the extracted tree. */
  verifiedFiles: number
}

export interface AssembleCoreArtifactResult {
  sha: string
  digest: string
  /** Absolute path of the tarball. */
  tarballPath: string
  manifestPath: string
  sigPath?: string
  smoke?: SmokeResult
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await stat(path)
    return true
  } catch {
    return false
  }
}

/**
 * Copy one file, following it if it is a symlink and preserving its mode —
 * `apps/cli/dist/tau.js`, the machine scripts and the `.bin` shims are all
 * executed on the box, so the exec bit is load-bearing.
 */
async function copyRegularFile(src: string, dest: string): Promise<void> {
  let stats
  try {
    stats = await stat(src)
  } catch (error) {
    throw new Error(`cannot stage ${src} (broken symlink?): ${String(error)}`)
  }
  await mkdir(dirname(dest), { recursive: true })
  await copyFile(src, dest)
  await chmod(dest, stats.mode & 0o777)
}

/** Recursively copy `src` into `dest`, materializing symlinks and dropping junk. */
async function copyTree(src: string, dest: string): Promise<void> {
  await mkdir(dest, { recursive: true })
  for (const entry of await readdir(src, { withFileTypes: true })) {
    if (EXCLUDED_NAMES.has(entry.name)) continue
    // See the header: a `.bin` shim materialized away from its own directory
    // is broken, and nothing at runtime calls one.
    if (entry.name === '.bin' && entry.isDirectory()) continue
    const from = join(src, entry.name)
    const to = join(dest, entry.name)
    let isDirectory = entry.isDirectory()
    if (entry.isSymbolicLink()) {
      try {
        isDirectory = (await stat(from)).isDirectory()
      } catch (error) {
        throw new Error(`cannot stage symlink ${from} (broken target?): ${String(error)}`)
      }
    }
    if (isDirectory) await copyTree(from, to)
    else await copyRegularFile(from, to)
  }
}

/**
 * Every `config/agent/extensions/<name>` must arrive with its dependencies
 * already installed: the box never runs `bun install`, so an extension whose
 * `node_modules` is missing here is an extension that is silently dead in
 * production. `extensions:install` is what fills these in.
 */
async function assertExtensionsInstalled(checkoutRoot: string): Promise<void> {
  const extensionsDir = join(checkoutRoot, 'config/agent/extensions')
  if (!(await pathExists(extensionsDir))) return
  for (const entry of await readdir(extensionsDir, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue
    const extensionRoot = join(extensionsDir, entry.name)
    if (!(await pathExists(join(extensionRoot, 'package.json')))) continue
    if (!(await pathExists(join(extensionRoot, 'node_modules')))) {
      throw new Error(
        `config extension ${entry.name} has a package.json but no installed node_modules (${join(extensionRoot, 'node_modules')}) — run \`bun run extensions:install\` before assembling`
      )
    }
  }
}

/**
 * `apps/core/dist` is copied file by file, so a NEW build entrypoint would be
 * silently left out of every artifact until something 404s in production.
 * Any top-level `.js` in dist that the layout does not carry is a hard error.
 * Non-`.js` build detritus (`tsconfig.tsbuildinfo`, a stale nested `apps/`
 * dir) is ignored — it is not something core loads.
 */
async function assertNoStrayCoreBundles(checkoutRoot: string): Promise<void> {
  const distDir = join(checkoutRoot, 'apps/core/dist')
  const carried = new Set(
    LAYOUT.filter((entry) => entry.path.startsWith('apps/core/dist/')).map((entry) =>
      entry.path.slice('apps/core/dist/'.length)
    )
  )
  for (const entry of await readdir(distDir, { withFileTypes: true })) {
    if (!entry.isFile() || !entry.name.endsWith('.js')) continue
    if (!carried.has(entry.name)) {
      throw new Error(
        `apps/core/dist/${entry.name} is a build output the artifact layout does not carry — add it to LAYOUT (or delete the stale file) before assembling`
      )
    }
  }
}

/** Stage the layout, failing by name on the first missing piece. */
async function stageLayout(checkoutRoot: string, treeRoot: string): Promise<void> {
  for (const page of ['index.html', '404.html', 'pagefind/pagefind.js']) {
    const path = `apps/core/docs-dist/${page}`
    if (!(await pathExists(join(checkoutRoot, path))))
      throw new Error(`artifact layout is missing ${path} — run the Core build first`)
  }
  await assertExtensionsInstalled(checkoutRoot)
  await assertNoStrayCoreBundles(checkoutRoot)
  for (const entry of LAYOUT) {
    if (entry.kind === 'generated') {
      const dest = join(treeRoot, entry.path)
      await mkdir(dirname(dest), { recursive: true })
      await writeFile(dest, entry.contents!)
      continue
    }
    const src = join(checkoutRoot, entry.path)
    if (!(await pathExists(src))) {
      throw new Error(
        `artifact layout is missing ${entry.path} — expected at ${src}. Run the builds (and the machine-bundle prebuild) first.`
      )
    }
    const dest = join(treeRoot, entry.path)
    if (entry.kind === 'dir') await copyTree(src, dest)
    else await copyRegularFile(src, dest)
  }
}

/**
 * Build the pruned `node_modules`: a scratch package.json holding exactly the
 * runtime externals at the versions the checkout resolved, installed
 * `--production --ignore-scripts` in a temp dir, then copied into the tree.
 *
 * Copied rather than moved because the install leaves `.bin` symlinks behind
 * and {@link copyTree} is what materializes them (see the file header).
 */
async function stagePrunedNodeModules(
  checkoutRoot: string,
  treeRoot: string,
  run: Run,
  log: (message: string) => void
): Promise<void> {
  const dependencies: Record<string, string> = {}
  for (const pkg of RUNTIME_EXTERNALS) {
    const packageJsonPath = join(checkoutRoot, 'node_modules', pkg, 'package.json')
    if (!(await pathExists(packageJsonPath))) {
      throw new Error(
        `runtime external ${pkg} is not installed in the checkout (${packageJsonPath}); cannot pin its version for the pruned node_modules`
      )
    }
    const version = JSON.parse(await readFile(packageJsonPath, 'utf8')).version
    if (typeof version !== 'string' || version.length === 0) {
      throw new Error(`runtime external ${pkg} has no version in ${packageJsonPath}`)
    }
    dependencies[pkg] = version
  }

  const scratch = await mkdtemp(join(tmpdir(), 'tau-core-artifact-prune-'))
  try {
    await writeFile(
      join(scratch, 'package.json'),
      `${JSON.stringify({ name: 'tau-core-artifact-externals', version: '0.0.0', private: true, dependencies }, null, 2)}\n`
    )
    log(
      `pruned node_modules: installing ${Object.entries(dependencies)
        .map(([n, v]) => `${n}@${v}`)
        .join(' ')}`
    )
    const install = await run(['bun', 'install', '--production', '--ignore-scripts'], { cwd: scratch })
    if (install.exitCode !== 0) {
      throw new Error(`pruned bun install failed (exit ${install.exitCode}): ${install.stderr || install.stdout}`)
    }
    const installed = join(scratch, 'node_modules')
    if (!(await pathExists(installed))) {
      throw new Error(`pruned bun install produced no node_modules at ${installed}`)
    }
    await copyTree(installed, join(treeRoot, 'node_modules'))
  } finally {
    await rm(scratch, { recursive: true, force: true })
  }
}

/**
 * Prove the artifact is usable without a database: extract it, run the bundled
 * migration runner with no `FICUS_MIGRATE_LIVE` and no `DATABASE_URL` (its guard
 * must refuse — which it can only do if the bundle loaded and executed), then
 * re-hash every file in the manifest against the extracted tree.
 */
async function runSmoke(opts: {
  tarballPath: string
  commit: string
  manifest: CoreArtifactManifest
  checkoutRoot: string
  run: Run
  log: (message: string) => void
}): Promise<SmokeResult> {
  const extractDir = await mkdtemp(join(tmpdir(), 'tau-core-artifact-smoke-'))
  try {
    const untar = await opts.run(['tar', '-xzf', opts.tarballPath, '-C', extractDir], {})
    if (untar.exitCode !== 0) throw new Error(`smoke: extracting the tarball failed: ${untar.stderr}`)
    const treeRoot = join(extractDir, `tau-core-${opts.commit}`)

    const migrate = await opts.run(['bun', join(treeRoot, 'apps/core/dist/migrate.js')], {
      cwd: join(treeRoot, 'apps/core'),
      // Both spellings (Ficus rename): the in-process bridge would promote an
      // inherited TAU_ name to FICUS_ and let the migration run.
      env: {
        DATABASE_URL: undefined,
        FICUS_MIGRATE_LIVE: undefined,
        FICUS_ROOT: undefined,
        TAU_MIGRATE_LIVE: undefined, // legacy-env
        TAU_ROOT: undefined, // legacy-env
      },
    })
    const output = `${migrate.stdout}\n${migrate.stderr}`
    if (migrate.exitCode === 0) {
      throw new Error(
        `smoke: the bundled migrate.js exited 0 without FICUS_MIGRATE_LIVE; its guard must refuse.\n${output}`
      )
    }
    if (!/refus/i.test(output)) {
      // Non-zero for some OTHER reason (a missing module, a syntax error)
      // would otherwise be mistaken for the guard doing its job.
      throw new Error(`smoke: the bundled migrate.js failed without refusing (exit ${migrate.exitCode}).\n${output}`)
    }

    // Exercise the same bundled Pi loader and host-module contract Core uses
    // at runtime. Running inside the extracted tree prevents the builder checkout
    // from satisfying a missing host dependency through monorepo hoisting.
    const extensionsDir = join(treeRoot, 'config/agent/extensions')
    const coreDir = join(treeRoot, 'apps/core')
    const extensionSmoke = await opts.run(
      ['bun', join(coreDir, 'dist/smoke-configured-extensions.js'), extensionsDir, coreDir],
      { cwd: coreDir, env: { FICUS_ROOT: treeRoot } }
    )
    if (extensionSmoke.exitCode !== 0) {
      throw new Error(
        `smoke: configured extensions failed to load (exit ${extensionSmoke.exitCode}).\n${extensionSmoke.stdout}\n${extensionSmoke.stderr}`
      )
    }

    const actual = await computeFilesMap(treeRoot)
    const expected = opts.manifest.files
    for (const [relPath, hash] of Object.entries(expected)) {
      if (actual[relPath] === undefined) throw new Error(`smoke: ${relPath} is missing from the extracted artifact`)
      if (actual[relPath] !== hash) throw new Error(`smoke: ${relPath} does not match the manifest hash`)
    }
    for (const relPath of Object.keys(actual)) {
      if (expected[relPath] === undefined) throw new Error(`smoke: ${relPath} is in the artifact but not the manifest`)
    }

    // A bundled module that references CommonJS `__dirname`/`__filename` gets
    // the BUILDER's absolute path inlined by bun. Code that later reads files
    // through that path works on the builder — the path exists there, which is
    // exactly why this smoke could not see it — and crashes on every box
    // (live-hit: jsdom's boot-time default-stylesheet read took down the
    // first artifact canary). Refuse any shipped bundle that embeds the
    // builder checkout path.
    const needle = Buffer.from(opts.checkoutRoot)
    for (const relPath of Object.keys(expected)) {
      if (!/\/dist\//.test(relPath)) continue
      const content = await readFile(join(treeRoot, relPath))
      if (content.includes(needle)) {
        throw new Error(
          `smoke: ${relPath} embeds the builder checkout path (${opts.checkoutRoot}) — a baked __dirname/__filename; this bundle would crash anywhere but the builder`
        )
      }
    }

    opts.log(
      `smoke: PASS (migrate refused with exit ${migrate.exitCode}, ${Object.keys(expected).length} files verified)`
    )
    return { migrateExitCode: migrate.exitCode, verifiedFiles: Object.keys(expected).length }
  } finally {
    await rm(extractDir, { recursive: true, force: true })
  }
}

/** The machine-readable trailer both CI and the control plane parse. */
export function formatTrailer(result: {
  sha: string
  digest: string
  tarballPath: string
  manifestPath: string
}): string {
  return [
    `CORE_ARTIFACT_SHA=${result.sha}`,
    `CORE_ARTIFACT_DIGEST=${result.digest}`,
    `CORE_ARTIFACT_TARBALL=${result.tarballPath}`,
  ].join('\n')
}

export async function assembleCoreArtifact(opts: AssembleCoreArtifactOptions): Promise<AssembleCoreArtifactResult> {
  const run = opts.run ?? defaultRun
  const log = opts.log ?? ((message: string) => console.error(`[assemble] ${message}`))
  const checkoutRoot = resolve(opts.checkoutRoot)
  const outDir = resolve(opts.outDir)
  const commit = opts.commit
  const platform = artifactPlatform()

  const bunVersion = opts.bunVersion ?? (await readFile(join(checkoutRoot, '.bun-version'), 'utf8')).trim()
  let commitDate = opts.commitDate
  if (commitDate === undefined) {
    const shown = await run(['git', 'show', '-s', '--format=%cI', commit], { cwd: checkoutRoot })
    if (shown.exitCode !== 0) throw new Error(`cannot read the commit date for ${commit}: ${shown.stderr}`)
    commitDate = shown.stdout.trim()
    if (commitDate.length === 0) throw new Error(`git returned an empty commit date for ${commit}`)
  }

  const staging = await mkdtemp(join(tmpdir(), 'tau-core-artifact-stage-'))
  try {
    // A FRESH staging dir every run: the manifest walker signs whatever it
    // finds, so a reused directory would fold a previous run's leftovers into
    // this artifact's digest.
    const treeRoot = join(staging, `tau-core-${commit}`)
    await mkdir(treeRoot, { recursive: true })

    log(`staging tau-core-${commit} in ${staging}`)
    await stageLayout(checkoutRoot, treeRoot)
    for (const notice of ['LICENSE', 'THIRD_PARTY_NOTICES.md']) {
      if (await pathExists(join(checkoutRoot, notice)))
        await copyRegularFile(join(checkoutRoot, notice), join(treeRoot, notice))
    }
    await stagePrunedNodeModules(checkoutRoot, treeRoot, run, log)

    const manifest = await buildManifest({
      rootDir: treeRoot,
      commit,
      commitDate,
      bun: bunVersion,
      platform,
      builder: opts.builder ?? `local:${hostname()}`,
    })
    const manifestJson = `${JSON.stringify(manifest, null, 2)}\n`

    // Written into the tree as well as beside the tarball: the box reads
    // `current/artifact.json` to report what it is running. buildManifest
    // excludes a root-level artifact.json from its own files map, so writing
    // it after the walk is exactly right.
    await writeFile(join(treeRoot, 'artifact.json'), manifestJson)

    await mkdir(outDir, { recursive: true })
    const manifestPath = join(outDir, 'artifact.json')
    await writeFile(manifestPath, manifestJson)

    let sigPath: string | undefined
    if (opts.signKeyPath) {
      const signature = signManifest(new TextEncoder().encode(manifestJson), await readFile(opts.signKeyPath, 'utf8'))
      sigPath = join(outDir, 'artifact.sig')
      await writeFile(sigPath, `${signature}\n`)
      log(`signed artifact.json -> ${sigPath}`)
    }

    const tarballPath = join(outDir, `tau-core-${commit}-${platform}.tar.gz`)
    const tar = await run(['tar', '-C', staging, '-czf', tarballPath, `tau-core-${commit}`], {})
    if (tar.exitCode !== 0) throw new Error(`tar failed (exit ${tar.exitCode}): ${tar.stderr}`)
    log(`wrote ${tarballPath}`)

    const result: AssembleCoreArtifactResult = {
      sha: commit,
      digest: manifest.digest,
      tarballPath,
      manifestPath,
      ...(sigPath ? { sigPath } : {}),
    }
    if (opts.smoke) {
      result.smoke = await runSmoke({ tarballPath, commit, manifest, checkoutRoot, run, log })
    }
    return result
  } finally {
    await rm(staging, { recursive: true, force: true })
  }
}

function requireFlag(argv: string[], name: string): string {
  const index = argv.indexOf(name)
  if (index === -1 || argv[index + 1] === undefined) {
    throw new Error(`missing required flag ${name}`)
  }
  return argv[index + 1]!
}

function optionalFlag(argv: string[], name: string): string | undefined {
  const index = argv.indexOf(name)
  return index === -1 ? undefined : argv[index + 1]
}

if (import.meta.main) {
  const argv = process.argv.slice(2)
  const checkoutRoot = optionalFlag(argv, '--checkout') ?? process.cwd()
  const outDirArg = requireFlag(argv, '--out-dir')
  const result = await assembleCoreArtifact({
    checkoutRoot,
    outDir: isAbsolute(outDirArg) ? outDirArg : resolve(process.cwd(), outDirArg),
    commit: requireFlag(argv, '--commit'),
    commitDate: optionalFlag(argv, '--commit-date'),
    builder: optionalFlag(argv, '--builder'),
    signKeyPath: optionalFlag(argv, '--sign-key'),
    smoke: argv.includes('--smoke'),
  })
  // Progress goes to stderr (see `log`); stdout carries ONLY the trailer, so a
  // caller can consume it whole.
  console.log(formatTrailer(result))
}
