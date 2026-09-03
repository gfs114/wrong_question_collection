import { hdsMaterial, SystemMaterialParams } from '@kit.UIDesignKit'
import { hilog } from '@kit.PerformanceAnalysisKit'

const DOMAIN: number = 0x0000
const TAG: string = 'WQC_MATERIAL'

// HdsTabs 底栏正式沉浸光感材质策略（API24 兼容路径）。
// 官方 hdsMaterial 文档（6.1.0(23)+）：
//   MaterialType.ADAPTIVE = 100 自适应系统材质，默认为沉浸式材质
//   MaterialLevel.ADAPTIVE = 10  系统根据设备性能自适应材质等级
// 正式版固定使用 ADAPTIVE + ADAPTIVE，由系统根据设备能力与性能自行适配，
// 不默认强制 IMMERSIVE + EXQUISITE（高等级材质性能开销更大）。
export interface HdsMaterialSelection {
  materialType: hdsMaterial.MaterialType
  materialLevel: hdsMaterial.MaterialLevel
}

export class HdsMaterialPolicy {
  // 设备真正支持的 HDS 材质类型。任何异常都返回空数组，不影响启动与导航。
  static supportedTypes(): Array<hdsMaterial.MaterialType> {
    try {
      return hdsMaterial.getSystemMaterialTypes()
    } catch (err) {
      let detail: string = 'unknown error'
      if (err instanceof Error) {
        detail = err.message
      }
      hilog.warn(DOMAIN, TAG, 'getSystemMaterialTypes failed. Cause: %{public}s', detail)
      return new Array<hdsMaterial.MaterialType>()
    }
  }

  // 正式底栏材质解析：始终返回 ADAPTIVE + ADAPTIVE。
  // 设备支持情况只用于开发日志，不改变正式策略；
  // 设备返回 [] 或调用异常时同样安全降级为 ADAPTIVE 参数，
  // HdsTabs 结构不受影响，四个 Tab 与业务照常工作。
  static resolve(): HdsMaterialSelection {
    const types: Array<hdsMaterial.MaterialType> = HdsMaterialPolicy.supportedTypes()
    const supportsAdaptive: boolean = types.includes(hdsMaterial.MaterialType.ADAPTIVE)
    const supportsImmersive: boolean = types.includes(hdsMaterial.MaterialType.IMMERSIVE)
    if (supportsImmersive) {
      hilog.info(DOMAIN, TAG, 'IMMERSIVE supported (dev log only, official policy stays ADAPTIVE)')
    }
    if (supportsAdaptive) {
      hilog.info(DOMAIN, TAG, 'official material policy: ADAPTIVE + ADAPTIVE')
    } else {
      hilog.warn(DOMAIN, TAG,
        'no system material types reported, HdsTabs stays functional with ADAPTIVE params')
    }
    const selection: HdsMaterialSelection = {
      materialType: hdsMaterial.MaterialType.ADAPTIVE,
      materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
    }
    return selection
  }

  static systemMaterialEffect(): SystemMaterialParams {
    const selection: HdsMaterialSelection = HdsMaterialPolicy.resolve()
    const params: SystemMaterialParams = {
      materialType: selection.materialType,
      materialLevel: selection.materialLevel
    }
    return params
  }

  // 启动期打印设备材质能力（API24 真机首检入口）：
  // 观察 getSystemMaterialTypes() 返回 [] / [100] / [100,101]。
  static logDeviceSupport(): void {
    hilog.info(DOMAIN, TAG, 'getSystemMaterialTypes: %{public}s',
      JSON.stringify(HdsMaterialPolicy.supportedTypes()))
  }
}
