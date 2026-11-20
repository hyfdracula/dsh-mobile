/**
 * dsh-mobile — browser half.
 *
 * Registers one section in the DSH settings dialog: the pairing panel a phone
 * scans. Everything it shows comes from the host half through same-origin
 * routes (`/api/dsh-mobile/panel/*`), so this bundle never holds the bearer
 * token and never talks to the phone gateway directly.
 * @module @deepseek-ai/dsh-mobile/client
 */
import { MobileSection } from './MobileSection.tsx'

/** Services this half needs: the settings dialog exposes one slot per section. */
export const inject = ['slots']

/**
 * Register the pairing section.
 * @param ctx - client root context.
 */
export function apply(ctx: any): void {
  ctx.slots.inject('settings.section', () => ctx.slots.register({
    name: 'settings.section',
    id: 'dsh-mobile',
    order: 36,
    label: () => '手机连接',
  }, MobileSection as never))
}
