# 软件完成度审查与首轮整改实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use executing-plans to implement this plan task-by-task. Production changes must follow test-driven-development, and completion claims must follow verification-before-completion.

**Goal:** 核实既有计划是否真正闭环，记录当前软件中可复现的不合理行为，并优先修复 PDF 审核页在权威状态未知时仍允许离开的恢复性缺陷。

**Architecture:** 保持现有 Stage 模型、客户端直连 AI、来源中立审核会话和既有持久化边界不变。本轮首改只收紧审核页状态机：权威状态未知时页面继续拥有会话，禁止返回、放弃和编辑，直到显式重新加载成功。平台能力、配置身份和性能问题拆成后续独立任务，避免与恢复性修复相互耦合。

**Tech Stack:** HarmonyOS API 26（compatible API 24）、ArkTS、ArkUI、Node.js CJS 合同测试、ArkTS checker、NestJS/Jest、Python/pytest、hdc。

---

## 1. 审查范围与结论

审查日期：2026-09-12。

审查对象：

- `docs/superpowers/plans/2026-09-05-client-ai-math-pdf-import.md`
- `docs/superpowers/plans/2026-09-08-client-ai-import-continuation.md`
- `docs/superpowers/specs/2026-09-09-ai-platform-catalog-design.md`
- `docs/superpowers/plans/2026-09-09-ai-platform-catalog.md`
- `entry/src/main/ets`、`entry/src/test`、`entry/src/ohosTest`
- `server/src`、`server/worker`

总体结论：**主要实现已存在，但不能认定所有文档任务均已完成并验收。** Task 0–13 的实现和合同覆盖基本齐全；Task 14 仍包含设备、真实 PDF 和构建验证缺口。平台目录计划的实现文件已经存在，但计划内 43 个步骤仍全部未勾选，无法从文档本身形成可信的完成记录。

### 1.1 当前验证快照

| 检查项 | 2026-09-12 结果 | 判定 |
|---|---:|---|
| 客户端 CJS（逐文件运行） | 37 文件；36 文件通过，1 文件失败 | **部分通过**。唯一失败是已知的 `CloudCutoverContracts` server 脏树守卫，不是运行时断言失败，但仍不能记为全绿 |
| ArkTS（逐文件检查 123 个主源码） | 0 errors，261 warnings，0 internal，0 unparsable | **可继续开发，但不满足旧文档写的 0 errors / 0 warnings** |
| server Jest | 34 suites；330 passed，1 skipped | **通过** |
| worker pytest | 122 passed，2 skipped，3 failed，7 errors | **本次未验证通过**。失败均源自 `server/worker/.pytest-tmp` 的 Windows ACL 拒绝访问；历史记录为 132 passed / 2 skipped |
| `git diff --check` | exit 0 | **通过** |
| `hdc list targets` | `192.168.0.104:35911` | **设备现在可见**；旧文档“无设备”已过时，但本次尚未执行 HUKS 设备测试 |
| HUKS AES-GCM 设备测试 | 未运行 | **NOT RUN** |
| 用户真实六题 PDF + 自有凭据 E2E | 未运行，未产生收费调用 | **NOT RUN** |
| Hypium / debug build | 旧记录卡在 `Starting hvigor daemon`，本次未重试 | **NOT VERIFIED** |

### 1.2 文档一致性问题

1. `2026-09-08-client-ai-import-continuation.md` 同时保留了 Task 13 “实现代理正在做”的过期文字和后文“终审完成”的最终记录，状态自相矛盾。
2. 同一文档把 Task 14 标为“已完成”，但其验收内容里 HUKS、真实 PDF、构建仍分别是 NOT RUN / NOT RUN / NOT VERIFIED；更准确的状态应为“代码完成，交付验证未闭环”。
3. `2026-09-05-client-ai-math-pdf-import.md` 仍有 95 个未勾选步骤，`2026-09-09-ai-platform-catalog.md` 仍有 43 个未勾选步骤。实际实现与合同测试存在，但计划没有回填证据，不能仅凭标题判断完成。
4. 旧记录称 ArkTS `0 errors / 0 warnings`；本次可靠的逐文件检查结果为 `0 errors / 261 warnings`。一键全项目检查显示 0/0，但它与逐文件结果不一致，不能继续把一键结果当作唯一证据。

## 2. 软件合理性问题清单

### [P1] 权威审核状态未知时仍会直接离开页面

**位置：**

