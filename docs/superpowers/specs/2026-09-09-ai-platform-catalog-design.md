# AI 平台目录扩展设计（对齐 Cherry Studio 62 家）

**日期：** 2026-09-09
**状态：** 设计已确认，等待书面规格复核
**适用工程：** `G:\code\openHarmony\wrong_question_collection`

## 1. 目标

`AiRecognitionSettingsPage` 当前的 Provider 只有「OpenAI 官方」与「OpenAI-compatible 自定义」两项。本次把它扩展为对齐 Cherry Studio 官方 *Model Provider Directory*（62 家）的**平台目录**：用户选中平台后，API 地址自动填充，并给出该平台**支持图像输入**的推荐模型芯片，一次点选即可完成「平台 + 模型」配置。

不变的安全边界：API Key 仍只由 HUKS 保护、只在受限闭包内使用；`Authorization` 仍只由 `AiVisionTransport` 构造；不新增任何联网路径；换平台仍视为配置变更，已有 Key 时必须重新输入 Key。

## 2. 已确认的产品边界（用户决策，2026-09-09）

| 决策点 | 结论 |
|---|---|
| 目录范围 | **以 Cherry Studio 官方 62 家清单为基准，实际收录 61 家**（`cherryai` 查无公开官方 API，见附录 A.4） |
| 非直连平台 | **分三类接入能力**：`direct` 直连、`local_http` 本机 http、`gateway` 需自建兼容网关 |
| 模型补全 | 地址自动填 + **每平台 1–3 个视觉模型芯片**（点选填入 Model，仍可手输）；**不做** GET /models 联网拉取 |
| 选择器形态 | **独立选择页**（搜索 + 分类筛选 + 分组列表 + 平台标记） |
| 本期不做 | Azure `api-version`、Vertex/Bedrock 服务账号或 AK/SK、Copilot OAuth 的直连适配；远程目录；模型列表联网拉取 |
| 仓库约束 | 不提交、不 push、不建 PR；保留用户既有脏工作区 |

## 3. 方案选择

**采用：静态目录 + 三类接入能力。**

- 62 家以 ArkTS 常量表内置（`AiPlatformCatalog.ets`），每家声明分类、接入类型、默认 HTTPS 地址、视觉模型与官方文档链接。
- `direct` 平台选中即自动填地址，沿用现有 `HTTPS + Bearer + POST <base>/chat/completions` 传输层，无需改动网络协议。
- `local_http` 平台（Ollama / LM Studio / OpenVINO / GPUStack）允许 **仅本机与私网** 的 http 地址，并在页面强制显示风险提示。
- `gateway` 平台（Azure OpenAI / Vertex AI / AWS Bedrock / GitHub Copilot）只展示与说明，不写入伪造地址，引导用户改用「自定义」填写自建兼容网关。

**未采用：**

- **远程目录**（Cherry 式 registry）：免发版更新，但需要自建托管端点、新增一条联网路径并重做安全审查，本项目没有对应后端，且离线不可用。
- **最小改动（保留下拉框）**：改动最小，但 62 项无搜索与分类，手机端不可用，达不到参考截图的体验。
- **本期适配全部特殊鉴权**：Azure/Vertex/Bedrock/Copilot 需要新增多种密钥类型（服务账号 JSON、AK/SK、OAuth 设备流）与多套鉴权分支，工作量数倍且扩大密钥面，本设计明确排除。

## 4. 总体架构

```text
AiRecognitionSettingsPage（改造）
  ├─ 平台行 ──push──▶ AiPlatformPickerPage（新增）
  │                        └─ AiPlatformCatalog（新增，62 家静态目录）
  │                                ▲
  │      AiPlatformSelectionState.shared()（新增，选择结果回传单例）
  │                                │
  ├─ Base URL：自动填充只读；「自定义」开关后手输
  ├─ 模型芯片：AiPlatform.models → 点选填 Model
  ├─ AiProviderConfigStore（providerId 由枚举扩为 string，其余不变）
  └─ AiCredentialStore（HUKS，不变）
```

新增／修改文件：

| 文件 | 动作 |
|---|---|
| `entry/src/main/ets/models/ai/AiPlatformCatalog.ets` | 新增：目录数据 + 分类/接入类型 + 查询与筛选 |
| `entry/src/main/ets/utils/AiPlatformSelectionState.ets` | 新增：选择结果回传单例（对齐 `NavigationState.shared()`） |
| `entry/src/main/ets/pages/AiPlatformPickerPage.ets` | 新增：平台选择页 |
| `entry/src/main/ets/models/ai/AiProviderConfig.ets` | 修改：`providerId` 类型、校验器本机 http 例外、结构化输出标记 |
| `entry/src/main/ets/pages/AiRecognitionSettingsPage.ets` | 修改：平台行、地址自动填、模型芯片、风险/网关提示 |
| `entry/src/main/resources/base/profile/main_pages.json` | 修改：注册 `pages/AiPlatformPickerPage` |
| `entry/src/main/resources/base/profile/easy_go.json` | 修改：`fullScreenPages` 增加 `pages/AiPlatformPickerPage` |
| `entry/src/main/resources/base/profile/network_config.json` | 条件修改：仅当设备上本机/私网 http 被系统拦截时，显式放行明文流量（保持 `trust-global-user-ca`/`trust-current-user-ca` 为 `false`） |
| `entry/src/test/AiImportLocalUnit.test.ets` | 修改：目录与筛选单测 |
| `entry/src/test/AiImportContracts.test.cjs` | 修改：校验器 http 白名单、迁移、UI 合同 |
| `entry/src/test/Task9ResourceContracts.test.cjs` | 修改：`main_pages.json` 期望路由表 |

