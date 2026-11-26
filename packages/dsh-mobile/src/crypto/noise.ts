/**
 * 标准 Noise Protocol Framework (Revision 34) `Noise_IK_25519_ChaChaPoly_SHA256` 实现。
 * 密码原语全部委托 Node 内置 `node:crypto`（X25519 / ChaCha20-Poly1305 / SHA-256 / HMAC），零外部依赖。
 */
import {
  createCipheriv,
  createDecipheriv,
  createHash,
  createHmac,
  createPrivateKey,
  createPublicKey,
  diffieHellman,
  generateKeyPairSync,
  getCiphers,
  timingSafeEqual,
} from 'node:crypto'
import { chacha20Poly1305Open, chacha20Poly1305Seal } from './chacha20poly1305.ts'

export const NOISE_IK_PROTOCOL = 'Noise_IK_25519_ChaChaPoly_SHA256' as const

const KEY_LEN = 32
const TAG_LEN = 16
const MAX_NONCE = 0xffffffffffffffffn
const EMPTY_BUF = Buffer.alloc(0)
const HAS_NATIVE_CHACHA = getCiphers().includes('chacha20-poly1305')

// RFC 8410 DER headers for raw 32-byte X25519 keys.
const X25519_PKCS8_PREFIX = Buffer.from('302e020100300506032b656e04220420', 'hex')
const X25519_SPKI_PREFIX = Buffer.from('302a300506032b656e032100', 'hex')

export interface X25519Keypair {
  privateKey: Buffer
  publicKey: Buffer
}

export class NoiseError extends Error {
  readonly code: string

  constructor(code: string, message: string) {
    super(message)
    this.code = code
  }
}

/** 兼容标准 Base64 与 Base64Url 解码字节序列。 */
export function decodeBase64Flexible(input: string): Buffer {
  const cleaned = input.trim().replace(/-/g, '+').replace(/_/g, '/')
  if (cleaned.length === 0) return Buffer.alloc(0)
  const pad = cleaned.length % 4
  if (pad === 1) {
    throw new NoiseError('INVALID_BASE64', 'Invalid base64 encoding')
  }
  const padded = pad === 0 ? cleaned : cleaned + '='.repeat(4 - pad)
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(padded)) {
    throw new NoiseError('INVALID_BASE64', 'Invalid base64 characters')
  }
  return Buffer.from(padded, 'base64')
}

/** 校验并拷贝 32 字节 X25519 密钥。 */
export function requireKey32(key: Uint8Array | string, label = 'key'): Buffer {
  const buf = typeof key === 'string' ? decodeBase64Flexible(key) : Buffer.from(key)
  if (buf.length !== KEY_LEN) {
    throw new NoiseError('INVALID_KEY', `${label} must be exactly 32 bytes`)
  }
  return Buffer.from(buf)
}

/** 生成 32 字节原始 X25519 密钥对。 */
export function generateX25519Keypair(): X25519Keypair {
  const { privateKey, publicKey } = generateKeyPairSync('x25519')
  const pkcs8 = privateKey.export({ type: 'pkcs8', format: 'der' })
  const spki = publicKey.export({ type: 'spki', format: 'der' })
  return {
    privateKey: Buffer.from(pkcs8.subarray(pkcs8.length - KEY_LEN)),
    publicKey: Buffer.from(spki.subarray(spki.length - KEY_LEN)),
  }
}

/** 从 32 字节 X25519 原始私钥推导 32 字节原始公钥。 */
export function x25519PublicFromPrivate(priv: Uint8Array | string): Buffer {
  const rawPriv = requireKey32(priv, 'private key')
  const privObj = createPrivateKey({
    key: Buffer.concat([X25519_PKCS8_PREFIX, rawPriv]),
    format: 'der',
    type: 'pkcs8',
  })
  const pubObj = createPublicKey(privObj)
  const spki = pubObj.export({ type: 'spki', format: 'der' })
  return Buffer.from(spki.subarray(spki.length - KEY_LEN))
}

function dh(priv: Buffer, pub: Buffer): Buffer {
  const privObj = createPrivateKey({
    key: Buffer.concat([X25519_PKCS8_PREFIX, priv]),
    format: 'der',
    type: 'pkcs8',
  })
  const pubObj = createPublicKey({
    key: Buffer.concat([X25519_SPKI_PREFIX, pub]),
    format: 'der',
    type: 'spki',
  })
  const shared = diffieHellman({ privateKey: privObj, publicKey: pubObj })
  let nonZero = 0
  for (let i = 0; i < shared.length; i += 1) {
    nonZero |= shared[i] as number
  }
  if (nonZero === 0) {
    throw new NoiseError('WEAK_DH', 'X25519 shared secret is all zeros')
  }
  return shared
}

