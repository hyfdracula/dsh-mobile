/*
 * 标准 Noise Protocol Framework (Revision 34, CC0 Public Domain)
 * Noise_IK_25519_ChaChaPoly_SHA256 发起端状态机（基于原生 CryptoArchitectureKit 原语）。
 */

import { copyOf, utf8Encode } from './Bytes';
import { chacha20poly1305Open, chacha20poly1305Seal } from './Chacha20';
import { hkdf2, HkdfResult, sha256, sha256Concat } from './Sha256';
import { x25519, x25519Public } from './X25519';

const PROTOCOL_NAME: string = 'Noise_IK_25519_ChaChaPoly_SHA256';
const KEY_BYTES: number = 32;
const TAG_BYTES: number = 16;
const MAX_COUNTER: bigint = 0xffffffffffffffffn;

export class CipherState {
  private symKey: Uint8Array;
  private nonceVal: bigint = 0n;

  constructor(key: Uint8Array) {
    this.symKey = copyOf(key);
  }

  private buildNonce(): Uint8Array {
    const buf: Uint8Array = new Uint8Array(12);
    new DataView(buf.buffer).setBigUint64(4, this.nonceVal, true);
    return buf;
  }

  counter(): bigint {
    return this.nonceVal;
  }

  encrypt(ad: Uint8Array, plaintext: Uint8Array): Uint8Array {
    if (this.nonceVal >= MAX_COUNTER) {
      throw new Error('Noise nonce exhausted');
    }
    const sealed: Uint8Array = chacha20poly1305Seal(this.symKey, this.buildNonce(), ad, plaintext);
    this.nonceVal += 1n;
    return sealed;
  }

  decrypt(ad: Uint8Array, ciphertext: Uint8Array): Uint8Array {
    if (this.nonceVal >= MAX_COUNTER) {
      throw new Error('Noise nonce exhausted');
    }
    const opened: Uint8Array = chacha20poly1305Open(this.symKey, this.buildNonce(), ad, ciphertext);
    this.nonceVal += 1n;
    return opened;
  }

  destroy(): void {
    this.symKey.fill(0);
  }
}

function initialDigest(name: string): Uint8Array {
  const raw: Uint8Array = utf8Encode(name);
  if (raw.length <= KEY_BYTES) {
    const out: Uint8Array = new Uint8Array(KEY_BYTES);
    out.set(raw, 0);
    return out;
  }
  return sha256(raw);
}

export class NoiseIkInitiator {
  private readonly randFn: (n: number) => Uint8Array;
  private hashAcc: Uint8Array;
  private chainKey: Uint8Array;
  private handCipher: CipherState | undefined = undefined;
  private readonly remoteStatic: Uint8Array;
  private readonly staticPriv: Uint8Array;
  private readonly staticPub: Uint8Array;
  private ephPriv: Uint8Array | undefined = undefined;
  private txCipher: CipherState | undefined = undefined;
  private rxCipher: CipherState | undefined = undefined;

  constructor(
    localPrivate: Uint8Array,
    localPublic: Uint8Array,
    remotePublic: Uint8Array,
    prologue: Uint8Array,
    random: (n: number) => Uint8Array
  ) {
    this.randFn = random;
    this.hashAcc = initialDigest(PROTOCOL_NAME);
    this.chainKey = copyOf(this.hashAcc);
    this.remoteStatic = copyOf(remotePublic);
    this.staticPriv = copyOf(localPrivate);
    this.staticPub = copyOf(localPublic);
    this.mixHash(prologue);
    // IK pre-message pattern: <- s
    this.mixHash(this.remoteStatic);
  }

  private mixHash(data: Uint8Array): void {
    this.hashAcc = sha256Concat(this.hashAcc, data);
  }

  private mixKey(ikm: Uint8Array): void {
    const pair: HkdfResult = hkdf2(this.chainKey, ikm);
    this.chainKey.fill(0);
    this.chainKey = pair.o1;
    if (this.handCipher !== undefined) {
      this.handCipher.destroy();
    }
    this.handCipher = new CipherState(pair.o2);
    pair.o2.fill(0);
  }

