# 客户端直连多模态 AI 识别数学 PDF 设计

**日期：** 2026-09-05  
**状态：** 设计已确认，等待书面规格复核  
**适用工程：** `G:\code\openHarmony\wrong_question_collection`

## 1. 目标

HarmonyOS 客户端允许用户配置自己的 OpenAI-compatible 多模态 AI。应用在设备端把 PDF 逐页渲染为受限尺寸的图片，直接请求用户选择的 AI Provider，校验严格 JSON 并生成包含 KaTeX 兼容 LaTeX 的题目草稿。用户继续在现有 `PdfImportReviewPage` 中查看原题图片、审核、编辑和保存，审核后的普通题目数据使用现有业务同步能力写入服务端。

API Key 必须始终处于设备安全边界内：不上传业务服务器、不进入数据库或同步数据、不进入日志、异常、埋点、调试输出、Prompt、路由参数或剪贴板。现有服务端 PaddleOCR 及 Worker 代码保留作为代码级回滚能力，但正式 PDF 导入入口只提供 AI 视觉识别，AI 失败时绝不调用或自动回退到 OCR。

## 2. 已确认的产品边界

- 正式界面不显示旧服务端 PaddleOCR 选项。
- “导入 PDF”始终进入客户端 AI 流程。
- 旧 `PdfImportSetupPage`、`PdfImportProgressPage`、`CloudImportService`、`CloudImportApi` 和 `server/worker` 保留，不由正式入口触达。
- 不新增 AI 业务服务端接口，不伪造 cloud import job，也不把客户端 AI 草稿提交给旧 `/v1/imports/pdf/:jobId/confirm`。
- 审核后的题目文字继续通过现有 `/v1/sync/push` 保存；原题图片继续只保存在创建导入的设备。
- 复用现有 `PdfImportReviewPage`、题目编辑、`MathContentView`/KaTeX、题库浏览、云同步、Auth、EasyGo、HdsTabs 和 SDK 配置。
- 不修改现有 piecewise、radical、inline anchoring 或 OCR geometry 算法。
- 不删除或覆盖当前工作区的未提交改动。

## 3. 方案选择

采用“AI 独立管线 + 双源审核适配器”。AI 设置、凭据、Provider 请求、Prompt、解析、页面调度和保存分别隔离；审核页只依赖统一审核模型和提交接口。旧 cloud import 通过 Cloud 审核适配器保留，AI 通过本地审核适配器接入。

未采用以下方案：

- 独立 AI 审核页：会复制审核、编辑、KaTeX 和保存逻辑，并使两套页面长期分叉。
- 伪造服务端导入任务：旧 confirm 要求服务端已有且完全匹配的 draft，扩展它会混淆安全边界并增加不必要的服务端改造。
- 直接复用 `ApiHttpClient`：该客户端固定绑定业务服务器 Base URL、私有 CA 和业务 Bearer Token，不适合任意 AI Provider。

## 4. 总体架构

```text
AIRecognitionSettingsPage
  ├─ AiProviderConfigStore        Provider / Model / Base URL
  └─ AiCredentialStore            HUKS key + encrypted Preferences envelope
                  │
ImportBankPage → PdfAiImportSetupPage → PdfAiImportProgressPage
                  │
          PdfAiImportCoordinator
            ├─ PdfPageImageEncoder
            ├─ MathQuestionPromptBuilder
            ├─ AiProviderAdapter
            │    └─ OpenAiCompatibleAdapter
            ├─ AiVisionTransport
            └─ AiQuestionResponseParser
                  │
       PdfReviewSession（无凭据、无原始响应）
          ├─ AI questions + local evidence images
          └─ failed pages + local full-page images
                  │
          PdfImportReviewPage
            ├─ CloudPdfReviewAdapter（保留旧路径）
            └─ AiPdfReviewAdapter
                  │
          AiImportSaveService
            ├─ CloudQuestionRepository → /v1/sync/push
            └─ DeviceImageStore → device-only image mapping
```

## 5. 模块职责

### 5.1 配置与凭据

`AiProviderConfig` 只包含 Provider ID、Model 和 Base URL，不包含 API Key。`AiProviderConfigStore` 使用独立 Preferences 保存这些非秘密配置，配置不进入业务同步数据。

