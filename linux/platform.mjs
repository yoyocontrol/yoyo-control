// What differs between the two computers this server runs on: Linux (an X display) and Windows (the signed-in
// user's desktop). Everything else — the routes, the stream loop and flow control, sound, the clipboard's protocol, the
// window catalog, input pacing, remote access and uu Link — is the same code: each platform has its own helper
// programs that speak the same records (windows/README.md「辅助程序」 lists the Windows ones), and on Windows the input
// helper reads the very xdotool lines input.mjs writes.
import { fileURLToPath } from "node:url";

export const PLATFORMS = Object.freeze({
  linux: Object.freeze({
    /** `/status.platform`, the pairing's `server.platform`, the account statement's. */
    id: "linux",
    /** `/status.app`. */
    app: "yoyo-linux",
    /** The display's default name (`--name`). */
    name: "Linux",
    helpers: Object.freeze({ video: "yoyo-x11video", audio: "yoyo-pa-opus", clipboard: "yoyo-x11clip", windows: "yoyo-x11windows" }),
    /** The input program (`<it> -` reads xdotool lines): found in PATH. */
    input: "xdotool",
    /** GET /frame: ffmpeg's x11grab (`ffmpeg`), or the video helper's `--jpeg` (`helper`). */
    frame: "ffmpeg",
    /** Where the display is, for the start-up line. */
    display: (env) => `display ${env.DISPLAY ?? "?"}`,
  }),
  windows: Object.freeze({
    id: "windows",
    app: "yoyo-windows",
    name: "Windows",
    helpers: Object.freeze({ video: "yoyo-winvideo.exe", audio: "yoyo-winaudio.exe", clipboard: "yoyo-winclip.exe", windows: "yoyo-winwindows.exe" }),
    /** Beside this file, like the other helpers. */
    input: "yoyo-wininput.exe",
    frame: "helper",
    display: (env) => `session ${env.SESSIONNAME ?? "?"} of ${env.USERNAME ?? "?"}`,
  }),
});

/** The platform of this process (`YOYO_PLATFORM` = linux | windows overrides, for tests and odd setups). */
export function hostPlatform(env = process.env, os = process.platform) {
  const p = env.YOYO_PLATFORM;
  if (p && PLATFORMS[p]) return PLATFORMS[p];
  return os === "win32" ? PLATFORMS.windows : PLATFORMS.linux;
}

/** A helper's default path: beside the server's files. */
export const besideServer = (file) => fileURLToPath(new URL(`./${file}`, import.meta.url));
