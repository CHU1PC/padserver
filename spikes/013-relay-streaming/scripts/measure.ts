import { MAX_PATTERN_SLICE, patternSlice } from "../shared/pattern.ts";

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
}

const base = requireEnv("RELAY_URL");
const authHeaders = { "x-spike-token": requireEnv("SPIKE_TOKEN") };
const MB = 1_000_000;

function scrub(text: string): string {
  return text.replaceAll(new URL(base).host, "<relay-host>");
}

function matches(chunk: Uint8Array, offset: number): boolean {
  for (let done = 0; done < chunk.length; done += MAX_PATTERN_SLICE) {
    const part = chunk.subarray(done, done + MAX_PATTERN_SLICE);
    if (Buffer.compare(part, patternSlice(offset + done, part.length)) !== 0) return false;
  }
  return true;
}

interface ReadResult {
  status: number;
  received: number;
  seconds: number;
  ok: boolean;
  error: string;
  headers: Headers;
}

// delayPerByte (秒) だけ読むのを遅らせて, 遅い受け手を作る
async function readPattern(
  path: string,
  extraHeaders: Record<string, string>,
  startOffset: number,
  delayPerByte: number,
): Promise<ReadResult> {
  const t0 = performance.now();
  let received = 0;
  let ok = true;
  let error = "";
  let lastProgress = Date.now();
  let status = 0;
  let headers = new Headers();
  try {
    const response = await fetch(base + path, { headers: { ...authHeaders, ...extraHeaders } });
    status = response.status;
    headers = response.headers;
    if (response.body && (status === 200 || status === 206)) {
      for await (const chunk of response.body) {
        if (ok && !matches(chunk, startOffset + received)) ok = false;
        received += chunk.length;
        if (delayPerByte > 0 && Date.now() - lastProgress >= 10_000) {
          lastProgress = Date.now();
          console.log(`  progress t=${((performance.now() - t0) / 1000).toFixed(0)}s received=${received}`);
        }
        if (delayPerByte > 0) await Bun.sleep(chunk.length * delayPerByte * 1000);
      }
    } else if (response.body) {
      await response.body.cancel();
    }
  } catch (caught) {
    error = scrub((caught as Error).message);
  }
  return { status, received, seconds: (performance.now() - t0) / 1000, ok, error, headers };
}

function rate(result: ReadResult): string {
  const mibPerSecond = result.received / 1_048_576 / result.seconds;
  return `MiB_per_s=${mibPerSecond.toFixed(2)} Mbit_per_s=${(mibPerSecond * 8 * 1.048576).toFixed(1)}`;
}

async function download(sizeMb: number): Promise<void> {
  const size = sizeMb * MB;
  const r = await readPattern(`/big?size=${size}`, {}, 0, 0);
  console.log(
    `DOWNLOAD size=${size} status=${r.status} received=${r.received} seconds=${r.seconds.toFixed(2)} ${rate(r)} content_ok=${r.ok && r.received === size} error="${r.error}"`,
  );
}

async function slow(sizeMb: number, kBps: number): Promise<void> {
  const size = sizeMb * MB;
  const r = await readPattern(`/big?size=${size}`, {}, 0, 1 / (kBps * 1000));
  console.log(
    `SLOW size=${size} consumer_rate=${kBps}KB/s status=${r.status} received=${r.received} seconds=${r.seconds.toFixed(2)} complete=${r.received === size} content_ok=${r.ok} error="${r.error}"`,
  );
}

async function range(): Promise<void> {
  const size = 100 * MB;
  const cases: { label: string; header: string; start: number; length: number }[] = [
    { label: "first-100B", header: "bytes=0-99", start: 0, length: 100 },
    { label: "middle-1MB", header: "bytes=1000000-1999999", start: 1_000_000, length: MB },
    { label: "suffix-500B", header: "bytes=-500", start: size - 500, length: 500 },
    { label: "open-ended-tail-10MB", header: `bytes=${size - 10 * MB}-`, start: size - 10 * MB, length: 10 * MB },
    { label: "middle-50MB", header: `bytes=10000000-59999999`, start: 10 * MB, length: 50 * MB },
  ];
  for (const c of cases) {
    const r = await readPattern(`/big?size=${size}`, { range: c.header }, c.start, 0);
    console.log(
      `RANGE ${c.label} header=${c.header} status=${r.status} content_range="${r.headers.get("content-range")}" received=${r.received} expected=${c.length} seconds=${r.seconds.toFixed(2)} content_ok=${r.ok && r.received === c.length}`,
    );
  }
  const bad = await readPattern(`/big?size=${size}`, { range: `bytes=${size + 5}-` }, 0, 0);
  console.log(`RANGE unsatisfiable header=bytes=${size + 5}- status=${bad.status} content_range="${bad.headers.get("content-range")}"`);
}

