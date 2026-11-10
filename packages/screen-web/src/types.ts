// The wire shapes the web client reads and writes (docs/PROTOCOL.md). Open sets stay open.

export type Modifier = "cmd" | "shift" | "alt" | "ctrl";
export type ScrollPhase = "began" | "changed" | "ended";
export type InputType = "click" | "doubleClick" | "rightClick" | "move" | "drag" | "scroll" | "type" | "key" | "down" | "up";

/** An input to the computer (docs/PROTOCOL.md「输入」): coordinates normalized 0…1 of the display. */
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
  button?: "left";
  phase?: ScrollPhase;
  vx?: number;
  vy?: number;
  seq?: number;
}

/** What a server can do right now (`features`): true works, false doesn't, absent = not said. */
export interface Features {
  clipboard?: boolean;
  audio?: boolean;
  cursor?: boolean;
  focus?: boolean;
}

/** One display. `width` / `height` in points, `scale` = pixels per point. */
export interface Display {
  id: number;
  width: number;
  height: number;
  scale: number;
  main: boolean;
  asleep?: boolean;
  name?: string;
  kind?: string;
}

export type StatePhase = "connecting" | "reconnecting" | "ready" | "unavailable";

/** A display's connection state (「连接状态」). */
export interface DisplayState {
  display: number;
  main?: boolean;
  phase: StatePhase | (string & {});
  reason?: string;
  since: number;
  retryAt?: number;
  detail?: string;
}

export interface Console {
  locked: boolean;
}

/** A status part of the stream: its display's state, and the console. */
export interface StreamStatusPart extends DisplayState {
  console?: Console | null;
}

/** A cursor part (`cursor=client`): coordinates 0…1 of the display; `shape` only when it changed. */
export interface CursorPart {
  x: number;
  y: number;
  visible: boolean;
  shapeId: number;
  shape?: { id: number; png: string; hotX: number; hotY: number; width: number; height: number };
}

/** The client's network, inside a playout report. */
export interface NetReport {
  route?: "lan" | "tunnel" | (string & {});
  iface?: string;
  radio?: string;
  expensive?: boolean;
  constrained?: boolean;
  inputRttMs?: { p50?: number; p90?: number; n?: number };
  rxKbps?: number;
  failures?: number;
}

/** How the client's playout is going (on an ack every ~2 s; for the server's log). */
export interface PlayoutReport {
  mode: "smooth" | "latency";
  fps?: number;
  gapP50Ms?: number;
  gapP90Ms?: number;
  arrivalGapP50Ms?: number;
  arrivalGapP90Ms?: number;
  hitchesPerSec?: number;
  bufferMs?: number;
  droppedPerSec?: number;
  decodeMs?: number;
  refreshHz?: number;
  paceMs?: number;
  bufferCapMs?: number;
  /** The p95 of (delay − base) in the playout's estimate. */
  jitterP95Ms?: number;
  /** `latency`: the interactive depth in use; 0 = shown on arrival. */
  touchBufferMs?: number;
  /** Live pictures in a row shown ≥ 150 / 300 ms further apart than the computer captured them, per second. */
  stall150PerSec?: number;
  stall300PerSec?: number;
  /** How the computer's sound plays here (`AudioReport`), while a sound stream is open. */
  audio?: AudioReport;
  net?: NetReport;
  [field: string]: unknown;
}

/** `PlayoutReport.audio` (docs/PROTOCOL.md「声音」): how the computer's sound plays here, for its log. Milliseconds;
 *  counts since the previous report that carried one. */
export interface AudioReport {
  /** The output's latency (AudioContext `outputLatency` + `baseLatency`) and its render quantum. */
  outputMs: number;
  ioMs: number;
  bluetooth?: boolean;
  /** The jitter depth the buffer itself needs (not the A/V sync's). */
  depthMs: number;
  bufferedMs: number;
  /** What this side adds to a packet that came on time: the playout delay + the output latency. */
  addedMs: number;
  /** Sound − picture for the same instant (+ = sound later). */
  skewMs?: number;
  /** Extra video delay used for sync, when > 0. */
  floorMs?: number;
  underruns: number;
  late: number;
  concealed: number;
  cuts: number;
  /** Net time-stretch (cuts make it negative). */
  stretchMs?: number;
  kbps?: number;
}

/** An ack of a stream's pictures (cumulative `seq`). */
export interface StreamAck {
  stream: string;
  seq: number;
  keyframe?: boolean;
  report?: PlayoutReport;
}

/** How the stream's network looks to the server. */
export interface NetQuality {
  grade: "good" | "fair" | "poor" | "unknown" | (string & {});
  rttMs?: { min: number; p50: number; p90: number };
  jitterMs?: number;
  reasons: string[];
}

export interface StreamAckResponse {
  ok: true;
  net?: NetQuality;
}

/** A device that controls the screen: an id, and a name to show. */
export interface ControlDevice {
  id: string;
  name?: string;
}

/** Who controls the screen ("user" = a person's device; servers may name others). */
export type Controller = "none" | "user" | "agent" | (string & {});
