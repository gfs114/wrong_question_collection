# 客户端直连多模态 AI 数学 PDF 导入 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在不上传 PDF、题图或 API Key 到业务服务器的前提下，让 HarmonyOS 客户端逐页直连用户配置的 OpenAI-compatible 多模态模型，生成可在既有审核页编辑、预览、保存和同步的数学题目。

**Architecture:** 新增独立的配置、HUKS 凭据、Provider adapter、HTTP transport、Prompt、严格解析器、PDF 图片编码器、串行 coordinator 和分阶段保存服务。`PdfImportReviewPage` 通过 Cloud/AI 双源 adapter 复用既有审核、KaTeX 与图片展示；正式 PDF 入口只进入 AI 流程，保留但不触达旧 Cloud/PaddleOCR 实现。

**Tech Stack:** ArkTS/ArkUI V1、HarmonyOS API 24+、UniversalKeystoreKit HUKS AES-256-GCM、PDFKit、ImageKit、NetworkKit、Preferences、ArkData RDB、Hypium、Node.js `node:test`、现有 `/v1/sync/push`。

---

## 执行约束

- 当前工作树已有用户改动。每个任务都必须基于当前文件增量编辑；禁止 `git reset`、`git checkout --` 或从 `HEAD` 覆盖文件。
- 用户明确要求不保留正式界面的旧 OCR 选项。`ImportBankPage` 的 PDF 入口只能指向 `PdfAiImportSetupPage`，AI 失败不得调用 Cloud import、PaddleOCR 或本地 OCR。
- 用户明确要求不提交。所有通常的 commit 步骤均替换为 `git diff` 检查点；全程不 commit、不 push、不创建 PR。
- 自动测试只能使用 fake renderer/fake transport/fake Provider，不得调用真实收费 API。“测试连接”仅由用户在 UI 中明确点击时发起。
- 安全表述必须准确：Key 仅在内存中短暂解密并通过 TLS `Authorization` 发给用户配置的 AI Provider；“只保存在设备”指持久化边界。Key 不得发给 wrong_question_collection 业务服务器、同步、日志或明文 Preferences。
- `PdfImportReviewPage.ets` 中当前未提交的 `MathContentView`、`MathContentUtils`、`previewDraftQuestionId`、公式预览 builder 与按钮必须原样保留。
- 不修改 `server/worker/**`、`server/src/imports/**`、`CloudImportService.ets`、`CloudImportApi.ets`、旧 `PdfImportSetupPage.ets`、旧 `PdfImportProgressPage.ets`、MathContent 内部算法、Auth、HdsTabs 或 SDK 版本。
- 新增 ArkTS 遵循显式命名 class/interface：不使用 `any`、`unknown`、类型断言、对象展开、动态属性访问或在页面内编写网络协议逻辑。

## 已核对的开源参考