- `entry/src/main/ets/pages/PdfImportReviewPage.ets:68`
- `entry/src/main/ets/pages/PdfImportReviewPage.ets:406`
- `entry/src/main/ets/pages/PdfImportReviewPage.ets:468`
- `entry/src/test/AiImportContracts.test.cjs:1343`

**触发路径：** 保存、重试或丢弃操作已经部分提交，但随后重新读取权威会话失败；或者首次加载草稿失败。用户随后点击页面“返回”或系统返回键。

**证据：** `returnToImportPage()` 把 `authoritativeStatePending` 与 `session === null`、不可放弃阶段放在同一条件中，并在条件为真时直接调用 `navigateToImportPage()`。这与页面其他位置“状态未知时锁定编辑/保存”的策略相反。现有测试只断言没有弹窗和没有调用 abandon，没有断言 `navigate === 0`，因此遗漏了逃逸路径。首次 `loadDraft()` 失败也没有把 `authoritativeStatePending` 置为 `true`。

**影响：** 用户可能从仍拥有持久检查点/证据图的审核会话中离开，界面不再提供明确恢复入口；之后选择新 PDF 还可能覆盖当前导入状态。该问题影响数据可恢复性，应优先于视觉或便利性优化。

**修改意见：**

- `loadDraft()` 失败后统一进入权威状态未知态。
- `returnToImportPage()` 遇到权威状态未知时不得导航，改为显示“请重新加载审核状态后再返回”。
- 页面返回按钮在该状态下禁用；系统返回仍由同一守卫拦截。
- 只有显式重新加载成功并取得权威会话后，才恢复编辑/返回决策。
- 用运行时合同测试断言 `navigate === 0`，不能只做源码正则匹配。

### [P1] 已知不支持题目识别的平台仍可被选择

**位置：**

- `entry/src/main/ets/models/ai/AiPlatformCatalog.ets:35`
- `entry/src/main/ets/models/ai/AiPlatformCatalog.ets:232`
- `entry/src/main/ets/pages/AiPlatformPickerPage.ets:65`
- `entry/src/main/ets/pages/AiPlatformPickerPage.ets:84`
- `entry/src/main/ets/pages/AiRecognitionSettingsPage.ets:84`

**触发路径：** 在平台选择页选择百川、SophNet 或 LongCat。目录备注明确写着“不支持题目识别”，但列表标签显示“未确认视觉模型”，整个条目仍可点击；用户还能手填模型并保存/测试。

**影响：** 软件允许用户把 API Key 发送给已知不适用于当前图片识别流程的端点，造成可预见的失败或费用，且标签会让用户误以为只是“推荐模型未确认”。

**修改意见：** 给 `AiPlatform` 增加明确能力字段（如 `CONFIRMED`、`MANUAL`、`UNSUPPORTED`），不要解析中文备注判断逻辑。`UNSUPPORTED` 显示“暂不支持识别”，禁用选择，并在 `applyPlatform()` 再做一次防御性拦截。

### [P1] “自定义地址”只解锁输入框，却保留原平台身份

**位置：**

- `entry/src/main/ets/pages/AiRecognitionSettingsPage.ets:72`
- `entry/src/main/ets/pages/AiRecognitionSettingsPage.ets:270`
- `entry/src/main/ets/models/ai/AiProviderConfig.ets:151`

**触发路径：** 先选择 OpenAI，再点击“自定义”，把地址改为任意兼容服务并保存。

**证据：** 按钮只翻转 `urlEditable`，仍保留 `providerId = openai`、OpenAI 平台名称和模型列表。校验器仅依据 `providerId === openai` 打开 `supportsStructuredOutput`。

**影响：** 设置页会把自定义端点继续显示为 OpenAI，并可能向不支持该参数的兼容端点发送 OpenAI 专属结构化输出字段；更重要的是，用户对 API Key 实际发往何处的认知与界面身份不一致。

**修改意见：** 把开关替换为显式的 `enterCustomAddress()`：进入自定义模式时同步设置 `providerId = custom`、清空已应用平台 id/推荐模型/平台备注，并将标签改成“自定义”。恢复平台身份只能通过重新选择平台完成。

### [P2] 平台选择页导航失败被静默吞掉

**位置：** `entry/src/main/ets/pages/AiRecognitionSettingsPage.ets:263`

**问题：** `pushUrl(...).catch(() => {})` 会让路由失败表现为按钮无反应。

**修改意见：** 提取 `openPlatformPicker()`，失败时显示可理解的状态消息或 Toast，并允许重试。

