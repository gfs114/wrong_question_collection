# 已保存 API Key 与模型选择设计

## 目标

用户保存 AI 识别配置并离开页面后，再次进入 `AiRecognitionSettingsPage` 时应明确看到 API Key 已安全保存，无需重新输入即可加载并选择云端模型。完整 API Key 不回显、不进入普通页面状态，也不新增明文持久化。

## 范围

本次修改仅涉及 AI 识别设置页、模型目录服务及对应客户端合同测试。保留现有 HUKS 加密记录、配置更新屏障、平台目录、连接测试、识别请求、PDF 生命周期和错误安全边界。不修改 `server/`、worker 或任何收费识别流程。

## 页面状态与交互

### 已保存密钥

当 `AiCredentialStore.hasCredential()` 返回 `true` 且凭据更新屏障未挂起时，密钥区域显示不可编辑的 `••••••••（已安全保存）`。该字符串只表达状态，不写入 `apiKey`，不能被保存、测试连接或模型请求当作凭据。

已保存状态提供“更换 API Key”操作。点击后显示现有的新密钥输入框；输入内容仍只存在于当前页面生命周期，离开、保存成功、清除成功或相关失败收尾时继续清空 `apiKey` 并关闭明文显示。

未保存密钥时直接显示新密钥输入框。原有“显示本次输入 / 隐藏本次输入”只作用于本次输入，不适用于已保存密钥。

### 模型目录

页面加载已保存配置并确认密钥可用后，自动使用已保存密钥请求当前 API 地址的 `/models`。请求期间显示“正在获取模型…”，模型选择和会改变配置的操作继续受 `pending` 守卫限制。

当前已保存模型从 `AiProviderConfigStore` 立即恢复。模型目录返回后：

- 当前模型仍在目录中时保持选中；
- 当前模型不在最新目录时保留其显示，不静默清空，并提示用户重新选择；
- 返回空目录或请求失败时保留当前模型，显示本地安全错误与“重新获取模型”操作；
- 用户选择新模型后，仍需点击“保存设置”才持久化。

模型目录不新增持久缓存。每次重新进入已配置页面都重新获取，避免长期展示过期目录；网络不可用时仍显示已保存的当前模型。

### 配置切换

切换平台或编辑 API 地址后，清空当前页面的模型目录并进入需要新密钥的替换流程。不得使用属于旧 provider/base URL 配置的已保存密钥请求新地址。现有 `REPLACEMENT_KEY_REQUIRED` 和凭据更新屏障保持有效。

仅切换模型不改变密钥作用域。用户可以用同一平台、同一 API 地址下已保存的密钥获取目录并保存新模型；保存完成后，识别请求仍需通过现有“表单配置与持久化配置完全一致”检查。平台或 API 地址任一变化仍必须提供替换密钥。

## 数据流与安全边界

`AiModelCatalogService` 增加使用已保存密钥的入口。它通过 `AiCredentialStore.withCredential(context, callback)` 获取临时 `Uint8Array`，并在该回调尚未结束时调用现有 `fetchWithCredential(baseUrl, credential)`。页面永远不接收密钥字节或明文字符串。

`AiCredentialStore` 继续负责解密、串行化和回调结束后的字节清零。模型服务继续负责地址规范化、禁止不安全公网 HTTP、请求边界、响应大小与模型 ID 校验。任意底层异常只映射到现有稳定错误信息，不能展示响应正文、Authorization 或 HUKS 细节。

模型目录调用是只读 `GET /models`，不发送图片、不调用识别模型，也不改变服务端数据。自动化测试使用 fake transport 和 fake credential store，不访问真实 Provider。

## 代码边界

- `entry/src/main/ets/pages/AiRecognitionSettingsPage.ets`
  - 增加“已保存 / 正在更换”展示状态。
  - 页面加载完成后自动获取模型目录。
  - 统一处理本次输入和已保存密钥两条模型加载路径。
  - 保证失败时保留当前模型，并维持现有 pending/返回/保存守卫。
- `entry/src/main/ets/services/ai/AiModelCatalogService.ets`
  - 增加在 HUKS 凭据作用域内调用 `fetchWithCredential` 的方法。
  - 不改变解析器、传输限制或 typed-key 入口。
- `entry/src/test/AiImportContracts.test.cjs`
  - 更新页面运行夹具，验证自动加载、模型保留和配置切换守卫。
- `entry/src/test/AiModelCatalogContracts.test.cjs`
  - 验证整个传输 await 位于 `withCredential` 回调期间，回调结束后凭据已清零。
- `entry/src/test/AiImportSecurityContracts.test.cjs`
  - 继续禁止页面解密或回显完整密钥，并禁止掩码值进入凭据/配置持久化。

## 错误与恢复

- 缺少密钥：显示未配置状态，不自动请求模型。
- 凭据更新挂起：维持现有锁定与修复提示，不自动请求模型。
- 模型网络或响应错误：清空本次目录结果但保留当前已保存模型，提供“重新获取模型”。
- 页面离开或请求完成：不在页面保留任何解密字节；本次输入按现有规则清空。
- 快速返回、重复获取、保存或清除：继续由单一 `pending` 状态阻止并发操作。

## 验证

先新增合同并确认旧实现红灯，再实现生产代码。依次运行：

1. AI 设置与模型目录相关 CJS 合同；
2. AI/PDF 相关 CJS 合同；
3. 全量客户端 CJS；
4. 两个生产 ArkTS 文件逐文件检查；
5. HAP 构建；
6. `git diff --check`。

真机只验证掩码状态、模型列表与退出重入，不点击“测试连接”或开始 PDF 识别。打开设置页会发起一次只读 `/models` 请求；若不允许连接当前配置的模型目录，则仅完成静态和 fake-transport 验证，不启动应用。
