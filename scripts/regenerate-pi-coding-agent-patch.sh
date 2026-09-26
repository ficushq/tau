#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PI_MONO_DIR="${PI_MONO_DIR:-$ROOT_DIR/../../pi-mono}"
PACKAGE="@earendil-works/pi-coding-agent"
EXPECTED_REF="f07218c4d4bbc12bef056a7058c3dd49dfe41abe"
EXPECTED_AI_TARBALL_SHA1="7d1f174120d5e6d33f301503677ec3281f217e2a"
EXPECTED_CODING_AGENT_TARBALL_SHA1="5708b9310325177d5c1b487b5c99627ffa733324"
SOURCE_ROOT="$ROOT_DIR/patches/pi-coding-agent-0.87.1-source"
PATCH_ARTIFACT="$ROOT_DIR/patches/@earendil-works%2Fpi-coding-agent@0.87.1.patch"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
ORIGINAL_PATCH="$TEMP_DIR/original.patch"
WRITE_MODE=0

SOURCE_FILES=(
  packages/coding-agent/src/core/agent-session.ts
  packages/coding-agent/src/core/extensions/loader.ts
  packages/coding-agent/src/core/index.ts
  packages/coding-agent/src/core/sdk.ts
  packages/coding-agent/src/core/tools/read.ts
  packages/coding-agent/src/index.ts
)
OUTPUT_FILES=(
  dist/core/agent-session.d.ts
  dist/core/agent-session.d.ts.map
  dist/core/agent-session.js
  dist/core/agent-session.js.map
  dist/core/extensions/loader.d.ts.map
  dist/core/extensions/loader.js
  dist/core/extensions/loader.js.map
  dist/core/index.d.ts
  dist/core/index.d.ts.map
  dist/core/index.js
  dist/core/index.js.map
  dist/core/sdk.d.ts
  dist/core/sdk.d.ts.map
  dist/core/sdk.js
  dist/core/sdk.js.map
  dist/core/tools/read.d.ts
  dist/core/tools/read.d.ts.map
  dist/core/tools/read.js
  dist/core/tools/read.js.map
  dist/index.d.ts
  dist/index.d.ts.map
  dist/index.js
  dist/index.js.map
)

if [[ "${1:-}" == "--write" ]]; then
  WRITE_MODE=1
elif [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--write]" >&2
  exit 2
fi
if ! node -e 'const [major, minor] = process.versions.node.split(".").map(Number); process.exit(major > 22 || (major === 22 && minor >= 19) ? 0 : 1)'; then
  echo "Pi patch regeneration requires Node.js >=22.19" >&2
  exit 1
fi

cd "$ROOT_DIR"
if [[ "$(git -C "$PI_MONO_DIR" rev-parse HEAD)" != "$EXPECTED_REF" ]] ||
   [[ -n "$(git -C "$PI_MONO_DIR" status --porcelain --untracked-files=all)" ]]; then
  echo "pi-mono must be clean and pinned to $EXPECTED_REF" >&2
  exit 1
fi
for source_file in "${SOURCE_FILES[@]}"; do
  test -f "$SOURCE_ROOT/$source_file" || { echo "Missing source overlay: $source_file" >&2; exit 1; }
done
test -f "$PATCH_ARTIFACT" || { echo "Missing committed patch artifact" >&2; exit 1; }
cp "$PATCH_ARTIFACT" "$ORIGINAL_PATCH"

FICUS_VERSION="$(node -p "require('./apps/core/package.json').dependencies['$PACKAGE']")"
test "$FICUS_VERSION" = 0.87.1 || { echo "Expected Tau dependency 0.87.1" >&2; exit 1; }

manifest_outputs() {
  local root="$1"
  for file in "${OUTPUT_FILES[@]}"; do
    sha256sum "$root/$file" | sed "s|$root/||"
  done
}

