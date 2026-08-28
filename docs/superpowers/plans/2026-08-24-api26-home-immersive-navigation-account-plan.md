# API 26 首页、沉浸光感导航、华为账号与同步实施计划

> **执行要求：** 使用 harmonyos-dev、test-driven-development、arkts-error-fixes（仅在编译报错时）和 verification-before-completion。每个任务先写失败测试，再做最小实现，最后运行该任务相关测试。工程中存在用户自己的未提交内容，只修改本计划列出的文件，不批量暂存或覆盖无关改动。

**目标：** 将错题收集应用升级到 HarmonyOS API 26，新增真实数据驱动的学习仪表盘首页、四项官方沉浸光感悬浮导航，并接通华为账号登录、HTTPS 会话和基础多设备文本同步，同时保持未登录时端侧功能完整可用。

**架构：** `Index` 通过 `Stack` 组合持久化页面容器与自定义悬浮导航。`HomeDashboardService` 聚合现有端侧数据。账户层由 Account Kit UI、HTTPS 客户端、Asset Store 会话存储组成。同步层使用本地 UUID 映射表和 outbox，不改写已有业务主键；服务器序列作为跨设备操作顺序，基础冲突策略为按服务器序列最后写入生效。

**技术栈：** ArkTS、ArkUI、API 26 `uiMaterial.ImmersiveMaterial`、Account Kit、Network Kit、Asset Store Kit、ArkData RDB、现有 NestJS/MySQL 同步 API、Hypium、Node 源码契约测试、Hvigor。

---

## 任务 1：建立 API 26 可构建基线

**文件：**

- 修改：`build-profile.json5`
- 修改：`entry/src/main/module.json5`
- 创建：`entry/src/test/Api26ConfigurationContracts.test.cjs`

### 步骤 1：写失败的 API 26 配置契约测试

测试读取 `build-profile.json5` 和 `module.json5`，断言：

- `targetSdkVersion` 为 `26.0.0`。
- `compatibleSdkVersion` 为 `26.0.0`，避免包含 API 26 UI 调用的 HAP 安装到不支持设备。
- entry 模块 metadata 包含 `ohos.arkui.UIMaterial.state=enable`。

### 步骤 2：验证测试先失败

运行：

```powershell
node entry/src/test/Api26ConfigurationContracts.test.cjs
```

预期：因当前目标和兼容版本仍为 `6.1.1(24)` 且 metadata 缺失而失败。

### 步骤 3：做最小配置升级

- 将目标和兼容 SDK 改为 `26.0.0`。
- 在 entry 模块级 metadata 中启用系统材质。
- 不触碰签名字段及证书密码。

### 步骤 4：运行配置测试和 API 26 基线构建

```powershell
node entry/src/test/Api26ConfigurationContracts.test.cjs
$env:DEVECO_SDK_HOME='D:\Program Files\Huawei\DevEco Studio1\sdk'
& 'D:\Program Files\Huawei\DevEco Studio1\tools\hvigor\bin\hvigorw.bat' --no-daemon --mode module -p product=default -p module=entry@default -p buildMode=debug assembleHap
```

预期：配置测试通过；若 Hvigor 模型版本需要迁移，只按 API 26 构建器给出的明确诊断调整 `oh-package.json5`/锁文件，不猜测版本。

### 步骤 5：检查点

```powershell
git diff --check -- build-profile.json5 entry/src/main/module.json5 entry/src/test/Api26ConfigurationContracts.test.cjs
```

## 任务 2：封装官方沉浸光感主题

**文件：**

- 修改：`entry/src/main/ets/constants/AppTheme.ets`
- 创建：`entry/src/main/ets/constants/ImmersiveMaterials.ets`
- 创建：`entry/src/test/ImmersiveMaterialContracts.test.cjs`

### 步骤 1：写失败的材质契约测试

断言材质模块：

- 从 `@ohos.arkui.uiMaterial` 导入官方类型。
- 构造 `uiMaterial.ImmersiveMaterial`。
- 导航材质启用 `applyShadow`、`interactive` 和 `lightEffect`。
- 主题主色切换为参考图所需绿色，并保留可读的深色未选中颜色。

### 步骤 2：验证测试失败

```powershell
node entry/src/test/ImmersiveMaterialContracts.test.cjs
```

### 步骤 3：实现集中材质工厂/常量

- 导航使用 `ImmersiveStyle.REGULAR`、带透明度的浅色 `materialColor`、阴影、交互形变和白/绿色光效。
- 首页重点卡与登录卡使用较弱配置，避免所有组件相同层级。
- 材质对象集中创建，页面不重复拼接配置。