## 5. 数据模型

```ts
export enum AiPlatformCategory {
  DIRECT = 'direct',            // 模型原厂
  INFERENCE = 'inference',      // 推理平台
  AGGREGATOR = 'gateway',       // 聚合 & 转发（成员名避开与 AiPlatformAccess.GATEWAY 撞名）
  CLOUD = 'cloud',              // 云平台
  LOCAL = 'local'               // 本地部署
}

export enum AiPlatformAccess {
  DIRECT = 'direct',            // HTTPS + Bearer + /chat/completions 直连
  LOCAL_HTTP = 'local_http',    // 仅本机/私网 http
  GATEWAY = 'gateway'           // 本期不直连，需自建兼容网关
}

export class AiPlatformModel {
  readonly id: string           // 模型 ID（写入 Model 字段）
  readonly label: string        // 展示名
  readonly supportsVision: boolean
}

export class AiPlatform {
  readonly id: string           // 稳定语义化平台 ID；与 Cherry 目录 ID 的映射见附录 A.4
  readonly nameZh: string
  readonly nameEn: string
  readonly category: AiPlatformCategory
  readonly access: AiPlatformAccess
  readonly baseUrl: string      // direct/local_http 为可直连地址；gateway 为空串
  readonly models: Array<AiPlatformModel>   // 1–3 个视觉模型
  readonly note: string         // 风险/网关说明；无则为空串
  readonly docsUrl: string      // 官方文档出处
}
```

`AiPlatformCatalog` 提供：`all()`、`find(id)`、`search(keyword)`（大小写不敏感，匹配 `id/nameZh/nameEn`）、`byCategory(category)`、`count()`。

**数据准确性规则：** 每家地址与模型必须来自官方文档，目录条目携带 `docsUrl`；研究阶段查不到的平台标 `access = GATEWAY` 并在 `note` 说明，**不猜测 URL**。

**视觉能力规则：** `access` 只表达**传输可达性**，视觉能力由 `models` 与 `note` 表达：

- `direct` / `local_http`：能用现有 `HTTPS/本机 http + Bearer + /chat/completions` 触达。
- `gateway`：单个静态 Key 无法触达（OAuth 短期 token、SigV4、`api-version` 查询参数、OAuth 设备流），或官方 API 地址未能取证。
- 目录尽量为每家列出**官方已确认支持图像输入**的模型；未获确认时 `models` 允许为空，UI 显示「未确认视觉模型，请手动填写」。
- 官方明确**不支持**图像输入或本业务用不上的平台（如 LongCat 官方声明仅文本、SophNet 的视觉模型是生成式、VoyageAI 只有嵌入/重排）保留在目录中但 `note` 必须写明「不支持题目识别」，且 `models` 为空。目前仅 `longcat`、`baichuan`、`sophnet` 三家属于此类；`jina` 有官方 OpenAI 兼容的视觉模型（`jina-ocr-v1`、`jina-vlm`），按直连处理。

**每平台额外请求头：** 本设计**不引入** per-provider 自定义头（如 AiHubMix 的 `APP-Code` 归因头是可选、TokenFlux 亦接受 Bearer）。传输层继续只发送 `Authorization: Bearer` 与 `Content-Type: application/json`，避免扩大 Header 注入面；确有需要时再单独设计。

## 6. 配置模型与校验器变更

1. `AiProviderConfig.providerId`：`AiProviderId` 枚举 → `string`。
   - 保留 `AiProviderId.OPENAI = 'openai'`、`AiProviderId.CUSTOM = 'openai_compatible'` 两个常量用于兼容与「自定义」分支。
   - 目录平台的 `providerId` 即平台 `id`（如 `deepseek`、`siliconflow`）。
2. `supportsStructuredOutput`：保持现有语义，仅当 `providerId === AiProviderId.OPENAI` 时为 `true`，其余平台（含全部目录平台）一律 `false`。目录**不新增**该字段——当前没有任何平台被证实需要它，避免引入未验证的假设；将来若某平台确认支持，再单独设计。
3. `AiProviderConfigValidator.normalize()` 校验规则：
   - `model` 去空格后长度 1–200，否则 `MISSING_MODEL`。
   - 解析失败、`username`/`password`/`search`/`hash` 非空、路径以 `/chat/completions` 结尾 → `INVALID_BASE_URL`（**保持不变**）。
   - `https:` → 允许（**保持不变**）。
   - `http:` → **仅当主机属于本机或私网白名单**时允许：`localhost`、`127.0.0.0/8`、`::1`、`10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16`；其余一律 `INVALID_BASE_URL`。
   - 归一化仍去掉末尾 `/`、保留 origin + path。