function sha256(data: Buffer): Buffer {
  return createHash('sha256').update(data).digest()
}

function hmacSha256(key: Buffer, data: Buffer): Buffer {
  return createHmac('sha256', key).update(data).digest()
}

function hkdf2(chainingKey: Buffer, ikm: Buffer): [Buffer, Buffer] {
  const tempKey = hmacSha256(chainingKey, ikm)
  const output1 = hmacSha256(tempKey, Buffer.from([0x01]))
  const output2 = hmacSha256(tempKey, Buffer.concat([output1, Buffer.from([0x02])]))
  tempKey.fill(0)
  return [output1, output2]
}

function encodeNonce(n: bigint): Buffer {
  const nonce = Buffer.alloc(12)
  nonce.writeBigUInt64LE(n, 4)
  return nonce
}

function aeadEncrypt(key: Buffer, nonce: bigint, ad: Buffer, plaintext: Uint8Array): Buffer {
  const nonceBuf = encodeNonce(nonce)
  if (!HAS_NATIVE_CHACHA) {
    return chacha20Poly1305Seal(key, nonceBuf, ad, plaintext)
  }
  const cipher = createCipheriv('chacha20-poly1305', key, nonceBuf, { authTagLength: TAG_LEN })
  if (ad.byteLength > 0) {
    cipher.setAAD(ad, { plaintextLength: plaintext.byteLength })
  }
  const head = cipher.update(plaintext)
  const tail = cipher.final()
  const tag = cipher.getAuthTag()
  return Buffer.concat([head, tail, tag])
}

function aeadDecrypt(key: Buffer, nonce: bigint, ad: Buffer, ciphertext: Uint8Array): Buffer {
  if (ciphertext.byteLength < TAG_LEN) {
    throw new NoiseError('DECRYPT_FAILED', 'Ciphertext too short')
  }
  const nonceBuf = encodeNonce(nonce)
  if (!HAS_NATIVE_CHACHA) {
    try {
      return chacha20Poly1305Open(key, nonceBuf, ad, ciphertext)
    } catch {
      throw new NoiseError('DECRYPT_FAILED', 'ChaCha20-Poly1305 authentication failed')
    }
  }
  const ctBuf = Buffer.from(ciphertext)
  const body = ctBuf.subarray(0, ctBuf.length - TAG_LEN)
  const tag = ctBuf.subarray(ctBuf.length - TAG_LEN)
  try {
    const decipher = createDecipheriv('chacha20-poly1305', key, nonceBuf, { authTagLength: TAG_LEN })
    decipher.setAuthTag(tag)
    if (ad.byteLength > 0) {
      decipher.setAAD(ad, { plaintextLength: body.byteLength })
    }
    const head = decipher.update(body)
    const tail = decipher.final()
    return Buffer.concat([head, tail])
  } catch {
    throw new NoiseError('DECRYPT_FAILED', 'ChaCha20-Poly1305 authentication failed')
  }
}

/** Noise CipherState：维护单个方向的 32 字节对称密钥与 64 位单调递增 Nonce。 */
export class NoiseCipherState {
  private key: Buffer | null = null
  private n = 0n

  constructor(key?: Buffer) {
    if (key !== undefined) {
      this.initializeKey(key)
    }
  }

  initializeKey(key: Buffer | null): void {
    if (this.key !== null) this.key.fill(0)
    this.key = key === null ? null : Buffer.from(key)
    this.n = 0n
  }

  hasKey(): boolean {
    return this.key !== null
  }

  get nonce(): bigint {
    return this.n
  }

  encryptWithAd(ad: Buffer, plaintext: Uint8Array): Buffer {
    if (this.key === null) return Buffer.from(plaintext)
    if (this.n >= MAX_NONCE) {
      throw new NoiseError('NONCE_EXHAUSTED', 'Noise cipher nonce exhausted')
    }
    const out = aeadEncrypt(this.key, this.n, ad, plaintext)
    this.n += 1n
    return out
  }

  decryptWithAd(ad: Buffer, ciphertext: Uint8Array): Buffer {
    if (this.key === null) return Buffer.from(ciphertext)
    if (this.n >= MAX_NONCE) {
      throw new NoiseError('NONCE_EXHAUSTED', 'Noise cipher nonce exhausted')
    }
    const out = aeadDecrypt(this.key, this.n, ad, ciphertext)
    this.n += 1n
    return out
  }

