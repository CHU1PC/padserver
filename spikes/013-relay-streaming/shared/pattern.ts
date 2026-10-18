const PERIOD = 1_048_573;

let doubled: Uint8Array | undefined;

function table(): Uint8Array {
  if (doubled) return doubled;
  const out = new Uint8Array(PERIOD * 2);
  let state = 0x9e3779b9;
  for (let i = 0; i < PERIOD; i++) {
    state ^= state << 13;
    state >>>= 0;
    state ^= state >>> 17;
    state ^= state << 5;
    state >>>= 0;
    out[i] = state & 0xff;
  }
  out.copyWithin(PERIOD, 0, PERIOD);
  doubled = out;
  return out;
}

export const MAX_PATTERN_SLICE = PERIOD;

// offset 番目からの length byte. 同じ offset なら, どの process でも同じ byte 列になる
export function patternSlice(offset: number, length: number): Uint8Array {
  if (length > PERIOD) throw new Error("slice too long");
  const start = offset % PERIOD;
  return table().subarray(start, start + length);
}
