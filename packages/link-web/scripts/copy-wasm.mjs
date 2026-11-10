// After tsc: the wasm-bindgen glue and the .wasm go to dist/wasm/, where dist/wasm.js imports and fetches them.
import { copyFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const pkg = join(dirname(fileURLToPath(import.meta.url)), "..");
mkdirSync(join(pkg, "dist", "wasm"), { recursive: true });
for (const f of ["uu_link_wasm.js", "uu_link_wasm.d.ts", "uu_link_wasm_bg.wasm"]) {
  copyFileSync(join(pkg, "src", "wasm", f), join(pkg, "dist", "wasm", f));
}