`AiCredentialStore` 独占 API Key 的持久化职责。它使用 HUKS 生成不可导出的 AES-256-GCM 设备密钥，Preferences 只保存版本、nonce、密文和认证标签。已保存的 Key 不提供普通读取接口，只提供窄作用域的 `withCredential` 操作；调用完成后覆盖可变字节缓冲并释放字符串、Header 和请求对象引用。

`AiProviderAdapter` 定义 Provider 请求地址、请求体构造、响应内容提取和 Provider 能力。首版实现 `OpenAiCompatibleAdapter`；OpenAI 官方预设和自定义 OpenAI-compatible 配置共享该适配器。后续 Provider 通过新增 adapter 和 preset 扩展，不修改页面或 coordinator。

### 5.2 AI 请求与解析

`AiVisionTransport` 只负责 HTTPS HTTP 请求、Content-Type、响应大小、超时、取消和状态码映射。它不记录 URL、Header、请求体、响应体或底层异常详情，不复用业务 `ApiHttpClient`，也不使用业务服务器私有 CA。正式构建和测试均拒绝非 HTTPS Base URL。

`MathQuestionPromptBuilder` 生成固定 system prompt，并注入当前页码、总页数、最多 1000 字的上一页末尾上下文和输出 JSON Schema。该模块不接受 API Key、用户身份、账号、业务服务器地址或服务端状态作为参数。

`AiQuestionResponseParser` 是唯一允许清理 Markdown JSON 围栏的位置。它负责提取一个完整 JSON 对象、字段上限、危险内容、bbox 和 LaTeX 校验，不信任 Provider 的类型或内容。

### 5.3 PDF 与逐页协调

`PdfPageImageEncoder` 打开指定页、按最长边和最大请求体约束渲染、JPEG 压缩和 Base64 编码。PixelMap 在网络请求前释放；网络等待期间不持有 PDF 页面像素。请求完成后及时释放 Base64、JSON body 和响应引用。

AI 页面图使用确定的资源上限：最长边 2200 px，JPEG 初始质量 82，必要时逐级降低但不低于 60；单页 JPEG 最大 4 MiB，包含 Base64 和 JSON 的完整请求体最大 6 MiB。无法在这些限制内生成可辨认页面图时，本页以安全错误失败，不发送超限请求。

`PdfAiImportCoordinator` 严格串行处理页面。它维护 generation/cancellation token 和当前 HTTP request key，支持取消、失败页重试和进度回调。该模块通过构造器或接口注入 renderer、credential access、adapter、transport 和 parser，自动测试全部使用 fake，不调用收费 API。

### 5.4 审核与保存

`PdfReviewSession` 保存来源类型、题库信息、AI 草稿、失败页、本机图片路径和稳定保存 ID。它不得保存 API Key、Authorization、Provider 原始响应或业务 access token。

`PdfImportReviewPage` 改用通用审核模型。现有字段编辑和当前未提交的 KaTeX 预览保留；AI 题目在审核阶段即可显示本机原题图片。失败页显示整页图片，并提供“重试识别”“手动新增题目”和“放弃本页”。

`AiImportSaveService` 为题库和每道题预生成稳定 UUID，并调用新增的 `CloudQuestionRepository.createBankWithIds`。原 `createBank` 行为和签名不变。稳定 UUID 允许保存失败后幂等重试，并让本机题图在提交文字前就具备最终 question UUID。

题目文字成功写入 `/v1/sync/push` 后，图片移动到当前账号的 `DeviceImageScope` 目录并通过 `DeviceImageStore` 建立映射。若文字已成功而图片落盘失败，审核会话保留保存结果和缓存图片，只重试图片阶段，不重复创建题库或题目。

## 6. 设置界面

“我的 → 设置”新增“AI 识别设置”入口，进入独立 `AiRecognitionSettingsPage`。页面包含：

- 识别方式：固定显示“AI 视觉识别（推荐）”，不提供旧 OCR 选项。
- API Provider：首版为 OpenAI 官方预设和 OpenAI-compatible 自定义项。
- Model：自由输入，空值禁止测试和导入。
- API Key：密码输入框，支持当前输入显示/隐藏、替换已保存 Key 和清除。
- Base URL：位于“高级设置”；官方预设自动填写，自定义 Provider 必填。
- 测试连接：使用极小测试图片和受限输出验证地址、鉴权、模型及视觉请求格式。

