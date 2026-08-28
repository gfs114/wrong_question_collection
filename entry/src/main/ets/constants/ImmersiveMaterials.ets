import uiMaterial from '@ohos.arkui.uiMaterial'

export class ImmersiveMaterials {
  static readonly navigation: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.REGULAR,
    materialColor: '#D9FFFFFF',
    colorInvert: false,
    applyShadow: true,
    interactive: true,
    lightEffect: {
      color: '#CCFFFFFF'
    }
  })

  static readonly overviewCard: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THIN,
    materialColor: '#B8FFFFFF',
    colorInvert: false,
    applyShadow: true,
    interactive: false,
    lightEffect: {
      color: '#8018A66A'
    }
  })

  static readonly accountCard: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.REGULAR,
    materialColor: '#CFFFFFFF',
    colorInvert: false,
    applyShadow: true,
    interactive: true,
    lightEffect: {
      color: '#9918A66A'
    }
  })
}
