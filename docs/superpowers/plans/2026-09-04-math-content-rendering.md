# 数学公式规范显示 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在保持题目原始字符串与业务协议不变的前提下，为详情和编辑预览提供离线 KaTeX 数学排版，并为列表提供无 Web 的轻量摘要。

**Architecture:** `MathContentUtils` 统一检测数学内容并生成列表摘要；`MathContentView` 对普通内容使用原生 `Text`，对数学内容使用只加载本地资源的 ArkWeb + KaTeX。ArkTS 与 HTML 通过 JavaScript Proxy 传递原始字符串和回报渲染状态/高度，任何失败都保留原生原文。

**Tech Stack:** HarmonyOS 6.1.1(24), ArkTS, ArkUI V1, ArkWeb, KaTeX 0.18.5, Hypium, Node contract tests, Hvigor.

**Execution constraint:** 用户明确要求不 commit、不 push、不创建 PR，因此所有提交步骤均省略；只保留可检查的工作树改动。

---

### Task 1: 写出失败的公式工具与集成契约

**Files:**
- Create: `entry/src/test/MathContentContracts.test.cjs`
- Modify: `entry/src/test/LocalUnit.test.ets`

- [x] **Step 1: 在 Hypium 套件中先引用尚不存在的工具并写行为测试**

加入 `import { MathContentUtils } from '../main/ets/utils/MathContentUtils'`，并增加 `mathContentUtils` 测试组，直接断言：普通中文和 `file_name` 为 false；四类 delimiter、`\\frac`、`\\sqrt`、`x^2`、`a_1` 为 true；预览将 `x^2`、`a_1`、比较符号、希腊字母、根式、简单分式、积分、求和与 `\\pm` 转成可读文本，同时保留换行及 `< > & \" ' \\`。

- [x] **Step 2: 新增源代码/资源契约测试**

`MathContentContracts.test.cjs` 必须读取预期新增文件及目标页面，并断言：

```js
for (const file of [
  'entry/src/main/ets/utils/MathContentUtils.ets',
  'entry/src/main/ets/components/MathContentView.ets',
  'entry/src/main/resources/rawfile/math/math-content.html',
  'entry/src/main/resources/rawfile/math/katex.min.js',
  'entry/src/main/resources/rawfile/math/auto-render.min.js',
  'entry/src/main/resources/rawfile/math/katex.min.css',
  'entry/src/main/resources/rawfile/math/LICENSE'
]) {
  requireFile(file)
}
```

契约还必须检查 HTML 包含 `textContent`、`trust: false`、`throwOnError: true`、失败回报、`white-space: pre-wrap`、`overflow-x: auto`、高度回报和 `ResizeObserver`；所有 math rawfile 禁止 `http://`、`https://` 及三个 CDN 域名。详情页必须各有四类 `MathContentView`；卡片必须调用 `toPlainPreview` 且不得出现 `Web(`；编辑页继续包含 `TextInput`/`TextArea` 并接入预览；PDF 审核页必须具备按题目 ID 展开的预览状态。

- [x] **Step 3: 运行测试并确认按预期失败**

Run:

```powershell
node entry/src/test/MathContentContracts.test.cjs
& 'D:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'D:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' test --mode module -p module=entry@default
```

Expected: contract 因新增文件不存在而失败；Hvigor 测试因 `MathContentUtils` import 不存在而失败。不得在 RED 阶段修改生产代码。

### Task 2: 实现保守检测和纯文本摘要

**Files:**
- Create: `entry/src/main/ets/utils/MathContentUtils.ets`
- Test: `entry/src/test/LocalUnit.test.ets`

- [x] **Step 1: 实现公开 API 和确定性解析辅助方法**

创建只含静态方法的 `MathContentUtils`：

```ts
export class MathContentUtils {
  static containsMath(content: string): boolean
  static toPlainPreview(content: string): string
}
```

`containsMath` 使用成对 delimiter、已知命令列表、单变量上下标的边界规则；不能以单独 `_` 判定。`toPlainPreview` 先安全移除 delimiter，再用显式扫描和配对花括号处理 `\\frac{a}{b}`、`\\sqrt{x}` 与上下标，最后用固定 `replaceAll` 映射数学符号。不得使用 `any`、`unknown`、动态属性访问、类型断言或模板字符串。

- [x] **Step 2: 检查 ArkTS 并运行工具测试**

Run:

```powershell
$env:DEVECO_HOME='D:\Program Files\Huawei\DevEco Studio'
& 'D:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'C:\Users\32773\.agents\skills\harmonyos-dev-skill\scripts\arkts-check.cjs' --project . --files entry/src/main/ets/utils/MathContentUtils.ets entry/src/test/LocalUnit.test.ets
& 'D:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'D:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' test --mode module -p module=entry@default
```

