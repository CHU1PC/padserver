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

// type (1 byte) + request id (4 bytes, big endian)
export const HEADER_SIZE = 5;

export interface Frame {
  type: FrameType;
  id: number;
  payload: Uint8Array;
}

export interface ReqHead {
  method: string;
  path: string;
  headers: [string, string][];
  hasBody: boolean;
}

export interface ResHead {
  status: number;
  headers: [string, string][];
}

const frameTypes = new Set<number>(Object.values(FrameType));

export function encodeFrame(type: FrameType, id: number, payload: Uint8Array): ArrayBuffer {
  const out = new Uint8Array(HEADER_SIZE + payload.length);
  const view = new DataView(out.buffer);
  view.setUint8(0, type);
  view.setUint32(1, id);
  out.set(payload, HEADER_SIZE);
  return out.buffer;
}

export function decodeFrame(data: ArrayBuffer): Frame {
  if (data.byteLength < HEADER_SIZE) throw new Error("frame too short");
  const view = new DataView(data);
  const type = view.getUint8(0);
  if (!frameTypes.has(type)) throw new Error(`unknown frame type ${type}`);
  return { type: type as FrameType, id: view.getUint32(1), payload: new Uint8Array(data, HEADER_SIZE) };
}

export function encodeJson(value: ReqHead | ResHead): Uint8Array {
  return new TextEncoder().encode(JSON.stringify(value));
}

export function decodeReqHead(payload: Uint8Array): ReqHead {
  return JSON.parse(new TextDecoder().decode(payload)) as ReqHead;
}

export function decodeResHead(payload: Uint8Array): ResHead {
  return JSON.parse(new TextDecoder().decode(payload)) as ResHead;
}

export function encodeAckPayload(bytes: number): Uint8Array {
  const out = new Uint8Array(4);
  new DataView(out.buffer).setUint32(0, bytes);
  return out;
}

export function decodeAckPayload(payload: Uint8Array): number {
  return new DataView(payload.buffer, payload.byteOffset, payload.byteLength).getUint32(0);
}