- [OpenHarmony AES/GCM/NoPadding 官方样例](https://github.com/openharmony/applications_app_samples/blob/master/code/DocsSample/Security/UniversalKeystoreKit/KeyUsage/EncryptionDecryption/entry/src/main/ets/pages/AESGCMNoPadding.ets)（Apache-2.0）：采用 `ciphertext || 16-byte tag`，解密时把 tag 放入 `HUKS_TAG_AE_TAG`。
- [XCube PdfTextExtractionService](https://github.com/YANGZX22/XCube/blob/main/entry/src/main/ets/services/PdfTextExtractionService.ets)（MIT）：只借鉴 `PdfDocument`、`PdfPage`、`PixelMap` 分层 `finally` 释放模式；其 API 26、OCR、日志和网络等待期间资源持有方式不能照搬。
- [OniroGPT](https://github.com/eclipse-oniro4openharmony/app-oniroGPT)（Apache-2.0）：只借鉴 Chat Completions 的 `text + image_url` 消息形状；硬编码 Key、完整响应日志、旧图片编码 API 和无请求上限的实现不能照搬。
- AGPL/GPL 或未声明许可证的示例不复制代码。本计划按本机 SDK 声明重新实现，仅使用上述 API 形状，因此不引入第三方源文件或许可证义务。

## 文件结构

### 新建

| 文件 | 单一职责 |
|---|---|
| `entry/src/main/ets/constants/AiImportLimits.ets` | AI 图片、请求、响应、字段和页题数上限 |
| `entry/src/main/ets/models/ai/AiProviderConfig.ets` | Provider 配置、HTTPS 规范化、安全错误码 |
| `entry/src/main/ets/models/ai/AiImportModels.ets` | AI 题目、bbox、失败、进度和编码页模型 |
| `entry/src/main/ets/services/ai/AiProviderConfigStore.ets` | 非秘密 Provider/Model/Base URL Preferences |
| `entry/src/main/ets/services/ai/HuksAesGcmCipher.ets` | HUKS AES-256-GCM 与会话清理 |
| `entry/src/main/ets/services/ai/AiCredentialEnvelopeCodec.ets` | 版本化 nonce/ciphertext/tag Base64 envelope |
| `entry/src/main/ets/services/ai/AiCredentialStore.ets` | API Key 加密持久化与窄作用域读取 |
| `entry/src/main/ets/services/ai/AiProviderAdapter.ets` | Provider 构建请求和提取 assistant content 的接口 |
| `entry/src/main/ets/services/ai/OpenAiCompatibleAdapter.ets` | OpenAI-compatible endpoint、JSON body、外层响应解析 |
| `entry/src/main/ets/services/ai/AiVisionTransport.ets` | HTTPS POST、Content-Type/大小/状态码、取消 |
| `entry/src/main/ets/services/ai/AiConnectionTestService.ets` | 用户明确触发的极小视觉连接测试 |
| `entry/src/main/ets/services/ai/MathQuestionPromptBuilder.ets` | 固定数学视觉 Prompt 与页上下文 |
| `entry/src/main/ets/services/ai/AiQuestionResponseParser.ets` | 围栏清理、严格内层 JSON、字段/bbox/LaTeX 校验 |
| `entry/src/main/ets/services/ai/PdfPageImageEncoder.ets` | PDFKit 单页渲染、JPEG 自适应压缩和证据图 |
| `entry/src/main/ets/services/ai/PdfAiImportCoordinator.ets` | 串行逐页、进度、取消、失败页重试 |
| `entry/src/main/ets/services/ai/AiImportSaveService.ets` | 稳定 UUID、文字同步、账号级题图落盘 |
| `entry/src/main/ets/services/review/PdfReviewModels.ets` | Cloud/AI 共用审核模型与 adapter 接口 |
| `entry/src/main/ets/services/review/PdfReviewSession.ets` | 审核会话深拷贝内存仓库和保存阶段 |
| `entry/src/main/ets/services/review/CloudPdfReviewAdapter.ets` | 现有 Cloud draft/confirm/artifact 行为适配 |
| `entry/src/main/ets/services/review/AiPdfReviewAdapter.ets` | AI 会话读取、编辑、重试、放弃与保存适配 |
| `entry/src/main/ets/pages/AiRecognitionSettingsPage.ets` | Provider、Model、Base URL、Key 和测试连接 UI |
| `entry/src/main/ets/pages/PdfAiImportSetupPage.ets` | AI PDF 题库名、科目和页码范围配置 |
| `entry/src/main/ets/pages/PdfAiImportProgressPage.ets` | AI 串行识别进度、取消和进入审核 |
| `entry/src/test/AiImportLocalUnit.test.ets` | 纯 ArkTS 逻辑与 fake 端口测试 |
| `entry/src/test/AiImportContracts.test.cjs` | 路由、请求形状、审核与兼容合同 |
| `entry/src/test/AiImportSecurityContracts.test.cjs` | 无泄密、无 OCR/Cloud fallback、备份排除合同 |
| `entry/src/ohosTest/ets/test/AiCredentialStore.test.ets` | 真 HUKS、Preferences 和篡改测试 |

### 修改

| 文件 | 修改点 |
|---|---|
| `entry/src/main/ets/pages/MinePage.ets` | 设置区新增 AI 识别设置入口，不接触测试 Token 复制逻辑 |
| `entry/src/main/ets/pages/ImportBankPage.ets` | 复用 `PdfImportService.selectPdf()`，正式 PDF 路由切到 AI setup |
| `entry/src/main/ets/pages/PdfImportReviewPage.ets` | 从 Cloud 具体类型改为通用 adapter，保留全部编辑/KaTeX UI |
| `entry/src/main/ets/services/CloudQuestionRepository.ets` | 保留 `createBank()`，新增稳定实体 ID 保存入口 |
| `entry/src/main/ets/services/DeviceImageStore.ets` | 新增预校验 + 单事务 `saveBatch()` |
| `entry/src/main/ets/utils/PdfImportState.ets` | 新增 AI review session ID；Cloud 字段和方法保持兼容 |
| `entry/src/test/List.test.ets` | 注册 AI 纯逻辑测试 |
| `entry/src/ohosTest/ets/test/List.test.ets` | 注册 HUKS 设备测试 |
| `entry/src/test/PdfImportContracts.test.cjs` | 将正式入口合同更新为 AI，保留旧实现资源合同 |
| `entry/src/test/CloudCutoverContracts.test.cjs` | 允许仅 AI transport 的外部网络，继续禁止旧本地 OCR 路径 |
| `entry/src/test/CloudImportPageContracts.test.cjs` | Cloud 行为迁入 adapter 后保持确认/下载/ACK 顺序 |
| `entry/src/test/CloudCacheContracts.test.cjs` | 稳定 ID 与批量图片事务合同 |
| `entry/src/main/resources/base/profile/main_pages.json` | 注册三个新页面 |
| `entry/src/main/resources/base/profile/easy_go.json` | 三个新页面加入全屏列表 |
| `entry/src/main/resources/base/profile/backup_config.json` | 精确排除 AI 凭据 Preferences |

## Task 0: 固化工作树与测试基线

**Files:**
- Inspect: all currently modified/untracked files
- Test: existing client, server, and worker suites

- [ ] **Step 1: 记录当前工作树，不写文件**

Run: `git status --short`

Expected: 输出包含现有用户改动；至少包括 `PdfImportReviewPage.ets`、`MathContentView.ets`、`MathContentUtils.ets` 和已有 server/worker 改动。后续检查不得让这些无关 diff 消失。

- [ ] **Step 2: 运行现有客户端源码合同基线**

Run:

```powershell
Get-ChildItem 'entry/src/test' -Filter '*.test.cjs' | ForEach-Object {
  node --test $_.FullName
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
```

Expected: PASS；若既存脏工作树合同失败，记录测试名和原始错误，后续只能把新增回归与该基线比较，不能顺带改 server/worker 算法。

- [ ] **Step 3: 运行 ArkTS 静态检查基线**

Run:

```powershell
node 'C:/Users/32773/.agents/skills/harmonyos-dev-skill/scripts/arkts-check.cjs' --project .
```

Expected: JSON 中 `success: true`；若存在既有错误，保存精确文件和行号作为基线。

- [ ] **Step 4: 运行 server 与 worker 基线**

Run:

```powershell
npm test --prefix server -- --runInBand
python -m pytest server/worker/tests -q --basetemp .pytest-ai-import-baseline
```

Expected: PASS；本功能不修改这两个区域，最终结果必须与基线一致。

- [ ] **Step 5: 无提交 diff 检查点**

Run: `git diff --stat`

Expected: 与 Step 1 相同，本任务没有产生新 diff；不要执行 `git add` 或 `git commit`。

## Task 1: 定义 AI 限额、配置和数据模型

**Files:**
- Create: `entry/src/main/ets/constants/AiImportLimits.ets`
- Create: `entry/src/main/ets/models/ai/AiProviderConfig.ets`
- Create: `entry/src/main/ets/models/ai/AiImportModels.ets`
- Create: `entry/src/test/AiImportLocalUnit.test.ets`
- Modify: `entry/src/test/List.test.ets:1-5`

- [ ] **Step 1: 写 Provider 与限额失败测试**

Create `entry/src/test/AiImportLocalUnit.test.ets` with:

```ts
import { describe, it, expect } from '@ohos/hypium'
import { AiImportLimits } from '../main/ets/constants/AiImportLimits'
import {
  AiImportError,
  AiImportErrorCode,
  AiProviderConfig,
  AiProviderConfigValidator,
  AiProviderId
} from '../main/ets/models/ai/AiProviderConfig'

class AiImportAssertions {
  static expectConfigError(config: AiProviderConfig, code: AiImportErrorCode): void {
    let actual: string = ''
    try {
      AiProviderConfigValidator.normalize(config)
    } catch (err) {
      if (err instanceof AiImportError) {
        actual = err.code
      }
    }
    expect(actual).assertEqual(code)
  }
}

export default function aiImportLocalUnitTest(): void {
  describe('aiProviderConfig', () => {
    it('normalizes an HTTPS base URL without changing its controlled path', 0, () => {
      const input: AiProviderConfig = new AiProviderConfig(
        AiProviderId.CUSTOM, '  vision-model  ', ' https://ai.example.com/v1/ ')
      const value: AiProviderConfig = AiProviderConfigValidator.normalize(input)
      expect(value.model).assertEqual('vision-model')
      expect(value.baseUrl).assertEqual('https://ai.example.com/v1')
      expect(value.supportsStructuredOutput).assertFalse()
    })

    it('rejects unsafe or incomplete provider settings', 0, () => {
      AiImportAssertions.expectConfigError(
        new AiProviderConfig(AiProviderId.CUSTOM, '', 'https://ai.example.com/v1'),
        AiImportErrorCode.MISSING_MODEL)
      AiImportAssertions.expectConfigError(
        new AiProviderConfig(AiProviderId.CUSTOM, 'model', 'http://ai.example.com/v1'),
        AiImportErrorCode.INVALID_BASE_URL)
      AiImportAssertions.expectConfigError(
        new AiProviderConfig(AiProviderId.CUSTOM, 'model', 'https://user:pass@ai.example.com/v1'),
        AiImportErrorCode.INVALID_BASE_URL)
      AiImportAssertions.expectConfigError(
        new AiProviderConfig(AiProviderId.CUSTOM, 'model', 'https://ai.example.com/v1?q=1'),
        AiImportErrorCode.INVALID_BASE_URL)
      AiImportAssertions.expectConfigError(
        new AiProviderConfig(AiProviderId.CUSTOM, 'model', 'https://ai.example.com/v1#x'),
        AiImportErrorCode.INVALID_BASE_URL)
      AiImportAssertions.expectConfigError(
        new AiProviderConfig(AiProviderId.CUSTOM, 'model', 'https://ai.example.com/v1/chat/completions'),
        AiImportErrorCode.INVALID_BASE_URL)
    })

    it('locks the bounded resource policy', 0, () => {
      expect(AiImportLimits.MAX_IMAGE_LONG_EDGE).assertEqual(2200)
      expect(AiImportLimits.MAX_JPEG_BYTES).assertEqual(4 * 1024 * 1024)
      expect(AiImportLimits.MAX_REQUEST_BYTES).assertEqual(6 * 1024 * 1024)
      expect(AiImportLimits.MAX_RESPONSE_BYTES).assertEqual(2 * 1024 * 1024)
      expect(AiImportLimits.MAX_QUESTIONS_PER_PAGE).assertEqual(50)
    })
  })
}
```

Modify `entry/src/test/List.test.ets` to:

```ts
import localUnitTest from './LocalUnit.test'
import aiImportLocalUnitTest from './AiImportLocalUnit.test'

export default function testsuite(): void {
  localUnitTest()
  aiImportLocalUnitTest()
}
```

- [ ] **Step 2: 运行测试确认失败**

Run:

```powershell
& 'D:/Program Files/Huawei/DevEco Studio/tools/node/node.exe' `
  'D:/Program Files/Huawei/DevEco Studio/tools/hvigor/bin/hvigorw.js' test `
  --mode module -p module=entry@default
```

Expected: FAIL，错误指出 `AiImportLimits` 或 `AiProviderConfig` 模块不存在。

- [ ] **Step 3: 实现限额和 Provider 配置验证**

Create `entry/src/main/ets/constants/AiImportLimits.ets`:

```ts
export class AiImportLimits {
  static readonly MAX_IMAGE_LONG_EDGE: number = 2200
  static readonly JPEG_QUALITY_STEPS: Array<number> = [82, 75, 68, 60]
  static readonly MAX_JPEG_BYTES: number = 4 * 1024 * 1024
  static readonly MAX_REQUEST_BYTES: number = 6 * 1024 * 1024
  static readonly MAX_RESPONSE_BYTES: number = 2 * 1024 * 1024
  static readonly MAX_QUESTIONS_PER_PAGE: number = 50
  static readonly MAX_LABEL_LENGTH: number = 32
  static readonly MAX_QUESTION_LENGTH: number = 20000
  static readonly MAX_OPTION_LENGTH: number = 2000
  static readonly MAX_ANSWER_LENGTH: number = 20000
  static readonly MAX_ANALYSIS_LENGTH: number = 40000
  static readonly MAX_PREVIOUS_CONTEXT_LENGTH: number = 1000
  static readonly MIN_BBOX_EDGE: number = 8
  static readonly CONNECT_TIMEOUT_MS: number = 15000
  static readonly READ_TIMEOUT_MS: number = 90000
}
```

Create `entry/src/main/ets/models/ai/AiProviderConfig.ets`:

```ts
import url from '@ohos.url'

export enum AiProviderId {
  OPENAI = 'openai',
  CUSTOM = 'openai_compatible'
}

export enum AiImportErrorCode {
  INVALID_BASE_URL = 'INVALID_BASE_URL',
  MISSING_API_KEY = 'MISSING_API_KEY',
  MISSING_MODEL = 'MISSING_MODEL',
  NETWORK_UNAVAILABLE = 'NETWORK_UNAVAILABLE',
  TLS_FAILED = 'TLS_FAILED',
  AUTH_FAILED = 'AUTH_FAILED',
  ENDPOINT_OR_MODEL_NOT_FOUND = 'ENDPOINT_OR_MODEL_NOT_FOUND',
  RATE_LIMITED = 'RATE_LIMITED',
  PROVIDER_UNAVAILABLE = 'PROVIDER_UNAVAILABLE',
  TIMEOUT = 'TIMEOUT',
  RESPONSE_TOO_LARGE = 'RESPONSE_TOO_LARGE',
  INVALID_CONTENT_TYPE = 'INVALID_CONTENT_TYPE',
  INVALID_JSON = 'INVALID_JSON',
  NO_QUESTIONS = 'NO_QUESTIONS',
  LATEX_INVALID = 'LATEX_INVALID',
  CANCELLED = 'CANCELLED'
}

export class AiImportError extends Error {
  readonly code: AiImportErrorCode

  constructor(code: AiImportErrorCode) {
    super(AiImportErrorMessages.forCode(code))
    this.name = 'AiImportError'
    this.code = code
  }
}

export class AiImportErrorMessages {
  static forCode(code: AiImportErrorCode): string {
    if (code === AiImportErrorCode.INVALID_BASE_URL) return 'AI 服务地址无效，正式环境仅支持 HTTPS'
    if (code === AiImportErrorCode.MISSING_API_KEY) return '请先配置 API Key'
    if (code === AiImportErrorCode.MISSING_MODEL) return '请填写模型名称'
    if (code === AiImportErrorCode.NETWORK_UNAVAILABLE) return '当前网络不可用'
    if (code === AiImportErrorCode.TLS_FAILED) return '无法建立安全连接，请检查服务地址或证书'
    if (code === AiImportErrorCode.AUTH_FAILED) return 'API Key 或权限不可用'
    if (code === AiImportErrorCode.ENDPOINT_OR_MODEL_NOT_FOUND) return '接口地址或模型不可用'
    if (code === AiImportErrorCode.RATE_LIMITED) return '请求过于频繁或额度不足，请稍后重试'
    if (code === AiImportErrorCode.PROVIDER_UNAVAILABLE) return 'AI 服务暂时不可用'
    if (code === AiImportErrorCode.TIMEOUT) return 'AI 识别超时'
    if (code === AiImportErrorCode.RESPONSE_TOO_LARGE) return 'AI 返回内容超过限制'
    if (code === AiImportErrorCode.INVALID_CONTENT_TYPE) return 'AI 返回格式不是 JSON'
    if (code === AiImportErrorCode.NO_QUESTIONS) return '本页未识别到题目'
    if (code === AiImportErrorCode.LATEX_INVALID) return '数学公式结构不完整'
    if (code === AiImportErrorCode.CANCELLED) return '本次识别已取消'
    return 'AI 返回的 JSON 无法解析或不符合格式'
  }
}

export class AiProviderConfig {
  providerId: AiProviderId
  model: string
  baseUrl: string
  supportsStructuredOutput: boolean

  constructor(providerId: AiProviderId, model: string, baseUrl: string,
    supportsStructuredOutput: boolean = false) {
    this.providerId = providerId
    this.model = model
    this.baseUrl = baseUrl
    this.supportsStructuredOutput = supportsStructuredOutput
  }
}

export class AiProviderConfigValidator {
  static openAiDefault(): AiProviderConfig {
    return new AiProviderConfig(AiProviderId.OPENAI, '', 'https://api.openai.com/v1', true)
  }

  static normalize(input: AiProviderConfig): AiProviderConfig {
    const model: string = input.model.trim()
    if (model.length === 0 || model.length > 200) {
      throw new AiImportError(AiImportErrorCode.MISSING_MODEL)
    }
    const rawBaseUrl: string = input.baseUrl.trim()
    let parsed: url.URL
    try {
      parsed = url.URL.parseURL(rawBaseUrl)
    } catch {
      throw new AiImportError(AiImportErrorCode.INVALID_BASE_URL)
    }
    if (parsed.protocol.toLowerCase() !== 'https:' || parsed.hostname.length === 0 ||
      parsed.username.length > 0 || parsed.password.length > 0 ||
      parsed.search.length > 0 || parsed.hash.length > 0) {
      throw new AiImportError(AiImportErrorCode.INVALID_BASE_URL)
    }
    let path: string = parsed.pathname
    while (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1)
    }
    if (path.toLowerCase().endsWith('/chat/completions')) {
      throw new AiImportError(AiImportErrorCode.INVALID_BASE_URL)
    }
    const normalizedPath: string = path === '/' ? '' : path
    return new AiProviderConfig(input.providerId, model, parsed.origin + normalizedPath,
      input.providerId === AiProviderId.OPENAI)
  }
}
```

Create `entry/src/main/ets/models/ai/AiImportModels.ets`:

```ts
import { AiImportErrorCode } from './AiProviderConfig'

export enum AiQuestionType {
  SINGLE_CHOICE = 'single_choice',
  BLANK = 'blank',
  SHORT_ANSWER = 'short_answer',
  UNKNOWN = 'unknown'
}

export class AiOption {
  key: string
  value: string

  constructor(key: string, value: string) {
    this.key = key
    this.value = value
  }
}

export class AiBoundingBox {
  x1: number
  y1: number
  x2: number
  y2: number

  constructor(x1: number, y1: number, x2: number, y2: number) {
    this.x1 = x1
    this.y1 = y1
    this.x2 = x2
    this.y2 = y2
  }
}

export class AiQuestionDraft {
  label: string
  type: AiQuestionType
  question: string
  options: Array<AiOption>
  answer: string
  analysis: string
  bbox: AiBoundingBox
  bboxUsable: boolean
  pageNumber: number

  constructor(label: string, type: AiQuestionType, question: string, options: Array<AiOption>,
    answer: string, analysis: string, bbox: AiBoundingBox, bboxUsable: boolean, pageNumber: number) {
    this.label = label
    this.type = type
    this.question = question
    this.options = options
    this.answer = answer
    this.analysis = analysis
    this.bbox = bbox
    this.bboxUsable = bboxUsable
    this.pageNumber = pageNumber
  }
}

export class EncodedPdfPage {
  pageNumber: number
  width: number
  height: number
  jpegBase64: string
  evidencePath: string

  constructor(pageNumber: number, width: number, height: number,
    jpegBase64: string, evidencePath: string) {
    this.pageNumber = pageNumber
    this.width = width
    this.height = height
    this.jpegBase64 = jpegBase64
    this.evidencePath = evidencePath
  }

  releaseTransientText(): void {
    this.jpegBase64 = ''
  }
}

export class AiPageFailure {
  pageNumber: number
  code: AiImportErrorCode
  message: string
  evidencePath: string

  constructor(pageNumber: number, code: AiImportErrorCode, message: string, evidencePath: string) {
    this.pageNumber = pageNumber
    this.code = code
    this.message = message
    this.evidencePath = evidencePath
  }
}

export class AiImportProgress {
  currentPage: number
  totalPages: number
  processedPages: number
  questionCount: number
  stage: string

  constructor(currentPage: number, totalPages: number, processedPages: number,
    questionCount: number, stage: string) {
    this.currentPage = currentPage
    this.totalPages = totalPages
    this.processedPages = processedPages
    this.questionCount = questionCount
    this.stage = stage
  }
}
```

- [ ] **Step 4: 运行 ArkTS 检查与 Hypium 测试**

Run:

```powershell
node 'C:/Users/32773/.agents/skills/harmonyos-dev-skill/scripts/arkts-check.cjs' --project . --files `
  entry/src/main/ets/constants/AiImportLimits.ets `
  entry/src/main/ets/models/ai/AiProviderConfig.ets `
  entry/src/main/ets/models/ai/AiImportModels.ets
& 'D:/Program Files/Huawei/DevEco Studio/tools/node/node.exe' `
  'D:/Program Files/Huawei/DevEco Studio/tools/hvigor/bin/hvigorw.js' test `
  --mode module -p module=entry@default
```

Expected: ArkTS JSON `success: true`；Hypium PASS。

- [ ] **Step 5: 无提交 diff 检查点**

Run: `git diff -- entry/src/main/ets/constants/AiImportLimits.ets entry/src/main/ets/models/ai entry/src/test/AiImportLocalUnit.test.ets entry/src/test/List.test.ets`

Expected: 只包含本任务列出的模型、限额和测试注册；不要提交。

## Task 2: 持久化非秘密 Provider 配置

**Files:**
- Create: `entry/src/main/ets/services/ai/AiProviderConfigStore.ets`
- Create: `entry/src/test/AiImportContracts.test.cjs`

- [ ] **Step 1: 写配置存储源码合同**

Create `entry/src/test/AiImportContracts.test.cjs` with:

```js
const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')

function read(path) {
  return fs.readFileSync(path, 'utf8')
}

test('provider configuration stores only non-secret fields', () => {
  const source = read('entry/src/main/ets/services/ai/AiProviderConfigStore.ets')
  assert.match(source, /PREFERENCES_NAME:\s*string\s*=\s*'ai_provider_config'/)
  assert.match(source, /AiProviderConfigValidator\.normalize/)
  assert.match(source, /PROVIDER_KEY/)
  assert.match(source, /MODEL_KEY/)
  assert.match(source, /BASE_URL_KEY/)
  assert.doesNotMatch(source, /api.?key|authorization|credential/i)
})
```

- [ ] **Step 2: 运行合同确认失败**

Run: `node --test entry/src/test/AiImportContracts.test.cjs`

Expected: FAIL with `ENOENT` for `AiProviderConfigStore.ets`.

- [ ] **Step 3: 实现配置存储**

Create `entry/src/main/ets/services/ai/AiProviderConfigStore.ets`:

```ts
import { Context } from '@kit.AbilityKit'
import { preferences } from '@kit.ArkData'
import {
  AiProviderConfig,
  AiProviderConfigValidator,
  AiProviderId
} from '../../models/ai/AiProviderConfig'

const PREFERENCES_NAME: string = 'ai_provider_config'
const PROVIDER_KEY: string = 'provider_id'
const MODEL_KEY: string = 'model'
const BASE_URL_KEY: string = 'base_url'

export class AiProviderConfigStore {
  static async load(context: Context): Promise<AiProviderConfig | null> {
    const store: preferences.Preferences = await preferences.getPreferences(context, PREFERENCES_NAME)
    const providerValue: preferences.ValueType = await store.get(PROVIDER_KEY, '')
    const modelValue: preferences.ValueType = await store.get(MODEL_KEY, '')
    const baseUrlValue: preferences.ValueType = await store.get(BASE_URL_KEY, '')
    if (typeof providerValue !== 'string' || typeof modelValue !== 'string' ||
      typeof baseUrlValue !== 'string' || providerValue.length === 0) {
      return null
    }
    const providerId: AiProviderId = providerValue === AiProviderId.OPENAI ?
      AiProviderId.OPENAI : AiProviderId.CUSTOM
    return AiProviderConfigValidator.normalize(
      new AiProviderConfig(providerId, modelValue, baseUrlValue))
  }

  static async save(context: Context, config: AiProviderConfig): Promise<AiProviderConfig> {
    const normalized: AiProviderConfig = AiProviderConfigValidator.normalize(config)
    const store: preferences.Preferences = await preferences.getPreferences(context, PREFERENCES_NAME)
    await store.put(PROVIDER_KEY, normalized.providerId)
    await store.put(MODEL_KEY, normalized.model)
    await store.put(BASE_URL_KEY, normalized.baseUrl)
    await store.flush()
    return normalized
  }

  static async clear(context: Context): Promise<void> {
    const store: preferences.Preferences = await preferences.getPreferences(context, PREFERENCES_NAME)
    await store.clear()
    await store.flush()
  }
}
```

- [ ] **Step 4: 运行合同与 ArkTS 检查**

Run:

```powershell
node --test entry/src/test/AiImportContracts.test.cjs
node 'C:/Users/32773/.agents/skills/harmonyos-dev-skill/scripts/arkts-check.cjs' --project . --files `
  entry/src/main/ets/services/ai/AiProviderConfigStore.ets
```

Expected: contract PASS；ArkTS JSON `success: true`。

- [ ] **Step 5: 无提交 diff 检查点**

Run: `git diff -- entry/src/main/ets/services/ai/AiProviderConfigStore.ets entry/src/test/AiImportContracts.test.cjs`

Expected: 配置 Preferences 中没有 Key、credential 或 Authorization 字段；不要提交。

## Task 3: 使用 HUKS 加密 API Key 并排除备份

**Files:**
- Create: `entry/src/main/ets/services/ai/HuksAesGcmCipher.ets`
- Create: `entry/src/main/ets/services/ai/AiCredentialEnvelopeCodec.ets`
- Create: `entry/src/main/ets/services/ai/AiCredentialStore.ets`
- Create: `entry/src/test/AiImportSecurityContracts.test.cjs`
- Create: `entry/src/ohosTest/ets/test/AiCredentialStore.test.ets`
- Modify: `entry/src/ohosTest/ets/test/List.test.ets:1-5`
- Modify: `entry/src/main/resources/base/profile/backup_config.json:1-3`

- [ ] **Step 1: 写 HUKS 与无明文持久化失败合同**

Create `entry/src/test/AiImportSecurityContracts.test.cjs`:

```js
const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')

function read(path) {
  return fs.readFileSync(path, 'utf8')
}

test('credential storage uses HUKS AES-256-GCM and a versioned envelope', () => {
  const cipher = read('entry/src/main/ets/services/ai/HuksAesGcmCipher.ets')
  const codec = read('entry/src/main/ets/services/ai/AiCredentialEnvelopeCodec.ets')
  const store = read('entry/src/main/ets/services/ai/AiCredentialStore.ets')
  assert.match(cipher, /HUKS_AES_KEY_SIZE_256/)
  assert.match(cipher, /HUKS_MODE_GCM/)
  assert.match(cipher, /HUKS_PADDING_NONE/)
  assert.match(cipher, /NONCE_LENGTH:\s*number\s*=\s*12/)
  assert.match(cipher, /TAG_LENGTH:\s*number\s*=\s*16/)
  assert.match(cipher, /abortSession/)
  assert.doesNotMatch(cipher, /exportKeyItem|console\.|hilog\./)
  assert.match(codec, /'1\.'/)
  assert.match(store, /withCredential/)
  assert.doesNotMatch(store, /getCredential|getApiKey|console\.|hilog\./i)
})

test('credential preferences are excluded from device backup', () => {
  const config = JSON.parse(read('entry/src/main/resources/base/profile/backup_config.json'))
  assert.equal(config.allowToBackupRestore, true)
  assert.deepEqual(config.excludes, [
    'data/storage/el2/base/preferences/ai_credentials.xml'
  ])
})
```

- [ ] **Step 2: 运行合同确认失败**

Run: `node --test entry/src/test/AiImportSecurityContracts.test.cjs`

Expected: FAIL with `ENOENT` for the HUKS files or missing `excludes`.

- [ ] **Step 3: 实现 HUKS AES-256-GCM 包装器**

Create `entry/src/main/ets/services/ai/HuksAesGcmCipher.ets` with the following public model and exact session rules:

```ts
import { huks } from '@kit.UniversalKeystoreKit'
import { cryptoFramework } from '@kit.CryptoArchitectureKit'
import { util } from '@kit.ArkTS'

const KEY_ALIAS: string = 'wrongquestion.ai.credentials.aes.v1'
const NONCE_LENGTH: number = 12
const TAG_LENGTH: number = 16
const AAD_TEXT: string = 'wrongquestion.ai.credentials.v1'

export class HuksCipherText {
  nonce: Uint8Array
  ciphertext: Uint8Array
  tag: Uint8Array

  constructor(nonce: Uint8Array, ciphertext: Uint8Array, tag: Uint8Array) {
    this.nonce = nonce
    this.ciphertext = ciphertext
    this.tag = tag
  }
}

export class HuksAesGcmCipher {
  private static keyCreation: Promise<void> | null = null

  static async encrypt(plainText: Uint8Array): Promise<HuksCipherText> {
    await HuksAesGcmCipher.ensureKey()
    const random: cryptoFramework.Random = cryptoFramework.createRandom()
    const blob: cryptoFramework.DataBlob = await random.generateRandom(NONCE_LENGTH)
    const nonce: Uint8Array = blob.data
    const options: huks.HuksOptions = {
      properties: HuksAesGcmCipher.operationProperties(
        huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT, nonce, null),
      inData: plainText
    }
    const output: Uint8Array = await HuksAesGcmCipher.finish(options)
    if (output.length <= TAG_LENGTH) {
      throw new Error('AI credential encryption failed')
    }
    return new HuksCipherText(nonce.slice(), output.slice(0, output.length - TAG_LENGTH),
      output.slice(output.length - TAG_LENGTH))
  }

  static async decrypt(value: HuksCipherText): Promise<Uint8Array> {
    if (value.nonce.length !== NONCE_LENGTH || value.tag.length !== TAG_LENGTH ||
      value.ciphertext.length === 0) {
      throw new Error('AI credential envelope is invalid')
    }
    await HuksAesGcmCipher.ensureKey()
    const options: huks.HuksOptions = {
      properties: HuksAesGcmCipher.operationProperties(
        huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT, value.nonce, value.tag),
      inData: value.ciphertext
    }
    return HuksAesGcmCipher.finish(options)
  }

  static async hasKey(): Promise<boolean> {
    return huks.hasKeyItem(KEY_ALIAS, { properties: [] })
  }

  static async deleteKey(): Promise<void> {
    if (await HuksAesGcmCipher.hasKey()) {
      await huks.deleteKeyItem(KEY_ALIAS, { properties: [] })
    }
  }

  private static async ensureKey(): Promise<void> {
    if (await HuksAesGcmCipher.hasKey()) return
    if (HuksAesGcmCipher.keyCreation === null) {
      HuksAesGcmCipher.keyCreation = HuksAesGcmCipher.generateKey()
    }
    const pending: Promise<void> | null = HuksAesGcmCipher.keyCreation
    if (pending === null) throw new Error('AI credential key creation failed')
    try {
      await pending
    } finally {
      if (HuksAesGcmCipher.keyCreation === pending) {
        HuksAesGcmCipher.keyCreation = null
      }
    }
  }

  private static async generateKey(): Promise<void> {
    if (await HuksAesGcmCipher.hasKey()) return
    const options: huks.HuksOptions = {
      properties: [
        { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
        { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
        {
          tag: huks.HuksTag.HUKS_TAG_PURPOSE,
          value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT |
            huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT
        }
      ]
    }
    await huks.generateKeyItem(KEY_ALIAS, options)
  }

  private static operationProperties(purpose: number, nonce: Uint8Array,
    tag: Uint8Array | null): Array<huks.HuksParam> {
    const encoder: util.TextEncoder = new util.TextEncoder('utf-8')
    const properties: Array<huks.HuksParam> = [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
      { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
      { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: purpose },
      { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
      { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
      { tag: huks.HuksTag.HUKS_TAG_NONCE, value: nonce },
      { tag: huks.HuksTag.HUKS_TAG_ASSOCIATED_DATA, value: encoder.encodeInto(AAD_TEXT) }
    ]
    if (tag !== null) {
      properties.push({ tag: huks.HuksTag.HUKS_TAG_AE_TAG, value: tag })
    }
    return properties
  }

  private static async finish(options: huks.HuksOptions): Promise<Uint8Array> {
    let handle: number = -1
    let finished: boolean = false
    try {
      const session: huks.HuksSessionHandle = await huks.initSession(KEY_ALIAS, options)
      handle = session.handle
      const result: huks.HuksReturnResult = await huks.finishSession(handle, options)
      finished = true
      if (result.outData === undefined) {
        throw new Error('AI credential operation failed')
      }
      return result.outData
    } finally {
      if (handle >= 0 && !finished) {
        try {
          await huks.abortSession(handle, { properties: [] })
        } catch {
        }
      }
    }
  }
}
```

- [ ] **Step 4: 实现 envelope codec 与窄作用域凭据存储**

Create `entry/src/main/ets/services/ai/AiCredentialEnvelopeCodec.ets`:

```ts
import { util } from '@kit.ArkTS'
import { HuksCipherText } from './HuksAesGcmCipher'

export class AiCredentialEnvelopeCodec {
  static encode(value: HuksCipherText): string {
    const base64: util.Base64Helper = new util.Base64Helper()
    return '1.' + base64.encodeToStringSync(value.nonce, util.Type.BASIC) + '.' +
      base64.encodeToStringSync(value.ciphertext, util.Type.BASIC) + '.' +
      base64.encodeToStringSync(value.tag, util.Type.BASIC)
  }

  static decode(value: string): HuksCipherText {
    const parts: Array<string> = value.split('.')
    if (parts.length !== 4 || parts[0] !== '1') {
      throw new Error('AI credential envelope is invalid')
    }
    const base64: util.Base64Helper = new util.Base64Helper()
    const nonce: Uint8Array = base64.decodeSync(parts[1], util.Type.BASIC)
    const ciphertext: Uint8Array = base64.decodeSync(parts[2], util.Type.BASIC)
    const tag: Uint8Array = base64.decodeSync(parts[3], util.Type.BASIC)
    if (nonce.length !== 12 || ciphertext.length === 0 || tag.length !== 16 ||
      base64.encodeToStringSync(nonce, util.Type.BASIC) !== parts[1] ||
      base64.encodeToStringSync(ciphertext, util.Type.BASIC) !== parts[2] ||
      base64.encodeToStringSync(tag, util.Type.BASIC) !== parts[3]) {
      throw new Error('AI credential envelope is invalid')
    }
    return new HuksCipherText(nonce, ciphertext, tag)
  }
}
```

Create `entry/src/main/ets/services/ai/AiCredentialStore.ets`:

```ts
import { Context } from '@kit.AbilityKit'
import { preferences } from '@kit.ArkData'
import { util } from '@kit.ArkTS'
import { AiImportError, AiImportErrorCode } from '../../models/ai/AiProviderConfig'
import { AiCredentialEnvelopeCodec } from './AiCredentialEnvelopeCodec'
import { HuksAesGcmCipher, HuksCipherText } from './HuksAesGcmCipher'

const PREFERENCES_NAME: string = 'ai_credentials'
const ENVELOPE_KEY: string = 'credential_envelope'

export class AiCredentialStore {
  static async save(context: Context, apiKey: string): Promise<void> {
    const normalized: string = apiKey.trim()
    if (normalized.length === 0) {
      throw new AiImportError(AiImportErrorCode.MISSING_API_KEY)
    }
    const encoder: util.TextEncoder = new util.TextEncoder('utf-8')
    const plainText: Uint8Array = encoder.encodeInto(normalized)
    let encrypted: HuksCipherText | null = null
    try {
      encrypted = await HuksAesGcmCipher.encrypt(plainText)
      const store: preferences.Preferences = await preferences.getPreferences(context, PREFERENCES_NAME)
      await store.put(ENVELOPE_KEY, AiCredentialEnvelopeCodec.encode(encrypted))
      await store.flush()
    } finally {
      plainText.fill(0)
      if (encrypted !== null) {
        encrypted.ciphertext.fill(0)
        encrypted.tag.fill(0)
      }
    }
  }

  static async hasCredential(context: Context): Promise<boolean> {
    const store: preferences.Preferences = await preferences.getPreferences(context, PREFERENCES_NAME)
    const raw: preferences.ValueType = await store.get(ENVELOPE_KEY, '')
    if (typeof raw !== 'string' || raw.length === 0) return false
    if (!await HuksAesGcmCipher.hasKey()) {
      await AiCredentialStore.clearEnvelope(store)
      return false
    }
    return true
  }

  static async withCredential<T>(context: Context,
    action: (credential: Uint8Array) => Promise<T>): Promise<T> {
    const store: preferences.Preferences = await preferences.getPreferences(context, PREFERENCES_NAME)
    const raw: preferences.ValueType = await store.get(ENVELOPE_KEY, '')
    if (typeof raw !== 'string' || raw.length === 0 || !await HuksAesGcmCipher.hasKey()) {
      await AiCredentialStore.clearEnvelope(store)
      throw new AiImportError(AiImportErrorCode.MISSING_API_KEY)
    }
    let plainText: Uint8Array | null = null
    try {
      plainText = await HuksAesGcmCipher.decrypt(AiCredentialEnvelopeCodec.decode(raw))
      return await action(plainText)
    } catch (err) {
      if (plainText === null) {
        await AiCredentialStore.clearEnvelope(store)
        throw new AiImportError(AiImportErrorCode.MISSING_API_KEY)
      }
      throw err
    } finally {
      if (plainText !== null) plainText.fill(0)
    }
  }

  static async clear(context: Context): Promise<void> {
    const store: preferences.Preferences = await preferences.getPreferences(context, PREFERENCES_NAME)
    await AiCredentialStore.clearEnvelope(store)
    await HuksAesGcmCipher.deleteKey()
  }

  private static async clearEnvelope(store: preferences.Preferences): Promise<void> {
    await store.delete(ENVELOPE_KEY)
    await store.flush()
  }
}
```

The implementation must keep the UI's temporary API Key in one `@State` string only until `save()` resolves, then assign `''`; because ArkTS strings are immutable, claim only that byte buffers are zeroed and string lifetime is minimized.

- [ ] **Step 5: 精确排除凭据备份并添加真机测试套件**

Replace `entry/src/main/resources/base/profile/backup_config.json` with:

```json
{
  "allowToBackupRestore": true,
  "excludes": [
    "data/storage/el2/base/preferences/ai_credentials.xml"
  ]
}
```

Create `entry/src/ohosTest/ets/test/AiCredentialStore.test.ets` with these exact helpers and cases:

```ts
import { describe, it, expect } from '@ohos/hypium'
import { Context } from '@kit.AbilityKit'
import { preferences } from '@kit.ArkData'
import { huks } from '@kit.UniversalKeystoreKit'
import { AiImportError, AiImportErrorCode } from '../../../main/ets/models/ai/AiProviderConfig'
import { AiCredentialStore } from '../../../main/ets/services/ai/AiCredentialStore'
import { HuksAesGcmCipher } from '../../../main/ets/services/ai/HuksAesGcmCipher'
import { Utf8Utils } from '../../../main/ets/utils/Utf8Utils'

const ALIAS: string = 'wrongquestion.ai.credentials.aes.v1'

async function envelope(context: Context): Promise<string> {
  const store: preferences.Preferences = await preferences.getPreferences(context, 'ai_credentials')
  const raw: preferences.ValueType = await store.get('credential_envelope', '')
  return typeof raw === 'string' ? raw : ''
}

async function replaceEnvelope(context: Context, value: string): Promise<void> {
  const store: preferences.Preferences = await preferences.getPreferences(context, 'ai_credentials')
  await store.put('credential_envelope', value)
  await store.flush()
}

function mutateSegment(value: string, segmentIndex: number): string {
  const parts: Array<string> = value.split('.')
  const segment: string = parts[segmentIndex]
  const first: string = segment.charAt(0) === 'A' ? 'B' : 'A'
  parts[segmentIndex] = first + segment.substring(1)
  return parts.join('.')
}

async function expectMissingKey(context: Context): Promise<void> {
  let code: string = ''
  try {
    await AiCredentialStore.withCredential<void>(context,
      async (_credential: Uint8Array): Promise<void> => {})
  } catch (err) {
    if (err instanceof AiImportError) code = err.code
  }
  expect(code).assertEqual(AiImportErrorCode.MISSING_API_KEY)
  expect((await envelope(context)).length).assertEqual(0)
}

export default function aiCredentialStoreTest(): void {
  describe('aiCredentialStore', () => {
    it('round trips Unicode without plaintext preferences', 0, async () => {
      const context: Context = getContext()
      const secret: string = 'sk-device-only-数学'
      await AiCredentialStore.clear(context)
      await AiCredentialStore.save(context, secret)
      let recovered: string = ''
      await AiCredentialStore.withCredential<void>(context,
        async (bytes: Uint8Array): Promise<void> => { recovered = Utf8Utils.decode(bytes) })
      const store: preferences.Preferences = await preferences.getPreferences(context, 'ai_credentials')
      const raw: preferences.ValueType = await store.get('credential_envelope', '')
      expect(recovered).assertEqual(secret)
      expect(typeof raw === 'string' && raw.indexOf(secret) < 0).assertTrue()
      await AiCredentialStore.clear(context)
      expect(await AiCredentialStore.hasCredential(context)).assertFalse()
    })

    it('uses a fresh nonce on every save', 0, async () => {
      const context: Context = getContext()
      await AiCredentialStore.clear(context)
      await AiCredentialStore.save(context, 'sk-first')
      const firstNonce: string = (await envelope(context)).split('.')[1]
      await AiCredentialStore.save(context, 'sk-second')
      const secondNonce: string = (await envelope(context)).split('.')[1]
      expect(firstNonce === secondNonce).assertFalse()
      await AiCredentialStore.clear(context)
    })

    it('rejects one-character tampering in nonce, ciphertext, and tag', 0, async () => {
      const context: Context = getContext()
      for (let segmentIndex: number = 1; segmentIndex <= 3; segmentIndex++) {
        await AiCredentialStore.clear(context)
        await AiCredentialStore.save(context, 'sk-tamper-check')
        await replaceEnvelope(context, mutateSegment(await envelope(context), segmentIndex))
        await expectMissingKey(context)
      }
      await AiCredentialStore.clear(context)
    })

    it('clears an envelope whose device key is missing', 0, async () => {
      const context: Context = getContext()
      await AiCredentialStore.clear(context)
      await AiCredentialStore.save(context, 'sk-stale')
      await HuksAesGcmCipher.deleteKey()
      expect(await AiCredentialStore.hasCredential(context)).assertFalse()
      expect((await envelope(context)).length).assertEqual(0)
    })

    it('does not export the device AES key', 0, async () => {
      const context: Context = getContext()
      await AiCredentialStore.clear(context)
      await AiCredentialStore.save(context, 'sk-non-exportable')
      let rejected: boolean = false
      try {
        await huks.exportKeyItem(ALIAS, { properties: [] })
      } catch {
        rejected = true
      }
      expect(rejected).assertTrue()
      await AiCredentialStore.clear(context)
    })
  })
}
```

Modify `entry/src/ohosTest/ets/test/List.test.ets` to:

```ts
import abilityTest from './Ability.test'
import aiCredentialStoreTest from './AiCredentialStore.test'

export default function testsuite(): void {
  abilityTest()
  aiCredentialStoreTest()
}
```

- [ ] **Step 6: 运行合同、ArkTS 检查和可用设备测试**

Run:

```powershell
node --test entry/src/test/AiImportSecurityContracts.test.cjs
node 'C:/Users/32773/.agents/skills/harmonyos-dev-skill/scripts/arkts-check.cjs' --project . --files `
  entry/src/main/ets/services/ai/HuksAesGcmCipher.ets `
  entry/src/main/ets/services/ai/AiCredentialEnvelopeCodec.ets `
  entry/src/main/ets/services/ai/AiCredentialStore.ets
hdc list targets
```

Expected: contract PASS，ArkTS JSON `success: true`。有 API 24+ 设备时运行 ohosTest 并 PASS；无设备时记录 `HUKS device test: NOT RUN (no hdc target)`，不能把源码合同当作真机通过。

- [ ] **Step 7: 无提交 diff 检查点**

Run: `git diff -- entry/src/main/ets/services/ai entry/src/main/resources/base/profile/backup_config.json entry/src/test/AiImportSecurityContracts.test.cjs entry/src/ohosTest/ets/test`

Expected: 无明文 Key、日志、异常详情或 export 调用进入主代码；测试中的 `exportKeyItem` 仅用于断言不可导出；不要提交。

## Task 4: 构建固定 Prompt 与严格题目 JSON 解析器

**Files:**
- Create: `entry/src/main/ets/services/ai/MathQuestionPromptBuilder.ets`
- Create: `entry/src/main/ets/services/ai/AiQuestionResponseParser.ets`
- Modify: `entry/src/test/AiImportLocalUnit.test.ets`

- [ ] **Step 1: 写 Prompt、Schema、围栏和恶意响应失败测试**

Add these imports and suites to `entry/src/test/AiImportLocalUnit.test.ets`:

```ts
import { AiQuestionType } from '../main/ets/models/ai/AiImportModels'
import { MathQuestionPromptBuilder } from '../main/ets/services/ai/MathQuestionPromptBuilder'
import { AiQuestionResponseParser } from '../main/ets/services/ai/AiQuestionResponseParser'

describe('mathQuestionPromptBuilder', () => {
  it('contains the page context, schema and required math rules without secrets', 0, () => {
    const prompt: string = MathQuestionPromptBuilder.build(2, 6, '上一页末尾')
    expect(prompt.indexOf('第 2 页，共 6 页') >= 0).assertTrue()
    expect(prompt.indexOf('上一页末尾') >= 0).assertTrue()
    expect(prompt.indexOf('"type"') >= 0).assertTrue()
    expect(prompt.indexOf('"bbox"') >= 0).assertTrue()
    expect(prompt.indexOf('\\frac') >= 0).assertTrue()
    expect(prompt.indexOf('\\sqrt') >= 0).assertTrue()
    expect(prompt.indexOf('f^{-1}(x)') >= 0).assertTrue()
    expect(prompt.indexOf('\\begin{cases}') >= 0).assertTrue()
    expect(prompt.toLowerCase().indexOf('api key') < 0).assertTrue()
    expect(prompt.toLowerCase().indexOf('authorization') < 0).assertTrue()
  })
})

describe('aiQuestionResponseParser', () => {
  it('keeps visual order and maps typed fields', 0, () => {
    const json: string = '{"questions":[' +
      '{"label":"例1.2","type":"unknown","question":"求 $\\\\sqrt{x}$",' +
      '"options":null,"answer":null,"analysis":null,' +
      '"bbox":{"x1":10,"y1":20,"x2":900,"y2":400}},' +
      '{"label":"Q4","type":"single_choice","question":"选择",' +
      '"options":{"B":"乙","A":"甲"},"answer":"A","analysis":"理由",' +
      '"bbox":{"x1":0,"y1":0,"x2":1000,"y2":1000}}]}'
    const questions = AiQuestionResponseParser.parse(json, 3)
    expect(questions.length).assertEqual(2)
    expect(questions[0].label).assertEqual('例1.2')
    expect(questions[1].type).assertEqual(AiQuestionType.SINGLE_CHOICE)
    expect(questions[1].options[0].key).assertEqual('A')
    expect(questions[1].options[1].key).assertEqual('B')
  })

  it('accepts one complete json fence only', 0, () => {
    const source: string = '```json\n{"questions":[{"label":"1.","type":"unknown",' +
      '"question":"题目","options":null,"answer":null,"analysis":null,' +
      '"bbox":{"x1":0,"y1":0,"x2":1000,"y2":1000}}]}\n```'
    expect(AiQuestionResponseParser.parse(source, 1).length).assertEqual(1)
    let rejected: boolean = false
    try {
      AiQuestionResponseParser.parse(source + '\n解释', 1)
    } catch {
      rejected = true
    }
    expect(rejected).assertTrue()
  })

  it('uses a whole-page fallback for bad bbox but rejects unsafe page content', 0, () => {
    const badBox: string = '{"questions":[{"label":"第3题","type":"short_answer",' +
      '"question":"证明题","options":null,"answer":null,"analysis":null,' +
      '"bbox":{"x1":700,"y1":20,"x2":600,"y2":30}}]}'
    expect(AiQuestionResponseParser.parse(badBox, 1)[0].bboxUsable).assertFalse()
    const unsafe: Array<string> = [
      '<script>alert(1)</script>',
      '<img src=x onerror=alert(1)>',
      'javascript:alert(1)',
      '$\\\\begin{cases}x,&x>0\\\\end{matrix}$',
      '∫2−x'
    ]
    for (let index: number = 0; index < unsafe.length; index++) {
      const payload: string = '{"questions":[{"label":"1.","type":"unknown","question":' +
        JSON.stringify(unsafe[index]) + ',"options":null,"answer":null,"analysis":null,' +
        '"bbox":{"x1":0,"y1":0,"x2":1000,"y2":1000}}]}'
      let rejected: boolean = false
      try {
        AiQuestionResponseParser.parse(payload, 1)
      } catch {
        rejected = true
      }
      expect(rejected).assertTrue()
    }
  })
})
```

- [ ] **Step 2: 运行 Hypium 确认失败**

Run:

```powershell
& 'D:/Program Files/Huawei/DevEco Studio/tools/node/node.exe' `
  'D:/Program Files/Huawei/DevEco Studio/tools/hvigor/bin/hvigorw.js' test `
  --mode module -p module=entry@default
```

Expected: FAIL because both AI parser modules are missing.

- [ ] **Step 3: 实现固定 Prompt**

Create `entry/src/main/ets/services/ai/MathQuestionPromptBuilder.ets`:

```ts
import { AiImportLimits } from '../../constants/AiImportLimits'

const OUTPUT_SCHEMA: string = '{"questions":[{' +
  '"label":"例1.5",' +
  '"type":"single_choice|blank|short_answer|unknown",' +
  '"question":"题干，数学表达式使用 $...$ 或 $$...$$",' +
  '"options":null,' +
  '"answer":null,' +
  '"analysis":null,' +
  '"bbox":{"x1":0,"y1":0,"x2":1000,"y2":1000}}]}'

export class MathQuestionPromptBuilder {
  static build(pageNumber: number, totalPages: number, previousPageTail: string): string {
    const tail: string = previousPageTail.trim().substring(0,
      AiImportLimits.MAX_PREVIOUS_CONTEXT_LENGTH)
    const context: string = tail.length === 0 ? '无' : tail
    return '你是一个数学试题视觉转录引擎。准确读取给定页面图片，按视觉顺序提取题目。\n' +
      '当前页面：第 ' + pageNumber.toString() + ' 页，共 ' + totalPages.toString() + ' 页。\n' +
      '上一页末尾上下文：' + context + '\n' +
      '只返回一个合法 JSON 对象，不返回 Markdown 围栏、解释或额外文字。\n' +
      '输出 JSON Schema：' + OUTPUT_SCHEMA + '\n' +
      'type 只能是 single_choice、blank、short_answer 或 unknown，不根据答案猜测。\n' +
      'bbox 使用页面 0–1000 归一化坐标。完整保留中文。' +
      '数学公式转成 KaTeX 兼容 LaTeX；行内用 $...$，独立公式用 $$...$$。\n' +
      '分数用 \\frac{}{}，根式用 \\sqrt{}，逆函数用 f^{-1}(x)，' +
      '≤ 和 ≥ 分别用 \\le 和 \\ge。\n' +
      '每个分段函数使用独立的 \\begin{cases} expression, & condition \\\\ ' +
      'expression, & condition \\end{cases}。不要把左大括号识别为积分号，禁止输出 ∫2−x。\n' +
      '不得臆造题目、答案或解析；无法辨认的局部写 [无法识别]。' +
      '没有选项时 options 为 null，有选项时键只能是 A–J 的对象。\n' +
      'LaTeX 反斜杠按 JSON 规则转义；输出前检查 JSON 字符串、括号、公式分隔符、' +
      '花括号、cases 行和 begin/end 环境均闭合。'
  }
}
```

- [ ] **Step 4: 实现专用递归下降解析器**

Create `entry/src/main/ets/services/ai/AiQuestionResponseParser.ets`. Copy the character-level primitives `skipWhitespace`, `peek`, `expect`, `readString`, `readUnicode`, `hexValue`, `skipValue`, `skipObject`, `skipArray`, `skipNumber`, `skipDigits`, and `skipLiteral` from the existing `entry/src/main/ets/utils/JsonParser.ets:55-258` into a private `AiJsonReader`; keep them private to this new file. Add these exact typed productions:

```ts
import { AiImportLimits } from '../../constants/AiImportLimits'
import { AiImportError, AiImportErrorCode } from '../../models/ai/AiProviderConfig'
import {
  AiBoundingBox,
  AiOption,
  AiQuestionDraft,
  AiQuestionType
} from '../../models/ai/AiImportModels'

class NullableText {
  value: string
  constructor(value: string) { this.value = value }
}

class ParsedBox {
  value: AiBoundingBox
  present: boolean
  constructor(value: AiBoundingBox, present: boolean) {
    this.value = value
    this.present = present
  }
}

class AiJsonReader {
  private text: string
  private index: number = 0

  constructor(text: string) { this.text = text }

  readQuestions(pageNumber: number): Array<AiQuestionDraft> {
    let questions: Array<AiQuestionDraft> = new Array<AiQuestionDraft>()
    let hasQuestions: boolean = false
    this.expect('{')
    if (this.nextIs('}')) {
      this.expect('}')
    } else {
      while (true) {
        const key: string = this.readString()
        this.expect(':')
        if (key !== 'questions' || hasQuestions) this.invalidJson()
        questions = this.readQuestionArray(pageNumber)
        hasQuestions = true
        if (this.nextIs('}')) {
          this.expect('}')
          break
        }
        this.expect(',')
      }
    }
    this.skipWhitespace()
    if (this.index !== this.text.length || !hasQuestions) this.invalidJson()
    if (questions.length === 0) throw new AiImportError(AiImportErrorCode.NO_QUESTIONS)
    return questions
  }

  private readQuestionArray(pageNumber: number): Array<AiQuestionDraft> {
    const values: Array<AiQuestionDraft> = new Array<AiQuestionDraft>()
    this.expect('[')
    if (this.nextIs(']')) {
      this.expect(']')
      return values
    }
    while (true) {
      if (values.length >= AiImportLimits.MAX_QUESTIONS_PER_PAGE) this.invalidJson()
      values.push(this.readQuestion(pageNumber))
      if (this.nextIs(']')) {
        this.expect(']')
        return values
      }
      this.expect(',')
    }
  }

  private readQuestion(pageNumber: number): AiQuestionDraft {
    let label: string = ''
    let typeText: string = ''
    let question: string = ''
    let options: Array<AiOption> = new Array<AiOption>()
    let answer: string = ''
    let analysis: string = ''
    let box: ParsedBox = new ParsedBox(new AiBoundingBox(0, 0, 1000, 1000), false)
    let seen: Array<string> = new Array<string>()
    this.expect('{')
    while (!this.nextIs('}')) {
      const key: string = this.readString()
      if (seen.indexOf(key) >= 0) this.invalidJson()
      seen.push(key)
      this.expect(':')
      if (key === 'label') label = this.readString()
      else if (key === 'type') typeText = this.readString()
      else if (key === 'question') question = this.readString()
      else if (key === 'options') options = this.readOptions()
      else if (key === 'answer') answer = this.readNullableString().value
      else if (key === 'analysis') analysis = this.readNullableString().value
      else if (key === 'bbox') box = this.readBox()
      else this.invalidJson()
      if (!this.nextIs('}')) this.expect(',')
    }
    this.expect('}')
    const required: Array<string> = ['label', 'type', 'question', 'options', 'answer', 'analysis']
    for (let index: number = 0; index < required.length; index++) {
      if (seen.indexOf(required[index]) < 0) this.invalidJson()
    }
    const type: AiQuestionType = AiQuestionValidation.type(typeText)
    AiQuestionValidation.label(label)
    AiQuestionValidation.text(question, AiImportLimits.MAX_QUESTION_LENGTH, false)
    AiQuestionValidation.text(answer, AiImportLimits.MAX_ANSWER_LENGTH, true)
    AiQuestionValidation.text(analysis, AiImportLimits.MAX_ANALYSIS_LENGTH, true)
    for (let index: number = 0; index < options.length; index++) {
      AiQuestionValidation.text(options[index].value, AiImportLimits.MAX_OPTION_LENGTH, false)
    }
    AiQuestionValidation.latex(question + '\n' + answer + '\n' + analysis)
    return new AiQuestionDraft(label.trim(), type, question.trim(), options, answer.trim(),
      analysis.trim(), box.value, AiQuestionValidation.usableBox(box), pageNumber)
  }

  private readOptions(): Array<AiOption> {
    if (this.nextLiteral('null')) {
      this.skipLiteral('null')
      return new Array<AiOption>()
    }
    const values: Array<AiOption> = new Array<AiOption>()
    this.expect('{')
    while (!this.nextIs('}')) {
      const key: string = this.readString().trim().toUpperCase()
      if (!/^[A-J]$/.test(key) || values.length >= 10) this.invalidJson()
      for (let index: number = 0; index < values.length; index++) {
        if (values[index].key === key) this.invalidJson()
      }
      this.expect(':')
      values.push(new AiOption(key, this.readString()))
      if (!this.nextIs('}')) this.expect(',')
    }
    this.expect('}')
    values.sort((left: AiOption, right: AiOption): number => left.key.localeCompare(right.key))
    return values
  }

  private readNullableString(): NullableText {
    if (this.nextLiteral('null')) {
      this.skipLiteral('null')
      return new NullableText('')
    }
    return new NullableText(this.readString())
  }

  private readBox(): ParsedBox {
    let x1: number = 0
    let y1: number = 0
    let x2: number = 1000
    let y2: number = 1000
    const seen: Array<string> = new Array<string>()
    this.expect('{')
    while (!this.nextIs('}')) {
      const key: string = this.readString()
      if (seen.indexOf(key) >= 0) this.invalidJson()
      seen.push(key)
      this.expect(':')
      const value: number = this.readNumber()
      if (key === 'x1') x1 = value
      else if (key === 'y1') y1 = value
      else if (key === 'x2') x2 = value
      else if (key === 'y2') y2 = value
      else this.invalidJson()
      if (!this.nextIs('}')) this.expect(',')
    }
    this.expect('}')
    return new ParsedBox(new AiBoundingBox(x1, y1, x2, y2), seen.length === 4)
  }

  private readNumber(): number {
    this.skipWhitespace()
    const start: number = this.index
    this.skipNumber()
    const value: number = Number(this.text.substring(start, this.index))
    if (!Number.isFinite(value)) this.invalidJson()
    return value
  }

  private nextIs(character: string): boolean {
    this.skipWhitespace()
    return this.peek() === character
  }

  private nextLiteral(literal: string): boolean {
    this.skipWhitespace()
    return this.text.substring(this.index, this.index + literal.length) === literal
  }

  private invalidJson(): void {
    throw new AiImportError(AiImportErrorCode.INVALID_JSON)
  }
}

class AiQuestionValidation {
  static type(value: string): AiQuestionType {
    if (value === AiQuestionType.SINGLE_CHOICE) return AiQuestionType.SINGLE_CHOICE
    if (value === AiQuestionType.BLANK) return AiQuestionType.BLANK
    if (value === AiQuestionType.SHORT_ANSWER) return AiQuestionType.SHORT_ANSWER
    if (value === AiQuestionType.UNKNOWN) return AiQuestionType.UNKNOWN
    throw new AiImportError(AiImportErrorCode.INVALID_JSON)
  }

  static label(value: string): void {
    const normalized: string = value.trim()
    if (normalized.length < 1 || normalized.length > AiImportLimits.MAX_LABEL_LENGTH ||
      !/^(?:例\s*[0-9]+(?:\.[0-9]+)*|[0-9]+[.．、]?|第\s*[0-9]+\s*题|Q\s*[0-9]+)$/i.test(normalized)) {
      throw new AiImportError(AiImportErrorCode.INVALID_JSON)
    }
  }

  static text(value: string, maximum: number, emptyAllowed: boolean): void {
    if ((!emptyAllowed && value.trim().length === 0) || value.length > maximum ||
      /<\s*\/?\s*[a-z][^>]*>/i.test(value) || /javascript\s*:/i.test(value) ||
      /\bon[a-z]+\s*=/i.test(value)) {
      throw new AiImportError(AiImportErrorCode.INVALID_JSON)
    }
    for (let index: number = 0; index < value.length; index++) {
      const code: number = value.charCodeAt(index)
      if (code < 32 && code !== 9 && code !== 10 && code !== 13) {
        throw new AiImportError(AiImportErrorCode.INVALID_JSON)
      }
    }
  }

  static usableBox(box: ParsedBox): boolean {
    const value: AiBoundingBox = box.value
    return box.present && Number.isFinite(value.x1) && Number.isFinite(value.y1) &&
      Number.isFinite(value.x2) && Number.isFinite(value.y2) &&
      value.x1 >= 0 && value.y1 >= 0 && value.x2 <= 1000 && value.y2 <= 1000 &&
      value.x2 - value.x1 >= AiImportLimits.MIN_BBOX_EDGE &&
      value.y2 - value.y1 >= AiImportLimits.MIN_BBOX_EDGE
  }

  static latex(value: string): void {
    if (value.indexOf('∫2−x') >= 0 || !AiQuestionValidation.balancedDollars(value) ||
      !AiQuestionValidation.balancedBraces(value) || !AiQuestionValidation.balancedEnvironments(value) ||
      !AiQuestionValidation.validCases(value)) {
      throw new AiImportError(AiImportErrorCode.LATEX_INVALID)
    }
  }

  private static balancedDollars(value: string): boolean {
    let delimiterWidth: number = 0
    for (let index: number = 0; index < value.length; index++) {
      if (value.charAt(index) === '\\') {
        index++
      } else if (value.charAt(index) === '$') {
        const width: number = value.charAt(index + 1) === '$' ? 2 : 1
        if (delimiterWidth === 0) delimiterWidth = width
        else if (delimiterWidth === width) delimiterWidth = 0
        else return false
        if (width === 2) index++
      }
    }
    return delimiterWidth === 0
  }

  private static balancedBraces(value: string): boolean {
    let depth: number = 0
    for (let index: number = 0; index < value.length; index++) {
      const character: string = value.charAt(index)
      if (character === '\\') index++
      else if (character === '{') depth++
      else if (character === '}') {
        depth--
        if (depth < 0) return false
      }
    }
    return depth === 0
  }

  private static balancedEnvironments(value: string): boolean {
    const token: RegExp = /\\(begin|end)\{([A-Za-z*]+)\}/g
    const stack: Array<string> = new Array<string>()
    let match: RegExpExecArray | null = token.exec(value)
    while (match !== null) {
      if (match[1] === 'begin') stack.push(match[2])
      else if (stack.length === 0 || stack.pop() !== match[2]) return false
      match = token.exec(value)
    }
    return stack.length === 0
  }

  private static validCases(value: string): boolean {
    const begin: string = '\\begin{cases}'
    const end: string = '\\end{cases}'
    let offset: number = 0
    while (value.indexOf(begin, offset) >= 0) {
      const start: number = value.indexOf(begin, offset) + begin.length
      const finish: number = value.indexOf(end, start)
      if (finish < 0) return false
      const rows: Array<string> = value.substring(start, finish).split('\\\\')
      let nonEmpty: number = 0
      for (let index: number = 0; index < rows.length; index++) {
        if (rows[index].trim().length > 0) {
          nonEmpty++
          if (rows[index].indexOf('&') < 0) return false
        }
      }
      if (nonEmpty === 0) return false
      offset = finish + end.length
    }
    return value.indexOf(end, offset) < 0
  }
}

export class AiQuestionResponseParser {
  static parse(response: string, pageNumber: number): Array<AiQuestionDraft> {
    const text: string = AiQuestionResponseParser.unwrapFence(response)
    return new AiJsonReader(text).readQuestions(pageNumber)
  }

  private static unwrapFence(response: string): string {
    const trimmed: string = response.trim()
    if (!trimmed.startsWith('```')) return trimmed
    const match: RegExpMatchArray | null = trimmed.match(/^```(?:json)?[ \t]*\r?\n([\s\S]*)\r?\n```$/i)
    if (match === null) throw new AiImportError(AiImportErrorCode.INVALID_JSON)
    return match[1].trim()
  }
}
```

Reject unknown and duplicate fields rather than silently skipping them. `bbox` may be absent or unusable and then becomes the whole-page fallback; every other structural or LaTeX failure rejects the entire page.

- [ ] **Step 5: 运行 parser 测试并补齐边界数据表**

Add these helpers and cases to the same suite:

```ts
function repeatText(value: string, count: number): string {
  let result: string = ''
  for (let index: number = 0; index < count; index++) result += value
  return result
}

function countToken(value: string, token: string): number {
  let count: number = 0
  let offset: number = 0
  while (value.indexOf(token, offset) >= 0) {
    count++
    offset = value.indexOf(token, offset) + token.length
  }
  return count
}

function questionJson(label: string, question: string, optionsJson: string = 'null'): string {
  return '{"label":' + JSON.stringify(label) + ',"type":"unknown","question":' +
    JSON.stringify(question) + ',"options":' + optionsJson +
    ',"answer":null,"analysis":null,' +
    '"bbox":{"x1":0,"y1":0,"x2":1000,"y2":1000}}'
}

function responseJson(question: string): string {
  return '{"questions":[' + question + ']}'
}

function parserErrorCode(value: string): string {
  try {
    AiQuestionResponseParser.parse(value, 1)
  } catch (err) {
    if (err instanceof AiImportError) return err.code
  }
  return ''
}

it('rejects structural and bounded-field violations with INVALID_JSON', 0, () => {
  const questions: Array<string> = new Array<string>()
  for (let index: number = 1; index <= 51; index++) {
    questions.push(questionJson(index.toString() + '.', '题目'))
  }
  const invalidJsonCases: Array<string> = [
    '{"questions":[' + questions.join(',') + ']}',
    responseJson(questionJson('例' + repeatText('1', 32), '题目')),
    responseJson(questionJson('1.', repeatText('题', 20001))),
    responseJson(questionJson('1.', '题目', '{"A":' + JSON.stringify(repeatText('甲', 2001)) + '}')),
    responseJson(questionJson('1.', '题目', '{"K":"越界"}')),
    responseJson(questionJson('1.', '题目', '{"A":"甲","A":"重复"}')),
    responseJson(questionJson('1.', '题目\u0000')),
    responseJson(questionJson('1.', '题目')) + '{"extra":true}'
  ]
  for (let index: number = 0; index < invalidJsonCases.length; index++) {
    expect(parserErrorCode(invalidJsonCases[index])).assertEqual(AiImportErrorCode.INVALID_JSON)
  }
})

it('rejects incomplete LaTeX with LATEX_INVALID', 0, () => {
  const invalidLatexCases: Array<string> = [
    '$x+1',
    '$$x+1$',
    '$\\\\frac{x}{1+x^2$',
    '$$\\\\begin{cases}x, & x>0 \\\\\\\\ 0, & x\\\\le0$$',
    '∫2−x'
  ]
  for (let index: number = 0; index < invalidLatexCases.length; index++) {
    expect(parserErrorCode(responseJson(questionJson('1.', invalidLatexCases[index]))))
      .assertEqual(AiImportErrorCode.LATEX_INVALID)
  }
})

it('preserves supported math and separate cases environments', 0, () => {
  const math: string = '$\\\\sqrt{x}$、$f^{-1}(x)$、$\\\\varphi(x)$、' +
    '$$\\\\frac{x}{1+x^2}$$、' +
    '$$f(x)=\\\\begin{cases}x, & x>0 \\\\\\\\ 0, & x\\\\le0\\\\end{cases}$$、' +
    '$$g(x)=\\\\begin{cases}1, & x\\\\ge0 \\\\\\\\ -1, & x<0\\\\end{cases}$$'
  const parsed: Array<AiQuestionDraft> =
    AiQuestionResponseParser.parse(responseJson(questionJson('例1.5', math)), 1)
  expect(parsed.length).assertEqual(1)
  expect(parsed[0].question.indexOf('\\frac{x}{1+x^2}') >= 0).assertTrue()
  expect(parsed[0].question.indexOf('\\sqrt{x}') >= 0).assertTrue()
  expect(parsed[0].question.indexOf('$f^{-1}(x)$') >= 0).assertTrue()
  expect(parsed[0].question.indexOf('\\varphi') >= 0).assertTrue()
  expect(countToken(parsed[0].question, '\\begin{cases}')).assertEqual(2)
  expect(countToken(parsed[0].question, '\\end{cases}')).assertEqual(2)
})
```

Import `AiImportError`, `AiImportErrorCode`, and `AiQuestionDraft` with the existing Task 4 imports. Keep `repeatText()` and `countToken()` at file scope so Task 13 reuses the latter without a second definition.

Run:

```powershell
node 'C:/Users/32773/.agents/skills/harmonyos-dev-skill/scripts/arkts-check.cjs' --project . --files `
  entry/src/main/ets/services/ai/MathQuestionPromptBuilder.ets `
  entry/src/main/ets/services/ai/AiQuestionResponseParser.ets
& 'D:/Program Files/Huawei/DevEco Studio/tools/node/node.exe' `
  'D:/Program Files/Huawei/DevEco Studio/tools/hvigor/bin/hvigorw.js' test `
  --mode module -p module=entry@default
```

Expected: ArkTS JSON `success: true`；all prompt/parser Hypium cases PASS。

- [ ] **Step 6: 无提交 diff 检查点**

Run: `git diff -- entry/src/main/ets/services/ai/MathQuestionPromptBuilder.ets entry/src/main/ets/services/ai/AiQuestionResponseParser.ets entry/src/test/AiImportLocalUnit.test.ets`

Expected: parser 是唯一允许去除 Markdown JSON 围栏的模块；没有修改 `MathContentUtils` 或 OCR geometry；不要提交。

## Task 5: 实现 OpenAI-compatible adapter 与安全 HTTP transport

**Files:**
- Create: `entry/src/main/ets/services/ai/AiProviderAdapter.ets`
- Create: `entry/src/main/ets/services/ai/OpenAiCompatibleAdapter.ets`
- Create: `entry/src/main/ets/services/ai/AiVisionTransport.ets`
- Modify: `entry/src/test/AiImportLocalUnit.test.ets`
- Modify: `entry/src/test/AiImportContracts.test.cjs`
- Modify: `entry/src/test/AiImportSecurityContracts.test.cjs`

- [ ] **Step 1: 写 adapter 请求形状和 transport 策略失败合同**

Append to `entry/src/test/AiImportContracts.test.cjs`:

```js
test('OpenAI-compatible adapter sends one page image through chat completions', () => {
  const source = read('entry/src/main/ets/services/ai/OpenAiCompatibleAdapter.ets')
  assert.match(source, /\/chat\/completions/)
  assert.match(source, /data:image\/jpeg;base64,/)
  assert.match(source, /"stream":false/)
  assert.match(source, /"type":"image_url"/)
  assert.match(source, /"role":"system"/)
  assert.match(source, /choices/)
  assert.match(source, /message/)
  assert.match(source, /content/)
})

test('AI transport is bounded, non-redirecting, cancellable and independent', () => {
  const source = read('entry/src/main/ets/services/ai/AiVisionTransport.ets')
  assert.match(source, /maxLimit:\s*AiImportLimits\.MAX_RESPONSE_BYTES/)
  assert.match(source, /maxRedirects:\s*0/)
  assert.match(source, /usingCache:\s*false/)
  assert.match(source, /expectDataType:\s*http\.HttpDataType\.STRING/)
  assert.match(source, /request\.destroy\(\)/)
  assert.match(source, /activeRequests\.get\(requestKey\)\s*===\s*request/)
  assert.doesNotMatch(source, /ApiHttpClient|ApiConfig\.CA_PATH|remoteValidation|console\.|hilog\./)
  assert.doesNotMatch(source, /\bbody\s*:/)
})
```

Append to `entry/src/test/AiImportSecurityContracts.test.cjs`:

```js
test('AI network errors expose only local stable messages', () => {
  const source = read('entry/src/main/ets/services/ai/AiVisionTransport.ets')
  assert.doesNotMatch(source, /JSON\.stringify\(error\)|error\.message|response\.result.*throw/)
  assert.match(source, /2300028/)
  assert.match(source, /2300058/)
  assert.match(source, /2300063/)
})
```

- [ ] **Step 2: 运行合同确认失败**

Run: `node --test entry/src/test/AiImportContracts.test.cjs entry/src/test/AiImportSecurityContracts.test.cjs`

Expected: FAIL because adapter and transport files do not exist.

- [ ] **Step 3: 定义 adapter 边界并构造有界请求**

Create `entry/src/main/ets/services/ai/AiProviderAdapter.ets`:

```ts
import { AiProviderConfig } from '../../models/ai/AiProviderConfig'

export class AiProviderRequest {
  endpoint: string
  body: string

  constructor(endpoint: string, body: string) {
    this.endpoint = endpoint
    this.body = body
  }

  release(): void { this.body = '' }
}

export interface AiProviderAdapter {
  buildRequest(config: AiProviderConfig, prompt: string, jpegBase64: string): AiProviderRequest
  extractAssistantContent(response: string): string
}
```

Create `entry/src/main/ets/services/ai/OpenAiCompatibleAdapter.ets`. Build JSON from escaped string values, so the API Key can never enter this object:

```ts
import { util } from '@kit.ArkTS'
import { AiImportLimits } from '../../constants/AiImportLimits'
import { AiImportError, AiImportErrorCode, AiProviderConfig } from '../../models/ai/AiProviderConfig'
import { AiProviderAdapter, AiProviderRequest } from './AiProviderAdapter'

export class OpenAiCompatibleAdapter implements AiProviderAdapter {
  buildRequest(config: AiProviderConfig, prompt: string, jpegBase64: string): AiProviderRequest {
    const endpoint: string = config.baseUrl + '/chat/completions'
    const responseFormat: string = config.supportsStructuredOutput ?
      ',"response_format":{"type":"json_object"}' : ''
    const body: string = '{"model":' + JSON.stringify(config.model) + ',"stream":false,' +
      '"messages":[' +
      '{"role":"system","content":' + JSON.stringify(prompt) + '},' +
      '{"role":"user","content":[' +
      '{"type":"text","text":"识别这一页数学题并按 system schema 返回。"},' +
      '{"type":"image_url","image_url":{"url":' +
      JSON.stringify('data:image/jpeg;base64,' + jpegBase64) + '}}]}]' + responseFormat + '}'
    const bytes: Uint8Array = new util.TextEncoder('utf-8').encodeInto(body)
    if (bytes.length > AiImportLimits.MAX_REQUEST_BYTES) {
      throw new AiImportError(AiImportErrorCode.RESPONSE_TOO_LARGE)
    }
    return new AiProviderRequest(endpoint, body)
  }

  extractAssistantContent(response: string): string {
    const content: string = new OpenAiResponseReader(response).readFirstContent()
    if (content.trim().length === 0) {
      throw new AiImportError(AiImportErrorCode.INVALID_JSON)
    }
    return content
  }
}
```

Before `OpenAiCompatibleAdapter`, add this high-level reader. Copy the existing private character-level method bodies `skipWhitespace`, `peek`, `expect`, `readString`, `readUnicode`, `hexValue`, `skipValue`, `skipObject`, `skipArray`, `skipNumber`, `skipDigits`, and `skipLiteral` verbatim from `entry/src/main/ets/utils/JsonParser.ets:55-258` into the marked class; only replace their error throw with `this.invalid()`:

```ts
class OpenAiResponseReader {
  private text: string
  private index: number = 0

  constructor(text: string) { this.text = text }

  readFirstContent(): string {
    let content: string = ''
    let choicesSeen: boolean = false
    this.expect('{')
    while (!this.nextIs('}')) {
      const key: string = this.readString()
      this.expect(':')
      if (key === 'choices') {
        if (choicesSeen) this.invalid()
        choicesSeen = true
        content = this.readChoices()
      } else {
        this.skipValue()
      }
      if (!this.nextIs('}')) this.expect(',')
    }
    this.expect('}')
    this.skipWhitespace()
    if (!choicesSeen || content.trim().length === 0 || this.index !== this.text.length) this.invalid()
    return content
  }

  private readChoices(): string {
    let content: string = ''
    let index: number = 0
    this.expect('[')
    while (!this.nextIs(']')) {
      if (index === 0) content = this.readChoice()
      else this.skipValue()
      index++
      if (!this.nextIs(']')) this.expect(',')
    }
    this.expect(']')
    if (index === 0) this.invalid()
    return content
  }

  private readChoice(): string {
    let content: string = ''
    let messageSeen: boolean = false
    this.expect('{')
    while (!this.nextIs('}')) {
      const key: string = this.readString()
      this.expect(':')
      if (key === 'message') {
        if (messageSeen) this.invalid()
        messageSeen = true
        content = this.readMessage()
      } else {
        this.skipValue()
      }
      if (!this.nextIs('}')) this.expect(',')
    }
    this.expect('}')
    if (!messageSeen) this.invalid()
    return content
  }

  private readMessage(): string {
    let content: string = ''
    let contentSeen: boolean = false
    this.expect('{')
    while (!this.nextIs('}')) {
      const key: string = this.readString()
      this.expect(':')
      if (key === 'content') {
        if (contentSeen) this.invalid()
        contentSeen = true
        content = this.readString()
      } else {
        this.skipValue()
      }
      if (!this.nextIs('}')) this.expect(',')
    }
    this.expect('}')
    if (!contentSeen || content.trim().length === 0) this.invalid()
    return content
  }

  private nextIs(character: string): boolean {
    this.skipWhitespace()
    return this.peek() === character
  }

  private invalid(): never {
    throw new AiImportError(AiImportErrorCode.INVALID_JSON)
  }

  // Insert the twelve private character-level methods named above here without changing their grammar.
}
```

This reader accepts unknown harmless envelope fields through `skipValue`, but rejects duplicate `choices`, `message`, or `content`, empty choices, non-string content, malformed/trailing JSON, and never includes the Provider response in its error.

- [ ] **Step 4: 实现安全 transport、状态映射与取消**

Create `entry/src/main/ets/services/ai/AiVisionTransport.ets`:

```ts
import { BusinessError } from '@kit.BasicServicesKit'
import { http } from '@kit.NetworkKit'
import { util } from '@kit.ArkTS'
import { AiImportLimits } from '../../constants/AiImportLimits'
import { AiImportError, AiImportErrorCode } from '../../models/ai/AiProviderConfig'
import { Utf8Utils } from '../../utils/Utf8Utils'

interface AiRequestHeaders {
  'Content-Type': string
  'Accept': string
  'Authorization': string
}

export interface AiVisionTransportPort {
  postJson(endpoint: string, credential: Uint8Array, body: string, requestKey: string): Promise<string>
  cancel(requestKey: string): void
}

export class AiTransportErrorMapper {
  static status(status: number): AiImportError | null {
    if (status >= 200 && status < 300) return null
    if (status === 401 || status === 403) return new AiImportError(AiImportErrorCode.AUTH_FAILED)
    if (status === 404) return new AiImportError(AiImportErrorCode.ENDPOINT_OR_MODEL_NOT_FOUND)
    if (status === 429) return new AiImportError(AiImportErrorCode.RATE_LIMITED)
    if (status >= 500) return new AiImportError(AiImportErrorCode.PROVIDER_UNAVAILABLE)
    return new AiImportError(AiImportErrorCode.INVALID_JSON)
  }

  static system(code: number, cancelled: boolean): AiImportError {
    if (cancelled) return new AiImportError(AiImportErrorCode.CANCELLED)
    if (code === 2300028) return new AiImportError(AiImportErrorCode.TIMEOUT)
    if (code === 2300063) return new AiImportError(AiImportErrorCode.RESPONSE_TOO_LARGE)
    if (code === 2300058 || code === 2300059 || code === 2300060 || code === 2300077) {
      return new AiImportError(AiImportErrorCode.TLS_FAILED)
    }
    return new AiImportError(AiImportErrorCode.NETWORK_UNAVAILABLE)
  }
}

export class AiVisionTransport implements AiVisionTransportPort {
  private activeRequests: Map<string, http.HttpRequest> = new Map<string, http.HttpRequest>()
  private cancelledKeys: Set<string> = new Set<string>()

  async postJson(endpoint: string, credential: Uint8Array, body: string,
    requestKey: string): Promise<string> {
    if (!endpoint.startsWith('https://')) {
      throw new AiImportError(AiImportErrorCode.INVALID_BASE_URL)
    }
    const bodyBytes: Uint8Array = new util.TextEncoder('utf-8').encodeInto(body)
    if (bodyBytes.length > AiImportLimits.MAX_REQUEST_BYTES) {
      throw new AiImportError(AiImportErrorCode.RESPONSE_TOO_LARGE)
    }
    const request: http.HttpRequest = http.createHttp()
    let credentialText: string = Utf8Utils.decode(credential)
    const headers: AiRequestHeaders = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'Authorization': 'Bearer ' + credentialText
    }
    this.cancelledKeys.delete(requestKey)
    this.activeRequests.set(requestKey, request)
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: body,
        connectTimeout: AiImportLimits.CONNECT_TIMEOUT_MS,
        readTimeout: AiImportLimits.READ_TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING,
        usingCache: false,
        maxLimit: AiImportLimits.MAX_RESPONSE_BYTES,
        maxRedirects: 0
      }
      const response: http.HttpResponse = await request.request(endpoint, options)
        .catch((error: BusinessError): http.HttpResponse => {
          throw AiTransportErrorMapper.system(error.code, this.cancelledKeys.has(requestKey))
        })
      if (this.cancelledKeys.has(requestKey)) {
        throw new AiImportError(AiImportErrorCode.CANCELLED)
      }
      const statusError: AiImportError | null = AiTransportErrorMapper.status(response.responseCode)
      if (statusError !== null) throw statusError
      const contentType: string = AiVisionTransport.contentType(response.header)
      if (!/^application\/json(?:\s*;|$)/i.test(contentType)) {
        throw new AiImportError(AiImportErrorCode.INVALID_CONTENT_TYPE)
      }
      const raw: string = String(response.result)
      if (new util.TextEncoder('utf-8').encodeInto(raw).length > AiImportLimits.MAX_RESPONSE_BYTES) {
        throw new AiImportError(AiImportErrorCode.RESPONSE_TOO_LARGE)
      }
      return raw
    } finally {
      headers.Authorization = ''
      credentialText = ''
      bodyBytes.fill(0)
      if (this.activeRequests.get(requestKey) === request) this.activeRequests.delete(requestKey)
      this.cancelledKeys.delete(requestKey)
      request.destroy()
    }
  }

  cancel(requestKey: string): void {
    this.cancelledKeys.add(requestKey)
    const request: http.HttpRequest | undefined = this.activeRequests.get(requestKey)
    if (request !== undefined) {
      this.activeRequests.delete(requestKey)
      request.destroy()
    }
  }

  private static contentType(header: Object): string {
    const serialized: string = JSON.stringify(header)
    const match: RegExpMatchArray | null = serialized.match(
      /"content-type"\s*:\s*(?:"([^"]*)"|\[\s*"([^"]*)")/i)
    if (match === null) return ''
    if (match[1] !== undefined) return match[1]
    return match[2] === undefined ? '' : match[2]
  }
}
```

- [ ] **Step 5: 添加 fake transport/adapter 逻辑测试**

Add these pure adapter/mapper tests to `AiImportLocalUnit.test.ets`; no production HTTP object is created:

```ts
import { OpenAiCompatibleAdapter } from '../main/ets/services/ai/OpenAiCompatibleAdapter'
import { AiProviderRequest } from '../main/ets/services/ai/AiProviderAdapter'
import { AiTransportErrorMapper } from '../main/ets/services/ai/AiVisionTransport'

