import { timingSafeEqual } from 'node:crypto';

const TAG_LEN = 16;
const POLY_P = (1n << 130n) - 5n;
const POLY_R_MASK = 0x0ffffffc0ffffffc0ffffffc0fffffffn;
const MASK_128 = (1n << 128n) - 1n;

const CHACHA_CONST_0 = 0x61707865;
const CHACHA_CONST_1 = 0x3320646e;
const CHACHA_CONST_2 = 0x79622d32;
const CHACHA_CONST_3 = 0x6b206574;

function readU32LE(buf: Uint8Array, off: number): number {
  return (
    (buf[off]! |
      (buf[off + 1]! << 8) |
      (buf[off + 2]! << 16) |
      (buf[off + 3]! << 24)) >>>
    0
  );
}

function writeU32LE(buf: Uint8Array, off: number, val: number): void {
  buf[off] = val & 0xff;
  buf[off + 1] = (val >>> 8) & 0xff;
  buf[off + 2] = (val >>> 16) & 0xff;
  buf[off + 3] = (val >>> 24) & 0xff;
}

function rotl32(v: number, n: number): number {
  return ((v << n) | (v >>> (32 - n))) >>> 0;
}

function quarterRound(s: Uint32Array, a: number, b: number, c: number, d: number): void {
  s[a] = (s[a]! + s[b]!) >>> 0;
  s[d] = rotl32(s[d]! ^ s[a]!, 16);

  s[c] = (s[c]! + s[d]!) >>> 0;
  s[b] = rotl32(s[b]! ^ s[c]!, 12);

  s[a] = (s[a]! + s[b]!) >>> 0;
  s[d] = rotl32(s[d]! ^ s[a]!, 8);

  s[c] = (s[c]! + s[d]!) >>> 0;
  s[b] = rotl32(s[b]! ^ s[c]!, 7);
}

/** RFC 8439 Section 2.3: single 64-byte ChaCha20 block. */
export function chacha20Block(key: Uint8Array, counter: number, nonce: Uint8Array): Uint8Array {
  if (key.length !== 32) {
    throw new Error('ChaCha20 key must be 32 bytes');
  }
  if (nonce.length !== 12) {
    throw new Error('ChaCha20 nonce must be 12 bytes');
  }

  const init = new Uint32Array(16);
  init[0] = CHACHA_CONST_0;
  init[1] = CHACHA_CONST_1;
  init[2] = CHACHA_CONST_2;
  init[3] = CHACHA_CONST_3;
  for (let i = 0; i < 8; i += 1) {
    init[4 + i] = readU32LE(key, i * 4);
  }
  init[12] = counter >>> 0;
  init[13] = readU32LE(nonce, 0);
  init[14] = readU32LE(nonce, 4);
  init[15] = readU32LE(nonce, 8);

  const state = new Uint32Array(init);
  for (let round = 0; round < 10; round += 1) {
    quarterRound(state, 0, 4, 8, 12);
    quarterRound(state, 1, 5, 9, 13);
    quarterRound(state, 2, 6, 10, 14);
    quarterRound(state, 3, 7, 11, 15);
    quarterRound(state, 0, 5, 10, 15);
    quarterRound(state, 1, 6, 11, 12);
    quarterRound(state, 2, 7, 8, 13);
    quarterRound(state, 3, 4, 9, 14);
  }

  const out = new Uint8Array(64);
  for (let i = 0; i < 16; i += 1) {
    writeU32LE(out, i * 4, (state[i]! + init[i]!) >>> 0);
  }
  init.fill(0);
  state.fill(0);
  return out;
}

/** RFC 8439 Section 2.4: ChaCha20 XOR stream cipher. */
export function chacha20Xor(
  key: Uint8Array,
  initialCounter: number,
  nonce: Uint8Array,
  input: Uint8Array,
): Buffer {
  const out = Buffer.allocUnsafe(input.length);
  let counter = initialCounter >>> 0;
  let offset = 0;
  while (offset < input.length) {
    const keystream = chacha20Block(key, counter, nonce);
    const take = Math.min(64, input.length - offset);
    for (let i = 0; i < take; i += 1) {
      out[offset + i] = input[offset + i]! ^ keystream[i]!;
    }
    keystream.fill(0);
    offset += take;
    counter = (counter + 1) >>> 0;
  }
  return out;
}

