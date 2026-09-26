# tau setup toolkit

Takes a fresh host from **nothing → a running tau** whose only remaining step
is a human opening a URL and creating the first admin passkey. Config-driven,
idempotent (every script is safe to re-run), and headless-friendly — this is
the per-tenant provisioning primitive a future cloud control-plane calls.

```
scripts/setup/
  tau-setup.example.yaml         the TENANT config contract (fully commented)
  setup-host.sh                  ON-TARGET primitive: runs ON a fresh Ubuntu 24.04 host
  upgrade-host.sh                ON-TARGET primitive: moves an ALREADY SET UP host to another
                                 source ref (sync → build core+web → migrate → restart). Needs
                                 no secrets — the host's .env already has them. Driven by the
                                 control plane's `upgrade` job, also runnable by hand.
  provision.sh                   ORCHESTRATOR: VM (exe, hetzner, or digitalocean) → setup-host.sh over SSH
  provision-exe.sh               compat shim → provision.sh (kept for old bookmarks/muscle memory)
  seed.sh                        idempotent API seeding (called by setup-host.sh,
                                 also usable standalone against a running instance)
  tau-backup.sh.tmpl             rendered → /usr/local/bin/tau-backup.sh (optional, backup.enabled)
  lib.sh                         shared helpers (logging, retry, config, http, git source, caddy, wizard)
  systemd/tau-api.service.tmpl   rendered → /etc/systemd/system/tau-api.service
  systemd/tau-worker.service.tmpl
  systemd/tau-backup.service.tmpl  rendered → /etc/systemd/system/tau-backup.{service,timer}
  systemd/tau-backup.timer.tmpl
```

The setup and provisioning scripts install a complete Tau instance: API, worker, database, sandbox runtime, and initial squad.

## Quickstart

### Path A — cloud VM, from your laptop

```bash
# 1. Generate a config (interactive; writes ./tau-setup.yaml, never stores secrets)
scripts/setup/provision.sh --wizard

# 2. Review the plan
OPENAI_API_KEY=sk-... scripts/setup/provision.sh --config tau-setup.yaml --dry-run

# 3. Go
OPENAI_API_KEY=sk-... scripts/setup/provision.sh --config tau-setup.yaml
```

This creates the VM, waits for SSH, pushes the toolkit + config + key files
(`COPYFILE_DISABLE=1`, never the source tree — see Pitfalls), runs
`setup-host.sh` remotely, and prints the handoff URL. `provision.provider`
picks the VM provider:

- **exe** (default) — `ssh exe.dev new --name <n> --image ghcr.io/ficushq/ficus-machine:latest`;
  the VM is reachable at the stable `<name>.exe.xyz` hostname before it even exists.
- **hetzner** — creates (or reuses, by name) a Hetzner Cloud server via the
  hcloud API (`provision.hetzner.{server_type,location,image,ssh_key_name}`),
  polls until it's running, and SSHes to its public IP directly (not DNS,
  which may not have propagated yet). `provision.ssh_user` defaults to
  `root`. Pair it with `dns.provider: cloudflare` + `dns.zone` to
  upsert a **proxied** A record for `core.origin`'s host → the server's IP
  (proxied because the origin serves a Cloudflare Origin CA certificate — see
  the TLS bullet below).
  Needs `$HCLOUD_TOKEN` (and `$CLOUDFLARE_API_TOKEN` if DNS is on) on the
  control machine only — never forwarded to the target. See
  `tau-setup.example.yaml` for the full contract.
- **digitalocean** — creates (or reuses, by tag + exact name) a Droplet via
  the DO API (`provision.digitalocean.{size,region,image,ssh_key_id}`),
  polls until it's `active` with a public IPv4 (`networks.v4[].type ==