### 步骤 4：运行测试与编译

```powershell
node entry/src/test/ImmersiveMaterialContracts.test.cjs
.\hvigorw.bat --mode module -p product=default -p module=entry@default -p buildMode=debug assembleHap
```

## 任务 3：测试驱动首页数据聚合模型

**文件：**

- 创建：`entry/src/main/ets/models/HomeDashboard.ets`
- 创建：`entry/src/main/ets/services/HomeDashboardService.ets`
- 修改：`entry/src/test/LocalUnit.test.ets`
- 创建：`entry/src/test/HomeDashboardContracts.test.cjs`

### 步骤 1：先写领域测试

在 Hypium 中覆盖：

- 错题为 0 时掌握率为 0。
- 掌握数量不超过错题数量，掌握率限制在 0–100。
- 最近书籍和最近错题最多各 3 条，并复制输入数组，防止页面修改服务结果。
- `pendingCount` 直接来自真实统计，不生成演示值。

契约测试断言聚合服务调用：

- `StatisticsService.load()`。
- `QuestionBankService.listBanks()`。
- `WrongQuestionService.listSummaries(new WrongQuestionFilter(), 3, 0)`。

### 步骤 2：验证测试失败

```powershell
node entry/src/test/HomeDashboardContracts.test.cjs
.\hvigorw.bat --mode module -p product=default -p module=entry@default test
```

### 步骤 3：实现最小模型与聚合服务

- `HomeDashboardSnapshot` 保存统计、最近书籍、最近错题和掌握率。
- `HomeDashboardMath.masteryRate()` 为无平台依赖的纯函数。
- 聚合服务并行读取现有服务，任何错误向页面抛出，由页面决定重试 UI。

### 步骤 4：运行领域测试

```powershell
node entry/src/test/HomeDashboardContracts.test.cjs
.\hvigorw.bat --mode module -p product=default -p module=entry@default test
```

## 任务 4：实现学习仪表盘首页

**文件：**

- 创建：`entry/src/main/ets/pages/HomePage.ets`
- 创建：`entry/src/main/ets/components/HomeOverviewCard.ets`
- 创建：`entry/src/main/ets/components/HomeRecentSection.ets`
- 创建：`entry/src/test/HomePageContracts.test.cjs`

### 步骤 1：写失败的首页契约测试

断言首页包含：

- `active` 和 `refreshVersion` 监听，沿用现有页面的防陈旧请求模式。
- 今日待复习、错题总数、已掌握、掌握率。
- 最近书籍、最近错题。
- “开始复习”“导入资料”。
- 加载、错误重试和真实空状态。
- 重点卡调用 `.systemMaterial(...)`。

### 步骤 2：验证失败

```powershell
node entry/src/test/HomePageContracts.test.cjs
```

### 步骤 3：实现首页

- 接收 `onSelectTab(index)`、`onStartImport()` 和 `onStartReview()` 回调，不在首页复制路由状态。
- 最近书籍跳转书籍页，最近错题跳转错题页。
- 没有数据时引导导入，不展示伪造数字。
- 为底部悬浮导航预留内容空间。

### 步骤 4：运行测试和构建

```powershell
node entry/src/test/HomePageContracts.test.cjs
.\hvigorw.bat --mode module -p product=default -p module=entry@default -p buildMode=debug assembleHap
```

## 任务 5：替换为四项悬浮光感导航

**文件：**

- 创建：`entry/src/main/ets/models/MainTab.ets`
- 创建：`entry/src/main/ets/components/MainBottomNavigation.ets`
- 修改：`entry/src/main/ets/pages/Index.ets`
- 删除：`entry/src/main/ets/components/BottomTabItem.ets`（确认无引用后）
- 创建：`entry/src/test/MainNavigationContracts.test.cjs`

### 步骤 1：写失败的导航契约测试

断言：

- 顺序严格为“首页、书籍、错题、我的”。
- 默认索引为 0。
- 使用 `Stack` 叠放页面和自定义导航。
- 导航容器应用官方 system material。
- 不出现中心加号或第五项。
- `BooksPage`、`WrongQuestionsPage`、`MinePage` 的 active/refresh 语义仍保留。

### 步骤 2：验证失败

```powershell
node entry/src/test/MainNavigationContracts.test.cjs
```

### 步骤 3：实现导航和页面容器

