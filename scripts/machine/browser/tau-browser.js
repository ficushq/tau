// @ts-check
// tau-browser.service program — per-box BrowserContext, token auth, caps
// (browser-tools-in-sandbox spec §4.2, Phase 2). Serves a small JSON verb
// protocol over the unix socket: one Playwright BrowserContext per
// authenticated box user, run-id-keyed pages inside it. A box can never
// reach another box's context or pages — identity comes from auth, no verb
// accepts a context identifier.
//
// SINGLE SOURCE OF TRUTH: packages/machine-image/Dockerfile COPYs this file, and
// scripts/machine/bootstrap.sh (write_browser_service) embeds it verbatim
// (it is streamed standalone over SSH and cannot COPY siblings). bootstrap.test.ts
// asserts the two copies stay byte-identical.
import fs from 'node:fs'
import crypto from 'node:crypto'

const SOCK = process.env.FICUS_BROWSER_SOCK || '/run/tau-browser/sock'
// A SIBLING of /opt/tau/browser, not a child — install_browser recursively
// chown/chmods /opt/tau/browser to root:root + a+rX (every box user must
// read the browser binaries), which would world-expose token digests if they
// lived inside it.
const DEFAULT_TOKENS_DIR = '/opt/tau/browser-tokens'
const DEFAULT_MEMORY_HIGH_MB = 8192

const VIEWPORT = { width: 1280, height: 720 }
const MAX_CONSOLE_ENTRIES = 50
const MAX_PAGES_PER_BOX = 3
const MEMORY_MB_PER_PAGE = 256
const PAGE_IDLE_MS = 10 * 60 * 1000
const CONTEXT_IDLE_MS = 15 * 60 * 1000
const SWEEP_INTERVAL_MS = 60 * 1000

// Also the path-traversal defense for the token filename below.
const BOX_USER_RE = /^box_[0-9a-f]{12}$/

// A box-user name safe to interpolate into a token filename: alphanumerics,
// underscore and hyphen only — no '/', no '.', no NUL — so it can never traverse
// out of tokensDir. box_<hex> already satisfies this; this guard exists for the
// docker-dev escape hatch below (R-B17), whose allowed user is an arbitrary OS
// username and must be filename-safe before it reaches readFileSync.
function isSafeTokenUser(name) {
  return typeof name === 'string' && /^[A-Za-z0-9_-]+$/.test(name)
}

// A fixed-length decoy digest so a missing/invalid token file compares against
// something the same shape as a real sha256 digest (32 bytes) — the timing and
// code path stay identical to a real mismatch, never leaking "no such file" vs
// "wrong token" (R-B8).
const DECOY_DIGEST = crypto.createHash('sha256').update('decoy').digest()

function jsonResponse(status, body) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  })
}

function errorResponse(status, message) {
  return jsonResponse(status, { error: message })
}

/**
 * @param {number} status
 * @param {string} message
 * @returns {Error & { status: number }}
 */
function httpError(status, message) {
  const err = /** @type {Error & { status: number }} */ (new Error(message))
  err.status = status
  return err
}

function toBase64(data) {
  return (Buffer.isBuffer(data) ? data : Buffer.from(data)).toString('base64')
}

// SSRF guard (R-B9 / R-B14). Blocks host-local, link-local and cloud-metadata
// surfaces — used both by open()'s own check and the per-context route()
// handler below (defense in depth for redirects/iframes/subresources).
// Deliberately conservative: loopback + link-local + metadata names only.
// RFC1918 private ranges are NOT blocked (R-B15) — a box's `bash` already
// reaches them, so blocking only in-browser would be inconsistent.
//
// WHATWG URL normalizes hostnames but keeps IPv6 addresses bracketed
// ('[::1]') and can leave a trailing '.' on FQDNs — both defeated the naive
// string-equality/endsWith checks this replaces (R-B14 proof: [::1],
// [::ffff:127.0.0.1], [::ffff:169.254.169.254], [::], a trailing-dot
// metadata.google.internal., and a trailing-dot localhost. all slipped
// through). This version normalizes first, then checks.

