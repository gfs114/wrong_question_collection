# 客户端多模态 AI 数学 PDF 导入：续跑交接

更新时间：2026-09-09（Asia/Shanghai）

## 目标与约束

- 仓库：`G:\code\openHarmony\wrong_question_collection`
- 主计划：`docs/superpowers/plans/2026-09-05-client-ai-math-pdf-import.md`
- 设计：`docs/superpowers/specs/2026-09-05-client-ai-math-pdf-import-design.md`
- 正式 PDF 入口只走客户端 AI 视觉识别；旧 Cloud/OCR 文件仅保留作代码级回滚，不得成为正式入口或 fallback。
- API Key 仅由 HUKS AES-256-GCM 保护并在受限闭包中使用；不得写日志、同步、业务数据库、路由或 UI。
- 不调用真实收费 Provider；没有 API 24+ `hdc` 设备时不得把 HUKS/真实 PDF E2E 标记为 PASS。
- 保留用户现有脏工作区；不要 reset/checkout、不要提交、不要 push、不要建 PR。
- 用户要求：剩余用量到 5% 时先写本文档，然后自动继续。

## 完整 Task 0–14 执行清单

下面是本功能全部任务的可续跑清单。原始逐步代码片段、RED/GREEN 命令和固定 A–J 模板仍以主计划
`2026-09-05-client-ai-math-pdf-import.md` 为准；本节补齐每个 Task 的目标、文件边界、验收重点和当前状态。

### Task 0：固化工作树与测试基线 — 已完成

- 目标：记录用户已有修改，建立客户端 CJS、ArkTS、server Jest、worker pytest 基线。
- 文件：只检查整个工作树，不应主动改文件。
- 命令：`git status --short`、逐个 `entry/src/test/*.test.cjs`、ArkTS checker、`npm test --prefix server -- --runInBand`、worker pytest、`git diff --stat`。
- 验收：后续不得丢失或覆盖用户已有 `MathContentView`、`MathContentUtils`、审核页及 server/worker 改动。
- 已知基线：`CloudCutoverContracts` 的 server-clean 守卫因预存 server 脏改动失败；该失败被用户允许，不能通过回退 server 修复。

### Task 1：AI 限额、配置和数据模型 — 已完成、双审通过

- 新增：`constants/AiImportLimits.ets`、`models/ai/AiProviderConfig.ets`、`models/ai/AiImportModels.ets`、`AiImportLocalUnit.test.ets`。
- 修改：`entry/src/test/List.test.ets` 注册 AI 单元测试。
- 核心：Provider ID、HTTPS Base URL 规范化、模型必填、稳定错误码；单页/图片/响应/字段/bbox 上限；严格 ArkTS class 模型。
- 验收：官方与自定义 OpenAI-compatible 配置可规范化；非 HTTPS、userinfo、query、fragment、空模型等失败；限额常量被后续模块统一复用。

### Task 2：非秘密 Provider 配置持久化 — 已完成、双审通过

- 新增：`services/ai/AiProviderConfigStore.ets` 及对应合同。
- 核心：Preferences 只保存 provider/model/base URL 等非秘密；读取后重新规范化；不保存 Key、Authorization、请求/响应。
- 后续加固：持久 `credential_update_pending` 闸门、`loadUsable/withUsableConfig`、配置相等校验与串行锁。
- 验收：凭据替换未完成或表单未保存时，任何连接测试/导入/重试均不能读取并发送旧 Key。

### Task 3：HUKS 加密 API Key 与备份排除 — 已完成、双审通过

- 新增：`HuksAesGcmCipher.ets`、`AiCredentialEnvelopeCodec.ets`、`AiCredentialStore.ets`、安全合同与 HUKS 设备测试。
- 修改：`backup_config.json`、`ohosTest` 注册。
- 核心：不可导出设备密钥、AES-256-GCM、随机 nonce、版本化单记录 envelope、AAD/完整性校验、原子 Preferences 记录、操作串行、明文缓冲清零。
- 验收：Unicode 往返、nonce 不复用、篡改拒绝、失效密钥清理、无明文备份；设备项只有 API 24+ 真机/模拟器执行后才能 PASS。

