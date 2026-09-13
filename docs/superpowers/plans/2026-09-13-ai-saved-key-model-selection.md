# 已保存 API Key 与模型选择实施计划

> **执行约束：** 使用 `executing-plans` 按任务顺序执行；每个生产改动必须先有可观察的红灯合同。当前工作树包含用户已有修改，禁止重置、覆盖或回退；禁止修改 `server/`、worker 或真实 AI 识别流程。

**目标：** AI 识别设置页重开后显示不可逆的已保存 Key 状态，并使用 HUKS 中的已保存凭据直接加载、选择和保存模型，同时保持平台/地址变化必须更换 Key 的安全边界。

**架构：** 页面只保存布尔展示状态和本次输入，不接触已保存密钥字节。`AiModelCatalogService` 在 `AiCredentialStore.withCredential` 回调内完成 `/models` 请求。配置存储新增“同凭据作用域”比较，仅允许同 provider/base URL 下修改 model；识别和连接测试继续使用完整配置一致性守卫。

**技术栈：** HarmonyOS ArkTS/ArkUI、HUKS 凭据存储、Node.js CJS 合同测试、DevEco ArkTS checker、hvigor、hdc。

---

### Task 1：锁定服务层的已保存凭据目录合同

**文件：**
- 修改：`entry/src/test/AiModelCatalogContracts.test.cjs`
- 测试：`entry/src/test/AiModelCatalogContracts.test.cjs`

- [ ] 扩展 VM 夹具，注入 fake `AiCredentialStore` 和 `Context`。
- [ ] 新增合同：`fetchWithSavedCredential(context, baseUrl)` 必须通过 `withCredential` 调用现有 `fetchWithCredential`，且整个异步 transport await 都处于凭据回调作用域内。
- [ ] 断言服务返回模型 ID，不返回凭据；回调完成后 fake 字节已清零。
- [ ] 运行 `node --test entry/src/test/AiModelCatalogContracts.test.cjs`，保存缺少新入口的预期红灯证据。

### Task 2：锁定页面恢复、掩码与模型保留合同

**文件：**
- 修改：`entry/src/test/AiImportContracts.test.cjs`
- 修改：`entry/src/test/AiImportSecurityContracts.test.cjs`
- 测试：上述两个文件

- [ ] 扩展设置页运行夹具，提供 `sameCredentialScope` 与模型服务的两条目录入口。
- [ ] 新增行为合同：加载已保存配置和可用凭据后，页面自动调用模型服务的 saved-credential 入口；当前模型即时恢复，返回目录后仍保留选中。
- [ ] 新增失败合同：目录为空、当前模型不在目录或请求失败时，保留已保存模型并显示安全状态，不清空持久化数据。
- [ ] 新增作用域合同：仅修改模型可以用已保存 Key 保存；平台或 API 地址变化会进入更换 Key 状态并拒绝复用旧凭据。
- [ ] 新增 UI/安全源码合同：出现 `••••••••（已安全保存）` 和“更换 API Key”，掩码不赋给 `apiKey`；页面仍禁止直接调用 `withCredential` 或读取完整 Key。
- [ ] 运行两个合同文件，确认旧生产实现因缺少掩码状态、自动目录加载和作用域比较而红灯，并保存证据。

### Task 3：实现模型目录服务的安全入口

**文件：**
- 修改：`entry/src/main/ets/services/ai/AiModelCatalogService.ets`
- 测试：`entry/src/test/AiModelCatalogContracts.test.cjs`

- [ ] 导入 `Context` 与 `AiCredentialStore`，新增 `fetchWithSavedCredential`。
- [ ] 仅在 `withCredential` 回调内 await `fetchWithCredential`，不复制、不转成字符串、不返回凭据。
- [ ] 保持 typed-key 入口、URL 校验、传输上限、模型解析和清零逻辑不变。
- [ ] 立即运行该文件 ArkTS 检查，然后运行模型目录合同直至绿灯。

### Task 4：实现设置页状态与模型选择流程

**文件：**
- 修改：`entry/src/main/ets/services/ai/AiProviderConfigStore.ets`
- 修改：`entry/src/main/ets/pages/AiRecognitionSettingsPage.ets`
- 测试：`entry/src/test/AiImportContracts.test.cjs`
- 测试：`entry/src/test/AiImportSecurityContracts.test.cjs`

- [ ] 在配置存储增加 `sameCredentialScope`，只比较规范化后的 providerId/baseUrl；保留 `sameConfig` 供识别、连接和持久化完整一致性检查。
- [ ] 页面增加“使用已保存 Key / 正在更换 Key”展示状态；掩码仅在 Builder 中作为固定文案，不写入 `apiKey`。
- [ ] `loadSettings` 完成持久化配置与 `hasCredential` 检查后，自动走 saved-credential 目录入口；无 Key 或更新屏障挂起时不请求。
- [ ] 统一 typed/saved 两条目录加载路径；成功、空结果、当前模型缺失和失败时都保留已有模型，目录选择仍需显式保存。
- [ ] 切换平台或编辑 API 地址时清空目录并进入更换 Key 流程；只更换模型不进入该流程。
- [ ] 页面加载、离开、保存、清除和失败收尾继续清空本次输入与显示开关；pending 时继续禁止返回、平台/地址/模型变更、保存、清除和测试。
- [ ] 调整 UI：已保存时显示不可编辑掩码和“更换 API Key”；更换/未配置时显示密码输入；已保存 Key 可直接“重新获取模型”；模型选项最长两行/溢出受控并维持当前原生主题、触控目标与深色模式。
- [ ] 每编辑一个 `.ets` 文件后运行逐文件 ArkTS 检查；再运行两个页面合同文件直至绿灯。

### Task 5：回归、构建与真机验证

**文件：**
- 修改：`docs/superpowers/plans/2026-09-12-ui-review-and-remediation.md`
- 创建证据：`docs/superpowers/plans/ui-review-2026-09-12/`

- [ ] 依次运行 AI 设置/模型目录合同、AI/PDF 相关 CJS、全量客户端 CJS，并记录已知 `CloudCutoverContracts` 的 `server/` 脏树守卫失败，不清理或修改 `server/`。
- [ ] 对 `AiProviderConfigStore.ets`、`AiModelCatalogService.ets`、`AiRecognitionSettingsPage.ets` 逐文件 ArkTS 检查。
- [ ] 构建 debug HAP，运行 `git diff --check`，检查设备连接并安装 HAP。
- [ ] 为避免自动恢复识别或真实服务请求，默认不启动普通应用；仅在可确认不会发起收费识别且当前配置允许只读 `/models` 时验证掩码与模型选择。否则记录安装成功及未启动原因。
- [ ] 将修改、红绿灯证据、ArkTS、构建、diff-check、设备状态、截图与后续问题回填到 UI remediation 文档。
- [ ] 不执行 commit、push、merge 或创建 PR。