manifest_unmodified() {
  local root="$1"
  (
    cd "$root"
    find . -type f -print0 | sort -z | while IFS= read -r -d '' file; do
      local_path="${file#./}"
      skip=0
      for output in "${OUTPUT_FILES[@]}"; do
        [[ "$local_path" == "$output" ]] && skip=1 && break
      done
      [[ "$skip" -eq 1 ]] || sha256sum "$local_path"
    done
  )
}

build_isolated() {
  local label="$1"
  local dir="$TEMP_DIR/$label" cache="$TEMP_DIR/cache-$label" pack="$TEMP_DIR/pack-$label"
  local pristine_package="$TEMP_DIR/$label-package-pristine"
  git clone --quiet --no-hardlinks "$PI_MONO_DIR" "$dir"
  git -C "$dir" checkout --quiet --detach "$EXPECTED_REF"
  test -z "$(git -C "$dir" status --porcelain --untracked-files=all)"
  test "$(git -C "$dir" hash-object package.json)" = "$(git -C "$dir" rev-parse "$EXPECTED_REF:package.json")"
  test "$(git -C "$dir" hash-object package-lock.json)" = "$(git -C "$dir" rev-parse "$EXPECTED_REF:package-lock.json")"
  test ! -d "$dir/node_modules"
  test -z "$(find "$dir/packages" -type d -name dist -print -quit)"

  # Bun cannot import this upstream npm lock's duplicate workspace entries.
  # Use the committed build-only lock, with the same pinned compiler versions.
  # Pristine output must still match the published tarball byte for byte below.
  cp "$SOURCE_ROOT/bun.lock" "$dir/bun.lock"
  (cd "$dir" && BUN_INSTALL_CACHE_DIR="$cache" bun install --frozen-lockfile --ignore-scripts --linker hoisted >/dev/null)
  # Upstream build scripts invoke npm recursively. Use Bun for those same
  # script commands in this disposable clone; dependency pins stay untouched.
  node --input-type=module - "$dir" <<'NODE'
import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
const root = process.argv[2];
function update(dir) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === 'node_modules' || entry.name === '.git') continue;
    const path = join(dir, entry.name);
    if (entry.isDirectory()) update(path);
    else if (entry.name === 'package.json') {
      const pkg = JSON.parse(readFileSync(path, 'utf8'));
      if (!pkg.scripts) continue;
      for (const key of Object.keys(pkg.scripts)) pkg.scripts[key] = pkg.scripts[key].replaceAll('npm run ', 'bun run ');
      writeFileSync(path, JSON.stringify(pkg, null, 2) + '\n');
    }
  }
}
update(root);
NODE
  mkdir -p "$pack/ai" "$pack/coding"
  local ai_tarball="$pack/ai/earendil-works-pi-ai-0.87.1.tgz"
  curl --fail --silent --show-error --location "https://registry.npmjs.org/@earendil-works/pi-ai/-/pi-ai-$FICUS_VERSION.tgz" --output "$ai_tarball"
  test "$(sha1sum "$ai_tarball" | cut -d' ' -f1)" = "$EXPECTED_AI_TARBALL_SHA1"
  tar -xzf "$ai_tarball" -C "$pack/ai"
  mkdir -p "$dir/packages/ai/src/providers/data"
  cp "$pack/ai/package/dist/providers/data/"*.json "$dir/packages/ai/src/providers/data/"
  cp "$pack/ai/package/dist/providers/data/.manifest.json" "$dir/packages/ai/src/providers/data/"

  local coding_tarball="$pack/coding/earendil-works-pi-coding-agent-0.87.1.tgz"
  curl --fail --silent --show-error --location "https://registry.npmjs.org/@earendil-works/pi-coding-agent/-/pi-coding-agent-$FICUS_VERSION.tgz" --output "$coding_tarball"
  test "$(sha1sum "$coding_tarball" | cut -d' ' -f1)" = "$EXPECTED_CODING_AGENT_TARBALL_SHA1"
  tar -xzf "$coding_tarball" -C "$pack/coding"
  mv "$pack/coding/package" "$pristine_package"

  (cd "$dir" && bun run build:offline)
  for output in "${OUTPUT_FILES[@]}"; do
    cmp "$dir/packages/coding-agent/$output" "$pristine_package/$output" || {
      echo "Pristine source build does not reproduce published output: $output" >&2
      exit 1
    }
  done

  for source_file in "${SOURCE_FILES[@]}"; do
    cp "$SOURCE_ROOT/$source_file" "$dir/$source_file"
  done
  (cd "$dir/packages/coding-agent" && bun run build)
  bun "$ROOT_DIR/.github/pi-agent-session-dataflow-cli.ts" \
    "$dir/packages/coding-agent/src/core/agent-session.ts" \
    "$dir/packages/coding-agent/dist/core/agent-session.js"
  manifest_outputs "$dir/packages/coding-agent" > "$TEMP_DIR/$label.outputs.manifest"
}

