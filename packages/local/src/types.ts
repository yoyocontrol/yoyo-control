// The local API's wire shapes this client reads and writes (mac/README.md「HTTP API」, docs/PROTOCOL.md). Open sets
// stay open: a server newer than this client may send values it doesn't list.

/** One display. `width` / `height` in points, `scale` = pixels per point. */
export interface Display {
  id: number;
  width: number;
  height: number;
  scale: number;
  main: boolean;
  asleep?: boolean;
  name?: string;
  kind?: "builtin" | "external";
}

/** A display's connection phase (docs/PROTOCOL.md「连接状态」). */
export type Phase = "connecting" | "reconnecting" | "ready" | "unavailable";

/** Why the phase is what it is. An open set; `helper-restart` / `helper-down` are made up by this client. */
export type StateReason = "starting" | "helper-restart" | "no-session" | "no-permission" | "helper-down" | (string & {});

/** One display's connection state (`/events` `{"type":"state"}`, `/status.states`). */
export interface DisplayState {
  display: number;
  main?: boolean;
  phase: Phase;
  reason?: StateReason;
  /** ms since epoch: when this phase + reason began. */
  since: number;
  /** ms: the next attempt to start the service (helper-down, with backoff). */
  retryAt?: number;
  /** English, technical; never the main UI text. */
  detail?: string;
}

/** The console: `locked` = the lock screen is up. */
export interface Console {
  locked: boolean;
}

/** What a server can do right now (`/status.features`): true works, false doesn't, absent = not said. Open set. */
export interface Features {
  clipboard?: boolean;
  audio?: boolean;
  cursor?: boolean;
  focus?: boolean;
  [feature: string]: boolean | undefined;
}

export type InputType = "click" | "doubleClick" | "rightClick" | "move" | "drag" | "scroll" | "type" | "key" | "down" | "up";
export const INPUT_TYPES: readonly InputType[] = ["click", "doubleClick", "rightClick", "move", "drag", "scroll", "type", "key", "down", "up"];
export type PointerButton = "left";
export const POINTER_BUTTONS: readonly PointerButton[] = ["left"];
export type ScrollPhase = "began" | "changed" | "ended";
export const SCROLL_PHASES: readonly ScrollPhase[] = ["began", "changed", "ended"];
export type Modifier = "cmd" | "shift" | "alt" | "ctrl";
export const MODIFIERS: readonly Modifier[] = ["cmd", "shift", "alt", "ctrl"];

/** POST /input (docs/PROTOCOL.md「输入」): coordinates normalized 0…1 of the display. */
export interface Input {
  type: InputType;
  display?: number;
  x?: number;
  y?: number;
  dx?: number;
  dy?: number;
  text?: string;
  key?: string;
  modifiers?: Modifier[];
  /** `move` only: the button held (a live drag between `down` and `up`). */
  button?: PointerButton;
  /** `scroll` only: the two-finger gesture's phase. */
  phase?: ScrollPhase;
  /** `scroll` only, on `ended`: the velocity at lift (points per second). */
  vx?: number;
  vy?: number;
  /** `move` only: the client's move counter (the server answers an overtaken one `stale`). */
  seq?: number;
}

/** POST /input's answer. `stale`: a move another one overtook; not applied. */
export interface InputResponse {
  ok: true;
  stale?: true;
}

/** A client's playout report, relayed as it came (the server decodes it leniently). */
export interface PlayoutReport {
  mode: string;
  [field: string]: unknown;
}

/** POST /stream/ack body. */
export interface StreamAck {
  stream: string;
  seq: number;
  keyframe?: boolean;
  report?: PlayoutReport;
}

/** GET /focus: whether the focused element takes typing. */
export interface Focus {
  editable: boolean;
  role: string | null;
}

/** The automation indicator (`/status.automation`; older builds `agentControl`). */
export interface AutomationState {
  active?: unknown;
  esc?: unknown;
  label?: unknown;
}

/** GET /status as a server answers it (every field unchecked: a server may be older or newer). */
export interface AppStatus {
  ok: boolean;
  error?: string;
  /** The account's GUI login session. */
  session?: { loggedIn?: unknown };
  screenRecording?: boolean;
  accessibility?: boolean;
  displays?: Display[];
  states?: DisplayState[];
  console?: Console | null;
  automation?: AutomationState;
  agentControl?: AutomationState;
  /** Who answers: "YoyoControl" for the Mac app; a remote server names itself. */
  app?: unknown;
  version?: unknown;
  build?: unknown;
  api?: unknown;
  /** What kind of computer ("linux"; the Mac's doesn't say). */
  platform?: unknown;
  features?: unknown;
  control?: unknown;
  [field: string]: unknown;
}

/** The server in use: the installed app ("app") or a service this client started itself ("child"). */
export interface ServerIdentity {
  mode: "app" | "child";
  version?: string;
  build?: string;
  api?: number;
}