"public"` — DO always returns both a public and private entry), and SSHes
  to that IP directly (not DNS). Supports an OPTIONAL ordered
  `provision.digitalocean.fallbacks` list of alternate `{size, region}`
  pairs, tried in turn on a capacity/availability error (422/503) — never on
  an auth/image/other error — so a temporarily-out-of-stock size/region
  doesn't fail a paid signup. Two more OPTIONAL knobs:
  `provision.digitalocean.vpc_uuid` pins the droplet to a specific VPC rather
  than whichever one is currently the region's default (needed whenever the
  droplet must reach a private-network endpoint, e.g. a managed database),
  and `provision.digitalocean.project_id` files it under a DO project via a
  separate post-create call that is best-effort by design — the droplet
  already exists and is already billing by then, so a failed assignment warns
  and continues rather than failing the run. This is the provider the hosted platform
  actually uses: Hetzner's cheap shared-vCPU tiers (CX23/CAX11) are
  frequently unbuyable (no capacity). `provision.ssh_user` defaults to
  `root`. Pair it with `dns.provider: cloudflare` + `dns.zone` the same way
  as hetzner. Needs `$DIGITALOCEAN_TOKEN` (and `$CLOUDFLARE_API_TOKEN` if
  DNS is on) on the control machine only — never forwarded to the target.
  See `tau-setup.example.yaml` for the full contract.

### Path B — any Ubuntu 24.04 host, on the host itself

```bash
scripts/setup/setup-host.sh --wizard                       # or write tau-setup.yaml by hand
OPENAI_API_KEY=sk-... scripts/setup/setup-host.sh --config tau-setup.yaml --dry-run
OPENAI_API_KEY=sk-... scripts/setup/setup-host.sh --config tau-setup.yaml
```

### Upgrading a host that is already set up

```bash
# ON the host (root), against the config it was set up with:
GH_TOKEN=ghp_... scripts/setup/upgrade-host.sh --config /root/tau-setup/tau-setup.yaml --ref main
```

Source sync → `bun install` → **core build** → web build → migrations →
`systemctl restart tau-api tau-worker` + health wait. `--ref` takes a branch,
tag or commit sha and defaults to the config's `source.ref`.

Before either tenant setup or upgrade builds, the toolkit reconciles swap and
manages root-owned `/usr/local/bin/bun` plus
`/usr/local/bin/node -> /usr/local/bin/bun`. It verifies a real Node shebang as
`core.run_user`; hosted tenants omit that key and therefore preserve their
root SSH/setup/upgrade identity. For a supported BYO non-root upgrade, the
invoking operator must either be root or have non-interactive sudo, the
configured `core.run_user` account must already exist, and Bun source discovery
must succeed from the invoking operator's `PATH` or `HOME/.bun/bin`; setup then
copies that executable into the managed system path before switching identity.
The Ficus env rename (below) is root-only: a non-root run takes no rename
lock (it warns instead) and goes on exactly as before as long as the host
needs no rename, restore or reconcile — a `TAU_*` host staying on a
pre-rename release, or a host already on `FICUS_*`. When the run would have to
rename `TAU_*` → `FICUS_*`, finish a journaled rename, or restore a set
(`--restore-env-backup`), it stops before changing anything and says so:
re-run it as root.

Do NOT hand-roll this sequence. `tau-api` runs `bun run dist/index.js`, so a
fetch without the core build leaves the OLD server running while `git log` on
the box shows the new commit — a failure that looks exactly like a successful
deploy. `upgrade-host.sh` and `setup-host.sh` both go through `lib.sh`'s
`build_app`, which is what makes skipping the build impossible rather than
merely discouraged.

The control plane drives this same script over SSH for its `upgrade` job
(the hosted control plane's admin "Upgrade" / "Upgrade all"), and independently verifies
afterwards that `apps/core/dist/index.js` was rebuilt and that the running
`tau-api` process started after it.

### The Ficus env rename (TAU*\* → FICUS*\*)

The Core release that ships the Ficus rename reads `FICUS_*` settings (with a
one-release in-process fallback for `TAU_*`). The upgrade onto it — and only
that upgrade — **hard-renames** the host's existing settings in place:

| File                                         | What is renamed                                                                                                                        |
| -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `<dest>/.env`, `managed.env`, `backup.env`   | every `KEY=` / `export KEY=` line whose key starts with `TAU_` (values, comments and order kept; `*_MANAGED_SECRET_KEYS` items mapped) |
| the host config (`--config`)                 | `core.env.TAU_*` keys (comments kept)                                                                                                  |
| the core API/worker units and their drop-ins | `Environment=TAU_…` assignments                                                                                                        |
| the installed `tau-backup.sh`                | re-rendered from `tau-backup.sh.tmpl` (which reads `FICUS_BACKUP_*`)                                                                   |

Only names change: every value (install paths included), file location and
unit name stays as it is. The direction comes from the release being
activated — `artifact.json`'s `"envPrefix": "FICUS"`, or for a git checkout
its root `package.json` name (`ficus` / `tau`) — never from the toolkit, so an
upgrade onto a pre-rename release renames nothing, and one onto a pre-rename
release on an already renamed host is refused (see `--restore-env-backup`).

**Safety.**

- **Conflicts stop the run.** When `TAU_X` and `FICUS_X` both exist with
  different values and `X` contains `ENCRYPTION_KEY` or `PASSWORD`, nothing is
  written: the message names both keys (never a value) — keep the right one,
  delete the other, re-run. Identical values collapse silently; for any other
  key the `FICUS_` value wins and the dropped `TAU_` key is logged.
- **Backup sets.** Before the first byte is renamed, every env-bearing file is
  copied byte for byte (`cp -p`, verified with `cmp`, sha256 recorded in a
  `MANIFEST`) into `/var/backups/ficus-env-rename/<UTC time>-<random>/`
  (override: `ENV_RENAME_BACKUP_ROOT`). **These sets hold plaintext secrets**
  — the encryption key, the database DSN, passwords. The directory is root
  0700, and the newest five sets are kept until pruned.
- **The journal.** `/var/backups/ficus-env-rename/PENDING` names the set, the
  target prefix and the release; it is flushed to disk before the first rename
  and removed only when the release that reads the new names is serving (or
  after a verified restore).
- **The files follow the active release.** When a run fails or is signalled
  (`SIGTERM` / `SIGHUP` / `SIGINT`, exit 143 / 129 / 130) after renaming, the
  env files are made to match the release that is serving at that moment:
  before the `current` symlink moved (or after the automatic rollback moved
  it back) the set is restored byte for byte; after it moved to the Ficus
  release the rename is kept and committed. A dropped control connection
  cannot interrupt this (the toolkit ignores `SIGPIPE`, and a failed log
  write never stops it). The rename itself runs immediately before the
  `current` symlink moves (artifact mode) or before the restart (git mode).
- **Reconcile.** A run that could not settle — `SIGKILL`, OOM, reboot —
  leaves the journal. The next `upgrade-host.sh`, `setup-host.sh` or
  `apply-artifacts.sh --config` makes the files match the release that is
  serving: it restores the set when that release reads `TAU_*`, and finishes
  the rename when it reads `FICUS_*`. The files are renamed one by one and
  each rename is idempotent, so a half-renamed host is always finished, never
  skipped. Toolkit runs that can rename, restore or reconcile (upgrade,
  setup, `apply-artifacts.sh --config`, `--restore-env-backup`) take an
  exclusive `flock` on `/var/backups/ficus-env-rename/.lock` first, when run
  as root (the lock, like the rename, is root-only; a non-root run skips it
  with a warning and refuses if a rename, restore or reconcile is needed).
  The wait for the lock is capped at 900 s (`ENV_RENAME_LOCK_WAIT`).
- **A failed git-mode build.** In git mode the checkout moves to the Ficus
  commit before the build, and the rename runs only after the build, just
  before the restart. If the build fails in between, the host is left with
  `TAU_*` files, a Ficus checkout and no journal. That is safe: the old
  `dist/` keeps serving on `TAU_*`, a Ficus build would still read them
  through its one-release fallback, and the next successful upgrade renames.
- **Units after a conversion.** When the same upgrade converts a git checkout
  to the artifact layout, the units are left out of the set; a restore
  re-renders them for the current layout with `TAU_ROOT` instead of copying
  back units that point at a checkout that no longer exists.

**`--restore-env-backup <set>`** is the manual way back:

```bash
sudo bash scripts/setup/upgrade-host.sh --config /root/tau-setup/tau-setup.yaml \
  --restore-env-backup /var/backups/ficus-env-rename/<set>
