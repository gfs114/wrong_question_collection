# AI 平台目录扩展实施计划（对齐 Cherry Studio 62 家）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 AI 识别设置从「OpenAI 官方 / 自定义」两项扩展为 61 家平台目录，选中平台自动填充 API 地址与推荐视觉模型芯片。

**Architecture:** 新增静态目录 `AiPlatformCatalog.ets`（61 条数据，三类接入能力 `direct`/`local_http`/`gateway`）；`AiProviderConfig.providerId` 由枚举改为字符串并保留旧值兼容；校验器新增「仅本机/私网 http」白名单；新增平台选择页 `AiPlatformPickerPage` 与回传单例 `AiPlatformSelectionState`；设置页改造为「平台行 + 只读地址 + 模型芯片」，保留原 API Key/HUKS/保存/测试流程不变。

**Tech Stack:** HarmonyOS ArkTS（ArkUI 声明式 UI、`@ohos.url`、Preferences）、Node.js CJS 合同测试（`node --test`）、ArkTS 静态检查脚本。

**数据来源：** 61 家目录的 id / 名称 / 分类 / 接入类型 / 默认地址 / 视觉模型 / 备注 / 出处，全部来自 `docs/superpowers/specs/2026-09-09-ai-platform-catalog-design.md` 附录 A.1–A.3（每行均有官方文档取证）。

**仓库约束（必须遵守）：** 不 `git add`、不 commit、不 push、不建 PR；保留用户既有脏工作区；不得修改 `server/`。

---

## 文件结构

| 文件 | 职责 |
|---|---|
| `entry/src/main/ets/models/ai/AiPlatformCatalog.ets` | 新增：平台枚举、数据类、61 条目录数据、`all/find/search/byCategory/count` |
| `entry/src/main/ets/utils/AiPlatformSelectionState.ets` | 新增：选择页 → 设置页的一次性回传单例 |
| `entry/src/main/ets/pages/AiPlatformPickerPage.ets` | 新增：搜索 + 分类筛选 + 分组列表 + 平台标记 |
| `entry/src/main/ets/models/ai/AiProviderConfig.ets` | 修改：`AiProviderId` 枚举→字符串常量、`providerId` 类型、本机 http 白名单 |
| `entry/src/main/ets/services/ai/AiProviderConfigStore.ets` | 修改：保留持久化的平台 id，不再折叠为 CUSTOM |
| `entry/src/main/ets/pages/AiRecognitionSettingsPage.ets` | 修改：平台行、地址自动填、模型芯片、风险/网关提示 |
| `entry/src/main/resources/base/profile/main_pages.json` | 修改：注册 `pages/AiPlatformPickerPage` |
| `entry/src/main/resources/base/profile/easy_go.json` | 修改：`fullScreenPages` 增加该页 |
| `entry/src/test/AiImportLocalUnit.test.ets` | 修改：目录/校验器/迁移单测 |
| `entry/src/test/AiImportContracts.test.cjs` | 修改：目录合同、校验器合同、设置页/选择页 UI 合同 |
| `entry/src/test/Task9ResourceContracts.test.cjs` | 修改：`main_pages.json` 期望路由 |

---

## Task 1: 平台目录数据与查询

> **实施记录（已完成 2026-09-09）：** 已交付 `AiPlatformCatalog.ets`（61 条：direct 42 / local_http 5 / gateway 14），ArkTS `0/0`，全量 CJS 回到 `268/267/1`（唯一失败为已知 server 脏树基线）。落地时相对下方代码有三处**有意收紧**，后续任务按收紧后的版本理解：
> 1. 分类枚举成员为 `AiPlatformCategory.AGGREGATOR = 'gateway'`（避免与 `AiPlatformAccess.GATEWAY` 撞名）；
> 2. `all()`/`search('')` 返回 `PLATFORMS.slice()`，`AiPlatform` 构造器内 `this.models = models.slice()`（防调用方污染全局常量）；
> 3. `search()` 内 id 比较用 `platform.id.toLowerCase()`。
>
> 单测额外覆盖：LOCAL_HTTP 主机白名单、DIRECT 禁 `#`/`@`、空 `models` 的 note 契约（仅 direct/local_http）、`count()` 一致性、`id` 小写、`docsUrl` 非空、「不支持题目识别」仅限 longcat/baichuan/sophnet。
> **注意**：`.ets` 测试内不得出现真实厂商 URL 字面量（既有安全合同要求测试文件只用保留测试域名）；逐条地址精确校验放到后续 CJS 目录合同。

**Files:**
- Create: `entry/src/main/ets/models/ai/AiPlatformCatalog.ets`
- Test: `entry/src/test/AiImportLocalUnit.test.ets`（追加 describe）

- [ ] **Step 1: 写失败测试**

在 `entry/src/test/AiImportLocalUnit.test.ets` 顶部 import 区加入：

```ts
import {
  AiPlatform, AiPlatformAccess, AiPlatformCatalog, AiPlatformCategory
} from '../main/ets/models/ai/AiPlatformCatalog'
```

在文件末尾追加：

```ts
describe('aiPlatformCatalog', () => {
  it('ships sixty one unique platforms with usable access classes', 0, () => {
    const platforms: Array<AiPlatform> = AiPlatformCatalog.all()
    expect(platforms.length).assertEqual(61)
    const ids: Set<string> = new Set<string>()
    for (let index: number = 0; index < platforms.length; index++) {
      const platform: AiPlatform = platforms[index]
      expect(platform.id.length > 0).assertTrue()
      expect(platform.nameZh.length > 0).assertTrue()
      expect(ids.has(platform.id)).assertFalse()
      ids.add(platform.id)
      if (platform.access === AiPlatformAccess.DIRECT) {
        expect(platform.baseUrl.startsWith('https://')).assertTrue()
        expect(platform.baseUrl.indexOf('?') < 0).assertTrue()
      } else if (platform.access === AiPlatformAccess.LOCAL_HTTP) {
        expect(platform.baseUrl.startsWith('http://')).assertTrue()
      } else {
        expect(platform.baseUrl.length).assertEqual(0)
        expect(platform.note.length > 0).assertTrue()
      }
      if (platform.models.length > 0) {
        let visionCount: number = 0
        for (let modelIndex: number = 0; modelIndex < platform.models.length; modelIndex++) {
          if (platform.models[modelIndex].supportsVision) visionCount++
        }
        expect(visionCount > 0).assertTrue()
      }
    }
  })

  it('finds, searches and filters platforms', 0, () => {
    const deepseek: AiPlatform | null = AiPlatformCatalog.find('deepseek')
    expect(deepseek === null).assertFalse()
    if (deepseek !== null) {
      expect(deepseek.access).assertEqual(AiPlatformAccess.DIRECT)
      expect(deepseek.baseUrl.startsWith('https://')).assertTrue()
    }
    expect(AiPlatformCatalog.find('missing-platform')).assertEqual(null)
    expect(AiPlatformCatalog.search('DEEPSEEK').length).assertEqual(1)
    expect(AiPlatformCatalog.search('月之暗面').length).assertEqual(1)
    expect(AiPlatformCatalog.search('').length).assertEqual(61)
    expect(AiPlatformCatalog.byCategory(AiPlatformCategory.LOCAL).length).assertEqual(5)
  })
})
```

