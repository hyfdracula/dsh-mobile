import { PopupItem, PopupSection, UnifiedPopupCard } from '../../common/UnifiedPopup';

/**
 * 会话分组/排序/归档/批量选择视图弹出卡片（F05）：
 * 统一挂载 UnifiedPopupCard，保持与工作区菜单、会话操作菜单及聊天页更多菜单完全一致的材质与行高。
 */
@Component
export struct SessionViewMenu {
  @Prop groupBy: string = 'time';
  @Prop sortBy: string = 'recent';
  @Prop archivedView: boolean = false;
  @Prop listState: string = 'all';

  onSelectGroupBy: (g: string) => void = () => {};
  onSelectSortBy: (sb: string) => void = () => {};
  onSetArchived: (wantArchived: boolean) => void = () => {};
  onSelectListState: (st: string) => void = () => {};
  onEnterSelect: () => void = () => {};
  onMarkAllRead: () => void = () => {};

  private buildSections(): PopupSection[] {
    const groupItems: PopupItem[] = [
      { id: 'group:time', label: '按时间排列', sub: '今天 / 昨天 / 更早', checked: this.groupBy === 'time' },
      { id: 'group:ws', label: '按工作区', checked: this.groupBy === 'ws' }
    ];
    const sortItems: PopupItem[] = [
      { id: 'sort:recent', label: '最近活动优先', checked: this.sortBy === 'recent' },
      { id: 'sort:title', label: '标题 A-Z', checked: this.sortBy === 'title' }
    ];
    const viewItems: PopupItem[] = [
      { id: 'arch:normal', label: '正常会话列表', checked: !this.archivedView },
      { id: 'arch:archived', label: '查看已归档会话', checked: this.archivedView },
      { id: 'state:all', label: '分组默认全展开', checked: this.listState === 'all' },
      { id: 'state:first', label: '分组仅展开第一组', checked: this.listState === 'first' },
      { id: 'state:none', label: '分组默认全收起', checked: this.listState === 'none' }
    ];
    const actionItems: PopupItem[] = [
      { id: 'act:select', label: '多选管理会话' },
      { id: 'act:readall', label: '全部标为已读' }
    ];
    const sections: PopupSection[] = [
      { title: '分组方式', items: groupItems },
      { title: '排序方式', items: sortItems },
      { title: '视图', items: viewItems },
      { title: '快捷操作', items: actionItems }
    ];
    return sections;
  }

  private handleSelect(id: string): void {
    if (id === 'group:time') {
      this.onSelectGroupBy('time');
    } else if (id === 'group:ws') {
      this.onSelectGroupBy('ws');
    } else if (id === 'sort:recent') {
      this.onSelectSortBy('recent');
    } else if (id === 'sort:title') {
      this.onSelectSortBy('title');
    } else if (id === 'arch:normal') {
      this.onSetArchived(false);
    } else if (id === 'arch:archived') {
      this.onSetArchived(true);
    } else if (id === 'state:all') {
      this.onSelectListState('all');
    } else if (id === 'state:first') {
      this.onSelectListState('first');
    } else if (id === 'state:none') {
      this.onSelectListState('none');
    } else if (id === 'act:select') {
      this.onEnterSelect();
    } else if (id === 'act:readall') {
      this.onMarkAllRead();
    }
  }

  build() {
    UnifiedPopupCard({
      sections: this.buildSections(),
      cardWidth: 256,
      maxCardHeight: 440,
      onSelect: (id: string) => {
        this.handleSelect(id);
      }
    })
  }
}
