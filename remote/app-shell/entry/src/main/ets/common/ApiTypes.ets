/**
 * Api 的请求/响应与领域类型。
 *
 * 从 Api.ets 拆出来：实现与类型分开，Api 只留方法；消费者仍从 Api 重新导出拿到同一批名字。
 */
import { ImagePart } from './Images';
import { FilePart } from './Files';

/** 会话行（对应 GET /api/sessions 的 sessions[]） */
export interface SessionRow {
  id: string;
  title: string;
  updatedAt: number;
  cwd: string;
  running: boolean;
  /** 宿主有挂起的提问/审批：会话卡片标黄「等你回答」。 */
  asking?: boolean;
  archived?: boolean;
  pinned?: boolean;
  agents?: AgentSummary;
  model?: ModelRef;
  context?: ContextUsage | null;
}

export interface TokenUsage {
  uncachedInputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
}

export interface SessionStats {
  turns: number;
  steps: number;
  toolCalls: number;
  tokens: TokenUsage;
}

/** 消息里的一张图片：只带摘要，字节由 /api/attachments 单独取 */
export interface ImageRef {
  id: string;
  mediaType: string;
  width: number;
  height: number;
  name: string;
}

/** 一轮的结局，挂在那一轮最后一条回复上（宿主 turn/end 的 reason）。 */
export interface GoalView {
  id?: string;
  objective?: string;
  phase?: string;
  revision?: number;
  roundsStarted?: number;
  maxGoalRounds?: number;
  activation?: string;
}

export interface GoalResp {
  ok?: boolean;
  sessionId?: string;
  goal?: GoalView | null;
}

export interface TurnInfo {
  status: string;
  ms: number;
  tokensIn: number;
  tokensOut: number;
  atSeq: number;
  finishedAt?: number;
}

export interface Message {
  role: string;
  text: string;
  time: number;
  seq: number;
  images?: ImageRef[];
  turn?: TurnInfo;
}

/** 上下文占用：宿主 token-meter 投影（used 为下一次请求的 prompt 估算，window 为路由容量）。 */
export interface ContextUsage {
  used: number;
  window: number;
}

/** 电脑端待发送队列里的一条（真正躺在 DSH 宿主里的，不是手机上假排的） */
export interface QueueTextBody {
  text: string;
}

/** 宿主队列里一条消息内的图片（只有元信息，字节走 /queue-image）。 */
export interface QueueImage {
  mediaType: string;
  name?: string;
}

export interface QueuedItem {
  id: string;
  text: string;
  at: number;
  index: number;
  images?: QueueImage[];
}

export interface AskOption {
  label: string;
  description?: string;
}

export interface AskQuestion {
  id: string;
  prompt?: string;
  header?: string;
  detail?: string;
  options?: AskOption[];
  multiSelect?: boolean;
}

export interface PendingAsk {
  callId: string;
  questions: AskQuestion[];
  state: string;
  /** 题卡编号由手机网关合成（宿主这次提问没有带 callId），回答时原样回传即可。 */
  synthetic?: boolean;
}

export interface AskAnswer {
  id: string;
  selected: string[];
  custom?: string;
}

export interface AnswerBody {
  callId: string;
  answers: AskAnswer[];
}

export interface AskState {
  active: PendingAsk[];
  settled: Object[];
}

/** 最后一轮失败的原因（插件从会话日志的 turn/end 里抠出来的）。 */
export interface TurnErr {
  code: string;
  text: string;
  time: number;
}

export interface MessagesResult {
  total: number;
  messages: Message[];
  context?: ContextUsage | null;
  stats?: SessionStats;
  firstSeq?: number;
  running?: boolean;
  /** 最后一轮的结束原因（completed / aborted / interrupted / error …） */
  lastTurn?: string;
  /** 最后一轮失败时的原始报错，手机端要在消息流里显示完整 body */
  lastErr?: TurnErr | null;
  queue?: QueuedItem[];
  questions?: AskState;
}

export interface ModelRef {
  provider: string;
  model: string;
  reasoningEffort?: string;
}

export interface AgentRef {
  id: string;
  label: string;
  mode: string;
  createdAt: number;
}

/** 会话携带的智能体概况（子智能体 + 团队任务数） */
export interface AgentSummary {
  enabled: number;
  tasks: number;
  subagents: AgentRef[];
}

export interface ApiInfo {
  ok: boolean;
  version: string;
  host: string;
  port: number;
}

export interface SessionsResp {
  ok: boolean;
  sessions: SessionRow[];
}

export interface PreviewRow {
  id: string;
  preview: string;
  count: number;
}

export interface PreviewsResp {
  ok: boolean;
  previews: PreviewRow[];
}

export interface MessagesResp {
  ok: boolean;
  sessionId: string;
  total: number;
  messages: Message[];
  stats?: SessionStats;
  context?: ContextUsage | null;
  running?: boolean;
  firstSeq?: number;
  lastTurn?: string;
  lastErr?: TurnErr;
  queue?: QueuedItem[];
  questions?: AskState;
}

export interface PresenceBody {
  online: boolean;
}

export interface PresenceResp {
  ok?: boolean;
  online?: boolean;
  ttlMs?: number;
}

export interface InfoResp {
  ok: boolean;
  version: string;
  host: string;
  port: number;
  addresses?: string[];
}

export interface RawResult {
  code: number;
  text: string;
}

/** 服务端出错时回的那一小段 JSON，只需要 error。 */
export interface QueueOrderBody {
  ids: string[];
}

export interface QueueOrderResp {
  ok?: boolean;
  moved?: number;
}

export interface ErrBody {
  error?: string;
}

export interface FsWriteBody {
  path: string;
  to: string;
}