4. `AiProviderConfigStore.loadLocked()`：不再把非 `openai` 的 id 一律折叠为 `CUSTOM`；保留持久化的字符串 id。读取到目录中不存在的 id 时**不报错、不清空**，在设置页按「自定义」展示并允许用户重新选择平台。

## 7. UI 设计

### 7.1 AI 识别设置页（改造）

```text
AI 视觉识别（推荐）
平台            [ 深度求索 DeepSeek        ▸ 切换 ]      ← 打开选择页
API 地址        https://api.deepseek.com/v1            ← 自动填充，只读
                [ 自定义 ]                              ← 打开后可编辑
                ⚠ 本机 http 提示（仅 local_http 平台显示）
推荐视觉模型     [ deepseek-v4-flash-vision-exp ] [ … ]  ← 芯片，点选填 Model
Model           [ 手输或由芯片填入 ]
API Key         [ 已配置/未配置 ] [ 输入新 Key ] [ 显示本次输入]
[ 保存设置 ]  [ 清除 API Key ]  [ 测试连接 ]
```

- 平台行显示当前平台中文名；未匹配目录的旧配置显示「自定义」。
- 地址自动填充后默认只读，点「自定义」才可编辑（`gateway` 平台强制进入自定义并要求手填）。
- 风险提示与网关说明使用 `AiPlatform.note`，样式沿用 `themePalette` 的 warning/error token。
- `pending` 期间所有可交互控件禁用（沿用现有规则）。

### 7.2 平台选择页（新增）

```text
[ 返回 ] 选择 AI 平台
[ 搜索平台… ]
[ 全部 ] [ 模型原厂 ] [ 推理平台 ] [ 聚合转发 ] [ 云平台 ] [ 本地部署 ]
────────────────────────────────────────────
  CherryIN              [视觉]
  硅基流动 SiliconFlow   [视觉]
  PPIO 派欧云            [视觉]
  Azure OpenAI          [需自建网关]
  Ollama                [本机]
  …
```

- **列表形态（2026-09-09 落地确认）**：采用**扁平列表 + 顶部分类筛选条 + 搜索框**，而非按分类插入分组标题。理由：手机上 61 条一次性可滚动更顺，分类筛选条已提供同等导航能力（Cherry Studio 的平台列表本身也是扁平列表），且避免分组标题在筛选态下产生空组。每行右侧标记：`[视觉]`＝有视觉模型、`[本机]`＝`local_http`、`[需自建网关]`＝`gateway`、`[未确认视觉模型]`＝`direct/local_http` 且 `models` 为空。
- 选中 `direct`/`local_http`：写入 `AiPlatformSelectionState.shared()` 选中 id → `router.back()`；设置页 `onPageShow` 以 **peek → 判空/`pending` 守卫 → take** 的顺序读取并应用（地址 + 芯片 + 风险提示），并清空旧的 Model 值。
- **平台行 no-op 语义（2026-09-09 落地确认）**：重选「当前已应用」的平台不重置表单，避免清空用户尚未保存的模型/手填地址；判据是最近一次应用的**目录 id**（恒小写），不是持久化字符串。例外：`gateway` 平台保存后持久化的是 `openai_compatible`，重进设置页显示「自定义」、平台归属已被刻意遗忘，此时再选同一 gateway 属**全新选择**（会重置表单），持久化配置不受损——这是接受的设计语义，不额外持久化来源平台。
- **明文风险提示判据（2026-09-09 落地确认）**：按**实际地址**前缀 `http://` 判定（`trim` + 小写后），不按目录 `access`；平台 `note` 恒用 `caption` 色。
- 选中 `gateway`：设置页展示 `note` 说明并进入自定义输入，不写入任何伪造地址。
- 搜索无结果时显示空态提示。

## 8. 安全与隐私

- 目录数据是纯静态常量：不含任何密钥、Token、账号、用户数据；合同测试断言目录文件中不存在真实密钥形态（`sk-` 长串、`Authorization:` 头、超长 Bearer 串）与 `Authorization` 构造。**注意**：`note` 里出现「api-key 头」「Bearer 鉴权」这类**鉴权方式说明文字**属正常内容，负断言不得误伤（扫描只针对真实密钥形态，不针对这些词）。
- 新增联网路径：**零**。模型芯片是本地数据，不触发 `GET /models`。
- API Key 流程不变：Key 只进 HUKS；`Authorization` 只由 `AiVisionTransport` 构造；测试连接仍需先保存配置。
- 换平台＝配置变更 → 已有 Key 时必须重新输入 Key（`REPLACEMENT_KEY_REQUIRED`），避免旧 Key 被发往新端点。
- http 放宽是本设计唯一的安全面变更：仅白名单地址可通过校验，且 UI 必须显示风险提示；公网 http 仍被合同测试锁死为拒绝。
- `gateway` 平台不提供地址，用户改用「自定义」时仍需通过同一套 HTTPS/白名单校验。

## 9. 测试策略

**ArkTS 单测（`AiImportLocalUnit.test.ets`）**

