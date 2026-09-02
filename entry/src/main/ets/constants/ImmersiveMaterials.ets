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

  static readonly navigationDark: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.REGULAR,
    materialColor: '#D91A1F26',
    colorInvert: false,
    applyShadow: true,
    interactive: true,
    lightEffect: {
      color: '#26FFFFFF'
    }
  })

  static readonly header: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
    materialColor: '#D9FFFFFF',
    colorInvert: false,
    applyShadow: false,
    interactive: false
  })

  static readonly headerDark: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
    materialColor: '#D91A1F26',
    colorInvert: false,
    applyShadow: false,
    interactive: false
  })

  static readonly floatingButton: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
    materialColor: '#40FFFFFF',
    colorInvert: false,
    applyShadow: false,
    interactive: true,
    lightEffect: {
      color: '#80FFFFFF'
    }
  })

  static readonly floatingButtonDark: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
    materialColor: '#402C343E',
    colorInvert: false,
    applyShadow: false,
    interactive: true,
    lightEffect: {
      color: '#33FFFFFF'
    }
  })

  static readonly selectedControl: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THIN,
    materialColor: '#F218A66A',
    colorInvert: false,
    applyShadow: false,
    interactive: true,
    lightEffect: {
      color: '#6618A66A'
    }
  })

  static readonly selectedControlDark: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THIN,
    materialColor: '#F221B573',
    colorInvert: false,
    applyShadow: false,
    interactive: true,
    lightEffect: {
      color: '#6621B573'
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

  static readonly overviewCardDark: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THIN,
    materialColor: '#B81A1F26',
    colorInvert: false,
    applyShadow: true,
    interactive: false,
    lightEffect: {
      color: '#8021B573'
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

  static readonly accountCardDark: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.REGULAR,
    materialColor: '#CF1A1F26',
    colorInvert: false,
    applyShadow: true,
    interactive: true,
    lightEffect: {
      color: '#9921B573'
    }
  })

  static navigationFor(dark: boolean): uiMaterial.ImmersiveMaterial {
    return dark ? ImmersiveMaterials.navigationDark : ImmersiveMaterials.navigation
  }

  static headerFor(dark: boolean): uiMaterial.ImmersiveMaterial {
    return dark ? ImmersiveMaterials.headerDark : ImmersiveMaterials.header
  }

  static floatingButtonFor(dark: boolean): uiMaterial.ImmersiveMaterial {
    return dark ? ImmersiveMaterials.floatingButtonDark : ImmersiveMaterials.floatingButton
  }

  static selectedControlFor(dark: boolean): uiMaterial.ImmersiveMaterial {
    return dark ? ImmersiveMaterials.selectedControlDark : ImmersiveMaterials.selectedControl
  }

  static overviewCardFor(dark: boolean): uiMaterial.ImmersiveMaterial {
    return dark ? ImmersiveMaterials.overviewCardDark : ImmersiveMaterials.overviewCard
  }

  static accountCardFor(dark: boolean): uiMaterial.ImmersiveMaterial {
    return dark ? ImmersiveMaterials.accountCardDark : ImmersiveMaterials.accountCard
  }
}
