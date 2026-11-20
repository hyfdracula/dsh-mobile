/**
 * 页面转场共享状态。
 *
 * Navigation 的 customNavContentTransition 只拿得到 navDestinationId，
 * 拿不到页面实例，所以每个页面在 onReady（首页在 aboutToAppear）里
 * 把「改自己位移/透明度/缩放」的回调注册进来，转场回调再按 id 找到
 * 两端页面一起驱动，做出 push/pop 的联动效果。
 */
export interface NavFxSink {
  apply: (tx: string, opacity: number, scale: number) => void;
}

export class NavFx {
  /** 首页是 Navigation 的内容区，没有 navDestinationId，用这个固定键。 */
  static readonly HOME: string = 'home';

  private static sinks: Map<string, NavFxSink> = new Map();

  static register(id: string, sink: NavFxSink): void {
    if (id === '') {
      return;
    }
    NavFx.sinks.set(id, sink);
  }

  /** 只删自己注册的那个：页面重建时新旧实例清理顺序不定，不能误删新注册的。 */
  static unregister(id: string, sink: NavFxSink): void {
    const cur: NavFxSink | undefined = NavFx.sinks.get(id);
    if (cur !== undefined && cur === sink) {
      NavFx.sinks.delete(id);
    }
  }

  static has(id: string): boolean {
    return NavFx.sinks.has(id);
  }

  static apply(id: string, tx: string, opacity: number, scale: number): void {
    const sink: NavFxSink | undefined = NavFx.sinks.get(id);
    if (sink !== undefined) {
      sink.apply(tx, opacity, scale);
    }
  }
}