已保存 Key 不重新填充到输入框，也不显示完整值；页面只显示“已配置”。显示/隐藏仅作用于用户当前输入、尚未持久化的临时字符串。保存完成、离开页面或清除后立即清空临时输入状态。

测试连接是用户明确触发的一次 Provider 请求，界面提示它可能产生极少量模型费用；自动化测试不触发该真实请求。

Base URL 规范化后必须满足：HTTPS、合法主机、无 username/password、无 query、无 fragment。adapter 在受控路径上追加 `/chat/completions`，避免任意路径拼接。Provider 重定向不得把 Authorization 跨源转发。

## 7. 客户端处理流程

1. `ImportBankPage` 调用现有 `PdfImportService.selectPdf()`，流式暂存 PDF 并获得真实页数。
2. 进入 `PdfAiImportSetupPage`，编辑题库名、科目和页码范围，并显示当前 Provider/Model 摘要。
3. 开始前验证登录状态、网络、Provider、Model、Base URL 和已保存 Key；不创建业务服务器 import job。
4. `PdfAiImportProgressPage` 启动 coordinator，一次只处理一页。
5. 页面渲染和压缩完成后释放 PixelMap，再在 `withCredential` 闭包内向 Provider 发送请求。
6. transport 验证 HTTP 层，adapter 提取 assistant content，parser 严格解析该页题目。
7. bbox 合法时使用本机 PDF 页面生成题目裁图；bbox 无效时使用整页图片并标记待复核。
8. 一页的解析及证据图片均成功后，才把该页结果追加到审核会话。
9. 页面失败时保存独立 `AiPageFailure` 和整页本机图片，继续处理后续页。
10. 全部页面结束后进入现有 `PdfImportReviewPage`。
11. 用户审核、编辑、重试失败页或手动新增题目后保存。
12. 题目文字通过现有同步 API 保存，本机图片通过 `DeviceImageStore` 绑定，不上传 PDF 或图片。

取消会销毁当前 AI HTTP 请求、停止下一页调度并释放当前资源。取消和页面失败均不调用 PaddleOCR，也不调用 `CloudImportService.createJob`、`resumeUpload` 或 `/v1/imports/pdf/**`。

## 8. OpenAI-compatible 请求协议

请求使用：

```text
POST {validatedBaseUrl}/chat/completions
Content-Type: application/json
Accept: application/json
Authorization: Bearer <ephemeral credential>
```

请求体包含用户 Model、`stream: false`、固定 system prompt、页码上下文、单页 JPEG data URL 和 JSON Schema。所有 Provider 都在 Prompt 中获得完整 Schema；只有声明支持结构化输出的 preset 才附加对应 `response_format`，自定义兼容接口不强依赖非通用扩展字段。

图片最长边沿用现有 PDF 导入限制，并通过自适应 JPEG 质量确保单页请求有界。整份 PDF 永不发送给 AI；每次请求只包含一页图片。

## 9. AI 输出 Schema 与 Prompt 规则

内层 AI 内容必须匹配：

```json
{
  "questions": [
    {
      "label": "例1.5",
      "type": "unknown",
      "question": "题干，数学表达式使用 $...$ 或 $$...$$",
      "options": null,
      "answer": null,
      "analysis": null,
      "bbox": {
        "x1": 0,
        "y1": 0,
        "x2": 1000,
        "y2": 1000
      }
    }
  ]
}
```

Prompt 明确要求：视觉顺序、完整中文、KaTeX 兼容 LaTeX、行内和独立公式分隔符、`\frac`、`\sqrt`、`f^{-1}(x)`、`\le`、`\ge`、独立 `cases` 环境、JSON 反斜杠转义、无法辨认时使用 `[无法识别]`，并禁止把高括号识别为积分号或臆造答案和解析。

现有题目模型没有独立 label 字段。转换到通用审核模型时保留 label；最终保存前将非空 label 以单个空格前置到题干，避免数据库和同步协议扩表，同时保持“例1.5”可搜索和可编辑。如果题干已经以相同的规范化 label 开头，则不重复前置。

## 10. 响应校验

### 10.1 HTTP 与外层响应

