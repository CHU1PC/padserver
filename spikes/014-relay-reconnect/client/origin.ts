const port = Number(process.env.ORIGIN_PORT ?? 18080);

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

Bun.serve({
  port,
  hostname: "127.0.0.1",
  idleTimeout: 120,
  fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/ping") return new Response("ok");
    if (url.pathname === "/sse") return handleSse(url);
    return new Response("not found", { status: 404 });
  },
});
console.log(`origin listening on 127.0.0.1:${port}`);
