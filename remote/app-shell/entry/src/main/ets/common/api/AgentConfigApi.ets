import { ApiTransport } from '../ApiTransport';
import {
  Catalog,
  GoalCreateBody,
  GoalResp,
  GoalView,
  ModelBody,
  ModelsResp,
  PermBody,
  PermResp,
  PermsResp,
  PresetBody,
  PresetResp,
  PresetsResp,
  TeamModeBody,
  TeamModeResp,
  TeamResp
} from '../ApiTypes';

interface GoalActionBody {
  action: string;
  objective?: string;
}

/**
 * 会话级智能体配置：模型路由、预设目录、权限档位、AgentTeams 团队协作与 Goal 目标控制。
 */
export class AgentConfigApi {
  static async models(t: ApiTransport, id: string): Promise<Catalog> {
    const r: ModelsResp = await t.call<ModelsResp>('/api/models?sessionId=' + encodeURIComponent(id), 'GET');
    return r.catalog;
  }

  static async selectModel(t: ApiTransport, id: string, provider: string, model: string, effort: string): Promise<void> {
    const body: ModelBody = { provider: provider, model: model };
    if (effort !== '') {
      body.reasoningEffort = effort;
    }
    await t.call<object>('/api/sessions/' + encodeURIComponent(id) + '/model', 'POST', JSON.stringify(body));
  }

  static async presets(t: ApiTransport): Promise<PresetsResp> {
    return await t.call<PresetsResp>('/api/presets', 'GET');
  }

  static async permissions(t: ApiTransport, id: string): Promise<PermsResp> {
    return await t.call<PermsResp>('/api/permissions?sessionId=' + encodeURIComponent(id), 'GET');
  }

  static async selectPreset(t: ApiTransport, id: string, presetId: string): Promise<string> {
    const body: PresetBody = { presetId: presetId };
    const r: PresetResp = await t.call<PresetResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/preset', 'POST', JSON.stringify(body));
    return r.scope === undefined ? 'session' : r.scope;
  }

  static async setPermission(t: ApiTransport, id: string, permission: string): Promise<string> {
    const body: PermBody = { permission: permission };
    const r: PermResp = await t.call<PermResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/permission', 'POST', JSON.stringify(body));
    return r.current === undefined ? permission : r.current;
  }

  static async team(t: ApiTransport, id: string): Promise<TeamResp> {
    return await t.call<TeamResp>('/api/sessions/' + encodeURIComponent(id) + '/team', 'GET');
  }

  static async teamMode(t: ApiTransport, id: string, enabled: boolean): Promise<boolean> {
    const body: TeamModeBody = { enabled: enabled };
    const r: TeamModeResp = await t.call<TeamModeResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/team/mode', 'POST', JSON.stringify(body));
    return r.enabled === true;
  }

  static async goal(t: ApiTransport, id: string): Promise<GoalView | null> {
    const r: GoalResp = await t.call<GoalResp>('/api/sessions/' + encodeURIComponent(id) + '/goal', 'GET');
    return r.goal === undefined ? null : r.goal;
  }

  static async goalCreate(t: ApiTransport, id: string, objective: string,
    maxRounds?: number): Promise<GoalView | null> {
    const body: GoalCreateBody = { action: 'create', objective: objective };
    if (maxRounds !== undefined && maxRounds > 0) {
      body.maxGoalRounds = Math.floor(maxRounds);
    }
    const r: GoalResp = await t.call<GoalResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/goal/action', 'POST', JSON.stringify(body));
    return r.goal === undefined ? null : r.goal;
  }

  static async goalAction(t: ApiTransport, id: string, action: string, objectiveOrPatch: string = ''): Promise<GoalView | null> {
    const body: GoalActionBody = { action: action };
    if (objectiveOrPatch !== '') {
      let objText: string = objectiveOrPatch;
      if (objectiveOrPatch.startsWith('"objective":')) {
        try {
          objText = JSON.parse(objectiveOrPatch.slice('"objective":'.length)) as string;
        } catch (e) {
          objText = objectiveOrPatch;
        }
      }
      body.objective = objText;
    }
    const r: GoalResp = await t.call<GoalResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/goal/action', 'POST', JSON.stringify(body));
    return r.goal === undefined ? null : r.goal;
  }
}