- 使用四个系统 Symbol 图标；以 API 26 SDK 中实际存在的符号资源为准并通过编译验证。
- 每项至少 48vp 点击高度并添加 `accessibilityText`。
- 选中项绿色，未选中项深灰。
- 点击采用短时颜色/缩放动画；系统材质负责光感交互。
- 首页导入回调路由到 `PdfImportSetupPage` 或现有统一导入入口；完成导入后增加 `refreshVersion`。

### 步骤 4：运行测试与构建

```powershell
node entry/src/test/MainNavigationContracts.test.cjs
.\hvigorw.bat --mode module -p product=default -p module=entry@default -p buildMode=debug assembleHap
```

## 任务 6：配置公网 HTTPS 私有 CA 和类型安全 HTTP 客户端

**文件：**

- 创建：`entry/src/main/resources/resfile/appCaCert/ca.crt`
- 创建：`entry/src/main/resources/base/profile/network_config.json`
- 修改：`entry/src/main/module.json5`
- 创建：`entry/src/main/ets/constants/ApiConfig.ets`
- 创建：`entry/src/main/ets/services/ApiHttpClient.ets`
- 创建：`entry/src/main/ets/models/ApiModels.ets`
- 创建：`entry/src/test/ApiClientContracts.test.cjs`

### 步骤 1：写失败的网络安全契约测试

断言：

- API 基地址为 `https://114.132.197.160`，没有 HTTP 降级。
- module 引用 `network_config.json`。
- 配置只信任随 HAP 预置的服务器 CA，并关闭用户 CA 信任。
- HTTP 客户端设置连接/读取超时、JSON 内容类型、状态码检查和 `caPath`。
- 客户端源码不包含 Client Secret。

### 步骤 2：验证失败

```powershell
node entry/src/test/ApiClientContracts.test.cjs
```

### 步骤 3：加入 CA 和客户端

- 从已验证的服务器 CA 文件复制证书到 `resfile/appCaCert`；先比较证书 SHA-256，再写入工程。
- Network Kit 使用 `/data/storage/el1/bundle/entry/resources/resfile/appCaCert`。
- 将底层请求封装为返回严格模型的 GET/POST，不把原始服务器错误直接渲染到 UI。
- 401 由账户服务统一处理，普通页面不自行刷新令牌。

### 步骤 4：运行测试和构建

```powershell
node entry/src/test/ApiClientContracts.test.cjs
.\hvigorw.bat --mode module -p product=default -p module=entry@default -p buildMode=debug assembleHap
```

## 任务 7：安全保存应用会话并实现刷新/退出

**文件：**

- 创建：`entry/src/main/ets/models/AccountSession.ets`
- 创建：`entry/src/main/ets/services/AccountSessionStore.ets`
- 创建：`entry/src/main/ets/services/AccountSessionService.ets`
- 修改：`entry/src/main/ets/services/AppBootstrapService.ets`
- 修改：`entry/src/test/LocalUnit.test.ets`
- 创建：`entry/src/test/AccountSessionContracts.test.cjs`

### 步骤 1：写失败的会话测试

覆盖：

- 登录响应序列化/反序列化。
- 访问令牌到期前使用现有令牌，到期或收到 401 时只允许一个刷新请求。
- 刷新失败清理令牌但保留本地学习数据和同步 outbox。
- 退出调用 `/v1/auth/logout` 后清理本机会话。
- deviceKey 首次生成后稳定复用。

契约测试断言敏感令牌使用 Asset Store Kit，而不是明文 Preferences。

### 步骤 2：验证失败

```powershell
node entry/src/test/AccountSessionContracts.test.cjs
.\hvigorw.bat --mode module -p product=default -p module=entry@default test
```

### 步骤 3：实现会话层

- 使用 Asset Store 保存 refresh token、deviceKey 和必要会话元数据。
- 访问令牌只在内存保存；应用恢复时用 refresh token 建立新访问令牌。
- 对外暴露只读的 `signedIn`、`syncing` 和可展示用户标识状态。

### 步骤 4：运行测试

```powershell
node entry/src/test/AccountSessionContracts.test.cjs
.\hvigorw.bat --mode module -p product=default -p module=entry@default test
```

## 任务 8：接入 Account Kit 登录卡

**文件：**

- 创建：`entry/src/main/ets/components/HuaweiAccountCard.ets`
- 创建：`entry/src/main/ets/services/HuaweiLoginService.ets`
- 修改：`entry/src/main/ets/pages/MinePage.ets`
- 创建：`entry/src/test/HuaweiLoginContracts.test.cjs`

