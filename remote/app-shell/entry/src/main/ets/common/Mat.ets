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
}