### Task 4：固定数学 Prompt 与严格 JSON Parser — 已完成、双审通过

- 新增：`MathQuestionPromptBuilder.ets`、`AiQuestionResponseParser.ets` 及 Hypium/CJS 合同。
- 核心：页码/总页数/有限前文、提示注入隔离、严格 `questions[]` schema、允许一层完整 JSON fence、拒绝尾随文本/HTML/超长字段/非法 bbox/非法 LaTeX。
- 验收：保留 `\frac`、`\sqrt`、`f^{-1}`、`\varphi`、独立 `cases`；视觉顺序稳定；不臆造答案/解析。

### Task 5：OpenAI-compatible Adapter 与安全 Transport — 已完成、双审通过

- 新增：`AiProviderAdapter.ets`、`OpenAiCompatibleAdapter.ets`、`AiVisionTransport.ets`。
- 核心：`POST <https-base>/chat/completions`、Bearer 只在 transport 构造、text + 单页 JPEG data URL、`stream:false`、可选结构化输出。
- 安全：仅 HTTPS、禁止重定向、状态码稳定映射、Content-Type 与 2 MiB 响应上限、超时/取消、同 request key 替换安全、请求体/响应释放、Header 控制字符拒绝。
- 验收：AI 模块中只有 `AiVisionTransport.ets` 可拥有 Authorization；不得复用业务 HTTP client 或私有 CA。

### Task 6：逐页渲染、JPEG 限额与证据图生命周期 — 已完成、双审通过

- 新增：`PdfPageImageEncoder.ets` 及合同/假实现。
- 核心：PDFKit 逐页渲染、自适应 JPEG 质量、最大尺寸/字节限制、PixelMap 先释放后网络、bbox 裁图、坏 bbox 使用整页证据。
- 文件安全：`session~attempt~...` 精确命名，临时文件 fsync/close 后原子 move，`~` 所有权分隔，拒绝符号链接与跨根路径。
- 生命周期：refcount/deferred close；成功、失败、取消、重试均有精确清理；整页未引用时删除。

### Task 7：Cloud/AI 双源审核模型与会话仓库 — 已完成、双审通过

- 新增：`services/review/PdfReviewModels.ets`、`PdfReviewSession.ets`。
- 修改：`PdfImportState.ets`。
- 核心：来源中立 session/question/option/image/failure 模型；Cloud/AI source；save stage；深拷贝存取；稳定 session/bank/question UUID；reviewSessionId 路由状态。
- 验收：外部调用不能通过引用修改仓库；nullable 字段、图片排序和失败证据完整保留。

### Task 8：串行 Coordinator、取消和单页重试 — 已完成、双审通过

- 新增：`PdfAiImportCoordinator.ets` 及 fake renderer/adapter/transport/parser 测试。
- 核心：一次仅一页；共同 `processPage` 支持初次与重试；generation + request identity 防延迟凭据/旧请求出网；取消当前 HTTP 并停止后续页。
- 原子性：单页题目与证据全成后才提交；失败页保留整页证据继续下一页；重试先提交新会话再删旧证据；显式 discard 尝试图片与 PDF 两类清理。
- 后续加固：`AiImportCleanupRequiredError`、精确 attempt 再清理、PDF 清理幂等、完整 discard 成功后才移除 session。

### Task 9：稳定 UUID 保存、账号固定与本机图片映射 — 已完成、双审通过

