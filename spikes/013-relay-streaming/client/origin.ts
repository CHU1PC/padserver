import { MAX_PATTERN_SLICE, patternSlice } from "../shared/pattern.ts";

const port = Number(process.env.ORIGIN_PORT ?? 18080);
const STREAM_CHUNK = Number(process.env.ORIGIN_CHUNK_BYTES ?? 256 * 1024);

function bigBody(start: number, length: number): ReadableStream<Uint8Array> {
  let sent = 0;
  return new ReadableStream<Uint8Array>({
    pull(controller) {
      if (sent >= length) {
        controller.close();
        return;
      }
      const n = Math.min(STREAM_CHUNK, MAX_PATTERN_SLICE, length - sent);
      controller.enqueue(patternSlice(start + sent, n));
      sent += n;
    },
  });
}

function parseRange(header: string, size: number): { start: number; end: number } | null {
  const match = /^bytes=(\d*)-(\d*)$/.exec(header);
  if (!match) return null;
  const [, first = "", last = ""] = match;
  if (first === "" && last === "") return null;
  if (first === "") {
    const suffix = Number(last);
    return { start: Math.max(0, size - suffix), end: size - 1 };
  }
  const start = Number(first);
  const end = last === "" ? size - 1 : Math.min(Number(last), size - 1);
  return start <= end && start < size ? { start, end } : null;
}

function handleBig(request: Request, url: URL): Response {
  const size = Number(url.searchParams.get("size") ?? 0);
  const rangeHeader = request.headers.get("range");
  if (rangeHeader === null) {
    return new Response(bigBody(0, size), {
      headers: { "content-type": "application/octet-stream", "content-length": String(size), "accept-ranges": "bytes" },
    });
  }
  const range = parseRange(rangeHeader, size);
  if (!range) return new Response(null, { status: 416, headers: { "content-range": `bytes */${size}` } });
  const length = range.end - range.start + 1;
  return new Response(bigBody(range.start, length), {
    status: 206,
    headers: {
      "content-type": "application/octet-stream",
      "content-length": String(length),
      "content-range": `bytes ${range.start}-${range.end}/${size}`,
      "accept-ranges": "bytes",
    },
  });
}

function handleSse(url: URL): Response {
  const count = Number(url.searchParams.get("count") ?? 50);
  const interval = Number(url.searchParams.get("interval") ?? 100);
  const body = new ReadableStream<Uint8Array>({
    async start(controller) {
      const encoder = new TextEncoder();
      for (let seq = 0; seq < count; seq++) {
        controller.enqueue(encoder.encode(`data: ${JSON.stringify({ seq, sent: Date.now() })}\n\n`));
        await Bun.sleep(interval);
      }
      controller.close();
    },
  });
  return new Response(body, { headers: { "content-type": "text/event-stream", "cache-control": "no-cache" } });
}

async function handleUpload(request: Request): Promise<Response> {
  let bytes = 0;
  if (request.body) {
    for await (const chunk of request.body) bytes += chunk.length;
  }
  return Response.json({ bytes });
}

Bun.serve({
  port,
  hostname: "127.0.0.1",
  idleTimeout: 120,
  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/big") return handleBig(request, url);
    if (url.pathname === "/sse") return handleSse(url);
    if (url.pathname === "/upload" && request.method === "POST") return handleUpload(request);
    return new Response("not found", { status: 404 });
  },
});
console.log(`origin listening on 127.0.0.1:${port}`);