class StatusExpectation {
  status: number
  code: AiImportErrorCode
  constructor(status: number, code: AiImportErrorCode) {
    this.status = status
    this.code = code
  }
}

describe('openAiCompatibleAdapter', () => {
  it('builds the official and custom multimodal bodies without credentials', 0, () => {
    const adapter: OpenAiCompatibleAdapter = new OpenAiCompatibleAdapter()
    const official: AiProviderConfig = new AiProviderConfig(
      AiProviderId.OPENAI, 'vision-model', 'https://api.openai.com/v1', true)
    const officialRequest: AiProviderRequest = adapter.buildRequest(official, 'prompt', 'AQID')
    expect(officialRequest.endpoint).assertEqual('https://api.openai.com/v1/chat/completions')
    expect(officialRequest.body.indexOf('data:image/jpeg;base64,AQID') >= 0).assertTrue()
    expect(officialRequest.body.indexOf('"response_format":{"type":"json_object"}') >= 0)
      .assertTrue()
    expect(officialRequest.body.toLowerCase().indexOf('authorization') < 0).assertTrue()
    officialRequest.release()

    const custom: AiProviderConfig = new AiProviderConfig(
      AiProviderId.CUSTOM, 'custom-vision', 'https://vision.example.com/api', false)
    const customRequest: AiProviderRequest = adapter.buildRequest(custom, 'prompt', 'AQID')
    expect(customRequest.endpoint).assertEqual('https://vision.example.com/api/chat/completions')
    expect(customRequest.body.indexOf('response_format') < 0).assertTrue()
    customRequest.release()
  })

  it('extracts only the first assistant content and rejects malformed envelopes', 0, () => {
    const adapter: OpenAiCompatibleAdapter = new OpenAiCompatibleAdapter()
    const content: string = adapter.extractAssistantContent(
      '{"id":"safe","choices":[{"message":{"role":"assistant","content":"{\\"questions\\":[]}"}}]}')
    expect(content).assertEqual('{"questions":[]}')
    const invalid: Array<string> = [
      '{}',
      '{"choices":[]}',
      '{"choices":[{"message":{}}]}',
      '{"choices":[{"message":{"content":7}}]}',
      '{"choices":[{"message":{"content":""}}]} trailing'
    ]
    for (let index: number = 0; index < invalid.length; index++) {
      let rejected: boolean = false
      try { adapter.extractAssistantContent(invalid[index]) } catch { rejected = true }
      expect(rejected).assertTrue()
    }
  })
})