```

It verifies every file against the set's `MANIFEST`, puts it back, clears the
journal if it names that set, and exits. Run it before downgrading to a
pre-rename Core or running an older toolkit on a renamed host. Two caveats:

- it also reverts **any secret changed since that set was taken** (a rotated
  password or key is rolled back with everything else);
- backup archives taken **after** the rename carry a `FICUS_` `.env`. Restoring
  one needs this toolkit or newer: an older `setup-host.sh` looks only for
  `TAU_ENCRYPTION_KEY` in the archive and dies. (This toolkit reads either
  spelling, permanently, and never generates a new key while either exists.)
- a restore does not move the release: if a Ficus release is serving, it now
  runs on `TAU_*` only through its one-release fallback, and syncs
  (`apply-artifacts.sh --config`) refuse with an env-prefix mismatch until
  you downgrade to a pre-rename release.
  It is root-only, like the rename.

`apply-artifacts.sh --config <yaml> <stage>` (what the control plane's sync
runs) refuses to install anything — exit 3, `FICUS_ENV_PREFIX_MISMATCH=1` on
stdout — while a rename is journaled or the host's `.env` and its active
release disagree; the fix is the tenant upgrade, which reconciles. The retarget
primitives (`retarget-origin.sh`, `retarget-backup.sh`) read and write
`FICUS_*` only and refuse a host that has not been renamed yet. Until phase 5
the `*_SETUP_*` inputs (`FICUS_SETUP_DATABASE_DSN`, `…_RESTORE_*`, `…_RRSYNC`,
`…_HTTP_CMD`) and the `*_SYSTEMD_UNIT_DIR` / `*_MANAGED_ENV_PATH` /
`*_ARTIFACTS_DIR` seams also answer to their `TAU_` spelling.

### What you end up with (the contract)

1. Core API healthy (`GET /health` → **401 means up**: healthy + auth-gated),
   DB migrated, web UI served from the core process at ONE origin.
2. `APP_URL` = `FICUS_WEB_ORIGIN` = `core.origin` — the exact browser-facing
   origin, no path. This is what makes passkeys work.
3. AI provider account + `exe-provider-ssh-key` secret + starter squad with one
   agent, seeded through the API with the `FICUS_PASSWORD` bootstrap bearer.
4. `tau-api` + `tau-worker` under systemd (auto-restart, survive reboot,
   `journalctl -u tau-api`). The in-UI Restart (`POST /api/system/restart`)
   restarts BOTH units: the api signals the worker over the internal event
   transport, and each exits non-zero so `Restart=on-failure` brings it back.
5. A printed URL + instruction: open it, register the first admin passkey.
   The bootstrap bearer is fully privileged **only while no admin exists** and
   disables itself the instant that passkey is created — nothing to revoke.

## The config file

See [`tau-setup.example.yaml`](tau-setup.example.yaml) — every field is
commented there. Ground rules:

- **`runtime.sandbox` is required and has no default.** It is exactly one of
  `docker-sysbox`, `docker-socket`, `k8s`, `vm`, or `host`, and it becomes
  `FICUS_SANDBOX_RUNTIME` in the generated `.env`. A config without it is a hard
  error before the host is touched, and the wizard prompts for it with no
  default — the core itself refuses to start without the variable, so there is
  nothing sensible to guess. See
  [`docs/wiki/sandbox-runtimes.md`](../../docs/wiki/sandbox-runtimes.md) to choose.
  `runtime.exe.*` (`ssh_key_path`, `machine_image`) applies only to
  `sandbox: vm` with exe.dev boxes; `sandbox: k8s` assumes a cluster this
  toolkit does not build.
- **Secrets never live in the yaml.** API keys come from env vars
  (`ai.key_env`), SSH keys from file paths, tokens from `GH_TOKEN`; anything
  missing is prompted for when a TTY is available and is a hard, early error
  when not (unattended runs fail fast, before touching the host).
- `secrets.encryption_key_env` / `secrets.password_env` name env vars for
  `FICUS_ENCRYPTION_KEY` / `FICUS_PASSWORD`; unset means _generate_. Re-runs reuse
  the values already in `<dest>/.env` — regenerating the encryption key would
  orphan the encrypted secret store.
- Headless setup **requires an api-key provider** (`openai` or `anthropic`).
  `openai-codex` needs an interactive ChatGPT OAuth login: setup warns, skips
  key seeding, and tells you to finish in Settings > AI Providers after the
  passkey handoff. The starter agent's `model` must match the seeded provider
  (guarded — `openai-codex:*` models are rejected with api-key providers).
- `source.mode: artifact` — a tenant-only seam driven by a cloud control
  plane, not by hand. Instead of cloning, `setup-host.sh` downloads a signed,
  prebuilt release bundle, verifies it, and stages it under
  `<dest>/releases/<sha>-<digest12>` — `artifact_acquire` → `artifact_stage`
  → `artifact_activate`, the same acquire/stage/activate primitives
  `upgrade-host.sh` uses for fleet upgrades (activation migrates, flips
  `<dest>/current`, restarts, health-checks, and auto-rolls-back on a failed
  check). The four inputs (`FICUS_ARTIFACT_TARBALL_URL`,
  `FICUS_ARTIFACT_MANIFEST_URL`, `FICUS_ARTIFACT_SIG_URL`,
  `FICUS_ARTIFACT_PUBKEY_B64`) arrive via the ENVIRONMENT (the control plane's
  `secrets.env` channel), never the config file — three of them are
  presigned GET credentials. All four are required: a partial set dies
  naming exactly what's missing rather than silently falling back to a
  source build. `source.repo`/`source.ref` stay required even in this mode
  (recorded metadata; there is no checkout to clone). The build and migrate
  phases are no-ops in this mode — the release ships prebuilt, and
  migrations run inside `artifact_activate`.

- `ingress.caddy` (default `false`) turns on a flag-gated ingress step: setup
  installs caddy and writes `/etc/caddy/Caddyfile` with a single vhost that
  terminates TLS for `core.origin`'s host and reverse-proxies to
  `127.0.0.1:<core.port>`. Caddy owns 443, so `core.origin` must be
  portless `https://...` when this is on — `setup-host.sh` refuses to start
  with a clear error otherwise. This is the shape the cloud control plane
  renders for tenant VMs.