### 步骤 1：写失败的登录契约测试

断言：

- 从 `@kit.AccountKit` 使用 `LoginWithHuaweiIDButton` 和 `loginComponentManager`。
- 只把 `authorizationCode`、deviceKey、deviceName 发送到 `/v1/auth/huawei`。
- 错误码 1001502012 作为用户取消处理，不显示技术错误。
- 登录卡使用重点沉浸材质。
- 未登录文案明确“登录后开启云同步”，不声称本地功能受限。
- 已登录显示同步状态和退出入口。

### 步骤 2：验证失败

```powershell
node entry/src/test/HuaweiLoginContracts.test.cjs
```

### 步骤 3：实现 Account Kit 组件和交互

- 使用官方按钮样式和控制器回调取得授权码。
- 防止重复登录请求，页面销毁后不更新陈旧状态。
- 服务端成功后刷新卡片和首页同步状态。
- 将 MinePage “所有学习数据仅保存在本机”改为准确的本地优先/可同步说明。

### 步骤 4：运行测试与构建

```powershell
node entry/src/test/HuaweiLoginContracts.test.cjs
.\hvigorw.bat --mode module -p product=default -p module=entry@default -p buildMode=debug assembleHap
```

## 任务 9：建立本地同步映射和 outbox

**文件：**

- 修改：`entry/src/main/ets/services/DatabaseService.ets`
- 创建：`entry/src/main/ets/models/SyncModels.ets`
- 创建：`entry/src/main/ets/services/SyncIdentityService.ets`
- 创建：`entry/src/main/ets/services/SyncOutboxService.ets`
- 修改：`entry/src/test/LocalUnit.test.ets`
- 创建：`entry/src/test/SyncSchemaContracts.test.cjs`

### 步骤 1：写失败的 schema/纯逻辑测试

覆盖：

- 数据库从版本 4 升到版本 5。
- `sync_identity(entity_type, local_id, client_uuid)` 保持已有非 UUID 本地主键与服务器 UUID 的稳定映射。
- `sync_outbox` 保存 UUID operationId、实体 UUID、类型、操作、payload 和创建时间。
- `sync_state` 保存用户维度 cursor，退出登录不删除未提交本地操作。
- 同一实体连续未发送 upsert 可压缩为最新一次；delete 覆盖待发送 upsert。

### 步骤 2：验证失败

```powershell
node entry/src/test/SyncSchemaContracts.test.cjs
.\hvigorw.bat --mode module -p product=default -p module=entry@default test
```

### 步骤 3：实现迁移和队列

- 迁移必须使用事务，失败保持 schema version 4。
- 使用 `util.generateRandomUUID()` 创建符合服务器验证规则的 UUID。
- 映射表允许远端首次出现的 UUID 创建新的本地行，同时不批量改写旧数据主键。

### 步骤 4：运行测试与构建

```powershell
node entry/src/test/SyncSchemaContracts.test.cjs
.\hvigorw.bat --mode module -p product=default -p module=entry@default -p buildMode=debug assembleHap
```

## 任务 10：让本地写操作可靠进入同步队列

**文件：**

- 修改：`entry/src/main/ets/services/QuestionBankService.ets`
- 修改：`entry/src/main/ets/services/WrongQuestionService.ets`
- 创建：`entry/src/main/ets/services/SyncPayloadFactory.ets`
- 修改：`entry/src/test/LocalUnit.test.ets`
- 创建：`entry/src/test/SyncMutationContracts.test.cjs`

### 步骤 1：写失败的变更捕获测试

断言：

- 新建/导入题库产生 question_bank 与 question upsert。
- 编辑题目产生 question upsert。
- 添加、掌握和移除错题产生 wrong_question upsert/delete。
- 清空错题逐条产生 delete，而不是丢失远端删除信息。
- 应用远端操作时使用 `remoteApply` 标志，不能再次进入 outbox。
- 图片路径和图片二进制不进入 payload，本轮只同步文字数据。

### 步骤 2：验证失败

```powershell
node entry/src/test/SyncMutationContracts.test.cjs
.\hvigorw.bat --mode module -p product=default -p module=entry@default test
```

### 步骤 3：在同一数据库事务中写业务数据和 outbox

- 题库/题目 payload 使用映射后的 UUID 关系。
- wrong_question 以 question client UUID 为服务器实体标识，status 表示 pending/mastered。
- 保持登录可选：未登录时也记录 outbox，登录后可上传现有本地文字数据。

### 步骤 4：运行测试与构建

