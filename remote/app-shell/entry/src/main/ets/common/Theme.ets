import { ConfigurationConstant } from '@kit.AbilityKit';
import { AppCtx } from './AppCtx';
import { Mat } from './Mat';
import { SafeArea } from './SafeArea';
import { Tokens } from './Tokens';

/** 外观模式：跟随系统 / 深色 / 浅色。 */
export const THEME_AUTO: string = 'auto';
export const THEME_DARK: string = 'dark';
export const THEME_LIGHT: string = 'light';

/** 把模式与系统深浅合成最终颜色。 */
export function resolveDark(mode: string, systemDark: boolean): boolean {
  if (mode === THEME_DARK) {
    return true;
  }
  if (mode === THEME_LIGHT) {
    return false;
  }
  return systemDark;
}

/**
 * 应用主题：改调色板 -> 刷新材质缓存与状态栏前景色 -> 写入 AppStorage 的 themeBg / themeDark / themeRev。
 * 页面用 @StorageLink('themeBg') 或 @StorageLink('themeDark') 订阅，值一变就会重绘。
 */
export function applyTheme(mode: string, systemDark: boolean): void {
  const dark: boolean = resolveDark(mode, systemDark);
  Tokens.applyDark(dark);
  Mat.invalidate();
  SafeArea.syncSystemBar(dark, Tokens.bg);
  // 系统沉浸光感材质跟的是应用色彩模式：跟随系统时设为 NOT_SET 以便继续接收系统深浅色切换事件。
  try {
    const ctx = AppCtx.abilityOrNull();
    if (ctx !== null) {
      const targetMode: ConfigurationConstant.ColorMode = mode === THEME_AUTO
        ? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET
        : (dark
          ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
          : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
      ctx.getApplicationContext().setColorMode(targetMode);
    }
  } catch (e) {
    console.info('DSH_THEME colorMode skipped: ' + JSON.stringify(e));
  }
  AppStorage.setOrCreate('themeBg', Tokens.bg);
  AppStorage.setOrCreate('themeDark', dark);
  const rev: number = AppStorage.get<number>('themeRev') ?? 0;
  AppStorage.setOrCreate('themeRev', rev + 1);
  console.info('DSH_THEME mode=' + mode + ' systemDark=' + systemDark + ' dark=' + dark);
}
