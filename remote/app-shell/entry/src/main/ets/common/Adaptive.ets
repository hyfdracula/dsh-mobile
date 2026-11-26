/*
 * 屏幕断点与折叠屏自适应状态管理：
 * 监听窗口尺寸变化与折叠形态变化，通过 AppCtx.px2vp 转换为 vp 断点并同步到 AppStorage。
 */

import { display, window } from '@kit.ArkUI';
import { AppCtx } from './AppCtx';

export const BREAKPOINT_XS_END: number = 320;
export const BREAKPOINT_SM_END: number = 600;
export const BREAKPOINT_MD_END: number = 840;
export const BREAKPOINT_LG_END: number = 1440;

export type Breakpoint = 'xs' | 'sm' | 'md' | 'lg' | 'xl';
export type FoldState = 'folded' | 'half' | 'expanded';

export function breakpointOf(widthVp: number): Breakpoint {
  if (widthVp <= 0 || widthVp < BREAKPOINT_SM_END) {
    return widthVp > 0 && widthVp < BREAKPOINT_XS_END ? 'xs' : 'sm';
  }
  if (widthVp < BREAKPOINT_MD_END) {
    return 'md';
  }
  if (widthVp < BREAKPOINT_LG_END) {
    return 'lg';
  }
  return 'xl';
}

export function isCompactWidth(breakpoint: Breakpoint): boolean {
  return breakpoint === 'xs' || breakpoint === 'sm';
}

export function isExpandedWidth(breakpoint: Breakpoint): boolean {
  return breakpoint === 'lg' || breakpoint === 'xl';
}

export function contentColumnWidth(breakpoint: Breakpoint, windowWidthVp: number): number {
  const w: number = windowWidthVp > 0 ? windowWidthVp : BREAKPOINT_SM_END;
  if (breakpoint === 'xl') {
    return Math.min(1200, w - 160);
  }
  if (breakpoint === 'lg') {
    return Math.min(1040, w - 120);
  }
  return w;
}

export function deviceColumns(breakpoint: Breakpoint, deviceCount: number): number {
  return isExpandedWidth(breakpoint) && deviceCount > 1 ? 2 : 1;
}

export function foldStateOf(status: number): FoldState {
  if (status <= 0) {
    return 'folded';
  }
  const axis: number = status >= 10 ? Math.floor(status / 10) : status;
  if (axis === 1) {
    return 'expanded';
  }
  if (axis === 3) {
    return 'half';
  }
  return 'folded';
}

export function isHalfFoldedFold(state: FoldState): boolean {
  return state === 'half';
}

export class Adaptive {
  private static boundWin: window.Window | null = null;
  private static sizeListening: boolean = false;
  private static foldListening: boolean = false;
  private static widthVp: number = 360;
  private static fold: FoldState = 'folded';

  private static readonly handleResize: (size: window.Size) => void = (size: window.Size): void => {
    Adaptive.updateFromPx(size.width);
  };

  private static readonly handleFold: (status: display.FoldStatus) => void = (status: display.FoldStatus): void => {
    Adaptive.fold = foldStateOf(status as number);
    Adaptive.publish();
  };

  private static updateFromPx(widthPx: number): void {
    if (widthPx > 0) {
      const vp: number = Math.round(AppCtx.px2vp(widthPx));
      if (vp > 0) {
        Adaptive.widthVp = vp;
      }
    }
    Adaptive.publish();
  }

  private static publish(): void {
    const wide: boolean = Adaptive.widthVp >= BREAKPOINT_SM_END || Adaptive.fold === 'expanded';
    AppStorage.setOrCreate('winWidth', Adaptive.widthVp);
    AppStorage.setOrCreate('winWidthVp', Adaptive.widthVp);
    AppStorage.setOrCreate('foldState', Adaptive.fold);
    AppStorage.setOrCreate('wideScreen', wide);
  }

  static attach(win: window.Window): void {
    if (Adaptive.boundWin !== null && Adaptive.boundWin !== win && Adaptive.sizeListening) {
      try {
        Adaptive.boundWin.off('windowSizeChange', Adaptive.handleResize);
      } catch (e) {
      }
      Adaptive.sizeListening = false;
    }
    Adaptive.boundWin = win;
    AppCtx.bindWindow(win);
    try {
      Adaptive.fold = display.isFoldable() ? foldStateOf(display.getFoldStatus() as number) : 'folded';
    } catch (e) {
      Adaptive.fold = 'folded';
    }
    try {
      const rect = win.getWindowProperties().windowRect;
      Adaptive.updateFromPx(rect !== undefined ? rect.width : 0);
    } catch (e) {
      Adaptive.publish();
    }
    if (!Adaptive.sizeListening) {
      try {
        win.on('windowSizeChange', Adaptive.handleResize);
        Adaptive.sizeListening = true;
      } catch (e) {
      }
    }
    if (!Adaptive.foldListening) {
      try {
        if (display.isFoldable()) {
          display.on('foldStatusChange', Adaptive.handleFold);
          Adaptive.foldListening = true;
        }
      } catch (e) {
      }
    }
  }

  static detach(): void {
    if (Adaptive.boundWin !== null && Adaptive.sizeListening) {
      try {
        Adaptive.boundWin.off('windowSizeChange', Adaptive.handleResize);
      } catch (e) {
      }
      Adaptive.sizeListening = false;
    }
    if (Adaptive.foldListening) {
      try {
        display.off('foldStatusChange', Adaptive.handleFold);
      } catch (e) {
      }
      Adaptive.foldListening = false;
    }
    Adaptive.boundWin = null;
  }
}
