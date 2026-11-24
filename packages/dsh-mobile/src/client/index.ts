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
import { FeedbackSection } from './FeedbackSection.tsx'

/** Services this half needs: the settings dialog exposes one slot per section. */
export const inject = ['slots']

/** Where the ticket console lives on the host half. */
const FEEDBACK_STATE = 'api/dsh-mobile/panel/feedback/state'

/**
 * Register the pairing section, and the ticket console when this machine holds
 * an admin key. The second section is registered only after the host says
 * `configured: true`, so a plain install of this plugin shows no console and no
 * other machine's tickets.
 * @param ctx - client root context.
 */
export function apply(ctx: any): void {
  ctx.slots.inject('settings.section', () => ctx.slots.register({
    name: 'settings.section',
    id: 'dsh-mobile',
    order: 36,
    label: () => '手机连接',
  }, MobileSection as never))

  const registerFeedback = (): void => {
    ctx.slots.inject('settings.section', () => ctx.slots.register({
      name: 'settings.section',
      id: 'dsh-mobile-feedback',
      order: 37,
      label: () => '用户反馈',
    }, FeedbackSection as never))
  }

  void fetch(FEEDBACK_STATE, { cache: 'no-store' })
    .then(async (res) => (await res.json()) as { configured?: boolean })
    .then((state) => {
      if (state.configured === true) registerFeedback()
    })
    .catch(() => undefined)
}