- 新增/修改：`AiImportSaveService.ets`、`CloudQuestionRepository.ets`、`DeviceImageStore.ets`、`AccountSessionService/Store.ets`、`EntryAbility.ets`、恢复/幂等/证据生命周期测试。
- 核心：用户确认后才保存；稳定 bank/question UUID；文本走现有 `/v1/sync/push`，PDF/图片/Provider/Key 不进同步 payload。
- 检查点：先持久 `TEXT_SAVING` 再远程文字写入，随后 `TEXT_SAVED/COMPLETE`；pending ID 索引；前台恢复；保存终态幂等。
- 账号：每批次固定 expectedAccountId；登录/刷新/退出串行；refresh token 与 owner 同一版本化 AssetStore 记录，旧/raw/mismatch fail closed。
- 图片：保存前 SHA/size/ownership 预检；单个 IMMEDIATE 事务写全部映射；区分 ROLLED_BACK/UNKNOWN；UNKNOWN 保留 finals。
- 终态清理：逐引用清理 + 严格 session 前缀 sweep；PDF 已删除但后续失败时用只读 absence proof 收敛，已存在未注册 PDF 仅恢复流程可删除。

### Task 10：统一 Cloud/AI 审核 Adapter 与 UI — 已完成、双审通过

- 新增：`CloudPdfReviewAdapter.ets`、`AiPdfReviewAdapter.ets`。
- 修改：`PdfImportReviewPage.ets`、审核模型/coordinator/合同。
- 核心：页面只依赖来源中立 adapter；Cloud 保持 confirm→持久状态→下载/校验/保存→账号复核→ACK→confirmed 顺序；AI 以持久检查点优先。
- UI：继续使用 `MathContentView`/KaTeX；本地 `file://` 原图；失败页提供“重试识别”“手动新增题目”“放弃本页”。
- 安全状态：任何写入后无法重新加载权威状态时设置 `authoritativeStatePending`，锁定编辑、保存、返回和放弃，提供“重新加载审核状态”。

### Task 11：AI 设置页与显式连接测试 — 已完成、双审通过

- 新增：`AiRecognitionSettingsPage.ets`、`AiConnectionTestService.ets`。
- 修改：`MinePage.ets`、`main_pages.json`、`easy_go.json`、AI 合同。
- UI：Provider、Model、API Key、Base URL 高级设置；Key 只显示“已配置”，当前输入可显示/隐藏；保存/清除后清空输入。
- 连接测试：仅用户按钮触发；内存 1×1 JPEG；一次请求、无自动重试；只要求非空 assistant content，不要求白图产生题目。
- 跨存储加固：更新 Key 前先持久 pending marker；config+HUKS 都成功后才清除；配置改变且已有 Key 时必须重新输入 Key；测试及生产 credential dispatch 在同一 usable-config 锁内。

### Task 12：正式 PDF 入口、Setup 与 Progress — 已完成、双审通过

- 新增：`PdfAiImportSetupPage.ets`、`PdfAiImportProgressPage.ets`。
- 修改：`ImportBankPage.ets`、路由、`PdfImportService.ets`、coordinator、保存清理及合同。
- 正式入口：只调用 `PdfImportService.selectPdf()` 并进入 AI setup；旧 Cloud 页面保留但不可从正式选择进入。
- Setup：显示 Provider/Model、题库名、科目、页码；校验账号、`loadUsable`、Key、页数；可进入 AI 设置。
- Progress：单 coordinator、单 start guard、逐页进度/题数、显式 Cancel、无自动 retry；普通页失败进入审核 session。
- 生命周期加固：预检取消、部分 discard、账号切换、审核导航失败、重复选择/路由失败、终态 prefix debt、PDF post-delete retry 均有可达所有者和幂等重试。

### Task 13：六题回放、无回退和无泄密合同 — 已完成、双审通过

- 修改：`AiImportLocalUnit.test.ets`、`AiImportContracts.test.cjs`、`AiImportSecurityContracts.test.cjs`、`PdfImportContracts.test.cjs`、`CloudCutoverContracts.test.cjs`；必要时加强 `CloudCacheContracts.test.cjs`。
- 六题：固定内层 assistant content，断言例 1.1–1.6 数量/顺序与目标 LaTeX；绝不联网。
- 安全：AI services 无日志/OCR/Cloud/business endpoint；Authorization 唯一 transport owner；sync writer 无 Provider/Key/PDF/image bytes。
- 正式入口：负断言严格限定 AI 流文件；不得扫描整个仓库误伤回滚代码。
- 图片/保存/fake：坏 bbox 必须保留整页图；自动化只用 fake 和保留测试域名；稳定 UUID；单次 IMMEDIATE 图片事务；纯文本同步。
- 当前状态：初版 `SPEC_COMPLIANT`；质量要求加固 4 个 Medium 合同。实现代理正在做大小写 Authorization、真实 bbox 语义、事务调用次数、禁止生产网络实现/真实主机测试。完成后必须再次规格/质量双审。

