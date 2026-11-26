/**
 * Pick arbitrary files from the system file picker and turn them into the
 * base64 payload the dsh-mobile `/files` route expects.
 *
 * The document picker is a system UI: it grants read access to exactly the
 * files the user taps, so no storage permission is declared in `module.json5`.
 *
 * Note the asymmetry with images: an image goes into the prompt as a content
 * part, whereas a file cannot -- the model only ever reads bytes that live on
 * the machine running DSH. So the server writes these to
 * `~/.dsh/mobile-uploads/<day>/` and the message carries the resulting paths.
 */

import { picker } from '@kit.CoreFileKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

/** One picked file, already base64-encoded, ready for `POST …/files`. */
export interface FilePart {
  name: string;
  data: string;
}

/** Largest single file we push through; the server caps the batch too. */
const MAX_FILE_BYTES: number = 8 * 1024 * 1024;

/** Last path segment, used as the saved file name. */
function nameOf(uri: string): string {
  const cut: number = uri.lastIndexOf('/');
  let tail: string = cut >= 0 ? uri.slice(cut + 1) : uri;
  try {
    tail = decodeURIComponent(tail);
  } catch (e) {
  }
  return tail.length > 100 ? tail.slice(tail.length - 100) : tail;
}

/** Open the system file picker; returns the uris the user selected. */
export async function pickFiles(limit: number): Promise<string[]> {
  const options = new picker.DocumentSelectOptions();
  options.maxSelectNumber = limit;
  const viewPicker = new picker.DocumentViewPicker();
  const uris: string[] = await viewPicker.select(options);
  return uris === undefined || uris === null ? [] : uris;
}

/** Read one picked uri into a `FilePart`; `undefined` when it is empty or too large. */
export async function readFile(uri: string): Promise<FilePart | undefined> {
  const file: fileIo.File = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
  try {
    const st: fileIo.Stat = await fileIo.stat(file.fd);
    if (st.size <= 0 || st.size > MAX_FILE_BYTES) {
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
    return { name: nameOf(uri), data: data };
  } finally {
    try {
      await fileIo.close(file);
    } catch (e) {
    }
  }
}