function isBlockedIPv4(h) {
  const m = /^(\d{1,3})\.(\d{1,3})\.\d{1,3}\.\d{1,3}$/.exec(h)
  if (!m) return false
  if (h === '0.0.0.0') return true
  const first = Number(m[1])
  const second = Number(m[2])
  if (first === 127) return true // 127.0.0.0/8 (loopback)
  if (first === 169 && second === 254) return true // 169.254.0.0/16 (incl. the 169.254.169.254 cloud metadata IP)
  return false
}

// Converts a bare "hex:hex" IPv4-in-hex tail (the last 32 bits of an
// IPv4-mapped IPv6 address, e.g. "7f00:1") to dotted-quad. Returns null if
// the tail isn't that shape.
function hexPairToDottedQuad(tail) {
  const m = /^([0-9a-f]{1,4}):([0-9a-f]{1,4})$/i.exec(tail)
  if (!m) return null
  const hi = parseInt(m[1], 16)
  const lo = parseInt(m[2], 16)
  return [(hi >> 8) & 0xff, hi & 0xff, (lo >> 8) & 0xff, lo & 0xff].join('.')
}

function isBlockedIPv6(h) {
  // h is already lowercase with surrounding [ ] stripped.
  if (h === '::1' || h === '::') return true
  // Fully-expanded loopback ("0:0:0:0:0:0:0:1" and zero-padded variants) —
  // WHATWG URL always compresses to "::1", but this stays defensive against
  // any input that reaches isBlockedHost some other way.
  const groups = h.split(':')
  if (groups.length === 8 && groups.slice(0, 7).every((g) => /^0*$/.test(g)) && /^0*1$/.test(groups[7])) {
    return true
  }
  // IPv4-embedding IPv6 prefixes: IPv4-mapped (::ffff:a.b.c.d /
  // ::ffff:HHHH:HHHH), IPv4-translated (::ffff:0:0/96, one extra zero group
  // vs IPv4-mapped), and NAT64 well-known (64:ff9b::/96). Each embeds the
  // target as the low 32 bits, in either dotted-quad or bare hex-pair form —
  // extract and re-classify it as IPv4.
  for (const prefixRe of [/^::ffff:(.+)$/i, /^::ffff:0:(.+)$/i, /^64:ff9b::(.+)$/i]) {
    const m = prefixRe.exec(h)
    if (!m) continue
    const tail = m[1]
    const dotted = /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(tail) ? tail : hexPairToDottedQuad(tail)
    if (dotted && isBlockedIPv4(dotted)) return true
  }
  if (/^fe[89ab][0-9a-f]:/.test(h)) return true // fe80::/10 (link-local)
  if (/^f[cd][0-9a-f]{2}:/.test(h)) return true // fc00::/7 (unique-local)
  return false
}

function isBlockedHost(hostname) {
  let h = (hostname || '').toLowerCase()
  if (h.startsWith('[') && h.endsWith(']')) h = h.slice(1, -1)
  h = h.replace(/\.+$/, '') || h // strip ALL trailing FQDN root dots (guard: never reduce to '')
  if (h === 'localhost' || h === 'metadata' || h === 'metadata.google.internal') return true
  if (h.endsWith('.internal')) return true
  if (h.includes(':')) return isBlockedIPv6(h)
  return isBlockedIPv4(h)
}

// Installed on every BrowserContext (R-B9b). Applies to every request the
// context makes — top-level navigation, redirects, iframes, subresources —
// not just the `open` verb's initial goto, which only validates the URL the
// caller supplied. `blockedHost` is the host predicate in force for this
// service (the built-in one unless createService was given deps.isBlockedHost).
async function routeHandler(route, blockedHost = isBlockedHost) {
  let target
  try {
    target = new URL(route.request().url())
  } catch {
    await route.abort()
    return
  }
  const bad = !/^https?:$/.test(target.protocol) || blockedHost(target.hostname)
  if (bad) {
    await route.abort()
  } else {
    await route.continue()
  }
}

