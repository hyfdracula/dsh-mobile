/*
 * 原生 RFC 7748 X25519 密钥协商与公钥推导（基于 @kit.CryptoArchitectureKit + RFC 8410 ASN.1 DER）。
 */

import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { concat2 } from './Bytes';

// RFC 8410 SubjectPublicKeyInfo (44B total = 12B header + 32B raw key) & PKCS#8 (48B total = 16B header + 32B raw key)
const X25519_PKCS8_PREFIX: Uint8Array = new Uint8Array([
  0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06,
  0x03, 0x2b, 0x65, 0x6e, 0x04, 0x22, 0x04, 0x20
]);
const X25519_SPKI_PREFIX: Uint8Array = new Uint8Array([
  0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65,
  0x6e, 0x03, 0x21, 0x00
]);

export function clampScalar(bytes: Uint8Array): Uint8Array {
  if (bytes.length !== 32) {
    throw new Error('X25519 scalar must be 32 bytes');
  }
  const k: Uint8Array = new Uint8Array(32);
  k.set(bytes);
  k[0] &= 248;
  k[31] &= 127;
  k[31] |= 64;
  return k;
}

export function x25519(scalarBytes: Uint8Array, pointBytes: Uint8Array): Uint8Array {
  if (scalarBytes.length !== 32 || pointBytes.length !== 32) {
    throw new Error('X25519 key length must be 32 bytes');
  }
  const clamped: Uint8Array = clampScalar(scalarBytes);
  const keyGen: cryptoFramework.AsyKeyGenerator = cryptoFramework.createAsyKeyGenerator('X25519');
  const priPair: cryptoFramework.KeyPair = keyGen.convertKeySync(null, {
    data: concat2(X25519_PKCS8_PREFIX, clamped)
  });
  const pubPair: cryptoFramework.KeyPair = keyGen.convertKeySync({
    data: concat2(X25519_SPKI_PREFIX, pointBytes)
  }, null);
  clamped.fill(0);
  const agreement: cryptoFramework.KeyAgreement = cryptoFramework.createKeyAgreement('X25519');
  const shared: Uint8Array = agreement.generateSecretSync(priPair.priKey, pubPair.pubKey).data;
  let nonZero: number = 0;
  for (let i = 0; i < shared.length; i++) {
    nonZero |= shared[i];
  }
  if (shared.length !== 32 || nonZero === 0) {
    throw new Error('X25519 low-order point');
  }
  return shared;
}

export function x25519Public(secret: Uint8Array): Uint8Array {
  const basepoint: Uint8Array = new Uint8Array(32);
  basepoint[0] = 9;
  return x25519(secret, basepoint);
}