  encrypt(plaintext: Uint8Array): Buffer {
    return this.encryptWithAd(EMPTY_BUF, plaintext)
  }

  decrypt(ciphertext: Uint8Array): Buffer {
    return this.decryptWithAd(EMPTY_BUF, ciphertext)
  }

  destroy(): void {
    if (this.key !== null) {
      this.key.fill(0)
      this.key = null
    }
  }
}

class SymmetricState {
  private readonly cipher = new NoiseCipherState()
  private ck: Buffer
  private h: Buffer

  constructor(protocolName: string) {
    const nameBytes = Buffer.from(protocolName, 'ascii')
    if (nameBytes.length <= KEY_LEN) {
      this.h = Buffer.alloc(KEY_LEN)
      nameBytes.copy(this.h)
    } else {
      this.h = sha256(nameBytes)
    }
    this.ck = Buffer.from(this.h)
  }

  mixKey(ikm: Buffer): void {
    const [nextCk, tempK] = hkdf2(this.ck, ikm)
    this.ck.fill(0)
    this.ck = nextCk
    this.cipher.initializeKey(tempK)
    tempK.fill(0)
  }

  mixHash(data: Uint8Array): void {
    this.h = sha256(Buffer.concat([this.h, Buffer.from(data)]))
  }

  encryptAndHash(plaintext: Uint8Array): Buffer {
    const ct = this.cipher.encryptWithAd(this.h, plaintext)
    this.mixHash(ct)
    return ct
  }

  decryptAndHash(ciphertext: Uint8Array): Buffer {
    const pt = this.cipher.decryptWithAd(this.h, ciphertext)
    this.mixHash(ciphertext)
    return pt
  }

  split(): [NoiseCipherState, NoiseCipherState] {
    const [k1, k2] = hkdf2(this.ck, EMPTY_BUF)
    this.ck.fill(0)
    this.cipher.destroy()
    const c1 = new NoiseCipherState(k1)
    const c2 = new NoiseCipherState(k2)
    k1.fill(0)
    k2.fill(0)
    return [c1, c2]
  }
}

export interface NoiseHandshakeResult {
  sendCipher: NoiseCipherState
  recvCipher: NoiseCipherState
  remoteStatic: Buffer
  payload: Buffer
}

export interface NoiseResponderAcceptResult extends NoiseHandshakeResult {
  msg2: Buffer
}

/**
 * Noise_IK 发起端（手机 / 客户端）：已知服务端静态公钥 `remoteStaticPub`。
 */
export class NoiseInitiator {
  private readonly sPriv: Buffer
  private readonly sPub: Buffer
  private readonly rsPub: Buffer
  private readonly sym: SymmetricState
  private ePriv: Buffer | null = null
  private step: 0 | 1 | 2 = 0

  constructor(options: {
    localStaticPriv: Uint8Array | string
    localStaticPub?: Uint8Array | string
    remoteStaticPub: Uint8Array | string
    prologue?: Uint8Array
  }) {
    this.sPriv = requireKey32(options.localStaticPriv, 'initiator static private key')
    this.sPub = options.localStaticPub !== undefined
      ? requireKey32(options.localStaticPub, 'initiator static public key')
      : x25519PublicFromPrivate(this.sPriv)
    this.rsPub = requireKey32(options.remoteStaticPub, 'responder static public key')
    this.sym = new SymmetricState(NOISE_IK_PROTOCOL)
    this.sym.mixHash(options.prologue ?? EMPTY_BUF)
    // Pre-message: <- s
    this.sym.mixHash(this.rsPub)
  }

  /** 生成首条握手消息 `-> e, es, s, ss`（可注入确定性临时私钥用于金标向量测试）。 */
  writeMessage1(payload: Uint8Array = EMPTY_BUF, ephemeralPriv?: Uint8Array | string): Buffer {
    if (this.step !== 0) {
      throw new NoiseError('HANDSHAKE_ORDER', 'writeMessage1 already called')
    }
    const eph = ephemeralPriv !== undefined
      ? {
          privateKey: requireKey32(ephemeralPriv, 'ephemeral private key'),
          publicKey: x25519PublicFromPrivate(ephemeralPriv),
        }
      : generateX25519Keypair()
    this.ePriv = eph.privateKey
    this.sym.mixHash(eph.publicKey)
    this.sym.mixKey(dh(this.ePriv, this.rsPub))
    const encS = this.sym.encryptAndHash(this.sPub)
    this.sym.mixKey(dh(this.sPriv, this.rsPub))
    const encPayload = this.sym.encryptAndHash(payload)
    this.step = 1
    return Buffer.concat([eph.publicKey, encS, encPayload])
  }