export function createService(deps = {}) {
  const launch =
    deps.launch ||
    (async () => {
      // Dynamic import: the default path is only ever evaluated if a real
      // launch actually happens. Tests always inject a fake `launch`, so the
      // test suite has zero load-time dependency on the `playwright` package
      // being installed (Phase 3 drops it from apps/core entirely).
      const { chromium } = await import('playwright')
      return chromium.launch({ headless: true })
    })
  const now = deps.now || Date.now
  const tokensDir = deps.tokensDir || process.env.FICUS_BROWSER_TOKENS_DIR || DEFAULT_TOKENS_DIR
  // Docker-dev-only escape hatch (R-B17): the docker sandbox's box server runs as
  // a plain OS user (root) whose name never matches BOX_USER_RE, so the prod
  // box_<hex> gate would 401 every in-container browser call. When — and ONLY
  // when — FICUS_BROWSER_DEV_ALLOW_USER is set (prod NEVER sets it; the systemd
  // unit does not carry it), also accept a box user equal to it, still
  // constrained by isSafeTokenUser so the token filename can't traverse. With the
  // env unset the auth path is byte-identical to box_<hex>-only.
  const devAllowUser = deps.devAllowUser || process.env.FICUS_BROWSER_DEV_ALLOW_USER || ''
  const memoryHighMb = deps.memoryHighMb || Number(process.env.FICUS_BROWSER_MEMORY_HIGH_MB) || DEFAULT_MEMORY_HIGH_MB
  // The SSRF host guard is injectable so an embedder whose browser has no more
  // network reach than the caller already has can turn it off (the host sandbox
  // runtime runs this engine in-process on the user's own machine, where the
  // agent's `bash` already reaches localhost). Unset — every machine host and
  // container — this is the built-in blocklist, unchanged.
  const blockedHost = deps.isBlockedHost || isBlockedHost
  // The disconnect policy is injectable: the host sandbox runtime runs this
  // engine IN-PROCESS inside the long-lived core, where process.exit(1) on a
  // Chrome crash would kill the api/worker. Unset — the systemd unit and the
  // docker box — the production default is unchanged: exit(1), systemd
  // restarts the unit.
  const onDisconnected = deps.onDisconnected || (() => process.exit(1))
  const pageCeiling = Math.max(1, Math.floor(memoryHighMb / MEMORY_MB_PER_PAGE))

  let browser = null
  let browserPromise = null

  // boxUser -> { context, lastUsed, pages: Map<runId, {page, consoleLogs, lastUsed}>, pagePromises: Map<runId, Promise> }
  // Structurally isolated: every lookup below is scoped through this map keyed
  // on the AUTHENTICATED box user — no verb ever accepts or looks up a
  // context/box identifier, so cross-context reach is not expressible.
  const contexts = new Map()
  // In-flight context creations, keyed by boxUser (R-B10 / C2 fix). Closes the
  // TOCTOU window where concurrent requests for the same box would each pass
  // "no existing context" and each call newContext().
  const contextPromises = new Map()

  function totalPages() {
    let n = 0
    for (const ctxEntry of contexts.values()) n += ctxEntry.pages.size
    return n
  }

  // Pages currently being created anywhere on the machine but not yet in any
  // ctxEntry.pages map — counted toward the machine ceiling so concurrent
  // opens can't all pass the same capacity check before any of them finishes
  // creating (R-B10 / proven C2: "498 leaked pages, caps bypassed").
  function totalPending() {
    let n = 0
    for (const ctxEntry of contexts.values()) n += ctxEntry.pagePromises.size
    return n
  }

  function resetState() {
    // Close the OLD browser before dropping our reference — otherwise a
    // transient newPage()/newContext() failure on a still-alive Chromium
    // (renderer crash, "Target closed", allocation failure under memory
    // pressure) leaks the process: every other box's pages silently stop
    // counting toward pageCeiling (contexts.clear()), and the next open()
    // launches a SECOND Chromium in the same cgroup — a MemoryHigh feedback
    // loop where the response to memory pressure doubles memory use.
    const old = browser
    browser = null
    browserPromise = null
    contexts.clear()
    if (old) old.close().catch(() => {})
  }

  async function getBrowser() {
    if (browser) return browser
    if (!browserPromise) {
      browserPromise = Promise.resolve()
        .then(() => launch())
        .then((b) => {
          browser = b
          // Real Chromium exposes `.on`; the plain fakes used by most tests
          // don't. Systemd restarts the unit on crash (Restart=on-failure);
          // every box gets a clean recovery once the service comes back up —
          // an embedder that injected a different onDisconnected policy gets
          // that policy resolved here instead of the exit.
          if (typeof b.on === 'function') {
            b.on('disconnected', onDisconnected)
          }
          return b
        })
        .catch(() => {
          resetState()
          throw httpError(502, 'browser restarted')
        })
    }
    return browserPromise
  }

  // Builds (but does not await here) a fresh context for boxUser. Synchronous
  // up to its first await, and the caller registers the returned promise into
  // contextPromises BEFORE any other code can run — see getOrCreateContext.
  function createContext(boxUser) {
    return (async () => {
      const b = await getBrowser()
      let context
      try {
        context = await b.newContext({ viewport: VIEWPORT, acceptDownloads: false })
        await context.route('**', (route) => routeHandler(route, blockedHost))
      } catch {
        resetState()
        throw httpError(502, 'browser restarted')
      }
      const ctxEntry = { context, lastUsed: now(), pages: new Map(), pagePromises: new Map() }
      contexts.set(boxUser, ctxEntry)
      return ctxEntry
    })()
  }

  async function getOrCreateContext(boxUser) {
    const existing = contexts.get(boxUser)
    if (existing) {
      existing.lastUsed = now()
      return existing
    }
    const inFlight = contextPromises.get(boxUser)
    if (inFlight) return inFlight

    const p = createContext(boxUser)
    contextPromises.set(boxUser, p)
    try {
      return await p
    } finally {
      contextPromises.delete(boxUser)
    }
  }

  // Returns whether a slot was actually freed. Only a REALIZED page
  // (ctxEntry.pages) can be evicted — an in-flight reservation
  // (ctxEntry.pagePromises) isn't a page yet, so during a concurrent burst
  // where every slot is pending, there is nothing to evict (R-B16).
  function evictLruPage(ctxEntry) {
    let lruRunId = null
    let lruTime = Infinity
    for (const [runId, pageEntry] of ctxEntry.pages) {
      if (pageEntry.lastUsed < lruTime) {
        lruTime = pageEntry.lastUsed
        lruRunId = runId
      }
    }
    if (lruRunId === null) return false
    const pageEntry = ctxEntry.pages.get(lruRunId)
    ctxEntry.pages.delete(lruRunId)
    pageEntry.page.close().catch(() => {})
    return true
  }

  // Builds (but does not await here) a fresh page for runId inside ctxEntry.
  // Synchronous up to its first await; the caller registers the returned
  // promise into ctxEntry.pagePromises before any other code can run.
  function createPage(ctxEntry, runId) {
    return (async () => {
      let page
      try {
        page = await ctxEntry.context.newPage()
      } catch {
        resetState()
        throw httpError(502, 'browser restarted')
      }
      const consoleLogs = []
      page.on('console', (msg) => {
        consoleLogs.push({ type: msg.type(), text: msg.text() })
        if (consoleLogs.length > MAX_CONSOLE_ENTRIES) consoleLogs.shift()
      })
      const pageEntry = { page, consoleLogs, lastUsed: now() }
      // The page closing out from under us (crash, external close) drops the
      // tracked entry so it doesn't linger as a phantom slot against the caps.
      page.on('close', () => {
        if (ctxEntry.pages.get(runId) === pageEntry) {
          ctxEntry.pages.delete(runId)
        }
      })
      ctxEntry.pages.set(runId, pageEntry)
      return pageEntry
    })()
  }

  async function openPage(boxUser, runId) {
    const ctxEntry = await getOrCreateContext(boxUser)

    // Everything from here to the pagePromises.set() below runs with NO
    // `await` in between — a single synchronous turn — so concurrent opens
    // for other runIds cannot interleave between the capacity check and the
    // reservation that accounts for it (R-B10 / proven C2).
    const existing = ctxEntry.pages.get(runId)
    if (existing) {
      existing.lastUsed = now()
      return existing
    }
    const inFlight = ctxEntry.pagePromises.get(runId)
    if (inFlight) return inFlight

    const occupied = ctxEntry.pages.size + ctxEntry.pagePromises.size
    if (occupied >= MAX_PAGES_PER_BOX) {
      // A same-box LRU swap nets ZERO change to the machine-wide total (one
      // realized page leaves, one reservation joins), so it never needs the
      // ceiling check below — but if every one of this box's slots is
      // currently in-flight (a concurrent burst), there is nothing realized
      // to swap: reject rather than silently let the box exceed its own cap
      // (R-B16; proven: 10 concurrent opens on one box produced 10 live
      // pages because eviction only ever looked at ctxEntry.pages, which
      // stays empty until each page finishes creating).
      if (!evictLruPage(ctxEntry)) {
        throw httpError(429, `this box already has ${MAX_PAGES_PER_BOX} pages opening, retry shortly`)
      }
    } else if (totalPages() + totalPending() >= pageCeiling) {
      // A genuine net-new page against the machine-wide budget (not an
      // own-box swap, so it can't be absorbed by an eviction above).
      throw httpError(429, 'browser at capacity on this machine, retry shortly')
    }

    const p = createPage(ctxEntry, runId)
    ctxEntry.pagePromises.set(runId, p)
    try {
      return await p
    } finally {
      ctxEntry.pagePromises.delete(runId)
    }
  }

  // The ONLY way any verb reaches a page — scoped to the authenticated box's
  // own context, never any other box's.
  function getPage(boxUser, runId) {
    const ctxEntry = contexts.get(boxUser)
    if (!ctxEntry) return null
    const pageEntry = ctxEntry.pages.get(runId)
    if (!pageEntry) return null
    ctxEntry.lastUsed = now()
    pageEntry.lastUsed = now()
    return pageEntry
  }

  async function closePage(boxUser, runId) {
    const ctxEntry = contexts.get(boxUser)
    if (!ctxEntry) return
    const pageEntry = ctxEntry.pages.get(runId)
    if (!pageEntry) return
    ctxEntry.pages.delete(runId)
    try {
      await pageEntry.page.close()
    } catch {}
  }

  function sweepIdle() {
    const t = now()
    for (const [boxUser, ctxEntry] of contexts) {
      for (const [runId, pageEntry] of ctxEntry.pages) {
        if (t - pageEntry.lastUsed >= PAGE_IDLE_MS) {
          ctxEntry.pages.delete(runId)
          pageEntry.page.close().catch(() => {})
        }
      }
      if (t - ctxEntry.lastUsed >= CONTEXT_IDLE_MS) {
        contexts.delete(boxUser)
        for (const pageEntry of ctxEntry.pages.values()) {
          pageEntry.page.close().catch(() => {})
        }
        ctxEntry.context.close().catch(() => {})
      }
    }
  }

  // Programmatic close of one box's context — for the in-process host
  // embedder, which knows sandboxId -> boxUser and must not wait for the
  // 15-min idle sweep when a sandbox stops. The HTTP verb protocol never
  // accepts a box identifier; this is an embedder-only API. An in-flight
  // context creation for the same user may still land after a close — the
  // idle sweep collects it later, same race the engine already has.
  function closeContext(boxUser) {
    const ctxEntry = contexts.get(boxUser)
    if (!ctxEntry) return Promise.resolve(false)
    contexts.delete(boxUser)
    const closers = []
    for (const pageEntry of ctxEntry.pages.values()) closers.push(pageEntry.page.close().catch(() => {}))
    closers.push(ctxEntry.context.close().catch(() => {}))
    return Promise.all(closers).then(() => true)
  }

  // R-B8: token files store sha256(token) as 64 lowercase hex chars, NEVER the
  // raw token — a digest leaked via a misconfigured file:// serve or a
  // mis-permissioned file is unreplayable. Task 4's writer must write digests,
  // not raw tokens. We hash the bearer token from the request and compare
  // digests, always through a fixed-length timingSafeEqual (real digest or the
  // DECOY_DIGEST placeholder above) so an invalid/missing file takes the same
  // code path and shape as a genuine mismatch — never leaking which it was.
  function checkAuth(req) {
    const boxUser = req.headers.get('x-tau-box-user') || ''
    const authHeader = req.headers.get('authorization') || ''
    const match = /^Bearer (.+)$/.exec(authHeader)
    // Prod gate: box_<hex> only. R-B17 dev escape hatch: additionally accept a
    // user equal to the (prod-unset) FICUS_BROWSER_DEV_ALLOW_USER, still
    // filename-safe. isSafeTokenUser is redundant for BOX_USER_RE matches but
    // mandatory for the dev user before it reaches readFileSync below.
    const allowed =
      BOX_USER_RE.test(boxUser) || (devAllowUser !== '' && boxUser === devAllowUser && isSafeTokenUser(boxUser))
    if (!allowed || !match) return null

    const provided = match[1]
    let storedHex = null
    try {
      storedHex = fs.readFileSync(`${tokensDir}/${boxUser}.token`, 'utf8').trim()
    } catch {
      // Missing token file — falls through to the same generic failure as a
      // mismatch below.
    }
    const validHex = typeof storedHex === 'string' && /^[0-9a-f]{64}$/i.test(storedHex)
    const providedDigest = crypto.createHash('sha256').update(provided).digest()
    const storedDigest = validHex ? Buffer.from(storedHex, 'hex') : DECOY_DIGEST
    const matches = crypto.timingSafeEqual(providedDigest, storedDigest)
    if (!validHex || !matches) return null
    return boxUser
  }

  async function routeVerb(verb, boxUser, body) {
    const runId = body && body.runId

    if (verb === 'open') {
      // R-B9a: validate the scheme of the caller-supplied URL before ever
      // touching page/context state. The per-context route (installed at
      // context creation) is the defense-in-depth layer that also covers
      // redirects/iframes/subresources — this is just the top-level check.
      let parsedUrl
      try {
        parsedUrl = new URL(body.url)
      } catch {
        throw httpError(400, 'invalid url')
      }
      if (parsedUrl.protocol !== 'http:' && parsedUrl.protocol !== 'https:') {
        throw httpError(400, 'invalid url')
      }
      // R-B14: open() enforces the SSRF guard itself — the primary attack
      // (opening a host-local/metadata URL directly) must not depend solely
      // on the per-context route() handler below.
      if (blockedHost(parsedUrl.hostname)) {
        throw httpError(400, 'invalid url')
      }
      const pageEntry = await openPage(boxUser, runId)
      await pageEntry.page.goto(parsedUrl.href, { waitUntil: 'domcontentloaded', timeout: 30000 })
      const title = await pageEntry.page.title()
      const screenshot = await pageEntry.page.screenshot({ type: 'png' })
      return jsonResponse(200, { title, screenshotBase64: toBase64(screenshot) })
    }

    if (verb === 'close') {
      await closePage(boxUser, runId)
      return jsonResponse(200, { ok: true })
    }

    const pageEntry = getPage(boxUser, runId)
    if (!pageEntry) throw httpError(404, 'unknown runId')

    switch (verb) {
      case 'click': {
        if (body.selector) {
          await pageEntry.page.locator(body.selector).click({ timeout: 5000 })
        } else if (body.x != null && body.y != null) {
          await pageEntry.page.mouse.click(body.x, body.y)
        } else {
          throw httpError(400, 'Provide either a selector or x/y coordinates.')
        }
        const result = { ok: true }
        if (body.returnScreenshot === true) {
          result.screenshotBase64 = toBase64(await pageEntry.page.screenshot({ type: 'png' }))
        }
        return jsonResponse(200, result)
      }
      case 'type': {
        if (body.selector) {
          await pageEntry.page.locator(body.selector).fill(body.text, { timeout: 5000 })
        } else {
          await pageEntry.page.keyboard.type(body.text)
        }
        const result = { ok: true }
        if (body.returnScreenshot === true) {
          result.screenshotBase64 = toBase64(await pageEntry.page.screenshot({ type: 'png' }))
        }
        return jsonResponse(200, result)
      }
      case 'scroll': {
        const delta = (body.amount ?? 500) * (body.direction === 'up' ? -1 : 1)
        await pageEntry.page.mouse.wheel(0, delta)
        await pageEntry.page.waitForTimeout(300)
        const result = { deltaPx: delta }
        if (body.returnScreenshot === true) {
          result.screenshotBase64 = toBase64(await pageEntry.page.screenshot({ type: 'png' }))
        }
        return jsonResponse(200, result)
      }
      case 'screenshot': {
        const screenshot = await pageEntry.page.screenshot({ type: 'png' })
        return jsonResponse(200, { screenshotBase64: toBase64(screenshot) })
      }
      case 'read': {
        const text = body.selector
          ? ((await pageEntry.page.locator(body.selector).textContent({ timeout: 5000 })) ?? '')
          : await pageEntry.page.evaluate(() => document.body.innerText)
        return jsonResponse(200, { text })
      }
      case 'console': {
        return jsonResponse(200, { entries: pageEntry.consoleLogs })
      }
      default:
        throw httpError(404, 'unknown verb')
    }
  }

  async function fetchHandler(req) {
    const url = new URL(req.url)

    if (req.method === 'GET' && url.pathname === '/healthz') {
      return jsonResponse(200, { ok: true, pages: totalPages(), contexts: contexts.size })
    }
    if (req.method !== 'POST') {
      return errorResponse(404, 'not found')
    }

    const boxUser = checkAuth(req)
    if (!boxUser) return errorResponse(401, 'unauthorized')

    let body
    try {
      body = await req.json()
    } catch {
      return errorResponse(400, 'invalid JSON body')
    }
    if (body === null || typeof body !== 'object') {
      return errorResponse(400, 'invalid JSON body')
    }

    const verb = url.pathname.slice(1)
    try {
      return await routeVerb(verb, boxUser, body)
    } catch (err) {
      const status = (err && err.status) || 500
      const message = err && err.status ? err.message : err instanceof Error ? err.message : String(err)
      return errorResponse(status, message)
    }
  }

  const sweepTimer = setInterval(sweepIdle, SWEEP_INTERVAL_MS)
  if (typeof sweepTimer.unref === 'function') sweepTimer.unref()

  function shutdown() {
    clearInterval(sweepTimer)
    const closers = []
    for (const ctxEntry of contexts.values()) {
      for (const pageEntry of ctxEntry.pages.values()) {
        closers.push(pageEntry.page.close().catch(() => {}))
      }
      closers.push(ctxEntry.context.close().catch(() => {}))
    }
    contexts.clear()
    const b = browser
    browser = null
    browserPromise = null
    if (b) closers.push(b.close().catch(() => {}))
    return Promise.all(closers)
  }

  return { fetch: fetchHandler, shutdown, sweepIdle, closeContext }
}

if (import.meta.main) {
  const service = createService()

  try {
    fs.unlinkSync(SOCK)
  } catch {}

  Bun.serve({ unix: SOCK, fetch: service.fetch, maxRequestBodySize: 1 << 20 })

  try {
    fs.chmodSync(SOCK, 0o660)
  } catch (err) {
    console.error('tau-browser: could not chmod socket', err)
  }

  const onShutdown = () => {
    service.shutdown().finally(() => process.exit(0))
  }
  process.on('SIGTERM', onShutdown)
  process.on('SIGINT', onShutdown)
}
