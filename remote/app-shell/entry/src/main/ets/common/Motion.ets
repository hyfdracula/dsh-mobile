import curves from '@ohos.curves';

/**
 * 全 App 唯一的动效参数表。
 *
 * 三档时长、两条曲线就够：
 * - fade：纯透明度变化（160）
 * - move：位移/尺寸/布局（220）
 * - emph：页面级/强调动画（320）
 *
 * 曲线：
 * - std：先快后慢、末尾轻轻收住，位移与尺寸都用它
 * - spring：按压回弹，只给底部 Tab 与点按反馈
 */
export class Motion {
  static readonly fade: number = 160;
  static readonly move: number = 220;
  static readonly emph: number = 320;

  static readonly std = curves.cubicBezierCurve(0.2, 0.72, 0.32, 1);
  static readonly spring = curves.springCurve(0.42, 0.62, 200, 12);
}
