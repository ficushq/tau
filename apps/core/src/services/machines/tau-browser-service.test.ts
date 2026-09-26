import { describe, expect, it, beforeEach, afterEach } from 'bun:test'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
// Plain-JS machine script (runs directly under bun on machine hosts, no build
// step, no .d.ts) — see scripts/machine/browser/tau-browser.js's header.
// @ts-expect-error no type declarations for this untyped machine script
import { createService } from '../../../../../scripts/machine/browser/tau-browser.js'

// --- Helpers -----------------------------------------------------------

function sha256Hex(value: string): string {
  return createHash('sha256').update(value).digest('hex')
}

// --- Fakes -----------------------------------------------------------------

class FakePage {
  closed = false
  closeCalls = 0
  screenshotCalls = 0
  gotoCalls: Array<{ url: string; opts: unknown }> = []
  fillCalls: Array<{ selector: string; text: string; opts: unknown }> = []
  clickCalls: Array<{ selector: string; opts: unknown }> = []
  mouseClicks: Array<{ x: number; y: number }> = []
  typedText: string[] = []
  wheelCalls: Array<{ x: number; y: number }> = []
  waitedTimeouts: number[] = []
  evalCalls = 0
  nullTextContentSelectors = new Set<string>()

  private consoleHandler: ((msg: { type: () => string; text: () => string }) => void) | null = null
  private closeHandlers: Array<() => void> = []

  on(event: string, handler: (msg: { type: () => string; text: () => string }) => void) {
    if (event === 'console') this.consoleHandler = handler
    if (event === 'close') this.closeHandlers.push(handler as unknown as () => void)
  }

  async goto(url: string, opts: unknown) {
    this.gotoCalls.push({ url, opts })
  }

  async title() {
    return 'Fake Title'
  }

  async screenshot(_opts?: unknown) {
    this.screenshotCalls++
    return Buffer.from('fake-png-bytes')
  }

  locator(selector: string) {
    return {
      click: async (opts: unknown) => {
        this.clickCalls.push({ selector, opts })
      },
      fill: async (text: string, opts: unknown) => {
        this.fillCalls.push({ selector, text, opts })
      },
      textContent: async (_opts: unknown) => {
        if (this.nullTextContentSelectors.has(selector)) return null
        return `text-of-${selector}`
      },
    }
  }

  mouse = {
    click: async (x: number, y: number) => {
      this.mouseClicks.push({ x, y })
    },
    wheel: async (x: number, y: number) => {
      this.wheelCalls.push({ x, y })
    },
  }

  keyboard = {
    type: async (text: string) => {
      this.typedText.push(text)
    },
  }

  async waitForTimeout(ms: number) {
    this.waitedTimeouts.push(ms)
  }

  async evaluate(_fn: unknown) {
    this.evalCalls++
    return 'body-inner-text'
  }

  async close() {
    this.closed = true
    this.closeCalls++
    for (const h of this.closeHandlers) h()
  }

  emitConsole(type: string, text: string) {
    this.consoleHandler?.({ type: () => type, text: () => text })
  }
}

type FakeRoute = ReturnType<typeof fakeRoute>

function fakeRoute(url: string) {
  const state = { aborted: false, continued: false }
  return {
    state,
    request: () => ({ url: () => url }),
    abort: async () => {
      state.aborted = true
    },
    continue: async () => {
      state.continued = true
    },
  }
}

class FakeContext {
  closed = false
  pages: FakePage[] = []
  opts: unknown
  failNewPage = false
  routeHandler: ((route: FakeRoute) => Promise<void>) | null = null
  routeCalls: Array<{ pattern: string }> = []

  constructor(opts: unknown) {
    this.opts = opts
  }

  async newPage() {
    if (this.failNewPage) throw new Error('newPage failed')
    const page = new FakePage()
    this.pages.push(page)
    return page
  }

  async route(pattern: string, handler: (route: FakeRoute) => Promise<void>) {
    this.routeCalls.push({ pattern })
    this.routeHandler = handler
  }

  async close() {
    this.closed = true
  }
}

class FakeBrowser {
  contexts: FakeContext[] = []
  failNewContext = false
  closeCalls = 0
  disconnectHandlers: Array<() => void> = []

  // Real Chromium exposes `.on`; the engine's disconnect policy only
  // registers when it sees this method. The fakes used by most tests still
  // have no `on` — this class deliberately does.
  on(event: string, handler: () => void) {
    if (event === 'disconnected') this.disconnectHandlers.push(handler)
  }

  emitDisconnected() {
    for (const handler of [...this.disconnectHandlers]) handler()
  }

  async newContext(opts: unknown) {
    if (this.failNewContext) throw new Error('newContext failed')
    const ctx = new FakeContext(opts)
    this.contexts.push(ctx)
    return ctx
  }

  async close() {
    this.closeCalls++
  }
}

// A launch() that hands out a FRESH FakeBrowser every call and counts how
// many times it was invoked — for asserting a leaked/never-closed browser
// doesn't cause the next open() to keep reusing the same (bad) instance, and
// that a genuine relaunch after a reset happens exactly once. Callers must
// read `.launchCalls`/`.browsers` off the returned object (not destructure
// them) so they see live values as launch() gets called more than once.
function makeMultiLaunch() {
  const state = {
    browsers: [] as FakeBrowser[],
    launchCalls: 0,
    launch: async () => {
      state.launchCalls++
      const b = new FakeBrowser()
      state.browsers.push(b)
      return b
    },
  }
  return state
}

function makeLaunch(browser: FakeBrowser = new FakeBrowser()) {
  return { launch: async () => browser, browser }
}