describe('aiTransportErrorMapper', () => {
  it('maps HTTP, timeout, TLS, size and cancellation to local codes', 0, () => {
    const statuses: Array<StatusExpectation> = [
      new StatusExpectation(401, AiImportErrorCode.AUTH_FAILED),
      new StatusExpectation(403, AiImportErrorCode.AUTH_FAILED),
      new StatusExpectation(404, AiImportErrorCode.ENDPOINT_OR_MODEL_NOT_FOUND),
      new StatusExpectation(429, AiImportErrorCode.RATE_LIMITED),
      new StatusExpectation(500, AiImportErrorCode.PROVIDER_UNAVAILABLE)
    ]
    for (let index: number = 0; index < statuses.length; index++) {
      const mapped: AiImportError | null = AiTransportErrorMapper.status(statuses[index].status)
      expect(mapped === null ? '' : mapped.code).assertEqual(statuses[index].code)
    }
    expect(AiTransportErrorMapper.status(200) === null).assertTrue()
    expect(AiTransportErrorMapper.system(2300028, false).code).assertEqual(AiImportErrorCode.TIMEOUT)
    expect(AiTransportErrorMapper.system(2300058, false).code).assertEqual(AiImportErrorCode.TLS_FAILED)
    expect(AiTransportErrorMapper.system(2300063, false).code)
      .assertEqual(AiImportErrorCode.RESPONSE_TOO_LARGE)
    expect(AiTransportErrorMapper.system(1, true).code).assertEqual(AiImportErrorCode.CANCELLED)
  })
})
```

The CJS contract from Step 1 supplies the request-identity regression check: an old request's `finally` may delete the Map entry only when `activeRequests.get(requestKey) === request`.

Run:

```powershell
node --test entry/src/test/AiImportContracts.test.cjs entry/src/test/AiImportSecurityContracts.test.cjs
node 'C:/Users/32773/.agents/skills/harmonyos-dev-skill/scripts/arkts-check.cjs' --project . --files `
  entry/src/main/ets/services/ai/AiProviderAdapter.ets `
  entry/src/main/ets/services/ai/OpenAiCompatibleAdapter.ets `
  entry/src/main/ets/services/ai/AiVisionTransport.ets
& 'D:/Program Files/Huawei/DevEco Studio/tools/node/node.exe' `
  'D:/Program Files/Huawei/DevEco Studio/tools/hvigor/bin/hvigorw.js' test `
  --mode module -p module=entry@default
```

Expected: contracts, ArkTS check and fake-only Hypium tests PASS; no external host is contacted.

- [ ] **Step 6: 无提交 diff 检查点**

Run: `git diff -- entry/src/main/ets/services/ai/AiProviderAdapter.ets entry/src/main/ets/services/ai/OpenAiCompatibleAdapter.ets entry/src/main/ets/services/ai/AiVisionTransport.ets entry/src/test`

Expected: Key 只出现在 ephemeral Authorization header；没有业务 CA、业务 bearer、Provider body 日志或自动重试；不要提交。

## Task 6: 逐页渲染、JPEG 限额与证据图生命周期

**Files:**
- Create: `entry/src/main/ets/services/ai/PdfPageImageEncoder.ets`
- Modify: `entry/src/test/AiImportLocalUnit.test.ets`
- Modify: `entry/src/test/AiImportContracts.test.cjs`

- [ ] **Step 1: 写资源与限额失败合同**

Append to `entry/src/test/AiImportContracts.test.cjs`:

```js
test('PDF encoder releases page pixels before returning network-ready text', () => {
  const source = read('entry/src/main/ets/services/ai/PdfPageImageEncoder.ets')
  const limits = read('entry/src/main/ets/constants/AiImportLimits.ets')
  assert.match(source, /getAreaPixelMapWithOptions/)
  assert.match(source, /packToData/)
  assert.match(limits, /\[82, 75, 68, 60\]/)
  assert.match(source, /MAX_JPEG_BYTES/)
  assert.match(source, /pixelMap\.release/)
  assert.match(source, /page\.release/)
  assert.match(source, /document\.releaseDocument/)
  assert.doesNotMatch(source, /textRecognition|PaddleOCR|CloudImport/)
})
```

- [ ] **Step 2: 运行合同确认失败**

Run: `node --test entry/src/test/AiImportContracts.test.cjs`

Expected: FAIL because `PdfPageImageEncoder.ets` is missing.

- [ ] **Step 3: 定义可替换渲染端口并实现 PDF session**

Create `entry/src/main/ets/services/ai/PdfPageImageEncoder.ets` with these public types and ownership boundary:

```ts
import { Context } from '@kit.AbilityKit'
import { image } from '@kit.ImageKit'
import { pdfService } from '@kit.PDFKit'
import fs from '@ohos.file.fs'
import { util } from '@kit.ArkTS'
import { AiImportLimits } from '../../constants/AiImportLimits'
import { AiBoundingBox, EncodedPdfPage } from '../../models/ai/AiImportModels'

export class PdfPageOutputSize {
  width: number
  height: number
  constructor(width: number, height: number) {
    this.width = width
    this.height = height
  }
}

export class PdfPageSizing {
  static calculate(width: number, height: number): PdfPageOutputSize {
    const scale: number = Math.min(1,
      AiImportLimits.MAX_IMAGE_LONG_EDGE / Math.max(width, height))
    return new PdfPageOutputSize(Math.max(1, Math.round(width * scale)),
      Math.max(1, Math.round(height * scale)))
  }
}

export class JpegQualityPolicy {
  static steps(): Array<number> { return AiImportLimits.JPEG_QUALITY_STEPS.slice() }
  static accepts(byteLength: number): boolean {
    return byteLength > 0 && byteLength <= AiImportLimits.MAX_JPEG_BYTES
  }
}

export interface PdfRenderSessionPort {
  pageCount(): number
  encodePage(context: Context, pageIndex: number, sessionId: string): Promise<EncodedPdfPage>
  cropEvidence(context: Context, pageIndex: number, sessionId: string,
    questionId: string, box: AiBoundingBox): Promise<string>
  close(): void
}

export interface PdfPageImageEncoderPort {
  open(pdfPath: string): PdfRenderSessionPort
  cleanupSession(context: Context, sessionId: string): Promise<void>
}

export class PdfPageImageEncoder implements PdfPageImageEncoderPort {
  open(pdfPath: string): PdfRenderSessionPort {
    return new PdfRenderSession(pdfPath)
  }

  async cleanupSession(context: Context, sessionId: string): Promise<void> {
    await PdfRenderSession.cleanupOwnedCache(context, sessionId)
  }
}

class PdfRenderSession implements PdfRenderSessionPort {
  private document: pdfService.PdfDocument = new pdfService.PdfDocument()
  private closed: boolean = false

  constructor(pdfPath: string) {
    if (this.document.loadDocument(pdfPath) !== pdfService.ParseResult.PARSE_SUCCESS) {
      this.document.releaseDocument()
      this.closed = true
      throw new Error('PDF 页面无法读取')
    }
  }

  pageCount(): number { return this.document.getPageCount() }

  async encodePage(context: Context, pageIndex: number, sessionId: string): Promise<EncodedPdfPage> {
    const page: pdfService.PdfPage = this.document.getPage(pageIndex)
    let pixelMap: image.PixelMap | null = null
    let packer: image.ImagePacker | null = null
    let jpeg: Uint8Array | null = null
    try {
      const size: PdfPageOutputSize = PdfPageSizing.calculate(page.getWidth(), page.getHeight())
      const matrix: pdfService.PdfMatrix = new pdfService.PdfMatrix()
      matrix.x = 0
      matrix.y = 0
      matrix.width = page.getWidth()
      matrix.height = page.getHeight()
      matrix.rotate = 0
      const pixelOptions: pdfService.PixelOptions = new pdfService.PixelOptions()
      pixelOptions.isGray = false
      pixelOptions.drawAnnotations = true
      pixelOptions.isTransparent = false
      pixelMap = page.getAreaPixelMapWithOptions(matrix, size.width, size.height, pixelOptions)
      packer = image.createImagePacker()
      jpeg = await PdfRenderSession.packBounded(packer, pixelMap)
      const evidencePath: string = context.cacheDir + '/ai_import_page_' + sessionId + '_' +
        (pageIndex + 1).toString() + '.jpg'
      await PdfRenderSession.writeExclusive(evidencePath, jpeg)
      const base64: string = await new util.Base64Helper().encodeToString(jpeg, util.Type.BASIC)
      return new EncodedPdfPage(pageIndex + 1, size.width, size.height, base64, evidencePath)
    } finally {
      if (jpeg !== null) jpeg.fill(0)
      if (packer !== null) await packer.release()
      if (pixelMap !== null) await pixelMap.release()
      page.release()
    }
  }

  async cropEvidence(context: Context, pageIndex: number, sessionId: string,
    questionId: string, box: AiBoundingBox): Promise<string> {
    const page: pdfService.PdfPage = this.document.getPage(pageIndex)
    try {
      const matrix: pdfService.PdfMatrix = new pdfService.PdfMatrix()
      matrix.x = page.getWidth() * box.x1 / 1000
      matrix.y = page.getHeight() * (1000 - box.y2) / 1000
      matrix.width = page.getWidth() * (box.x2 - box.x1) / 1000
      matrix.height = page.getHeight() * (box.y2 - box.y1) / 1000
      matrix.rotate = 0
      return await PdfRenderSession.packCropToExclusiveFile(context, page, matrix,
        sessionId, questionId)
    } finally {
      page.release()
    }
  }

  close(): void {
    if (!this.closed) {
      this.closed = true
      this.document.releaseDocument()
    }
  }

  static async cleanupOwnedCache(context: Context, sessionId: string): Promise<void> {
    PdfRenderSession.validateIdentifier(sessionId)
    const names: Array<string> = await fs.listFile(context.cacheDir)
    const pagePrefix: string = 'ai_import_page_' + sessionId + '_'
    const cropPrefix: string = 'ai_import_crop_' + sessionId + '_'
    for (let index: number = 0; index < names.length; index++) {
      const name: string = names[index]
      if (!name.startsWith(pagePrefix) && !name.startsWith(cropPrefix)) continue
      if (!/^[A-Za-z0-9._:-]+\.jpg$/.test(name)) continue
      const path: string = context.cacheDir + '/' + name
      const info: fs.Stat = await fs.lstat(path)
      if (!info.isSymbolicLink() && info.isFile()) await fs.unlink(path)
    }
  }

  private static validateIdentifier(value: string): void {
    if (!/^[A-Za-z0-9._:-]{1,160}$/.test(value)) {
      throw new Error('AI 导入会话标识无效')
    }
  }

  private static async packBounded(packer: image.ImagePacker,
    pixelMap: image.PixelMap): Promise<Uint8Array> {
    const qualities: Array<number> = JpegQualityPolicy.steps()
    for (let index: number = 0; index < qualities.length; index++) {
      const option: image.PackingOption = {
        format: 'image/jpeg',
        quality: qualities[index],
        bufferSize: AiImportLimits.MAX_JPEG_BYTES + 1
      }
      const output: ArrayBuffer = await packer.packToData(pixelMap, option)
      if (JpegQualityPolicy.accepts(output.byteLength)) return new Uint8Array(output)
    }
    throw new Error('页面图片超过识别大小限制')
  }
}
```