- [ ] **Step 2: 运行确认失败**

Run: `node 'C:/Users/32773/.agents/skills/harmonyos-dev-skill/scripts/arkts-check.cjs' --project .`
Expected: 报 `AiPlatformCatalog` 模块不存在（此时 Hypium 无法运行，静态检查即可确认缺失）。

- [ ] **Step 3: 实现目录文件**

创建 `entry/src/main/ets/models/ai/AiPlatformCatalog.ets`：

```ts
export enum AiPlatformCategory {
  DIRECT = 'direct',
  INFERENCE = 'inference',
  AGGREGATOR = 'gateway',
  CLOUD = 'cloud',
  LOCAL = 'local'
}

export enum AiPlatformAccess {
  DIRECT = 'direct',
  LOCAL_HTTP = 'local_http',
  GATEWAY = 'gateway'
}

export class AiPlatformModel {
  readonly id: string
  readonly label: string
  readonly supportsVision: boolean

  constructor(id: string, label: string, supportsVision: boolean) {
    this.id = id
    this.label = label
    this.supportsVision = supportsVision
  }
}

export class AiPlatform {
  readonly id: string
  readonly nameZh: string
  readonly nameEn: string
  readonly category: AiPlatformCategory
  readonly access: AiPlatformAccess
  readonly baseUrl: string
  readonly models: Array<AiPlatformModel>
  readonly note: string
  readonly docsUrl: string

  constructor(id: string, nameZh: string, nameEn: string, category: AiPlatformCategory,
    access: AiPlatformAccess, baseUrl: string, models: Array<AiPlatformModel>,
    note: string, docsUrl: string) {
    this.id = id
    this.nameZh = nameZh
    this.nameEn = nameEn
    this.category = category
    this.access = access
    this.baseUrl = baseUrl
    this.models = models
    this.note = note
    this.docsUrl = docsUrl
  }
}

function vision(id: string, label: string): AiPlatformModel {
  return new AiPlatformModel(id, label, true)
}

const PLATFORMS: Array<AiPlatform> = [
  new AiPlatform('openai', 'OpenAI', 'OpenAI', AiPlatformCategory.DIRECT,
    AiPlatformAccess.DIRECT, 'https://api.openai.com/v1',
    [vision('gpt-6-astra', 'GPT-6 Astra'), vision('gpt-5.6-sol', 'GPT-5.6 Sol')],
    '', 'https://developers.openai.com/api/reference/overview'),
  new AiPlatform('deepseek', '深度求索 DeepSeek', 'DeepSeek', AiPlatformCategory.DIRECT,
    AiPlatformAccess.DIRECT, 'https://api.deepseek.com',
    [vision('deepseek-v4-flash-vision-exp', 'DeepSeek V4 Flash Vision')],
    '每图计费上限 384 tokens，整页小字建议先裁题', 'https://api-docs.deepseek.com/guides/vision'),
  new AiPlatform('siliconflow', '硅基流动 SiliconFlow', 'SiliconFlow', AiPlatformCategory.AGGREGATOR,
    AiPlatformAccess.DIRECT, 'https://api.siliconflow.cn/v1',
    [vision('Qwen/Qwen3-VL-32B-Instruct', 'Qwen3-VL 32B'),
      vision('deepseek-ai/DeepSeek-OCR', 'DeepSeek OCR')],
    '视觉模型可能不支持 json_object', 'https://docs.siliconflow.cn/cn/userguide/capabilities/multimodal-vision'),
  new AiPlatform('cherryin', 'CherryIN', 'CherryIN', AiPlatformCategory.AGGREGATOR,
    AiPlatformAccess.DIRECT, 'https://open.cherryin.net/v1', [],
    '官方未列出视觉模型清单；模型名必须带厂商前缀', 'https://docs.cherryin.ai/zh/docs/newapi/openai-compatible-usage/'),
  new AiPlatform('ollama', 'Ollama', 'Ollama', AiPlatformCategory.LOCAL,
    AiPlatformAccess.LOCAL_HTTP, 'http://localhost:11434/v1',
    [vision('qwen3-vl', 'Qwen3-VL'), vision('gemma4', 'Gemma 4')],
    '本机服务默认无鉴权，API Key 可填任意占位符（如 ollama）', 'https://docs.ollama.com/api/openai-compatibility'),
  new AiPlatform('new-api', 'New API（自建网关）', 'New API', AiPlatformCategory.LOCAL,
    AiPlatformAccess.LOCAL_HTTP, 'http://localhost:3000/v1', [],
    '自建网关：地址与可用模型取决于你的部署，请按需修改', 'https://github.com/QuantumNous/new-api'),
  new AiPlatform('azure-openai', 'Azure OpenAI', 'Azure OpenAI', AiPlatformCategory.CLOUD,
    AiPlatformAccess.GATEWAY, '',
    [vision('gpt-5.6-sol', 'GPT-5.6 Sol'), vision('gpt-4.1', 'GPT-4.1')],
    '需替换为你自己的资源名（https://<资源名>.openai.azure.com/openai/v1），请用自定义填写',
    'https://learn.microsoft.com/en-us/azure/foundry/openai/api-version-lifecycle'),
  new AiPlatform('yi-01ai', '零一万物 01.AI', '01.AI', AiPlatformCategory.DIRECT,
    AiPlatformAccess.GATEWAY, [], [],
    '平台正在停服（2026-08 公告，接口实测 410），可改用百炼托管的 Yi 系列',
    'https://platform.lingyiwanwu.com/docs'),
  new AiPlatform('longcat', 'LongCat 龙猫', 'LongCat', AiPlatformCategory.AGGREGATOR,
    AiPlatformAccess.DIRECT, 'https://api.longcat.chat/openai/v1',
    new Array<AiPlatformModel>(),
    '不支持题目识别：官方原文「仅支持文本输入」', 'https://longcat.chat/platform/docs/')
]

export class AiPlatformCatalog {
  static all(): Array<AiPlatform> {
    return PLATFORMS
  }

  static count(): number {
    return PLATFORMS.length
  }

  static find(id: string): AiPlatform | null {
    const key: string = id.trim().toLowerCase()
    for (let index: number = 0; index < PLATFORMS.length; index++) {
      if (PLATFORMS[index].id === key) return PLATFORMS[index]
    }
    return null
  }

  static search(keyword: string): Array<AiPlatform> {
    const needle: string = keyword.trim().toLowerCase()
    if (needle.length === 0) return PLATFORMS
    const matches: Array<AiPlatform> = new Array<AiPlatform>()
    for (let index: number = 0; index < PLATFORMS.length; index++) {
      const platform: AiPlatform = PLATFORMS[index]
      if (platform.id.indexOf(needle) >= 0 ||
        platform.nameZh.toLowerCase().indexOf(needle) >= 0 ||
        platform.nameEn.toLowerCase().indexOf(needle) >= 0) {
        matches.push(platform)
      }
    }
    return matches
  }

  static byCategory(category: AiPlatformCategory): Array<AiPlatform> {
    const matches: Array<AiPlatform> = new Array<AiPlatform>()
    for (let index: number = 0; index < PLATFORMS.length; index++) {
      if (PLATFORMS[index].category === category) matches.push(PLATFORMS[index])
    }
    return matches
  }
}
```

