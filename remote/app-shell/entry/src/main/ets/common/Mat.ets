import uiMaterial from '@ohos.arkui.uiMaterial';
import { Tokens } from './Tokens';

/**
 * 系统沉浸光感材质（HarmonyOS 6 / API 26）的唯一入口。
 *
 * 只有放在 Navigation/NavDestination 标题栏或 Tabs 底部 TabBar 里的组件才拿得到，
 * 自绘浮层再漂亮也不算数。设备不支持时退回空材质，外观与不开启时一致。
 */
export class Mat {
  private static cache: uiMaterial.Material | undefined = undefined;

  static bar(): uiMaterial.Material {
    if (Mat.cache === undefined) {
      let m: uiMaterial.Material = uiMaterial.Material.empty;
      try {
        if (uiMaterial.isImmersiveMaterialSupported()) {
          m = new uiMaterial.ImmersiveMaterial({
            style: uiMaterial.ImmersiveStyle.THIN,
            interactive: true,
            lightEffect: { color: Tokens.accent }
          });
        }
      } catch (e) {
        console.info('DSH_MAT build failed: ' + JSON.stringify(e));
      }
      Mat.cache = m;
    }
    return Mat.cache as uiMaterial.Material;
  }

  private static whiteCache: uiMaterial.Material | undefined = undefined;

  /** 白色光晕版本：不带品牌蓝，点按只泛白光。 */
  static white(): uiMaterial.Material {
    if (Mat.whiteCache === undefined) {
      let m: uiMaterial.Material = uiMaterial.Material.empty;
      try {
        if (uiMaterial.isImmersiveMaterialSupported()) {
          m = new uiMaterial.ImmersiveMaterial({
            style: uiMaterial.ImmersiveStyle.THIN,
            interactive: true,
            lightEffect: { color: '#FFFFFF' }
          });
        }
      } catch (e) {
        console.info('DSH_MAT white build failed: ' + JSON.stringify(e));
      }
      Mat.whiteCache = m;
    }
    return Mat.whiteCache as uiMaterial.Material;
  }

  /** 设置里的「沉浸光感」开关：关掉时返回空材质，控件退回普通底色。 */
  static bySwitch(enabled: boolean): uiMaterial.Material {
    if (!enabled) {
      return uiMaterial.Material.empty;
    }
    return Mat.bar();
  }

  /** 只要白光、不要品牌蓝的开关版本。 */
  static whiteOn(enabled: boolean): uiMaterial.Material {
    if (!enabled) {
      return uiMaterial.Material.empty;
    }
    return Mat.white();
  }
}