### Task 14：全量验证、设备验收和 A–J 交付 — 已完成

- 全 CJS：逐文件运行并汇总，不能因 server-clean 已知失败跳过其余文件。
- ArkTS：全项目 checker 必须 `0 errors / 0 warnings`。
- Hypium/build：已有唯一有界尝试卡 `Starting hvigor daemon` 并终止 PID 3488；没有环境变化时记录 NOT VERIFIED，不重复空耗。
- Server/worker：运行 Task 0 同命令并与基线比较；`git diff --name-only -- server` 只能是既存路径。
- HUKS：运行 `hdc list targets`；无 API 24+ 目标时精确报告 NOT RUN。
- 真实 PDF：只有设备、用户真实六题 PDF、用户自有多模态凭据/model、用户在 app 内显式点击都具备时才可收费执行；否则 NOT RUN 并写缺失前提。
- 审计：AI 日志/Authorization/credential/OCR/Cloud endpoint 扫描；检查无 PDF、Key、响应、HAP、签名材料或新 server feature 文件；`git status/diff --stat/diff --check`。
- 报告：按主计划固定 A–J 骨架，区分 PASS、FAIL、NOT RUN、NOT VERIFIED；不提交。

## 已完成并通过双审

- Task 1：AI 模型、限制、Provider 配置。
- Task 2：非敏感 Provider Preferences 存储。
- Task 3：HUKS AES-GCM 凭据存储、原子 envelope、备份排除与设备测试定义。
- Task 4：数学 Prompt 与严格响应 parser。
- Task 5：OpenAI-compatible adapter 与独立、受限、可取消 HTTPS transport。
- Task 6：PDF 单页 JPEG/证据裁图编码与严格文件所有权。
- Task 7：来源中立审核模型/会话。
- Task 8：严格串行 coordinator、取消、重试、证据清理。
- Task 9：文本/图片保存、稳定 UUID、账号固定、持久检查点、恢复与幂等。
- Task 10：Cloud/AI 双审核 adapter 与统一审核 UI。
- Task 11：AI 设置页与显式 1x1 JPEG 连接测试；新增持久凭据更新闸门，避免旧 Key 被发送到新端点。最终：`SPEC_COMPLIANT`、`APPROVED`。
- Task 12：正式 PDF 入口、AI setup/progress、取消/清理/审核导航状态机；补齐 PDF 所有权、清理债务、终态前缀清理和 PDF 已删除后的只读 absence proof。最终：`SPEC_COMPLIANT`、`APPROVED`。

## Task 12 关键最终行为

- `ImportBankPage.selectPdf()` 使用 `PdfImportService.selectPdf()`，只路由 `PdfAiImportSetupPage`。
- 旧选择删除失败或新页面导航失败时，新候选 PDF 会删除或原子转为 orphan，不会成为不可达 registered path。
- setup 使用 `AiProviderConfigStore.loadUsable()`，并校验账号、Key、题库名、科目和页码。
- progress 只启动一次；预检期间取消也进入中央清理；清理失败保留 request/session/path 并提供“重试清理”。
- 完成识别后立即禁用取消、重新核对账号；审核导航失败可“重新进入审核”或“放弃并清理”，不会重新识别。
- `AiImportCleanupRequiredError` 只在最终清理仍失败时暴露；进度页据此保留清理所有权。
- 保存完成与放弃都会调用严格 session 前缀清理，覆盖未引用的失败 attempt/旧证据。
- `PdfImportService.proveTemporaryPdfAbsent()` 只读验证缓存根下 `staged_pdf_<digits>.pdf` 已不存在；不会删除存在的未注册文件。用于 PDF 已删但后续账号/检查点操作失败后的普通前台重试幂等。