- [ ] **Step 4: 补齐 61 条数据**

按 `docs/superpowers/specs/2026-09-09-ai-platform-catalog-design.md` 附录 A.1–A.3 逐行转写剩余条目，规则：

- A.1 行 → `AiPlatformAccess.DIRECT`，`baseUrl` 用「默认地址」列，视觉模型列拆成 `vision(id, label)`；该列写「**无**」或「未查证」时 `models` 传 `new Array<AiPlatformModel>()`，并把对应说明写进 `note`；「备注」列非空则写入 `note`。
- A.2 行 → `AiPlatformAccess.LOCAL_HTTP`，分类 `AiPlatformCategory.LOCAL`。
- A.3 行 → `AiPlatformAccess.GATEWAY`，`baseUrl` 传 `''`，原因列写入 `note`；该行若列了模型芯片则一并给出。
- 分类映射：模型原厂=`DIRECT`、推理平台=`INFERENCE`、聚合转发=`AGGREGATOR`、云平台=`CLOUD`、本地部署=`LOCAL`。
- 完成后 `PLATFORMS.length` 必须为 61，`byCategory(LOCAL)` 为 5。

- [ ] **Step 5: 运行静态检查**

Run: `node 'C:/Users/32773/.agents/skills/harmonyos-dev-skill/scripts/arkts-check.cjs' --project .`
Expected: `"success": true`，`errorCount: 0`，`warnCount: 0`。

- [ ] **Step 6: 无提交检查点**

Run: `git status --short`
Expected: 只有新增目录文件与测试文件变化；不执行 `git add`/`git commit`。

---

## Task 2: 配置模型与校验器（providerId 字符串化 + 本机 http 白名单）

**Files:**
- Modify: `entry/src/main/ets/models/ai/AiProviderConfig.ets`
- Modify: `entry/src/main/ets/pages/AiRecognitionSettingsPage.ets`（仅最小编译修复：`@State providerId: AiProviderId` → `@State providerId: string`、`private selectProvider(provider: AiProviderId)` → `provider: string`；整页改造在 Task 6）
- Test: `entry/src/test/AiImportLocalUnit.test.ets`、`entry/src/test/AiImportContracts.test.cjs`

- [ ] **Step 1: 写失败测试（ArkTS）**

在 `AiImportLocalUnit.test.ets` 的校验器 describe 内追加：

```ts
  it('accepts https and local http but rejects public http', 0, () => {
    const accepted: Array<string> = [
      'https://api.deepseek.com/v1',
      'http://localhost:11434/v1',
      'http://127.0.0.1:1234/v1',
      'http://192.168.1.9:8000/v1',
      'http://10.0.0.7/v1',
      'http://172.16.4.4/v1',
      'http://172.31.4.4/v1'
    ]
    for (let index: number = 0; index < accepted.length; index++) {
      const config: AiProviderConfig = AiProviderConfigValidator.normalize(
        new AiProviderConfig(AiProviderId.CUSTOM, 'vision-model', accepted[index]))
      expect(config.baseUrl.length > 0).assertTrue()
    }
    const rejected: Array<string> = [
      'http://ai.example.com/v1',
      'http://172.32.4.4/v1',
      'http://172.15.4.4/v1',
      'http://11.0.0.1/v1'
    ]
    for (let index: number = 0; index < rejected.length; index++) {
      let threw: boolean = false
      try {
        AiProviderConfigValidator.normalize(
          new AiProviderConfig(AiProviderId.CUSTOM, 'vision-model', rejected[index]))
      } catch {
        threw = true
      }
      expect(threw).assertTrue()
    }
  })

  it('keeps catalog platform ids through normalization', 0, () => {
    const config: AiProviderConfig = AiProviderConfigValidator.normalize(
      new AiProviderConfig('deepseek', 'deepseek-v4-flash-vision-exp', 'https://api.deepseek.com'))
    expect(config.providerId).assertEqual('deepseek')
    expect(config.supportsStructuredOutput).assertFalse()
    const custom: AiProviderConfig = AiProviderConfigValidator.normalize(
      new AiProviderConfig(AiProviderId.CUSTOM, 'model', 'https://custom.invalid/v1'))
    expect(custom.providerId).assertEqual('openai_compatible')
  })
```

- [ ] **Step 2: 运行确认失败**

Run: `node 'C:/Users/32773/.agents/skills/harmonyos-dev-skill/scripts/arkts-check.cjs' --project .`
Expected: 类型错误（`providerId` 目前是枚举，无法传 `'deepseek'`）。

- [ ] **Step 3: 实现**

`AiProviderConfig.ets` 中把枚举替换为字符串常量类，并修改 `providerId` 类型：

```ts
export class AiProviderId {
  static readonly OPENAI: string = 'openai'
  static readonly CUSTOM: string = 'openai_compatible'
}
```

```ts
export class AiProviderConfig {
  providerId: string
  model: string
  baseUrl: string
  supportsStructuredOutput: boolean

  constructor(providerId: string, model: string, baseUrl: string,
    supportsStructuredOutput: boolean = false) {
    this.providerId = providerId
    this.model = model
    this.baseUrl = baseUrl
    this.supportsStructuredOutput = supportsStructuredOutput
  }
}
```

`AiProviderConfigValidator` 增加私有白名单方法并在 `normalize` 中使用：

```ts
  private static isLocalOrPrivateHost(hostname: string): boolean {
    const host: string = hostname.trim().toLowerCase()
      .replace('[', '').replace(']', '')
    if (host === 'localhost' || host === '::1') return true
    if (host.startsWith('127.')) return true
    if (host.startsWith('10.')) return true
    if (host.startsWith('192.168.')) return true
    if (host.startsWith('172.')) {
      const parts: Array<string> = host.split('.')
      if (parts.length < 2) return false
      const second: number = Number.parseInt(parts[1], 10)
      return second >= 16 && second <= 31
    }
    return false
  }
```

`normalize` 内的协议判断替换为：

