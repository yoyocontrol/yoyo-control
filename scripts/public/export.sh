#!/usr/bin/env bash
# The open-source tree of this repository, for the public one (github.com/yoyocontrol/yoyo-control):
#
#   scripts/public/export.sh <dir>
#
# <dir> is a clone of the public repository (or an empty directory): everything in it but .git is replaced by the
# tracked files scripts/public/paths.txt selects, with scripts/public/README.md as the README and the root
# package.json's workspaces limited to what is there; then the checks below. Commit and push there yourself.
#
# Checks (any failure: exit 1, nothing to commit):
#   - the private-string list (scripts/check-private.mjs --dir, the list required);
#   - no Yoyo Control service address in code: none is built in anywhere public (docs may name them);
#   - none of the product's paths slipped in.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(git -C "$here" rev-parse --show-toplevel)
out=${1:?usage: $0 <dir>}
mkdir -p "$out"
out=$(cd "$out" && pwd)
[ "$out" != "$root" ] || { echo "export.sh: not into this checkout" >&2; exit 2; }

# select
list=$(mktemp "${TMPDIR:-/tmp}/yoyo-export.XXXXXX")
trap 'rm -f "$list"' EXIT
git -C "$root" ls-files -z | node -e '
  const fs = require("fs");
  const rules = fs.readFileSync(process.argv[1], "utf8").split("\n").map((l) => l.trim()).filter((l) => l && !l.startsWith("#"));
  const files = fs.readFileSync(0, "utf8").split("\0").filter(Boolean);
  const hit = (f, p) => (p.endsWith("/") ? f.startsWith(p) : f === p);
  for (const f of files) {
    let keep = false;
    for (const r of rules) if (hit(f, r.slice(1))) keep = r[0] === "+";
    if (keep && fs.existsSync(process.argv[2] + "/" + f)) console.log(f);
  }
' "$here/paths.txt" "$root" > "$list"

# replace
find "$out" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
(cd "$root" && tr '\n' '\0' < "$list" | xargs -0 -I{} sh -c 'mkdir -p "$1/$(dirname "$2")" && cp -p "$2" "$1/$2"' _ "$out" {})
cp "$here/README.md" "$out/README.md"
node -e '
  const fs = require("fs");
  const f = process.argv[1] + "/package.json";
  const p = JSON.parse(fs.readFileSync(f, "utf8"));
  p.workspaces = ["packages/*"];
  p.description = "Yoyo Control'"'"'s TypeScript kits (packages/*).";
  fs.writeFileSync(f, JSON.stringify(p, null, 2) + "\n");
' "$out"
echo "export.sh: $(wc -l < "$list" | tr -d ' ') files into $out"

# check
fail=0
node "$root/scripts/check-private.mjs" --require --dir "$out" || fail=1
# (access tokens and the private repository's owner are entries of the private list: checked above, named nowhere here)
code=$(cd "$out" && grep -rlE --exclude='*.md' --exclude-dir=.git -e 'yoyocontrol\.com' . || true)
if [ -n "$code" ]; then
  echo "export.sh: a Yoyo Control service address in code (none may be built in):" >&2
  echo "$code" >&2
  fail=1
fi
for p in ios/App mac/Sources/YoyoApp mac/Sources/yoyo-control relay web webapp .github ios/YoyoKit/Sources/YoyoPro CLAUDE.md; do
  if [ -e "$out/$p" ]; then echo "export.sh: product path $p is in the tree" >&2; fail=1; fi
done
[ $fail = 0 ] || exit 1
echo "export.sh: checks passed"