  private encryptAndHash(plaintext: Uint8Array): Uint8Array {
    const ct: Uint8Array = this.handCipher !== undefined
      ? this.handCipher.encrypt(this.hashAcc, plaintext)
      : copyOf(plaintext);
    this.mixHash(ct);
    return ct;
  }

  private decryptAndHash(ciphertext: Uint8Array): Uint8Array {
    const pt: Uint8Array = this.handCipher !== undefined
      ? this.handCipher.decrypt(this.hashAcc, ciphertext)
      : copyOf(ciphertext);
    this.mixHash(ciphertext);
    return pt;
  }

  writeHandshake(payload: Uint8Array): Uint8Array {
    if (this.ephPriv !== undefined) {
      throw new Error('handshake already written');
    }
    const ePriv: Uint8Array = this.randFn(KEY_BYTES);
    this.ephPriv = ePriv;
    const ePub: Uint8Array = x25519Public(ePriv);
    // -> e, es, s, ss
    this.mixHash(ePub);
    this.mixKey(x25519(ePriv, this.remoteStatic));
    const encStatic: Uint8Array = this.encryptAndHash(this.staticPub);
    this.mixKey(x25519(this.staticPriv, this.remoteStatic));
    const encPayload: Uint8Array = this.encryptAndHash(payload);

    const frame: Uint8Array = new Uint8Array(KEY_BYTES + encStatic.length + encPayload.length);
    frame.set(ePub, 0);
    frame.set(encStatic, KEY_BYTES);
    frame.set(encPayload, KEY_BYTES + encStatic.length);
    return frame;
  }

  readHandshake(message: Uint8Array): Uint8Array {
    if (message.length < KEY_BYTES + TAG_BYTES) {
      throw new Error('handshake message too short');
    }
    if (this.ephPriv === undefined) {
      throw new Error('handshake not started');
    }
    const ePriv: Uint8Array = this.ephPriv;
    const rePub: Uint8Array = message.subarray(0, KEY_BYTES);
    // <- e, ee, se
    this.mixHash(rePub);
    this.mixKey(x25519(ePriv, rePub));
    this.mixKey(x25519(this.staticPriv, rePub));
    const payload: Uint8Array = this.decryptAndHash(message.subarray(KEY_BYTES));

    const splitPair: HkdfResult = hkdf2(this.chainKey, new Uint8Array(0));
    this.txCipher = new CipherState(splitPair.o1);
    this.rxCipher = new CipherState(splitPair.o2);
    splitPair.o1.fill(0);
    splitPair.o2.fill(0);
    this.chainKey.fill(0);
    if (this.handCipher !== undefined) {
      this.handCipher.destroy();
      this.handCipher = undefined;
    }
    ePriv.fill(0);
    this.ephPriv = undefined;
    return payload;
  }

  isComplete(): boolean {
    return this.txCipher !== undefined && this.rxCipher !== undefined;
  }

  sendingCounter(): bigint {
    return this.txCipher !== undefined ? this.txCipher.counter() : 0n;
  }

  receivingCounter(): bigint {
    return this.rxCipher !== undefined ? this.rxCipher.counter() : 0n;
  }

  encrypt(plaintext: Uint8Array): Uint8Array {
    if (this.txCipher === undefined) {
      throw new Error('noise handshake not complete');
    }
    return this.txCipher.encrypt(new Uint8Array(0), plaintext);
  }

  decrypt(ciphertext: Uint8Array): Uint8Array {
    if (this.rxCipher === undefined) {
      throw new Error('noise handshake not complete');
    }
    return this.rxCipher.decrypt(new Uint8Array(0), ciphertext);
  }

  destroy(): void {
    this.staticPriv.fill(0);
    this.chainKey.fill(0);
    if (this.handCipher !== undefined) {
      this.handCipher.destroy();
      this.handCipher = undefined;
    }
    if (this.ephPriv !== undefined) {
      this.ephPriv.fill(0);
      this.ephPriv = undefined;
    }
    if (this.txCipher !== undefined) {
      this.txCipher.destroy();
      this.txCipher = undefined;
    }
    if (this.rxCipher !== undefined) {
      this.rxCipher.destroy();
      this.rxCipher = undefined;
    }
  }
}