```ts
    const protocol: string = parsed.protocol.toLowerCase()
    const localHttp: boolean = protocol === 'http:' &&
      AiProviderConfigValidator.isLocalOrPrivateHost(parsed.hostname)
    if (protocol !== 'https:' && !localHttp) {
      throw new AiImportError(AiImportErrorCode.INVALID_BASE_URL)
    }
```

其余规则（userinfo/query/hash 非空、路径以 `/chat/completions` 结尾一律拒绝）保持不变；`supportsStructuredOutput` 仍由 `input.providerId === AiProviderId.OPENAI` 决定。

- [ ] **Step 4: 更新 CJS 合同**

`entry/src/test/AiImportContracts.test.cjs` 顶部增加一个合同（放在现有校验器合同之后）：

```js
test('provider validator accepts local http only for private hosts', () => {
  const runtime = providerValidatorRuntime()
  const accepted = [
    'https://api.example.com/v1',
    'http://localhost:11434/v1',
    'http://127.0.0.1:1234/v1',
    'http://192.168.0.20/v1',
    'http://10.1.2.3/v1',
    'http://172.16.0.1/v1',
    'http://172.31.255.254/v1'
  ]
  for (const baseUrl of accepted) {
    const config = new runtime.AiProviderConfig('openai_compatible', 'vision-model', baseUrl)
    assert.equal(runtime.AiProviderConfigValidator.normalize(config).baseUrl.startsWith('http'), true)
  }
  for (const baseUrl of ['http://api.example.com/v1', 'http://172.32.0.1/v1', 'http://172.15.0.1/v1']) {
    assert.throws(() => runtime.AiProviderConfigValidator.normalize(
      new runtime.AiProviderConfig('openai_compatible', 'vision-model', baseUrl)))
  }
  const platform = runtime.AiProviderConfigValidator.normalize(
    new runtime.AiProviderConfig('deepseek', 'deepseek-v4-flash-vision-exp', 'https://api.deepseek.com'))
  assert.equal(platform.providerId, 'deepseek')
  assert.equal(platform.supportsStructuredOutput, false)
})
```

并新增该 runtime 辅助函数（`stripEtsModule` 接收**相对路径**并返回剥掉 import/export 的源码，与文件内既有 `aiQuestionParserRuntime()` 写法一致）：

```js
function providerValidatorRuntime() {
  const source = stripEtsModule('entry/src/main/ets/models/ai/AiProviderConfig.ets')
  return vm.runInNewContext(stripTypeScriptTypes(source, { mode: 'transform' }) +
    '\n({ AiProviderConfig, AiProviderConfigValidator, AiProviderId, AiImportError, AiImportErrorCode })', {
    url: { URL: { parseURL: value => new URL(value) } }
  })
}
```

- [ ] **Step 5: 运行合同测试**

Run: `node --test entry/src/test/AiImportContracts.test.cjs`
Expected: 全部 PASS（新增用例通过）。

- [ ] **Step 6: 无提交检查点**

Run: `git diff --stat -- entry/src/main/ets/models/ai/AiProviderConfig.ets entry/src/test/AiImportContracts.test.cjs`
Expected: 仅这两个文件有改动；不提交。

---

## Task 3: 配置存储保留平台 id

**Files:**
- Modify: `entry/src/main/ets/services/ai/AiProviderConfigStore.ets`
- Test: `entry/src/test/AiImportContracts.test.cjs`

- [ ] **Step 1: 写失败测试（CJS）**

在 `AiImportContracts.test.cjs` 追加：

```js
test('provider config store keeps catalog platform ids and tolerates unknown ids', async () => {
  const source = read('entry/src/main/ets/services/ai/AiProviderConfigStore.ets')
  assert.doesNotMatch(source, /providerValue === AiProviderId\.OPENAI/, 'store must not collapse ids')
  assert.match(source, /const providerId: string = providerValue/)
})
```

- [ ] **Step 2: 运行确认失败**

Run: `node --test entry/src/test/AiImportContracts.test.cjs`
Expected: FAIL（当前源码仍含折叠逻辑）。

- [ ] **Step 3: 实现**

`AiProviderConfigStore.loadLocked()` 中把：

```ts
    const providerId: AiProviderId = providerValue === AiProviderId.OPENAI
      ? AiProviderId.OPENAI
      : AiProviderId.CUSTOM
```

替换为：

```ts
    const providerId: string = providerValue
```

并删除文件顶部 import 中不再使用的 `AiProviderId`。

- [ ] **Step 4: 运行合同测试**

Run: `node --test entry/src/test/AiImportContracts.test.cjs`
Expected: 全部 PASS。

- [ ] **Step 5: 无提交检查点**

Run: `git diff --stat -- entry/src/main/ets/services/ai/AiProviderConfigStore.ets`
Expected: 仅该文件改动；不提交。

---

## Task 4: 选择结果回传单例

**Files:**
- Create: `entry/src/main/ets/utils/AiPlatformSelectionState.ets`
- Test: `entry/src/test/AiImportLocalUnit.test.ets`

- [ ] **Step 1: 写失败测试（ArkTS）**

```ts
describe('aiPlatformSelectionState', () => {
  it('returns a pending selection exactly once', 0, () => {
    const state: AiPlatformSelectionState = AiPlatformSelectionState.shared()
    expect(state.take()).assertEqual('')
    state.select('deepseek')
    expect(state.peek()).assertEqual('deepseek')
    expect(state.take()).assertEqual('deepseek')
    expect(state.take()).assertEqual('')
    expect(AiPlatformSelectionState.shared() === state).assertTrue()
  })
})
```

- [ ] **Step 2: 运行确认失败**

Run: `node 'C:/Users/32773/.agents/skills/harmonyos-dev-skill/scripts/arkts-check.cjs' --project .`
Expected: 报 `AiPlatformSelectionState` 不存在。

- [ ] **Step 3: 实现**

创建 `entry/src/main/ets/utils/AiPlatformSelectionState.ets`：

```ts
export class AiPlatformSelectionState {
  private static instance: AiPlatformSelectionState | null = null
  private selectedId: string = ''

  private constructor() {
  }

  static shared(): AiPlatformSelectionState {
    if (AiPlatformSelectionState.instance === null) {
      AiPlatformSelectionState.instance = new AiPlatformSelectionState()
    }
    return AiPlatformSelectionState.instance
  }

  select(id: string): void {
    this.selectedId = id
  }

  peek(): string {
    return this.selectedId
  }

  take(): string {
    const value: string = this.selectedId
    this.selectedId = ''
    return value
  }
}
```

- [ ] **Step 4: 运行静态检查**

Run: `node 'C:/Users/32773/.agents/skills/harmonyos-dev-skill/scripts/arkts-check.cjs' --project .`
Expected: `success: true`，`0 errors / 0 warnings`。

---

## Task 5: 平台选择页与路由注册

