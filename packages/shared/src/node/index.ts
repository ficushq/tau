// Node-only helpers, reachable as `@ficus/shared/node`.
//
// Deliberately NOT re-exported from the `@ficus/shared` barrel (src/index.ts):
// that barrel is imported by apps/web, and dragging a node builtin into the
// browser bundle breaks the vite build — the same reason `./crypto` sits behind
// its own subpath. Server code (apps/core, apps/cli, the hosted control plane) imports
// this path directly.
export * from './tilde'
export * from './local-install-env'
