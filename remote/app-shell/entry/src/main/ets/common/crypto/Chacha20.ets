/*
 * 原生 RFC 8439 ChaCha20-Poly1305 AEAD 加解密（基于 @kit.CryptoArchitectureKit）。
 */

import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { concat2 } from './Bytes';

const TAG_LEN: number = 16;

function makeSymKey(key: Uint8Array): cryptoFramework.SymKey {
  if (key.length !== 32) {
    throw new Error('ChaCha20-Poly1305 key must be 32 bytes');
  }
  const gen: cryptoFramework.SymKeyGenerator = cryptoFramework.createSymKeyGenerator('ChaCha20');
  return gen.convertKeySync({ data: key });
}

function makeAeadSpec(nonce: Uint8Array, aad: Uint8Array): cryptoFramework.AeadParamsSpec {
  const spec: cryptoFramework.AeadParamsSpec = {
    algName: 'AeadParamsSpec',
    nonce: nonce,
    tagLen: TAG_LEN
  };
  if (aad.length > 0) {
    spec.authenticatedData = aad;
  }
  return spec;
}

export function chacha20poly1305Seal(key: Uint8Array, nonce: Uint8Array, aad: Uint8Array,
  plaintext: Uint8Array): Uint8Array {
  if (nonce.length !== 12) {
    throw new Error('ChaCha20-Poly1305 nonce must be 12 bytes');
  }
  const symKey: cryptoFramework.SymKey = makeSymKey(key);
  try {
    const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher('ChaCha20|Poly1305');
    cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, makeAeadSpec(nonce, aad));
    const blob: cryptoFramework.DataBlob | null = plaintext.length > 0
      ? cipher.doFinalSync({ data: plaintext })
      : cipher.doFinalSync(null);
    return blob !== null && blob !== undefined && blob.data !== undefined ? blob.data : new Uint8Array(0);
  } catch (primaryErr) {
    // 兼容需要显式 Poly1305ParamsSpec 的系统路径
    const cipher2: cryptoFramework.Cipher = cryptoFramework.createCipher('ChaCha20|Poly1305');
    const polySpec: cryptoFramework.Poly1305ParamsSpec = {
      algName: 'Poly1305ParamsSpec',
      iv: { data: nonce },
      aad: { data: aad },
      authTag: { data: new Uint8Array(TAG_LEN) }
    };
    cipher2.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, polySpec);
    const out: cryptoFramework.DataBlob | null = plaintext.length > 0
      ? cipher2.doFinalSync({ data: plaintext })
      : cipher2.doFinalSync(null);
    return out !== null && out !== undefined && out.data !== undefined ? out.data : new Uint8Array(0);
  }
}

export function chacha20poly1305Open(key: Uint8Array, nonce: Uint8Array, aad: Uint8Array,
  ciphertextWithTag: Uint8Array): Uint8Array {
  if (nonce.length !== 12) {
    throw new Error('ChaCha20-Poly1305 nonce must be 12 bytes');
  }
  if (ciphertextWithTag.length < TAG_LEN) {
    throw new Error('ChaChaPoly: too short');
  }
  const symKey: cryptoFramework.SymKey = makeSymKey(key);
  try {
    const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher('ChaCha20|Poly1305');
    cipher.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, makeAeadSpec(nonce, aad));
    const blob: cryptoFramework.DataBlob | null = cipher.doFinalSync({ data: ciphertextWithTag });
    return blob !== null && blob !== undefined && blob.data !== undefined ? blob.data : new Uint8Array(0);
  } catch (primaryErr) {
    const splitAt: number = ciphertextWithTag.length - TAG_LEN;
    const body: Uint8Array = ciphertextWithTag.subarray(0, splitAt);
    const tag: Uint8Array = ciphertextWithTag.subarray(splitAt);
    const cipher2: cryptoFramework.Cipher = cryptoFramework.createCipher('ChaCha20|Poly1305');
    const polySpec: cryptoFramework.Poly1305ParamsSpec = {
      algName: 'Poly1305ParamsSpec',
      iv: { data: nonce },
      aad: { data: aad },
      authTag: { data: tag }
    };
    cipher2.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, polySpec);
    const out: cryptoFramework.DataBlob | null = body.length > 0
      ? cipher2.doFinalSync({ data: body })
      : cipher2.doFinalSync(null);
    if (out === null || out === undefined || out.data === undefined) {
      return new Uint8Array(0);
    }
    return out.data;
  }
}

export function sealWithConcatFallback(key: Uint8Array, nonce: Uint8Array, aad: Uint8Array,
  ct: Uint8Array, tag: Uint8Array): Uint8Array {
  return concat2(ct, tag);
}