**Files:**
- Create: `entry/src/main/ets/pages/AiPlatformPickerPage.ets`
- Modify: `entry/src/main/resources/base/profile/main_pages.json`、`entry/src/main/resources/base/profile/easy_go.json`
- Test: `entry/src/test/AiImportContracts.test.cjs`、`entry/src/test/Task9ResourceContracts.test.cjs`

- [ ] **Step 1: 更新路由合同测试**

`Task9ResourceContracts.test.cjs` 的 `expectedPages` 在 `'pages/Index'` 之后插入 `'pages/AiPlatformPickerPage'`，使数组与 `main_pages.json` 完全一致。

`AiImportContracts.test.cjs` 追加：

```js
test('platform picker page is registered once and reachable from settings', () => {
  const route = 'pages/AiPlatformPickerPage'
  const pages = JSON.parse(read('entry/src/main/resources/base/profile/main_pages.json')).src
  assert.equal(pages.filter(value => value === route).length, 1)
  const easy = JSON.parse(read('entry/src/main/resources/base/profile/easy_go.json'))
  assert.equal(easy.common.displayModeOptions.routerSplitOptions.fullScreenPages
    .filter(value => value === route).length, 1)
  const picker = read('entry/src/main/ets/pages/AiPlatformPickerPage.ets')
  assert.match(picker, /AiPlatformCatalog\.search/)
  assert.match(picker, /AiPlatformCatalog\.byCategory/)
  assert.match(picker, /AiPlatformSelectionState\.shared\(\)\.select/)
  assert.match(picker, /getRouter\(\)\.back\(\)/)
  assert.match(picker, /textOnly|本机|需自建网关/)
  const settings = read('entry/src/main/ets/pages/AiRecognitionSettingsPage.ets')
  assert.match(settings, /pages\/AiPlatformPickerPage/)
  assert.match(settings, /AiPlatformSelectionState\.shared\(\)\.take\(\)/)
})
```

- [ ] **Step 2: 运行确认失败**

Run: `node --test entry/src/test/AiImportContracts.test.cjs entry/src/test/Task9ResourceContracts.test.cjs`
Expected: FAIL（页面与路由尚不存在）。

- [ ] **Step 3: 注册路由**

`main_pages.json` 的 `src` 数组在 `"pages/Index"` 后加入 `"pages/AiPlatformPickerPage"`。

`easy_go.json` 的 `fullScreenPages` 数组在 `"pages/AiRecognitionSettingsPage"` 后加入 `"pages/AiPlatformPickerPage"`。

- [ ] **Step 4: 实现选择页**

创建 `entry/src/main/ets/pages/AiPlatformPickerPage.ets`：

```ts
import { router } from '@kit.ArkUI'
import { BODY_FONT_SIZE, CARD_RADIUS, CONTENT_MAX_WIDTH, PAGE_PADDING, themePalette } from '../constants/AppTheme'
import {
  AiPlatform, AiPlatformAccess, AiPlatformCatalog, AiPlatformCategory
} from '../models/ai/AiPlatformCatalog'
import { AppColors } from '../theme/AppColors'
import { AiPlatformSelectionState } from '../utils/AiPlatformSelectionState'
import { SafeAreaInsets, SafeAreaUtils } from '../utils/SafeAreaUtils'

class CategoryFilter {
  readonly key: string
  readonly label: string
  readonly category: AiPlatformCategory | null

  constructor(key: string, label: string, category: AiPlatformCategory | null) {
    this.key = key
    this.label = label
    this.category = category
  }
}

const FILTERS: Array<CategoryFilter> = [
  new CategoryFilter('all', '全部', null),
  new CategoryFilter('direct', '模型原厂', AiPlatformCategory.DIRECT),
  new CategoryFilter('inference', '推理平台', AiPlatformCategory.INFERENCE),
  new CategoryFilter('gateway', '聚合转发', AiPlatformCategory.AGGREGATOR),
  new CategoryFilter('cloud', '云平台', AiPlatformCategory.CLOUD),
  new CategoryFilter('local', '本地部署', AiPlatformCategory.LOCAL)
]

@Entry
@Component
struct AiPlatformPickerPage {
  @StorageProp('darkMode') darkMode: boolean = false
  @StorageProp('safeAreaInsets') safeAreaInsets: SafeAreaInsets = { top: 0, left: 0, right: 0, bottom: 0 }
  @State keyword: string = ''
  @State filterKey: string = 'all'

  private colors(): AppColors {
    return themePalette(this.darkMode)
  }

  private visiblePlatforms(): Array<AiPlatform> {
    const matched: Array<AiPlatform> = AiPlatformCatalog.search(this.keyword)
    let category: AiPlatformCategory | null = null
    for (let index: number = 0; index < FILTERS.length; index++) {
      if (FILTERS[index].key === this.filterKey) category = FILTERS[index].category
    }
    if (category === null) return matched
    const filtered: Array<AiPlatform> = new Array<AiPlatform>()
    for (let index: number = 0; index < matched.length; index++) {
      if (matched[index].category === category) filtered.push(matched[index])
    }
    return filtered
  }

  private tagFor(platform: AiPlatform): string {
    if (platform.access === AiPlatformAccess.GATEWAY) return '需自建网关'
    if (platform.access === AiPlatformAccess.LOCAL_HTTP) return '本机'
    if (platform.models.length === 0) return '未确认视觉模型'
    return '视觉'
  }

  private choose(platform: AiPlatform): void {
    AiPlatformSelectionState.shared().select(platform.id)
    router.back()
  }

  build() {
    Column() {
      Row({ space: 12 }) {
        Button('返回').onClick(() => { router.back() })
        Text('选择 AI 平台').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.colors().textPrimary)
      }.width('100%').padding(PAGE_PADDING)
      Column({ space: 12 }) {
        TextInput({ text: this.keyword, placeholder: '搜索平台名称，如 deepseek / 月之暗面' })
          .fontColor(this.colors().textPrimary).backgroundColor(this.colors().pageBackground)
          .onChange((value: string) => { this.keyword = value })
        Scroll() {
          Row({ space: 8 }) {
            ForEach(FILTERS, (item: CategoryFilter) => {
              Button(item.label)
                .backgroundColor(this.filterKey === item.key ? this.colors().brand : this.colors().pageBackground)
                .fontColor(this.filterKey === item.key ? Color.White : this.colors().textPrimary)
                .onClick(() => { this.filterKey = item.key })
            })
          }
        }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%')
        List({ space: 8 }) {
          ForEach(this.visiblePlatforms(), (platform: AiPlatform) => {
            ListItem() {
              Row({ space: 8 }) {
                Column({ space: 4 }) {
                  Text(platform.nameZh).fontSize(BODY_FONT_SIZE).fontColor(this.colors().textPrimary)
                  Text(platform.access === AiPlatformAccess.LOCAL_HTTP ? platform.baseUrl : platform.nameEn)
                    .fontSize(12).fontColor(this.colors().textCaption)
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                Text(this.tagFor(platform)).fontSize(12).fontColor(this.colors().brand)
              }.width('100%').padding(12)
              .backgroundColor(this.colors().cardBackground).borderRadius(CARD_RADIUS)
            }.onClick(() => { this.choose(platform) })
          }, (platform: AiPlatform) => platform.id)
        }.layoutWeight(1).width('100%').scrollBar(BarState.Off)
        if (this.visiblePlatforms().length === 0) {
          Text('没有匹配的平台，试试其它关键词').fontSize(13).fontColor(this.colors().textCaption)
        }
      }.layoutWeight(1).width('100%').constraintSize({ maxWidth: CONTENT_MAX_WIDTH }).padding(PAGE_PADDING)
    }.width('100%').height('100%').backgroundColor(this.colors().pageBackground)
    .padding({ top: SafeAreaUtils.top(this.safeAreaInsets), bottom: SafeAreaUtils.bottom(this.safeAreaInsets) })
  }
}
```

