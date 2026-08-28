const fs = require('fs')
const path = require('path')

const etsRoot = path.resolve(__dirname, '../main/ets')

function read(relativePath) {
  const file = path.join(etsRoot, relativePath)
  if (!fs.existsSync(file)) {
    throw new Error(relativePath + ' is required')
  }
  return fs.readFileSync(file, 'utf8')
}

function expectIncludes(source, text, message) {
  if (!source.includes(text)) {
    throw new Error(message + ': ' + text)
  }
}

const materials = read('constants/ImmersiveMaterials.ets')
const theme = read('constants/AppTheme.ets')

expectIncludes(materials, "from '@ohos.arkui.uiMaterial'", 'official ArkUI material API must be used')
expectIncludes(materials, 'new uiMaterial.ImmersiveMaterial', 'immersive material must be constructed')
expectIncludes(materials, 'uiMaterial.ImmersiveStyle.REGULAR', 'navigation must use regular material')
expectIncludes(materials, 'applyShadow: true', 'material shadow must be enabled')
expectIncludes(materials, 'interactive: true', 'navigation material must react to touch')
expectIncludes(materials, 'lightEffect:', 'immersive light feedback must be configured')
expectIncludes(theme, "export const COLOR_PRIMARY: string = '#18A66A'", 'selected navigation color must be green')
expectIncludes(theme, 'COLOR_NAV_INACTIVE', 'inactive navigation color must be centralized')

process.stdout.write('Immersive material contracts passed\n')
