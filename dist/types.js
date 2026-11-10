// The local API's wire shapes this client reads and writes (mac/README.md「HTTP API」, docs/PROTOCOL.md). Open sets
// stay open: a server newer than this client may send values it doesn't list.
export const INPUT_TYPES = ["click", "doubleClick", "rightClick", "move", "drag", "scroll", "type", "key", "down", "up"];
export const POINTER_BUTTONS = ["left"];
export const SCROLL_PHASES = ["began", "changed", "ended"];
export const MODIFIERS = ["cmd", "shift", "alt", "ctrl"];