### [P2] 大审核会话中每次键入会多次深拷贝整个会话

**位置：** `entry/src/main/ets/pages/PdfImportReviewPage.ets:111`、`:117`

**问题：** 每个字段变化都会在 `replaceQuestion()`、`persistEdits()` 和 `applySession()` 路径多次复制完整会话。按现有限额最多可达到约 1000 道题，长文本和证据元数据会放大主线程开销。

**修改意见：** 后续单独设计“行级草稿 + 失焦/防抖持久化”，保留离页前强制 flush；不要在本轮恢复性修复中顺带重构。

### [P2] AI 平台目录存在时效性漂移

**位置：** `entry/src/main/ets/models/ai/AiPlatformCatalog.ets:207`

**问题：** 目录是静态常量，但供应商模型会变动。例如仓库给 Groq 推荐 Llama 4 Maverick；截至本次核验，Groq 官方视觉文档列出的图像模型是 `qwen/qwen3.6-27b` 与 `qwen/qwen3.8-27b`。

**来源：** https://console.groq.com/docs/vision

**修改意见：** 给每条平台记录增加 `verifiedAt` 或为目录建立统一更新时间；发布前运行官方文档抽查。模型过期不应阻止用户手填，但推荐列表不能长期无版本信息。

## 3. 整改范围选择

### 方案 A：先修恢复性缺陷（推荐）

只修“权威状态未知时可离开”的 P1 问题，并补齐对应运行时合同测试。改动小、风险可控，直接保护草稿与证据恢复路径；其余问题保留为后续任务。

### 方案 B：一次修完三个 P1

同时修审核页守卫、平台能力字段、自定义地址身份。用户体验提升更完整，但会同时触及审核状态机、目录模型、设置页和测试，回归面明显更大。

### 方案 C：连同性能与目录刷新一起整改

包含全部 P1/P2。需要重新设计编辑持久化节流和平台目录维护机制，不适合作为本轮“先进行一个修改”的首批范围。

**推荐：选择方案 A。** 完成并验证后，再按“平台能力 → 自定义身份 → 导航反馈 → 编辑性能 → 目录刷新”的顺序分批处理。

## 4. 首轮修改的行为设计（方案 A）

状态规则：

1. `loadDraft()` 开始加载时不解除未知态。
2. 读取成功：应用权威快照，然后设置 `authoritativeStatePending = false`。
3. 读取失败：设置 `authoritativeStatePending = true`，保留当前可用快照但禁止修改、保存、丢弃和返回。
4. 用户点击“重新加载审核状态”：再次读取；成功后按新的 `saveStage` 决定允许放弃、继续保存或只允许返回。
5. 用户在未知态点击系统返回：页面消费返回事件，不导航；页面内返回按钮禁用，并保留明确的重新加载动作。

非目标：

- 不清理、不迁移、不重写现有审核会话。
- 不改变 Cloud/AI adapter 接口。
- 不改变保存幂等、账号绑定、证据图生命周期。
- 不修改 server/worker，也不为使脏树合同变绿而回退用户已有改动。

## 5. 方案 A 的测试驱动实施任务

### Task 1：用运行时测试锁定返回逃逸缺陷

**Files:**

- Modify: `entry/src/test/AiImportContracts.test.cjs`
- Test: `entry/src/test/AiImportContracts.test.cjs`

**Step 1: 添加失败测试**

- 在“authoritative-state reload”运行时测试中，调用 `returnToImportPage()` 后断言：
  - `calls.navigate === 0`
  - `calls.abandon === 0`
  - `authoritativeStatePending === true`
- 新增首次 `adapter.load()` 失败测试，断言进入未知态、返回不导航；随后 reload 成功，再断言状态解除。

**Step 2: 确认测试先红**

Run: `node --test entry/src/test/AiImportContracts.test.cjs`

Expected: 新增断言因当前 `returnToImportPage()` 调用了导航而失败。

### Task 2：最小化修复审核页状态机

**Files:**

- Modify: `entry/src/main/ets/pages/PdfImportReviewPage.ets`
- Test: `entry/src/test/AiImportContracts.test.cjs`

**Step 1: 修改加载失败状态**

在 `loadDraft()` 的 `catch` 中无条件设置 `authoritativeStatePending = true`，并给出统一的重新加载提示。

**Step 2: 修改返回守卫**

将未知态从“直接导航”的复合条件拆出：未知态只更新错误提示并返回；`session === null` 和不可放弃阶段继续按权威状态规则处理。

