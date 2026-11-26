/**
 * Pick images from the system gallery and turn them into the base64 payload the
 * dsh-mobile `/images` route expects.
 *
 * The photo picker is a system UI: it grants read access to exactly the files
 * the user taps, so no media permission is declared in `module.json5`.
 */

import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

/** One image part, already base64-encoded, ready for `POST …/images`. */
export interface ImagePart {
  mediaType: string;
  data: string;
  name: string;
}

/** Largest single image we allow through; the server caps the batch too. */
const MAX_IMAGE_BYTES: number = 12 * 1024 * 1024;

/** Map a file extension onto one of the media types the server accepts. */
function mediaTypeOf(uri: string): string {
  const lower: string = uri.toLowerCase();
  if (lower.endsWith('.png')) {
    return 'image/png';
  }
  if (lower.endsWith('.webp')) {
    return 'image/webp';
  }
  if (lower.endsWith('.gif')) {
    return 'image/gif';
  }
  return 'image/jpeg';
}

/** Last path segment, used only as a display name. */
function nameOf(uri: string): string {
  const cut: number = uri.lastIndexOf('/');
  let tail: string = cut >= 0 ? uri.slice(cut + 1) : uri;
  try {
    tail = decodeURIComponent(tail);
  } catch (e) {
  }
  return tail.length > 80 ? tail.slice(tail.length - 80) : tail;
}

/** Read one picked uri into an `ImagePart`; `undefined` when it is too large. */
async function readOne(uri: string): Promise<ImagePart | undefined> {
  const file: fileIo.File = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
  try {
    const st: fileIo.Stat = await fileIo.stat(file.fd);
    if (st.size <= 0 || st.size > MAX_IMAGE_BYTES) {
      return undefined;
    }
    const buf: ArrayBuffer = new ArrayBuffer(st.size);
    let offset: number = 0;
    while (offset < st.size) {
      const n: number = await fileIo.read(file.fd, buf, { offset: offset, length: st.size - offset });
      if (n <= 0) {
        break;
      }
      offset += n;
    }
    if (offset <= 0) {
      return undefined;
    }
    const bytes: Uint8Array = new Uint8Array(buf, 0, offset);
    const data: string = new util.Base64Helper().encodeToStringSync(bytes);
    return { mediaType: mediaTypeOf(uri), data: data, name: nameOf(uri) };
  } finally {
    try {
      await fileIo.close(file);
    } catch (e) {
    }
  }
}

/**
 * Open the gallery picker and return the chosen images.
 * @returns the encoded parts; an empty array when the user cancels.
 */
export async function pickImages(limit: number): Promise<ImagePart[]> {
  const picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
  const opt: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
  opt.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
  opt.maxSelectNumber = limit;
  const picked: photoAccessHelper.PhotoSelectResult = await picker.select(opt);
  const out: ImagePart[] = [];
  for (const uri of picked.photoUris) {
    const part = await readOne(uri);
    if (part !== undefined) {
      out.push(part);
    }
  }
  return out;
}

/** Turn already-granted uris (e.g. from the camera picker) into image parts. */
export async function fromUris(uris: string[]): Promise<ImagePart[]> {
  const out: ImagePart[] = [];
  for (const uri of uris) {
    const part = await readOne(uri);
    if (part !== undefined) {
      out.push(part);
    }
  }
  return out;
}
