#!/usr/bin/env node
// Keeps private strings out of the repository: the owner's domain, addresses, machine and account names, team id, …
//
//   node scripts/check-private.mjs            # every tracked file
//   node scripts/check-private.mjs --staged   # what is staged for the next commit (scripts/hooks/pre-commit)
//   node scripts/check-private.mjs --require  # a missing list is an error (default: a note, exit 0)
//   node scripts/check-private.mjs --dir <d>  # every file under a directory instead (the public tree, scripts/public/export.sh)
//
// The strings themselves are NOT in this script, nor anywhere in git: they are read from a local list that is never
// committed — $YOYO_PRIVATE_LIST, else <the main checkout>/.private/private-identifiers.txt (.private/ is ignored; a
// worktree finds the main checkout's through git), else ~/.config/yoyocontrol/private-identifiers.txt. Hashes would not do instead:
// an IP address or a short name is recovered from its hash in seconds.
//
// The list: one entry a line, `#` comments. A plain entry matches anywhere, ignoring case. `/…/` is a regular
// expression (JavaScript, case-insensitive). `!path/prefix` leaves the tracked files under that path out (a place the
// strings are still allowed for now). scripts/private-pending.txt (committed: paths only) is more of the last kind:
// the product's own deployment files, which never leave this repository (scripts/public/paths.txt leaves them out).
//
// Output names the file and line and which entry of the list matched (its number, not its text).
import { execFileSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2);
const git = (...a) => execFileSync("git", a, { cwd: root, encoding: "utf8", maxBuffer: 256 * 1024 * 1024 });

function listFile() {
  if (process.env.YOYO_PRIVATE_LIST) return process.env.YOYO_PRIVATE_LIST;
  const candidates = [];
  try {
    // the main checkout (a worktree's common dir is its .git)
    candidates.push(join(dirname(resolve(root, git("rev-parse", "--git-common-dir").trim())), ".private", "private-identifiers.txt"));
  } catch {
    /* not a git checkout */
  }
  candidates.push(join(root, ".private", "private-identifiers.txt"), join(homedir(), ".config", "yoyocontrol", "private-identifiers.txt"));
  return candidates.find((f) => existsSync(f)) ?? null;
}

const file = listFile();
if (!file || !existsSync(file)) {
  const msg = "check-private: no private list on this computer (.private/private-identifiers.txt): nothing checked";
  if (args.includes("--require")) {
    console.error(msg);
    process.exit(1);
  }
  console.log(msg);
  process.exit(0);
}

const lines = (text) => text.split(/\r?\n/).map((l) => l.trim()).filter((l) => l && !l.startsWith("#"));
const entries = [];
const skip = [];
readFileSync(file, "utf8").split(/\r?\n/).forEach((raw, i) => {
  const l = raw.trim();
  if (!l || l.startsWith("#")) return;
  if (l.startsWith("!")) skip.push(l.slice(1));
  else if (l.length > 2 && l.startsWith("/") && l.endsWith("/")) entries.push({ n: i + 1, re: new RegExp(l.slice(1, -1), "i") });
  else entries.push({ n: i + 1, re: new RegExp(l.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "i") });
});
const pending = join(root, "scripts", "private-pending.txt");
if (existsSync(pending)) skip.push(...lines(readFileSync(pending, "utf8")));
const skipped = (f) => skip.some((p) => f === p || f.startsWith(p.endsWith("/") ? p : `${p}/`));

const staged = args.includes("--staged");
const dirAt = args.indexOf("--dir");
const dir = dirAt >= 0 ? resolve(args[dirAt + 1] ?? ".") : null;
const walk = (d, pre = "") =>
  readdirSync(join(d, pre), { withFileTypes: true }).flatMap((e) =>
    e.name === ".git" ? [] : e.isDirectory() ? walk(d, join(pre, e.name)) : e.isFile() ? [join(pre, e.name)] : [],
  );
const files = dir
  ? walk(dir)
  : (staged ? git("diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z") : git("ls-files", "-z")).split("\0").filter(Boolean);
if (dir) skip.length = 0; // the public tree: nothing is left out
let hits = 0;
let checked = 0;
for (const f of files) {
  if (skipped(f)) continue;
  let text;
  try {
    // the staged blob (what the commit will hold), or the file as it is
    text = staged ? execFileSync("git", ["show", `:${f}`], { cwd: root, maxBuffer: 256 * 1024 * 1024 }) : readFileSync(join(dir ?? root, f));
  } catch {
    continue;
  }
  if (text.includes(0)) continue; // binary
  checked++;
  // the path counts too (a file named after a machine)
  const rows = [f, ...text.toString("utf8").split("\n")];
  rows.forEach((row, i) => {
    for (const e of entries) {
      if (!e.re.test(row)) continue;
      hits++;
      console.error(`${f}:${i === 0 ? "(its path)" : i}: private string (entry at line ${e.n} of the list)`);
    }
  });
}
if (hits) {
  console.error(`\ncheck-private: ${hits} match(es) in ${staged ? "the staged changes" : dir ? dir : "the tracked files"}. Replace them with neutral examples (example.com, 203.0.113.x, alex, …).`);
  process.exit(1);
}
console.log(`check-private: clean (${checked} ${staged ? "staged" : dir ? "" : "tracked"} files, ${entries.length} entries${skip.length ? `, ${skip.length} path(s) left out` : ""})`);
