// The native addon (link/node, crate uu-link-node): its shape, and where it is loaded from.
//
// Order: $YOYO_LINK_NATIVE (a path to a .node file), then native/uu-link.<platform>-<arch>[-gnu].node beside dist/
// (the prebuilt files a release ships), then the workspace build (link/target/{release-node,debug}) for development.
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
export function nativeName(platform = process.platform, arch = process.arch) {
    return `uu-link.${platform}-${arch}${platform === "linux" ? "-gnu" : ""}.node`;
}
function candidates() {
    const here = dirname(fileURLToPath(import.meta.url));
    const pkg = join(here, "..");
    const ext = process.platform === "darwin" ? "dylib" : "so";
    const target = join(pkg, "..", "..", "link", "target");
    // beside the JS too: a copy of dist/ with the addon in it (the Linux server's vendor/link)
    const list = [join(pkg, "native", nativeName()), join(here, nativeName())];
    list.push(join(target, "release-node", `libuu_link_node.${ext}`), join(target, "debug", `libuu_link_node.${ext}`));
    const env = process.env.YOYO_LINK_NATIVE;
    return env ? [env, ...list] : list;
}
let loaded = null;
export function native() {
    if (loaded)
        return loaded;
    const tried = [];
    for (const path of candidates()) {
        if (!existsSync(path)) {
            tried.push(path);
            continue;
        }
        const m = { exports: {} };
        process.dlopen(m, path);
        loaded = m.exports;
        return loaded;
    }
    throw new Error(`@yoyocontrol/link: no native addon for ${process.platform}-${process.arch} (looked at ${tried.join(", ")})`);
}