  /** 校验服务端响应 `<- e, ee, se` 并切入双向传输态。 */
  readMessage2(msg2: Uint8Array): NoiseHandshakeResult {
    if (this.step !== 1 || this.ePriv === null) {
      throw new NoiseError('HANDSHAKE_ORDER', 'readMessage2 called out of order')
    }
    const buf = Buffer.from(msg2)
    if (buf.length < KEY_LEN + TAG_LEN) {
      throw new NoiseError('INVALID_MESSAGE', 'Handshake message 2 too short')
    }
    const rePub = buf.subarray(0, KEY_LEN)
    this.sym.mixHash(rePub)
    this.sym.mixKey(dh(this.ePriv, rePub))
    this.sym.mixKey(dh(this.sPriv, rePub))
    const payload = this.sym.decryptAndHash(buf.subarray(KEY_LEN))
    const [sendCipher, recvCipher] = this.sym.split()
    this.ePriv.fill(0)
    this.ePriv = null
    this.step = 2
    return {
      sendCipher,
      recvCipher,
      remoteStatic: Buffer.from(this.rsPub),
      payload,
    }
  }
}

/**
 * Noise_IK 响应端（电脑端网关）：接收 `msg1`，解密校验客户端静态公钥，生成 `msg2` 并产出双向 CipherState。
 */
export class NoiseResponder {
  private readonly sPriv: Buffer
  private readonly sPub: Buffer
  private readonly prologue: Buffer

  constructor(options: {
    localStaticPriv: Uint8Array | string
    localStaticPub?: Uint8Array | string
    prologue?: Uint8Array
  }) {
    this.sPriv = requireKey32(options.localStaticPriv, 'responder static private key')
    this.sPub = options.localStaticPub !== undefined
      ? requireKey32(options.localStaticPub, 'responder static public key')
      : x25519PublicFromPrivate(this.sPriv)
    this.prologue = Buffer.from(options.prologue ?? EMPTY_BUF)
  }

  /** 接受客户端 `msg1` 并一次性完成响应 `msg2` 构造与传输态切分。 */
  accept(
    msg1: Uint8Array,
    responsePayload: Uint8Array = EMPTY_BUF,
    ephemeralPriv?: Uint8Array | string,
  ): NoiseResponderAcceptResult {
    const buf = Buffer.from(msg1)
    const minLen = KEY_LEN + KEY_LEN + TAG_LEN + TAG_LEN
    if (buf.length < minLen) {
      throw new NoiseError('INVALID_MESSAGE', 'Handshake message 1 too short')
    }
    const sym = new SymmetricState(NOISE_IK_PROTOCOL)
    sym.mixHash(this.prologue)
    // Pre-message: <- s
    sym.mixHash(this.sPub)

    // -> e, es, s, ss
    const rePub = buf.subarray(0, KEY_LEN)
    sym.mixHash(rePub)
    sym.mixKey(dh(this.sPriv, rePub))
    const rsPub = sym.decryptAndHash(buf.subarray(KEY_LEN, KEY_LEN + KEY_LEN + TAG_LEN))
    if (rsPub.length !== KEY_LEN) {
      throw new NoiseError('INVALID_KEY', 'Decrypted remote static key has invalid length')
    }
    sym.mixKey(dh(this.sPriv, rsPub))
    const payload = sym.decryptAndHash(buf.subarray(KEY_LEN + KEY_LEN + TAG_LEN))

    // <- e, ee, se
    const eph = ephemeralPriv !== undefined
      ? {
          privateKey: requireKey32(ephemeralPriv, 'ephemeral private key'),
          publicKey: x25519PublicFromPrivate(ephemeralPriv),
        }
      : generateX25519Keypair()
    sym.mixHash(eph.publicKey)
    sym.mixKey(dh(eph.privateKey, rePub))
    sym.mixKey(dh(eph.privateKey, rsPub))
    const encRespPayload = sym.encryptAndHash(responsePayload)
    eph.privateKey.fill(0)

    const [recvCipher, sendCipher] = sym.split()
    return {
      msg2: Buffer.concat([eph.publicKey, encRespPayload]),
      sendCipher,
      recvCipher,
      remoteStatic: rsPub,
      payload,
    }
  }
}

/** 常量时间比较两个 32 字节密钥是否一致。 */
export function keysEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.byteLength !== b.byteLength) return false
  return timingSafeEqual(a, b)
}