1. 目录完整性：条目数＝61；`id` 唯一；`nameZh` 非空。
2. `direct` 条目地址均为 `https:` 且不含 query/fragment/userinfo。
3. `local_http` 条目地址均为 http 且主机在本机白名单内。
4. `gateway` 条目地址为空串且 `note` 非空。
5. 每个 `direct`/`local_http` 条目：若 `models` 非空则至少一个 `supportsVision = true`；`models` 为空时 `note` 必须说明「未确认视觉模型」或「不支持题目识别」；官方明确不支持图像输入的条目（LongCat 等）必须带「不支持题目识别」说明。
6. `search()` 大小写不敏感、可命中中英文名；`byCategory()` 过滤正确；未命中返回空数组。
7. 校验器：https 通过；公网 http 拒绝；`127.0.0.1`/`localhost`/`192.168.x`/`10.x`/`172.16-31.x` 通过；`172.32.x`（超出私网段）拒绝。
8. 配置迁移：旧的 `providerId='openai'` 与 `'openai_compatible'` 仍可加载；目录 id 可往返；未知 id 不丢失。

**CJS 合同（`AiImportContracts.test.cjs` 等）**

1. 目录常量文件存在且条目数、字段结构符合规格；不含密钥/Authorization。
2. 校验器新增本机 http 白名单用例与公网 http 拒绝用例（负断言）。
3. 设置页合同：包含平台行、跳转选择页、模型芯片渲染、风险提示分支；不再硬编码两家 Provider 按钮。
4. 选择页合同：搜索框、分类筛选、三种标记、`AiPlatformSelectionState` 回传、`router.back()`。
5. `AiProviderConfigStore.loadLocked` 不再折叠未知 id（源码级断言 + 行为级断言）。
6. `Task9ResourceContracts`：`main_pages.json` 期望路由加入 `pages/AiPlatformPickerPage`。
7. `AiImportContracts` 首个设置页合同：标签清单随新 UI 更新（`平台`/`API 地址`/`推荐视觉模型`/`自定义`/`测试连接` 等），并断言选择页路由在 `main_pages.json` 与 `easy_go.json fullScreenPages` 中各注册一次。

**回归基线**

- 全量 36 个 CJS 文件：**失败文件仍仅 `CloudCutoverContracts`（总失败数 = 1）**；用例总数会随本功能每个 Task 递增（Task 1 前 268，Task 3 后 270+），故门禁按「失败文件/失败数」判定，不按 pass 绝对数。
- ArkTS 静态检查**必须逐文件**执行：`arkts-check.cjs --project .` 在 2026-09-09 被实测为**假绿**——checker 内部异常被脚本 `try/catch` 吞掉后仍输出 `success:true / 0 errors`（多文件批量同样会整批丢诊断）。可信命令为 `node .../arkts-check.cjs --project . --files <相对路径>`，逐文件累加 `errorCount`；warning 属既有历史项（如 `getContext` 弃用），不要求归零，但不得因本功能新增。2026-09-09 全项目逐文件基线：120 个 `.ets`，真实 error 仅 `AiProviderConfigStore.ets:124`（Task 2 的预期中间态，Task 3 修复），其余 0 error。
- **该工具的已知盲区（2026-09-09 实测）**：`--files` 对**不存在的路径**也返回 `success:true / 0 errors`（不做存在性校验），且**不解析跨模块 import**；更严重的是全项目 122 个 `.ets` 中约 **40 个会让 DevEco 的 `ets_checker` 抛 `TypeError: Cannot read properties of undefined (reading 'some')`**（`api_validate_node.js` 的 `WhiteListValidator.hasApiFileName`），脚本吞掉异常后**连单文件模式也报 0/0** —— 这些文件的「0」不构成证据。因此必须配合**阳性对照**：临时向目标文件注入 `const probeUntypedLiteral = { value: 1 };`，应报 `arkts-no-untyped-obj-literals`，随后还原并校验文件哈希。
  **2026-09-09 阳性对照结论**：本功能改动的 7 个文件（`AiPlatformCatalog.ets`、`AiProviderConfig.ets`、`AiProviderConfigStore.ets`、`AiPlatformSelectionState.ets`、`AiPlatformPickerPage.ets`、`AiRecognitionSettingsPage.ets`、`AiVisionTransport.ets`）**全部通过阳性对照**，其 0 error 可信；40 个假绿文件均为本功能未触碰的既有文件。
  **例外（Task 6 实测）**：`PdfAiImportSetupPage.ets` **属于假绿集合**——注入未类型化对象字面量、甚至注入语法错误都返回 `errorCount: 0`（原始输出仅含 `TypeError … reading 'some'`）。该文件本次被修改（Provider 文案改为目录查表），其「0 error」**不作为证据**；替代证据是「同形态镜像文件可被正常分析且报出探针错误」。该文件的改动正确性依赖 CJS 合同与人工复审。
- 逐文件扫描只能证明「每个已存在文件自身 lint 干净」，**不能**证明 import 可解析或跨文件类型一致；后者在本环境（hvigor 卡死）属 `NOT VERIFIED`，由 CJS 合同与人工复审兜底。

## 10. 任务边界（供 writing-plans 展开）

