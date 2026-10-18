import {
  FrameType,
  decodeAckPayload,
  decodeFrame,
  decodeReqHead,
  encodeAckPayload,
  encodeFrame,
  encodeJson,
  type ReqHead,
} from "../shared/protocol.ts";

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
}

const relayUrl = requireEnv("RELAY_URL");
const token = requireEnv("SPIKE_TOKEN");
const origin = process.env.ORIGIN_URL ?? "http://127.0.0.1:18080";
const chunkSize = Number(process.env.CHUNK_BYTES ?? 256 * 1024);
// 0 は window なし (ack を待たずに送る)
const windowBytes = Number(process.env.WINDOW_BYTES ?? 0);
const EMPTY = new Uint8Array(0);

const ws = new WebSocket(`${relayUrl.replace(/^http/, "ws")}/_ws`, { headers: { "x-spike-token": token } });
ws.binaryType = "arraybuffer";

interface Active {
  abort: AbortController;
  inflight: number;
  wake: (() => void) | null;
  bodyQueue: Uint8Array[];
  bodyEnded: boolean;
  bodyWake: (() => void) | null;
  bodyFrames: number;
  bodyBytes: number;
}

const active = new Map<number, Active>();

function send(type: FrameType, id: number, payload: Uint8Array): void {
  ws.send(encodeFrame(type, id, payload));
}

function requestBody(id: number, state: Active): ReadableStream<Uint8Array> {
  return new ReadableStream<Uint8Array>(
    {
      async pull(controller) {
        while (state.bodyQueue.length === 0 && !state.bodyEnded) {
          await new Promise<void>((resolve) => {
            state.bodyWake = resolve;
          });
        }
        const chunk = state.bodyQueue.shift();
        if (chunk) {
          send(FrameType.Ack, id, encodeAckPayload(chunk.length));
          controller.enqueue(chunk);
          return;
        }
        controller.close();
      },
    },
    { highWaterMark: 0 },
  );
}

async function serve(id: number, head: ReqHead, state: Active): Promise<void> {
  try {
    const headers = new Headers();
    for (const [name, value] of head.headers) {
      if (name === "content-length" || name === "transfer-encoding") continue;
      headers.append(name, value);
    }
    const init: RequestInit & { duplex?: "half" } = {
      method: head.method,
      headers,
      signal: state.abort.signal,
    };
    if (head.hasBody) {
      init.body = requestBody(id, state);
      init.duplex = "half";
    }
    const response = await fetch(origin + head.path, init);
    send(
      FrameType.ResHead,
      id,
      encodeJson({ status: response.status, headers: [...response.headers] }),
    );
    if (response.body) {
      for await (const chunk of response.body) {
        for (let offset = 0; offset < chunk.length; offset += chunkSize) {
          while (windowBytes > 0 && state.inflight >= windowBytes && !state.abort.signal.aborted) {
            await new Promise<void>((resolve) => {
              state.wake = resolve;
            });
          }
          if (state.abort.signal.aborted) return;
          const part = chunk.subarray(offset, offset + chunkSize);
          send(FrameType.ResBody, id, part);
          state.inflight += part.length;
        }
      }
    }
    send(FrameType.ResEnd, id, EMPTY);
  } catch (error) {
    if (!state.abort.signal.aborted) {
      console.error(`request ${id} failed: ${(error as Error).message}`);
      send(FrameType.Cancel, id, EMPTY);
    }
  } finally {
    active.delete(id);
  }
}

ws.addEventListener("message", (event) => {
  if (!(event.data instanceof ArrayBuffer)) return;
  const frame = decodeFrame(event.data);
  const state = active.get(frame.id);
  switch (frame.type) {
    case FrameType.ReqHead: {
      const created: Active = {
        abort: new AbortController(),
        inflight: 0,
        wake: null,
        bodyQueue: [],
        bodyEnded: false,
        bodyWake: null,
        bodyFrames: 0,
        bodyBytes: 0,
      };
      active.set(frame.id, created);
      void serve(frame.id, decodeReqHead(frame.payload), created);
      break;
    }
    case FrameType.ReqBody:
      if (state) {
        state.bodyFrames += 1;
        state.bodyBytes += frame.payload.length;
      }
      state?.bodyQueue.push(frame.payload);
      state?.bodyWake?.();
      break;
    case FrameType.ReqEnd:
      if (state) {
        console.log(`request ${frame.id} body frames=${state.bodyFrames} bytes=${state.bodyBytes} at=${Date.now()}`);
        state.bodyEnded = true;
      }
      state?.bodyWake?.();
      break;
    case FrameType.Ack:
      if (state) state.inflight -= decodeAckPayload(frame.payload);
      state?.wake?.();
      break;
    case FrameType.Cancel:
      state?.abort.abort();
      state?.wake?.();
      if (state) state.bodyEnded = true;
      state?.bodyWake?.();
      break;
    default:
      break;
  }
});

ws.addEventListener("open", () => {
  console.log(`agent connected chunk=${chunkSize} window=${windowBytes}`);
});
ws.addEventListener("close", (event) => {
  console.log(`agent closed code=${event.code} reason=${event.reason} at=${new Date().toISOString()}`);
  process.exit(0);
});
ws.addEventListener("error", () => {
  console.error("agent socket error");
});