function percentile(sorted: number[], p: number): number {
  return sorted[Math.min(sorted.length - 1, Math.floor((sorted.length * p) / 100))] ?? 0;
}

async function sse(count: number, interval: number): Promise<void> {
  const t0 = Date.now();
  const response = await fetch(`${base}/sse?count=${count}&interval=${interval}`, { headers: authHeaders });
  const firstByteMs = Date.now() - t0;
  const latencies: number[] = [];
  const gaps: number[] = [];
  let lastArrival = 0;
  let buffer = "";
  const decoder = new TextDecoder();
  if (response.body) {
    for await (const chunk of response.body) {
      const arrival = Date.now();
      buffer += decoder.decode(chunk, { stream: true });
      for (let end = buffer.indexOf("\n\n"); end >= 0; end = buffer.indexOf("\n\n")) {
        const event = buffer.slice(0, end);
        buffer = buffer.slice(end + 2);
        const sent = (JSON.parse(event.slice("data: ".length)) as { sent: number }).sent;
        latencies.push(arrival - sent);
        if (lastArrival > 0) gaps.push(arrival - lastArrival);
        lastArrival = arrival;
      }
    }
  }
  const sorted = [...latencies].sort((a, b) => a - b);
  const sortedGaps = [...gaps].sort((a, b) => a - b);
  console.log(
    `SSE status=${response.status} events=${latencies.length}/${count} interval_ms=${interval} first_byte_ms=${firstByteMs} latency_ms min=${sorted[0]} p50=${percentile(sorted, 50)} p95=${percentile(sorted, 95)} max=${sorted[sorted.length - 1]} arrival_gap_ms min=${sortedGaps[0]} p50=${percentile(sortedGaps, 50)} max=${sortedGaps[sortedGaps.length - 1]}`,
  );
}

async function upload(sizeMb: number): Promise<void> {
  const size = sizeMb * MB;
  let sent = 0;
  const body = new ReadableStream<Uint8Array>({
    pull(controller) {
      if (sent >= size) {
        controller.close();
        return;
      }
      const n = Math.min(MAX_PATTERN_SLICE, size - sent);
      controller.enqueue(patternSlice(sent, n));
      sent += n;
    },
  });
  const t0 = performance.now();
  try {
    const init: RequestInit & { duplex?: "half" } = { method: "POST", headers: authHeaders, body, duplex: "half" };
    const response = await fetch(`${base}/upload`, init);
    const seconds = (performance.now() - t0) / 1000;
    const text = (await response.text()).slice(0, 200);
    console.log(`UPLOAD(chunked) size=${size} status=${response.status} seconds=${seconds.toFixed(2)} body=${text}`);
  } catch (caught) {
    console.log(`UPLOAD(chunked) size=${size} error="${scrub((caught as Error).message)}"`);
  }
}

async function stats(reset: boolean): Promise<void> {
  const response = await fetch(`${base}/_stats${reset ? "?reset" : ""}`, { headers: authHeaders });
  console.log(`STATS ${await response.text()}`);
}

const [command = "", a = "0", b = "0"] = process.argv.slice(2);
switch (command) {
  case "download":
    await download(Number(a));
    break;
  case "slow":
    await slow(Number(a), Number(b));
    break;
  case "range":
    await range();
    break;
  case "sse":
    await sse(Number(a), Number(b));
    break;
  case "upload":
    await upload(Number(a));
    break;
  case "stats":
    await stats(a === "reset");
    break;
  default:
    console.error("usage: measure.ts download|slow|range|sse|upload|stats ...");
    process.exit(1);
}