export interface FsDeleteBody {
  path: string;
}

export interface RawSignBody {
  path: string;
}

export interface RawSignResp {
  e?: string;
  sig?: string;
}

export interface SignBody {
  ids: string[];
}

export interface SignItem {
  id: string;
  e: string;
  sig: string;
}

export interface SignResp {
  items?: SignItem[];
}

export interface ForkBody {
  atSeq?: number;
}

export interface ForkResp {
  ok?: boolean;
  sessionId?: string;
}

export interface FilesBody {
  text: string;
  files: FilePart[];
  mode?: string;
}

export interface FilesResp {
  ok: boolean;
  count: number;
  bytes: number;
}

export interface OutboxBody {
  text: string;
  images: ImagePart[];
  files: FilePart[];
  mode?: string;
}

export interface OutboxResp {
  ok: boolean;
  parts: number;
  queued?: boolean;
}

export interface ImagesBody {
  text: string;
  images: ImagePart[];
  mode?: string;
}

export interface ImagesResp {
  ok: boolean;
  count: number;
  bytes: number;
}

export interface StopResp {
  ok: boolean;
  accepted: boolean;
}

export interface CreateBody {
  cwd: string;
}

export interface CreateResp {
  ok: boolean;
  sessionId?: string;
}

export interface RenameBody {
  title: string;
}

export interface ModelBody {
  provider: string;
  model: string;
  reasoningEffort?: string;
}

export interface EffortRef {
  id: string;
  name: string;
}

export interface CatalogModel {
  id: string;
  name: string;
  description: string;
  efforts: EffortRef[];
  defaultEffort: string;
}

export interface CatalogGroup {
  id: string;
  name: string;
  models: CatalogModel[];
}

export interface Catalog {
  current: ModelRef | null;
  routable: boolean;
  groups: CatalogGroup[];
}

export interface ModelsResp {
  ok: boolean;
  sessionId: string;
  catalog: Catalog;
}

export interface PresetRow {
  id: string;
  name: string;
  description: string;
  isDefault: boolean;
  broken: string;
}

export interface PermRow {
  value: string;
  name: string;
  description: string;
}

export interface PresetsResp {
  ok: boolean;
  presets: PresetRow[];
  current: string;
  unavailable: boolean;
}

export interface PermsResp {
  ok: boolean;
  presets: PermRow[];
  current: string;
  defaultPreset: string;
  unavailable: boolean;
}

export interface PresetBody {
  presetId: string;
}

export interface PresetResp {
  ok: boolean;
  selected?: string;
  scope?: string;
}

export interface PermBody {
  permission: string;
}

export interface PermResp {
  ok: boolean;
  preset?: string;
  current?: string;
}

export interface ArchiveResp {
  ok: boolean;
  sessionId?: string;
  archived?: boolean;
  cancelledFirst?: boolean;
  via?: string;
}

export interface PinBody {
  pinned: boolean;
}

export interface PinResp {
  ok: boolean;
  sessionId?: string;
  pinned?: boolean;
  via?: string;
}

export interface SendBody {
  text: string;
  mode?: string;
}

export interface HostPluginRow {
  name: string;
  version: string;
  enabled: boolean;
  local: boolean;
}

export interface HostPluginGroup {
  profile: string;
  items: HostPluginRow[];
}

export interface HostPluginsResp {
  ok?: boolean;
  groups?: HostPluginGroup[];
}

export interface HostTaskRow {
  id: string;
  title: string;
  kind: string;
  when: string;
  active: boolean;
  sessionId: string;
}

export interface HostSchedulesResp {
  ok?: boolean;
  source?: string;
  items?: HostTaskRow[];
}

/** 任务动作的请求体：action 只认 pause / resume / run / delete。 */
export interface HostTaskActionBody {
  action: string;
}

/** 插件开关的请求体。 */
export interface HostPluginToggleBody {
  profile: string;
  name: string;
  enabled: boolean;
}

export interface HostPluginToggleResp {
  ok?: boolean;
  profile?: string;
  name?: string;
  enabled?: boolean;
  /** 清单是否真的被改写；没改说明本来就是那个状态 */
  changed?: boolean;
  /** 改写后必须重启宿主才生效 */
  restartRequired?: boolean;
}

export interface FsEntry {
  name: string;
  dir: boolean;
  size: number;
  mtime: number;
}

export interface FsListing {
  root: string;
  path: string;
  entries: FsEntry[];
  more: boolean;
  /** 会话没有工作目录时，宿主退回了它自己的当前目录 */
  fallback?: boolean;
}

export interface FsResp {
  ok?: boolean;
  root?: string;
  path?: string;
  entries?: FsEntry[];
  more?: boolean;
  fallback?: boolean;
}

export interface TeamMemberRow {
  id: string;
  name: string;
  description: string;
  phase: string;
  error: string;
}

export interface TeamTaskRow {
  id: string;
  revision: number;
  subject: string;
  description: string;
  status: string;
  ownerName: string;
  ownerId: string;
}

export interface TeamResp {
  ok?: boolean;
  sessionId?: string;
  enabled?: boolean;
  sawMode?: boolean;
  members?: TeamMemberRow[];
  tasks?: TeamTaskRow[];
}

export interface TeamModeBody {
  enabled: boolean;
}

export interface TeamModeResp {
  ok?: boolean;
  enabled?: boolean;
}

export interface FsFile {
  name: string;
  size: number;
  text: string;
}

export interface FsFileResp {
  ok?: boolean;
  name?: string;
  size?: number;
  text?: string;
}

export interface AnswerModeBody {
  mode: string;
}

export interface AnswerModeResp {
  ok?: boolean;
  mode?: string;
}
