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
  const tail: string = cut >= 0 ? uri.slice(cut + 1) : uri;
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
export function readFile(uri: string): FilePart | undefined {
  const file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
  try {
    const st = fileIo.statSync(file.fd);
    if (st.size <= 0 || st.size > MAX_FILE_BYTES) {
      return undefined;
    }
    const buf = new ArrayBuffer(st.size);
    const read = fileIo.readSync(file.fd, buf);
    if (read <= 0) {
      return undefined;
    }
    const bytes = new Uint8Array(buf.slice(0, read));
    const data: string = new util.Base64Helper().encodeToStringSync(bytes);
    return { name: nameOf(uri), data: data };
  } finally {
    fileIo.closeSync(file);
  }
}
