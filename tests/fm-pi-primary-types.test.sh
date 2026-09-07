#!/usr/bin/env bash
# Strict no-emit contract check for the tracked Firstmate Pi extensions.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v npm >/dev/null 2>&1 || { echo "skip: npm not found for Pi extension typecheck"; exit 0; }
command -v tsc >/dev/null 2>&1 || { echo "skip: tsc not found for Pi extension typecheck"; exit 0; }

PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g)/@earendil-works/pi-coding-agent"}
if [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
  echo "skip: installed @earendil-works/pi-coding-agent package not found"
  exit 0
fi

# Pi 0.85 nests dependencies below its package while the isolated 0.84.4 runtime
# installs them alongside it.  Match Node's extension resolution instead of tying
# the type contract to one npm layout.
pi_dependency_dir() {
  node - "$1" "$PI_PACKAGE_DIR" <<'NODE'
const [name, packageRoot] = process.argv.slice(2);
const { dirname, join } = require("node:path");
const { existsSync } = require("node:fs");
// Resolve the same node_modules ancestry Pi's extension imports traverse.  Some
// Pi dependencies intentionally export no package entry, so require.resolve(name)
// alone cannot find their package root.
for (let directory = packageRoot; ; directory = dirname(directory)) {
  const candidate = join(directory, "node_modules", name);
  if (existsSync(join(candidate, "package.json"))) {
    console.log(candidate);
    process.exit(0);
  }
  const parent = dirname(directory);
  if (parent === directory) break;
}
throw new Error(`package root not found for ${name}`);
NODE
}

PI_TUI_PACKAGE_DIR=$(pi_dependency_dir "@earendil-works/pi-tui") || \
  fail "installed Pi package is missing pi-tui"
PI_AI_PACKAGE_DIR=$(pi_dependency_dir "@earendil-works/pi-ai") || \
  fail "installed Pi package is missing pi-ai"
TYPEBOX_PACKAGE_DIR=$(pi_dependency_dir "typebox") || \
  fail "installed Pi package is missing typebox"
NODE_TYPES_PACKAGE_DIR=$(pi_dependency_dir "@types/node") || \
  fail "installed Pi package is missing Node declarations"
if [ ! -d "$PI_TUI_PACKAGE_DIR" ] || [ ! -d "$PI_AI_PACKAGE_DIR" ] || \
   [ ! -d "$TYPEBOX_PACKAGE_DIR" ] || [ ! -d "$NODE_TYPES_PACKAGE_DIR" ]; then
  echo "not ok - installed Pi package is missing pi-tui, pi-ai, typebox, or Node declarations" >&2
  exit 1
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-primary-types.XXXXXX")
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$TMP_ROOT/lib" "$TMP_ROOT/node_modules/@earendil-works" "$TMP_ROOT/node_modules/@types"
cp "$ROOT/.pi/extensions/fm-branch-supervision.ts" "$TMP_ROOT/fm-branch-supervision.ts"
cp "$ROOT/.pi/extensions/fm-calm.ts" "$TMP_ROOT/fm-calm.ts"
cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$TMP_ROOT/fm-primary-pi-watch.ts"
cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$TMP_ROOT/fm-primary-turnend-guard.ts"
cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$TMP_ROOT/lib/fm-branch-dispatch.ts"
cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$TMP_ROOT/lib/fm-async-exec.ts"
cp "$ROOT/.pi/extensions/lib/fm-branch-model-picker.ts" "$TMP_ROOT/lib/fm-branch-model-picker.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-assistant-layout.ts" "$TMP_ROOT/lib/fm-calm-assistant-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-operational-user-layout.ts" "$TMP_ROOT/lib/fm-calm-operational-user-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$TMP_ROOT/lib/fm-calm-visibility.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-working-ship.ts" "$TMP_ROOT/lib/fm-calm-working-ship.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$TMP_ROOT/lib/fm-operational-input.ts"
ln -s "$PI_PACKAGE_DIR" "$TMP_ROOT/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PI_TUI_PACKAGE_DIR" "$TMP_ROOT/node_modules/@earendil-works/pi-tui"
ln -s "$PI_AI_PACKAGE_DIR" "$TMP_ROOT/node_modules/@earendil-works/pi-ai"
ln -s "$TYPEBOX_PACKAGE_DIR" "$TMP_ROOT/node_modules/typebox"
ln -s "$NODE_TYPES_PACKAGE_DIR" "$TMP_ROOT/node_modules/@types/node"

cat > "$TMP_ROOT/package.json" <<'JSON'
{"type":"module"}
JSON
cat > "$TMP_ROOT/tsconfig.json" <<'JSON'
{
  "compilerOptions": {
    "allowImportingTsExtensions": true,
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "noEmit": true,
    "skipLibCheck": true,
    "strict": true,
    "target": "ES2022",
    "types": ["node"]
  },
  "include": ["*.ts", "lib/*.ts"]
}
JSON

tsc -p "$TMP_ROOT/tsconfig.json" || exit 1
version=$(jq -r '.version' "$PI_PACKAGE_DIR/package.json" 2>/dev/null || printf 'unknown')
printf 'ok - tracked Pi extensions pass strict no-emit typecheck against Pi %s\n' "$version"