## Task 13：已完成（2026-09-09 终审）

初版 4 个 Medium 质量问题的最终处理（只改测试，生产未动）：

1. ✅ Authorization 扫描大小写无关 + 路径规范化后断言唯一 owner；助手自测含小写/反斜杠/多 owner 反例（`AiImportSecurityContracts.test.cjs`）。
2. ✅ bbox 真实 coordinator 语义测试已接线：`AiImportContracts.test.cjs` 新增两个经 vm 驱动真实 `PdfAiImportCoordinator.processPage` 的语义测试——坏 bbox 不裁图、问题持有整页 `evidencePath`、`cleanupEvidence` 不被调用；好 bbox 对照（裁图 1 次、整页证据被丢弃）。`bboxCoordinatorRuntime` 死代码已消除。
3. ✅ `DeviceImageStore.saveBatch()` 恰好一次 `createTransaction(DEVICE_IMAGE_TRANSACTION_OPTIONS)`（`TransactionType.IMMEDIATE`），且创建晚于批次完整校验（`CloudCacheContracts.test.cjs`）。
4. ✅ fake-only 合同接线：`assertTestOnlyUrlLiterals` + `assertNoProductionNetworkUse` 已对 `AiImportLocalUnit.test.ets` 全文实际调用；新增自测含真实收费域名 / `AiVisionTransport` 导入 / `@kit.NetworkKit` / `fetch(` 四个反例与正例。

破坏性复核（字节级干净突变 + 哈希验证恢复，仓库未动）：

- bbox 突变 `source.bboxUsable ?` → `true ?`：仅 'unusable bbox skips cropping…' 变红，对照保持绿。
- 注入 `https://api.deepseek.com/v1/chat/completions`：仅 'automated tests use fakes…' 以 "URL fixture must use a reserved test hostname" 变红。

最终双审：

- 规格复审（spec_review_task13）：`SPEC_COMPLIANT`（S1–S10 全部 PASS）。
- 质量复审（quality_review_task13）：`APPROVED`（Q1–Q8 全部 PASS）。

Task 14 期间补修的 3 个被 Task 11/12 遗留的过期合同测试（均只改测试，与批准架构一致）：

- `CloudImportPageContracts.test.cjs`：正式入口测试改为「只经 `PdfImportService.selectPdf()` 进入 `PdfAiImportSetupPage`，不再暂存 Cloud 选择」。
- `NativeNavigationContracts.test.cjs`：`ImportBankPage` 断言改为 UIContext `pushUrl({ url: 'pages/PdfAiImportSetupPage' })`；新 AI setup 页加入 `pushUrl(options)` 白名单。
- `Task9ResourceContracts.test.cjs`：`main_pages.json` 期望路由列表加入 `AiRecognitionSettingsPage`、`PdfAiImportSetupPage`、`PdfAiImportProgressPage`。

## 最终验证证据（2026-09-09，Task 13/14 完成）

- Task 13 五个计划 CJS：`160/159/1`。唯一失败 = 已知允许基线 `CloudCutoverContracts` 的「server directory has zero uncommitted changes」（`server/` 用户预存改动，不得修复）。
- 全量 `entry/src/test/*.test.cjs`（36 文件）：`268/267/1`；除上述基线外全部通过。
- ArkTS 全项目 checker：`0 errors / 0 warnings`。
- server Jest：34 suites / 330 passed / 1 skipped，exit 0。worker pytest（`--basetemp .pytest-ai-import-final`）：132 passed / 2 skipped，exit 0。
- `git diff --name-only -- server` 与 Task 0 记录的既存脏树一致（全部时间戳早于本功能窗口），无新 server/worker 路径。
- `hdc list targets` → `[Empty]`：`HUKS device test: NOT RUN (no API 24+ hdc target)`。
- 真实 PDF E2E：`NOT RUN`——API 24+ 设备、用户真实六题 PDF、用户自有凭据/模型、用户显式点击均未提供；未发起任何收费调用。
- Hypium/debug build：`NOT VERIFIED`——本环境持续卡在 `Starting hvigor daemon`，环境状态无变化，未重复空耗。
- 泄密/范围审计：Authorization 仅 `AiVisionTransport.ets` 构造；AI services/页面无日志、无 OCR、无 Cloud endpoint；测试 fixture 无真实 Key/域名/PDF 字节；工作区无 PDF/Key/响应/HAP/签名材料；`git diff --check` 干净。
- 未 `git add`、未提交、未 push、未建 PR；用户现有脏工作区保留。