- [ ] **Step 5: 运行合同与静态检查**

Run: `node --test entry/src/test/AiImportContracts.test.cjs entry/src/test/Task9ResourceContracts.test.cjs`
Expected: 全部 PASS。

Run: `node 'C:/Users/32773/.agents/skills/harmonyos-dev-skill/scripts/arkts-check.cjs' --project .`
Expected: `0 errors / 0 warnings`。

---

## Task 6: 设置页改造（平台行 + 地址自动填 + 模型芯片）

> **执行约束（来自 Task 3 质量复审的硬性要求）：**
> 1. **不得把 `AiPlatformSelectionState.take()` 的空串赋给 `providerId`**——`onPageShow` 必须先判空返回（见下方代码的 `selectedId.length === 0` 守卫）。store 的空 id 读写不对称是既有行为：写 `provider_id=''` 会成功但随后 `load()` 返回 `null`，留下孤儿 model/baseUrl。
> 2. **未知/已移除的平台 id 一律走「目录查表 + 自定义兜底」展示**（`AiPlatformCatalog.find(id) === null → '自定义'`），**绝不把持久化字符串原样渲染到 UI**。
> 3. **不要把 providerId 校验加进 `AiProviderConfigValidator.normalize()`**——它跑在读路径（`AiProviderConfigStore:122`），加 id 校验会直接违反规格 §6.4「未知 id 不报错、不清空」。若将来要收紧，只能放在写路径（`save()`/UI）。

**Files:**
- Modify: `entry/src/main/ets/pages/AiRecognitionSettingsPage.ets`
- Test: `entry/src/test/AiImportContracts.test.cjs`

- [ ] **Step 1: 更新设置页合同**

`AiImportContracts.test.cjs` 首个测试的标签清单替换为：

```js
  for (const label of ['AI 视觉识别（推荐）', '平台', 'API 地址', '推荐视觉模型', 'API Key', 'Model',
    '保存设置', '清除 API Key', '测试连接', '已配置', '自定义',
    '测试连接会发送一张极小测试图片，可能产生极少量模型费用']) assert.ok(page.includes(label), label)
  assert.doesNotMatch(page, /OpenAI 官方|OpenAI-compatible 自定义/)
  assert.match(page, /AiPlatformCatalog\.find/)
  assert.match(page, /AiPlatformAccess\.LOCAL_HTTP/)
  assert.match(page, /必须重新输入 API Key|REPLACEMENT_KEY_REQUIRED/)
```

- [ ] **Step 2: 运行确认失败**

Run: `node --test entry/src/test/AiImportContracts.test.cjs`
Expected: FAIL（页面仍是两家按钮）。

- [ ] **Step 3: 实现设置页改造**

`AiRecognitionSettingsPage.ets` 变更要点（保留既有 API Key/HUKS/保存/测试流程与全部错误处理）：

```ts
import { AiPlatform, AiPlatformAccess, AiPlatformCatalog, AiPlatformModel } from '../models/ai/AiPlatformCatalog'
import { AiPlatformSelectionState } from '../utils/AiPlatformSelectionState'
```

状态新增：

```ts
  @State platformId: string = AiProviderId.CUSTOM
  @State platformLabel: string = '自定义'
  @State platformNote: string = ''
  @State platformModels: Array<AiPlatformModel> = new Array<AiPlatformModel>()
  @State urlEditable: boolean = false
```

`aboutToAppear()` 保持既有加载逻辑，并调用一次 `this.syncPlatformFromConfig()`；新增：

```ts
  onPageShow(): void {
    const selectedId: string = AiPlatformSelectionState.shared().peek()
    if (selectedId.length === 0 || this.pending) return
    AiPlatformSelectionState.shared().take()
    this.applyPlatform(selectedId)
  }

  private applyPlatform(id: string): void {
    const platform: AiPlatform | null = AiPlatformCatalog.find(id)
    if (platform === null) return
    this.platformId = platform.id
    this.platformLabel = platform.nameZh
    this.platformNote = platform.note
    this.platformModels = platform.models.slice()   // 必须 slice：@State 可变，不能共享目录实例数组
    this.model = ''
    if (platform.access === AiPlatformAccess.GATEWAY) {
      this.providerId = AiProviderId.CUSTOM
      this.baseUrl = ''
      this.urlEditable = true
      this.statusMessage = platform.note.length > 0 ? platform.note : '该平台需自建兼容网关，请填写你自己的地址'
      this.failed = !!this.statusMessage
    } else {
      this.providerId = platform.id
      this.baseUrl = platform.baseUrl
      this.urlEditable = platform.access === AiPlatformAccess.LOCAL_HTTP
      this.statusMessage = platform.note
      this.failed = false
    }
  }

  private syncPlatformFromConfig(): void {
    const platform: AiPlatform | null = AiPlatformCatalog.find(this.providerId)
    if (platform === null) {
      this.platformLabel = '自定义'
      this.platformNote = ''
      this.platformModels = new Array<AiPlatformModel>()
      this.urlEditable = true
      return
    }
    this.platformLabel = platform.nameZh
    this.platformNote = platform.note
    this.platformModels = platform.models.slice()   // 必须 slice：@State 可变，不能共享目录实例数组
    this.urlEditable = platform.access !== AiPlatformAccess.DIRECT
  }
```

`applyConfig()` 末尾追加 `this.syncPlatformFromConfig()`；`selectProvider()` 删除（由选择页取代）。

UI 区块替换：把原来两个 Provider 按钮改成