- **TLS is a supplied certificate, never ACME.** `ingress.tls_cert_path` /
  `ingress.tls_key_path` (both required when `ingress.caddy: true`) point at a
  Cloudflare Origin CA cert+key pair; the rendered vhost is `tls <cert> <key>`
  and there is no ACME and no global email block anywhere. Two reasons, neither
  negotiable:
  - Let's Encrypt allows **50 certificates per registered domain per week**,
    shared across every `*.hiretau.ai` subdomain. Per-tenant ACME therefore
    caps signups at 50/week, and issuance happens _after_ payment — a
    rate-limited failure is a paid-but-broken tenant.
  - An Origin CA certificate is trusted by **Cloudflare's proxy only**, never
    by a browser, so the hostname MUST be proxied (orange cloud).
    `provision.sh` creates its A records with `proxied: true` for exactly this
    reason; a grey-cloud record would both break TLS for real browsers and
    publish the origin IP.

  One pair covers the apex and `*.<zone>` and is valid for years, so nothing
  does per-host issuance or renewal, and port 80 is neither used nor opened
  (there is no HTTP-01 challenge). `provision.sh` delivers the pair to tenant
  VMs the same way it delivers the git deploy key — `scp` into
  `<remote dir>/keys/` at 0600, config paths rewritten to match —
  and `setup-host.sh` installs them to `/etc/caddy/tls/origin.{crt,key}` (key
  0600, owned by the `caddy` service user). The key's contents are never
  logged, echoed, or printed by `--dry-run`.