Expected: ArkTS 0 diagnostics；新增 Hypium 测试通过。资源契约仍保持失败。

### Task 3: 固化 KaTeX 0.18.5 离线资源与安全 HTML

**Files:**
- Create: `entry/src/main/resources/rawfile/math/math-content.html`
- Create: `entry/src/main/resources/rawfile/math/katex.min.js`
- Create: `entry/src/main/resources/rawfile/math/auto-render.min.js`
- Create: `entry/src/main/resources/rawfile/math/katex.min.css`
- Create: `entry/src/main/resources/rawfile/math/fonts/*.woff2`
- Create: `entry/src/main/resources/rawfile/math/LICENSE`

- [x] **Step 1: 下载并校验官方 npm 包**

Run in a temporary directory:

```powershell
npm pack katex@0.18.5 --registry=https://registry.npmjs.org
npm view katex@0.18.5 dist.integrity license --registry=https://registry.npmjs.org
```

Expected: integrity 为 `sha512-1FU5H3RjGJVj6GT9fMjf2uMIXmPQp232aXS3UEeQzf0dxefHg/CKMvNB3DuOC46LFG/E5PNxrE8dOwB782FDGg==`，license 为 MIT。解包后只复制 `dist/katex.min.js`、`dist/contrib/auto-render.min.js`、`dist/katex.min.css`、CSS 引用的 WOFF2 字体和 `LICENSE`；不保留 CLI、源码、测试或文档站点资源。

- [x] **Step 2: 创建固定 HTML 渲染壳**

HTML 加载相对路径的 CSS/JS，读取 `window.mathBridge` 固定方法。渲染混合内容时先把原始字符串赋给 `root.textContent`，再调用 `renderMathInElement`；无 delimiter 时调用 `katex.render(content, root, options)`。统一选项必须包含：

```js
const options = {
  throwOnError: true,
  trust: false,
  strict: 'error',
  output: 'htmlAndMathml'
}
```

auto-render 的 `errorCallback` 设置失败标志，任何异常调用 `mathBridge.reportFailure()`。成功后在立即、字体完成及 `ResizeObserver` 变化时调用 `mathBridge.reportSuccess(document.documentElement.scrollHeight)`。根节点使用 `white-space: pre-wrap`、`max-width: 100%` 和 `overflow-x: auto`。

- [x] **Step 3: 运行资源契约的资源子集**

Run: `node entry/src/test/MathContentContracts.test.cjs`

Expected: 本地资源、安全 HTML 与许可证断言通过；组件/页面断言仍失败。

### Task 4: 实现带原生回退和动态高度的 MathContentView

**Files:**
- Create: `entry/src/main/ets/components/MathContentView.ets`
- Test: `entry/src/test/MathContentContracts.test.cjs`

- [x] **Step 1: 建立桥接对象**

创建明确类型的 `MathContentBridge` 类，保存 `content/fontSize/fontWeight/textColor/lineHeight`，暴露读取方法和 `reportSuccess(height)`、`reportFailure()`。回调通过显式箭头函数字段绑定到组件状态，不使用动态对象访问。

- [x] **Step 2: 实现组件状态机**

`MathContentView` 使用 ArkUI V1：

```ts
@Prop @Watch('onContentChanged') content: string = ''
@Prop fontSize: number = 16
@Prop fontWeight: number = 400
@Prop textColor: string = ''
@Prop lineHeight: number = 24
@StorageProp('darkMode') @Watch('onStyleChanged') darkMode: boolean = false
@State webHeight: number = 24
@State renderReady: boolean = false
@State renderFailed: boolean = false
```

普通内容只构建 `Text`。数学内容用 `Stack` 同时保留原生回退文本和尚未显示的 Web；成功后隐藏原生文本，失败后移除 Web。Web 使用 `$rawfile('math/math-content.html')`、JavaScript Proxy 和固定脚本 `window.renderMathContent()` 更新内容，关闭在线图片、DOM Storage、地理位置和混合内容，并用 `onLoadIntercept` 只允许 `resource://rawfile/math/`。组件宽度为 `100%`，Web 高度取回报值而非固定常量。

- [x] **Step 3: ArkTS 检查与组件契约**

Run arkts-check on `MathContentView.ets` and `MathContentUtils.ets`, then run `node entry/src/test/MathContentContracts.test.cjs`.

Expected: ArkTS 0 diagnostics；组件安全/回退/动态高度契约通过；页面契约仍失败。

### Task 5: 接入两个详情页

**Files:**
- Modify: `entry/src/main/ets/pages/QuestionDetailPage.ets`
- Modify: `entry/src/main/ets/pages/WrongQuestionDetailPage.ets`

- [x] **Step 1: 将四类业务正文替换为统一组件**