- 只接受成功 HTTP 状态。
- Content-Type 必须是 `application/json`，允许 charset 参数。
- 响应最大 2 MiB，HTTP request 同时设置系统 `maxLimit`。
- OpenAI-compatible 外层必须包含非空 `choices[0].message.content` 字符串。
- 不向上层暴露 Provider 原始错误 body、Header 或响应片段。

### 10.2 内层 JSON

- 允许首尾空白及一层完整的 `json` Markdown 围栏；禁止围栏外文字。
- 只接受一个 JSON 对象，拒绝尾随 JSON 或解释文本。
- `questions` 必须为数组，每页最多 50 题。
- label 去除首尾空白后长度为 1–32 字，接受 `例1.5`、`1.`、`第3题`、`Q4` 等常见题号形式；拒绝句子、换行、控制字符和标记文本。
- type 必须是 `single_choice`、`blank`、`short_answer` 或 `unknown`；不得根据答案文本猜测题型。
- 题干最长 20,000 字；答案最长 20,000 字；解析最长 40,000 字。
- options 只能为 null 或对象，键必须是 A–J 且不得重复，最多 10 项，每项最长 2,000 字；转换到现有数组模型时按 A–J 顺序保存。
- 文本允许正常的换行、回车和制表符，但拒绝 NUL、其他不可见控制字符、HTML 标签、script、事件属性和 `javascript:` 内容。
- 保留 questions 数组顺序作为 AI 给出的视觉阅读顺序。

### 10.3 bbox 与 LaTeX

bbox 坐标必须是有限数值并位于 0–1000，且 `x1 < x2`、`y1 < y2`。bbox 缺失、越界、倒序或区域过小不会丢弃题目，而是标记 `bboxUsable=false` 并使用整页证据图。

LaTeX 校验包括 `$...$`、`$$...$$`、花括号、`\begin`/`\end` 环境和 cases 行结构闭合。同页多个 piecewise 必须形成彼此独立的 cases 环境。包含已知错误文本 `∫2−x` 的页面被判为 LaTeX 校验失败。除 bbox 以外的结构或 LaTeX 错误会使整页失败，避免创建半截题目。

## 11. 错误与重试

内部使用稳定、安全的错误码并映射为用户提示：

- `INVALID_BASE_URL`：AI 服务地址无效，正式环境仅支持 HTTPS。
- `MISSING_API_KEY`：请先配置 API Key。
- `MISSING_MODEL`：请填写模型名称。
- `NETWORK_UNAVAILABLE`：当前网络不可用。
- `TLS_FAILED`：无法建立安全连接，请检查服务地址或证书。
- `AUTH_FAILED`：401/403，API Key 或权限不可用。
- `ENDPOINT_OR_MODEL_NOT_FOUND`：404，接口地址或模型不可用。
- `RATE_LIMITED`：429，请稍后重试或检查额度。
- `PROVIDER_UNAVAILABLE`：5xx，AI 服务暂时不可用。
- `TIMEOUT`：AI 识别超时。
- `RESPONSE_TOO_LARGE`：AI 返回内容超过限制。
- `INVALID_CONTENT_TYPE`：AI 返回格式不是 JSON。
- `INVALID_JSON`：AI 返回的 JSON 无法解析或不符合 Schema。
- `NO_QUESTIONS`：本页未识别到题目。
- `LATEX_INVALID`：数学公式结构不完整。
- `CANCELLED`：本次识别已取消。

默认不自动重试收费请求，因为超时不代表 Provider 没有处理。用户可以明确重试单页；重试替换该页失败记录，并继续保持页面级原子提交。所有错误消息均由本地映射生成，不拼接底层异常、URL、Header、Key 或原始响应。

## 12. 数据与图片保存

业务服务端只接收现有同步字段：题库名、科目、题型、题干、选项、答案和解析。AI Provider、Model、Base URL、API Key、Prompt、原始响应、bbox、本机路径、PDF 和题图均不进入同步 payload。

AI 保存流程：

1. 为 bank 和每道 review question 生成一次稳定 UUID，并写入内存审核会话。
2. 使用 `CloudQuestionRepository.createBankWithIds` 构造既有 `SyncPushOperation`。
3. 调用 `/v1/sync/push`，按现有批次限制保存普通题目数据。
4. 服务器成功后移动本机证据图到账号隔离目录，校验文件、SHA-256、路径边界和符号链接。
5. 使用 `DeviceImageStore` 写入 accountId + questionUuid + sortOrder 映射。
6. 全部图片成功后清理暂存 PDF 和缓存图。