已知且允许的基线失败：

- `CloudCutoverContracts.test.cjs` 的 `server directory has zero uncommitted changes` 因用户/先前任务已有 `server/` 修改失败。
- 不得为使该断言变绿而修改、回退或删除 `server/` 现有工作。

## Task 14：已完成（2026-09-09）

按主计划执行完毕并输出 A–J 报告（在会话回复中，不落盘）：

1. ✅ 逐个运行 `entry/src/test/*.test.cjs`（36 文件，不因单文件失败中断）：`268/267/1`；唯一失败 = 已知 server 脏树守卫，单独归类。
2. ✅ 全项目 ArkTS checker：`0 errors / 0 warnings`。
3. ✅ 不重复已知挂起的 Hypium/build：`NOT VERIFIED`（环境无变化，Task 12 已有唯一一次有界尝试并终止 PID 3488）。
4. ✅ server 基线对比：Jest `330/331`（1 skipped）、pytest `132 passed / 2 skipped`，与基线一致；`git diff --name-only -- server` 仅既存路径，未修改 server 修测试。
5. ✅ `hdc list targets` 为空：`HUKS device test: NOT RUN (no API 24+ hdc target)`。
6. ✅ 真实六题 PDF/用户凭据/用户显式点击均未提供：`Real PDF E2E: NOT RUN`，未发起任何收费调用。
7. ✅ 最终泄密与范围扫描、`git status --short`、`git diff --stat`、`git diff --check` 全部完成且干净。
8. ✅ 按 A–J 骨架报告；未提交、未 push、未建 PR。

## 常用命令

```powershell
$env:DEVECO_HOME='D:\Program Files\Huawei\DevEco Studio'
node 'C:/Users/32773/.agents/skills/harmonyos-dev-skill/scripts/arkts-check.cjs' --project .

node --test entry/src/test/AiImportContracts.test.cjs `
  entry/src/test/AiImportSecurityContracts.test.cjs `
  entry/src/test/PdfImportContracts.test.cjs `
  entry/src/test/CloudCutoverContracts.test.cjs `
  entry/src/test/CloudCacheContracts.test.cjs

hdc list targets
git status --short
git diff --stat
git diff --check
```

## 重要文件

- AI 配置/凭据：`entry/src/main/ets/services/ai/AiProviderConfigStore.ets`、`AiCredentialStore.ets`
- 网络/协议：`AiVisionTransport.ets`、`OpenAiCompatibleAdapter.ets`
- 编码/协调：`PdfPageImageEncoder.ets`、`PdfAiImportCoordinator.ets`
- 设置与正式入口：`AiRecognitionSettingsPage.ets`、`ImportBankPage.ets`、`PdfAiImportSetupPage.ets`、`PdfAiImportProgressPage.ets`
- 审核/保存：`services/review/AiPdfReviewAdapter.ets`、`PdfImportReviewPage.ets`、`AiImportSaveService.ets`
- 关键测试：`AiImportLocalUnit.test.ets`、`AiImportContracts.test.cjs`、`AiImportSecurityContracts.test.cjs`、`PdfImportContracts.test.cjs`、`CloudCutoverContracts.test.cjs`、`CloudCacheContracts.test.cjs`、`AiImportSaveIdempotency.test.cjs`
