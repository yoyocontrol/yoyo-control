// Builds the browser's media layer (link/wasm, crate uu-link-wasm) and its wasm-bindgen glue into src/wasm/:
// uu_link_wasm.js + .d.ts (committed: `--check` fails when they no longer match the Rust code) and
// uu_link_wasm_bg.wasm (gitignored; `npm run build` copies it into dist/wasm/ next to the glue).
//
// Needs the wasm32-unknown-unknown target (link/rust-toolchain.toml lists it) and wasm-bindgen-cli of the exact
// version the crate resolved (Cargo.lock); when it is not on PATH it is installed once into link/target/tools.

import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, copyFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const pkg = join(here, "..");
const link = join(pkg, "..", "..", "link");
const out = join(pkg, "src", "wasm");
const check = process.argv.includes("--check");
const run = (cmd, args, opts = {}) => execFileSync(cmd, args, { cwd: link, stdio: "inherit", ...opts });

const lock = readFileSync(join(link, "Cargo.lock"), "utf8");
const version = /name = "wasm-bindgen"\nversion = "([^"]+)"/.exec(lock)?.[1];
if (!version) throw new Error("wasm-bindgen is not in link/Cargo.lock");

function bindgen() {
  const local = join(link, "target", "tools", "bin", "wasm-bindgen");
  for (const bin of ["wasm-bindgen", local]) {
    try {
      const v = execFileSync(bin, ["--version"], { encoding: "utf8" }).trim();
      if (v.endsWith(` ${version}`)) return bin;
    } catch {
      /* not there */
    }
  }
  console.log(`installing wasm-bindgen-cli ${version} into link/target/tools`);
  run("cargo", ["install", "--locked", "--root", join(link, "target", "tools"), "wasm-bindgen-cli", "--version", `=${version}`]);
  return local;
}

run("cargo", ["build", "--locked", "--profile", "release-wasm", "--target", "wasm32-unknown-unknown", "-p", "uu-link-wasm"]);
const built = join(link, "target", "wasm32-unknown-unknown", "release-wasm", "uu_link_wasm.wasm");
const dest = check ? mkdtempSync(join(tmpdir(), "uu-link-wasm-")) : out;
mkdirSync(dest, { recursive: true });
run(bindgen(), ["--target", "web", "--out-dir", dest, "--out-name", "uu_link_wasm", built]);

if (check) {
  let stale = false;
  for (const f of ["uu_link_wasm.js", "uu_link_wasm.d.ts"]) {
    const a = readFileSync(join(dest, f), "utf8");
    const b = existsSync(join(out, f)) ? readFileSync(join(out, f), "utf8") : "";
    if (a !== b) {
      console.error(`src/wasm/${f} is stale: run npm -w packages/link-web run wasm and commit it`);
      stale = true;
    }
  }
  copyFileSync(join(dest, "uu_link_wasm_bg.wasm"), join(out, "uu_link_wasm_bg.wasm"));
  rmSync(dest, { recursive: true, force: true });
  if (stale) process.exit(1);
}
rmSync(join(out, "uu_link_wasm_bg.wasm.d.ts"), { force: true });
console.log(`src/wasm/uu_link_wasm_bg.wasm (${readFileSync(join(out, "uu_link_wasm_bg.wasm")).length} bytes)`);