**Step 3: 禁用页面内返回按钮**

按钮 `.enabled(...)` 增加 `!this.authoritativeStatePending`。系统返回仍调用 `returnToImportPage()` 并被同一守卫拦截。

**Step 4: 运行定向测试**

Run: `node --test entry/src/test/AiImportContracts.test.cjs`

Expected: PASS。

### Task 3：回归与交付记录

**Files:**

- Modify: `docs/superpowers/plans/2026-09-12-software-review-and-remediation.md`

**Step 1: 客户端合同回归**

逐个运行 `entry/src/test/*.test.cjs`，不得因单文件失败停止；预期除已知 server 脏树守卫外无新增失败。

**Step 2: ArkTS 逐文件检查**

对 `entry/src/main/**/*.ets` 逐文件运行 checker；验收标准是 `0 errors / 0 internal / 0 unparsable`，并记录 warnings 数量及类别，不再把有警告写成 0 warnings。

**Step 3: 静态质量检查**

Run: `git diff --check`

Expected: exit 0。

**Step 4: 范围确认**

确认本轮生产代码只修改 `PdfImportReviewPage.ets`，测试只修改 `AiImportContracts.test.cjs`，并在本文件追加实际测试结果。

## 6. 后续任务队列

1. 为平台目录增加明确的视觉识别能力字段，禁用 `UNSUPPORTED` 项。
2. 修复自定义地址与 provider 身份不一致。
3. 给平台选择页路由失败增加可见反馈。
4. 设计审核页行级草稿和防抖持久化，并补离页 flush 测试。
5. 刷新 Groq 等动态模型目录，记录统一核验日期。
6. 修复或安全替换 `server/worker/.pytest-tmp` 的异常 ACL 后，重新得到 worker 全绿证据。
7. 在当前已连接的 API 24+ 设备上执行 HUKS 设备测试；若设备版本不足则记录准确原因。
8. 在用户提供真实六题 PDF、自有凭据并在应用内显式确认后执行真实 E2E；不得由自动化擅自发起收费调用。
9. 环境变化后只做一次有界 Hypium/debug build；若仍卡住，记录 daemon 日志和 NOT VERIFIED。
10. 回填旧计划的真实完成状态，删除 Task 13 过期叙述；不能把 NOT RUN / NOT VERIFIED 改写成 PASS。

## 7. 批准与执行记录

用户已于 2026-09-12 明确批准执行“方案 A：先修恢复性缺陷”。

### 7.1 TDD 红灯证据

- 只添加测试后运行 `node --test entry/src/test/AiImportContracts.test.cjs`。
- 结果：68 tests，66 passed，2 failed。
- 失败 1：权威状态未知时 `calls.navigate` 实际为 1，期望为 0。
- 失败 2：首次加载失败后 `authoritativeStatePending` 实际为 false，期望为 true。
- 两个失败都由待修行为造成，不是测试语法、装载或环境错误。

### 7.2 最小生产修改

- `loadDraft()` 失败后进入 `authoritativeStatePending = true`。
- `returnToImportPage()` 在未知态只提示重新加载，不再导航。
- 页面内“返回”按钮在未知态禁用；系统返回仍由同一方法守卫。
- 未修改 adapter、持久化格式、保存幂等、账号绑定、证据生命周期或 server/worker。

### 7.3 绿灯与回归证据

- 定向测试：`AiImportContracts.test.cjs` 为 68 passed / 0 failed。
- 全量客户端 CJS：37 文件，36 文件通过；278 tests，277 passed / 1 failed。
- 唯一失败仍为 `CloudCutoverContracts.test.cjs` 的 `server directory has zero uncommitted changes`；该断言打印的路径与审查前既有 server 脏树一致，本轮未为其改动或回退 server。
- ArkTS 逐文件检查：123 files，0 errors，261 warnings，0 internal，0 unparsable。
- `git diff --check`：exit 0。

### 7.4 本轮范围

本轮实际涉及：

- Production: `entry/src/main/ets/pages/PdfImportReviewPage.ets`
- Test: `entry/src/test/AiImportContracts.test.cjs`
- Documentation: `docs/superpowers/plans/2026-09-12-software-review-and-remediation.md`

方案 A 状态：**实现完成，合同测试与 ArkTS 静态检查范围内已验证；项目整体仍保留第 1 节列出的设备、真实 PDF、构建和 worker ACL 缺口。**
