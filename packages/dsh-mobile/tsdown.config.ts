/**
 * Standalone build config for dsh-mobile.
 *
 * Two halves from one entry: the host gateway (`lib/index.js`, ESM, node
 * externals kept intact) and the settings-dialog bundle (`lib/client.js`, the
 * loader's closure-factory artifact). `qrcode` stays external on the node half
 * — it is imported lazily and only when the panel asks for a QR, so loading the
 * plugin never pays for it.
 */
import { clientBundle } from '../../shared/tsdown.client.ts'

export default clientBundle('@deepseek-ai/dsh-mobile', ['src/index.ts'], {
  libExternal: [/^qrcode$/],
})