async function req(
  service: { fetch: (req: Request) => Promise<Response> },
  path: string,
  opts: {
    method?: string
    user?: string | null
    token?: string | null
    body?: unknown
    rawBody?: string
  } = {}
) {
  const headers: Record<string, string> = {}
  if (opts.user !== null) headers['x-tau-box-user'] = opts.user ?? 'box_abcdef012345'
  if (opts.token !== null) headers['authorization'] = `Bearer ${opts.token ?? 'right-token'}`
  const init: RequestInit = {
    method: opts.method ?? 'POST',
    headers,
  }
  if (opts.rawBody !== undefined) {
    init.body = opts.rawBody
    headers['content-type'] = 'application/json'
  } else if (opts.body !== undefined) {
    init.body = JSON.stringify(opts.body)
    headers['content-type'] = 'application/json'
  }
  const res = await service.fetch(new Request(`http://tau-browser${path}`, init))
  const json = await res.json().catch(() => null)
  return { status: res.status, json }
}

// --- Tests -------------------------------------------------------------

describe('tau-browser service', () => {
  let tokensDir: string

  beforeEach(() => {
    tokensDir = mkdtempSync(join(tmpdir(), 'tau-browser-tokens-'))
    // R-B8: token files store sha256(token) hex digests, never raw tokens.
    writeFileSync(join(tokensDir, 'box_abcdef012345.token'), sha256Hex('right-token') + '\n')
    writeFileSync(join(tokensDir, 'box_fedcba987654.token'), sha256Hex('other-token'))
  })

  afterEach(() => {
    rmSync(tokensDir, { recursive: true, force: true })
  })

  describe('auth', () => {
    it('rejects a request with no box-user header', async () => {
      const service = createService({ ...makeLaunch(), tokensDir })
      const { status, json } = await req(service, '/open', { user: null, body: { runId: 'r1', url: 'http://x' } })
      expect(status).toBe(401)
      expect(json).toEqual({ error: 'unauthorized' })
    })

    it('rejects a malformed box-user (path traversal attempt)', async () => {
      const service = createService({ ...makeLaunch(), tokensDir })
      const { status, json } = await req(service, '/open', {
        user: '../../etc/passwd',
        body: { runId: 'r1', url: 'http://x' },
      })
      expect(status).toBe(401)
      expect(json).toEqual({ error: 'unauthorized' })
    })

    it('rejects a wrong token', async () => {
      const service = createService({ ...makeLaunch(), tokensDir })
      const { status, json } = await req(service, '/open', {
        token: 'totally-wrong',
        body: { runId: 'r1', url: 'http://x' },
      })
      expect(status).toBe(401)
      expect(json).toEqual({ error: 'unauthorized' })
    })

    it('rejects a token for a box that has no token file', async () => {
      const service = createService({ ...makeLaunch(), tokensDir })
      const { status } = await req(service, '/open', {
        user: 'box_000000000000',
        token: 'anything',
        body: { runId: 'r1', url: 'http://x' },
      })
      expect(status).toBe(401)
    })

    it('rejects when the stored file is not a valid 64-hex-char digest', async () => {
      writeFileSync(join(tokensDir, 'box_111111111111.token'), 'not-a-digest')
      const service = createService({ ...makeLaunch(), tokensDir })
      const { status } = await req(service, '/open', {
        user: 'box_111111111111',
        token: 'not-a-digest',
        body: { runId: 'r1', url: 'http://x' },
      })
      expect(status).toBe(401)
    })

    it('accepts the right token, checked against its stored digest', async () => {
      const service = createService({ ...makeLaunch(), tokensDir })
      const { status, json } = await req(service, '/open', { body: { runId: 'r1', url: 'http://x' } })
      expect(status).toBe(200)
      expect(json).toMatchObject({ title: 'Fake Title' })
    })

    it('rejects a traversal-shaped user even when a matching digest file exists one directory up', async () => {
      // Plant a digest file OUTSIDE the service's configured tokensDir, at the
      // path a naive '../victim' read would resolve to, then point tokensDir
      // one level deeper. If BOX_USER_RE ever stopped gating the filename,
      // this traversal would authenticate.
      const outerDir = mkdtempSync(join(tmpdir(), 'tau-browser-outer-'))
      const innerDir = join(outerDir, 'inner')
      mkdirSync(innerDir)
      const victimToken = 'victim-token'
      writeFileSync(join(outerDir, 'victim.token'), sha256Hex(victimToken))
      try {
        const service = createService({ ...makeLaunch(), tokensDir: innerDir })
        const { status } = await req(service, '/open', {
          user: '../victim',
          token: victimToken,
          body: { runId: 'r1', url: 'http://x' },
        })
        expect(status).toBe(401)
      } finally {
        rmSync(outerDir, { recursive: true, force: true })
      }
    })
  })

  // R-B17: the docker-dev box server runs un-su-exec'd (as `root`), so
  // browser-proxy sends x-tau-box-user:root, which never matches the prod
  // box_<hex> gate. FICUS_BROWSER_DEV_ALLOW_USER (an env prod NEVER sets) admits
  // exactly that one non-box user, still filename-safe. These pin: dev user
  // authenticates ONLY with the env; the prod gate is intact without it; a
  // traversal-shaped dev user is refused; box_<hex> is unaffected either way.
  describe('R-B17 docker-dev auth escape hatch', () => {
    const ENV_KEY = 'FICUS_BROWSER_DEV_ALLOW_USER'
    const saved = process.env[ENV_KEY]

    afterEach(() => {
      if (saved === undefined) delete process.env[ENV_KEY]
      else process.env[ENV_KEY] = saved
    })

    it('authenticates a non-box dev user (root) WITH the env set + matching digest', async () => {
      writeFileSync(join(tokensDir, 'root.token'), sha256Hex('root-token'))
      process.env[ENV_KEY] = 'root'
      const service = createService({ ...makeLaunch(), tokensDir })
      const { status, json } = await req(service, '/open', {
        user: 'root',
        token: 'root-token',
        body: { runId: 'r1', url: 'http://x' },
      })
      expect(status).toBe(200)
      expect(json).toMatchObject({ title: 'Fake Title' })
    })

    it('rejects the same non-box user WITHOUT the env (prod gate intact)', async () => {
      writeFileSync(join(tokensDir, 'root.token'), sha256Hex('root-token'))
      delete process.env[ENV_KEY]
      const service = createService({ ...makeLaunch(), tokensDir })
      const { status } = await req(service, '/open', {
        user: 'root',
        token: 'root-token',
        body: { runId: 'r1', url: 'http://x' },
      })
      expect(status).toBe(401)
    })

    it('rejects a traversal-shaped dev-allow user even when its digest file exists (safe-filename guard)', async () => {
      // Plant the victim digest one dir up and point tokensDir one level deeper,
      // so a naive '../victim' read WOULD resolve to it. isSafeTokenUser must
      // refuse the '/'-bearing user before readFileSync is ever reached.
      const outerDir = mkdtempSync(join(tmpdir(), 'tau-browser-devouter-'))
      const innerDir = join(outerDir, 'inner')
      mkdirSync(innerDir)
      writeFileSync(join(outerDir, 'victim.token'), sha256Hex('victim-token'))
      try {
        process.env[ENV_KEY] = '../victim'
        const service = createService({ ...makeLaunch(), tokensDir: innerDir })
        const { status } = await req(service, '/open', {
          user: '../victim',
          token: 'victim-token',
          body: { runId: 'r1', url: 'http://x' },
        })
        expect(status).toBe(401)
      } finally {
        rmSync(outerDir, { recursive: true, force: true })
      }
    })

    it('box_<hex> still authenticates both WITH and WITHOUT the env', async () => {
      delete process.env[ENV_KEY]
      let service = createService({ ...makeLaunch(), tokensDir })
      expect((await req(service, '/open', { body: { runId: 'r1', url: 'http://x' } })).status).toBe(200)

      process.env[ENV_KEY] = 'root'
      service = createService({ ...makeLaunch(), tokensDir })
      expect((await req(service, '/open', { body: { runId: 'r2', url: 'http://x' } })).status).toBe(200)
    })
  })

  describe('isolation', () => {
    it("user A's runId is invisible to user B — B's status is 404 AND A's fake page is never touched", async () => {
      const { launch, browser } = makeLaunch()
      const service = createService({ launch, tokensDir })

      const openA = await req(service, '/open', {
        user: 'box_abcdef012345',
        body: { runId: 'only-in-a', url: 'http://x' },
      })
      expect(openA.status).toBe(200)

      const openB = await req(service, '/open', {
        user: 'box_fedcba987654',
        token: 'other-token',
        body: { runId: 'only-in-b', url: 'http://y' },
      })
      expect(openB.status).toBe(200)

      expect(browser.contexts.length).toBe(2)
      const pageA = browser.contexts[0].pages[0]
      expect(pageA.screenshotCalls).toBe(1) // from A's own /open

      const crossReach = await req(service, '/screenshot', {
        user: 'box_fedcba987654',
        token: 'other-token',
        body: { runId: 'only-in-a' },
      })
      expect(crossReach.status).toBe(404)
      expect(crossReach.json).toEqual({ error: 'unknown runId' })
      // Identity assertion, not just status: A's page must never have been
      // touched by B's request. A getPage() that scanned every context would
      // find A's page, call screenshot() on it, and this would go to 2.
      expect(pageA.screenshotCalls).toBe(1)
    })
  })

  describe('caps', () => {
    it('evicts the LRU page of a box when a 4th page is opened', async () => {
      const { launch, browser } = makeLaunch()
      const service = createService({ launch, tokensDir, memoryHighMb: 999999 })

      await req(service, '/open', { body: { runId: 'r1', url: 'http://x' } })
      await req(service, '/open', { body: { runId: 'r2', url: 'http://x' } })
      await req(service, '/open', { body: { runId: 'r3', url: 'http://x' } })

      const ctx = browser.contexts[0]
      const firstPage = ctx.pages[0]
      expect(firstPage.closeCalls).toBe(0)

      const fourth = await req(service, '/open', { body: { runId: 'r4', url: 'http://x' } })
      expect(fourth.status).toBe(200)
      expect(firstPage.closeCalls).toBe(1)

      const afterEvict = await req(service, '/screenshot', { body: { runId: 'r1' } })
      expect(afterEvict.status).toBe(404)
    })

    it('returns 429 at the machine page ceiling', async () => {
      const { launch } = makeLaunch()
      // memoryHighMb 512 -> ceiling floor(512/256) = 2
      const service = createService({ launch, tokensDir, memoryHighMb: 512 })

      const a = await req(service, '/open', { user: 'box_abcdef012345', body: { runId: 'r1', url: 'http://x' } })
      const b = await req(service, '/open', {
        user: 'box_fedcba987654',
        token: 'other-token',
        body: { runId: 'r1', url: 'http://x' },
      })
      expect(a.status).toBe(200)
      expect(b.status).toBe(200)

      const c = await req(service, '/open', { user: 'box_abcdef012345', body: { runId: 'r2', url: 'http://x' } })
      expect(c.status).toBe(429)
      expect(c.json).toEqual({ error: 'browser at capacity on this machine, retry shortly' })
    })
  })

  describe('concurrency (TOCTOU — R-B10)', () => {
    it('concurrent opens for distinct runIds never exceed the machine ceiling, with zero leaked pages', async () => {
      const { launch, browser } = makeLaunch()
      const service = createService({ launch, tokensDir, memoryHighMb: 512 }) // ceiling = 2

      const results = await Promise.all(
        Array.from({ length: 6 }, (_, i) => req(service, '/open', { body: { runId: `r${i}`, url: 'http://x' } }))
      )

      const ok = results.filter((r) => r.status === 200)
      const capped = results.filter((r) => r.status === 429)
      expect(ok.length).toBe(2)
      expect(capped.length).toBe(4)

      const ctx = browser.contexts[0]
      // Exactly as many fake pages were ever created as are tracked live.
      expect(ctx.pages.length).toBe(2)

      const health = await req(service, '/healthz', { method: 'GET', user: null, token: null })
      expect(health.json).toMatchObject({ pages: 2, contexts: 1 })
    })

    it('concurrent opens for the SAME runId are deduped to a single page creation', async () => {
      const { launch, browser } = makeLaunch()
      const service = createService({ launch, tokensDir })

      const results = await Promise.all(
        Array.from({ length: 5 }, () => req(service, '/open', { body: { runId: 'shared', url: 'http://x' } }))
      )
      expect(results.every((r) => r.status === 200)).toBe(true)
      const ctx = browser.contexts[0]
      expect(ctx.pages.length).toBe(1)
    })

    it('concurrent first-opens for the same box dedupe context creation to a single newContext call', async () => {
      const { launch, browser } = makeLaunch()
      const service = createService({ launch, tokensDir })

      await Promise.all(
        Array.from({ length: 4 }, (_, i) => req(service, '/open', { body: { runId: `c${i}`, url: 'http://x' } }))
      )
      expect(browser.contexts.length).toBe(1)
    })
  })

  describe('idle sweeps', () => {
    it('closes an idle page after 10 minutes and an idle context after 15 minutes', async () => {
      let t = 1000
      const { launch, browser } = makeLaunch()
      const service = createService({ launch, tokensDir, now: () => t })

      await req(service, '/open', { body: { runId: 'r1', url: 'http://x' } })
      const ctx = browser.contexts[0]
      const page = ctx.pages[0]

      t += 9 * 60 * 1000
      service.sweepIdle()
      expect(page.closeCalls).toBe(0)
      expect(ctx.closed).toBe(false)

      t += 2 * 60 * 1000 // total 11 min idle -> page swept
      service.sweepIdle()
      expect(page.closeCalls).toBe(1)
      expect(ctx.closed).toBe(false)

      t += 5 * 60 * 1000 // total 16 min since context lastUsed -> context swept
      service.sweepIdle()
      expect(ctx.closed).toBe(true)

      const after = await req(service, '/screenshot', { body: { runId: 'r1' } })
      expect(after.status).toBe(404)
    })
  })

  describe('console', () => {
    it('caps console entries at 50, dropping the oldest', async () => {
      const { launch, browser } = makeLaunch()
      const service = createService({ launch, tokensDir })
      await req(service, '/open', { body: { runId: 'r1', url: 'http://x' } })
      const page = browser.contexts[0].pages[0]
      for (let i = 0; i < 55; i++) {
        page.emitConsole('log', `entry-${i}`)
      }
      const { status, json } = await req(service, '/console', { body: { runId: 'r1' } })
      expect(status).toBe(200)
      const entries = (json as { entries: Array<{ type: string; text: string }> }).entries
      expect(entries.length).toBe(50)
      expect(entries[0].text).toBe('entry-5')
      expect(entries[49].text).toBe('entry-54')
    })
  })

  describe('close', () => {
    it('is idempotent — closing twice both return ok', async () => {
      const service = createService({ ...makeLaunch(), tokensDir })
      await req(service, '/open', { body: { runId: 'r1', url: 'http://x' } })
      const first = await req(service, '/close', { body: { runId: 'r1' } })
      const second = await req(service, '/close', { body: { runId: 'r1' } })
      expect(first.status).toBe(200)
      expect(first.json).toEqual({ ok: true })
      expect(second.status).toBe(200)
      expect(second.json).toEqual({ ok: true })
    })

    it('is 200 ok:true even for a runId that never existed', async () => {
      const service = createService({ ...makeLaunch(), tokensDir })
      const { status, json } = await req(service, '/close', { body: { runId: 'never-opened' } })
      expect(status).toBe(200)
      expect(json).toEqual({ ok: true })
    })
  })

  describe('click', () => {
    it('returns 400 with the exact message when neither selector nor x/y are given', async () => {
      const service = createService({ ...makeLaunch(), tokensDir })
      await req(service, '/open', { body: { runId: 'r1', url: 'http://x' } })
      const { status, json } = await req(service, '/click', { body: { runId: 'r1' } })
      expect(status).toBe(400)
      expect(json).toEqual({ error: 'Provide either a selector or x/y coordinates.' })
    })
  })

  describe('returnScreenshot flag (R-B13 / Phase 3 thin-client prep)', () => {
    it('click with returnScreenshot:true returns ok:true AND the fake screenshot bytes', async () => {
      const service = createService({ ...makeLaunch(), tokensDir })
      await req(service, '/open', { body: { runId: 'r1', url: 'http://x' } })
      const { status, json } = await req(service, '/click', {
        body: { runId: 'r1', x: 1, y: 2, returnScreenshot: true },
      })
      expect(status).toBe(200)
      expect(json).toEqual({ ok: true, screenshotBase64: Buffer.from('fake-png-bytes').toString('base64') })
    })

    it('click WITHOUT returnScreenshot has no screenshotBase64 key (byte-compat with Phase 2)', async () => {
      const service = createService({ ...makeLaunch(), tokensDir })
      await req(service, '/open', { body: { runId: 'r1', url: 'http://x' } })
      const { status, json } = await req(service, '/click', { body: { runId: 'r1', x: 1, y: 2 } })
      expect(status).toBe(200)
      expect(json).toEqual({ ok: true })
    })

    it('scroll with returnScreenshot:true returns deltaPx AND the fake screenshot bytes', async () => {
      const service = createService({ ...makeLaunch(), tokensDir })
      await req(service, '/open', { body: { runId: 'r1', url: 'http://x' } })
      const { status, json } = await req(service, '/scroll', {
        body: { runId: 'r1', direction: 'down', returnScreenshot: true },
      })
      expect(status).toBe(200)
      expect(json).toEqual({ deltaPx: 500, screenshotBase64: Buffer.from('fake-png-bytes').toString('base64') })
    })
  })

  describe('healthz', () => {
    it('is unauthenticated and reports counts', async () => {
      const { launch } = makeLaunch()
      const service = createService({ launch, tokensDir })
      await req(service, '/open', { body: { runId: 'r1', url: 'http://x' } })

      const res = await service.fetch(new Request('http://tau-browser/healthz', { method: 'GET' }))
      expect(res.status).toBe(200)
      const json = (await res.json()) as { ok: boolean; pages: number; contexts: number }
      expect(json).toEqual({ ok: true, pages: 1, contexts: 1 })
    })
  })

  describe('malformed input', () => {
    it('returns 400 (not a silent empty body) for unparseable JSON', async () => {
      const service = createService({ ...makeLaunch(), tokensDir })
      const { status, json } = await req(service, '/open', { rawBody: '{not json' })
      expect(status).toBe(400)
      expect(json).toEqual({ error: 'invalid JSON body' })
    })
  })

  describe('open URL validation (R-B9a)', () => {
    it('rejects a file:// URL with 400', async () => {
      const service = createService({ ...makeLaunch(), tokensDir })
      const { status, json } = await req(service, '/open', { body: { runId: 'r1', url: 'file:///etc/passwd' } })
      expect(status).toBe(400)
      expect(json).toEqual({ error: 'invalid url' })
    })

    it('rejects an unparseable URL with 400', async () => {
      const service = createService({ ...makeLaunch(), tokensDir })
      const { status } = await req(service, '/open', { body: { runId: 'r1', url: 'not a url' } })
      expect(status).toBe(400)
    })
  })

  describe('per-context navigation guard (R-B9b)', () => {
    it('installs a route handler at context creation that aborts host-local/metadata targets and allows the rest', async () => {
      const { launch, browser } = makeLaunch()
      const service = createService({ launch, tokensDir })
      await req(service, '/open', { body: { runId: 'r1', url: 'http://example.com' } })
      const ctx = browser.contexts[0]
      expect(typeof ctx.routeHandler).toBe('function')

      const metadataRoute = fakeRoute('http://169.254.169.254/latest/meta-data/')
      await ctx.routeHandler!(metadataRoute)
      expect(metadataRoute.state.aborted).toBe(true)
      expect(metadataRoute.state.continued).toBe(false)

      const loopbackRoute = fakeRoute('http://127.0.0.1:9999/')
      await ctx.routeHandler!(loopbackRoute)
      expect(loopbackRoute.state.aborted).toBe(true)

      const fileRoute = fakeRoute('file:///etc/passwd')
      await ctx.routeHandler!(fileRoute)
      expect(fileRoute.state.aborted).toBe(true)

      const okRoute = fakeRoute('https://example.com/asset.js')
      await ctx.routeHandler!(okRoute)
      expect(okRoute.state.continued).toBe(true)
      expect(okRoute.state.aborted).toBe(false)
    })
  })

  // The host sandbox runtime (FICUS_SANDBOX_RUNTIME=host) injects its own
  // always-false blocklist: there the browser runs on the user's own machine
  // with exactly the reach the agent's `bash` already has, so the machine-host
  // SSRF guard protects nothing and breaks localhost screenshots.
  describe('injected isBlockedHost seam', () => {
    it('an injected always-false blocklist lets a loopback open through to page.goto', async () => {
      const { launch, browser } = makeLaunch()
      const service = createService({ launch, tokensDir, isBlockedHost: () => false })
      const { status } = await req(service, '/open', { body: { runId: 'r1', url: 'http://127.0.0.1:1/' } })
      expect(status).toBe(200)
      expect(browser.contexts[0]!.pages[0]!.gotoCalls.map((c) => c.url)).toEqual(['http://127.0.0.1:1/'])

      // The per-context route guard uses the SAME injected predicate, so
      // loopback subresources/redirects are continued rather than aborted.
      const route = fakeRoute('http://127.0.0.1:1/asset.js')
      await browser.contexts[0]!.routeHandler!(route)
      expect(route.state.continued).toBe(true)
      expect(route.state.aborted).toBe(false)
    })

    it('the injected predicate never widens the scheme check — file:// is still 400', async () => {
      const service = createService({ ...makeLaunch(), tokensDir, isBlockedHost: () => false })
      const { status, json } = await req(service, '/open', { body: { runId: 'r1', url: 'file:///etc/passwd' } })
      expect(status).toBe(400)
      expect(json).toEqual({ error: 'invalid url' })
    })

    it('the default (no injection) still blocks loopback with 400 invalid url', async () => {
      const { launch, browser } = makeLaunch()
      const service = createService({ launch, tokensDir })
      const { status, json } = await req(service, '/open', { body: { runId: 'r1', url: 'http://127.0.0.1:1/' } })
      expect(status).toBe(400)
      expect(json).toEqual({ error: 'invalid url' })
      expect(browser.contexts[0]?.pages[0]?.gotoCalls ?? []).toEqual([])
    })
  })

  describe('browser restarted', () => {
    it('returns 502 and resets state when launch rejects', async () => {
      const service = createService({
        launch: async () => {
          throw new Error('chromium exploded')
        },
        tokensDir,
      })
      const { status, json } = await req(service, '/open', { body: { runId: 'r1', url: 'http://x' } })
      expect(status).toBe(502)
      expect(json).toEqual({ error: 'browser restarted' })
    })

    it('returns 502 and resets state when newContext rejects (browser dead but not disconnected)', async () => {
      const { launch, browser } = makeLaunch()
      browser.failNewContext = true
      const service = createService({ launch, tokensDir })
      const { status, json } = await req(service, '/open', { body: { runId: 'r1', url: 'http://x' } })
      expect(status).toBe(502)
      expect(json).toEqual({ error: 'browser restarted' })
    })

    it('returns 502 and resets state when newPage rejects (browser dead but not disconnected) — and does NOT leak the old browser', async () => {
      const multi = makeMultiLaunch()
      const service = createService({ launch: multi.launch, tokensDir })
      // First open succeeds, creating the context normally...
      await req(service, '/open', { body: { runId: 'ok', url: 'http://x' } })
      expect(multi.launchCalls).toBe(1)
      const firstBrowser = multi.browsers[0]

      // ...then the browser goes bad for subsequent page creation.
      firstBrowser.contexts[0].failNewPage = true
      const { status, json } = await req(service, '/open', { body: { runId: 'r2', url: 'http://x' } })
      expect(status).toBe(502)
      expect(json).toEqual({ error: 'browser restarted' })

      // Important #1 (fix round 3): resetState() must close the OLD,
      // still-alive Chromium before dropping the reference — otherwise it
      // leaks (every other box's pages silently stop counting toward
      // pageCeiling, and the next open() launches a SECOND Chromium in the
      // same cgroup: a MemoryHigh feedback loop).
      expect(firstBrowser.closeCalls).toBe(1)

      // The next open() must relaunch a genuinely FRESH browser, not keep
      // limping along on the broken/leaked one.
      const after = await req(service, '/open', { body: { runId: 'r3', url: 'http://x' } })
      expect(after.status).toBe(200)
      expect(multi.launchCalls).toBe(2)
      expect(multi.browsers[1]).not.toBe(firstBrowser)
    })
  })

  describe('disconnect policy (deps.onDisconnected)', () => {
    it('uses an injected deps.onDisconnected instead of process.exit', async () => {
      const calls: string[] = []
      const { launch, browser } = makeLaunch()
      const service = createService({
        launch,
        tokensDir,
        // The host sandbox runtime runs this engine in-process inside the
        // long-lived core: a Chrome crash must not process.exit it.
        onDisconnected: () => calls.push('disconnected'),
      })
      await req(service, '/open', { body: { runId: 'r1', url: 'http://x' } }) // forces a launch
      browser.emitDisconnected()
      expect(calls).toEqual(['disconnected'])
    })

    it('defaults to process.exit(1) when no onDisconnected is injected (systemd restarts the unit)', async () => {
      const { launch, browser } = makeLaunch()
      const service = createService({ launch, tokensDir })
      await req(service, '/open', { body: { runId: 'r1', url: 'http://x' } })
      const exits: number[] = []
      const realExit = process.exit
      process.exit = ((code?: number) => {
        exits.push(code ?? 0)
      }) as unknown as typeof process.exit
      try {
        browser.emitDisconnected()
      } finally {
        process.exit = realExit
      }
      expect(exits).toEqual([1])
    })
  })

  describe('contract fidelity (mirrors apps/core/src/tools/browser.ts exactly)', () => {
    it('newContext gets the exact viewport + acceptDownloads', async () => {
      const { launch, browser } = makeLaunch()
      const service = createService({ launch, tokensDir })
      await req(service, '/open', { body: { runId: 'r1', url: 'http://x' } })
      expect(browser.contexts[0].opts).toEqual({ viewport: { width: 1280, height: 720 }, acceptDownloads: false })
    })

    it('goto uses domcontentloaded + a 30s timeout, navigating the VALIDATED (parsed) URL', async () => {
      const { launch, browser } = makeLaunch()
      const service = createService({ launch, tokensDir })
      // No trailing slash in the input — goto must receive parsedUrl.href
      // (the normalized form, with the trailing slash WHATWG URL adds), not
      // the raw body.url string, so validation and navigation never diverge.
      await req(service, '/open', { body: { runId: 'r1', url: 'http://example.com' } })
      const page = browser.contexts[0].pages[0]
      expect(page.gotoCalls).toEqual([
        { url: 'http://example.com/', opts: { waitUntil: 'domcontentloaded', timeout: 30000 } },
      ])
    })

    it('open returns the base64 of the actual screenshot bytes', async () => {
      const service = createService({ ...makeLaunch(), tokensDir })
      const { json } = await req(service, '/open', { body: { runId: 'r1', url: 'http://x' } })
      expect((json as { screenshotBase64: string }).screenshotBase64).toBe(
        Buffer.from('fake-png-bytes').toString('base64')
      )
    })

    it('click via selector uses a 5s locator timeout', async () => {
      const { launch, browser } = makeLaunch()
      const service = createService({ launch, tokensDir })
      await req(service, '/open', { body: { runId: 'r1', url: 'http://x' } })
      await req(service, '/click', { body: { runId: 'r1', selector: '#btn' } })
      const page = browser.contexts[0].pages[0]
      expect(page.clickCalls).toEqual([{ selector: '#btn', opts: { timeout: 5000 } }])
    })

    it('click via x/y calls mouse.click with the exact coordinates', async () => {
      const { launch, browser } = makeLaunch()
      const service = createService({ launch, tokensDir })
      await req(service, '/open', { body: { runId: 'r1', url: 'http://x' } })
      await req(service, '/click', { body: { runId: 'r1', x: 12, y: 34 } })
      const page = browser.contexts[0].pages[0]
      expect(page.mouseClicks).toEqual([{ x: 12, y: 34 }])
    })

    it('type with a selector calls fill (5s timeout), not keyboard.type', async () => {
      const { launch, browser } = makeLaunch()
      const service = createService({ launch, tokensDir })
      await req(service, '/open', { body: { runId: 'r1', url: 'http://x' } })
      await req(service, '/type', { body: { runId: 'r1', selector: '#in', text: 'hello' } })
      const page = browser.contexts[0].pages[0]
      expect(page.fillCalls).toEqual([{ selector: '#in', text: 'hello', opts: { timeout: 5000 } }])
      expect(page.typedText).toEqual([])
    })

    it('type without a selector types into the focused element via keyboard', async () => {
      const { launch, browser } = makeLaunch()
      const service = createService({ launch, tokensDir })
      await req(service, '/open', { body: { runId: 'r1', url: 'http://x' } })
      await req(service, '/type', { body: { runId: 'r1', text: 'hello' } })
      const page = browser.contexts[0].pages[0]
      expect(page.typedText).toEqual(['hello'])
      expect(page.fillCalls).toEqual([])
    })

    it('scroll defaults to 500px and flips sign for "up"', async () => {
      const { launch, browser } = makeLaunch()
      const service = createService({ launch, tokensDir })
      await req(service, '/open', { body: { runId: 'r1', url: 'http://x' } })

      const down = await req(service, '/scroll', { body: { runId: 'r1', direction: 'down' } })
      expect(down.json).toEqual({ deltaPx: 500 })

      const up = await req(service, '/scroll', { body: { runId: 'r1', direction: 'up', amount: 200 } })
      expect(up.json).toEqual({ deltaPx: -200 })

      const page = browser.contexts[0].pages[0]
      expect(page.wheelCalls).toEqual([
        { x: 0, y: 500 },
        { x: 0, y: -200 },
      ])
      expect(page.waitedTimeouts).toEqual([300, 300])
    })

    it('read returns "" (not null) when textContent resolves null', async () => {
      const { launch, browser } = makeLaunch()
      const service = createService({ launch, tokensDir })
      await req(service, '/open', { body: { runId: 'r1', url: 'http://x' } })
      const page = browser.contexts[0].pages[0]
      page.nullTextContentSelectors.add('#empty')
      const { json } = await req(service, '/read', { body: { runId: 'r1', selector: '#empty' } })
      expect(json).toEqual({ text: '' })
    })

    it('read without a selector evaluates document.body.innerText', async () => {
      const { launch, browser } = makeLaunch()
      const service = createService({ launch, tokensDir })
      await req(service, '/open', { body: { runId: 'r1', url: 'http://x' } })
      const { json } = await req(service, '/read', { body: { runId: 'r1' } })
      expect(json).toEqual({ text: 'body-inner-text' })
      const page = browser.contexts[0].pages[0]
      expect(page.evalCalls).toBe(1)
    })
  })

  describe('SSRF host guard corpus (R-B14) — the ALLOWED set must be empty', () => {
    // Every string here is a PROVEN or plausible bypass of a naive
    // string-equality/endsWith host filter: bracketed IPv6, IPv4-mapped IPv6
    // (both dotted-quad and hex-tail forms, which WHATWG URL can normalize to
    // either), the unspecified address, link-local/unique-local IPv6, and
    // trailing-dot FQDNs. Verified against Bun's actual URL normalization
    // (`new URL(url).hostname`) before being added here.
    const blockedUrls = [
      'http://localhost/',
      'http://localhost./',
      'http://localhost../', // round 3: a single trailing dot was stripped, TWO were not
      'http://LOCALHOST/',
      'http://127.0.0.1/',
      'http://127.55.66.77/',
      'http://169.254.169.254/',
      'http://169.254.1.2/',
      'http://0.0.0.0/',
      'http://[::1]/',
      'http://[::]/',
      'http://[0:0:0:0:0:0:0:1]/',
      'http://[::ffff:127.0.0.1]/',
      'http://[::ffff:169.254.169.254]/',
      'http://[::ffff:7f00:1]/',
      'http://[::ffff:a9fe:a9fe]/',
      'http://[::ffff:0:127.0.0.1]/', // round 3: IPv4-translated, ::ffff:0:0/96
      'http://[64:ff9b::7f00:1]/', // round 3: NAT64 well-known, 64:ff9b::/96
      'http://[fe80::1]/',
      'http://[fe9a::1]/',
      'http://[fc00::1]/',
      'http://[fd12:3456::1]/',
      'http://metadata/',
      'http://metadata.google.internal/',
      'http://metadata.google.internal./',
      'http://metadata.google.internal../', // round 3: multiple trailing dots
      'http://METADATA.GOOGLE.INTERNAL/',
      'http://evil.internal/',
      'http://evil.internal./',
      'http://sub.evil.internal/',
    ]

    it('open() rejects every row with 400 — a future bypass shows as a diff, not a silent pass', async () => {
      const service = createService({ ...makeLaunch(), tokensDir })
      const allowed: string[] = []
      for (const [i, url] of blockedUrls.entries()) {
        const { status } = await req(service, '/open', { body: { runId: `ssrf-open-${i}`, url } })
        if (status !== 400) allowed.push(url)
      }
      expect(allowed).toEqual([])
    })

    it('the per-context route() handler also aborts every row — the ALLOWED set is empty', async () => {
      const { launch, browser } = makeLaunch()
      const service = createService({ launch, tokensDir })
      await req(service, '/open', { body: { runId: 'seed', url: 'http://example.com/' } })
      const ctx = browser.contexts[0]
      expect(typeof ctx.routeHandler).toBe('function')

      const allowed: string[] = []
      for (const url of blockedUrls) {
        const route = fakeRoute(url)
        await ctx.routeHandler!(route)
        if (!route.state.aborted) allowed.push(url)
      }
      expect(allowed).toEqual([])
    })
  })

  describe('SSRF host guard does not block RFC1918 (R-B15)', () => {
    it('a box bash already reaches private ranges, so the browser must too', async () => {
      const { launch, browser } = makeLaunch()
      const service = createService({ launch, tokensDir })
      const privateUrls = ['http://10.1.2.3/', 'http://192.168.1.1/', 'http://172.16.5.5/', 'http://172.31.255.255/']

      for (const [i, url] of privateUrls.entries()) {
        const { status } = await req(service, '/open', { body: { runId: `priv-${i}`, url } })
        expect(status).toBe(200)
      }

      const ctx = browser.contexts[0]
      for (const url of privateUrls) {
        const route = fakeRoute(url)
        await ctx.routeHandler!(route)
        expect(route.state.continued).toBe(true)
        expect(route.state.aborted).toBe(false)
      }
    })
  })

  describe('per-box cap under concurrency (R-B16)', () => {
    it('10 concurrent opens on ONE box create at most 3 pages, with zero leaked pages', async () => {
      const { launch, browser } = makeLaunch()
      // Huge ceiling so only the per-box cap (3) can bind.
      const service = createService({ launch, tokensDir, memoryHighMb: 999999 })

      const results = await Promise.all(
        Array.from({ length: 10 }, (_, i) => req(service, '/open', { body: { runId: `burst-${i}`, url: 'http://x' } }))
      )

      const ok = results.filter((r) => r.status === 200)
      const capped = results.filter((r) => r.status === 429)
      expect(ok.length).toBe(3)
      expect(capped.length).toBe(7)

      // The per-box cap bound here, NOT the (huge, non-binding) machine
      // ceiling — the message must say so, distinctly from the
      // machine-ceiling message asserted in the "machine page ceiling" test
      // above, so an operator (or the model surfacing the error) can tell
      // which limit to react to.
      for (const r of capped) {
        expect(r.json).toEqual({ error: 'this box already has 3 pages opening, retry shortly' })
      }

      const ctx = browser.contexts[0]
      // The fake's newPage() was invoked at most 3 times — no page was ever
      // created and then silently orphaned.
      expect(ctx.pages.length).toBe(3)

      const health = await req(service, '/healthz', { method: 'GET', user: null, token: null })
      expect(health.json).toMatchObject({ pages: 3, contexts: 1 })
    })
  })

  describe('page ceiling clamp', () => {
    it('memoryHighMb:100 clamps the ceiling to 1 (Math.max(1, floor(100/256)))', async () => {
      const service = createService({ ...makeLaunch(), tokensDir, memoryHighMb: 100 })
      const first = await req(service, '/open', { body: { runId: 'r1', url: 'http://x' } })
      expect(first.status).toBe(200)
      const second = await req(service, '/open', { body: { runId: 'r2', url: 'http://x' } })
      expect(second.status).toBe(429)
    })
  })

  describe('external page close', () => {
    it('a page closing out from under the service (crash, external close) drops its tracked slot', async () => {
      const { launch, browser } = makeLaunch()
      const service = createService({ launch, tokensDir })
      await req(service, '/open', { body: { runId: 'r1', url: 'http://x' } })
      const page = browser.contexts[0].pages[0]

      // Simulate the page closing itself (not via /close) — e.g. a crash.
      await page.close()

      const after = await req(service, '/screenshot', { body: { runId: 'r1' } })
      expect(after.status).toBe(404)
      expect(after.json).toEqual({ error: 'unknown runId' })
    })
  })

  describe('closeContext (embedder API)', () => {
    it('closes one box user context and drops it from the caps', async () => {
      const { launch, browser } = makeLaunch()
      const service = createService({ launch, tokensDir })
      // Two authenticated boxes with open pages (contexts in open order).
      // Each box user's token file holds a DIFFERENT token (see beforeEach).
      await req(service, '/open', { user: 'box_abcdef012345', body: { runId: 'r1', url: 'http://x' } })
      await req(service, '/open', {
        user: 'box_fedcba987654',
        token: 'other-token',
        body: { runId: 'r2', url: 'http://x' },
      })
      const healthBefore = await req(service, '/healthz', { method: 'GET', user: null, token: null })
      expect((healthBefore.json as { contexts: number }).contexts).toBe(2)

      const closed = await service.closeContext('box_abcdef012345')
      expect(closed).toBe(true)
      // The closed box's context AND its page are closed...
      expect(browser.contexts[0].closed).toBe(true)
      expect(browser.contexts[0].pages[0].closed).toBe(true)
      // ...while the other box is untouched.
      expect(browser.contexts[1].closed).toBe(false)
      expect(browser.contexts[1].pages[0].closed).toBe(false)
      const healthAfter = await req(service, '/healthz', { method: 'GET', user: null, token: null })
      expect((healthAfter.json as { contexts: number; pages: number }).contexts).toBe(1)
      expect((healthAfter.json as { contexts: number; pages: number }).pages).toBe(1)
    })

    it('resolves false without throwing for an unknown box user', async () => {
      const service = createService({ ...makeLaunch(), tokensDir })
      await expect(service.closeContext('box_000000000000')).resolves.toBe(false)
    })
  })
})
