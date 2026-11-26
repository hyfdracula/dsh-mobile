/*
 * 原生 ArkTS 字节序列、UTF-8、Base64/Base64Url、CSPRNG 与 RFC 9562 UUIDv7 工具，
 * 全部基于 @kit.ArkTS 与 @kit.CryptoArchitectureKit 实现。
 */

import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

const UTF8_ENCODER: util.TextEncoder = util.TextEncoder.create('utf-8');
const UTF8_DECODER: util.TextDecoder = util.TextDecoder.create('utf-8');
const BASE64_HELPER: util.Base64Helper = new util.Base64Helper();

export function utf8Encode(input: string): Uint8Array {
  if (input.length === 0) {
    return new Uint8Array(0);
  }
  const encoded: Uint8Array | undefined = UTF8_ENCODER.encodeInto(input);
  return encoded !== undefined ? encoded : new Uint8Array(0);
}

export function utf8Decode(bytes: Uint8Array): string {
  if (bytes.length === 0) {
    return '';
  }
  return UTF8_DECODER.decodeToString(bytes);
}

export function toBase64Url(bytes: Uint8Array): string {
  if (bytes.length === 0) {
    return '';
  }
  const encoded: string = BASE64_HELPER.encodeToStringSync(bytes, util.Type.BASIC_URL_SAFE);
  return encoded.replace(/=+$/, '');
}

export function toBase64(bytes: Uint8Array): string {
  if (bytes.length === 0) {
    return '';
  }
  return BASE64_HELPER.encodeToStringSync(bytes, util.Type.BASIC);
}

export function fromBase64Url(value: string): Uint8Array {
  const std: string = value.trim().replace(/-/g, '+').replace(/_/g, '/').replace(/=+$/, '');
  if (std.length === 0) {
    return new Uint8Array(0);
  }
  const rem: number = std.length % 4;
  if (rem === 1) {
    throw new Error('invalid base64url length');
  }
  const padded: string = rem === 0 ? std : std + (rem === 2 ? '==' : '=');
  return BASE64_HELPER.decodeSync(padded, util.Type.BASIC);
}

/** 兼容标准 Base64 与 Base64Url 解码。 */
export function fromBase64Flexible(value: string): Uint8Array {
  return fromBase64Url(value);
}

export function randomBytes(n: number): Uint8Array {
  if (n <= 0) {
    return new Uint8Array(0);
  }
  const rand: cryptoFramework.Random = cryptoFramework.createRandom();
  return rand.generateRandomSync(n).data;
}

export function randomUuid(): string {
  const b: Uint8Array = randomBytes(16);
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  return formatUuidBytes(b);
}

export function uuidV7(): string {
  const b: Uint8Array = randomBytes(16);
  const ts: number = Date.now();
  b[0] = Math.floor(ts / 1099511627776) & 0xff;
  b[1] = Math.floor(ts / 4294967296) & 0xff;
  b[2] = Math.floor(ts / 16777216) & 0xff;
  b[3] = Math.floor(ts / 65536) & 0xff;
  b[4] = Math.floor(ts / 256) & 0xff;
  b[5] = ts & 0xff;
  b[6] = (b[6] & 0x0f) | 0x70;
  b[8] = (b[8] & 0x3f) | 0x80;
  return formatUuidBytes(b);
}

export function randomId(): string {
  return uuidV7();
}

function formatUuidBytes(b: Uint8Array): string {
  const hex: string = bytesToHex(b);
  return hex.substring(0, 8) + '-' + hex.substring(8, 12) + '-' + hex.substring(12, 16) +
    '-' + hex.substring(16, 20) + '-' + hex.substring(20, 32);
}

export function constantTimeEqual(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) {
    return false;
  }
  let diff: number = 0;
  for (let i = 0; i < left.length; i++) {
    diff |= left[i] ^ right[i];
  }
  return diff === 0;
}

export function copyOf(bytes: Uint8Array): Uint8Array {
  const out: Uint8Array = new Uint8Array(bytes.length);
  out.set(bytes);
  return out;
}

export function concat2(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out: Uint8Array = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}

export function concat3(a: Uint8Array, b: Uint8Array, c: Uint8Array): Uint8Array {
  const out: Uint8Array = new Uint8Array(a.length + b.length + c.length);
  out.set(a, 0);
  out.set(b, a.length);
  out.set(c, a.length + b.length);
  return out;
}

export function bytesToHex(bytes: Uint8Array): string {
  let out: string = '';
  for (let i = 0; i < bytes.length; i++) {
    const v: number = bytes[i];
    out += (v >> 4).toString(16);
    out += (v & 0x0f).toString(16);
  }
  return out;
}
