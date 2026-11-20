import { ConfigurationConstant } from '@kit.AbilityKit';
import { common } from '@kit.AbilityKit';
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
 * 应用主题：改调色板 → 写入 AppStorage 的 themeBg / themeRev。
 * 页面用 @StorageLink('themeBg') 订阅，值一变就会重绘（进而重新读取 Tokens）。
 */
export function applyTheme(mode: string, systemDark: boolean): void {
  const dark: boolean = resolveDark(mode, systemDark);
  Tokens.applyDark(dark);
  // 系统沉浸光感材质跟的是"应用色彩模式"，不是我们自己的 Tokens。
  // 不告诉系统，深色界面下会糊出一块浅灰板。
  try {
    const ctx = getContext() as common.UIAbilityContext;
    ctx.getApplicationContext().setColorMode(dark
      ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
      : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
  } catch (e) {
    console.info('DSH_THEME colorMode skipped: ' + JSON.stringify(e));
  }
  AppStorage.setOrCreate('themeBg', Tokens.bg);
  AppStorage.setOrCreate('themeFg', Tokens.fg);
  AppStorage.setOrCreate('themeDark', dark);
  const rev: number = AppStorage.get<number>('themeRev') ?? 0;
  AppStorage.setOrCreate('themeRev', rev + 1);
  console.info('DSH_THEME mode=' + mode + ' systemDark=' + systemDark + ' dark=' + dark);
}