通用审核题型在保存边界执行显式映射：`single_choice` 保持不变，`blank` 转为现有 `fill_blank`，`short_answer` 保持不变，`unknown` 转为 `unclassified`。页面和同步层不得依赖隐式字符串兼容。

文字保存失败时保留审核会话和缓存图片供重试。文字已保存但图片失败时记录已保存 UUID，只重试本机图片阶段，避免重复创建文字。退出并明确放弃导入时，只删除本次会话拥有的缓存 PDF 和图片。

## 13. 文件修改计划

### 13.1 新增

- `entry/src/main/ets/constants/AiImportLimits.ets`
- `entry/src/main/ets/models/ai/AiProviderConfig.ets`
- `entry/src/main/ets/models/ai/AiImportModels.ets`
- `entry/src/main/ets/services/ai/AiProviderConfigStore.ets`
- `entry/src/main/ets/services/ai/AiCredentialStore.ets`
- `entry/src/main/ets/services/ai/AiProviderAdapter.ets`
- `entry/src/main/ets/services/ai/OpenAiCompatibleAdapter.ets`
- `entry/src/main/ets/services/ai/AiVisionTransport.ets`
- `entry/src/main/ets/services/ai/MathQuestionPromptBuilder.ets`
- `entry/src/main/ets/services/ai/AiQuestionResponseParser.ets`
- `entry/src/main/ets/services/ai/PdfPageImageEncoder.ets`
- `entry/src/main/ets/services/ai/PdfAiImportCoordinator.ets`
- `entry/src/main/ets/services/ai/AiImportSaveService.ets`
- `entry/src/main/ets/services/review/PdfReviewModels.ets`
- `entry/src/main/ets/services/review/PdfReviewSession.ets`
- `entry/src/main/ets/services/review/CloudPdfReviewAdapter.ets`
- `entry/src/main/ets/services/review/AiPdfReviewAdapter.ets`
- `entry/src/main/ets/pages/AiRecognitionSettingsPage.ets`
- `entry/src/main/ets/pages/PdfAiImportSetupPage.ets`
- `entry/src/main/ets/pages/PdfAiImportProgressPage.ets`
- `entry/src/test/AiImportContracts.test.cjs`
- `entry/src/test/AiImportSecurityContracts.test.cjs`
- `entry/src/test/AiImportLocalUnit.test.ets`
- `entry/src/ohosTest/ets/test/AiCredentialStore.test.ets`

### 13.2 修改

- `entry/src/main/ets/pages/MinePage.ets`
- `entry/src/main/ets/pages/ImportBankPage.ets`
- `entry/src/main/ets/pages/PdfImportReviewPage.ets`
- `entry/src/main/ets/services/CloudQuestionRepository.ets`
- `entry/src/main/ets/services/DeviceImageStore.ets`
- `entry/src/main/ets/utils/PdfImportState.ets`
- `entry/src/test/List.test.ets`
- `entry/src/ohosTest/ets/test/List.test.ets`
- `entry/src/test/PdfImportContracts.test.cjs`
- `entry/src/test/CloudCutoverContracts.test.cjs`
- `entry/src/main/resources/base/profile/main_pages.json`
- `entry/src/main/resources/base/profile/easy_go.json`
- `entry/src/main/resources/base/backup_config.json`

### 13.3 保持不动

- `server/worker/**`
- `server/src/imports/**`
- `entry/src/main/ets/services/CloudImportService.ets`
- `entry/src/main/ets/services/CloudImportApi.ets`
- `entry/src/main/ets/pages/PdfImportSetupPage.ets`
- `entry/src/main/ets/pages/PdfImportProgressPage.ets`
- `entry/src/main/ets/components/MathContentView.ets` 的内部实现
- `entry/src/main/ets/utils/MathContentUtils.ets` 的内部算法
- Auth、HdsTabs 和 SDK 版本配置

## 14. 测试策略

### 14.1 快速源码合同