generate_patch() {
  local label="$1"
  local source_package="$TEMP_DIR/$label/packages/coding-agent"
  local pristine_package="$TEMP_DIR/$label-package-pristine"
  local candidate="$TEMP_DIR/$label-candidate" verify="$TEMP_DIR/$label-verify"
  local generated="$TEMP_DIR/$label.patch"
  cp -a "$pristine_package" "$candidate"
  cp -a "$pristine_package" "$verify"

  git -C "$candidate" init --quiet
  git -C "$candidate" config user.name tau-pi-regenerator
  git -C "$candidate" config user.email tau-pi-regenerator.invalid
  git -C "$candidate" add -f .
  git -C "$candidate" commit --quiet -m pristine
  for output in "${OUTPUT_FILES[@]}"; do
    cp "$source_package/$output" "$candidate/$output"
  done
  git -C "$candidate" diff --binary --no-ext-diff --src-prefix=a/ --dst-prefix=b/ HEAD -- "${OUTPUT_FILES[@]}" > "$generated"
  test -s "$generated"

  manifest_unmodified "$verify" > "$TEMP_DIR/$label.before.manifest"
  git -C "$verify" apply "$generated"
  for output in "${OUTPUT_FILES[@]}"; do
    cmp "$verify/$output" "$source_package/$output"
  done
  manifest_unmodified "$verify" > "$TEMP_DIR/$label.after.manifest"
  cmp "$TEMP_DIR/$label.before.manifest" "$TEMP_DIR/$label.after.manifest"
}

echo "Pi regeneration stage: pristine and reviewed-overlay build run-a"
build_isolated run-a
echo "Pi regeneration stage: pristine and reviewed-overlay build run-b"
build_isolated run-b
cmp "$TEMP_DIR/run-a.outputs.manifest" "$TEMP_DIR/run-b.outputs.manifest"
echo "Reviewed overlay outputs are byte-identical; generating portable patch run-a"
generate_patch run-a
echo "Pi regeneration stage: generate portable patch run-b"
generate_patch run-b
GENERATED_PATCH_A="$TEMP_DIR/run-a.patch"
GENERATED_PATCH_B="$TEMP_DIR/run-b.patch"
cmp "$GENERATED_PATCH_A" "$GENERATED_PATCH_B"
echo "Portable generated patches are byte-identical"

if cmp -s "$ORIGINAL_PATCH" "$GENERATED_PATCH_A"; then
  echo "Regenerated patch is byte-identical to the committed artifact"
  exit 0
fi
if [[ "$WRITE_MODE" -eq 1 ]]; then
  cp "$GENERATED_PATCH_A" "$PATCH_ARTIFACT"
  echo "Regenerated patch for $PACKAGE@$FICUS_VERSION (--write)"
  exit 0
fi
echo "Regenerated Pi patch drifted from the committed artifact" >&2
echo "Committed artifact was not modified; rerun with --write only for an intentional reviewed update" >&2
exit 1
