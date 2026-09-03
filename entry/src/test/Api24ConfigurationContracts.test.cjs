const fs = require('fs')
const path = require('path')

const projectRoot = path.resolve(__dirname, '../../..')
const buildProfile = fs.readFileSync(path.join(projectRoot, 'build-profile.json5'), 'utf8')
const moduleProfile = fs.readFileSync(path.join(projectRoot, 'entry/src/main/module.json5'), 'utf8')

function expectIncludes(source, text, message) {
  if (!source.includes(text)) {
    throw new Error(message + ': ' + text)
  }
}

function expectAbsent(source, text, message) {
  if (source.includes(text)) {
    throw new Error(message + ': ' + text)
  }
}

// 1. 正式运行兼容目标：API24（HarmonyOS 6.1.1(24)）真机可安装运行
expectIncludes(buildProfile, '"compatibleSdkVersion": "6.1.1(24)"',
  'the application must be installable and runnable on API 24 devices')
// 2. 编译目标允许保持 API26 工具链（compile SDK 不降级，避免 HDS/工具链失败）
expectIncludes(buildProfile, '"targetSdkVersion": "26.0.0"',
  'the compile target may stay on the installed API 26 toolchain')
expectIncludes(buildProfile, '"runtimeOS": "HarmonyOS"',
  'the application must keep the HarmonyOS runtime')
// 3. API26 专属 App 级 UIMaterial 开关 metadata 必须移除（API24 无此能力）
expectAbsent(moduleProfile, 'ohos.arkui.UIMaterial.state',
  'the API 26-only UIMaterial metadata must be removed for the API 24 path')
// 4. 入口与 EasyGo 引用保持不变
expectIncludes(moduleProfile, '"pages": "$profile:main_pages"', 'main pages reference must remain')
expectIncludes(moduleProfile, '"easyGo": "$profile:easy_go"', 'easy_go reference must remain')

process.stdout.write('API 24 configuration contracts passed\n')
