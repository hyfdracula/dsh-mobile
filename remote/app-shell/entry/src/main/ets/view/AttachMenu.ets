import { BackendCapabilities, SlashCommandRow, defaultBackendCapabilities } from '../common/Api';
import { ComposerPlusMenu } from './chat/ComposerPlusMenu';

/**
 * 输入框「+」与「/」双分组指令菜单入口（F09）：
 * 委托至 chat/ComposerPlusMenu 渲染「添加」与「指令」双分组浮层。
 */
@Component
export struct AttachMenu {
  @Prop planActive: boolean = false;
  @Prop hasGoal: boolean = false;
  @Prop hostCommands: SlashCommandRow[] = [];
  @Prop filterPrefix: string = '';
  @Prop cmdBusyText: string = '';
  @Prop backendId: string = 'dsh';
  @Prop caps: BackendCapabilities = defaultBackendCapabilities('dsh');
  @Prop showFeedback: boolean = false;
  onCamera: () => void = () => {};
  onPhotos: () => void = () => {};
  onFiles: () => void = () => {};
  onGoal: () => void = () => {};
  onTogglePlan: () => void = () => {};
  onFeedback: () => void = () => {};
  onSelectCommand: (cmd: SlashCommandRow) => void = () => {};

  build() {
    ComposerPlusMenu({
      planActive: this.planActive,
      hasGoal: this.hasGoal,
      hostCommands: this.hostCommands,
      filterPrefix: this.filterPrefix,
      cmdBusyText: this.cmdBusyText,
      backendId: this.backendId,
      caps: this.caps,
      showFeedback: this.showFeedback,
      onCamera: (): void => { this.onCamera(); },
      onPhotos: (): void => { this.onPhotos(); },
      onFiles: (): void => { this.onFiles(); },
      onGoal: (): void => { this.onGoal(); },
      onTogglePlan: (): void => { this.onTogglePlan(); },
      onFeedback: (): void => { this.onFeedback(); },
      onSelectCommand: (cmd: SlashCommandRow): void => { this.onSelectCommand(cmd); }
    })
  }
}