1. 目录数据文件 `AiPlatformCatalog.ets`（61 家，含分类/接入/地址/视觉模型/出处）＋ 单测。
2. 配置模型与校验器改造（providerId 字符串化、本机 http 白名单、结构化输出标记）＋ 单测/CJS 合同。
3. `AiProviderConfigStore` 兼容改造（未知 id 不折叠）＋ 合同。
4. 选择结果回传单例 `AiPlatformSelectionState`＋ 合同。
5. 平台选择页 `AiPlatformPickerPage`（搜索/分类/标记/空态）＋ 合同与路由注册。
6. 设置页改造（平台行、地址自动填与自定义、模型芯片、风险/网关提示）＋ 合同。
7. 全量回归：CJS 全跑、ArkTS checker、（设备相关项按环境如实标 NOT RUN）。

## 11. 风险与缓解

| 风险 | 缓解 |
|---|---|
| 62 家端点/模型随时间变化 | 目录携带 `docsUrl`；模型仅作建议，Model 始终可手输；数据随版本更新 |
| 研究阶段查不到官方地址 | 标 `GATEWAY` 并写明原因，绝不猜测 URL |
| http 放宽被误用 | 白名单收敛到本机/私网 + 合同负断言 + UI 风险提示 |
| 旧配置被破坏 | `loadLocked` 保留原始 id，未知 id 降级为自定义展示，不清空数据 |
| 平台 id 与业务语义混淆 | 平台 id 只影响目录选择与展示；传输层行为仍由 `access` 与校验器决定 |

## 附录 A：61 家平台目录

目录以 Cherry Studio 官方 *Model Provider Directory*（62 家 ID 与分类）为清单基准，逐家按下列字段取证后写入 `AiPlatformCatalog.ets`。**未取证不猜测**：查不到官方地址或鉴权不满足单静态 Key 的平台一律 `gateway`。

字段：`id` / 名称 / 分类 / 接入 / 默认地址 / 鉴权 / 视觉模型（示例）/ 出处。
`access` 取值：`direct`＝HTTPS+Bearer 直连；`local_http`＝仅本机/私网 http；`gateway`＝本期不直连。

### A.1 直连平台（`direct`：HTTPS + Bearer + `POST <base>/chat/completions` + 无 query）

