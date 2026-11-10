// Builds the native addon (link/node, crate uu-link-node) for this machine and puts it where the loader looks:
// native/uu-link.<platform>-<arch>[-gnu].node. `--debug` for a debug build.
//
// Linux builds for a release come from linux/release.Dockerfile (a Rust stage per architecture); a cross build from
// macOS also works with cargo-zigbuild: `cargo zigbuild --profile release-node -p uu-link-node
// --target x86_64-unknown-linux-gnu.2.36` (glibc of Debian 12), then copy libuu_link_node.so to
// native/uu-link.linux-x64-gnu.node.

import { execFileSync } from "node:child_process";
import { copyFileSync, mkdirSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const pkg = join(here, "..");
const link = join(pkg, "..", "..", "link");
const debug = process.argv.includes("--debug");
const profile = debug ? "dev" : "release-node";
const outDir = debug ? "debug" : "release-node";

execFileSync("cargo", ["build", "--locked", "--profile", profile, "-p", "uu-link-node"], { cwd: link, stdio: "inherit" });

const ext = process.platform === "darwin" ? "dylib" : "so";
const built = join(link, "target", outDir, `libuu_link_node.${ext}`);
const name = `uu-link.${process.platform}-${process.arch}${process.platform === "linux" ? "-gnu" : ""}.node`;
mkdirSync(join(pkg, "native"), { recursive: true });
// a new file, not an overwrite: macOS kills a process that loads a signed binary changed in place
rmSync(join(pkg, "native", name), { force: true });
copyFileSync(built, join(pkg, "native", name));
console.log(`native/${name}`);
