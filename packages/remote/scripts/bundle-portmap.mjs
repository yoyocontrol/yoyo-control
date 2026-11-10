// After tsc: puts the built @yoyocontrol/portmap inside dist/portmap and points the imports there, so the package (and
// anything that copies its dist, like the Linux server's release) needs nothing installed beside it.
import { cpSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const dist = join(here, "..", "dist");
const portmap = join(here, "..", "..", "portmap", "dist");
cpSync(portmap, join(dist, "portmap"), { recursive: true });
let n = 0;
for (const f of readdirSync(dist)) {
  if (!f.endsWith(".js") && !f.endsWith(".d.ts")) continue;
  const p = join(dist, f);
  const s = readFileSync(p, "utf8");
  const t = s.replace(/(["'])@yoyocontrol\/portmap\1/g, '"./portmap/index.js"');
  if (t !== s) {
    writeFileSync(p, t);
    n++;
  }
}
console.log(`bundle-portmap: dist/portmap, ${n} files pointed at it`);