function leBytesToBigInt(bytes: Uint8Array): bigint {
  let acc = 0n;
  for (let i = bytes.length - 1; i >= 0; i -= 1) {
    acc = (acc << 8n) | BigInt(bytes[i]!);
  }
  return acc;
}

/** RFC 8439 Section 2.5: Poly1305 one-time authenticator. */
export function poly1305Mac(otk: Uint8Array, msg: Uint8Array): Buffer {
  if (otk.length !== 32) {
    throw new Error('Poly1305 key must be 32 bytes');
  }
  const r = leBytesToBigInt(otk.subarray(0, 16)) & POLY_R_MASK;
  const s = leBytesToBigInt(otk.subarray(16, 32));

  let acc = 0n;
  for (let off = 0; off < msg.length; off += 16) {
    const chunk = msg.subarray(off, Math.min(off + 16, msg.length));
    const n = leBytesToBigInt(chunk) + (1n << BigInt(chunk.length * 8));
    acc = ((acc + n) * r) % POLY_P;
  }

  let finalVal = (acc + s) & MASK_128;
  const tag = Buffer.alloc(TAG_LEN);
  for (let i = 0; i < TAG_LEN; i += 1) {
    tag[i] = Number(finalVal & 0xffn);
    finalVal >>= 8n;
  }
  return tag;
}

function buildAeadMacInput(aad: Uint8Array, ciphertext: Uint8Array): Buffer {
  const aadPad = (16 - (aad.length % 16)) % 16;
  const ctPad = (16 - (ciphertext.length % 16)) % 16;
  const macData = Buffer.alloc(aad.length + aadPad + ciphertext.length + ctPad + 16);
  let pos = 0;
  if (aad.length > 0) {
    Buffer.from(aad).copy(macData, pos);
  }
  pos += aad.length + aadPad;
  if (ciphertext.length > 0) {
    Buffer.from(ciphertext).copy(macData, pos);
  }
  pos += ciphertext.length + ctPad;
  macData.writeBigUInt64LE(BigInt(aad.length), pos);
  macData.writeBigUInt64LE(BigInt(ciphertext.length), pos + 8);
  return macData;
}

/** RFC 8439 Section 2.8: AEAD_CHACHA20_POLY1305 encryption (`ciphertext || 16B tag`). */
export function chacha20Poly1305Seal(
  key: Uint8Array,
  nonce: Uint8Array,
  aad: Uint8Array,
  plaintext: Uint8Array,
): Buffer {
  if (key.length !== 32) {
    throw new Error('ChaCha20-Poly1305 key must be 32 bytes');
  }
  if (nonce.length !== 12) {
    throw new Error('ChaCha20-Poly1305 nonce must be 12 bytes');
  }
  const otkBlock = chacha20Block(key, 0, nonce);
  const otk = otkBlock.subarray(0, 32);
  try {
    const ct = chacha20Xor(key, 1, nonce, plaintext);
    const macInput = buildAeadMacInput(aad, ct);
    const tag = poly1305Mac(otk, macInput);
    macInput.fill(0);
    return Buffer.concat([ct, tag]);
  } finally {
    otkBlock.fill(0);
  }
}

/** RFC 8439 Section 2.8: AEAD_CHACHA20_POLY1305 authenticated decryption. */
export function chacha20Poly1305Open(
  key: Uint8Array,
  nonce: Uint8Array,
  aad: Uint8Array,
  ciphertextWithTag: Uint8Array,
): Buffer {
  if (key.length !== 32) {
    throw new Error('ChaCha20-Poly1305 key must be 32 bytes');
  }
  if (nonce.length !== 12) {
    throw new Error('ChaCha20-Poly1305 nonce must be 12 bytes');
  }
  if (ciphertextWithTag.byteLength < TAG_LEN) {
    throw new Error('Ciphertext too short');
  }
  const splitAt = ciphertextWithTag.byteLength - TAG_LEN;
  const ct = ciphertextWithTag.subarray(0, splitAt);
  const tag = ciphertextWithTag.subarray(splitAt);
  const otkBlock = chacha20Block(key, 0, nonce);
  const otk = otkBlock.subarray(0, 32);
  try {
    const macInput = buildAeadMacInput(aad, ct);
    const expectedTag = poly1305Mac(otk, macInput);
    macInput.fill(0);
    if (!timingSafeEqual(expectedTag, tag)) {
      throw new Error('ChaCha20-Poly1305 authentication failed');
    }
    return chacha20Xor(key, 1, nonce, ct);
  } finally {
    otkBlock.fill(0);
  }
}
