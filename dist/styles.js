/**
 * The pages' look: CSS custom properties on the element (`--yoyo-*`, the README lists them), light and dark by the
 * system's (or the host's) scheme; glass that turns solid with Reduce Transparency; motion that turns into fades with
 * Reduce Motion.
 */
export const THEME = `
:host {
  --yoyo-font: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", "PingFang SC", "Noto Sans", system-ui, sans-serif;
  --yoyo-mono: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
  --yoyo-background: #f2f2f7;
  --yoyo-picture-background: #e5e5ea;
  --yoyo-text: #1c1c1e;
  --yoyo-text-secondary: rgba(60, 60, 67, 0.72);
  --yoyo-text-tertiary: rgba(60, 60, 67, 0.42);
  --yoyo-accent: #d97757;
  --yoyo-on-accent: #ffffff;
  --yoyo-success: #34a853;
  --yoyo-danger: #d93025;
  --yoyo-glass: rgba(255, 255, 255, 0.62);
  --yoyo-glass-solid: #ffffff;
  --yoyo-glass-border: rgba(255, 255, 255, 0.7);
  --yoyo-glass-shadow: 0 4px 18px rgba(0, 0, 0, 0.12), 0 0 0 0.5px rgba(0, 0, 0, 0.06);
  --yoyo-glass-blur: 22px;
  --yoyo-pad: rgba(0, 0, 0, 0.045);
  --yoyo-pad-border: rgba(0, 0, 0, 0.08);
  --yoyo-sheet: #ffffff;
  --yoyo-sheet-grouped: #f2f2f7;
  --yoyo-separator: rgba(60, 60, 67, 0.18);
  --yoyo-key: #ffffff;
  --yoyo-key-bar: rgba(209, 212, 219, 0.92);
  --yoyo-radius: 22px;
  --yoyo-scrim: rgba(0, 0, 0, 0.32);
  color-scheme: light;
}
@media (prefers-color-scheme: dark) {
  :host(:not([color-scheme="light"])) {
    --yoyo-background: #000000;
    --yoyo-picture-background: #1c1c1e;
    --yoyo-text: #f5f5f7;
    --yoyo-text-secondary: rgba(235, 235, 245, 0.68);
    --yoyo-text-tertiary: rgba(235, 235, 245, 0.36);
    --yoyo-glass: rgba(44, 44, 46, 0.6);
    --yoyo-glass-solid: #2c2c2e;
    --yoyo-glass-border: rgba(255, 255, 255, 0.12);
    --yoyo-glass-shadow: 0 4px 18px rgba(0, 0, 0, 0.45), 0 0 0 0.5px rgba(255, 255, 255, 0.08);
    --yoyo-pad: rgba(255, 255, 255, 0.06);
    --yoyo-pad-border: rgba(255, 255, 255, 0.1);
    --yoyo-sheet: #1c1c1e;
    --yoyo-sheet-grouped: #000000;
    --yoyo-separator: rgba(84, 84, 88, 0.6);
    --yoyo-key: #6b6b6f;
    --yoyo-key-bar: rgba(43, 43, 46, 0.94);
    --yoyo-scrim: rgba(0, 0, 0, 0.55);
    color-scheme: dark;
  }
}
:host([color-scheme="dark"]) {
  --yoyo-background: #000000;
  --yoyo-picture-background: #1c1c1e;
  --yoyo-text: #f5f5f7;
  --yoyo-text-secondary: rgba(235, 235, 245, 0.68);
  --yoyo-text-tertiary: rgba(235, 235, 245, 0.36);
  --yoyo-glass: rgba(44, 44, 46, 0.6);
  --yoyo-glass-solid: #2c2c2e;
  --yoyo-glass-border: rgba(255, 255, 255, 0.12);
  --yoyo-glass-shadow: 0 4px 18px rgba(0, 0, 0, 0.45), 0 0 0 0.5px rgba(255, 255, 255, 0.08);
  --yoyo-pad: rgba(255, 255, 255, 0.06);
  --yoyo-pad-border: rgba(255, 255, 255, 0.1);
  --yoyo-sheet: #1c1c1e;
  --yoyo-sheet-grouped: #000000;
  --yoyo-separator: rgba(84, 84, 88, 0.6);
  --yoyo-key: #6b6b6f;
  --yoyo-key-bar: rgba(43, 43, 46, 0.94);
  --yoyo-scrim: rgba(0, 0, 0, 0.55);
  color-scheme: dark;
}
`;
/** Shared pieces: glass, buttons, sheets, menus, the toast. */
export const COMMON = `
* { box-sizing: border-box; }
[hidden] { display: none !important; }
button { font: inherit; color: inherit; -webkit-tap-highlight-color: transparent; }
.glass {
  background: var(--yoyo-glass);
  -webkit-backdrop-filter: blur(var(--yoyo-glass-blur)) saturate(1.8);
  backdrop-filter: blur(var(--yoyo-glass-blur)) saturate(1.8);
  box-shadow: var(--yoyo-glass-shadow);
  border: 0.5px solid var(--yoyo-glass-border);
}
@media (prefers-reduced-transparency: reduce) {
  .glass { background: var(--yoyo-glass-solid); -webkit-backdrop-filter: none; backdrop-filter: none; }
}
.round {
  min-width: 44px; height: 44px; border-radius: 22px; padding: 0 12px;
  display: inline-flex; align-items: center; justify-content: center; gap: 6px;
  cursor: pointer; position: relative; flex: none; touch-action: manipulation;
  transition: transform 0.18s cubic-bezier(.3,1.4,.5,1), opacity 0.2s;
}
.round:active { transform: scale(0.92); }
.round:disabled { opacity: 0.4; cursor: default; transform: none; }
.round.on { background: var(--yoyo-accent); color: var(--yoyo-on-accent); }
.round .dot { position: absolute; top: 4px; right: 4px; width: 9px; height: 9px; border-radius: 50%; background: var(--yoyo-accent); border: 1.5px solid rgba(255,255,255,.85); }
.capsule { border-radius: 999px; }
.prominent {
  background: var(--yoyo-accent); color: var(--yoyo-on-accent); border: 0; border-radius: 999px;
  padding: 10px 18px; font-weight: 600; cursor: pointer; font-size: 15px;
}
.prominent.small { padding: 6px 14px; font-size: 13px; }
.plain-button { background: none; border: 0; color: var(--yoyo-accent); font-weight: 600; cursor: pointer; padding: 4px; }
.toast {
  position: absolute; left: 50%; bottom: 0; transform: translate(-50%, 12px); opacity: 0; pointer-events: none;
  padding: 10px 16px; border-radius: 999px; font-size: 14px; max-width: calc(100% - 32px); text-align: center; z-index: 40;
  transition: opacity 0.2s, transform 0.3s cubic-bezier(.3,1.3,.5,1);
}
.toast.shown { opacity: 1; transform: translate(-50%, 0); }
.scrim { position: absolute; inset: 0; background: var(--yoyo-scrim); z-index: 50; opacity: 0; transition: opacity 0.25s; }
.scrim.shown { opacity: 1; }
.sheet {
  position: absolute; left: 0; right: 0; bottom: 0; z-index: 51; max-height: calc(100% - 24px - env(safe-area-inset-top));
  background: var(--yoyo-sheet-grouped); border-radius: 14px 14px 0 0; overflow: auto; overscroll-behavior: contain;
  padding: 8px 20px calc(20px + env(safe-area-inset-bottom)); transform: translateY(100%);
  transition: transform 0.38s cubic-bezier(.2,.9,.25,1); box-shadow: 0 -8px 40px rgba(0,0,0,.18);
  margin: 0 auto; max-width: 560px;
}
.sheet.shown { transform: none; }
.sheet .grabber { width: 36px; height: 5px; border-radius: 3px; background: var(--yoyo-text-tertiary); margin: 0 auto 14px; }
@media (min-width: 700px) and (min-height: 600px) {
  .sheet { bottom: auto; top: 50%; left: 50%; right: auto; width: 520px; border-radius: 16px; transform: translate(-50%, -46%) scale(0.98); opacity: 0;
    transition: transform 0.3s cubic-bezier(.2,.9,.25,1), opacity 0.2s; padding-bottom: 24px; max-height: calc(100% - 48px); }
  .sheet.shown { transform: translate(-50%, -50%); opacity: 1; }
  .sheet .grabber { display: none; }
}
.menu {
  position: absolute; z-index: 60; min-width: 240px; max-width: min(320px, calc(100% - 24px)); border-radius: 14px; padding: 6px 0;
  transform-origin: bottom center; transform: scale(0.9); opacity: 0; transition: transform 0.22s cubic-bezier(.3,1.3,.5,1), opacity 0.15s;
  max-height: 70%; overflow: auto;
}
.menu.shown { transform: none; opacity: 1; }
.menu .section + .section { border-top: 6px solid var(--yoyo-separator); }
.menu .title { font-size: 12px; color: var(--yoyo-text-secondary); padding: 6px 16px 4px; }
.menu button {
  display: flex; align-items: center; gap: 12px; width: 100%; text-align: left; background: none; border: 0;
  padding: 10px 16px; cursor: pointer; font-size: 16px; color: var(--yoyo-text);
}
.menu button + button { border-top: 0.5px solid var(--yoyo-separator); }
.menu button:disabled { color: var(--yoyo-text-tertiary); cursor: default; }
.menu button:not(:disabled):hover { background: rgba(127,127,127,.12); }
.menu .label { flex: 1; min-width: 0; }
.menu .sub { display: block; font-size: 12.5px; color: var(--yoyo-text-secondary); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.menu .mark { width: 20px; display: inline-flex; color: var(--yoyo-accent); }
@media (prefers-reduced-motion: reduce) {
  .round, .toast, .sheet, .menu, .scrim { transition-duration: 0.01s !important; }
  .round:active { transform: none; }
}
`;
export const SCREEN_STYLE = `
:host { display: block; position: relative; overflow: hidden; contain: strict; font-family: var(--yoyo-font); color: var(--yoyo-text);
  background: var(--yoyo-background); -webkit-user-select: none; user-select: none; -webkit-touch-callout: none; }
:host([fullscreen]) { position: fixed; inset: 0; z-index: 2147483000; background: #000; }
.page { position: absolute; inset: 0; }
.stage { position: absolute; inset: 0; touch-action: none; }
.probe { position: absolute; visibility: hidden; pointer-events: none; inset: 0;
  padding: env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left); }
.pad { position: absolute; border-radius: 22px; background: var(--yoyo-pad); border: 1px solid var(--yoyo-pad-border);
  transition: background 0.3s, border-color 0.3s; display: flex; align-items: center; justify-content: center; pointer-events: none; }
.pad.outside { border: 2px solid var(--yoyo-accent); background: color-mix(in srgb, var(--yoyo-accent) 8%, transparent); transition-duration: 0.12s; }
.pad-hint { display: flex; flex-direction: column; align-items: center; gap: 8px; padding: 0 24px; text-align: center; font-size: 13px; color: var(--yoyo-text-secondary); }
.pad-hint svg { width: 28px; height: 28px; }
.clip { position: absolute; overflow: hidden; background: var(--yoyo-picture-background); border-radius: 4px; }
:host([fullscreen]) .clip { border-radius: 0; background: #000; }
.zoom { position: absolute; left: 0; top: 0; transform-origin: 0 0; will-change: transform; }
.zoom.animate { transition: transform 0.35s cubic-bezier(.2,.9,.25,1); }
video, canvas.video { display: block; width: 100%; height: 100%; }
.dim { position: absolute; inset: 0; background: #000; opacity: 0; transition: opacity 0.35s; pointer-events: none; }
.dim.on { opacity: 0.45; }
.loupe { position: absolute; left: 0; top: 0; pointer-events: none; will-change: transform; z-index: 2; }
.overlay { position: absolute; inset: 0; pointer-events: none; z-index: 3; }
.cursor { position: absolute; left: 0; top: 0; transform-origin: var(--hx, 0) var(--hy, 0); will-change: transform; image-rendering: auto; }
.cursor.press { transition: scale 0.12s; scale: 0.9; }
.ring { position: absolute; width: 22px; height: 22px; margin: -11px 0 0 -11px; border-radius: 50%; border: 1.5px solid #fff;
  background: rgba(255,255,255,.25); box-shadow: 0 0 2px rgba(0,0,0,.6); animation: ring 0.24s ease-out forwards; }
@keyframes ring { from { transform: scale(0.3); opacity: 0.9; } to { transform: scale(1); opacity: 0; } }
.pbadge { position: absolute; left: 0; top: 0; width: 26px; height: 26px; margin: -13px 0 0 -13px; border-radius: 50%;
  display: flex; align-items: center; justify-content: center; color: #fff; background: rgba(0,0,0,.45);
  -webkit-backdrop-filter: blur(8px); backdrop-filter: blur(8px); transition: opacity 0.2s, scale 0.3s cubic-bezier(.3,1.5,.5,1); }
.pbadge svg { width: 14px; height: 14px; transition: translate 0.18s; }
.pbadge[hidden] { display: flex !important; opacity: 0; scale: 0.6; }
.fs { position: absolute; z-index: 5; width: 36px; height: 36px; min-width: 36px; padding: 0; border-radius: 18px; transition: opacity 0.4s; }
.fs svg { width: 17px; height: 17px; }
.fs.faded { opacity: 0; }
.badges { position: absolute; z-index: 6; display: flex; flex-direction: column; align-items: center; gap: 6px; transform: translateX(-50%);
  max-width: calc(100% - 32px); transition: opacity 0.4s; pointer-events: none; }
.badges.faded { opacity: 0; }
.badges.faded .vpill { pointer-events: none; }
.badge, .vpill { display: inline-flex; align-items: center; gap: 6px; font-size: 13px; border-radius: 999px; padding: 7px 12px; white-space: nowrap; max-width: 100%; }
.badge svg, .vpill svg { width: 15px; height: 15px; flex: none; }
.badge.agent svg { color: var(--yoyo-accent); }
.badge.user svg { color: var(--yoyo-success); }
.badge.none { color: var(--yoyo-text-secondary); }
.vpill { pointer-events: auto; padding: 3px 6px 3px 12px; }
.vpill .name { overflow: hidden; text-overflow: ellipsis; min-width: 0; }
.vpill .sep { color: var(--yoyo-text-tertiary); }
.vpill .icon { display: inline-flex; }
.vpill svg { color: var(--yoyo-text-secondary); }
.vpill.agent svg { color: var(--yoyo-accent); }
.vpill button { background: none; border: 0; color: var(--yoyo-accent); font-weight: 600; font-size: 13px; cursor: pointer; padding: 4px; }
.vpill.nudge { animation: nudge 0.45s cubic-bezier(.3,1.5,.5,1); }
@keyframes nudge { 30% { transform: scale(1.06); } }
.hint { position: absolute; z-index: 7; transform: translate(-50%, -14px); opacity: 0; display: flex; align-items: center; gap: 6px;
  border-radius: 999px; padding: 9px 14px; font-size: 13px; cursor: pointer; border: 0; max-width: min(380px, calc(100% - 24px));
  transition: opacity 0.2s, transform 0.4s cubic-bezier(.3,1.3,.5,1); pointer-events: none; text-align: left; }
.hint.shown { opacity: 1; transform: translate(-50%, 0); pointer-events: auto; }
.hint svg { width: 16px; height: 16px; color: var(--yoyo-accent); flex: none; }
.hint span { overflow: hidden; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; }
.zhint { pointer-events: none !important; }
.stats { position: absolute; z-index: 8; font: 500 11px/1.35 var(--yoyo-mono); color: #fff; background: rgba(0,0,0,.55); border-radius: 4px;
  padding: 2px 4px; white-space: pre-wrap; pointer-events: none; max-width: calc(100% - 16px); font-variant-numeric: tabular-nums; }
.conn { position: absolute; z-index: 9; transform: translate(-50%, -50%); border-radius: 22px; padding: 16px 20px; text-align: center;
  display: flex; flex-direction: column; align-items: center; gap: 8px; max-width: min(360px, calc(100% - 24px)); }
.conn .title { font-weight: 600; font-size: 16px; }
.conn .detail { font-size: 13px; color: var(--yoyo-text-secondary); }
.conn .prominent { margin-top: 6px; }
.spin { width: 22px; height: 22px; border-radius: 50%; border: 2.5px solid var(--yoyo-text-tertiary); border-top-color: var(--yoyo-text-secondary); animation: spin 0.9s linear infinite; }
.spinner { position: absolute; z-index: 9; transform: translate(-50%, -50%); }
@keyframes spin { to { transform: rotate(360deg); } }
.note { position: absolute; z-index: 9; border-radius: 20px; padding: 12px 12px 12px 16px; display: flex; align-items: center; gap: 12px; font-size: 13px; color: var(--yoyo-text-secondary); }
.empty { position: absolute; inset: 0; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 10px; padding: 32px;
  text-align: center; z-index: 4; }
.empty svg { width: 44px; height: 44px; color: var(--yoyo-text-tertiary); stroke-width: 1.4; }
.empty .title { font-size: 20px; font-weight: 600; }
.empty .detail { font-size: 15px; color: var(--yoyo-text-secondary); max-width: 420px; }
.empty .prominent { margin-top: 8px; }
.bar { position: absolute; z-index: 10; display: flex; gap: 10px; align-items: center; pointer-events: none; }
.bar .group { display: flex; gap: inherit; align-items: center; pointer-events: auto; }
.bar.column { flex-direction: column; }
.bar.column .group { flex-direction: column; }
.bar.narrow { gap: 4px; }
.bar.narrow .round { min-width: 40px; height: 40px; padding: 0 10px; }
.keys { position: absolute; left: 0; top: 0; width: 1px; height: 1px; opacity: 0; border: 0; padding: 0; margin: 0; resize: none;
  font-size: 16px; color: transparent; background: transparent; caret-color: transparent; pointer-events: none; }
.keybar { position: fixed; left: 0; right: 0; z-index: 30; display: flex; gap: 6px; align-items: center; padding: 7px 8px; overflow-x: auto;
  background: var(--yoyo-key-bar); -webkit-backdrop-filter: blur(20px); backdrop-filter: blur(20px); scrollbar-width: none; touch-action: pan-x; }
.keybar::-webkit-scrollbar { display: none; }
.keybar button { flex: none; min-width: 44px; height: 38px; border-radius: 8px; border: 0; background: var(--yoyo-key); color: var(--yoyo-text);
  font-size: 17px; font-weight: 500; padding: 0 10px; display: inline-flex; align-items: center; gap: 5px; box-shadow: 0 1px 0 rgba(0,0,0,.25); cursor: pointer; }
.keybar button.word { font-size: 13px; }
.keybar button.on { background: var(--yoyo-accent); color: var(--yoyo-on-accent); }
.keybar button svg { width: 16px; height: 16px; }
.keybar .gap { flex: none; width: 8px; }
.card h2 { font-size: 20px; margin: 4px 0 6px; }
.card .intro { font-size: 15px; color: var(--yoyo-text-secondary); margin: 0 0 18px; line-height: 1.35; }
.card table { width: 100%; border-collapse: collapse; font-size: 16px; }
.card th { font-size: 13px; font-weight: 400; color: var(--yoyo-text-secondary); text-align: left; padding: 0 0 6px; }
.card td { padding: 5px 0; vertical-align: baseline; line-height: 1.3; }
.card td.icon { width: 34px; color: var(--yoyo-accent); vertical-align: middle; }
.card td.icon svg { width: 20px; height: 20px; }
.card td.what { color: var(--yoyo-text-secondary); padding-left: 10px; width: 44%; }
.card h3 { font-size: 17px; margin: 24px 0 8px; }
.card .foot { font-size: 13px; color: var(--yoyo-text-secondary); margin: 8px 0 0; }
.card .done { display: block; width: 100%; margin-top: 22px; padding: 14px; font-size: 17px; }
`;