- 正式 PDF 入口只进入 AI 页面。
- AI 分支不引用 CloudImportService、CloudImportApi、PaddleOCR 或 `/v1/imports/pdf`。
- Provider 请求格式和单页 image URL 正确。
- AI 模块不存在 console、hilog、埋点、Header/Key/原始响应输出。
- Sync payload 和服务端 DTO 不出现 API Key、Provider、Base URL 或 Authorization。
- 设置页包含 Provider、Model、Base URL、密码输入、显示/隐藏、修改、清除和测试连接。
- Auth、EasyGo、HdsTabs、KaTeX 和现有审核编辑合同不回退。

### 14.2 Hypium 纯逻辑测试

- Provider、Model、Base URL 规范化和 HTTPS 校验。
- Prompt 包含页码、总页数、可选上下文和 Schema，不含凭据、身份或服务端信息。
- 严格 JSON、完整 Markdown 围栏、非法 JSON、尾随内容和超长响应。
- questions、字段长度、options、label、危险 HTML、bbox 和 LaTeX 校验。
- 分数、根式、逆函数、varphi、cases、JSON 转义和同页多个 piecewise 保持。
- fake transport 覆盖连接成功、401、403、404、429、5xx、TLS 和超时。
- fake renderer/provider 覆盖严格逐页、最大并发为 1、PixelMap/请求体释放、取消和单页重试。
- AI 失败时 OCR 和 cloud import 调用次数恒为 0。
- 审核会话深拷贝、编辑、原图、失败页手动新增及稳定 UUID 重试。

### 14.3 HUKS 与设备测试

- HUKS 生成不可导出设备密钥并完成 AES-GCM encrypt/decrypt。
- Preferences 原始值中不存在明文 API Key。
- 应用重启后可解密，清除后不可读取。
- nonce 或密文被篡改时安全失败且不泄露内容。
- 备份恢复后若设备密钥不可用，删除失效密文并要求重新配置。
- PDFKit 真 PDF 页面渲染、资源释放、设置 UI 和审核原图在设备上验证。

### 14.4 六题回归

自动测试使用固定 fake Provider replay，不调用真实收费 API，必须断言：

- questionCount = 6。
- 例1.2 包含 `\sqrt`。
- 例1.3 包含 `$f^{-1}(x)$`。
- 例1.4 包含 `\varphi` 且不包含错误 cases。
- 例1.5 包含 `\begin{cases}` 且不包含 `∫2−x`。
- 例1.6 包含 `\frac{x}{1+x^2}`。
- Q1–Q6 顺序不变。
- 同页多个 piecewise 为独立 cases。

仓库当前没有包含例1.1–例1.6的真实数学 PDF，且 `hdc list targets` 当前没有设备。因此实现完成时，真实 PDF 真机 E2E 只能在用户提供样本并连接设备后运行；在此之前最终报告必须写 `Real PDF E2E: NOT RUN`，不能用 replay 或伪 PDF 冒充通过。

## 15. TDD 实施顺序

1. 记录当前工作树与目标测试基线，区分既存失败和新增失败。
2. 先写 Provider/config/HTTPS 失败测试，再实现模型和配置存储。
3. 先写凭据密文和泄密负向测试，再实现 HUKS store 与备份排除。
4. 先写 Prompt 和解析器测试，再实现 builder/parser。
5. 先写 fake transport 请求与错误映射测试，再实现 adapter/transport/测试连接。
6. 先写串行、释放、取消、重试和无 OCR 测试，再实现 encoder/coordinator。
7. 先写双源审核、原图和失败页测试，再接入审核模型与页面。
8. 先写稳定 UUID、同步 payload 和本机映射测试，再实现保存服务。
9. 接入设置页、正式 PDF 入口和页面注册。
10. 依次执行 ArkTS 检查、Hypium、客户端 CJS、服务端回归、Worker 回归和 debug HAP 构建。
11. 有设备和真实 PDF 时执行设备/HUKS/UI/真实 PDF E2E；否则明确记录 NOT RUN 及缺失条件。

## 16. 验收与最终报告

最终报告必须包含：

- A. Architecture
- B. Modified Files
- C. API Key security
- D. Provider request format
- E. AI response schema
- F. Error handling
- G. Tests
- H. Real PDF E2E：PASS / FAIL / NOT RUN
- I. 明确确认 API Key 未上传业务服务端、未写日志、未明文存储
- J. 明确确认未 commit、未 push、未创建 PR

不得以静态源码扫描替代真实 HUKS 设备验证，也不得以 fake replay 替代真实 PDF 视觉识别验收。无法运行的层级必须如实标记。