```ts
          this.FieldLabel('平台')
          Row({ space: 12 }) {
            Text(this.platformLabel).fontSize(BODY_FONT_SIZE).fontColor(this.colors().textPrimary).layoutWeight(1)
            Button('切换').enabled(!this.pending).onClick(() => {
              this.getUIContext().getRouter().pushUrl({ url: 'pages/AiPlatformPickerPage' }).catch(() => {})
            })
          }.width('100%')
          this.FieldLabel('API 地址')
          TextInput({ text: this.baseUrl, placeholder: this.urlEditable ? 'https://服务地址/v1' : '' })
            .fontColor(this.colors().textPrimary).backgroundColor(this.colors().pageBackground)
            .enabled(!this.pending && this.urlEditable).onChange((value: string) => { this.baseUrl = value })
          Button(this.urlEditable ? '完成自定义地址' : '自定义').enabled(!this.pending).onClick(() => {
            this.urlEditable = !this.urlEditable
          })
          if (this.platformNote.length > 0) {
            Text(this.platformNote).fontSize(13).fontColor(this.colors().textCaption)
          }
          if (this.platformModels.length > 0) {
            this.FieldLabel('推荐视觉模型')
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.platformModels, (item: AiPlatformModel) => {
                Button(item.label).fontSize(13).margin({ right: 8, bottom: 8 })
                  .backgroundColor(this.model === item.id ? this.colors().brand : this.colors().pageBackground)
                  .fontColor(this.model === item.id ? Color.White : this.colors().textPrimary)
                  .enabled(!this.pending).onClick(() => { this.model = item.id })
              }, (item: AiPlatformModel) => item.id)
            }.width('100%')
          }
```

注意：`gateway` 平台 `baseUrl` 为空，`formConfig()` 会抛 `INVALID_BASE_URL`——这是期望行为（用户必须先填地址），`saveSettings()` 既有的 `showError` 会显示「AI 服务地址无效」。

- [ ] **Step 4: 同步 PDF 导入设置页的 Provider 文案**

`entry/src/main/ets/pages/PdfAiImportSetupPage.ets:98-99` 仍把 Provider 硬编码成两种文案，61 家目录下会显示错误。改为读目录：

```ts
      const platform: AiPlatform | null = AiPlatformCatalog.find(config.providerId)
      this.providerLabel = platform === null ? '自定义' : platform.nameZh
```

并在该文件 import 区加入 `AiPlatform, AiPlatformCatalog`（来自 `../models/ai/AiPlatformCatalog`）；若 `AiProviderId` 因此不再被使用则一并删除其 import。改完运行：

Run: `node 'C:/Users/32773/.agents/skills/harmonyos-dev-skill/scripts/arkts-check.cjs' --project .`
Expected: `0 errors / 0 warnings`。

- [ ] **Step 5: 运行合同与静态检查**

Run: `node --test entry/src/test/AiImportContracts.test.cjs`
Expected: 全部 PASS。

Run: `node 'C:/Users/32773/.agents/skills/harmonyos-dev-skill/scripts/arkts-check.cjs' --project .`
Expected: `0 errors / 0 warnings`。

- [ ] **Step 5: 无提交检查点**

Run: `git diff --check`
Expected: 无输出（无空白错误）；不提交。

---

## Task 6B: Transport 支持本机/私网 http（必须在 Task 7 之前执行）

> **为什么需要：** Task 2 只放开了**校验器**，`AiVisionTransport.postJson` 仍硬编码 `endpoint.startsWith('https://')`（`AiVisionTransport.ets:92`），因此 Ollama / LM Studio / OVMS / GPUStack / New API 五家在真实请求时仍会失败。原设计与计划都漏了这个文件，2026-09-09 由实现代理发现。

**Files:**
- Modify: `entry/src/main/ets/models/ai/AiProviderConfig.ets`（把白名单谓词提升为公开的端点判定）
- Modify: `entry/src/main/ets/services/ai/AiVisionTransport.ets`
- Test: `entry/src/test/AiImportContracts.test.cjs`、`entry/src/test/AiImportSecurityContracts.test.cjs`

- [ ] **Step 1: 写失败测试（CJS）**

在 `AiImportContracts.test.cjs` 追加（复用 Task 2 的 `providerValidatorRuntime()`）：

```js
test('endpoint guard allows https and private http but never public http', () => {
  const runtime = providerValidatorRuntime()
  const allowed = ['https://api.example.com/v1', 'http://localhost:11434/v1',
    'http://127.0.0.1:1234/v1', 'http://192.168.1.9:8000/v1', 'http://10.0.0.7/v1',
    'http://172.16.4.4/v1', 'http://172.31.4.4/v1']
  for (const endpoint of allowed) {
    assert.equal(runtime.AiProviderConfigValidator.isAllowedEndpoint(endpoint), true, endpoint)
  }
  const rejected = ['http://api.example.com/v1', 'http://10.evil.com/v1',
    'http://127.0.0.1.evil.com/v1', 'http://192.168.1.9.evil.com/v1',
    'http://172.32.4.4.invalid/v1', 'ftp://localhost/v1', 'not a url']
  for (const endpoint of rejected) {
    assert.equal(runtime.AiProviderConfigValidator.isAllowedEndpoint(endpoint), false, endpoint)
  }
  const transport = read('entry/src/main/ets/services/ai/AiVisionTransport.ets')
  assert.match(transport, /AiProviderConfigValidator\.isAllowedEndpoint\(endpoint\)/)
  assert.doesNotMatch(transport, /endpoint\.startsWith\('https:\/\/'\)/)
})
```

在 `AiImportSecurityContracts.test.cjs` 追加一条安全合同：

```js
test('transport delegates its endpoint scheme guard to the shared private-host predicate', () => {
  const source = read('entry/src/main/ets/services/ai/AiVisionTransport.ets')
  assert.match(source, /AiProviderConfigValidator\.isAllowedEndpoint\(endpoint\)/)
  assert.doesNotMatch(source, /startsWith\('https:\/\/'\)/)
  assert.match(read('entry/src/main/ets/models/ai/AiProviderConfig.ets'),
    /static isAllowedEndpoint\(rawEndpoint: string\): boolean/)
})
```

- [ ] **Step 2: 运行确认失败**

Run: `node --test entry/src/test/AiImportContracts.test.cjs`
Expected: FAIL（`isAllowedEndpoint` 尚不存在）。

- [ ] **Step 3: 实现**

`AiProviderConfig.ets`：把 `isLocalOrPrivateHost` 保持私有，新增公开静态方法（供校验器与传输层共用，避免白名单两处实现漂移）：

```ts
  static isAllowedEndpoint(rawEndpoint: string): boolean {
    let parsed: url.URL
    try {
      parsed = url.URL.parseURL(rawEndpoint.trim())
    } catch {
      return false
    }
    const protocol: string = parsed.protocol.toLowerCase()
    if (protocol === 'https:') return true
    return protocol === 'http:' &&
      AiProviderConfigValidator.isLocalOrPrivateHost(parsed.hostname)
  }
```

`normalize()` 内的协议判断改为复用该方法（保留 userinfo/query/hash/`/chat/completions` 等既有规则不变）：

