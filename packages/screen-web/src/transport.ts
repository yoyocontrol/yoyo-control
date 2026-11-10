/**
 * How the web client reaches a screen: one `fetch`-shaped function the host supplies. The client never builds URLs or
 * picks credentials itself; it asks for these resources, and the transport maps them to its own server (adding a path
 * prefix, cookies or a token, device headers, a different method):
 *
 * | request | what it is |
 * | --- | --- |
 * | `POST /stream` | the video stream; JSON body = the stream's parameters (`GET /stream`'s query as JSON), `Accept` names the media types the client reads |
 * | `POST /stream/ack` | an ack (JSON `StreamAck`) |
 * | `POST /audio` | the sound; body `{}`, `Accept` as for the stream |
 * | `GET /frame?maxWidth=&quality=&display=` | one JPEG |
 * | `POST /input` | an input (JSON `Input`) |
 * | `POST /control` | take / release control (JSON `{ controller, device? }`) |
 *
 * The stream and the sound are POST so a proxy in between can't buffer or cache them; a transport for a server that
 * only takes `GET /stream?…` turns the body back into the query.
 */
export interface ScreenTransport {
  fetch(path: string, init: RequestInit): Promise<Response>;
}

/** A refused request: its HTTP status, the server's `error` text, and its JSON body (e.g. a 409's `code`). */
export class RequestError extends Error {
  constructor(
    readonly status: number,
    message: string,
    readonly body?: unknown,
  ) {
    super(message);
  }
}

/** A response that isn't ok as a RequestError (its JSON `error`, else `HTTP <status>`). */
export async function requestError(res: Response): Promise<RequestError> {
  let body: { error?: unknown } | undefined;
  try {
    body = (await res.json()) as typeof body;
  } catch {
    /* not JSON */
  }
  return new RequestError(res.status, typeof body?.error === "string" ? body.error : `HTTP ${res.status}`, body);
}

/** The global fetch with a path prefix and same-origin credentials (a page served by the screen's own server). */
export function sameOriginTransport(prefix = "", extraHeaders: (path: string) => Record<string, string> = () => ({})): ScreenTransport {
  return {
    fetch: (path, init) =>
      fetch(`${prefix}${path}`, {
        credentials: "same-origin",
        ...init,
        headers: { ...(init.headers as Record<string, string> | undefined), ...extraHeaders(path) },
      }),
  };
}