| id | 名称 | 分类 | 默认地址 | 视觉模型（官方取证） | 备注 |
|---|---|---|---|---|---|
| `openai` | OpenAI | 模型原厂 | `https://api.openai.com/v1` | `gpt-6-astra`、`gpt-5.6-sol` | 唯一 `supportsStructuredOutput = true` |
| `anthropic` | Anthropic Claude | 模型原厂 | `https://api.anthropic.com/v1` | `claude-opus-5`、`claude-sonnet-5`、`claude-haiku-4-5` | 官方 OpenAI 兼容层 |
| `gemini` | Google Gemini | 模型原厂 | `https://generativelanguage.googleapis.com/v1beta/openai` | `gemini-3-flash`、`gemini-3.1-pro-preview` | 官方 OpenAI 兼容层 |
| `deepseek` | 深度求索 DeepSeek | 模型原厂 | `https://api.deepseek.com` | `deepseek-v4-flash-vision-exp` | 每图计费上限 384 tokens，整页小字需先裁题 |
| `xai` | xAI Grok | 模型原厂 | `https://api.x.ai/v1` | `grok-4.6`、`grok-4.5` | 各模型页 Modalities: text,image→text |
| `nvidia-nim` | 英伟达 NIM | 云平台 | `https://integrate.api.nvidia.com/v1` | `meta/llama-3.2-11b-vision-instruct`、`nvidia/nemotron-nano-12b-v2-vl` | 自托管形态走 `http://<host>:8000/v1`（gateway 分类） |
| `cerebras` | Cerebras | 推理平台 | `https://api.cerebras.ai/v1` | `qwen-3.8-27b` | 仅 base64 data URI、≤10 MiB、免费档 ≤2 图/请求 |
| `zhipu` | 智谱 BigModel | 模型原厂 | `https://open.bigmodel.cn/api/paas/v4` | `glm-5.3-flash`、`glm-4.6v` | 官方：一次请求不要混放文件/视频/图片 |
| `moonshot` | 月之暗面 Kimi | 模型原厂 | `https://api.moonshot.cn/v1` | `kimi-k3`、`kimi-k2.6` | **不支持 URL 图片**，必须 base64；旧 vision 模型已下线 |
| `bailian` | 阿里云百炼 | 云平台 | `https://dashscope.aliyuncs.com/compatible-mode/v1` | `qwen3.8-max`、`qwen3.5-ocr` | 新域名含 `{WorkspaceId}` 占位，继续用旧域名 |
| `stepfun` | 阶跃星辰 StepFun | 模型原厂 | `https://api.stepfun.com/v1` | `step-3.7-flash`、`step-1o-turbo-vision` | 勿用 `/step_plan/v1`（不支持图像） |
| `volcengine-ark` | 豆包 / 火山方舟 | 云平台 | `https://ark.cn-beijing.volces.com/api/v3` | `doubao-seed-2-1-pro-260628`、`doubao-seed-1.6-vision` | Bearer 下可直接填模型名，无需 `ep-xxxx` |
| `infini` | 无问芯穹 | 云平台 | `https://cloud.infini-ai.com/maas/v1` | `deepseek-ocr-2`（PDF→Markdown） | 仅 base64、单文件 ≤5 MiB；路径是 `/maas/v1` |
| `minimax` | MiniMax | 模型原厂 | `https://api.minimax.io/v1`（国内 `https://api.minimax.cn/v1`） | `MiniMax-M3` | 国内外端点二选一 |
| `hunyuan` | 腾讯混元 | 云平台 | `https://api.hunyuan.cloud.tencent.com/v1` | `hunyuan-vision`、`hunyuan-turbos-vision` | 新 TokenHub：`https://tokenhub.tencentmaas.com/v1` |
| `qianfan` | 百度千帆 | 云平台 | `https://qianfan.baidubce.com/v2` | `ernie-4.5-turbo-vl-preview` | Bearer（Key 形如 `bce-v3/ALTAK-…`） |
| `modelscope` | 魔搭 ModelScope | 推理平台 | `https://api-inference.modelscope.cn/v1` | `Qwen/Qwen3-VL-235B-A22B-Instruct`、`OpenGVLab/InternVL3_5-241B-A28B` | 出处为官方组织仓库（文档站是空壳 SPA） |
| `huggingface` | Hugging Face Router | 推理平台 | `https://router.huggingface.co/v1` | `zai-org/GLM-4.5V`、`Qwen/Qwen2.5-VL-3B-Instruct` | 需 fine-grained token |
| `jina` | Jina AI | 模型原厂 | `https://api.jina.ai/v1` | `jina-ocr-v1`（文档→Markdown）、`jina-vlm` | 对扫描版数学 PDF 对口 |
| `siliconflow` | 硅基流动 | 聚合转发 | `https://api.siliconflow.cn/v1` | `Qwen/Qwen3-VL-32B-Instruct`、`deepseek-ai/DeepSeek-OCR` | 多图与 PDF base64 |
| `dmxapi` | DMXAPI | 聚合转发 | `https://www.dmxapi.cn/v1`（国际 `https://www.dmxapi.com/v1`） | `gpt-4o`、`gemini-2.5-flash`、`doubao-1.5-vision-pro-250328` | 官方逐字给出 base64 `image_url` |
| `ppio` | PPIO 派欧云 | 聚合转发 | `https://api.ppio.com/openai/v1` | 未查证（官方有视觉语言模型专章，模型清单未渲染） | — |
| `fireworks` | Fireworks AI | 推理平台 | `https://api.fireworks.ai/inference/v1` | `accounts/fireworks/models/qwen3-vl-235b-a22b-instruct` | 官方有 PDF 逐页 base64 多图范例 |
| `together` | Together AI | 推理平台 | `https://api.together.xyz/v1` | `MiniMaxAI/MiniMax-M3` | Vision + OpenAI 兼容 |
| `openrouter` | OpenRouter | 聚合转发 | `https://openrouter.ai/api/v1` | `厂商/模型`（按实时列表） | 额外头可选，不需配置 |
| `aihubmix` | AiHubMix | 聚合转发 | `https://aihubmix.com/v1`（备 `https://api.aihubmix.com/v1`） | `gemini-3.1-pro-preview` | `APP-Code` 头可选，本设计不引入 |
| `cherryin` | CherryIN | 聚合转发 | `https://open.cherryin.net/v1` | 未查证 | 模型名必须带 `厂商/` |
| `302ai` | 302.AI | 聚合转发 | `https://api.302.ai/v1`（大陆 `https://api.302ai.com/v1`） | `gpt-4o-mini` | — |
| `tokenflux` | TokenFlux | 聚合转发 | `https://tokenflux.ai/v1` | `openai/gpt-4o` | Bearer 已确认 |
| `qiniu` | 七牛云 | 聚合转发 | `https://api.qnaigc.com/v1` | 模型广场多模态（ID 逐字一致） | 单次消息体 ≤50 MB |
| `alayanew` | 九章智算云 | 聚合转发 | `https://token.alayanew.com/v1` | 未查证 | — |
| `burncloud` | BurnCloud | 聚合转发 | `https://ai.burncloud.com/v1` | OpenAI 通道视觉未证实 | 有 base64 证据的是 Gemini 原生通道 |
| `vercel-ai-gateway` | Vercel AI Gateway | 聚合转发 | `https://ai-gateway.vercel.sh/v1` | `anthropic/claude-sonnet-5` | 模型名须 `provider/model` |
| `groq` | Groq | 推理平台 | `https://api.groq.com/openai/v1` | `meta-llama/llama-4-maverick-17b-128e-instruct` | ⚠️ `llama-4-scout` 已排期弃用 |
| `hyperbolic` | Hyperbolic | 推理平台 | `https://api.hyperbolic.xyz/v1` | 未查证 | base URL 来自 LiteLLM 官方文档 |
| `poe` | Poe | 推理平台 | `https://api.poe.com/v1` | 未查证（bot 名） | base URL 来自 LiteLLM 官方文档 |
| `ocoolai` | ocoolAI | 聚合转发 | `https://one.ocoolai.com/v1` | 未查证 | — |
| `ph8` | PH8 | 聚合转发 | `https://ph8.co/v1` | 未查证 | — |
| `lanyun` | 蓝耘 LANYUN | 聚合转发 | `https://maas-api.lanyun.net/v1` | 未查证（官方自相矛盾） | 鉴权按 Bearer 处理 |
| `baichuan` | 百川智能 | 模型原厂 | `https://api.baichuan-ai.com/v1` | **无**（content 仅 text/file） | 不支持题目识别 |
| `sophnet` | SophNet 算能云 | 聚合转发 | `https://www.sophnet.com/api/open-apis` | **无**（视觉模型是生成式） | 不支持题目识别 |
| `longcat` | LongCat 龙猫 | 聚合转发 | `https://api.longcat.chat/openai/v1` | **无** | 官方原文「仅支持文本输入」 |

