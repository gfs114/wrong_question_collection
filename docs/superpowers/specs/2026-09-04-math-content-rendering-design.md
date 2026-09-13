# 数学公式规范显示设计

## 目标与边界

在不修改题目数据模型、数据库、云端 API、同步协议、OCR 服务或 SDK 配置的前提下，为题干、选项、答案和解析提供统一的数学内容显示能力。存储层继续保存原始字符串；所有检测、预览转换和公式排版都发生在 UI 渲染层。

本阶段不修改 EasyGo、平行视界、响应式框架、HdsTabs、沉浸光感、服务器或 Worker。原题图片继续作为 OCR 结果的最终视觉参考。

## 可行性结论

本机 SDK 声明确认：`Web` 加载本地 `$rawfile` 自 API 8 可用，JavaScript Proxy 自 API 8 可用，`WebviewController.runJavaScript` 自 API 9 可用，`onLoadIntercept` 自 API 10 可用。项目兼容 API24，因此可以使用本地 ArkWeb 承载 KaTeX，并通过 JavaScript Proxy 完成安全数据传递和动态高度回传。

## 总体架构

新增 `MathContentUtils` 和 `MathContentView` 两个统一入口。

`MathContentUtils` 负责：

- 以保守规则实现 `containsMath(content)`；成对 delimiter、已知 LaTeX 命令和明确的单变量上下标结构才判定为数学内容。
- 实现 `toPlainPreview(content)`，供列表卡片将常见命令、上下标、根式和简单分式转换成可读 Unicode 摘要。
- delimiter 扫描感知反斜杠转义；完整闭合 span 默认尊重显式公式标记。`$` 后的纯数字金额只有在遇到空白/正文标点且后续仍存在公式对时才作为独立价格 token，数字后紧接变量或运算内容仍按公式处理，因此公式与价格的前后顺序不会改变解析。列表只转换确认过的公式片段，周围的 `file_name`、`$5-$10` 等普通文本不参与替换。
- 不修改调用方传入的字符串，也不猜测或修复不合法 OCR 数学语义。

`MathContentView` 负责：

- 普通内容直接使用 ArkUI `Text`。
- 数学内容挂载一个本地 `Web`，加载 `rawfile/math/math-content.html` 和本地 KaTeX 静态资源。
- 支持 `content`、`fontSize`、`fontWeight`、`textColor` 和 `lineHeight` 参数，宽度始终跟随父容器。
- 组件复用时更新 JavaScript Proxy 中的内容并调用页面内固定的渲染函数，不把内容拼入脚本字符串。

## 安全数据流

ArkTS 端桥接对象只暴露固定方法，用于读取内容和样式、回报渲染成功高度、回报渲染失败。HTML 通过桥接方法取得原始字符串，并通过 DOM `textContent` 建立文本节点；题目中的引号、尖括号、与号和反斜杠不会成为 HTML 或 JavaScript 源码。

KaTeX 使用 `trust: false` 和严格错误处理。Web 关闭在线图片、DOM Storage、地理位置和混合内容访问；导航拦截只允许 `resource://rawfile/math/` 下的资源。HTML、JavaScript、CSS、字体和许可证均随应用打包，不引用 CDN 或其他远程地址。

## 渲染与回退

具有 `$...$`、`$$...$$`、`\(...\)` 或 `\[...\]` delimiter 的内容由 KaTeX auto-render 处理，以支持中文和行内/块级公式混排。存在货币美元符号或转义美元符号时，HTML 使用同样的保守扫描结果，通过安全文本节点和逐公式 `katex.render` 避免 auto-render 把价格误配成公式。没有 delimiter 但被 `containsMath` 确认的内容，作为一个完整数学片段尝试渲染；残缺 delimiter 直接回退原文。

渲染期间先显示原生原文，避免 Web 初始化时出现空白。只有 KaTeX 完整成功后才显示 Web 内容；任一公式解析失败、资源加载失败或脚本执行失败都会移除 Web 并继续显示原始 `Text`。切换题目时重置渲染状态，既不保留失败状态，也不修改原始数据。

HTML 保留换行和空行，使用与 ArkUI 参数一致的字体大小、行高和颜色。公式根节点限制最大宽度，并允许内部横向滚动，避免撑破卡片或页面。

渲染完成、字体加载完成及内容尺寸变化时，HTML 通过根节点边界和固有滚动高度将实际高度回传 ArkUI；组件据此更新 Web 高度，不使用统一固定高度或静默高度上限。一行公式不会留下大块空白，多行内容不会被裁剪。每次内容或样式更新都携带递增 generation；字体、动画帧和 ResizeObserver 的旧回调会被忽略，避免连续切题时旧公式覆盖新状态。

## 页面接入

- `QuestionDetailPage`：题干、选项、答案、解析改用 `MathContentView`；题型标签、按钮和 `QuestionSourceImages` 保持原样。
- `WrongQuestionDetailPage`：题干、选项、答案、解析使用同一组件和同一套样式规则。
- `QuestionListPage`：通过 `QuestionCard` 使用 `toPlainPreview`，不创建 Web。
- `WrongQuestionsPage`：通过 `WrongQuestionCard` 使用 `toPlainPreview`，不创建 Web。
- `EditQuestionPage`：输入框继续编辑原始字符串；仅对检测到数学内容的题干、选项、答案和解析显示公式预览。
- `PdfImportReviewPage`：输入框继续编辑原始 OCR/LaTeX 字符串；每题提供按需展开的公式预览，同一时刻只展开一个题目的预览，避免审核列表常驻大量 Web 实例。
- `QuestionBankCard`：不显示题目正文，因此无需公式处理，保持现状。

详情页的 Web 数量由当前题目中实际包含数学内容的字段决定，并在页面退出时随组件释放；普通字段不会创建 Web。列表页始终保持纯原生渲染。

## 本地资源与许可证

只引入 KaTeX 浏览器渲染所需的压缩 JavaScript、auto-render、CSS、CSS 实际引用的字体及上游许可证/NOTICE。资源统一放入 `entry/src/main/resources/rawfile/math/`，测试会拒绝 `cdn.jsdelivr.net`、`unpkg.com`、`cdnjs.cloudflare.com` 和其他 HTTP(S) 资源引用。

## 测试与验证

先在 `LocalUnit.test.ets` 添加 `MathContentUtils` 的失败测试，覆盖普通文本、四类 delimiter、已知命令、保守下划线判断、上下标、比较符号、希腊字母、根式、简单分式、多行和特殊字符。随后实现最小工具代码使测试通过。

新增资源与页面契约测试，验证：

- KaTeX 资源和许可证完整存在且没有 CDN。
- HTML 使用桥接和 `textContent`，启用安全 KaTeX 参数、失败回报、换行、横向溢出和动态高度回报。
- HTML 执行测试覆盖货币与公式混排、两段价格、残缺 delimiter 和过期 generation 回调；固定 SHA-256 校验审阅过的 KaTeX 分发文件。
- 详情页四类内容统一使用 `MathContentView`。
- 列表卡片只使用 `toPlainPreview` 且不包含 `Web`。
- 编辑页和 PDF 审核页保留输入控件并提供有条件/按需预览。
- 被禁止的模型、业务、服务器、EasyGo、HdsTabs 和 SDK 配置没有变化。

实现后依次运行修改文件的 ArkTS 检查、全部 CJS 契约测试、Hvigor 本地测试和 debug HAP 构建。若设备可用，再安装并检查混排、非法公式、长公式、深色模式和连续切题；若无设备，则明确把运行时 UI 验证列为未执行，而不宣称通过。