- **An external database is verified, not merely encrypted.**
  `database.ca_path` points at the CA that signed the database server's
  certificate, on the machine running the script. It rides the exact same
  delivery path as the origin cert (scp into `<remote dir>/keys/`, config value
  rewritten to match) and `setup-host.sh` installs it at
  `/etc/tau/database-ca.crt` — **0644, root-owned**, deliberately unlike the
  origin key, because a CA certificate is a public document with several
  unprivileged readers (the `tau-api`/`tau-worker` units, the nightly
  `pg_dump`).

  Required whenever the DSN uses `sslmode=verify-full`, and both scripts refuse
  to proceed without it: `provision.sh` asserts the file exists **and is
  readable by the invoking user** before any VM is created, and `setup-host.sh`
  re-checks before it mutates the host. `require` on its own encrypts but
  authenticates nothing — anything able to intercept the connection can present
  its own certificate — and managed providers sign with a private CA that is in
  no system trust store, so the file has to be supplied.

- The generated `.env` always includes `FICUS_SYSTEM_LOG_PROVIDER=systemd`, so
  Settings → System Logs streams from journald on toolkit installs (the units
  default to `tau-api`/`tau-worker`; see `docs/wiki/system-logs.md`). Installs
  created before this line existed must add it to `<dest>/.env` by hand and
  restart both services.
