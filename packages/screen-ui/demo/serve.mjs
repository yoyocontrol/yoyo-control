// Serves the demo: the page from here, the packages' dist from their folders (link-web's only for `?link=`).
// `PORT` (default 8790).
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";

const here = fileURLToPath(new URL(".", import.meta.url));
const roots = { "/screen-ui/": join(here, "../dist"), "/screen-web/": join(here, "../../screen-web/dist"), "/link-web/": join(here, "../../link-web/dist"), "/": here };
const types = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".css": "text/css", ".map": "application/json", ".wasm": "application/wasm" };

createServer(async (req, res) => {
  const path = decodeURIComponent(new URL(req.url, "http://x").pathname);
  const [prefix, root] = Object.entries(roots).find(([p]) => path.startsWith(p));
  const rel = normalize(path.slice(prefix.length) || "index.html");
  if (rel.startsWith("..")) return res.writeHead(400).end();
  try {
    const body = await readFile(join(root, rel === "." ? "index.html" : rel));
    res.writeHead(200, { "content-type": types[extname(rel)] ?? "application/octet-stream", "cache-control": "no-store" }).end(body);
  } catch {
    res.writeHead(404).end("not found");
  }
}).listen(Number(process.env.PORT ?? 8790), () => console.log(`demo on http://localhost:${process.env.PORT ?? 8790}/`));