Implement `writeExclusive` by extracting the already proven `open → bounded write loop → fsync → close → lstat` pattern from `PdfImportService.selectPdf()` and keeping the flags exactly `WRITE_ONLY | CREATE | TRUNC | NOFOLLOW`. Before opening, reject an existing path; after closing, reject a symlink, non-file, or size mismatch. On failure, remove only a file whose canonical parent is `context.cacheDir` and whose name exactly matches `ai_import_page_<validated-sessionId>_<page>.jpg`.

Implement `packCropToExclusiveFile` by extracting the `PixelOptions → getAreaPixelMapWithOptions → ImagePacker.packToFile → close/packer.release/pixelMap.release` block from `QuestionImageService.saveCrop()`. Change only the output prefix to `ai_import_crop_<validated-sessionId>_<validated-questionId>.jpg`, use JPEG quality 82, derive bounded integer output dimensions through `PdfPageSizing.calculate(matrix.width, matrix.height)`, and preserve its first-error/cleanup-error handling. Accept identifiers only when `/^[A-Za-z0-9._:-]{1,160}$/` matches; use a unique temporary sibling and rename only after lstat confirms an ordinary non-empty file. Do not call `QuestionImageService.commitImages()`.

`cleanupOwnedCache()` deliberately lists one trusted cache directory and filters two session-specific validated prefixes. If an individual candidate disappears concurrently, ignore only filesystem code `13900002`; propagate every other stat/unlink error so cancellation cannot falsely report complete cleanup.

- [ ] **Step 4: 添加纯策略测试和资源顺序合同**

Add this Hypium suite to `AiImportLocalUnit.test.ets`:

```ts
import {
  JpegQualityPolicy,
  PdfPageOutputSize,
  PdfPageSizing
} from '../main/ets/services/ai/PdfPageImageEncoder'

describe('pdfPageImagePolicy', () => {
  it('bounds the long edge without upscaling and preserves quality order', 0, () => {
    const landscape: PdfPageOutputSize = PdfPageSizing.calculate(4400, 2200)
    const portrait: PdfPageOutputSize = PdfPageSizing.calculate(1000, 2000)
    expect(landscape.width).assertEqual(2200)
    expect(landscape.height).assertEqual(1100)
    expect(portrait.width).assertEqual(1000)
    expect(portrait.height).assertEqual(2000)
    expect(JpegQualityPolicy.steps().join(',')).assertEqual('82,75,68,60')
    expect(JpegQualityPolicy.accepts(4 * 1024 * 1024)).assertTrue()
    expect(JpegQualityPolicy.accepts(4 * 1024 * 1024 + 1)).assertFalse()
  })
})
```

Extend the Step 1 CJS contract with source-order checks for `packToData` before `packer.release`, then `pixelMap.release`, then `page.release`; check that `close()` guards `releaseDocument()` with `closed`; check evidence/crop writes use `NOFOLLOW`, `fsync`/`packToFile`, `lstat`, and exact `ai_import_page_`/`ai_import_crop_` prefixes. Task 8's fake render session supplies the behavioral assertion that transport does not start until `encodePage()` has resolved and active resource counters are zero.

Run:

```powershell
node --test entry/src/test/AiImportContracts.test.cjs
node 'C:/Users/32773/.agents/skills/harmonyos-dev-skill/scripts/arkts-check.cjs' --project . --files `
  entry/src/main/ets/services/ai/PdfPageImageEncoder.ets
& 'D:/Program Files/Huawei/DevEco Studio/tools/node/node.exe' `
  'D:/Program Files/Huawei/DevEco Studio/tools/hvigor/bin/hvigorw.js' test `
  --mode module -p module=entry@default
```

Expected: contract, ArkTS check and fake lifecycle tests PASS.

- [ ] **Step 5: 无提交 diff 检查点**

Run: `git diff -- entry/src/main/ets/services/ai/PdfPageImageEncoder.ets entry/src/test`

Expected: 不调用 OCR；网络边界前不再持有 `PdfPage`/`PixelMap`；不要提交。

## Task 7: 建立双源审核模型与深拷贝会话仓库

**Files:**
- Create: `entry/src/main/ets/services/review/PdfReviewModels.ets`
- Create: `entry/src/main/ets/services/review/PdfReviewSession.ets`
- Modify: `entry/src/main/ets/utils/PdfImportState.ets:35-45,95-115,226-246`
- Modify: `entry/src/test/AiImportLocalUnit.test.ets`

- [ ] **Step 1: 写会话隔离和稳定 ID 失败测试**

Add the review-model/store imports and this test to `AiImportLocalUnit.test.ets`:

```ts
it('deep-copies review sessions while preserving stable entity ids', 0, () => {
  const option: PdfReviewOption = new PdfReviewOption('A', '甲')
  const sourceImage: PdfReviewImage = new PdfReviewImage('', '/cache/page.jpg', '', 0,
    'image/jpeg', 0)
  const question: PdfReviewQuestion = new PdfReviewQuestion(
    'session-1:1:0', '11111111-1111-4111-8111-111111111111', '例1.1',
    AiQuestionType.SINGLE_CHOICE, '题目', [option], 'A', '解析', 1, 1, 1, false, [sourceImage])
  const failure: PdfReviewFailure = new PdfReviewFailure(
    2, AiImportErrorCode.INVALID_JSON, 'AI 返回的 JSON 无法解析或不符合格式', '/cache/page2.jpg')
  const session: PdfReviewSession = new PdfReviewSession(
    'session-1', PdfReviewSource.AI, '22222222-2222-4222-8222-222222222222',
    '题库', '数学', '/cache/staged.pdf', 'account-1', [question], [failure],
    PdfReviewSaveStage.DRAFT)

  PdfReviewSessionStore.put(session)
  option.value = '污染原对象'
  sourceImage.localPath = '/cache/changed.jpg'
  failure.message = '污染失败对象'
  session.questions.push(question)

  const first: PdfReviewSession | null = PdfReviewSessionStore.get('session-1')
  expect(first === null).assertFalse()
  if (first === null) return
  first.questions[0].options[0].value = '污染读取副本'
  first.questions[0].images[0].localPath = '/cache/changed-again.jpg'
  first.failures[0].message = '污染读取失败副本'
  PdfReviewSessionStore.put(first)

  const second: PdfReviewSession | null = PdfReviewSessionStore.get('session-1')
  expect(second === null).assertFalse()
  if (second === null) return
  expect(second.questions.length).assertEqual(1)
  expect(second.questions[0].options[0].value).assertEqual('污染读取副本')
  expect(second.questions[0].questionUuid).assertEqual('11111111-1111-4111-8111-111111111111')
  expect(second.bankUuid).assertEqual('22222222-2222-4222-8222-222222222222')
  second.questions[0].options[0].value = '仅改第二副本'
  const third: PdfReviewSession | null = PdfReviewSessionStore.get('session-1')
  expect(third === null).assertFalse()
  if (third !== null) {
    expect(third.questions[0].options[0].value).assertEqual('污染读取副本')
    expect(third.failures[0].message).assertEqual('污染读取失败副本')
  }
  PdfReviewSessionStore.remove('session-1')
})
```

The mutation before the first `get()` proves `put()` copied its input; the mutation after the second `get()` proves every `get()` returns a new deep copy. Do not use object spread for any copy.

- [ ] **Step 2: 运行 Hypium 确认失败**

Run the entry Hypium command from Task 1.

Expected: FAIL because review models and store are missing.

- [ ] **Step 3: 定义 source-neutral 审核模型和 adapter 接口**

Create `entry/src/main/ets/services/review/PdfReviewModels.ets`:

```ts
import { Context } from '@kit.AbilityKit'
import { AiImportErrorCode } from '../../models/ai/AiProviderConfig'
import { AiQuestionType } from '../../models/ai/AiImportModels'

export enum PdfReviewSource { CLOUD = 'cloud', AI = 'ai' }
export enum PdfReviewSaveStage { DRAFT = 'draft', TEXT_SAVED = 'text_saved', COMPLETE = 'complete' }

export class PdfReviewOption {
  key: string
  value: string
  constructor(key: string, value: string) { this.key = key; this.value = value }
}

export class PdfReviewImage {
  remoteArtifactId: string
  localPath: string
  sha256: string
  size: number
  contentType: string
  sortOrder: number

  constructor(remoteArtifactId: string, localPath: string, sha256: string, size: number,
    contentType: string, sortOrder: number) {
    this.remoteArtifactId = remoteArtifactId
    this.localPath = localPath
    this.sha256 = sha256
    this.size = size
    this.contentType = contentType
    this.sortOrder = sortOrder
  }
}

export class PdfReviewQuestion {
  draftQuestionId: string
  questionUuid: string
  label: string
  type: AiQuestionType
  question: string
  options: Array<PdfReviewOption>
  answer: string
  analysis: string
  pageStart: number
  pageEnd: number
  confidence: number
  reviewRequired: boolean
  images: Array<PdfReviewImage>

  constructor(draftQuestionId: string, questionUuid: string, label: string, type: AiQuestionType,
    question: string, options: Array<PdfReviewOption>, answer: string, analysis: string,
    pageStart: number, pageEnd: number, confidence: number, reviewRequired: boolean,
    images: Array<PdfReviewImage>) {
    this.draftQuestionId = draftQuestionId
    this.questionUuid = questionUuid
    this.label = label
    this.type = type
    this.question = question
    this.options = options
    this.answer = answer
    this.analysis = analysis
    this.pageStart = pageStart
    this.pageEnd = pageEnd
    this.confidence = confidence
    this.reviewRequired = reviewRequired
    this.images = images
  }
}

export class PdfReviewFailure {
  pageNumber: number
  code: AiImportErrorCode
  message: string
  evidencePath: string
  constructor(pageNumber: number, code: AiImportErrorCode, message: string, evidencePath: string) {
    this.pageNumber = pageNumber; this.code = code; this.message = message; this.evidencePath = evidencePath
  }
}

export class PdfReviewSession {
  sessionId: string
  source: PdfReviewSource
  bankUuid: string
  bankName: string
  subject: string
  pdfPath: string
  accountId: string
  questions: Array<PdfReviewQuestion>
  failures: Array<PdfReviewFailure>
  saveStage: PdfReviewSaveStage

  constructor(sessionId: string, source: PdfReviewSource, bankUuid: string, bankName: string,
    subject: string, pdfPath: string, accountId: string, questions: Array<PdfReviewQuestion>,
    failures: Array<PdfReviewFailure>, saveStage: PdfReviewSaveStage) {
    this.sessionId = sessionId
    this.source = source
    this.bankUuid = bankUuid
    this.bankName = bankName
    this.subject = subject
    this.pdfPath = pdfPath
    this.accountId = accountId
    this.questions = questions
    this.failures = failures
    this.saveStage = saveStage
  }
}

export interface PdfReviewAdapter {
  load(context: Context): Promise<PdfReviewSession>
  persist(session: PdfReviewSession): void
  save(context: Context, session: PdfReviewSession): Promise<PdfReviewSession>
  retryPage(context: Context, session: PdfReviewSession, pageNumber: number): Promise<PdfReviewSession>
  abandon(context: Context, session: PdfReviewSession): Promise<void>
}
```

- [ ] **Step 4: 实现深拷贝会话仓库**

Create `entry/src/main/ets/services/review/PdfReviewSession.ets`:

```ts
import {
  PdfReviewFailure,
  PdfReviewImage,
  PdfReviewOption,
  PdfReviewQuestion,
  PdfReviewSession
} from './PdfReviewModels'

export class PdfReviewSessionStore {
  private static sessions: Map<string, PdfReviewSession> = new Map<string, PdfReviewSession>()

  static put(session: PdfReviewSession): void {
    PdfReviewSessionStore.sessions.set(session.sessionId, PdfReviewSessionStore.copy(session))
  }

  static get(sessionId: string): PdfReviewSession | null {
    const session: PdfReviewSession | undefined = PdfReviewSessionStore.sessions.get(sessionId)
    return session === undefined ? null : PdfReviewSessionStore.copy(session)
  }

  static remove(sessionId: string): void { PdfReviewSessionStore.sessions.delete(sessionId) }

  private static copy(source: PdfReviewSession): PdfReviewSession {
    const questions: Array<PdfReviewQuestion> = new Array<PdfReviewQuestion>()
    for (let questionIndex: number = 0; questionIndex < source.questions.length; questionIndex++) {
      const question: PdfReviewQuestion = source.questions[questionIndex]
      const options: Array<PdfReviewOption> = new Array<PdfReviewOption>()
      for (let optionIndex: number = 0; optionIndex < question.options.length; optionIndex++) {
        const option: PdfReviewOption = question.options[optionIndex]
        options.push(new PdfReviewOption(option.key, option.value))
      }
      const images: Array<PdfReviewImage> = new Array<PdfReviewImage>()
      for (let imageIndex: number = 0; imageIndex < question.images.length; imageIndex++) {
        const image: PdfReviewImage = question.images[imageIndex]
        images.push(new PdfReviewImage(image.remoteArtifactId, image.localPath, image.sha256,
          image.size, image.contentType, image.sortOrder))
      }
      questions.push(new PdfReviewQuestion(question.draftQuestionId, question.questionUuid,
        question.label, question.type, question.question, options, question.answer, question.analysis,
        question.pageStart, question.pageEnd, question.confidence, question.reviewRequired, images))
    }
    const failures: Array<PdfReviewFailure> = new Array<PdfReviewFailure>()
    for (let index: number = 0; index < source.failures.length; index++) {
      const failure: PdfReviewFailure = source.failures[index]
      failures.push(new PdfReviewFailure(failure.pageNumber, failure.code,
        failure.message, failure.evidencePath))
    }
    return new PdfReviewSession(source.sessionId, source.source, source.bankUuid, source.bankName,
      source.subject, source.pdfPath, source.accountId, questions, failures, source.saveStage)
  }
}
```

- [ ] **Step 5: 给现有单例状态增加 AI session 选择器**

In `PdfImportState`, add one field and methods without changing existing Cloud fields:

```ts
private reviewSessionId: string = ''

