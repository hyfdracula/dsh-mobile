/*
 * 原生 SHA-256、HMAC-SHA256 与 Noise HKDF-2 派生（基于 @kit.CryptoArchitectureKit）。
 */

import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { concat2 } from './Bytes';

export function sha256(data: Uint8Array): Uint8Array {
  const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
  if (data.length > 0) {
    md.updateSync({ data: data });
  }
  return md.digestSync().data;
}

export function sha256Concat(a: Uint8Array, b: Uint8Array): Uint8Array {
  return sha256(concat2(a, b));
}

export function hmacSha256(key: Uint8Array, data: Uint8Array): Uint8Array {
  const normalizedKey: Uint8Array = key.length > 0 ? key : new Uint8Array(1);
  const symGen: cryptoFramework.SymKeyGenerator = cryptoFramework.createSymKeyGenerator('HMAC');
  const symKey: cryptoFramework.SymKey = symGen.convertKeySync({ data: normalizedKey });
  const mac: cryptoFramework.Mac = cryptoFramework.createMac('SHA256');
  mac.initSync(symKey);
  if (data.length > 0) {
    mac.updateSync({ data: data });
  }
  return mac.doFinalSync().data;
}

export class HkdfResult {
  o1: Uint8Array;
  o2: Uint8Array;

  constructor(o1: Uint8Array, o2: Uint8Array) {
    this.o1 = o1;
    this.o2 = o2;
  }
}

export function hkdf2(ck: Uint8Array, ikm: Uint8Array): HkdfResult {
  const tempKey: Uint8Array = hmacSha256(ck, ikm);
  const one: Uint8Array = new Uint8Array([0x01]);
  const out1: Uint8Array = hmacSha256(tempKey, one);
  const two: Uint8Array = new Uint8Array([0x02]);
  const out2: Uint8Array = hmacSha256(tempKey, concat2(out1, two));
  tempKey.fill(0);
  return new HkdfResult(out1, out2);
}
