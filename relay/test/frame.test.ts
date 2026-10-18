import { describe, expect, test } from "bun:test";
import {
  FrameError,
  FrameType,
  checkBodyChunk,
  decodeAckPayload,
  decodeFrame,
  decodeReqHead,
  decodeResHead,
  encodeAckPayload,
  encodeFrame,
  encodeReqHead,
  encodeResHead,
  type ReqHead,
  type ResHead,
} from "../src/frame";

type VectorPayload =
  | { json: ReqHead | ResHead }
  | { utf8: string }
  | { hex: string }
  | { ackBytes: number }
  | { repeat: { byteHex: string; count: number } };

interface Vector {
  name: string;
  frame: { type: keyof typeof FrameType; typeValue: number; id: number; payload: VectorPayload };
  hex?: string;
  headerHex?: string;
  totalLength?: number;
  decodeOnly?: boolean;
}

interface InvalidVector {
  name: string;
  hex?: string;
  headerHex?: string;
  payload?: { repeat: { byteHex: string; count: number } };
  totalLength?: number;
  expect: { level: "decode" | "connection" | "request"; reason: string };
}

const frames = (await Bun.file(new URL("../test-vectors/frames.json", import.meta.url)).json()) as {
  frames: Vector[];
};
const invalid = (await Bun.file(new URL("../test-vectors/invalid-frames.json", import.meta.url)).json()) as {
  invalidFrames: InvalidVector[];
};

const fromHex = (hex: string): Uint8Array => {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = Number.parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return out;
};

const toHex = (bytes: Uint8Array): string => Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");

const repeated = (byteHex: string, count: number): Uint8Array => new Uint8Array(count).fill(fromHex(byteHex)[0] ?? 0);

const concat = (a: Uint8Array, b: Uint8Array): Uint8Array => {
  const out = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
};

const payloadBytes = (type: number, payload: VectorPayload): Uint8Array => {
  if ("json" in payload) {
    return type === FrameType.ReqHead
      ? encodeReqHead(payload.json as ReqHead)
      : encodeResHead(payload.json as ResHead);
  }
  if ("utf8" in payload) return new TextEncoder().encode(payload.utf8);
  if ("hex" in payload) return fromHex(payload.hex);
  if ("ackBytes" in payload) return encodeAckPayload(payload.ackBytes);
  return repeated(payload.repeat.byteHex, payload.repeat.count);
};

const wireBytes = (v: { hex?: string; headerHex?: string; payload?: { repeat: { byteHex: string; count: number } } }) =>
  v.hex !== undefined
    ? fromHex(v.hex)
    : concat(fromHex(v.headerHex ?? ""), repeated(v.payload?.repeat.byteHex ?? "00", v.payload?.repeat.count ?? 0));

const catchError = (fn: () => unknown): unknown => {
  try {
    fn();
  } catch (error) {
    return error;
  }
  return undefined;
};

describe("valid frames", () => {
  for (const v of frames.frames) {
    test(`decode ${v.name}`, () => {
      const bytes =
        v.hex !== undefined
          ? fromHex(v.hex)
          : concat(
              fromHex(v.headerHex ?? ""),
              "repeat" in v.frame.payload
                ? repeated(v.frame.payload.repeat.byteHex, v.frame.payload.repeat.count)
                : new Uint8Array(),
            );
      const frame = decodeFrame(bytes);
      expect(frame.type).toBe(FrameType[v.frame.type]);
      expect(Number(frame.type)).toBe(v.frame.typeValue);
      expect(frame.id).toBe(v.frame.id);
      const payload = v.frame.payload;
      if ("json" in payload) {
        const head = frame.type === FrameType.ReqHead ? decodeReqHead(frame.payload) : decodeResHead(frame.payload);
        const expected = payload.json as unknown as Record<string, unknown>;
        const known = Object.fromEntries(Object.keys(head).map((key) => [key, expected[key]]));
        expect(head).toEqual(known as unknown as typeof head);
      } else if ("ackBytes" in payload) {
        expect(decodeAckPayload(frame.payload)).toBe(payload.ackBytes);
      } else {
        expect(toHex(frame.payload)).toBe(toHex(payloadBytes(frame.type, payload)));
      }
    });

    if (v.decodeOnly === true) continue;

    test(`encode ${v.name}`, () => {
      const type = FrameType[v.frame.type];
      const encoded = encodeFrame(type, v.frame.id, payloadBytes(type, v.frame.payload));
      if (v.hex !== undefined) {
        expect(toHex(encoded)).toBe(v.hex);
      } else {
        expect(toHex(encoded.subarray(0, 5))).toBe(v.headerHex ?? "");
        expect(encoded.length).toBe(v.totalLength ?? -1);
      }
    });
  }
});

describe("invalid frames", () => {
  for (const v of invalid.invalidFrames) {
    test(`${v.expect.level} ${v.name}`, () => {
      const bytes = wireBytes(v);
      if (v.expect.level === "decode") {
        const error = catchError(() => decodeFrame(bytes));
        expect(error).toBeInstanceOf(FrameError);
        expect((error as FrameError).level).toBe("decode");
        return;
      }
      const frame = decodeFrame(bytes);
      const error = catchError(() => {
        if (v.expect.level === "connection") {
          if (frame.type === FrameType.Ack) decodeAckPayload(frame.payload);
          else checkBodyChunk(frame.payload);
        } else if (frame.type === FrameType.ReqHead) {
          decodeReqHead(frame.payload);
        } else {
          decodeResHead(frame.payload);
        }
      });
      expect(error).toBeInstanceOf(FrameError);
      expect((error as FrameError).level).toBe(v.expect.level);
    });
  }
});

describe("boundaries", () => {
  test("a body chunk of exactly 1 MiB is accepted", () => {
    expect(() => checkBodyChunk(new Uint8Array(1_048_576))).not.toThrow();
  });

  test("encodeAckPayload rejects values outside uint32", () => {
    expect(() => encodeAckPayload(-1)).toThrow(FrameError);
    expect(() => encodeAckPayload(4_294_967_296)).toThrow(FrameError);
  });

  test("encodeFrame rejects an id outside uint32", () => {
    expect(() => encodeFrame(FrameType.Cancel, 4_294_967_296, new Uint8Array())).toThrow(FrameError);
  });

  test("decodeFrame accepts an ArrayBuffer", () => {
    const bytes = fromHex("0300000001");
    expect(decodeFrame(bytes.buffer as ArrayBuffer).type).toBe(FrameType.ReqEnd);
  });

  test("decodeFrame reads a subarray view at its own offset", () => {
    const frame = decodeFrame(fromHex("ff0300000001aa").subarray(1));
    expect(frame.type).toBe(FrameType.ReqEnd);
    expect(frame.id).toBe(1);
    expect(toHex(frame.payload)).toBe("aa");
  });
});