- The generated `.env` also carries `FICUS_WORKER_EVENT_PORT=3003` and a
  generated `FICUS_INTERNAL_EVENT_TOKEN`. tau-api and tau-worker exchange agent
  control signals, forwarded events and secret-cache invalidations over
  loopback HTTP (the worker's listener binds `127.0.0.1` only); the token
  authenticates both directions and MUST be identical in both units, which is
  exactly why it lives in the `.env` they share. Re-runs preserve an existing
  token; rotating it is harmless because both units restart together. Installs
  created before these lines existed can add it by hand (`openssl rand -hex 32`)
  or rely on the HMAC-derived token when both units share `FICUS_ENCRYPTION_KEY`.
  Only when both values are absent does each process generate a random token and
  reject cross-process events. Override
  the port via `core.env` if 3003 is taken on the host.
- `core.env` (default `{}`) is a flat string map appended verbatim to
  `<dest>/.env`, after the built-ins — the knob a future cloud control plane
  uses to inject per-tenant settings (e.g. `FICUS_MAX_MACHINES` tier limits)
  without a bespoke config field per knob. Keys must be
  `SCREAMING_SNAKE_CASE`. A key ending in `_ENV` follows the same secret
  indirection convention as `secrets.encryption_key_env`: the yaml names an
  env var (never the secret itself), and the rendered line drops the `_ENV`
  suffix and takes that var's content —
  `FICUS_PLATFORM_USAGE_TOKEN_ENV: PLATFORM_USAGE_TOKEN` renders
  `FICUS_PLATFORM_USAGE_TOKEN=<contents of $PLATFORM_USAGE_TOKEN>`. Setup dies
  fast (before touching the host) on an invalid key, a value with an embedded
  newline, or a `_ENV` reference to an unset variable — and on any attempt to
  override a built-in (`APP_URL`, `FICUS_WEB_ORIGIN`, `DATABASE_URL`,
  `FICUS_ENCRYPTION_KEY`, `FICUS_PASSWORD`, `FICUS_INTERNAL_EVENT_TOKEN`), which
  always wins. See
  `tau-setup.example.yaml` for the full contract.
- `backup.enabled` (default `false`) turns on a flag-gated nightly encrypted
  backup: setup renders `/usr/local/bin/tau-backup.sh` (from
  `tau-backup.sh.tmpl`) plus a `tau-backup.timer` (`backup.schedule`, `HH:MM`
  UTC) that triggers `tau-backup.service`. Each run: `pg_dump -Fc` (via
  `docker exec tau-postgres` in `database.mode: container`, else the DSN from
  `<dest>/.env`), tars it together with **`HOME_DIR`** (the agent
  workspace/memory tree — resolved the same way `apps/core` resolves it:
  `core.env.HOME_DIR` if set, else `<core.run_user's home>/.tau`) **and
  `<dest>/.env`** (the backup envelope carries `FICUS_ENCRYPTION_KEY` itself,
  by design — never the platform's tenant registry), encrypts the tarball
  with `openssl enc -aes-256-cbc -pbkdf2` using a passphrase, and uploads it
  to `<backup.s3_prefix>/<YYYY-MM-DD>.tar.gz.enc` via
  `curl --aws-sigv4 "aws:amz:<backup.s3_region>:s3"`. Prunes local temp files
  and keeps only the last 14 objects under the prefix (S3 `ListObjectsV2` +
  `DELETE` of the rest). S3 credentials and the passphrase are resolved from
  the env vars named by `backup.s3_access_key_env` /
  `backup.s3_secret_key_env` / `backup.passphrase_env` (the same `*_env`
  indirection convention used elsewhere — never stored in the yaml) and
  rendered into a 0600 root-owned `/etc/tau/backup.env` that only the
  rendered script reads; they never touch curl argv, logs, or the tenant
  `.env`. Non-zero exit on any failure (systemd flags the unit as failed).
  See `tau-setup.example.yaml` for the full contract. `bash
scripts/setup/tau-backup.test.sh` round-trip-tests the rendered script
  (tar → encrypt → decrypt → untar) against a scratch dir with a fake
  `pg_dump` (the `FICUS_BACKUP_PG_DUMP_CMD` seam) — no live postgres or S3
  needed.

**Dependency:** config parsing uses **mikefarah yq v4** (one flavor, one
syntax; the python jq-wrapper `yq` is rejected). `setup-host.sh` auto-installs
it on the Linux target; on a control machine: `brew install yq`.

## Idempotency (safe re-run)

| Phase                                       | Re-run behavior                                                                                                                                                                             |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| source                                      | clone → `fetch` + `checkout` of the configured ref                                                                                                                                          |
| database                                    | container + volume reused; password recovered from `<dest>/.env`; `tau` DB created only if missing                                                                                          |
| .env                                        | rewritten, but existing secret values are preserved                                                                                                                                         |
| systemd                                     | units re-rendered, `daemon-reload`, `restart`                                                                                                                                               |
| caddy (optional, `ingress.caddy`)           | Caddyfile rewritten and caddy `reload`d (never restarted) only when its content changed; the origin cert/key are re-installed to `/etc/caddy/tls/`                                          |
| Stripe webhook (optional, `stripe.enabled`) | endpoint looked up by URL: created only if absent, updated only if its event list drifted or Stripe disabled it, otherwise untouched; the signing secret already on file is carried through |
| backup (optional, `backup.enabled`)         | script/env-file/units re-rendered, `daemon-reload`, `enable --now` (idempotent — arming an already-armed timer is a no-op)                                                                  |
| seed                                        | check-before-create (provider account, squad, agent); total no-op once an admin exists (the bearer is dead by then)                                                                         |

Every wait is a bounded poll on a real condition (`pg_isready`, `docker info`,
`/health` → 200/401, `systemctl is-active`) — never a fixed sleep. Failures
tail journald so you see _why_. (The platform app is different: it really

## seed.sh standalone

Re-seed (or seed a manually-installed instance) without re-running setup:

```bash
scripts/setup/seed.sh --config tau-setup.yaml \
  --env-file /opt/tau/.env --api-url http://127.0.0.1:3000
```

## Pitfalls this toolkit encodes (hit live, 2026-07-14)

- **Never tar/scp the source tree from macOS.** AppleDouble `._*` files carry
  xattrs with NUL bytes that crash config-sync's YAML parser and boot-loop
  core. Source always arrives via `git clone` on the target; the orchestrator
  only pushes the small config/key files, with `COPYFILE_DISABLE=1`.
- **Build before start.** systemd runs `bun run dist/index.js|worker.js` — the
  production path. `bun run src/*.ts` is not it.
- **`bun install --ignore-scripts`** — skips the root postinstall (submodules +
  extensions); bun-pty is externalized from the core build so the runtime
  doesn't need it vendored. `bun run extensions:install` is run explicitly.
- **`FICUS_WEB_ORIGIN` must equal the browser origin** (no path!) or WebAuthn
  fails silently. The origin format is validated; for exe that is
  `https://<vm>.exe.xyz:<port>` — the proxy origin, not localhost.
- **The ficus-machine image masks rootful docker** (box hardening). The CORE host
  is not a box host, so `setup-host.sh` unmasks it for the local DB container —
  intentional and correct.
- **openai-codex cannot be seeded headless** (OAuth, not api-key) — see above.

## Seams (designed, not yet implemented)

- `provision.provider` — `provision_vm()` in provision.sh dispatches per
  provider; `exe`, `hetzner`, and `digitalocean` are implemented (more slot
  in there).
- `dns.provider` — `dns_upsert_a_record()` in provision.sh dispatches per
  provider; `cloudflare` is the only implementation today.

## Relationship to other deploy paths

- `docs/wiki/setup.md` — local development (pm2 + a local sandbox runtime) and
  integrations; points here for production single-host setup.
- `scripts/deploy.sh` + `docs/wiki/k8s/deployment.md` — the Kubernetes deployment
  path (untouched by this toolkit).
- **Sandbox runtime is a separate axis from all of these.** This toolkit sets
  up a host and writes `FICUS_SANDBOX_RUNTIME` from `runtime.sandbox`; which of
  `host`, `docker-socket`, `docker-sysbox`, `vm`, or `k8s` you pick is chosen in
  [`docs/wiki/sandbox-runtimes.md`](../../docs/wiki/sandbox-runtimes.md). The toolkit
  seeds the `vm` runtime's exe.dev credential (`runtime.exe.*`) and installs
  Docker when the database runs in a container, but it does not build a
  Kubernetes cluster — `sandbox: k8s` expects one to exist. `docs/wiki/hosting.md`
  maps both axes.
- `ecosystem.config.example.js` (pm2) — superseded by the systemd units for
  hosts set up with this toolkit; still used for local dev.

## tau-api memory guardrail

Tenant hosts constrain `tau-api` with a host-relative cgroup budget: soft
reclaim begins at 25% of host RAM and `MemoryMax=35%` is the hard cap. This
leaves 65% for the OS, machine agent, worker, database/runtime, and sandboxes
across the supported roughly 2–16 GiB host range. A cgroup OOM kills the whole
API process tree and is journaled; `Restart=on-failure` retries after five
seconds, bounded to five starts per five minutes. A repeated wedge therefore
fails closed instead of causing an unbounded restart storm. After repair:

```bash
sudo systemctl reset-failed tau-api
sudo systemctl start tau-api
```

Inspect the current budget, OOM result, and restart count with:

```bash
systemctl show tau-api -p Result -p NRestarts -p MemoryCurrent -p MemoryPeak -p MemoryHigh -p MemoryMax
journalctl -u tau-api -b --no-pager
```

This guardrail is pilot host insurance, not the memory-leak fix. If fleet-wide
aggregation becomes necessary, a separate change should add one low-cardinality
`tau-api` `NRestarts` delta to the machine usage payload; no API restart-count
payload seam exists today, so this pilot uses systemd and journald.

On a disposable Ubuntu 24.04 systemd host only, the opt-in proof renders a
unique runtime unit, triggers a test-only 64 MiB cgroup OOM, verifies the
replacement serves HTTP, and removes all runtime state:

```bash
sudo FICUS_API_MEMORY_E2E=1 bash scripts/setup/tau-api-memory-guardrail-e2e.sh
```

Never run the memory test on a tenant host.