### A.2 本机 / 私网平台（`local_http`）

| id | 名称 | 默认地址 | 视觉模型（官方） | 备注 |
|---|---|---|---|---|
| `ollama` | Ollama | `http://localhost:11434/v1` | `qwen3-vl`、`gemma4`、`glm-ocr` | 无鉴权，Key 可填占位符 |
| `lmstudio` | LM Studio | `http://localhost:1234/v1` | 取决于本地加载的 VLM | 默认无鉴权，可选 Token |
| `ovms` | OpenVINO Model Server | `http://localhost:8000/v1` | 取决于部署的 VLM | REST 8000 / gRPC 9000；另文档化 `/v3` |
| `gpustack` | GPUStack | `http://localhost/v1-openai` | 取决于部署的 VLM | 默认端口 80；`/v1-openai` 是主路径 |
| `new-api` | New API（自建网关） | `http://localhost:3000/v1` | 取决于上游渠道 | 自建网关，地址按部署自行修改 |

> `local_http` 四/五家均为明文 HTTP + 非标准端口，且默认无鉴权。HarmonyOS 侧若拦截明文流量，需在 `network_config.json` 显式放行（仅本机/私网），计划中列为条件步骤。

### A.3 需自建网关 / 本期不直连（`gateway`）

| id | 名称 | 原因 |
|---|---|---|
| `azure-openai` | Azure OpenAI | 新版 `https://<资源名>.openai.azure.com/openai/v1` 无 query 且接受 `api-key`/Bearer，但含资源名占位；经典形态 `?api-version=` 被校验器拒 → 走「自定义」，模型芯片保留（`gpt-5.6-sol`、`gpt-5.6-terra`、`gpt-5.5`、`gpt-4.1`，出处 learn.microsoft.com） |
| `vertexai` | Google Vertex AI | 唯一鉴权是 OAuth 短期 token（1 小时过期），非静态 Key |
| `aws-bedrock` | AWS Bedrock | Bedrock API key 可走 Bearer，但地址含 `<区域>` 占位 → 走「自定义」 |
| `copilot` | GitHub Copilot | REST 仅席位/用量/策略管理，无公开推理端点 |
| `github-models` | GitHub Models | **已于 2026-07-30 整体下线**（官方建议迁 Azure AI Foundry） |
| `perplexity` | Perplexity | 旧 Sonar 为 `POST /v1/sonar` 且仅支持到 2026-09-27；唯一 `/chat/completions` 形态是私测白名单的 Router API |
| `mistral` | Mistral AI | 报文结构不同：`image_url` 是**字符串**而非 `{url: …}` 对象，需传输层单独改写 → 本期不直连；Pixtral 系列已退役 |
| `mimo` | 小米 MiMo | 官方示例用 `api-key` 头而非 Bearer；vision 仅 `mimo-v2.5`（旗舰 pro 不支持） |
| `tencent-ti` | 腾讯云 TI-ONE | 平台 API 强制 TC3-HMAC-SHA256 签名，与 Bearer 传输层不兼容 |
| `yi-01ai` | 零一万物 01.AI | **平台正在停服**（2026-08-03 公告，实测 `/v1/models` 返回 410 Gone）；可改用百炼托管的 Yi 系列 |
| `voyageai` | VoyageAI | 仅 embeddings/rerank，无 chat 端点 |
| `xirang` | 商汤息壤 | 未找到官方 OpenAI 兼容端点；商汤现行平台为 SenseNova（`https://token.sensenova.cn/v1`，可用「自定义」接入） |
| `aionly` | AIOnly | 官方 base URL 未查证（其 API 主机不提供公开文档） |
| `cephalon` | 端脑云 Cephalon | 官方 API 文档未查证（`/api` 为应用市场页） |

### A.4 与 Cherry 目录的差异说明

- **`cherryai` 不入目录**：多轮中英文检索均未找到名为 CherryAI 的公开官方 API 平台（只命中开源客户端 Cherry Studio 与 `cherryin`）。目录条目数因此为 **61**（62 − 1）。若业务方确认其域名，再单独补入。
- **`github-models`、`yi-01ai` 保留条目但标注不可用/停服**，避免用户误配；`mistral`、`mimo`、`tencent-ti` 归入 `gateway`（需协议/鉴权改造），后续版本再评估。
- **结构化输出**：仅 `openai` 声明 `supportsStructuredOutput = true`；其余平台一律 `false`，解析端保持「一层完整 JSON fence + 严格 JSON」的容错策略（SiliconFlow 官方明确 VL 模型可能不支持 `json_object`）。
- **模型名不做跨平台规范化**：`厂商/模型`（CherryIN/OpenRouter/Vercel）、平台前缀（SiliconFlow `Pro/…`、Fireworks `accounts/fireworks/models/…`、七牛云逐字一致、Groq 自带厂商斜杠）、裸名（DMXAPI/BurnCloud/PH8/Poe）三套并存，芯片数据按平台独立存储。
- **ID 口径**：目录采用语义化稳定 ID；与 Cherry 官方 ID 的对应关系为
  `bailian`=`dashscope`、`xai`=`grok`、`nvidia-nim`=`nvidia`、`github-models`=`github`、`tencent-ti`=`tencent-cloud-ti`、`qianfan`=`baidu-cloud`、`yi-01ai`=`yi`、`volcengine-ark`=`doubao`、`vercel-ai-gateway`=`gateway`、`siliconflow`=`silicon`。
  其余 ID 与 Cherry 一致；`openai_compatible`（自定义）沿用旧值不变。