```ts
    if (!AiProviderConfigValidator.isAllowedEndpoint(rawBaseUrl)) {
      throw new AiImportError(AiImportErrorCode.INVALID_BASE_URL)
    }
```

`AiVisionTransport.ets:92` 的守卫替换为：

```ts
    if (!AiProviderConfigValidator.isAllowedEndpoint(endpoint)) {
      throw new AiImportError(AiImportErrorCode.INVALID_BASE_URL)
    }
```

并在该文件 import 区加入 `AiProviderConfigValidator`（来自 `../../models/ai/AiProviderConfig`）。

- [ ] **Step 4: 安全说明（写进代码注释）**

在传输层守卫上方加一行注释，写明放宽的边界与代价：

```ts
    // 仅 https 或本机/私网 http（明文会把 Bearer 暴露在局域网内，故白名单与 UI 风险提示同时生效）
```

- [ ] **Step 5: 验证**

Run: `node --test entry/src/test/AiImportContracts.test.cjs` 与 `node --test entry/src/test/AiImportSecurityContracts.test.cjs`
Expected: 全 PASS。

Run（逐文件）：`node 'C:/Users/32773/.agents/skills/harmonyos-dev-skill/scripts/arkts-check.cjs' --project . --files entry/src/main/ets/services/ai/AiVisionTransport.ets`
Expected: `errorCount: 0`。

## Task 7: 全量回归

**Files:** 只读验证，不改生产代码（除非发现缺陷，回到对应 Task）。

- [ ] **Step 1: 五个计划 CJS 文件**

Run:
```powershell
node --test entry/src/test/AiImportContracts.test.cjs entry/src/test/AiImportSecurityContracts.test.cjs entry/src/test/PdfImportContracts.test.cjs entry/src/test/CloudCutoverContracts.test.cjs entry/src/test/CloudCacheContracts.test.cjs
```
Expected: 仅 `CloudCutoverContracts` 的 `server directory has zero uncommitted changes` 失败（已知允许基线），其余全 PASS。

- [ ] **Step 2: 全量 CJS 扫描**

Run:
```powershell
Get-ChildItem 'entry/src/test' -Filter '*.test.cjs' | Sort-Object Name | ForEach-Object {
  $out = node --test $_.FullName 2>&1 | Out-String
  $m = [regex]::Matches($out, 'ℹ tests (\d+)'); $t = if ($m.Count) { [int]$m[$m.Count-1].Groups[1].Value } else { 0 }
  $m = [regex]::Matches($out, 'ℹ pass (\d+)'); $p = if ($m.Count) { [int]$m[$m.Count-1].Groups[1].Value } else { 0 }
  $m = [regex]::Matches($out, 'ℹ fail (\d+)'); $f = if ($m.Count) { [int]$m[$m.Count-1].Groups[1].Value } else { 0 }
  "=== $($_.Name) tests=$t pass=$p fail=$f"
}
```
Expected: 唯一失败文件为 `CloudCutoverContracts.test.cjs`；总失败数 1。

- [ ] **Step 3: ArkTS 全项目检查（必须逐文件）**

> ⚠️ **2026-09-09 实测结论：`arkts-check.cjs --project .` 是假绿。** checker 内部抛异常时被脚本 `try/catch`（`arkts-check.cjs:331-333`）吞掉，`Internal error:` 行不被诊断解析器识别，于是照样输出 `success:true / errorCount:0 / warnCount:0`；同理，**多文件批量**（实测 15 个一批）也会因批内某个文件崩溃而整批丢诊断。可靠做法是**逐文件**调用 `--files`。

Run:
```powershell
$checker = 'C:/Users/32773/.agents/skills/harmonyos-dev-skill/scripts/arkts-check.cjs'
$proj = (Get-Location).Path
$all = Get-ChildItem 'entry/src/main/ets' -Recurse -Filter *.ets |
  ForEach-Object { $_.FullName.Substring($proj.Length + 1).Replace('\','/') }
$errors = 0; $warnings = 0
foreach ($f in $all) {
  $out = & node $checker --project . --files $f 2>&1 | Out-String
  try { $j = $out | ConvertFrom-Json } catch { "UNPARSABLE: $f"; continue }
  $errors += [int]$j.summary.errorCount; $warnings += [int]$j.summary.warnCount
  foreach ($e in $j.errors) { if ($e.severity -eq 'error') { "ERROR $($e.file):$($e.line) $($e.message)" } }
}
"=== files=$($all.Count) errors=$errors warnings=$warnings ==="
```
Expected: `errors=0`；`warnings` 为既有历史项（如 `getContext` 弃用），不要求为 0，但**不得因本功能新增**（对照 Task 1 前的逐文件基线）。

- [ ] **Step 4: 泄密与范围扫描**

Run（用编辑器/`rg` 等价检索，只查**真实密钥形态**，不查说明性文字）：
```powershell
Select-String -Path entry/src/main/ets/models/ai/AiPlatformCatalog.ets `
  -Pattern 'sk-[A-Za-z0-9]{8,}|Authorization\s*:|Bearer\s+[A-Za-z0-9+/=]{12,}'
```
Expected: 无命中（目录是纯静态数据；`api-key`、`Bearer 鉴权` 这类**鉴权方式说明文字**属正常内容，不在扫描范围内）。

- [ ] **Step 5: 最终状态确认**

Run: `git status --short` 与 `git diff --stat`
Expected: 仅新增/修改本计划列出的文件；无 PDF、Key、日志、构建产物；**未提交、未 push、未建 PR**。

- [ ] **Step 6: Hypium 与设备项**

若设备可用（`hdc list targets` 非空且为 API 24+），运行 Hypium 与 `AiCredentialStore` 设备套件；否则如实记录 `NOT RUN`，不得由静态检查推断为 PASS。

---

## 自检记录

- **规格覆盖**：目录数据（Task 1）、providerId 字符串化与 http 白名单（Task 2）、存储兼容（Task 3）、回传单例（Task 4）、选择页与路由（Task 5）、设置页交互（Task 6）、回归与安全扫描（Task 7）逐条对应规格 §5–§9。
- **不做的事**（规格已明确排除）：远程目录、`GET /models` 联网拉取、Azure/Vertex/Bedrock/Copilot 直连、per-provider 自定义请求头、任何密钥进入目录或日志。
- **类型一致性**：`AiPlatformAccess`/`AiPlatformCategory`/`AiPlatformModel`/`AiPlatform`/`AiPlatformCatalog` 的命名与签名在 Task 1 定义，Task 5/6 只做消费；`AiProviderId` 在 Task 2 变为字符串常量类后，Task 3/6 沿用同一写法。
- **数据来源**：61 条目录数据以规格附录 A.1–A.3 为唯一事实来源，字段逐列对应，无凭空新增条目。
