import init, { ClientMedia as WasmClientMedia } from "./wasm/uu_link_wasm.js";
/** The `.wasm` shipped next to this module. */
export const defaultWasmUrl = () => new URL("./wasm/uu_link_wasm_bg.wasm", import.meta.url);
let loaded = null;
const MODULE = {
    createClientMedia: (config) => new WasmClientMedia(config ?? {}),
};
/**
 * Loads (once per page) and returns the media layer. `wasm` overrides where the `.wasm` comes from (see `WasmSource`);
 * the first call's source wins (one instance per page), a failed load is tried again on the next call.
 */
export function loadLinkMedia(wasm) {
    if (loaded)
        return loaded;
    const source = typeof wasm === "string" ? new URL(wasm, globalThis.location?.href) : (wasm ?? defaultWasmUrl());
    loaded = init({ module_or_path: source }).then(() => MODULE, (e) => {
        loaded = null;
        throw e;
    });
    return loaded;
}
