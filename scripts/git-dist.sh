#!/usr/bin/env bash
# Publish a TypeScript kit (packages/<pkg>) as a git dependency, without a registry:
#
#   scripts/git-dist.sh <pkg> <version> [--no-push]
#
# 1. checks that packages/<pkg>/package.json says <version> and that tag <pkg>-v<version> doesn't exist yet
#    (a published version never moves: change the kit → bump the patch version);
# 2. builds the workspace kits it depends on (their dist/ for its types), then builds and tests the package from the
#    current checkout (its HEAD must be committed: the dist commit names it);
# 3. commits what npm would install — package.json (without scripts / devDependencies; a dependency on another kit
#    becomes that kit's tag at its current version, which must be published already), dist/, README.md — on the
#    orphan branch dist/<pkg> (one commit per version, each on top of the previous one), without touching the
#    working tree;
# 4. tags that commit <pkg>-v<version> and pushes the branch and the tag to origin (unless --no-push).
#
# Consumers depend on the tag:  "@yoyocontrol/<pkg>": "git+https://github.com/yoyocontrol/yoyo-control.git#<pkg>-v<version>"
# Run it in a clone of the public repository (scripts/public/export.sh): its origin is what the tags name. The URL is
# https (anyone can fetch it); GIT_DIST_URL overrides it.
# GIT_DIST_TRAILER (optional) is appended to the commit and tag messages (e.g. a Co-Authored-By line).
set -euo pipefail

usage() { echo "usage: $0 <pkg> <version> [--no-push]" >&2; exit 2; }
[ $# -ge 2 ] || usage
pkg=$1
version=$2
push=1
[ "${3:-}" = "--no-push" ] && push=0

root=$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)
dir="$root/packages/$pkg"
[ -f "$dir/package.json" ] || { echo "no package at packages/$pkg" >&2; exit 1; }
branch="dist/$pkg"
tag="$pkg-v$version"

have=$(node -p "require(process.argv[1]).version" "$dir/package.json")
[ "$have" = "$version" ] || { echo "packages/$pkg/package.json says $have, not $version: bump it first" >&2; exit 1; }
if git -C "$root" rev-parse -q --verify "refs/tags/$tag" >/dev/null || git -C "$root" ls-remote --exit-code --tags origin "$tag" >/dev/null 2>&1; then
  echo "tag $tag exists already: a published version never moves (bump the version)" >&2
  exit 1
fi
if [ -n "$(git -C "$root" status --porcelain -- "packages/$pkg" package.json package-lock.json tsconfig.base.json)" ]; then
  echo "packages/$pkg has uncommitted changes: commit them first (the dist commit names its source)" >&2
  exit 1
fi
source_sha=$(git -C "$root" rev-parse HEAD)

remote=${GIT_DIST_URL:-$(git -C "$root" remote get-url origin | sed -E 's#^git@([^:]+):#https://\1/#; s#^ssh://git@#https://#')}
# the other kits it uses (dependencies, peer and dev dependencies that are packages/* here)
kits=$(node -e '
  const p = require(process.argv[1]);
  const names = Object.keys({ ...p.dependencies, ...p.peerDependencies, ...p.devDependencies });
  console.log(names.filter((n) => n.startsWith("@yoyocontrol/")).map((n) => n.slice(13)).join(" "));
' "$dir/package.json")
for kit in $kits; do
  [ -f "$root/packages/$kit/package.json" ] || continue
  echo "building $kit (a kit $pkg uses)"
  npm --prefix "$root/packages/$kit" run build
done
# a runtime dependency on another kit points at that kit's tag (there is no registry to resolve a range from)
deps=$(node -e '
  const p = require(process.argv[1]);
  for (const n of Object.keys(p.dependencies ?? {})) if (n.startsWith("@yoyocontrol/")) console.log(n.slice(13));
' "$dir/package.json")
for kit in $deps; do
  [ -f "$root/packages/$kit/package.json" ] || continue
  kv=$(node -p "require(process.argv[1]).version" "$root/packages/$kit/package.json")
  if ! git -C "$root" rev-parse -q --verify "refs/tags/$kit-v$kv" >/dev/null && ! git -C "$root" ls-remote --exit-code --tags origin "$kit-v$kv" >/dev/null 2>&1; then
    echo "$pkg depends on $kit $kv, which isn't published (tag $kit-v$kv): publish it first" >&2
    exit 1
  fi
done

echo "building $pkg $version from $source_sha"
npm --prefix "$dir" run build
npm --prefix "$dir" test

tmp=$(mktemp -d "${TMPDIR:-/tmp}/git-dist.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
stage="$tmp/package"
mkdir "$stage"
cp -R "$dir/dist" "$stage/dist"
# prebuilt native addons (packages/link: native/*.node, gitignored in the source tree)
[ -d "$dir/native" ] && cp -R "$dir/native" "$stage/native"
[ -f "$dir/README.md" ] && cp "$dir/README.md" "$stage/README.md"
[ -f "$root/LICENSE" ] && cp "$root/LICENSE" "$stage/LICENSE"
# what an installer needs, nothing that would make it build (a git dependency's `prepare` runs on install)
node -e '
  const fs = require("fs");
  const [src, out, sha, root, remote] = process.argv.slice(1);
  const p = JSON.parse(fs.readFileSync(src, "utf8"));
  delete p.scripts; delete p.devDependencies; delete p.private;
  for (const n of Object.keys(p.dependencies ?? {})) {
    const kit = `${root}/packages/${n.slice(13)}/package.json`;
    if (n.startsWith("@yoyocontrol/") && fs.existsSync(kit)) p.dependencies[n] = `git+${remote}#${n.slice(13)}-v${JSON.parse(fs.readFileSync(kit, "utf8")).version}`;
  }
  p.gitHead = sha;
  fs.writeFileSync(out, JSON.stringify(p, null, 2) + "\n");
' "$dir/package.json" "$stage/package.json" "$source_sha" "$root" "$remote"

# the tree, through a throwaway index (the working tree and the real index stay as they are)
gitdir=$(cd "$root" && cd "$(git rev-parse --git-dir)" && pwd)
GIT_INDEX_FILE="$tmp/index" git --git-dir="$gitdir" --work-tree="$stage" -C "$stage" add -A -f .
tree=$(GIT_INDEX_FILE="$tmp/index" git --git-dir="$gitdir" write-tree)

parent=""
local_parent=""
if git -C "$root" rev-parse -q --verify "refs/heads/$branch" >/dev/null; then
  parent=$(git -C "$root" rev-parse "refs/heads/$branch")
  local_parent=$parent
elif git -C "$root" fetch -q origin "refs/heads/$branch" 2>/dev/null; then
  parent=$(git -C "$root" rev-parse FETCH_HEAD)
fi
message="@yoyocontrol/$pkg $version

Built from $source_sha (packages/$pkg)."
[ -n "${GIT_DIST_TRAILER:-}" ] && message="$message

$GIT_DIST_TRAILER"
commit=$(git -C "$root" commit-tree "$tree" ${parent:+-p "$parent"} -m "$message")
# the old value only when the branch is here already (a parent fetched from origin has no local ref yet)
git -C "$root" update-ref "refs/heads/$branch" "$commit" ${local_parent:+"$local_parent"}
git -C "$root" tag -a "$tag" -m "$message" "$commit"
echo "committed $commit on $branch, tagged $tag"

if [ "$push" = 1 ]; then
  git -C "$root" push origin "refs/heads/$branch:refs/heads/$branch" "refs/tags/$tag:refs/tags/$tag"
  echo "depend on it: \"@yoyocontrol/$pkg\": \"git+$remote#$tag\""
fi