```powershell
node entry/src/test/SyncMutationContracts.test.cjs
.\hvigorw.bat --mode module -p product=default -p module=entry@default -p buildMode=debug assembleHap
```

## 任务 11：实现 push/pull 和可见同步状态

**文件：**

- 创建：`entry/src/main/ets/services/CloudSyncService.ets`
- 创建：`entry/src/main/ets/services/RemoteOperationApplier.ets`
- 修改：`entry/src/main/ets/components/HuaweiAccountCard.ets`
- 修改：`entry/src/main/ets/pages/HomePage.ets`
- 修改：`entry/src/main/ets/pages/Index.ets`
- 修改：`entry/src/test/LocalUnit.test.ets`
- 创建：`entry/src/test/CloudSyncContracts.test.cjs`

### 步骤 1：写失败的同步测试

覆盖：

- push 每批最多 100 条，成功后才删除对应 outbox 行。
- pull 使用当前 cursor，分页直到 `hasMore=false`。
- 远端操作按 `serverSequence` 顺序应用，完成事务后才推进 cursor。
- 网络失败不推进 cursor、不删除 outbox。
- 401 经过单次刷新后重试一次，仍失败则停止同步。
- 同一实体冲突以最后服务器序列为准。
- 未登录时 `syncNow()` 返回本地模式结果，不发网络请求。

### 步骤 2：验证失败

```powershell
node entry/src/test/CloudSyncContracts.test.cjs
.\hvigorw.bat --mode module -p product=default -p module=entry@default test
```

### 步骤 3：实现最小可靠同步循环

1. 检查登录状态。
2. push outbox 批次。
3. pull 并事务应用远端操作。
4. 刷新首页/书籍/错题/我的版本号。
5. 在首页和登录卡显示“本地模式、同步中、已同步、待同步、同步失败”。

不做后台常驻或定时唤醒；本轮在登录成功、用户点击同步和应用前台恢复时触发，避免扩大后台权限范围。

### 步骤 4：运行测试与构建

```powershell
node entry/src/test/CloudSyncContracts.test.cjs
.\hvigorw.bat --mode module -p product=default -p module=entry@default -p buildMode=debug assembleHap
```

## 任务 12：全量回归、安全检查和设备验证

**文件：**

- 修改：`项目开发进度与待办.md`
- 按实际结果修改：本计划涉及的文件

### 步骤 1：运行全部 Node 契约测试

```powershell
Get-ChildItem entry/src/test/*.test.cjs | ForEach-Object { node $_.FullName; if ($LASTEXITCODE -ne 0) { throw "Test failed: $($_.Name)" } }
```

预期：全部通过。

### 步骤 2：运行 ArkTS 单元测试和 API 26 构建

```powershell
$env:DEVECO_SDK_HOME='D:\Program Files\Huawei\DevEco Studio1\sdk'
.\hvigorw.bat --mode module -p product=default -p module=entry@default test
.\hvigorw.bat --mode module -p product=default -p module=entry@default -p buildMode=debug assembleHap
```

预期：零编译错误；警告逐条检查，不忽略与 API 26、Account Kit 或安全有关的警告。

### 步骤 3：运行服务端回归

```powershell
npm test --prefix server
npm run build --prefix server
```

预期：现有认证、数据库和同步测试全部通过。

### 步骤 4：执行敏感信息扫描

在受控文件范围内检查：

- 客户端无 `Client Secret`。
- 无 HTTP 明文 API 地址。
- 无 refresh token 日志。
- `.env`、签名密码和私钥未进入 diff。

### 步骤 5：连接设备验证

使用 harmonyos-dev 的 hdc 流程：

1. `hdc list targets` 确认 API 26 设备或模拟器。
2. 安装 debug HAP。
3. 冷启动检查首页和四项导航。
4. 检查底部安全区、旋转、平板布局和光感交互。
5. 未登录状态完成导入/添加/复习操作。
6. 华为账号登录，验证服务端注册、刷新、同步和退出。
7. 断网修改后恢复网络，确认 outbox 可靠补传。
8. 第二设备登录同一账号，确认文字数据 pull；确认图片不在本轮同步范围。

### 步骤 6：更新进度文档

只记录实际完成和实际验证结果；未完成的 Account Kit 真机授权、第二设备同步等必须保留为待办，不能因构建通过而标记完成。

### 步骤 7：最终差异检查

```powershell
git status --short
git diff --check
git diff --stat
```

确认没有覆盖用户原有改动，也没有把服务器环境变量、证书私钥或签名信息加入版本控制。