- **`docsUrl` 取值**：附录表格未单列出处列，实现时按「官方文档页优先、缺失则官方域名首页」取值，并对可达性做了实测（本网络可达的 33 条为 HTTP 200；Gemini/Vertex/HuggingFace/Mistral/Perplexity/VoyageAI/xAI/Jina/Poe/Hyperbolic/AiHubMix/302.AI/BurnCloud 等 12 条因本机网络封锁未能实测，域名取自各家公认官方文档站）。目录中的 `docsUrl` 仅作跳转导航，不是数据校验依据。
- **非模型 ID 的「视觉模型」列**：`openrouter`（`厂商/模型` 实时列表）、`qiniu`（须与模型广场逐字一致）以及 `lmstudio`/`ovms`/`gpustack`/`new-api`（取决于本地部署或上游渠道）不写成芯片，`models` 留空并在 `note` 注明「未确认视觉模型，请手动填写」。
- **不支持图像识别的平台**（`longcat`/`baichuan`/`sophnet`）`models` 留空，`note` 必须写明「不支持题目识别」及原因；不提供无视觉能力的文本模型芯片。
- **未查证项**（保持 `models` 为空 + UI 提示手动填写）：CherryIN、PPIO 视觉模型 ID、Hyperbolic、Poe、ocoolAI、PH8、蓝耘、302.AI 的完整视觉清单、AiHubMix 模型清单。

## 附录 B：后续可选能力——联网获取模型列表（本期未做）

用户在 2026-09-09 明确选择「地址自动填 + 视觉模型芯片，**不做** `GET /models` 联网拉取」，故本期零新增联网路径。后续若要做，调研已给出可直接落地的结论：

**可行性**（本机无鉴权探测）：绝大多数 OpenAI 兼容平台的 `GET {base}/models` 存在且返回 401/403（端点存在、需鉴权）；`modelscope` 与 `nvidia-nim` 实测 **200 免鉴权**（可在用户填 Key 前预置展示）；`qianfan`、`cerebras`、`anthropic` 返回 403。本地四家（Ollama/LM Studio/OVMS/GPUStack）与 New API 都支持 `/v1/models`（GPUStack 必须用 `/v1-openai/models`）。

**三个硬约束**：
1. **列表不表达视觉能力**：OpenAI 规范只返回 `id/object/created/owned_by`；唯一例外是 Anthropic（响应含 `capabilities`）。其余平台仍需本地「推荐视觉模型」白名单打标——正是附录 A.1 已交付的那一列。
2. **`model` 字段语义各家不同**：Azure 填部署名；Vertex/Bedrock 没有 OpenAI 形态的 `/models`；火山方舟 AK/SK 场景需 `ep-xxxx`；GPUStack 路径是 `/v1-openai/models`。
3. **列表含大量无关/退役/不可调用模型**（如 Moonshot 旧 ID 已下线、百川列表无可用视觉模型）。

**建议的三层设计**：① 校验层——用 `/models` 的 200/401/403 做「测试连接」（不计费），**404 不得判为密钥无效**（可能是该家没有 `/models`）；② 导入层——`列表 ∩ 本地能力白名单`，默认只展示打标为视觉的模型，其余收进「显示全部」，白名单里有而列表里没有的单独提示；③ 兜底层——内置 curated 清单（本期目录），覆盖无 `/models` 的平台与离线场景。

## 附录 C：实施记录（2026-09-09 完成）

7 个任务全部完成并通过双审（Task 1–6 + 6B，Task 7 全量回归）。最终验证：

- 全量 36 个 CJS：`276 tests / 275 pass / 1 fail`，唯一失败为既有 `CloudCutoverContracts` 的 server 脏树守卫。
- ArkTS：122 个 `.ets` 逐文件扫描 **0 error**；7 个改动文件全部通过**阳性对照**（注入探针必报 `arkts-no-untyped-obj-literals`）。
- 变异实验覆盖：平台 id 折叠回归、白名单放宽/收紧、`http` 前缀伪装主机、no-op 守卫、明文判据、transport 重复白名单、锚点断言顺序等，均被断言捕获。
- **未验证**：设备上明文 http 是否需放行（`network_config.json` 未被引用，属条件步骤）、真机布局/深色主题观感、Hypium 设备套件（环境无设备且 hvigor 卡死）。
- 未提交、未 push、未建 PR；`server/` 零改动；用户既有脏工作区完整保留。
