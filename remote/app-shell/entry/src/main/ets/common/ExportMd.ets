import { Message, TurnInfo } from './Api';
import { clock } from './Format';

/** 一轮结束状态的简短中文：导出文件里只写结果，不写整段报错。 */
function turnState(t: TurnInfo): string {
  if (t.status === 'completed') {
    return '已完成';
  }
  if (t.status === 'aborted' || t.status === 'interrupted') {
    return '已中断';
  }
  if (t.status === 'error') {
    return '出错';
  }
  return t.status;
}

/**
 * 把一个会话的正文导出成 Markdown。
 *
 * 从 ChatPage 抽出来：这只是字符串拼接，不需要页面状态；图片用附件 id 引用，
 * 换一台机器也能看出这里原本有一张图。
 */
export function buildSessionMarkdown(title: string, id: string, msgs: Message[], stamp: string): string {
  const lines: string[] = [];
  lines.push('# ' + title, '');
  lines.push('> 会话 ' + id + ' · 导出 ' + stamp + ' · 共 ' + String(msgs.length) + ' 条消息', '');
  for (let i = 0; i < msgs.length; i++) {
    const m: Message = msgs[i];
    lines.push('### ' + (m.role === 'user' ? '你' : '助手') + ' · ' + clock(m.time), '');
    if (m.images !== undefined) {
      for (let k = 0; k < m.images.length; k++) {
        lines.push('![图片](attachments/' + m.images[k].id + ')');
      }
      if (m.images.length > 0) {
        lines.push('');
      }
    }
    if (m.text !== undefined && m.text !== '') {
      lines.push(m.text.trim(), '');
    }
    if (m.turn !== undefined && m.turn !== null && m.turn.status !== 'completed') {
      lines.push('> 这一轮：' + turnState(m.turn), '');
    }
  }
  return lines.join('\n');
}