setReviewSessionId(sessionId: string): void { this.reviewSessionId = sessionId }
getReviewSessionId(): string { return this.reviewSessionId }
clearReviewSessionId(): void { this.reviewSessionId = '' }
```

At the start of `setCloudJob`, assign `this.reviewSessionId = ''`. In `reset()` and `resetCloudFlow()`, assign `this.reviewSessionId = ''` so stale AI sessions cannot be opened through a Cloud job.

- [ ] **Step 6: 运行深拷贝测试和 ArkTS 检查**

Run the targeted ArkTS check for both review files and `PdfImportState.ets`, then run the entry Hypium command.

Expected: all PASS；mutation of any returned options/images/failures array does not alter the stored session.

- [ ] **Step 7: 无提交 diff 检查点**

Run: `git diff -- entry/src/main/ets/services/review entry/src/main/ets/utils/PdfImportState.ets entry/src/test/AiImportLocalUnit.test.ets`

Expected: review session contains no credential, Authorization, Prompt, raw response, business token or Provider body；Cloud state methods remain present；不要提交。

## Task 8: 实现严格串行 coordinator、取消与单页重试

**Files:**
- Create: `entry/src/main/ets/services/ai/PdfAiImportCoordinator.ets`
- Modify: `entry/src/test/AiImportLocalUnit.test.ets`
- Modify: `entry/src/test/AiImportContracts.test.cjs`
- Modify: `entry/src/test/AiImportSecurityContracts.test.cjs`

- [ ] **Step 1: 写串行、释放、取消和零 fallback 失败测试**

Add named fakes to `AiImportLocalUnit.test.ets`:

```ts
class FakeCoordinatorCounters {
  activeRenders: number = 0
  activeRequests: number = 0
  maximumRenders: number = 0
  maximumRequests: number = 0
  encodedPages: Array<number> = new Array<number>()
  requestedPages: Array<number> = new Array<number>()
  cancelledKeys: Array<string> = new Array<string>()
  cloudCalls: number = 0
  ocrCalls: number = 0
}
```

Implement `FakePdfPageImageEncoder implements PdfPageImageEncoderPort`, `FakeRenderSession implements PdfRenderSessionPort`, `FakeProviderAdapter implements AiProviderAdapter`, `FakeTransport implements AiVisionTransportPort`, `FakeCredentialAccess implements AiCredentialAccessPort`, and `FakeQuestionParser implements AiQuestionParserPort`. They update those counters and the transport uses a deferred Promise for page 2. `FakePdfPageImageEncoder.cleanupSession()` records cleanup without touching disk. Add tests with these exact outcomes:

```ts
expect(counters.maximumRenders).assertEqual(1)
expect(counters.maximumRequests).assertEqual(1)
expect(counters.encodedPages.join(',')).assertEqual('1,2,3')
expect(counters.requestedPages.join(',')).assertEqual('1,2,3')
expect(counters.cloudCalls).assertEqual(0)
expect(counters.ocrCalls).assertEqual(0)
```

During the fake `postJson`, assert the renderer's active page and PixelMap counters are zero. Cancel page 2, resolve the deferred request, and assert page 3 was never encoded. Retry only page 2 and assert its prior failure is replaced, all other question UUIDs are unchanged, and the retry uses a different request key.

Append the following source boundary contract:

```js
test('AI coordinator owns a sequential local-only pipeline', () => {
  const source = read('entry/src/main/ets/services/ai/PdfAiImportCoordinator.ets')
  assert.match(source, /for \(let pageNumber:/)
  assert.match(source, /encodePage[\s\S]*postJson[\s\S]*extractAssistantContent[\s\S]*parse/)
  assert.match(source, /releaseTransientText/)
  assert.match(source, /transport\.cancel/)
  assert.doesNotMatch(source, /Promise\.all|CloudImportService|CloudImportApi|PaddleOCR|textRecognition/)
})
```

- [ ] **Step 2: 运行测试确认失败**

Run the AI CJS contracts and entry Hypium command.

Expected: FAIL because `PdfAiImportCoordinator.ets` is missing.

- [ ] **Step 3: 定义 coordinator 的可测端口与请求模型**

Create the beginning of `entry/src/main/ets/services/ai/PdfAiImportCoordinator.ets`:

```ts
import { Context } from '@kit.AbilityKit'
import { util } from '@kit.ArkTS'
import { PdfImportSettings } from '../../models/PdfImportModels'
import { PdfImportService } from '../PdfImportService'
import {
  AiImportError,
  AiImportErrorCode,
  AiProviderConfig
} from '../../models/ai/AiProviderConfig'
import { AiQuestionDraft, EncodedPdfPage } from '../../models/ai/AiImportModels'
import {
  PdfReviewFailure,
  PdfReviewImage,
  PdfReviewOption,
  PdfReviewQuestion,
  PdfReviewSaveStage,
  PdfReviewSession,
  PdfReviewSource
} from '../review/PdfReviewModels'
import { PdfReviewSessionStore } from '../review/PdfReviewSession'
import { AiCredentialStore } from './AiCredentialStore'
import { AiProviderAdapter, AiProviderRequest } from './AiProviderAdapter'
import { AiQuestionResponseParser } from './AiQuestionResponseParser'
import { OpenAiCompatibleAdapter } from './OpenAiCompatibleAdapter'
import { AiVisionTransport, AiVisionTransportPort } from './AiVisionTransport'
import { MathQuestionPromptBuilder } from './MathQuestionPromptBuilder'
import {
  PdfPageImageEncoder,
  PdfPageImageEncoderPort,
  PdfRenderSessionPort
} from './PdfPageImageEncoder'

export type AiProgressCallback = (currentPage: number, totalPages: number,
  processedPages: number, questionCount: number, stage: string) => void

export interface AiCredentialAccessPort {
  run(context: Context, action: AiCredentialAction): Promise<string>
}

export interface AiCredentialAction {
  execute(credential: Uint8Array): Promise<string>
}

export interface AiQuestionParserPort {
  parse(content: string, pageNumber: number): Array<AiQuestionDraft>
}

export class PdfAiImportRequest {
  sessionId: string
  accountId: string
  pdfPath: string
  settings: PdfImportSettings
  config: AiProviderConfig

  constructor(sessionId: string, accountId: string, pdfPath: string,
    settings: PdfImportSettings, config: AiProviderConfig) {
    this.sessionId = sessionId
    this.accountId = accountId
    this.pdfPath = pdfPath
    this.settings = settings
    this.config = config
  }
}

class StoredCredentialAccess implements AiCredentialAccessPort {
  run(context: Context, action: AiCredentialAction): Promise<string> {
    return AiCredentialStore.withCredential<string>(context,
      (credential: Uint8Array): Promise<string> => action.execute(credential))
  }
}

class StrictQuestionParser implements AiQuestionParserPort {
  parse(content: string, pageNumber: number): Array<AiQuestionDraft> {
    return AiQuestionResponseParser.parse(content, pageNumber)
  }
}

class TransportCredentialAction implements AiCredentialAction {
  private transport: AiVisionTransportPort
  private request: AiProviderRequest
  private requestKey: string

  constructor(transport: AiVisionTransportPort, request: AiProviderRequest, requestKey: string) {
    this.transport = transport
    this.request = request
    this.requestKey = requestKey
  }

  execute(credential: Uint8Array): Promise<string> {
    return this.transport.postJson(this.request.endpoint, credential, this.request.body, this.requestKey)
  }
}
```

- [ ] **Step 4: 实现串行页面循环和页面原子提交**

Add the coordinator class. The loop must append a page's questions only after parsing and every requested crop succeed:

```ts
export class PdfAiImportCoordinator {
  private renderer: PdfPageImageEncoderPort
  private credentials: AiCredentialAccessPort
  private adapter: AiProviderAdapter
  private transport: AiVisionTransportPort
  private parser: AiQuestionParserPort
  private generation: number = 0
  private activeRequestKey: string = ''

  constructor(renderer: PdfPageImageEncoderPort, credentials: AiCredentialAccessPort,
    adapter: AiProviderAdapter, transport: AiVisionTransportPort, parser: AiQuestionParserPort) {
    this.renderer = renderer
    this.credentials = credentials
    this.adapter = adapter
    this.transport = transport
    this.parser = parser
  }

  static createDefault(): PdfAiImportCoordinator {
    return new PdfAiImportCoordinator(new PdfPageImageEncoder(), new StoredCredentialAccess(),
      new OpenAiCompatibleAdapter(), new AiVisionTransport(), new StrictQuestionParser())
  }

  cancel(): void {
    this.generation++
    if (this.activeRequestKey.length > 0) this.transport.cancel(this.activeRequestKey)
    this.activeRequestKey = ''
  }

  async discard(context: Context, request: PdfAiImportRequest): Promise<void> {
    this.cancel()
    await this.renderer.cleanupSession(context, request.sessionId)
    await PdfImportService.removeTemporaryPdf(request.pdfPath)
  }

  async run(context: Context, request: PdfAiImportRequest,
    onProgress: AiProgressCallback): Promise<PdfReviewSession> {
    const generation: number = ++this.generation
    const renderSession: PdfRenderSessionPort = this.renderer.open(request.pdfPath)
    const questions: Array<PdfReviewQuestion> = new Array<PdfReviewQuestion>()
    const failures: Array<PdfReviewFailure> = new Array<PdfReviewFailure>()
    let previousTail: string = ''
    const totalPages: number = request.settings.endPage - request.settings.startPage + 1
    try {
      for (let pageNumber: number = request.settings.startPage;
        pageNumber <= request.settings.endPage; pageNumber++) {
        this.requireGeneration(generation)
        let encoded: EncodedPdfPage | null = null
        let providerRequest: AiProviderRequest | null = null
        let rawResponse: string = ''
        let assistantContent: string = ''
        try {
          onProgress(pageNumber, totalPages, pageNumber - request.settings.startPage,
            questions.length, '正在渲染第 ' + pageNumber.toString() + ' 页')
          encoded = await renderSession.encodePage(context, pageNumber - 1, request.sessionId)
          this.requireGeneration(generation)
          const prompt: string = MathQuestionPromptBuilder.build(pageNumber,
            renderSession.pageCount(), previousTail)
          providerRequest = this.adapter.buildRequest(request.config, prompt, encoded.jpegBase64)
          this.activeRequestKey = request.sessionId + ':' + pageNumber.toString() + ':' +
            generation.toString()
          rawResponse = await this.credentials.run(context,
            new TransportCredentialAction(this.transport, providerRequest, this.activeRequestKey))
          this.activeRequestKey = ''
          this.requireGeneration(generation)
          assistantContent = this.adapter.extractAssistantContent(rawResponse)
          const parsed: Array<AiQuestionDraft> = this.parser.parse(assistantContent, pageNumber)
          const pageQuestions: Array<PdfReviewQuestion> = new Array<PdfReviewQuestion>()
          for (let index: number = 0; index < parsed.length; index++) {
            const source: AiQuestionDraft = parsed[index]
            const questionUuid: string = util.generateRandomUUID()
            const draftQuestionId: string = request.sessionId + ':' + pageNumber.toString() + ':' +
              index.toString()
            const evidencePath: string = source.bboxUsable ?
              await renderSession.cropEvidence(context, pageNumber - 1, request.sessionId,
                draftQuestionId, source.bbox) : encoded.evidencePath
            this.requireGeneration(generation)
            const options: Array<PdfReviewOption> = new Array<PdfReviewOption>()
            for (let optionIndex: number = 0; optionIndex < source.options.length; optionIndex++) {
              options.push(new PdfReviewOption(source.options[optionIndex].key,
                source.options[optionIndex].value))
            }
            const images: Array<PdfReviewImage> = [
              new PdfReviewImage('', evidencePath, '', 0, 'image/jpeg', 0)
            ]
            pageQuestions.push(new PdfReviewQuestion(draftQuestionId, questionUuid, source.label,
              source.type, source.question, options, source.answer, source.analysis,
              pageNumber, pageNumber, 1, !source.bboxUsable, images))
          }
          for (let index: number = 0; index < pageQuestions.length; index++) {
            questions.push(pageQuestions[index])
          }
          previousTail = parsed[parsed.length - 1].question
            .substring(Math.max(0, parsed[parsed.length - 1].question.length - 1000))
        } catch (err) {
          if (generation !== this.generation) throw new AiImportError(AiImportErrorCode.CANCELLED)
          const failure: AiImportError = err instanceof AiImportError ? err :
            new AiImportError(AiImportErrorCode.INVALID_JSON)
          const evidencePath: string = encoded === null ? '' : encoded.evidencePath
          failures.push(new PdfReviewFailure(pageNumber, failure.code, failure.message, evidencePath))
        } finally {
          this.activeRequestKey = ''
          rawResponse = ''
          assistantContent = ''
          if (providerRequest !== null) providerRequest.release()
          if (encoded !== null) encoded.releaseTransientText()
        }
        onProgress(pageNumber, totalPages, pageNumber - request.settings.startPage + 1,
          questions.length, '已完成第 ' + pageNumber.toString() + ' 页')
      }
    } finally {
      renderSession.close()
    }
    this.requireGeneration(generation)
    const session: PdfReviewSession = new PdfReviewSession(request.sessionId, PdfReviewSource.AI,
      util.generateRandomUUID(), request.settings.bankName, request.settings.subject, request.pdfPath,
      request.accountId, questions, failures, PdfReviewSaveStage.DRAFT)
    PdfReviewSessionStore.put(session)
    return session
  }

  private requireGeneration(generation: number): void {
    if (generation !== this.generation) throw new AiImportError(AiImportErrorCode.CANCELLED)
  }
}
```

Before considering this step complete, extract the inner body from `encoded = await ...` through `previousTail = ...` into one private `processPage(...)` method returning `ProcessedAiPage`; both `run()` and retry call that exact method, so request construction, parsing, crop atomicity and transient-text cleanup cannot drift. Add:

```ts
class ProcessedAiPage {
  questions: Array<PdfReviewQuestion>
  previousTail: string
  constructor(questions: Array<PdfReviewQuestion>, previousTail: string) {
    this.questions = questions
    this.previousTail = previousTail
  }
}

async retryPage(context: Context, session: PdfReviewSession, pageNumber: number,
  config: AiProviderConfig): Promise<PdfReviewSession> {
  if (session.source !== PdfReviewSource.AI || pageNumber < 1) {
    throw new AiImportError(AiImportErrorCode.INVALID_JSON)
  }
  const generation: number = ++this.generation
  const renderSession: PdfRenderSessionPort = this.renderer.open(session.pdfPath)
  try {
    const stableIds: Map<string, string> = new Map<string, string>()
    for (let index: number = 0; index < session.questions.length; index++) {
      const question: PdfReviewQuestion = session.questions[index]
      if (question.pageStart === pageNumber && question.pageEnd === pageNumber) {
        stableIds.set(question.draftQuestionId, question.questionUuid)
      }
    }
    const processed: ProcessedAiPage = await this.processPage(context, renderSession,
      session.sessionId, pageNumber, config, '', generation, stableIds)
    this.requireGeneration(generation)
    const nextQuestions: Array<PdfReviewQuestion> = new Array<PdfReviewQuestion>()
    for (let index: number = 0; index < session.questions.length; index++) {
      const question: PdfReviewQuestion = session.questions[index]
      if (question.pageStart !== pageNumber || question.pageEnd !== pageNumber) {
        nextQuestions.push(question)
      }
    }
    for (let index: number = 0; index < processed.questions.length; index++) {
      nextQuestions.push(processed.questions[index])
    }
    nextQuestions.sort((left: PdfReviewQuestion, right: PdfReviewQuestion): number => {
      if (left.pageStart !== right.pageStart) return left.pageStart - right.pageStart
      return left.draftQuestionId.localeCompare(right.draftQuestionId)
    })
    const nextFailures: Array<PdfReviewFailure> = session.failures.filter(
      (failure: PdfReviewFailure): boolean => failure.pageNumber !== pageNumber)
    const updated: PdfReviewSession = new PdfReviewSession(session.sessionId, session.source,
      session.bankUuid, session.bankName, session.subject, session.pdfPath, session.accountId,
      nextQuestions, nextFailures, session.saveStage)
    PdfReviewSessionStore.put(updated)
    const stored: PdfReviewSession | null = PdfReviewSessionStore.get(updated.sessionId)
    if (stored === null) throw new AiImportError(AiImportErrorCode.INVALID_JSON)
    return stored
  } finally {
    renderSession.close()
  }
}
```

Give `processPage` this exact signature so the call above and the main loop type-check:

```ts
private async processPage(context: Context, renderSession: PdfRenderSessionPort,
  sessionId: string, pageNumber: number, config: AiProviderConfig, previousTail: string,
  generation: number, stableIds: Map<string, string>): Promise<ProcessedAiPage>
```

Within it, derive `draftQuestionId` exactly as in the main loop and select `questionUuid` with `stableIds.get(draftQuestionId)` when present, otherwise `util.generateRandomUUID()`. It returns only after every question crop succeeds. Its `finally` always clears `rawResponse`/`assistantContent`, calls `providerRequest.release()`, and calls `encoded.releaseTransientText()`. Retry does not catch this error, so the old questions and old failure remain untouched unless a complete `ProcessedAiPage` has been returned.

- [ ] **Step 5: 运行串行/failure/retry 测试**

Run targeted ArkTS check, all AI CJS contracts, and entry Hypium.

Expected: PASS；maximum Provider concurrency is 1；page 3 never starts after page 2 cancellation；page failure creates no partial questions；Cloud/OCR call counters remain zero。

- [ ] **Step 6: 无提交 diff 检查点**

Run: `git diff -- entry/src/main/ets/services/ai/PdfAiImportCoordinator.ets entry/src/test`

Expected: no `Promise.all`, no paid endpoint in tests, no OCR or Cloud import reference, no raw response in `PdfReviewSession`；不要提交。

## Task 9: 使用稳定 UUID 保存文字并原子映射本机题图

**Files:**
- Create: `entry/src/main/ets/services/ai/AiImportSaveService.ets`
- Modify: `entry/src/main/ets/services/CloudQuestionRepository.ets:311-349`
- Modify: `entry/src/main/ets/services/DeviceImageStore.ets:1-88`
- Modify: `entry/src/test/AiImportLocalUnit.test.ets`
- Modify: `entry/src/test/CloudCacheContracts.test.cjs`
- Modify: `entry/src/test/AiImportSecurityContracts.test.cjs`

- [ ] **Step 1: 写稳定实体 ID 和分阶段保存失败合同**

Append to `CloudCacheContracts.test.cjs`:

```js
test('AI import can persist stable bank and question UUIDs', () => {
  const source = fs.readFileSync('entry/src/main/ets/services/CloudQuestionRepository.ets', 'utf8')
  const withIds = extractMethod(source, 'static async createBankWithIds')
  assert.match(withIds, /bank\.id/)
  assert.match(withIds, /question\.id/)
  assert.match(withIds, /SyncEntityType\.QUESTION_BANK/)
  assert.match(withIds, /SyncEntityType\.QUESTION/)
  assert.match(withIds, /pushOperations/)
  assert.doesNotMatch(withIds, /entityId.*generateRandomUUID/)
  assert.match(source, /static async createBank\([\s\S]*createBankWithIds/)
})

test('device images validate a complete batch before one immediate transaction', () => {
  const source = fs.readFileSync('entry/src/main/ets/services/DeviceImageStore.ets', 'utf8')
  const batch = extractMethod(source, 'static async saveBatch')
  assert.match(batch, /TransactionType\.IMMEDIATE/)
  assert.match(batch, /await transaction\.commit\(\)/)
  assert.match(batch, /await transaction\.rollback\(\)/)
  assert.match(batch, /duplicate/i)
})
```

Append to `AiImportSecurityContracts.test.cjs`:

```js
test('AI save payload excludes provider and local-only data', () => {
  const source = read('entry/src/main/ets/services/ai/AiImportSaveService.ets')
  assert.doesNotMatch(source, /api.?key|authorization|base.?url|prompt|raw.?response/i)
  assert.doesNotMatch(source, /CloudImportService|\/v1\/imports\/pdf|QuestionImageService\.commitImages/)
  assert.match(source, /createBankWithIds/)
  assert.match(source, /DeviceImageStore\.saveBatch/)
})
```

- [ ] **Step 2: 运行合同确认失败**

Run: `node --test entry/src/test/CloudCacheContracts.test.cjs entry/src/test/AiImportSecurityContracts.test.cjs`

Expected: FAIL because the new methods/service are missing.

- [ ] **Step 3: 保留旧入口并新增稳定 ID repository 方法**

Replace only the current `createBank()` body and add `createBankWithIds()`:

```ts
static async createBank(bank: QuestionBank, context: Context): Promise<string> {
  const questions: Array<Question> = new Array<Question>()
  for (let index: number = 0; index < bank.questions.length; index++) {
    const source: Question = bank.questions[index]
    questions.push(new Question(util.generateRandomUUID(), '', source.type, source.question,
      source.options.slice(), source.answer, source.analysis, source.sourcePageStart,
      source.sourcePageEnd, source.reviewState, source.images.slice()))
  }
  const identified: QuestionBank = new QuestionBank(util.generateRandomUUID(), bank.bankName,
    bank.subject, questions.length, bank.createTime, bank.isSample, questions)
  return CloudQuestionRepository.createBankWithIds(identified, context)
}

static async createBankWithIds(bank: QuestionBank, context: Context): Promise<string> {
  if (bank.bankName.trim().length === 0 || !CloudQuestionRepository.isUuid(bank.id)) {
    throw new Error('题库标识或名称无效')
  }
  const seen: Set<string> = new Set<string>()
  const accountId: string = await CloudQuestionRepository.requireSignedIn(context)
  const operations: Array<SyncPushOperation> = new Array<SyncPushOperation>()
  operations.push(new SyncPushOperation(new SyncOutboxOperation(
    util.generateRandomUUID(), SyncEntityType.QUESTION_BANK, bank.id, SyncOperationType.UPSERT,
    SyncPayloadFactory.bankPayload(bank.bankName, bank.subject), Date.now())))
  for (let index: number = 0; index < bank.questions.length; index++) {
    const question: Question = bank.questions[index]
    if (!CloudQuestionRepository.isUuid(question.id) || seen.has(question.id)) {
      throw new Error('题目标识无效或重复')
    }
    seen.add(question.id)
    operations.push(new SyncPushOperation(new SyncOutboxOperation(
      util.generateRandomUUID(), SyncEntityType.QUESTION, question.id, SyncOperationType.UPSERT,
      SyncPayloadFactory.questionPayload(question, bank.id), Date.now())))
  }
  const applied: Array<RemoteSyncOperation> = await CloudQuestionRepository.pushOperations(context, operations)
  const snapshot: CloudCacheSnapshot = await CloudQuestionRepository.loadSnapshot(accountId)
  CloudQuestionRepository.applyOrdered(accountId, snapshot, applied)
  await CloudQuestionRepository.saveSnapshot(accountId, snapshot,
    CloudQuestionRepository.maxSequence(applied))
  return bank.id
}

private static isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
}
```

Operation UUIDs intentionally remain fresh on every attempt; only entity UUIDs are stable, so a retry can update edited content without duplicating the bank/question.

- [ ] **Step 4: 实现批量图片映射事务**

Add to `DeviceImageStore.ets` and make existing `save()` delegate to it:

```ts
const DEVICE_IMAGE_TRANSACTION_OPTIONS: relationalStore.TransactionOptions = {
  transactionType: relationalStore.TransactionType.IMMEDIATE
}

static async save(context: Context, image: DeviceQuestionImage): Promise<void> {
  return DeviceImageStore.saveBatch(context, [image])
}

static async saveBatch(context: Context, images: Array<DeviceQuestionImage>): Promise<void> {
  if (images.length === 0) return
  const keys: Set<string> = new Set<string>()
  for (let index: number = 0; index < images.length; index++) {
    const image: DeviceQuestionImage = images[index]
    DeviceImageScope.key(image.accountId, image.questionUuid)
    DeviceImageScope.validateOwnedPath(context.filesDir, image.accountId, image.imagePath)
    if (!/^[a-f0-9]{64}$/.test(image.sha256) || !Number.isInteger(image.sortOrder) ||
      image.sortOrder < 0) {
      throw new Error('Device image metadata is invalid')
    }
    const key: string = image.accountId + ':' + image.questionUuid + ':' + image.sortOrder.toString()
    if (keys.has(key)) throw new Error('Device image batch contains a duplicate key')
    keys.add(key)
  }
  const store: relationalStore.RdbStore = DatabaseService.getStore()
  const transaction: relationalStore.Transaction =
    await store.createTransaction(DEVICE_IMAGE_TRANSACTION_OPTIONS)
  try {
    for (let index: number = 0; index < images.length; index++) {
      const image: DeviceQuestionImage = images[index]
      const values: Array<relationalStore.ValueType> = [
        image.accountId, image.questionUuid, image.imagePath, image.sha256, image.sortOrder
      ]
      await transaction.execute(
        'INSERT INTO device_question_image(account_id, question_uuid, image_path, sha256, sort_order) ' +
        'VALUES (?, ?, ?, ?, ?) ON CONFLICT(account_id, question_uuid, sort_order) DO UPDATE SET ' +
        'image_path = excluded.image_path, sha256 = excluded.sha256', values)
    }
    await transaction.commit()
  } catch (err) {
    await transaction.rollback()
    throw err
  }
}
```

- [ ] **Step 5: 实现 label/type/options 转换和两阶段保存**

Create `AiImportSaveService.ets` with injectable writers for Hypium and these exact transitions:

```ts
import { Context } from '@kit.AbilityKit'
import { fileIo as fs, hash } from '@kit.CoreFileKit'
import { DeviceQuestionImage } from '../../models/CloudCacheModels'
import { AccountSessionState } from '../../models/AccountSession'
import { Question } from '../../models/Question'
import { QuestionBank } from '../../models/QuestionBank'
import { AccountSessionService } from '../AccountSessionService'
import { CloudQuestionRepository } from '../CloudQuestionRepository'
import { DeviceImageScope, DeviceImageStore } from '../DeviceImageStore'
import { AiQuestionType } from '../../models/ai/AiImportModels'
import {
  PdfReviewOption,
  PdfReviewQuestion,
  PdfReviewSaveStage,
  PdfReviewSession
} from '../review/PdfReviewModels'
import { PdfReviewSessionStore } from '../review/PdfReviewSession'

export interface AiImportBankWriterPort {
  write(context: Context, bank: QuestionBank): Promise<void>
}

export interface AiImportImageWriterPort {
  write(context: Context, session: PdfReviewSession): Promise<void>
}

export interface AiImportAccountPort {
  require(context: Context, expectedAccountId: string): Promise<void>
}

class DefaultAiImportBankWriter implements AiImportBankWriterPort {
  async write(context: Context, bank: QuestionBank): Promise<void> {
    await CloudQuestionRepository.createBankWithIds(bank, context)
  }
}

class DefaultAiImportImageWriter implements AiImportImageWriterPort {
  async write(context: Context, session: PdfReviewSession): Promise<void> {
    const mappings: Array<DeviceQuestionImage> =
      await AiImportSaveService.prepareImages(context, session)
    await DeviceImageStore.saveBatch(context, mappings)
  }
}

class DefaultAiImportAccount implements AiImportAccountPort {
  async require(context: Context, expectedAccountId: string): Promise<void> {
    const state: AccountSessionState = await AccountSessionService.state(context)
    if (!state.signedIn || state.userId !== expectedAccountId) {
      throw new Error('当前账号与导入会话不一致')
    }
  }
}

export class AiImportSaveService {
  private bankWriter: AiImportBankWriterPort
  private imageWriter: AiImportImageWriterPort
  private account: AiImportAccountPort

  constructor(bankWriter: AiImportBankWriterPort, imageWriter: AiImportImageWriterPort,
    account: AiImportAccountPort) {
    this.bankWriter = bankWriter
    this.imageWriter = imageWriter
    this.account = account
  }

  static async save(context: Context, session: PdfReviewSession): Promise<PdfReviewSession> {
    const service: AiImportSaveService = new AiImportSaveService(
      new DefaultAiImportBankWriter(), new DefaultAiImportImageWriter(),
      new DefaultAiImportAccount())
    const saved: PdfReviewSession = await service.saveSession(context, session)
    if (saved.saveStage === PdfReviewSaveStage.COMPLETE) {
      await AiImportSaveService.removeSessionCache(context, saved)
    }
    return saved
  }

  async saveSession(context: Context, session: PdfReviewSession): Promise<PdfReviewSession> {
    if (session.saveStage === PdfReviewSaveStage.DRAFT) {
      const bank: QuestionBank = AiImportSaveService.toBank(session)
      await this.bankWriter.write(context, bank)
      session.saveStage = PdfReviewSaveStage.TEXT_SAVED
      PdfReviewSessionStore.put(session)
    }
    if (session.saveStage === PdfReviewSaveStage.TEXT_SAVED) {
      await this.account.require(context, session.accountId)
      await this.imageWriter.write(context, session)
      session.saveStage = PdfReviewSaveStage.COMPLETE
      PdfReviewSessionStore.put(session)
    }
    return session
  }

  static async abandon(context: Context, session: PdfReviewSession): Promise<void> {
    if (session.saveStage !== PdfReviewSaveStage.DRAFT) {
      throw new Error('题目文字已保存，请完成原题图片保存')
    }
    await AiImportSaveService.removeSessionCache(context, session)
    PdfReviewSessionStore.remove(session.sessionId)
  }

  private static toBank(session: PdfReviewSession): QuestionBank {
    const questions: Array<Question> = new Array<Question>()
    for (let index: number = 0; index < session.questions.length; index++) {
      const source: PdfReviewQuestion = session.questions[index]
      const options: Array<string> = new Array<string>()
      const orderedOptions: Array<PdfReviewOption> = source.options.slice()
      orderedOptions.sort((left: PdfReviewOption, right: PdfReviewOption): number =>
        left.key.localeCompare(right.key))
      for (let optionIndex: number = 0; optionIndex < orderedOptions.length; optionIndex++) {
        options.push(AiImportSaveService.optionText(orderedOptions[optionIndex]))
      }
      questions.push(new Question(source.questionUuid, session.bankUuid,
        AiImportSaveService.questionType(source.type),
        AiImportSaveService.withLabel(source.label, source.question), options,
        source.answer, source.analysis, source.pageStart, source.pageEnd,
        source.reviewRequired ? 'needs_review' : 'confirmed'))
    }
    return new QuestionBank(session.bankUuid, session.bankName.trim(), session.subject.trim(),
      questions.length, Date.now(), false, questions)
  }

  private static questionType(type: AiQuestionType): string {
    if (type === AiQuestionType.SINGLE_CHOICE) return 'single_choice'
    if (type === AiQuestionType.BLANK) return 'fill_blank'
    if (type === AiQuestionType.SHORT_ANSWER) return 'short_answer'
    return 'unclassified'
  }

  private static withLabel(label: string, question: string): string {
    const normalizedLabel: string = label.trim()
    const normalizedQuestion: string = question.trim()
    if (normalizedQuestion === normalizedLabel ||
      normalizedQuestion.startsWith(normalizedLabel + ' ') ||
      normalizedQuestion.startsWith(normalizedLabel + '\n')) return normalizedQuestion
    return normalizedLabel.length === 0 ? normalizedQuestion : normalizedLabel + ' ' + normalizedQuestion
  }

  private static optionText(option: PdfReviewOption): string {
    const value: string = option.value.trim()
    if (value.startsWith(option.key + '.') || value.startsWith(option.key + '．') ||
      value.startsWith(option.key + '、')) return value
    return option.key + '. ' + value
  }
}
```

Add `static async prepareImages(context: Context, session: PdfReviewSession)` and `static async removeSessionCache(context: Context, session: PdfReviewSession)` before the conversion helpers. Build `prepareImages()` by moving the account-directory validation, `lstatIfPresent()`, ordinary-file and SHA-256 checks from the current `PdfImportReviewPage.verifyArtifactFile/ensureAccountDirectory` into this service. For every `PdfReviewImage`, compute `hash.hash(source.localPath, 'sha256')`, re-stat the source, and copy it to the validated direct child `ai_import_<questionUuid>_<sortOrder>_<sha256>.jpg` under `DeviceImageScope.accountDirectory(context.filesDir, session.accountId)`. Re-stat and re-hash the destination; an existing destination is reusable only when size and SHA match. Return all `DeviceQuestionImage` mappings before `saveBatch()` is called, and use copy rather than move until that transaction commits.

`removeSessionCache()` enumerates only the paths already present in `session.questions[].images[]` and `session.failures[]`; it removes a path only after `lstat` confirms an ordinary non-symlink direct child of `context.cacheDir` whose basename starts with `ai_import_page_<sessionId>_` or `ai_import_crop_<sessionId>_`. Then it calls `PdfImportService.removeTemporaryPdf(session.pdfPath)`. It never walks a broad directory, never follows links, and never removes an `ai_import_` final account image. Import `PdfImportService` for this call.

- [ ] **Step 6: 添加两阶段失败恢复测试**

Add imports for the three save ports and these named fakes to `AiImportLocalUnit.test.ets`:

```ts
class FakeBankWriter implements AiImportBankWriterPort {
  calls: number = 0
  fail: boolean = false
  captured: QuestionBank | null = null
  async write(_context: Context, bank: QuestionBank): Promise<void> {
    this.calls++
    if (this.fail) throw new Error('fake text failure')
    this.captured = bank
  }
}

class FakeImageWriter implements AiImportImageWriterPort {
  calls: number = 0
  fail: boolean = false
  async write(_context: Context, _session: PdfReviewSession): Promise<void> {
    this.calls++
    if (this.fail) throw new Error('fake image failure')
  }
}

class FakeAccount implements AiImportAccountPort {
  async require(_context: Context, _expectedAccountId: string): Promise<void> {}
}

function createSaveFixtureSession(): PdfReviewSession {
  const first: PdfReviewQuestion = new PdfReviewQuestion(
    'save-session:1:0', '11111111-1111-4111-8111-111111111111', '例1.1',
    AiQuestionType.BLANK, '例1.1 已含标签',
    [new PdfReviewOption('B', '乙'), new PdfReviewOption('A', '甲')], '', '',
    1, 1, 1, false, new Array<PdfReviewImage>())
  const second: PdfReviewQuestion = new PdfReviewQuestion(
    'save-session:1:1', '33333333-3333-4333-8333-333333333333', '例1.2',
    AiQuestionType.UNKNOWN, '尚未带标签', new Array<PdfReviewOption>(), '', '',
    1, 1, 1, true, new Array<PdfReviewImage>())
  return new PdfReviewSession('save-session', PdfReviewSource.AI,
    '22222222-2222-4222-8222-222222222222', '题库', '数学', '/unused.pdf', 'account-1',
    [first, second], new Array<PdfReviewFailure>(), PdfReviewSaveStage.DRAFT)
}
```

The fixture has stable bank/question UUIDs and two questions: a `BLANK` question whose text already begins with `例1.1` and B/A options, plus an `UNKNOWN` question whose text does not include `例1.2`. Add this test:

```ts
it('resumes image save without repeating text save and preserves conversion rules', 0, async () => {
  const context: Context = getContext()
  const session: PdfReviewSession = createSaveFixtureSession()
  const bankWriter: FakeBankWriter = new FakeBankWriter()
  const imageWriter: FakeImageWriter = new FakeImageWriter()
  const service: AiImportSaveService = new AiImportSaveService(
    bankWriter, imageWriter, new FakeAccount())

  bankWriter.fail = true
  try { await service.saveSession(context, session) } catch {}
  expect(session.saveStage).assertEqual(PdfReviewSaveStage.DRAFT)
  bankWriter.fail = false
  imageWriter.fail = true
  try { await service.saveSession(context, session) } catch {}
  expect(session.saveStage).assertEqual(PdfReviewSaveStage.TEXT_SAVED)
  expect(bankWriter.calls).assertEqual(2)
  expect(imageWriter.calls).assertEqual(1)

  imageWriter.fail = false
  await service.saveSession(context, session)
  expect(session.saveStage).assertEqual(PdfReviewSaveStage.COMPLETE)
  expect(bankWriter.calls).assertEqual(2)
  expect(imageWriter.calls).assertEqual(2)
  await service.saveSession(context, session)
  expect(bankWriter.calls).assertEqual(2)
  expect(imageWriter.calls).assertEqual(2)

  const bank: QuestionBank | null = bankWriter.captured
  expect(bank === null).assertFalse()
  if (bank === null) return
  expect(bank.id).assertEqual(session.bankUuid)
  expect(bank.questions[0].id).assertEqual(session.questions[0].questionUuid)
  expect(bank.questions[0].type).assertEqual('fill_blank')
  expect(bank.questions[1].type).assertEqual('unclassified')
  expect(bank.questions[0].question.indexOf('例1.1 例1.1')).assertEqual(-1)
  expect(bank.questions[1].question.startsWith('例1.2 ')).assertTrue()
  expect(bank.questions[0].options.join('|')).assertEqual('A. 甲|B. 乙')
})
```

The helper contains no filesystem path that exists and is safe because both I/O ports and account verification are fakes.

Run targeted ArkTS check, `CloudCacheContracts`, `AiImportSecurityContracts`, and entry Hypium.

Expected: all PASS; existing `createBank()` callers and `DeviceImageStore.save()` behavior remain compatible.

- [ ] **Step 7: 无提交 diff 检查点**

Run: `git diff -- entry/src/main/ets/services/CloudQuestionRepository.ets entry/src/main/ets/services/DeviceImageStore.ets entry/src/main/ets/services/ai/AiImportSaveService.ets entry/src/test`

Expected: only `/v1/sync/push` receives ordinary question text fields; paths, PDF, image bytes, Provider config and credentials are absent from payloads；不要提交。

## Task 10: 把现有审核页改为 Cloud/AI 双源 adapter

**Files:**
- Create: `entry/src/main/ets/services/review/CloudPdfReviewAdapter.ets`
- Create: `entry/src/main/ets/services/review/AiPdfReviewAdapter.ets`
- Modify: `entry/src/main/ets/pages/PdfImportReviewPage.ets:1-1132`
- Modify: `entry/src/test/CloudImportPageContracts.test.cjs`
- Modify: `entry/src/test/AiImportContracts.test.cjs`
- Test: `entry/src/test/MathContentContracts.test.cjs`

- [ ] **Step 1: 写 adapter 隔离与 KaTeX 保留失败合同**

Append to `AiImportContracts.test.cjs`:

```js
test('review page is source-neutral and AI evidence is visible before save', () => {
  const page = read('entry/src/main/ets/pages/PdfImportReviewPage.ets')
  const cloud = read('entry/src/main/ets/services/review/CloudPdfReviewAdapter.ets')
  const ai = read('entry/src/main/ets/services/review/AiPdfReviewAdapter.ets')
  assert.match(page, /PdfReviewAdapter/)
  assert.match(page, /PdfReviewQuestion/)
  assert.match(page, /file:\/\//)
  assert.match(page, /重试识别/)
  assert.match(page, /手动新增题目/)
  assert.match(page, /放弃本页/)
  assert.doesNotMatch(page, /CloudImportService|CloudImportApi|ConfirmImportResult/)
  assert.match(cloud, /CloudImportService/)
  assert.doesNotMatch(ai, /CloudImportService|CloudImportApi|\/v1\/imports\/pdf/)
})
```

Update `CloudImportPageContracts.test.cjs` so its confirm/download/SHA/map/ACK ordering assertions read `CloudPdfReviewAdapter.ets` instead of `PdfImportReviewPage.ets`. Keep every existing ordered fragment and failure-resume assertion unchanged.

- [ ] **Step 2: 运行审核与数学预览合同确认失败**

Run:

```powershell
node --test entry/src/test/AiImportContracts.test.cjs `
  entry/src/test/CloudImportPageContracts.test.cjs `
  entry/src/test/MathContentContracts.test.cjs
```

Expected: AI and relocated Cloud contracts FAIL；`MathContentContracts` retains its baseline result.

- [ ] **Step 3: 把 Cloud-only 操作迁入 adapter，不改变顺序**

Create `CloudPdfReviewAdapter.ets` implementing `PdfReviewAdapter`. Move these current page methods and their private helpers into the class: account verification, `CloudImportService.getDraft`, confirm request construction, artifact download, exact size/SHA verification, account-directory validation, `DeviceImageStore.save`, unavailable-artifact handling, and `acknowledgeArtifacts`. Preserve this order:

```ts
const result: ConfirmImportResult = existingResult === null ?
  await CloudImportService.confirm(context, jobId, request) : existingResult
state.setConfirmResult(result)
const savedArtifactIds: Array<string> = await this.downloadArtifacts(
  context, jobId, accountId, result)
await this.requireAccount(context, accountId)
await CloudImportService.acknowledgeArtifacts(context, jobId, savedArtifactIds)
state.setCloudStatus(CloudImportStatus.CONFIRMED)
```

Convert Cloud draft questions to `PdfReviewQuestion` on `load()`: use an empty `label` and `questionUuid`, map `single_choice → SINGLE_CHOICE`, `fill_blank → BLANK`, `short_answer → SHORT_ANSWER`, every other Cloud value to `UNKNOWN`, and convert each remote artifact to `PdfReviewImage` without inventing a local path. Deep-copy options by iterating sorted `Object.keys(source.options)` into `Array<PdfReviewOption>`; on `persist/save`, reverse the type mapping, rebuild a fresh Cloud options object and never reuse a mutable object owned by the page. `retryPage()` returns a deep copy of the unchanged Cloud session because the formal Cloud worker owns its completed draft; the AI-only retry controls are hidden for `PdfReviewSource.CLOUD`.

- [ ] **Step 4: 实现 AI adapter**

Create `AiPdfReviewAdapter.ets`:

```ts
import { Context } from '@kit.AbilityKit'
import { AiProviderConfig } from '../../models/ai/AiProviderConfig'
import { PdfImportState } from '../../utils/PdfImportState'
import { AiImportSaveService } from '../ai/AiImportSaveService'
import { PdfAiImportCoordinator } from '../ai/PdfAiImportCoordinator'
import { AiProviderConfigStore } from '../ai/AiProviderConfigStore'
import { PdfReviewAdapter, PdfReviewSession, PdfReviewSource } from './PdfReviewModels'
import { PdfReviewSessionStore } from './PdfReviewSession'

export class AiPdfReviewAdapter implements PdfReviewAdapter {
  private sessionId: string
  private coordinator: PdfAiImportCoordinator

  constructor(sessionId: string, coordinator: PdfAiImportCoordinator) {
    this.sessionId = sessionId
    this.coordinator = coordinator
  }

  async load(context: Context): Promise<PdfReviewSession> {
    const session: PdfReviewSession | null = PdfReviewSessionStore.get(this.sessionId)
    if (session === null || session.source !== PdfReviewSource.AI) {
      throw new Error('AI 导入审核会话已失效')
    }
    return session
  }

  persist(session: PdfReviewSession): void { PdfReviewSessionStore.put(session) }

  save(context: Context, session: PdfReviewSession): Promise<PdfReviewSession> {
    return AiImportSaveService.save(context, session)
  }

  async retryPage(context: Context, session: PdfReviewSession,
    pageNumber: number): Promise<PdfReviewSession> {
    const config: AiProviderConfig | null = await AiProviderConfigStore.load(context)
    if (config === null) throw new Error('请先配置 AI Provider 和模型')
    return this.coordinator.retryPage(context, session, pageNumber, config)
  }

  async abandon(context: Context, session: PdfReviewSession): Promise<void> {
    this.coordinator.cancel()
    await AiImportSaveService.abandon(context, session)
    PdfReviewSessionStore.remove(this.sessionId)
    PdfImportState.shared().clearReviewSessionId()
  }
}
```

- [ ] **Step 5: 把页面状态和编辑操作替换为通用模型**

At the top of `PdfImportReviewPage.ets`, replace Cloud model/service imports with review imports. Select the adapter once:

```ts
private adapter: PdfReviewAdapter | null = null
@State session: PdfReviewSession | null = null
@State draftQuestions: Array<PdfReviewQuestion> = new Array<PdfReviewQuestion>()
@State failures: Array<PdfReviewFailure> = new Array<PdfReviewFailure>()

aboutToAppear(): void {
  const state: PdfImportState = PdfImportState.shared()
  const sessionId: string = state.getReviewSessionId()
  this.adapter = sessionId.length > 0 ?
    new AiPdfReviewAdapter(sessionId, PdfAiImportCoordinator.createDefault()) :
    new CloudPdfReviewAdapter()
  this.loadReview()
}
```

Replace `updateOption` with an immutable array update:

```ts
private updateOption(draftQuestionId: string, optionKey: string, value: string): void {
  const index: number = this.findQuestionIndex(draftQuestionId)
  if (index < 0) return
  const source: PdfReviewQuestion = this.draftQuestions[index]
  const options: Array<PdfReviewOption> = new Array<PdfReviewOption>()
  for (let optionIndex: number = 0; optionIndex < source.options.length; optionIndex++) {
    const option: PdfReviewOption = source.options[optionIndex]
    options.push(new PdfReviewOption(option.key, option.key === optionKey ? value : option.value))
  }
  this.replaceQuestion(draftQuestionId, source.type, source.question, options,
    source.answer, source.analysis)
}
```

Change `optionKeys`/`optionValue` and every builder loop to use `PdfReviewOption.key/value`. Keep these current dirty-worktree symbols and behavior exactly present: `MathContentView`, `MathContentUtils`, `previewDraftQuestionId`, `hasMathContent`, `toggleMathPreview`, `MathFieldPreview`, `DraftMathPreview`, the native text inputs, and the “预览公式/收起公式预览” button.

- [ ] **Step 6: 显示 AI 原图和失败页操作**

In each question card, before the editable fields, render every non-empty local path:

```ts
ForEach(draftQuestion.images, (sourceImage: PdfReviewImage) => {
  if (sourceImage.localPath.length > 0) {
    Image('file://' + sourceImage.localPath)
      .width('100%')
      .objectFit(ImageFit.Contain)
      .borderRadius(12)
      .accessibilityText('第 ' + draftQuestion.pageStart.toString() + ' 页原题图片')
  }
}, (sourceImage: PdfReviewImage): string =>
  sourceImage.localPath + ':' + sourceImage.sortOrder.toString())
```

For each AI failure, show its whole-page image and three buttons. Their handlers are exact:

```ts
private async retryFailure(pageNumber: number): Promise<void> {
  if (this.adapter === null || this.session === null || this.pending) return
  this.pending = true
  try {
    this.session = await this.adapter.retryPage(getContext(this), this.session, pageNumber)
    this.applySession(this.session)
  } catch (err) {
    this.errorMessage = err instanceof AiImportError ?
      AiImportErrorMessages.forCode(err.code) : '本页重试失败'
  } finally {
    this.pending = false
  }
}

private addManualQuestion(failure: PdfReviewFailure): void {
  if (this.session === null) return
  const question: PdfReviewQuestion = new PdfReviewQuestion(
    this.session.sessionId + ':manual:' + failure.pageNumber.toString() + ':' + Date.now().toString(),
    util.generateRandomUUID(), '', AiQuestionType.UNKNOWN, '', new Array<PdfReviewOption>(), '', '',
    failure.pageNumber, failure.pageNumber, 0, true,
    [new PdfReviewImage('', failure.evidencePath, '', 0, 'image/jpeg', 0)])
  this.session.questions.push(question)
  this.discardFailure(failure.pageNumber)
}

private discardFailure(pageNumber: number): void {
  if (this.session === null) return
  this.session.failures = this.session.failures.filter(
    (failure: PdfReviewFailure): boolean => failure.pageNumber !== pageNumber)
  this.adapter?.persist(this.session)
  this.applySession(this.session)
}
```

The UI labels must be exactly `重试识别`, `手动新增题目`, and `放弃本页`. Cloud sessions do not render this failure section.
Import `AiImportError` and `AiImportErrorMessages` for the local retry message; never render an arbitrary caught `Error.message`.

- [ ] **Step 7: 统一保存和明确放弃**

Replace `confirmDraft()` with `saveReview()` that validates non-empty questions, persists page edits, calls `adapter.save`, and shows either complete or text-saved/image-failed state. On navigation back from a `DRAFT` session, ask whether to continue editing or explicitly abandon; only that explicit branch calls `adapter.abandon` and deletes owned cache files. When the stage is `TEXT_SAVED`, hide/disable abandon and show `题目文字已保存，请重试原题图片保存`; another Save call resumes only the image phase. A `COMPLETE` session leaves through the existing success navigation.

- [ ] **Step 8: 运行审核回归**

Run:

```powershell
node --test entry/src/test/AiImportContracts.test.cjs `
  entry/src/test/CloudImportPageContracts.test.cjs `
  entry/src/test/MathContentContracts.test.cjs `
  entry/src/test/PdfImportContracts.test.cjs
node 'C:/Users/32773/.agents/skills/harmonyos-dev-skill/scripts/arkts-check.cjs' --project . --files `
  entry/src/main/ets/services/review/CloudPdfReviewAdapter.ets `
  entry/src/main/ets/services/review/AiPdfReviewAdapter.ets `
  entry/src/main/ets/pages/PdfImportReviewPage.ets
```

Expected: all contracts PASS and ArkTS JSON `success: true`; Cloud confirm/download/ACK order and KaTeX preview remain intact.

- [ ] **Step 9: 无提交 diff 检查点**

Run: `git diff -- entry/src/main/ets/pages/PdfImportReviewPage.ets entry/src/main/ets/services/review entry/src/test/MathContentContracts.test.cjs entry/src/test/CloudImportPageContracts.test.cjs`

Expected: current uncommitted math-preview hunks still exist; Cloud protocol lives only in Cloud adapter; AI adapter has no Cloud import reference；不要提交。

## Task 11: 增加 AI 设置页和显式连接测试

**Files:**
- Create: `entry/src/main/ets/services/ai/AiConnectionTestService.ets`
- Create: `entry/src/main/ets/pages/AiRecognitionSettingsPage.ets`
- Modify: `entry/src/main/ets/pages/MinePage.ets:673-803`
- Modify: `entry/src/main/resources/base/profile/main_pages.json:2-12`
- Modify: `entry/src/main/resources/base/profile/easy_go.json:7-18`
- Modify: `entry/src/test/AiImportContracts.test.cjs`
- Modify: `entry/src/test/AiImportSecurityContracts.test.cjs`

- [ ] **Step 1: 写设置字段、路由与无回显失败合同**

Append to `AiImportContracts.test.cjs`:

```js
test('AI settings expose the approved provider controls', () => {
  const page = read('entry/src/main/ets/pages/AiRecognitionSettingsPage.ets')
  const mine = read('entry/src/main/ets/pages/MinePage.ets')
  const pages = JSON.parse(read('entry/src/main/resources/base/profile/main_pages.json')).src
  assert.match(page, /AI 视觉识别（推荐）/)
  assert.match(page, /API Provider/)
  assert.match(page, /API Key/)
  assert.match(page, /Model/)
  assert.match(page, /Base URL/)
  assert.match(page, /高级设置/)
  assert.match(page, /测试连接/)
  assert.match(page, /清除 API Key/)
  assert.match(mine, /pages\/AiRecognitionSettingsPage/)
  assert.ok(pages.includes('pages/AiRecognitionSettingsPage'))
})
```

Append to `AiImportSecurityContracts.test.cjs`:

```js
test('settings never load a saved key into visible state', () => {
  const page = read('entry/src/main/ets/pages/AiRecognitionSettingsPage.ets')
  assert.doesNotMatch(page, /getApiKey|getCredential|withCredential[\s\S]*this\.apiKey/)
  assert.match(page, /已配置/)
  assert.match(page, /this\.apiKey = ''/)
})
```

- [ ] **Step 2: 运行合同确认失败**

Run the two AI CJS contract files.

Expected: FAIL because the settings page and routes are missing.

- [ ] **Step 3: 实现显式、极小且无自动重试的连接测试**

Create `AiConnectionTestService.ets` with an injectable adapter/transport and this production entry. The tiny image constant is a 1×1 JPEG and exists only in memory:

```ts
import { Context } from '@kit.AbilityKit'
import { AiProviderConfig } from '../../models/ai/AiProviderConfig'
import { AiCredentialStore } from './AiCredentialStore'
import { AiProviderAdapter, AiProviderRequest } from './AiProviderAdapter'
import { OpenAiCompatibleAdapter } from './OpenAiCompatibleAdapter'
import { AiVisionTransport, AiVisionTransportPort } from './AiVisionTransport'

const TINY_JPEG_BASE64: string =
  '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAP//////////////////////////////////////////' +
  '////////////////////////////////////////////2wBDAf//////////////////////////' +
  '////////////////////////////////////////////////////////////wAARCAABAAEDASIA' +
  'AhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAX/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oADA' +
  'MBAAIQAxAAAAEf/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABBQJ//9k='

export class AiConnectionTestService {
  static async test(context: Context, config: AiProviderConfig): Promise<void> {
    const adapter: OpenAiCompatibleAdapter = new OpenAiCompatibleAdapter()
    const transport: AiVisionTransport = new AiVisionTransport()
    await AiCredentialStore.withCredential<void>(context,
      (credential: Uint8Array): Promise<void> =>
        AiConnectionTestService.testWithCredential(
          adapter, transport, config, credential, 'ai-connection-test'))
  }

  static async testWithCredential(adapter: AiProviderAdapter, transport: AiVisionTransportPort,
    config: AiProviderConfig, credential: Uint8Array, requestKey: string): Promise<void> {
    const request: AiProviderRequest = adapter.buildRequest(config,
      '连接测试：只返回 {"questions":[]}，不要解释。', TINY_JPEG_BASE64)
    let raw: string = ''
    try {
      raw = await transport.postJson(request.endpoint, credential, request.body, requestKey)
      adapter.extractAssistantContent(raw)
    } finally {
      raw = ''
      request.release()
    }
  }
}
```

Do not parse `questions` or require a real question for a white pixel; a successful HTTP response with a non-empty assistant content proves address, auth, model and visual message compatibility. There is no background invocation or automatic retry. `testWithCredential()` is a narrow dependency-injection seam used only inside the HUKS callback and fake-only tests; it never stores or returns the credential.

Add this fake and test to `AiImportLocalUnit.test.ets`:

```ts
class FakeConnectionTransport implements AiVisionTransportPort {
  response: string = '{"choices":[{"message":{"content":"{\\"questions\\":[]}"}}]}'
  error: AiImportError | null = null
  calls: number = 0

  async postJson(endpoint: string, _credential: Uint8Array, body: string,
    _requestKey: string): Promise<string> {
    this.calls++
    expect(endpoint.endsWith('/chat/completions')).assertTrue()
    expect(body.indexOf('data:image/jpeg;base64,') >= 0).assertTrue()
    if (this.error !== null) throw this.error
    return this.response
  }

  cancel(_requestKey: string): void {}
}

it('connection test uses one fake visual request and propagates stable failures', 0, async () => {
  const adapter: OpenAiCompatibleAdapter = new OpenAiCompatibleAdapter()
  const config: AiProviderConfig = new AiProviderConfig(
    AiProviderId.CUSTOM, 'vision-model', 'https://vision.example.com/v1', false)
  const credential: Uint8Array = new Uint8Array([115, 107, 45, 102, 97, 107, 101])
  const transport: FakeConnectionTransport = new FakeConnectionTransport()
  await AiConnectionTestService.testWithCredential(
    adapter, transport, config, credential, 'connection-success')
  expect(transport.calls).assertEqual(1)
  const errors: Array<AiImportErrorCode> = [
    AiImportErrorCode.AUTH_FAILED,
    AiImportErrorCode.RATE_LIMITED,
    AiImportErrorCode.TIMEOUT
  ]
  for (let index: number = 0; index < errors.length; index++) {
    transport.error = new AiImportError(errors[index])
    let actual: string = ''
    try {
      await AiConnectionTestService.testWithCredential(
        adapter, transport, config, credential, 'connection-failure-' + index.toString())
    } catch (err) {
      if (err instanceof AiImportError) actual = err.code
    }
    expect(actual).assertEqual(errors[index])
  }
  credential.fill(0)
})
```

Import `AiConnectionTestService` and `AiVisionTransportPort`. This test never creates `AiVisionTransport`, reads HUKS, or contacts an external host.

- [ ] **Step 4: 实现设置页状态和保存边界**

Create `AiRecognitionSettingsPage.ets` with these state fields and methods; style the surrounding `Navigation`, cards, colors, radius and safe-area padding with the same `DesignTokens`/`ThemeManager` pattern used by `MinePage`:

```ts
@Entry
@Component
struct AiRecognitionSettingsPage {
  @State providerId: AiProviderId = AiProviderId.OPENAI
  @State model: string = ''
  @State baseUrl: string = 'https://api.openai.com/v1'
  @State apiKey: string = ''
  @State showKey: boolean = false
  @State showAdvanced: boolean = false
  @State configuredKey: boolean = false
  @State pending: boolean = false
  @State message: string = ''

  aboutToAppear(): void { this.load() }

  private async load(): Promise<void> {
    try {
      const context: Context = getContext(this)
      const config: AiProviderConfig | null = await AiProviderConfigStore.load(context)
      if (config !== null) {
        this.providerId = config.providerId
        this.model = config.model
        this.baseUrl = config.baseUrl
      }
      this.configuredKey = await AiCredentialStore.hasCredential(context)
    } catch {
      this.message = 'AI 识别设置读取失败'
    } finally {
      this.apiKey = ''
    }
  }

  private async save(): Promise<void> {
    if (this.pending) return
    this.pending = true
    this.message = ''
    try {
      const context: Context = getContext(this)
      const config: AiProviderConfig = await AiProviderConfigStore.save(context,
        new AiProviderConfig(this.providerId, this.model, this.baseUrl))
      this.baseUrl = config.baseUrl
      if (this.apiKey.trim().length > 0) await AiCredentialStore.save(context, this.apiKey)
      this.configuredKey = await AiCredentialStore.hasCredential(context)
      this.message = 'AI 识别设置已保存'
    } catch (err) {
      this.message = this.safeMessage(err, 'AI 识别设置保存失败')
    } finally {
      this.apiKey = ''
      this.showKey = false
      this.pending = false
    }
  }

  private async clearKey(): Promise<void> {
    if (this.pending) return
    this.pending = true
    try {
      await AiCredentialStore.clear(getContext(this))
      this.configuredKey = false
      this.message = 'API Key 已清除'
    } catch {
      this.message = 'API Key 清除失败'
    } finally {
      this.apiKey = ''
      this.showKey = false
      this.pending = false
    }
  }

  private async testConnection(): Promise<void> {
    if (this.pending) return
    this.pending = true
    try {
      const config: AiProviderConfig = AiProviderConfigValidator.normalize(
        new AiProviderConfig(this.providerId, this.model, this.baseUrl))
      await AiConnectionTestService.test(getContext(this), config)
      this.message = '连接测试成功'
    } catch (err) {
      this.message = this.safeMessage(err, '连接测试失败')
    } finally {
      this.pending = false
    }
  }

  private safeMessage(err: Object, fallback: string): string {
    if (err instanceof AiImportError) return AiImportErrorMessages.forCode(err.code)
    return fallback
  }
}
```

Import `AiImportError` and `AiImportErrorMessages`. Do not use an arbitrary `Error.message`, HUKS error, Provider body, HTTP error object, stack, or credential-derived string as visible text.

The `build()` body must use two explicit provider buttons (`OpenAI 官方` and `OpenAI-compatible 自定义`), a `TextInput` for Model, a password `TextInput` whose type toggles only for current `apiKey`, the status `已配置` without masked suffix, an `高级设置` disclosure containing Base URL, and Save/Clear/Test buttons. Place the warning `测试连接会发送一张极小测试图片，可能产生极少量模型费用` immediately above the test button.

- [ ] **Step 5: 在“我的 → 设置”新增入口并注册页面**

Insert this button in `MinePage.SettingsSection()` before “深色模式”, without editing `DebugToolsSection` or `copyTestToken`:

```ts
Button() {
  Row({ space: 12 }) {
    Text('AI').width(36).height(36).textAlign(TextAlign.Center)
    Text('AI 识别设置').fontSize(BODY_FONT_SIZE).fontColor(this.colors().textPrimary)
    Blank()
    Text('›').fontSize(24).fontColor(this.colors().textCaption)
  }.width('100%').height(60)
}
.type(ButtonType.Normal)
.width('100%')
.height(60)
.padding(0)
.backgroundColor(this.colors().cardBackground)
.accessibilityText('AI 识别设置')
.onClick(() => {
  this.getUIContext().getRouter().pushUrl({ url: 'pages/AiRecognitionSettingsPage' })
})
```

Add `pages/AiRecognitionSettingsPage` to `main_pages.json` and `easy_go.json.fullScreenPages`.

- [ ] **Step 6: 运行设置页合同、ArkTS 检查和 build**

Run the two AI CJS contracts, targeted ArkTS check for page/service/MinePage, and:

```powershell
node 'C:/Users/32773/.agents/skills/harmonyos-dev-skill/scripts/deveco-build.cjs' `
  --project . --build-mode debug --module entry@default --json
```

Expected: contracts PASS，ArkTS JSON `success: true`，build JSON `success: true`。Automated tests do not call the connection button.

- [ ] **Step 7: 无提交 diff 检查点**

Run: `git diff -- entry/src/main/ets/pages/AiRecognitionSettingsPage.ets entry/src/main/ets/pages/MinePage.ets entry/src/main/ets/services/ai/AiConnectionTestService.ets entry/src/main/resources/base/profile`

Expected: saved Key is never loaded into page state, debug token code is unchanged, route registration is complete；不要提交。

## Task 12: 将正式 PDF 入口接入 AI setup/progress 页面

**Files:**
- Create: `entry/src/main/ets/pages/PdfAiImportSetupPage.ets`
- Create: `entry/src/main/ets/pages/PdfAiImportProgressPage.ets`
- Modify: `entry/src/main/ets/pages/ImportBankPage.ets:118-235`
- Modify: `entry/src/main/resources/base/profile/main_pages.json`
- Modify: `entry/src/main/resources/base/profile/easy_go.json`
- Modify: `entry/src/test/PdfImportContracts.test.cjs`
- Modify: `entry/src/test/CloudCutoverContracts.test.cjs`
- Modify: `entry/src/test/AiImportContracts.test.cjs`

- [ ] **Step 1: 写正式入口零 Cloud/OCR 和页面注册失败合同**

Update/add these assertions:

```js
test('formal PDF selection enters only the client AI setup', () => {
  const source = fs.readFileSync('entry/src/main/ets/pages/ImportBankPage.ets', 'utf8')
  const selectPdf = extractMethod(source, 'private async selectPdf')
  assert.match(selectPdf, /PdfImportService\.selectPdf/)
  assert.match(selectPdf, /pages\/PdfAiImportSetupPage/)
  assert.doesNotMatch(selectPdf, /CloudPdfSelection|CloudImportService|PdfImportSetupPage/)
})

test('AI pages never call the old cloud import or OCR pipeline', () => {
  const setup = fs.readFileSync('entry/src/main/ets/pages/PdfAiImportSetupPage.ets', 'utf8')
  const progress = fs.readFileSync('entry/src/main/ets/pages/PdfAiImportProgressPage.ets', 'utf8')
  const combined = setup + progress
  assert.match(combined, /PdfAiImportCoordinator/)
  assert.doesNotMatch(combined,
    /CloudImportService|CloudImportApi|\/v1\/imports\/pdf|PaddleOCR|textRecognition/)
})
```

Change the old `CloudCutoverContracts` blanket client-network assertion so it permits imports from `services/ai/AiVisionTransport.ets` only; keep every prohibition against `OcrService`, CoreVision OCR, CloudImport calls from the AI pages, server worker changes, and silent fallback.

- [ ] **Step 2: 运行合同确认失败**

Run `PdfImportContracts`, `CloudCutoverContracts`, and `AiImportContracts`.

Expected: FAIL because the formal entry still selects/stages the Cloud flow and the AI pages do not exist.

- [ ] **Step 3: 用现有安全 PDF selector 替换手写 Cloud 暂存**

Replace `ImportBankPage.selectPdf()` with:

```ts
private async selectPdf(): Promise<void> {
  if (this.importing || this.pdfSelecting) return
  this.pdfSelecting = true
  this.errorMessage = ''
  try {
    const context: Context = getContext(this)
    const selection: PdfFileSelection | null = await PdfImportService.selectPdf(context)
    if (selection === null) return
    const state: PdfImportState = PdfImportState.shared()
    const previous: PdfFileSelection | null = state.getSelection()
    state.reset()
    state.setSelection(selection)
    if (previous !== null && previous.uri !== selection.uri) {
      await PdfImportService.removeTemporaryPdf(previous.uri)
    }
    await this.getUIContext().getRouter().pushUrl({ url: 'pages/PdfAiImportSetupPage' })
  } catch (err) {
    this.errorMessage = this.messageForPdfError(err)
  } finally {
    this.pdfSelecting = false
  }
}
```

Remove only the now-unused page-local Cloud staging helpers/imports. Keep JSON import and all unrelated UI unchanged.

- [ ] **Step 4: 实现 AI setup 页面**

Create `PdfAiImportSetupPage.ets` using the field layout and page-range validation builders from current `PdfImportSetupPage`, but no Cloud job methods. Its start method is:

```ts
private async startRecognition(): Promise<void> {
  if (this.pending) return
  const state: PdfImportState = PdfImportState.shared()
  const selection: PdfFileSelection | null = state.getSelection()
  if (selection === null) {
    this.errorMessage = 'PDF 选择已失效，请返回重新选择'
    return
  }
  const startPage: number = Number(this.startPageText)
  const endPage: number = Number(this.endPageText)
  const validation: PdfPageRangeValidation = PdfImportValidator.validatePageRange(
    startPage, endPage, selection.pageCount)
  if (!validation.valid || this.bankName.trim().length === 0 || this.subject.trim().length === 0) {
    this.errorMessage = validation.valid ? '请填写题库名和科目' : validation.message
    return
  }
  this.pending = true
  try {
    const context: Context = getContext(this)
    const account: AccountSessionState = await AccountSessionService.state(context)
    const config: AiProviderConfig | null = await AiProviderConfigStore.load(context)
    if (!account.signedIn || account.userId.length === 0) {
      this.errorMessage = '请先登录华为账号'
      return
    }
    if (config === null) {
      this.errorMessage = '请先配置 AI Provider 和模型'
      return
    }
    if (!await AiCredentialStore.hasCredential(context)) {
      this.errorMessage = AiImportErrorMessages.forCode(AiImportErrorCode.MISSING_API_KEY)
      return
    }
    state.setSettings(new PdfImportSettings(
      this.bankName.trim(), this.subject.trim(), startPage, endPage))
    await this.getUIContext().getRouter().pushUrl({ url: 'pages/PdfAiImportProgressPage' })
  } catch (err) {
    this.errorMessage = err instanceof AiImportError ?
      AiImportErrorMessages.forCode(err.code) : 'AI 导入配置读取失败'
  } finally {
    this.pending = false
  }
}
```

Import `AccountSessionState`, `AiImportError`, `AiImportErrorCode`, and `AiImportErrorMessages`. Show read-only `AI 视觉识别（推荐）`, Provider label, Model, selected pages, and a link to `AiRecognitionSettingsPage`. There is no OCR radio option and no arbitrary exception text is rendered.

- [ ] **Step 5: 实现 AI progress 生命周期**

Create `PdfAiImportProgressPage.ets` with one coordinator instance and one start guard:

```ts
private coordinator: PdfAiImportCoordinator = PdfAiImportCoordinator.createDefault()
private started: boolean = false
@State currentPage: number = 0
@State totalPages: number = 0
@State processedPages: number = 0
@State questionCount: number = 0
@State statusText: string = '准备识别'
@State errorMessage: string = ''
@State cancelled: boolean = false

aboutToAppear(): void {
  if (!this.started) {
    this.started = true
    this.startImport()
  }
}

private async startImport(): Promise<void> {
  const context: Context = getContext(this)
  const state: PdfImportState = PdfImportState.shared()
  const selection: PdfFileSelection | null = state.getSelection()
  const settings: PdfImportSettings | null = state.getSettings()
  const config: AiProviderConfig | null = await AiProviderConfigStore.load(context)
  const account = await AccountSessionService.state(context)
  if (selection === null || settings === null || config === null ||
    !account.signedIn || account.userId.length === 0) {
    this.errorMessage = 'AI 导入配置已失效，请返回重新设置'
    return
  }
  const sessionId: string = util.generateRandomUUID()
  const request: PdfAiImportRequest = new PdfAiImportRequest(
    sessionId, account.userId, selection.uri, settings, config)
  try {
    await this.coordinator.run(context, request,
      (current: number, total: number, processed: number, count: number, stage: string): void => {
        this.currentPage = current
        this.totalPages = total
        this.processedPages = processed
        this.questionCount = count
        this.statusText = stage
      })
    state.setReviewSessionId(sessionId)
    await this.getUIContext().getRouter().replaceUrl({ url: 'pages/PdfImportReviewPage' })
  } catch (err) {
    if (this.cancelled || (err instanceof AiImportError && err.code === AiImportErrorCode.CANCELLED)) {
      try {
        await this.coordinator.discard(context, request)
        state.reset()
        await this.getUIContext().getRouter().replaceUrl({ url: 'pages/ImportBankPage' })
      } catch {
        this.errorMessage = '识别已取消，但临时文件清理失败，请重试'
      }
      return
    }
    this.errorMessage = err instanceof AiImportError ?
      AiImportErrorMessages.forCode(err.code) : 'AI 识别失败'
  }
}

private cancelImport(): void {
  if (this.cancelled) return
  this.cancelled = true
  this.coordinator.cancel()
  this.statusText = '正在取消'
}
```

Import `AiImportError`, `AiImportErrorCode`, and `AiImportErrorMessages`. Render progress as `processedPages / totalPages`, current page, question count, status text, non-secret local error, and one Cancel button. Do not auto-retry. The catch branch above is the only cancellation cleanup path; it removes session-owned image cache and the staged PDF before returning to the import page. Page-level failures remain inside the completed review session and never enter this fatal catch.

- [ ] **Step 6: 注册 setup/progress 页面并加入 EasyGo 全屏列表**

Add exactly these entries:

```json
"pages/AiRecognitionSettingsPage",
"pages/PdfAiImportSetupPage",
"pages/PdfAiImportProgressPage"
```

Keep all old page registrations to preserve code-level rollback, but no formal entry may route to them.

- [ ] **Step 7: 运行入口合同、ArkTS 检查、Hypium 和 debug build**

Run the three CJS contract files, targeted ArkTS check for both new pages and `ImportBankPage`, entry Hypium, then the debug build command from Task 11.

Expected: all PASS；formal UI contains only AI recognition；old pages still compile but are unreachable from the import entry.

- [ ] **Step 8: 无提交 diff 检查点**

Run: `git diff -- entry/src/main/ets/pages/ImportBankPage.ets entry/src/main/ets/pages/PdfAiImportSetupPage.ets entry/src/main/ets/pages/PdfAiImportProgressPage.ets entry/src/main/resources/base/profile entry/src/test`

Expected: no manual `cloud_import_pdf_` staging remains in the formal entry; `PdfImportService` owns the selected PDF; no AI page contains an OCR/Cloud import call；不要提交。

## Task 13: 锁定六题回放、无回退和无泄密合同

**Files:**
- Modify: `entry/src/test/AiImportLocalUnit.test.ets`
- Modify: `entry/src/test/AiImportContracts.test.cjs`
- Modify: `entry/src/test/AiImportSecurityContracts.test.cjs`
- Modify: `entry/src/test/CloudCutoverContracts.test.cjs`

- [ ] **Step 1: 添加例 1.1–例 1.6 的确定性 parser 回放**

Append this helper, fixture and test to `AiImportLocalUnit.test.ets`. The fixture is an already captured assistant `content` string, so it is deterministic and never contacts a Provider:

```ts
const SIX_QUESTION_RESPONSE: string =
  '{"questions":[' +
  '{"label":"例1.1","type":"short_answer","question":"求函数的定义域",' +
  '"options":null,"answer":null,"analysis":null,' +
  '"bbox":{"x1":40,"y1":35,"x2":960,"y2":165}},' +
  '{"label":"例1.2","type":"short_answer","question":"化简 $\\\\sqrt{x^2}$",' +
  '"options":null,"answer":null,"analysis":null,' +
  '"bbox":{"x1":40,"y1":170,"x2":960,"y2":300}},' +
  '{"label":"例1.3","type":"short_answer","question":"求 $f^{-1}(x)$",' +
  '"options":null,"answer":null,"analysis":null,' +
  '"bbox":{"x1":40,"y1":305,"x2":960,"y2":435}},' +
  '{"label":"例1.4","type":"short_answer","question":"讨论 $y=\\\\varphi(x)$ 的性质",' +
  '"options":null,"answer":null,"analysis":null,' +
  '"bbox":{"x1":40,"y1":440,"x2":960,"y2":570}},' +
  '{"label":"例1.5","type":"short_answer","question":"比较 ' +
  '$$f(x)=\\\\begin{cases}x, & x\\\\ge 0 \\\\\\\\ -x, & x<0\\\\end{cases}$$ 与 ' +
  '$$g(x)=\\\\begin{cases}1, & x>0 \\\\\\\\ 0, & x\\\\le 0\\\\end{cases}$$",' +
  '"options":null,"answer":null,"analysis":null,' +
  '"bbox":{"x1":40,"y1":575,"x2":960,"y2":790}},' +
  '{"label":"例1.6","type":"short_answer","question":"求 ' +
  '$$\\\\frac{x}{1+x^2}$$ 的值域","options":null,"answer":null,"analysis":null,' +
  '"bbox":{"x1":40,"y1":795,"x2":960,"y2":970}}]}'

describe('sixQuestionAcceptanceReplay', () => {
  it('preserves all six questions and the required math tokens in visual order', 0, () => {
    const values: Array<AiQuestionDraft> = AiQuestionResponseParser.parse(SIX_QUESTION_RESPONSE, 1)
    expect(values.length).assertEqual(6)
    const labels: Array<string> = values.map((value: AiQuestionDraft): string => value.label)
    expect(labels.join('|')).assertEqual('例1.1|例1.2|例1.3|例1.4|例1.5|例1.6')
    expect(values[1].question.indexOf('\\sqrt') >= 0).assertTrue()
    expect(values[2].question.indexOf('$f^{-1}(x)$') >= 0).assertTrue()
    expect(values[3].question.indexOf('\\varphi') >= 0).assertTrue()
    expect(values[3].question.indexOf('\\begin{cases}') < 0).assertTrue()
    expect(countToken(values[4].question, '\\begin{cases}')).assertEqual(2)
    expect(countToken(values[4].question, '\\end{cases}')).assertEqual(2)
    expect(values[4].question.indexOf('∫2−x') < 0).assertTrue()
    expect(values[5].question.indexOf('\\frac{x}{1+x^2}') >= 0).assertTrue()
  })
})
```

Reuse the Task 4 `AiQuestionDraft` import and `countToken()` helper; do not weaken the assertions or normalize the expected LaTeX.

- [ ] **Step 2: 添加正式入口、日志和 Authorization 边界合同**

Append this recursive source helper and contract to `AiImportSecurityContracts.test.cjs`:

```js
function sourceFiles(root) {
  const values = []
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const path = `${root}/${entry.name}`
    if (entry.isDirectory()) values.push(...sourceFiles(path))
    else if (/\.(?:ets|ts)$/.test(entry.name)) values.push(path)
  }
  return values.sort()
}

test('AI modules have no logging, OCR fallback, or business import endpoint', () => {
  const paths = sourceFiles('entry/src/main/ets/services/ai')
  const sources = paths.map((path) => read(path))
  const combined = sources.join('\n')
  assert.doesNotMatch(combined, /\b(?:console|hilog)\s*\./)
  assert.doesNotMatch(combined,
    /CloudImportService|CloudImportApi|PaddleOCR|OcrService|CoreVision|textRecognition|\/v1\/imports\/pdf/)
  const authorizationOwners = paths.filter((path, index) => sources[index].includes('Authorization'))
  assert.deepEqual(authorizationOwners,
    ['entry/src/main/ets/services/ai/AiVisionTransport.ets'])
})

test('sync writer cannot see provider configuration, credentials, PDF, or image bytes', () => {
  const repository = read('entry/src/main/ets/services/CloudQuestionRepository.ets')
  const save = read('entry/src/main/ets/services/ai/AiImportSaveService.ets')
  assert.doesNotMatch(repository,
    /AiProviderConfig|AiCredential|Authorization|api[_ -]?key|baseUrl|pdfPath|imageBytes/i)
  assert.doesNotMatch(save, /Authorization|AiCredentialStore|AiVisionTransport/)
  assert.match(repository, /\/v1\/sync\/push/)
})
```

In `PdfImportContracts.test.cjs` and `CloudCutoverContracts.test.cjs`, keep the Task 12 formal-entry assertions and add a negative assertion for `fallback`, `PaddleOCR`, `OcrService`, `CloudImportService`, and `/v1/imports/pdf` inside the extracted `selectPdf`, setup, progress, coordinator, and AI adapter sources. The old OCR/Cloud files may remain in the repository for rollback, so never scan the entire repository with this prohibition.

- [ ] **Step 3: 锁定图片、bbox、保存和测试替身合同**

Append these assertions to `AiImportContracts.test.cjs`:

```js
test('AI review keeps an image even when bbox is unusable', () => {
  const parser = read('entry/src/main/ets/services/ai/AiQuestionResponseParser.ets')
  const coordinator = read('entry/src/main/ets/services/ai/PdfAiImportCoordinator.ets')
  const review = read('entry/src/main/ets/pages/PdfImportReviewPage.ets')
  assert.match(parser, /bboxUsable/)
  assert.match(coordinator, /evidencePath/)
  assert.match(coordinator, /new PdfReviewImage/)
  assert.match(review, /file:\/\//)
})

test('automated tests use fakes and cannot call an external provider', () => {
  const unit = read('entry/src/test/AiImportLocalUnit.test.ets')
  assert.match(unit, /implements PdfPageImageEncoderPort/)
  assert.match(unit, /implements AiProviderAdapter/)
  assert.match(unit, /FakeConnectionTransport/)
  assert.doesNotMatch(unit, /api\.openai\.com|Authorization|AiConnectionTestService\.test/)
})
```

Also keep explicit assertions that `DeviceImageStore.saveBatch()` uses one `IMMEDIATE` transaction, `CloudQuestionRepository.createBankWithIds()` preserves supplied entity UUIDs, and the sync payload contains text fields only. These assertions belong in the existing `CloudCacheContracts.test.cjs`; do not duplicate the production implementation in a test.

- [ ] **Step 4: 运行六题回放和安全合同**

Run:

```powershell
node --test entry/src/test/AiImportContracts.test.cjs `
  entry/src/test/AiImportSecurityContracts.test.cjs `
  entry/src/test/PdfImportContracts.test.cjs `
  entry/src/test/CloudCutoverContracts.test.cjs `
  entry/src/test/CloudCacheContracts.test.cjs
& 'D:/Program Files/Huawei/DevEco Studio/tools/node/node.exe' `
  'D:/Program Files/Huawei/DevEco Studio/tools/hvigor/bin/hvigorw.js' test `
  --mode module -p module=entry@default
```

Expected: all CJS and Hypium tests PASS；six-question replay makes zero network calls；the production transport remains the sole owner of `Authorization`。

- [ ] **Step 5: 无提交 diff 检查点**

Run: `git diff -- entry/src/test entry/src/ohosTest/ets/test`

Expected: the six-question fixture contains no real API Key, account identifier, Provider response metadata, or user PDF bytes；不要提交。

## Task 14: 全量验证、真机验收和 A–J 交付报告

**Files:**
- Verify: all changed client files
- Verify unchanged baseline: `server/**`
- Verify user-supplied real PDF through the installed app
- Report: final response only; do not add secrets or a PDF to the repository

- [ ] **Step 1: 运行全部本地源码合同**

Run:

```powershell
Get-ChildItem 'entry/src/test' -Filter '*.test.cjs' | Sort-Object Name | ForEach-Object {
  node --test $_.FullName
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
```

Expected: every CJS contract PASS, including legacy PDF resource, Cloud adapter, KaTeX, EasyGo/Auth/HdsTabs and new AI security contracts.

- [ ] **Step 2: 运行全项目 ArkTS 检查、Hypium 和 debug HAP build**

Run:

```powershell
node 'C:/Users/32773/.agents/skills/harmonyos-dev-skill/scripts/arkts-check.cjs' --project .
& 'D:/Program Files/Huawei/DevEco Studio/tools/node/node.exe' `
  'D:/Program Files/Huawei/DevEco Studio/tools/hvigor/bin/hvigorw.js' test `
  --mode module -p module=entry@default
node 'C:/Users/32773/.agents/skills/harmonyos-dev-skill/scripts/deveco-build.cjs' `
  --project . --build-mode debug --module entry@default --json
```

Expected: ArkTS JSON `success: true`, Hypium PASS, and build JSON `success: true`. A build alone is not evidence that HUKS or a real Provider works on a device.

- [ ] **Step 3: 证明 server/worker 未因本功能回归**

Run the same commands used for the Task 0 baseline:

```powershell
npm test --prefix server -- --runInBand
python -m pytest server/worker/tests -q --basetemp .pytest-ai-import-final
```

Expected: results match or improve on the recorded baseline. Run `git diff --name-only -- server` and compare the output with Task 0's recorded dirty-worktree list; this feature must add no server/worker path. Do not edit unrelated pre-existing server/worker diffs to make this check green.

- [ ] **Step 4: 运行 API 24+ 设备 HUKS 套件**

Run: `hdc list targets`

If a target is present, select the `entry@ohosTest` configuration in DevEco Studio, run it on an API 24+ device/emulator, and capture the `AiCredentialStore` suite result. It must prove Unicode round trip, distinct nonces, nonce/ciphertext/tag tamper rejection, stale-envelope clearing after key deletion, non-exportability, and no plaintext in Preferences.

Expected: `PASS` when a suitable target is available. If no target is listed, record exactly `HUKS device test: NOT RUN (no API 24+ hdc target)`; never convert this to PASS from contracts or build output.

- [ ] **Step 5: 使用用户提供的真实六题 PDF 做显式收费 E2E**

This step requires all three external prerequisites: an API 24+ device, the real PDF containing 例 1.1–例 1.6, and a user-owned OpenAI-compatible multimodal credential/model. Do not invent a sample, copy a secret into a command, or start a paid request without the user explicitly initiating the import or test button in the app.

On the device:

1. Open `我的 → AI 识别设置`, choose Provider, enter Model and Key, optionally expand `高级设置`, save, then explicitly tap `测试连接`.
2. Return to import, select the real PDF, verify the next screen shows only `AI 视觉识别（推荐）`, set the page range, and start recognition.
3. While processing, verify one-page-at-a-time progress and Cancel; for the acceptance run, allow completion and enter the existing review page.
4. In review, count exactly six questions in this order: `例1.1`, `例1.2`, `例1.3`, `例1.4`, `例1.5`, `例1.6`; inspect the original-page/crop image and edit one harmless character, then undo it.
5. Verify 例 1.2 contains `\sqrt`, 例 1.3 contains `$f^{-1}(x)$`, 例 1.4 contains `\varphi` and no erroneous `cases`, 例 1.5 contains at least one complete `\begin{cases}`/`\end{cases}` pair and no `∫2−x`, and 例 1.6 contains `\frac{x}{1+x^2}`.
6. Save once, verify the bank appears locally and sync succeeds through the existing question sync path; reopen one question and verify its source image is still visible.

Expected: mark `Real PDF E2E: PASS` only if every assertion above was observed. Mark `FAIL` with the first mismatched assertion if the run completed but did not meet it. If any prerequisite is absent or no paid call was explicitly initiated, mark `NOT RUN` and name the missing prerequisite.

- [ ] **Step 6: 做最终泄密与范围审计**

Run:

```powershell
rg -n "console\.|hilog\.|Authorization|api[_ -]?key|credential|PaddleOCR|OcrService|CloudImportService|/v1/imports/pdf" `
  entry/src/main/ets/services/ai entry/src/main/ets/pages/PdfAiImportSetupPage.ets `
  entry/src/main/ets/pages/PdfAiImportProgressPage.ets entry/src/main/ets/services/review/AiPdfReviewAdapter.ets
git status --short
git diff --stat
```

Inspect every match: only `AiVisionTransport.ets` may construct the Authorization header; credential storage names and local non-secret user messages are allowed; no AI source may log them or call OCR/Cloud import. Confirm the final status contains no accidental PDF, Key file, captured response, HAP, signing material, server/worker feature change, or generated fixture with user content.

- [ ] **Step 7: 输出固定 A–J 报告，不提交**

Use this exact report skeleton and fill every evidence line with the command/result or `NOT RUN` reason from the preceding steps:

```markdown
## A. Architecture
- Client-only page render → provider adapter → HTTPS transport → strict parser → dual-source review adapter → existing sync.

## B. Modified Files
- Added: ...
- Modified: ...
- Preserved user worktree changes: ...

## C. API Key security
- HUKS AES-256-GCM, non-exportable alias, encrypted Preferences envelope, backup exclusion: PASS/FAIL.
- Plaintext lifetime and buffer clearing: ...

## D. Provider request format
- OpenAI-compatible `POST <https-base>/chat/completions`, Bearer header, text + JPEG data URL, no redirects: PASS/FAIL.

## E. AI response schema
- Strict `questions[]`, type, text/options/answer/analysis, normalized bbox, fenced-JSON compatibility and LaTeX checks: PASS/FAIL.

## F. Error handling
- HTTPS/config/auth/rate-limit/timeout/size/content-type/JSON/LaTeX/cancel/retry messages and no OCR fallback: PASS/FAIL.

## G. Tests
- CJS contracts: ...
- ArkTS check: ...
- Hypium: ...
- Debug build: ...
- Server/worker regression: ...
- HUKS device tests: ...

## H. Real PDF E2E
- PASS / FAIL / NOT RUN: ...
- Six-question and formula evidence: ...

## I. Security confirmation
- Confirmed/Not confirmed: API Key was transmitted only to the user-configured HTTPS AI Provider for the explicit request, and was not uploaded to the business server, logged, synchronized, or stored in plaintext; evidence: ...

## J. Git confirmation
- Confirmed: no commit, no push, and no PR were created.
```

Finally run `git status --short` once more. Do not run `git add`, `git commit`, `git push`, `gh pr create`, or any equivalent command.
