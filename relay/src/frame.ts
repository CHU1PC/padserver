export const FrameType = {
  ReqHead: 1,
  ReqBody: 2,
  ReqEnd: 3,
  ResHead: 4,
  ResBody: 5,
  ResEnd: 6,
  Cancel: 7,
  Ack: 8,
} as const;
export type FrameType = (typeof FrameType)[keyof typeof FrameType];

export const HEADER_SIZE = 5;
export const MAX_BODY_CHUNK = 1_048_576;

const MAX_UINT32 = 0xffff_ffff;

export interface Frame {
  type: FrameType;
  id: number;
  payload: Uint8Array;
}

export type HeaderPair = [name: string, value: string];

export interface ReqHead {
  method: string;
  path: string;
  host: string;
  headers: HeaderPair[];
  hasBody: boolean;
}

export interface ResHead {
  status: number;
  headers: HeaderPair[];
}

export type FrameErrorLevel = "decode" | "connection" | "request";

export class FrameError extends Error {
  readonly level: FrameErrorLevel;

  constructor(level: FrameErrorLevel, message: string) {
    super(message);
    this.name = "FrameError";
    this.level = level;
  }
}

const frameTypes = new Set<number>(Object.values(FrameType));

export function encodeFrame(type: FrameType, id: number, payload: Uint8Array): Uint8Array {
  if (!Number.isInteger(id) || id < 0 || id > MAX_UINT32) throw new FrameError("decode", "request id out of range");
  const out = new Uint8Array(HEADER_SIZE + payload.length);
  const view = new DataView(out.buffer);
  view.setUint8(0, type);
  view.setUint32(1, id);
  out.set(payload, HEADER_SIZE);
  return out;
}

export function decodeFrame(data: Uint8Array | ArrayBuffer): Frame {
  const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
  if (bytes.length < HEADER_SIZE) throw new FrameError("decode", "frame too short");
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const type = view.getUint8(0);
  if (!frameTypes.has(type)) throw new FrameError("decode", `unknown frame type ${type}`);
  return { type: type as FrameType, id: view.getUint32(1), payload: bytes.subarray(HEADER_SIZE) };
}

export function checkBodyChunk(payload: Uint8Array): void {
  if (payload.length > MAX_BODY_CHUNK) throw new FrameError("connection", "body chunk too large");
}

export function encodeAckPayload(bytes: number): Uint8Array {
  if (!Number.isInteger(bytes) || bytes < 0 || bytes > MAX_UINT32) throw new FrameError("decode", "ack bytes out of range");
  const out = new Uint8Array(4);
  new DataView(out.buffer).setUint32(0, bytes);
  return out;
}

export function decodeAckPayload(payload: Uint8Array): number {
  if (payload.length !== 4) throw new FrameError("connection", "ack payload must be 4 bytes");
  return new DataView(payload.buffer, payload.byteOffset, payload.byteLength).getUint32(0);
}

export function encodeReqHead(head: ReqHead): Uint8Array {
  const ordered: ReqHead = {
    method: head.method,
    path: head.path,
    host: head.host,
    headers: head.headers,
    hasBody: head.hasBody,
  };
  return new TextEncoder().encode(JSON.stringify(ordered));
}

export function encodeResHead(head: ResHead): Uint8Array {
  const ordered: ResHead = { status: head.status, headers: head.headers };
  return new TextEncoder().encode(JSON.stringify(ordered));
}

export function decodeReqHead(payload: Uint8Array): ReqHead {
  const value = parseHead(payload);
  const { method, path, host, headers, hasBody } = value;
  if (typeof method !== "string" || typeof host !== "string" || typeof hasBody !== "boolean") throw invalidHead();
  if (typeof path !== "string" || !path.startsWith("/")) throw invalidHead();
  return { method, path, host, headers: toHeaderPairs(headers), hasBody };
}

export function decodeResHead(payload: Uint8Array): ResHead {
  const value = parseHead(payload);
  const { status, headers } = value;
  if (typeof status !== "number" || !Number.isInteger(status) || status < 200 || status > 599) throw invalidHead();
  return { status, headers: toHeaderPairs(headers) };
}

function invalidHead(): FrameError {
  return new FrameError("request", "invalid head");
}

function parseHead(payload: Uint8Array): Record<string, unknown> {
  let value: unknown;
  try {
    value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(payload));
  } catch {
    throw invalidHead();
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw invalidHead();
  return value as Record<string, unknown>;
}

function toHeaderPairs(value: unknown): HeaderPair[] {
  if (!Array.isArray(value)) throw invalidHead();
  return value.map((pair): HeaderPair => {
    if (!Array.isArray(pair) || pair.length !== 2) throw invalidHead();
    const [name, headerValue] = pair as unknown[];
    if (typeof name !== "string" || typeof headerValue !== "string") throw invalidHead();
    return [name, headerValue];
  });
}