分别导入 `MathContentView`，将题干、每个选项、答案和解析的 `Text(value)` 替换为对应 `MathContentView({ content, fontSize, fontWeight, textColor, lineHeight })`。保留类型标签、选项序号、操作按钮、卡片布局、`QuestionSourceImages` 和原有响应式最大宽度。

- [x] **Step 2: 检查两个页面并运行契约**

Run arkts-check on component and both pages, then run `node entry/src/test/MathContentContracts.test.cjs`.

Expected: 两页各四类内容契约通过，无新的 ArkTS 错误。

### Task 6: 列表只接入纯文本摘要

**Files:**
- Modify: `entry/src/main/ets/components/QuestionCard.ets`
- Modify: `entry/src/main/ets/components/WrongQuestionCard.ets`

- [x] **Step 1: 在卡片渲染边界生成摘要**

导入 `MathContentUtils`，把正文改为 `Text(MathContentUtils.toPlainPreview(this.questionText))`。保留三行限制、颜色、字号和按钮结构；不得导入 `MathContentView`、ArkWeb 或创建 Web。

- [x] **Step 2: 检查卡片、列表页面和性能契约**

Run arkts-check on both cards plus `QuestionListPage.ets` and `WrongQuestionsPage.ets`, then run the contract.

Expected: 列表路径仅有原生 Text，页面没有 Web 实例。

### Task 7: 编辑页和 PDF 审核页提供不改原文的预览

**Files:**
- Modify: `entry/src/main/ets/pages/EditQuestionPage.ets`
- Modify: `entry/src/main/ets/pages/PdfImportReviewPage.ets`

- [x] **Step 1: 编辑页加入条件预览**

导入 `MathContentView` 与 `MathContentUtils`。在题干、每个选项、答案和解析输入控件之后，仅当 `containsMath(value)` 为 true 时显示“公式预览”和 `MathContentView`。所有 `.onChange` 继续把原始字符串写入当前 state，不使用 `toPlainPreview` 回写输入值。

- [x] **Step 2: PDF 审核页加入单题按需预览**

增加 `@State previewDraftQuestionId: string = ''`。每个草稿卡片只有在题干/选项/答案/解析任一字段含数学内容时显示“预览公式”按钮；点击后切换当前草稿 ID。同一时刻最多一个草稿展开，展开区域用 `MathContentView` 显示各个含数学内容的字段。现有 `TextArea`/`TextInput`、更新函数、确认流程和草稿模型保持不变。

- [x] **Step 3: 检查编辑页面并运行契约**

Run arkts-check on both pages, then the focused contract and all CJS contracts.

Expected: 输入仍显示原始 LaTeX；预览按条件/按需存在；所有 CJS contract 通过。

### Task 8: 完整验证与范围审计

**Files:**
- Verify only: all files changed by Tasks 1-7

- [x] **Step 1: 运行全部 ArkTS 检查**

Run `arkts-check.cjs` against every modified `.ets` file and `LocalUnit.test.ets`.

Expected: 0 diagnostics。

- [x] **Step 2: 运行全部客户端契约和 Hypium 测试**

```powershell
Get-ChildItem entry/src/test -Filter '*.test.cjs' | ForEach-Object { node $_.FullName; if ($LASTEXITCODE -ne 0) { throw $_.Name } }
& 'D:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'D:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' test --mode module -p module=entry@default
```

Expected: 全部测试 0 failure。

- [x] **Step 3: 构建 debug HAP**

```powershell
& 'D:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'D:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' --no-daemon --mode module -p product=default -p module=entry@default -p buildMode=debug assembleHap
```

Expected: `BUILD SUCCESSFUL`，输出 HAP 存在。

Result: 在不修改空签名配置的前提下使用 `properties.enableSignTask=false` 完成无增量构建，生成 `entry-default-unsigned.hap`；签名构建因仓库及本机均无证书/profile 而不可用。

- [x] **Step 4: 设备可用时执行运行验证**

先用 hdc 列出设备；只有存在单一可用设备时才安装并启动。验证普通文本、上下标、分式、根式、积分、求和、中文混排、多行、非法公式、超长公式、特殊字符、深色模式、上一题/下一题和 PDF 按需预览。没有设备时记录为 `NOT RUN`。

Result: 检测到单一设备 `192.168.0.107:35911`，但产物未签名且本机没有 `local-signing.json`、证书或 profile，无法安装；设备 UI 验证记为 `NOT RUN (missing signing material)`。

- [x] **Step 5: 审计范围和工作树**

Run `git diff --check`、`git status --short` 和限定路径 `git diff --stat`。确认 Question model、数据库、服务器、Worker、云同步、EasyGo、Index/HdsTabs、HdsMaterialPolicy、SDK 配置均无改动；确认没有 commit。
