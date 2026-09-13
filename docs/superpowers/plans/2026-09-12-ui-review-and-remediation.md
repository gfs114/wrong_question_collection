# UI/UX 审查与分批整改

日期：2026-09-12。仓库：`G:\code\openHarmony\wrong_question_collection`。

**当前状态：用户已确认方案 A“原生练习册”；第一批三页、H1 首页/主导航、H2 错题子项、H4 AI PDF 设置/进度/审核和 H5“我的”页均已完成代码与验证。H4 设置页后来在平板真机发现短内容仍被 `Scroll` 居中，现已改为顶部起排并重新安装验收；进度页同步修正同构问题，审核页已通过合同、ArkTS 和 HAP 构建。** H2 的题库子项及 H3、H6 仍是后续分批任务；进度/审核真机态、读屏、最大字号、手机窄窗、深色模式和二合一自由窗口仍需补充运行证据。

## 1. 范围、依据与保护边界

本次以当前工作树为准，保留其中已有的首页编辑风、HdsTabs 中央导入动作、AI 目录、审核恢复性及安全改动。旧文档中的“无中央加号”“完全本地优先”等描述与当前实现不一致，不作为回退依据。

已阅读的主要依据：

- `README.md`（目前仅仓库标题）。
- `docs/superpowers/specs/2026-08-24-api26-home-immersive-navigation-account-design.md`。
- `docs/superpowers/specs/2026-09-09-ai-platform-catalog-design.md`。
- `docs/superpowers/plans/2026-09-12-software-review-and-remediation.md`。
- `entry/src/main/ets/constants/AppTheme.ets`、`EditorialStyle.ets`、`ResponsiveLayout.ets`。
- `entry/src/main/ets/theme/AppColors.ets`、`LightColors.ets`、`DarkColors.ets`、`ThemeManager.ets`。
- `entry/src/main/ets/utils/SafeAreaUtils.ets`，主导航、首页、题库、错题、详情、编辑、我的、导入入口、AI 设置、平台选择、PDF 设置/进度/审核页与相关组件。
- `entry/src/test/EditorialUiContracts.test.cjs` 及本轮全量客户端 CJS 基线。

实施禁止事项：不改 `server/` 或 worker；不改变数据结构、AI 图像识别与导入链路、API Key/HUKS 持久化、账号绑定、审核会话、保存幂等、证据图片生命周期；不发起真实收费测试；不削弱安全合同；不提交、推送、合并、创建 PR；不清理已有脏树。2026-09-13 用户追加的明确需求允许客户端新增模型目录读取，但该读取必须继续走既有端点守卫和凭据传输边界，不能接入业务服务器。

### 1.1 证据分级

- **源码证据**：定位到实际属性、分支或回调，足以确定实现现状。
- **设备观察**：已安装应用在一台 2880×1920 横屏设备上的现象。未重新构建安装，不能保证安装包对应当前工作树。
- **待验证风险**：大字号、键盘、分屏、读屏等尚未实际复现，不写成已经确认的运行缺陷。

### 1.2 修改前与实施后截图

截图目录：`docs/superpowers/plans/ui-review-2026-09-12/`。

| 文件 | 内容 | 观察 |
|---|---|---|
| `before-home-selected.jpeg` | 首页，深色横屏 | 五个快捷入口、话题条、概览、侧边导入同时出现；导入入口重复；沿用细线练习册风 |
| `before-books-installed.jpeg` | 题库，深色横屏 | 单条题库占双列的左半边；留白较大，但不是数据丢失 |
| `before-books-layout.json` | 题库 UI 树 | 记录题库内容、操作及导航位置；仅供本地验收 |
| `before-ai-settings-installed.jpeg` | AI 设置，深色横屏 | 蓝色默认按钮与绿色主按钮混用；顶部返回/标题与表单不对齐；长表单把操作推到下方 |
| `before-platform-picker-installed.jpeg` | 平台选择，深色横屏 | 短列表项呈胶囊堆叠；标题在窗口左侧，内容在中央；分类仅通过颜色区分 |
| `before-import-installed.jpeg` | 导入入口，深色横屏 | 标题与状态栏区域重叠；内容垂直位置偏低；先看到 JSON 技术说明，再看到 PDF 入口 |

| 实施后文件 | 内容 | 验收结果 |
|---|---|---|
| `after-import.jpeg` | 导入入口，深色横屏 | 标题避开状态栏；PDF 成为推荐主入口；JSON 与格式说明合并为次级组；内容居中限宽且顶部对齐 |
| `after-import-json-example.jpeg` | JSON 示例区，深色横屏 | 单题示例完整显示；等宽代码表面与格式说明同组；滚动到底后没有裁切或底部手势区遮挡 |
| `after-ai-settings.jpeg` | AI 设置，深色横屏 | 标题与 680vp 内容轴线一致；服务/模型、密钥管理形成连续阅读顺序；长内容可继续滚动 |
| `after-platform-picker.jpeg` | 平台选择，深色横屏 | 搜索、分类、结果数和统一分隔列表层级清楚；选中分类同时使用填充与 accessibility 状态；列表行满足 48vp 最小目标 |
| `after-home-h1.jpeg` | H1 首页，深色横屏 | 快捷区由五项收敛为三个真实目的地；移除重复导入按钮和误导性数据 chips；最近内容使用明确的列表级入口；底栏导入动作保持不变 |
| `after-wrong-h2.jpeg` | H2 错题，深色横屏 | 学科筛选提升到 48vp 并支持两行；嵌入式空态随内容自然占位；统计、筛选、章节标题和空态层级连续 |
| `after-mine-h5.jpeg` | H5 我的，深色横屏 | 报头收紧并将学习概览前置；普通设置、数据与隐私、开发辅助独立分组；清空错题以红色文字和永久删除说明呈现 |
| `after-wrong-top-safe.jpeg` | 错题顶部安全区返修，深色横屏 | 页面内“错题”标题位于真实状态栏避让区之后；统计卡从标题分隔线下方开始，不再覆盖状态栏；Navigation 不再重复绘制标题 |
| `after-mine-top-safe.jpeg` | 我的顶部安全区返修，深色横屏 | 页面内“我的”标题固定在内容最上方；学习中心及全部状态内容从标题下方开始；Navigation 不再重复绘制标题 |
| `after-mine-account-before-overview.jpeg` | 我的账号合并与顺序调整中间稿，深色横屏 | 已将合并账号卡移到学习概览前，但仍保留“学习与账号”分区标题与横线；后续按用户反馈继续精简 |
| `after-mine-account-direct.jpeg` | 我的账号区顺序与分区精简，深色横屏 | “我的”标题下直接显示合并账号卡；已移除“学习与账号”文字及其分区横线；学习概览位于账号卡之后，宽屏设置保持两栏 |
| `after-mine-current-device.jpeg` | 我的当前设备名称，深色横屏 | 账号卡显示系统提供的真实营销名称“HUAWEI MatePad Pro”，不再展示固定的 `HarmonyOS device`；其他账号状态及操作不变 |
| `after-plus-single-route.jpeg` | 中央加号直接导入，深色横屏 | 点击中央加号直接进入“导入题库”；返回一次即回到主页面，再次点击仍能正常进入，未重复压栈 |
| `after-json-help-collapsed-again.jpeg` | JSON 帮助默认收起，深色横屏 | PDF 与 JSON 导入操作均在首屏完整可见；技术说明收敛为“JSON 格式与示例 / 展开”单行入口 |
| `after-json-help-expanded.jpeg` | JSON 帮助展开，深色横屏 | 展开后显示原有字段说明、UTF-8 要求和完整单题示例；入口文字变为“收起”，内容可继续滚动 |

设备：`192.168.0.104:35911`，应用：`com.gfs.wrongquestion`。只启动应用、切换已有页面、截图；未选文件、未修改配置、未显示密钥、未执行测试连接。

截图工具注意：技能 `device-screenshot.cjs` 返回 success，但设备拒绝 `.png` 文件名，且传输输出实际失败；本次改用 `snapshot_display -f ...jpeg`，确认传输成功并逐张打开验收。工具的 success 字段不能替代文件存在与视觉检查。

## 2. 当前问题清单

P1：阻碍辨识、关键操作或安全信息理解；P2：明显一致性、效率或适配缺口；P3：细节打磨。以下为 UI 优先级，不宣称新增安全漏洞。

| ID / 优先级 | 页面及准确文件（行号为审查时参考） | 问题、影响、建议 | 证据 / 批次 |
|---|---|---|---|
| UI-01 / P1 | `entry/src/main/ets/theme/LightColors.ets`、`DarkColors.ets`；`pages/AiRecognitionSettingsPage.ets:313`、`pages/AiPlatformPickerPage.ets:111` | 白字配品牌绿对比度不足；选中芯片还写死 `Color.White`。浅色白/绿约 3.13:1，深色约 2.65:1；普通文字难读。引入明确的操作背景/操作文字配对，不直接全局替换品牌色。 | 源码计算；首批限定新页面操作色 |
| UI-02 / P1 | `entry/src/main/ets/pages/ImportBankPage.ets:176`；`utils/SafeAreaUtils.ets` | 安装版导航标题与状态栏重叠；源码没有显式上避让，需核实原生 Navigation 与沉浸窗口的责任。确保标题位于顶部避让区之后，禁止机械叠加导致双重留白。 | 设备观察 + 源码；首批 |
| UI-03 / P1 | `entry/src/main/ets/pages/AiRecognitionSettingsPage.ets:249`、`pages/AiPlatformPickerPage.ets:94` | 手工蓝色“返回”栏，与其他页原生标题不一致；宽屏标题与内容偏离。统一内容轴线、返回层级和四边安全区；保留设置页 pending 返回守卫。 | 源码 + 截图；首批 |
| UI-04 / P1 | `entry/src/main/ets/pages/AiRecognitionSettingsPage.ets:249-333` | 一个长容器混排平台、地址、推荐模型、密钥、Model、保存、清除、付费测试；状态只在最末尾。阅读顺序不对应配置心智，长屏操作反馈不可见。分为“服务与模型 / API Key / 保存与连接验证”；保存为唯一主要操作，测试保持明确费用说明，状态放在可感知区域。 | 源码 + 截图；首批 |
| UI-05 / P1 | `entry/src/main/ets/pages/ImportBankPage.ets:182-273` | JSON 字段说明占首屏，JSON 主按钮在 PDF 之前；用户先被技术术语拦住，不易理解 PDF 路径。推荐 PDF 主入口前置并说明“选择→设置→识别→审核”，JSON 次入口和完整格式说明紧随其后。只调整呈现顺序，保持两个处理函数与互斥条件。 | 源码 + 截图；首批 |
| UI-06 / P2 | `entry/src/main/ets/pages/AiPlatformPickerPage.ets:102-144` | 搜索无独立结果计数；空结果只有一行提示；单行平台高度随文本收缩，选中分类仅变颜色。采用至少 48vp 行、分隔线、类别文字/选中语义；空结果给清空搜索与筛选入口。 | 源码 + 截图；首批 |
| UI-07 / P2 | `entry/src/main/ets/pages/HomePage.ets` 的 `QuickEntryRow`、`TopicChipStrip`、`ImportButton`；`components/HomeOverviewCard.ets` | 导入在快捷区、按钮、底栏和空态重复；五列入口在窄屏会压缩文字；“AI 识别”实际进入设置。已在 H1 删除常驻重复导入与话题条，将快捷区收敛为“AI 设置 / 查看题库 / 查看错题”，空数据 CTA 与底栏导入保留各自情境。 | **H1 已完成**；合同 + 当前源码构建截图 |
| UI-08 / P2 | `entry/src/main/ets/pages/HomePage.ets` 的 `TopicChipStrip`；`components/HomeRecentSection.ets` | 展示具体题库/科目名称，但点击仅切到题库/错题总列表。H1 已移除误导性数据 chips 和摘要行箭头/点击，把唯一跳转放到章节头并命名为“查看题库列表 / 查看错题列表”；未增加筛选或详情直达。 | **H1 已完成**；合同 + 当前源码构建截图 |
| UI-09 / P2 | `entry/src/main/ets/pages/WrongQuestionsPage.ets`、`pages/EditQuestionPage.ets`、`pages/PdfImportReviewPage.ets`、`pages/PdfAiImportSetupPage.ets` | 科目和题型控件原低于 48vp。错题筛选、PDF 设置科目和审核题型现均使用 `UiStyle.TOUCH_TARGET` 并保留原守卫；编辑页仍待处理。 | **H2/H4 已完成对应项**；编辑页后续 H3 |
| UI-10 / P2 | `entry/src/main/ets/constants/AppTheme.ets`、`EditorialStyle.ets`；详情与 PDF 页面 | 16vp 纸张卡、20vp 旧卡、胶囊输入、12/13/14vp 正文并存。建立页面角色和组件规范；先供首批使用，不一次替换所有卡片和已有合同。 | 源码；逐批 |
| UI-11 / P2 | `entry/src/main/ets/pages/QuestionDetailPage.ets:417`、`pages/WrongQuestionDetailPage.ets:447`、`pages/EditQuestionPage.ets:372` | 底部多按钮固定同一行且高度 48vp；题干/解析 TextArea 高度固定 100–112vp。大字、短窗口及键盘时有挤压风险。主操作优先，紧凑窗口允许纵排；表单最小高度和键盘可见性检查。 | 源码风险，未设备复现；后续 H3 |
| UI-12 / P2 | `entry/src/main/ets/pages/PdfAiImportSetupPage.ets`、`pages/PdfAiImportProgressPage.ets` | 设置页已改为中文标签、两行长文本与动态页码摘要；进度页已改为顶部阶段、真实页数进度和当前页/完成页/题目数，不虚构耗时或百分比。 | **H4 已完成**；合同 + ArkTS + 构建，设置页有真机证据 |
| UI-13 / P2 | `entry/src/main/ets/pages/PdfImportReviewPage.ets` | 权威状态未知时现进入独立恢复分支，只显示“重新加载审核状态”，编辑、保存和返回继续锁定；普通空态才显示“重新读取草稿”。 | **H4 已完成**；业务合同 + UI 合同 |
| UI-14 / P2 | `entry/src/main/ets/pages/PdfImportReviewPage.ets` | 题号/来源/题型与编辑区域已重新分层；EXPANDED 有原图时采用证据/编辑 4:6 双栏，紧凑窗保持单列；失败页动作按主次和危险级分层。 | **H4 已完成**；合同 + ArkTS + 构建，真机截图待补 |
| UI-15 / P2 | `entry/src/main/ets/pages/MinePage.ets:735` 的 `DataManagementSection` | 原“数据管理”行带右箭头却没有 onClick，形成假入口；清空错题与普通设置混列。现已删除假入口，将清空错题放入独立“数据与隐私”组，补充永久删除说明；既有确认弹窗、登录要求和云端优先清空逻辑不动。 | **H5 已完成**；合同 + 当前源码构建截图 |
| UI-16 / P2 | `entry/src/main/ets/components/EmptyState.ets:23`；`pages/HomePage.ets`、`pages/BooksPage.ets`、`pages/WrongQuestionsPage.ets:422` | 原 EmptyState 强制 100% 高，与 ListItem 嵌入语义不一致；错题空态固定 260vp。共享组件现支持 `fillAvailable`，错题使用 180vp 最小高度的嵌入模式；题库等其他嵌入点仍需逐页核对。 | **H2 错题子项已完成**；题库子项后续 |
| UI-17 / P2 | `entry/src/main/ets/utils/SafeAreaUtils.ets` 与各 pages | 首批页面及首页已消费四边 inset；错题与“我的”返修后由页面内标题统一消费 top inset，列表继续消费 left/right，加载、错误与正常内容均从标题下方开始。其他页面仍需覆盖横屏挖孔与自由窗口矩阵。 | 错题/我的已完成；其余逐页 |
| UI-18 / P2 | `entry/src/main/ets/pages/AiRecognitionSettingsPage.ets`、`pages/HomePage.ets`、`components/SectionTitle.ets`、`pages/Index.ets` | 可点击 Text/Row 和自定义控件有部分 accessibilityText，但缺少系统化角色、选中状态、键盘焦点及分组；不能只凭颜色、箭头或图标传达动作。先处理首批的标签、焦点、筛选状态。 | 源码；逐批，读屏待测 |
| UI-19 / P3 | `entry/src/main/ets/pages/BooksPage.ets:462`、`pages/WrongQuestionsPage.ets`；`constants/ResponsiveLayout.ets` | 宽屏双列最后仅一项时保留半列空位，属于布局选择而非 bug；少量内容可考虑受限单列，避免误判为缺数据。不在首批修改列表结构。 | 源码 + 题库截图；后续 H2 |
| UI-20 / P2 | `entry/src/main/ets/models/ai/AiPlatformCatalog.ets:69`；`pages/AiRecognitionSettingsPage.ets:278` | 平台备注直接露出 `supportsStructuredOutput = true` 等实现术语。应将展示文案改为用户可理解的能力说明，但不根据中文备注解析能力或改变模型配置。 | 源码 + 截图；后续业务文案审查 |

### 2.1 已知问题与本次边界

之前软件审查记录的“不支持图片的平台仍可选”和“自定义地址保留原平台身份”仍需独立处理。设备设置截图也出现平台标签与地址不一致，但本次不保存、不纠正用户配置。修复会改变目录数据结构或平台配置逻辑，因此不混入 UI 改造，也不把它们误写为已解决。

已存在的审核状态未知锁定、清理失败恢复、登录/离线提示、JSON/PDF 互斥和付费测试提示是应保留的有效设计。确认弹窗已使用系统 API；重点检查长文、危险动作命名、焦点及取消路径，不重写弹窗状态机。

## 3. 候选方向与推荐

方案图：[design-directions.png](ui-review-2026-09-12/design-directions.png)。这是一张静态构图示意，不能当作编译后的界面或像素验收结果。

| 方向 | 表现 | 优点 | 代价 |
|---|---|---|---|
| **A 原生练习册（推荐）** | 延续已有绿色、细分隔线和 16vp 分组；靠文字、留白和一主多次的操作关系组织页面 | 与现有首页和题库一致；能逐页迁移；保留 HarmonyOS 原生控件与材质边界 | 仍有少量分组容器，需控制密度，不能每个字段都包卡 |
| B 极简工具 | 接近系统设置列表，大面积中性表面，动作尽量行内 | 列表清楚、装饰少、紧凑 | 与既有练习册视觉有断层；首页与复习内容需要更多调整 |
| C 学习工作台 | 平板增加固定摘要/流程侧栏，表单置于主区 | 宽屏流程定位和信息利用率高 | 手机需要不同结构，焦点与阅读顺序更复杂；不适合第一批小范围验证 |

**推荐 A，首批只覆盖导入入口、AI 识别设置、AI 平台选择三页。** 这组页面直接连接开始导入和配置识别，视觉问题集中，能够避开 PDF 处理、审核和保存状态机。此选择包含 PDF 入口主次调整及整体排版变化，应等待用户确认后实施。

### 3.1 设计哲学：清晰留白

页面以内容的先后关系组织空间。标题说明当前位置，正文解释下一步，状态紧贴它所影响的动作。细致校准每个基线、边缘和段落节奏，让留白承担信息分组，不靠装饰图案制造层级。

绿色只承担可操作与选择的提示，背景以安静的中性色承接长时间阅读。深色表面保留明确明度差，按钮文字与按钮背景单独配对。配色的精度来自逐对计算和设备检查，而不是一整页铺设强调色。

形体沿用练习册的章节与细线语言。一个完整配置组共享一个容器，字段依靠标签、间距和输入边界区分；重复内容按行排列。精细打磨圆角比例和对齐关系，减少胶囊、阴影和嵌套卡片造成的视觉噪声。

响应式变化只改变空间分配，不改变任务顺序。触摸、键盘与读屏应遇到同一套明确动作；加载、错误和禁用都有文字解释。最终质感来自对长文、大字、窄窗口和失败状态的反复校验，静态美观不能替代这些细节。

## 4. 推荐设计规范

以下是本项目候选规范；vp/fp 是 ArkUI 单位，不能把桌面 PNG 像素尺寸直接抄进源码。保留系统 HarmonyOS 字体，借用 apple-ui-design 的层级、克制和单一主操作原则，不植入 SF Pro、不模拟 iOS 导航。不添加渐变或新的模糊/阴影。

### 4.1 色彩

| 角色 | 浅色 | 深色 | 处理方式 |
|---|---|---|---|
| 页面背景 | `#F5F7FB` | `#0F1216` | 延续现有 palette |
| 分组表面 | `#FFFFFF` | `#1A1F26` | 延续现有 palette |
| 主文字 | `#17233C` | `#E8EBF0` | 延续现有 palette |
| 次文字 | `#6B768A` | `#A6AFBD` | 延续现有 palette，长篇说明不再更小更淡 |
| 主操作背景（候选） | `#087A54` | `#3ECF93` | 新的 UI 操作令牌，首批局部使用 |
| 主操作文字（候选） | `#FFFFFF` | `#072B1E` | 对比分别约 5.35:1、7.68:1 |
| 次操作文字（候选） | `#087A54` | `#3ECF93` | 配现有分组表面；实际组合必须计算 |
| 错误文字（候选） | `#B42332` | `#FF8A8A` | 与错误软背景逐对计算后使用，不仅靠红色 |
| 焦点边框 | 使用可读的操作色 | 使用可读的操作色 | 2vp 可见焦点轮廓，不使用阴影代替 |

不要把 `brand` 全局改暗来解决按钮问题：统计、徽标、材质也使用它。可新增只读 UI 常量/颜色辅助文件，不修改 `AppColors` 数据接口；`base/element/color.json` 与 `dark/element/color.json` 暂不全局替换。禁用继续使用原 `.enabled(...)`，配明确原因；不能降低整个容器透明度让说明一起不可读。

普通文本目标 4.5:1，大文本与关键非文本边界目标 3:1，采用 [WCAG 2.2](https://www.w3.org/TR/WCAG22/) 作为项目可读性验收参考；不声称 48vp 是 WCAG 的单位要求，也不把合同通过等同完整无障碍认证。

### 4.2 字体、间距、圆角

| 项目 | 规范 |
|---|---|
| 原生导航标题 | 20fp Medium/Semibold，优先系统字号机制 |
| 页面引导标题 | 24–26fp Semibold，不在每个表单重复大标题 |
| 分组标题 | 16fp Medium/Semibold；既有首页章节 13fp 暂不全局变更 |
| 正文/输入/主要按钮 | 16fp；辅助信息 14fp；12fp 仅限非关键元数据 |
| 行高 | 说明约 1.45–1.6 倍；允许自然换行，费用与安全信息不省略 |
| 基础节奏 | 4、8、12、16、24、32vp |
| 页面边距 | <360vp：16vp；常规：20vp；宽屏：24vp；另加侧边安全区 |
| 分组间距 | 24vp；组内字段间 16vp；标签到输入 8vp |
| 分组圆角 | 沿用 `SHEET_RADIUS = 16`；输入/按钮 12–14vp；平台行按列表分隔，不逐行大胶囊 |
| 触控目标 | 至少 48×48vp；长文按钮采用 minHeight 而非刚性 height |
| 边界 | 分隔线使用现有 `divider`；须交互识别的边框单独满足对比目标；核对 `HAIRLINE=1` 的实际单位，注释中的“1px”不是验证结果 |

### 4.3 组件及状态

- 页面壳：受约束的内容宽度和一致标题轴线；保留原生返回语义。AI 设置页如迁移 Navigation，不得让自动返回绕过 `leavePage`/pending 守卫；可保留受守卫的自定义标题返回按钮。
- 表单：服务地址、平台、Model 放在同一组；密钥独立组；输入 label 持续可见；所有 onChange、Password 类型、`showPasswordIcon(false)`、离页清空继续保留。
- 操作：只用一个主按钮；次操作使用中性/描边；破坏性“清除 API Key”单独区域，保留现有调用与确认行为，不新增读出密钥能力。
- 状态区：标题+简短解释+已有恢复动作；成功/失败不可仅变色；使用现有 `failed`、`pending`、`statusMessage` 等状态，不通过识别中文错误文案生成新业务分支。
- 加载：同一布局保留标题；使用原生 LoadingProgress 和明确文字；不显示虚构百分比、预计耗时，不添加模拟等待。
- 空结果：显示搜索条件和“清空搜索与筛选”按钮；只重置 UI keyword/filterKey，不刷新目录、不联网。
- 分类选择：文字、形态与 accessibility 状态同时表达选中；Horizontal Scroll 不依赖小字号把所有分类塞进一行。
- 对话框：保留系统弹窗、取消和确认回调、防重复提交与 autoCancel 策略；危险操作采用准确对象和后果；不改写安全判断。

## 5. 响应式与安全区

沿用 `ResponsiveLayout.ets` 的 <600、600–839、≥840vp 三档，以窗口宽度而非设备型号分类；不因本轮把设备统一当作 2880px 平板。

| 场景 | 处理与验收 |
|---|---|
| 手机 320/360/390vp | 单列、16/20vp 内边距；标签换行；不出现页面横向滚动；底部动作不覆盖最后字段 |
| 600/839vp、平板竖屏 | 表单居中；单列阅读宽度建议最高 680vp（现有全局 760vp 暂不改变）；平台列表可到 760vp |
| ≥840vp、平板横屏 | 首批仍保持连续单列表单和一致标题轴线；不为了填满屏幕拆散平台—地址—模型关系；入口短内容顶端对齐 |
| 二合一自由窗口 | 拖拽越过 600/840vp 时状态、焦点与输入保留；键盘 Tab/Shift+Tab/Enter 可用；不依赖 hover 才显示关键动作 |
| 状态栏/挖孔/手势条 | 外层页面壳消费 SafeAreaInsets，内部只管内容间距；原生 Navigation 已消费部分必须用 UI 树/截图确认，避免两次 top/bottom |
| 软键盘、大字 | 最下方 Model、Key、保存可滚动到键盘上方；1.0/1.3/2.0 字号比例检查；长平台、URL、模型 ID 不挤压按钮 |
| 主导航 | 保留 HdsTabs、中央导入、索引映射、scrollable(false)、TAB_BAR_CLEARANCE；后续按窗口验证遮挡，不凭截图删除导航项 |

首批页面四边避让需要显式设计并设备验证；不能把 `expandSafeArea` 当作保证内容安全的替代品。新的监听器必须配对释放，优先复用已有 WindowSizeObserver；若仅靠受限宽度即可完成，不增加监听器。

## 6. 页面级任务与准确文件

### 第一批（已实施）

生产范围最多三页 + 一份只读 UI 样式文件；不修改任何 services、models、utils 的业务实现。

| 任务 | 文件 | 实施内容 |
|---|---|---|
| T1 | **新增** `entry/src/test/UiRemediationContracts.test.cjs` | 先写旧代码必失败的层级、对比、触控、安全区与布局合同；保留所有既有合同 |
| T2 | **新增** `entry/src/main/ets/constants/UiStyle.ets` | 定义首批排版、最小触控、内容宽度和操作色配对；复用 AppTheme/EditorialStyle，不创建第二个主题管理器 |
| T3 | **修改** `entry/src/main/ets/pages/ImportBankPage.ets` | PDF 入口前置；JSON 区域解释归组；内容顶部对齐；加载/错误靠近入口；修正标题/安全区；保持 startImport/selectPdf 与 enabled 条件 |
| T4 | **修改** `entry/src/main/ets/pages/AiRecognitionSettingsPage.ets` | 重排平台/地址/模型组、密钥组与保存/验证区域；统一返回、按钮和输入规范；安全/费用文案常驻；pending 与反馈可感知；不改配置存取方法 |
| T5 | **修改** `entry/src/main/ets/pages/AiPlatformPickerPage.ets` | 统一页面壳、搜索、结果摘要、分隔列表、48vp 点击目标、分类选中语义、空结果清空动作；不改 choose/tagFor 能力逻辑/目录数据 |
| T6 | 本文与 `docs/superpowers/plans/ui-review-2026-09-12/` | 回填红绿测试、逐文件 checker、截图对比、边界检查及尚未验证项 |

### 后续任务（不在第一批重写）

| 编号 | 页面级修改 | 准确文件 |
|---|---|---|
| H1（已完成） | 首页入口收敛、标签与跳转匹配、48vp 触控、大字两行标签、左右安全区和导航语义核对 | `entry/src/main/ets/pages/HomePage.ets`、`pages/Index.ets`、`components/HomeOverviewCard.ets`、`components/HomeRecentSection.ets`、`entry/src/test/HomePageContracts.test.cjs`、**新增** `entry/src/test/HomeUiFollowupContracts.test.cjs`；`components/SectionTitle.ets` 复核后无需改动 |
| H2（错题子项已完成） | 已完成错题筛选目标、空态嵌入和左右安全区；题库列表密度、卡片操作及宽屏双列末项仍待后续 | `entry/src/main/ets/pages/BooksPage.ets`、`pages/WrongQuestionsPage.ets`、`components/QuestionBankCard.ets`、`components/WrongQuestionCard.ets`、`components/QuestionCard.ets`、`components/EmptyState.ets`、`components/StatRow.ets` |
| H3 | 详情阅读层级、底栏自适应、编辑大字号和键盘避让、长公式阅读 | `entry/src/main/ets/pages/QuestionDetailPage.ets`、`pages/WrongQuestionDetailPage.ets`、`pages/EditQuestionPage.ets`、`components/MathContentView.ets`（仅评估展示，不改公式安全策略） |
| H4（已完成） | PDF 设置摘要/页码、进度阶段与恢复、审核题目密度和唯一恢复入口均已重构；设置页已真机验收，进度/审核页待设备恢复后补截图 | `entry/src/main/ets/pages/PdfAiImportSetupPage.ets`、`pages/PdfAiImportProgressPage.ets`、`pages/PdfImportReviewPage.ets`、`entry/src/test/UiRemediationContracts.test.cjs` |
| H5（已完成） | 删除静态假入口；普通设置与危险操作分组；学习中心并入账号卡，账号卡直接位于“我的”标题下且不再增加中间分区标题，学习概览位于账号之后；账号/迁移操作达到 48vp 并保留清楚的同步与迁移状态 | `entry/src/main/ets/pages/MinePage.ets`、`components/HuaweiAccountCard.ets`、`components/LegacyMigrationCard.ets`、**新增** `entry/src/test/WrongMineUiFollowupContracts.test.cjs` |
| H6 | 跨页颜色角色统一、资源颜色与启动窗口、四边避让、读屏/键鼠矩阵 | `entry/src/main/ets/theme/AppColors.ets`、`LightColors.ets`、`DarkColors.ets`、`constants/AppTheme.ets`、`EditorialStyle.ets`、`ResponsiveLayout.ets`、`utils/SafeAreaUtils.ets`、`entryability/EntryAbility.ets`、`entry/src/main/resources/base/element/color.json`、`entry/src/main/resources/dark/element/color.json` |

表中缩写路径（如 `pages/...`、`components/...`）均以 `entry/src/main/ets/` 为根，不指向 server。

## 7. 合同测试与实施顺序

- [x] 阅读文档、源码、主题和既有合同。
- [x] 采集安装版基线并记录版本局限。
- [x] 形成 3 个方向、推荐方案与完整页面任务。
- [x] 用户确认方案 A 及三页首批范围（2026-09-12）。
- [x] 在 `%TEMP%\wqc-ui-20260912-before` 保存三页修改前副本；所有补丁基于当前工作树，没有从 HEAD 覆盖文件。
- [x] T1：新增合同，旧代码 5/5 失败，失败来自操作色对比、入口顺序、表单分组、四边安全区/触控目标和筛选恢复能力。
- [x] T2–T5：新增 `UiStyle.ets` 并完成导入入口、AI 设置、平台选择三页改造。
- [x] T6：完成相关/全量合同、逐文件 checker、debug build、安装、截图和本文回填。
- [x] H1：先新增首页后续合同并确认旧实现 3 项失败，再完成入口收敛、列表级跳转语义、48vp 触控、左右安全区与主导航动作尺寸，执行全量验证和真机截图。
- [x] H2 错题子项 + H5：新增错题/我的合同并确认旧实现 5/5 失败，再完成筛选触控、空态模式、左右安全区、设置与危险操作分组、48vp 账号/迁移动作，执行全量验证和真机截图。

### 7.1 必须先红的测试

1. 从实际 UI 操作颜色计算 WCAG 相对亮度，断言所有首批主按钮/选中分类文字至少 4.5:1；旧白/绿组合应失败。测试必须追到页面使用的 token，避免只测未被使用的常量。
2. ImportBankPage 的 PDF 入口出现在 JSON 技术说明之前，短内容顶部对齐；JSON 文件格式、startImport/selectPdf 回调、两组互斥 enabled 表达式仍保留。旧页面应在层级断言失败。
3. 设置页 Model 输入位于平台/地址组内且在密钥组之前；保存/测试/清除为不同层级，费用提示紧邻测试入口；旧长表单顺序应失败。
4. 平台列表具有 48vp 最小高度、结果计数、空态重置与选中语义；用真实 `visiblePlatforms()`/重置 UI 方法抽取运行验证搜索+分类组合、无结果、恢复全目录，choose 回调仍只返回 id。旧页面缺少这些展示/恢复能力，应失败。
5. 首批页面四边避让策略与内容宽度断言；不能只断言存在 `.padding`。断言对应容器关系、minHeight、换行及原状态条件。
6. 对没有修改权限的设置存取、返回守卫、AI Key 生命周期方法做前后语义/方法正文比较；安全合同仍执行。源码结构合同只证明结构，不能证明屏幕不遮挡或读屏正常。

### 7.2 相关回归

```powershell
node --test entry/src/test/UiRemediationContracts.test.cjs
node --test entry/src/test/EditorialUiContracts.test.cjs entry/src/test/DarkModeContracts.test.cjs entry/src/test/NativeNavigationContracts.test.cjs entry/src/test/CloudImportPageContracts.test.cjs entry/src/test/PdfImportContracts.test.cjs entry/src/test/AiImportContracts.test.cjs entry/src/test/AiImportSecurityContracts.test.cjs entry/src/test/AiEvidenceLifecycle.test.cjs entry/src/test/AiImportSaveIdempotency.test.cjs
node --test --test-reporter=tap entry/src/test/*.cjs
git diff --check
```

新增用例通过后，对操作色、48vp 目标、PDF 顺序、密钥控件类型或互斥条件做受控变异验证（在临时副本运行），确认断言能发现回归。不要为了视觉测试改动安全实现。

### 7.3 ArkTS 逐文件检查与构建

发现工具链：`D:\Program Files\Huawei\DevEco Studio`（26.0.0），项目 target 26.0.0 / compatible 6.1.1(24)。

逐个文件启动 checker，不能一次传入全项目然后把不可靠的 0/0 当结论：

```powershell
$uiProject = 'G:/code/openHarmony/wrong_question_collection'
$uiChecker = 'C:/Users/32773/.agents/skills/harmonyos-dev-skill/scripts/arkts-check.cjs'
$uiFiles = rg --files entry/src/main/ets -g '*.ets'
foreach ($uiFile in $uiFiles) {
  node $uiChecker --project $uiProject --files $uiFile
  # 实施时保存每个文件的输出、进程退出码、error/warning/internal/unparsable 数量。
}
```

先检查本轮 3 页和新增 UIStyle，再全量逐文件。验收为 errors=0、internal=0、unparsable=0，分别报告警告数量和类别，不能把已有 warning 隐藏掉。对本轮改动文件在隔离的临时项目副本注入已知非法 ArkTS 探针，验证 checker 真正覆盖文件；不在用户源文件写探针后再回滚。基线未做探针，结果仅作初步参考。

设备 after 截图前必须对当前源代码执行可用的 debug build，成功后安装且保留用户数据。不执行 uninstall/clean。若 hvigor 卡在 daemon、签名缺失或安装失败，记录原始输出与阶段；此时不能将安装版截图称为“修改后”。

## 8. 视觉、无障碍与安全验收

| 检查 | 测试方法 | 通过条件 |
|---|---|---|
| 前后截图 | 同一页、窗口尺寸、主题、滚动位置；先核对安装包来源 | 导航避开状态栏；PDF 主次清楚；表单分组与状态可见；无重叠/裁切 |
| 深浅模式 | 三页至少各 1 张；平台选择含选中分类；设置含禁用、错误、成功 | 无意外蓝色默认强调；正文/按钮/错误文字对比合格；纯颜色不承担状态 |
| 窄窗/大字 | 320、390、600、840、1160vp；字级 1.0/1.3/2.0 | 完整标签、按钮最小目标、说明不裁切；仅横向分类/公式容器可独立滚动 |
| 长内容 | 长平台中文名、长模型 id、长 URL、长错误；用合成展示夹具 | 不挤出切换/返回；安全提示完整；不向真实 Provider 提交 |
| 搜索空态 | 无匹配关键词 + 非默认分类；点击清空 | 展示无结果原因并恢复目录；不更改实际平台配置 |
| 输入与键盘 | 依次焦点到 URL、Key、Model；展开软键盘、Tab 循环 | 标签与焦点可见、保存可达；不将焦点自动移到危险动作 |
| 读屏 | 返回、搜索、分类、平台行、Key 输入/显示、保存/测试依序遍历 | 控件名称、角色、选中/禁用状态可理解；装饰不重复播报；不播报保存的密钥 |
| 业务守卫 | 全量安全/AI/审核合同；方法对比 | 所有此前安全断言保留；无自动识别/自动重试/自动连接测试 |
| 弹窗 | 现有取消、确认、返回键、快速连点 | 无绕过、无重复提交；只在可用展示夹具或非破坏路径检查 |

PDF 设置、进度、审核的复杂状态本轮仅源码审查；后续视觉验收用隔离展示夹具/现有测试数据，禁止为凑截图在生产账号发收费 AI 请求或修改审核会话持久数据。

## 9. 本次已执行结果与回填区

### 9.1 修改前基线（当前实测）

| 项目 | 结果 | 证据 |
|---|---|---|
| 生产页/业务修改 | **0**；当前只创建审查文档、设计图、截图与日志 | 尚在方案确认阶段 |
| 客户端全量 CJS | **278 tests / 277 pass / 1 fail**，测试进程 exit 1；37 个 `.cjs` 文件 | `ui-review-2026-09-12/baseline-client-cjs.tap` |
| 唯一失败 | `CloudCutoverContracts`：`server directory has zero uncommitted changes` | 同日志 `not ok 156`；保留 server 脏树 |
| ImportBankPage 逐文件 ArkTS | exit 0；0 errors / 0 warnings | `baseline-arkts-ImportBankPage.log` |
| AiRecognitionSettingsPage 逐文件 ArkTS | exit 0；0 errors / **51 warnings**（含依赖诊断） | `baseline-arkts-AiRecognitionSettingsPage.log` |
| AiPlatformPickerPage 逐文件 ArkTS | exit 0；0 errors / 0 warnings | `baseline-arkts-AiPlatformPickerPage.log` |
| warning 类别 | 18 getContext deprecated；1 back deprecated；31 异常处理提示；1 INTERNET 权限提示 | 设置页 checker 输出；本轮不改权限配置 |
| 全量逐文件 ArkTS / 阳性对照 | **本轮未运行**；已有软件审查记录 123 文件/261 warnings 为历史文档结果，不作本轮实测 | 实施完成后重跑 |
| `git diff --check` | 审查基线与文档落盘后均 exit 0；新增 Markdown 尾随空白 0 行 | git diff 不包含 untracked 文档，已补充单独空白检查 |
| 设备截图 | 5 张应用页面截图逐张打开检查；仅深色横屏安装版 | 上述截图目录 |
| debug build / after 截图 / Hypium | **未运行** | 待确认后实施与构建 |
| 收费请求 / server 修改 / Git 发布 | **均未执行** | 本次边界 |

### 9.2 第一批实施结果（当前实测）

用户在 2026-09-12 确认方案 A“原生练习册”。首批范围保持为三页加一份只读样式常量，没有扩展到首页、题库、详情、PDF 设置/进度/审核或我的页面。

| 项目 | 结果 | 证据与说明 |
|---|---|---|
| 红测试 | **5 tests / 0 pass / 5 fail**，exit 1 | `ui-review-2026-09-12/ui-contracts-red.tap`；五项旧行为均被暴露，不是语法或导入失败 |
| 新 UI 合同 | **5 / 5 pass** | `entry/src/test/UiRemediationContracts.test.cjs`；覆盖对比度、PDF/JSON 层级、设置分组、四边避让/48vp、平台筛选恢复与选中 id |
| 相关 CJS | **191 / 191 pass** | 包含 Editorial、DarkMode、NativeNavigation、Cloud/PDF/AI 导入、安全、证据生命周期与保存幂等合同 |
| 全量客户端 CJS | **283 tests / 282 pass / 1 fail** | 唯一失败仍是 `CloudCutoverContracts` 的 `server directory has zero uncommitted changes`；其余 282 项通过；没有清理或改动 server 来绕过守卫 |
| 本轮 ArkTS | 4 文件均 **0 errors / 0 warnings** | `UiStyle.ets`、`ImportBankPage.ets`、`AiRecognitionSettingsPage.ets`、`AiPlatformPickerPage.ets` 逐文件执行 checker |
| 全量逐文件 ArkTS | **124 files / 0 errors / 210 warnings / 0 failed / 0 unparsable** | 每个 `.ets` 单独启动 checker；警告主要是既有异常处理、deprecated API 与权限提示，本轮四文件无警告 |
| debug build | **exit 0，BUILD SUCCESSFUL in 10 s 660 ms** | DevEco 26.0.0 `hvigorw.js --no-daemon ... assembleHap`；33 tasks，17 executed，16 up-to-date |
| 安装 | **exit 0** | `hdc install -r ...entry-default-signed.hap`，保留应用数据，输出 `install bundle successfully` |
| 真机视觉 | 深色横屏 2880×1920 三页通过 | `after-import.jpeg`、`after-ai-settings.jpeg`、`after-platform-picker.jpeg` 均逐张打开；无标题遮挡、裁切或横向拉伸 |
| 方法前后比较 | **23 个受保护方法正文全部 UNCHANGED** | 导入的 `startImport/importBank/selectPdf/...`，设置的加载/保存/清除/测试/返回守卫，平台的过滤/标签/选择方法逐项与修改前副本比较；仅新增 UI 筛选重置和导航失败反馈 |
| 收费/安全边界 | 未发起真实 AI 请求，未选择 PDF，未保存/清除 Key，未执行连接测试 | 安全、HUKS、账号、审核会话、幂等和证据生命周期实现未修改 |

实际生产文件：

- `entry/src/main/ets/constants/UiStyle.ets`：新增 680vp 阅读宽度、48vp 触控目标、间距/圆角和经合同计算的深浅操作色配对。
- `entry/src/main/ets/pages/ImportBankPage.ets`：PDF 推荐入口前置；JSON 作为次级导入并保留完整格式说明；提供经过解析验证的最小单选题 JSON 示例；反馈靠近入口；四边安全区与宽屏限宽。
- `entry/src/main/ets/pages/AiRecognitionSettingsPage.ets`：按服务与模型、密钥、连接验证分组；费用提示贴近测试；反馈移到滚动区上方；保留 Password 类型和 pending 返回守卫。
- `entry/src/main/ets/pages/AiPlatformPickerPage.ets`：搜索/分类/结果数/统一列表；48vp 行；选中语义；无结果时可清空搜索与筛选，且不改变实际平台配置。
- `entry/src/test/UiRemediationContracts.test.cjs`：新增首批 UI 合同。

视觉遗留与测试限制：已安装版本只覆盖深色横屏；搜索与分类组合已实际交互，但输入法候选层妨碍了干净的“零结果”截图，因此空态由合同覆盖，不能写成已完成视觉验收。浅色真机、320/390vp 窄窗、600/840vp 断点、2.0 倍字号、键鼠焦点和读屏顺序仍待后续设备矩阵。没有向真实 Provider 提交请求，也没有为 PDF 状态截图创建生产审核会话。

### 9.3 追加实施：JSON 题库示例

根据用户追加要求，在结构化 JSON 导入区加入一份可直接保存为 UTF-8 `.json` 文件的单题示例。示例覆盖 `bankName`、`subject`、`questions` 及题目的 `id/type/question/options/answer/analysis`，不增加导入分支或改变解析器。

- 测试先红：更新后的 UI 合同在旧展示上 **4 pass / 1 fail**，失败原因为缺少完整示例。
- 修改后合同：**5 / 5 pass**；测试提取页面常量并实际执行 `JSON.parse`，校验字段集合、题型、选项和答案。
- 相关 CJS：`UiRemediationContracts + PdfImportContracts + CloudImportPageContracts` 共 **65 / 65 pass**。
- 全量客户端 CJS：仍为 **283 tests / 282 pass / 1 fail**；唯一失败仍是既有 server 脏树守卫。
- `ImportBankPage.ets` 逐文件 ArkTS：**0 errors / 0 warnings**；其他 ArkTS 文件未改变，上一轮 124 文件逐文件结果仍适用。
- 当前源 debug build：**BUILD SUCCESSFUL in 9 s 848 ms**；HAP 覆盖安装成功。
- 真机：`after-import-json-example.jpeg` 已在 2880×1920 深色横屏滚动至示例底部检查，示例完整、无裁切；未选择文件或触发导入。

### 9.4 后续实施 H1：首页与主导航

H1 只调整首页入口层级、跳转文案、触控尺寸和安全区，不修改同步、缓存、导入、复习业务逻辑。HdsTabs 中间导入槽位、槽位到业务 Tab 的映射、`navigationPending` 防重复导航和原有回调全部保留。

实际修改：

- `entry/src/main/ets/pages/HomePage.ets`：快捷入口由五项收敛为“AI 设置 / 查看题库 / 查看错题”；删除常驻导入按钮和数据名称 chips；空数据时继续显示“导入资料”情境化 CTA；主列表左右 padding 叠加真实 safe-area inset；快捷入口改为 48vp 图形目标、80vp 整体最小高度和最多两行标签。
- `entry/src/main/ets/components/HomeRecentSection.ets`：题库/错题摘要行取消箭头和逐行点击，章节头提供唯一的 48vp “查看题库列表 / 查看错题列表”动作，避免用户误以为摘要能直达对应详情。
- `entry/src/main/ets/components/HomeOverviewCard.ets`：主复习按钮由 46vp 提升到 48vp，不改变 `pendingCount` 启用条件和 `onStartReview` 回调。
- `entry/src/main/ets/pages/Index.ets`：底栏中间导入图形目标由 44vp 提升到 48vp；导入路由、恢复原槽位和防重复导航逻辑不变。
- `entry/src/test/HomePageContracts.test.cjs`：更新已经过时的五入口和话题条合同，继续覆盖数据源、异步陈旧结果保护、空态和导航连接。
- `entry/src/test/HomeUiFollowupContracts.test.cjs`：新增 H1 合同，覆盖入口唯一性、文案与跳转一致性、列表级动作、非直达摘要、触控尺寸、两行标签、左右安全区和 HdsTabs 守卫。

验证结果：

| 项目 | 结果 | 证据与说明 |
|---|---|---|
| 红测试 | **4 tests / 1 pass / 3 fail**，exit 1 | `ui-review-2026-09-12/home-h1-contracts-red.tap`；失败准确来自旧快捷入口/文案、摘要伪直达、46vp 目标和缺少左右安全区；既有导航守卫基线通过 |
| 新 H1 合同 | **4 / 4 pass** | `HomeUiFollowupContracts.test.cjs` |
| 相关 CJS | **9 / 9 pass** | H1、HomePage、MainNavigation、Editorial、DarkMode、NativeNavigation 共六个合同文件 |
| 全量客户端 CJS | **287 tests / 286 pass / 1 fail** | `ui-review-2026-09-12/home-h1-full-client.tap`；唯一失败仍为 `CloudCutoverContracts` 的 server 脏树守卫，没有清理、覆盖或回退 server |
| 本轮 ArkTS | 4 个生产文件均 **0 errors / 0 warnings** | HomePage、Index、HomeOverviewCard、HomeRecentSection 逐文件 checker |
| 全量逐文件 ArkTS | **124 files / 0 errors / 210 warnings / 0 failed / 0 unparsable** | `ui-review-2026-09-12/home-h1-arkts-all.log`；warning 为既有 deprecated API、异常处理与权限提示，本轮四文件未新增 warning |
| debug build | **exit 0，BUILD SUCCESSFUL in 12 s 33 ms** | `ui-review-2026-09-12/home-h1-debug-build.log`；33 tasks，17 executed，16 up-to-date。首次命令因 `DEVECO_SDK_HOME` 未设置而在 0 task 阶段失败；确认 SDK 布局后仅在构建进程中设置为 `D:\Program Files\Huawei\DevEco Studio\sdk`，未修改系统环境 |
| 安装 | **exit 0** | 对连接设备执行 `hdc install -r`，保留应用数据，输出 `install bundle successfully` |
| 真机视觉 | 深色横屏 2880×1920 首页通过 | `ui-review-2026-09-12/after-home-h1.jpeg`；顶部、三快捷入口、概览、两列最近内容和底栏无重叠/裁切，重复导入入口与误导性 chips 已消失 |
| 安全与费用边界 | 未触发真实 AI 请求、文件选择或数据修改 | 仅启动首页并截图；未改变 AI Key、HUKS、账号、审核会话、保存幂等和证据生命周期 |

H1 尚未补齐浅色真机、320/390vp 窄窗、2.0 倍字号、键盘焦点和读屏顺序的运行证据。源码合同覆盖了两行标签、48vp 目标和四边安全区，但不能替代这些设备测试。

### 9.5 后续实施 H2 错题子项与 H5“我的”页

本批只处理错题列表和“我的”页的可见层级与交互反馈；没有改变错题加载/筛选数据源、账号绑定、同步、迁移、清空确认与云端优先写入逻辑。H2 中题库页相关工作继续保留为后续任务。

实际修改：

- `entry/src/main/ets/pages/WrongQuestionsPage.ets`：学科筛选由固定 40vp 改为 48vp 最小高度，允许两行并声明读屏选中状态；空态改用共享嵌入模式，移除固定 260vp 容器；列表左右 padding 叠加实时 safe-area inset。
- `entry/src/main/ets/components/EmptyState.ets`：新增默认开启的 `fillAvailable` 页面模式；嵌入列表时使用 180vp 最小高度并由内容撑开，避免长说明或大字号被固定高度裁切。
- `entry/src/main/ets/pages/MinePage.ets`：报头改为紧凑横排；紧凑窗口将学习概览移到账号前；删除无回调的“数据管理”假入口；普通设置与“数据与隐私”分组，清空错题增加永久删除说明及明确动作文字；两栏布局保持左右信息分工；左右 padding 叠加实时 safe-area inset。
- `entry/src/main/ets/components/HuaweiAccountCard.ets`：立即同步、退出登录由 46vp 提升到 48vp，回调和启用条件不变。
- `entry/src/main/ets/components/LegacyMigrationCard.ets`：开始迁移、重试由 44vp 提升到 48vp；禁用时文字使用禁用层级，迁移状态、确认和重试逻辑不变。
- `entry/src/test/WrongMineUiFollowupContracts.test.cjs`：新增五项合同，覆盖学科筛选、空态双模式、两页左右安全区、危险操作分组以及账号/迁移触控目标；继续断言确认弹窗和 `CloudQuestionRepository.clearWrongQuestions`。

验证结果：

| 项目 | 结果 | 证据与说明 |
|---|---|---|
| 红测试 | **5 tests / 0 pass / 5 fail**，exit 1 | `ui-review-2026-09-12/wrong-mine-contracts-red.tap`；五项失败分别来自旧 40vp 筛选、固定空态、缺少左右避让、假入口/危险操作混列、44/46vp 按钮 |
| 新合同 | **5 / 5 pass** | `WrongMineUiFollowupContracts.test.cjs` |
| 相关 CJS | **36 / 36 pass** | 新合同、Task7、Task8、Editorial、DarkMode、AuthSession、HuaweiLogin、LegacyCloudMigration、ServerFirst 共九个文件 |
| 全量客户端 CJS | **292 tests / 291 pass / 1 fail** | `ui-review-2026-09-12/wrong-mine-full-client.tap`；唯一失败仍为 `CloudCutoverContracts` 的 server 脏树守卫，没有清理、覆盖或回退 server |
| 本轮 ArkTS | 5 个生产文件均 **0 errors / 0 warnings** | `ui-review-2026-09-12/wrong-mine-arkts-changed.log` |
| 全量逐文件 ArkTS | **124 files / 0 errors / 210 warnings / 0 failed / 0 unparsable** | `ui-review-2026-09-12/wrong-mine-arkts-all.log`；warning 数量与 H1 相同，主要为既有 deprecated API、异常处理和权限提示 |
| debug build | **exit 0，BUILD SUCCESSFUL in 13 s 945 ms** | `ui-review-2026-09-12/wrong-mine-debug-build.log`；33 tasks，17 executed，16 up-to-date |
| 安装 | **exit 0** | 设备 `192.168.0.104:35911` 执行 `hdc install -r`，保留应用数据，输出 `install bundle successfully` |
| 初次真机视觉 | 深色横屏 2880×1920 两页已截图，但顶部验收结论被后续反馈纠正 | `after-wrong-h2.jpeg`、`after-mine-h5.jpeg` 显示页面内容从 y=0 开始，主导航标题位于左侧，错题统计卡接近/覆盖状态栏；不能继续标记为通过。返修及有效截图见 9.6 |
| `git diff --check` | **exit 0** | 生产代码修改后检查通过；文档回填后再次复核 |
| 安全与服务端边界 | 未发起真实 AI 请求，未改变账号/迁移/清空流程，未修改 server/worker | 清空按钮仍先登录、再确认、再调用原有云端优先仓库方法；没有点击破坏性操作 |

本批未处理错题宽屏双列的奇数末项、题库卡片密度和题库嵌入空态，也没有完成浅色、手机窄窗、最大字号、读屏与键鼠验证。真机使用现有账号缓存展示账号卡，但未读取、显示或复制 Token。

### 9.6 错题与“我的”顶部安全区返修

用户在真机结果中指出错题内容覆盖状态栏，并要求“错题”和“我的”都放到页面最上方。复核确认根因是 `Index.ets` 仍由 Navigation 在窗口左侧绘制标题，而两个页面的正常内容没有消费 top inset，导致统计卡/报头从 y=0 开始。

返修内容：

- `entry/src/main/ets/pages/WrongQuestionsPage.ets`：新增页面内“错题”标题、分隔线和 `SafeAreaUtils.top(...) + WRONG_FEED_TOP_GAP`；标题在所有加载、错误、空态和正常内容之前绘制，后续内容使用剩余高度。
- `entry/src/main/ets/pages/MinePage.ets`：新增页面内“我的”标题、分隔线和实时顶部安全区；学习中心、加载与失败状态统一从标题下方开始。
- `entry/src/main/ets/pages/Index.ets`：错题与“我的”的 Navigation 标题返回空字符串，消除左侧重复标题及覆盖式标题层。
- `entry/src/test/WrongMineUiFollowupContracts.test.cjs`：新增第六项合同，要求两个页面拥有 `PAGE_TITLE_SIZE` 页面标题、top inset、标题先于状态内容，并锁定 Navigation 标题为空。

验证结果：

| 项目 | 结果 | 证据与说明 |
|---|---|---|
| 返修红测试 | **6 tests / 5 pass / 1 fail**，exit 1 | `ui-review-2026-09-12/wrong-mine-top-title-contract-red.tap`；唯一失败准确来自两个页面缺少页面内标题/top inset，旧五项合同保持通过 |
| 返修合同 | **6 / 6 pass** | `WrongMineUiFollowupContracts.test.cjs` |
| 相关 CJS | **13 / 13 pass** | 新合同、Editorial、DarkMode、MainNavigation、NativeNavigation、Api24HdsTabs、Task7、Task8 |
| 全量客户端 CJS | **293 tests / 292 pass / 1 fail** | `ui-review-2026-09-12/wrong-mine-top-title-full-client.tap`；唯一失败仍为 `CloudCutoverContracts` 的 server 脏树守卫 |
| 本轮 ArkTS | 3 个改动文件均 **0 errors / 0 warnings** | `ui-review-2026-09-12/wrong-mine-top-title-arkts.log`；其余 121 文件沿用 9.5 当轮全量逐文件结果，当前构建再次编译全项目 |
| debug build | **exit 0，BUILD SUCCESSFUL in 11 s 567 ms** | `ui-review-2026-09-12/wrong-mine-top-title-debug-build.log`；33 tasks，17 executed，16 up-to-date |
| 安装 | **exit 0** | 当前 HAP 使用 `hdc install -r` 覆盖安装并保留数据 |
| 真机视觉 | **通过**，深色横屏 2880×1920 | `after-wrong-top-safe.jpeg`、`after-mine-top-safe.jpeg`：标题位于真实状态栏下方，统计卡/学习中心位于标题分隔线下方，左侧无重复标题；两张图均已逐张打开检查 |
| `git diff --check` | **exit 0** | 返修代码通过；文档回填后再次执行 |

本次只启动页面和截图，没有触发同步、退出、清空、迁移、Token 复制或 AI 请求。

### 9.7 “学习中心”与账号合并及最终顺序精简

用户先要求将学习中心与账号模块合并，随后明确要求账号卡直接移到“我的”标题下、学习概览之前，最后删除“学习与账号”分区标题及其下方横线。最终页面保留一张完整账号卡：卡片上部说明学习中心用途，内部横线区分账号状态与同步操作；卡片外不再添加重复的分区标题。

实际修改：

- `entry/src/main/ets/pages/MinePage.ets`：删除原独立学习中心报头；将账号区改为 `LearningAccountSection`，顺序固定在 `StatsSection` 之前；最终移除 `SectionTitle({ title: '学习与账号' })`，使账号卡直接承接“我的”标题。
- `entry/src/main/ets/components/HuaweiAccountCard.ets`：把“学习中心”名称、用途说明、账号状态、同步和退出操作整合进同一张卡；保留卡内分隔线，避免学习定位与账号动作混成一段；所有原回调、启用条件和账号状态分支不变。
- `entry/src/test/WrongMineUiFollowupContracts.test.cjs`：合同锁定独立报头已移除、合并账号卡存在、账号区先于学习概览，且不得重新出现“学习与账号”分区标题。
- `entry/src/test/EditorialUiContracts.test.cjs`：把旧独立报头断言更新为合并账号卡的层级断言。

测试驱动记录：

| 阶段 | 结果 | 证据与说明 |
|---|---|---|
| 合并前红测试 | **8 tests / 6 pass / 2 fail** | `ui-review-2026-09-12/mine-learning-account-merge-contract-red.tap`；旧实现仍有独立报头，账号卡尚未包含学习中心层级 |
| 顺序调整红测试 | **7 tests / 6 pass / 1 fail** | `ui-review-2026-09-12/mine-account-order-contract-red.tap`；旧顺序中账号区晚于学习概览 |
| 分区标题删除红测试 | **7 tests / 6 pass / 1 fail** | `ui-review-2026-09-12/mine-account-heading-removal-contract-red.tap`；唯一失败准确来自仍存在“学习与账号”标题 |
| 最终定向 CJS | **8 / 8 pass** | `WrongMineUiFollowupContracts.test.cjs` 与 `EditorialUiContracts.test.cjs` |
| 最终全量客户端 CJS | **294 tests / 293 pass / 1 fail** | `ui-review-2026-09-12/mine-account-heading-removal-full-client.tap`；唯一失败仍为 `CloudCutoverContracts` 的 server 脏树守卫，没有清理、覆盖或回退 server |
| 本轮逐文件 ArkTS | `MinePage.ets`、`HuaweiAccountCard.ets` 均 **0 errors / 0 warnings** | `mine-learning-account-merge-arkts.log`；删除分区标题后再次检查 `MinePage.ets`，仍为 0/0 |
| debug build | **exit 0，BUILD SUCCESSFUL in 10 s 831 ms** | `ui-review-2026-09-12/mine-account-heading-removal-debug-build.log`；33 tasks，17 executed，16 up-to-date；构建仍输出仓库既有 deprecated API 与异常处理 warning，本次文件未新增 warning |
| 安装 | **exit 0** | 当前 HAP 对设备 `192.168.0.104:35911` 执行 `hdc install -r`，保留应用数据 |
| 真机视觉 | **通过**，深色横屏 2880×1920 | `after-mine-account-direct.jpeg` 已逐图检查：“我的”下方直接进入账号卡，无“学习与账号”标题和对应分区线；学习概览及后续两栏无重叠或裁切 |
| `git diff --check` | **exit 0** | 代码与文档回填后复核 |

本次只改变组合方式、显示顺序和分区标题。没有触发同步、退出或清空操作，也没有修改账号绑定、HUKS、云端同步、迁移、确认弹窗或数据结构。

### 9.8 当前设备名称

用户要求账号卡中的“当前设备”显示实际设备。复核发现旧页面把登录时保存的固定字符串 `HarmonyOS device` 直接传给账号卡；连接设备通过系统信息返回营销名称 `HUAWEI MatePad Pro`、产品型号 `WEB-W00` 和设备类型 `tablet`。

本次仅调整显示来源：`MinePage.ets` 通过 `@ohos.deviceInfo` 优先读取 `marketName`，为空时使用 `productModel`，两者均不可用时显示“HarmonyOS 设备”。账号登录交换仍使用原参数，未改变服务端请求体、设备键、账号绑定或已保存会话。

| 项目 | 结果 | 证据与说明 |
|---|---|---|
| 红测试 | **8 tests / 7 pass / 1 fail** | `ui-review-2026-09-12/mine-current-device-contract-red.tap`；唯一失败来自旧实现没有系统设备名称读取方法 |
| 最终定向 CJS | **9 / 9 pass** | `mine-current-device-contract-green.tap`；覆盖系统名称、型号回退、通用回退及登录交换边界 |
| 全量客户端 CJS | **295 tests / 294 pass / 1 fail** | `mine-current-device-full-client.tap`；唯一失败仍为 `CloudCutoverContracts` 的 server 脏树守卫 |
| ArkTS 逐文件检查 | **0 errors / 0 warnings** | `mine-current-device-arkts.log`，目标为 `entry/src/main/ets/pages/MinePage.ets` |
| debug build | **BUILD SUCCESSFUL in 10 s 948 ms** | `mine-current-device-debug-build.log`；33 tasks，17 executed，16 up-to-date |
| 真机视觉 | **通过**，深色横屏 2880×1920 | `after-mine-current-device.jpeg`；页面显示“当前设备：HUAWEI MatePad Pro”，无重叠或裁切 |

本次没有触发重新登录、同步、退出、清空、迁移或 AI 请求，也没有修改 `server/` 或 worker。

### 9.9 中央加号直接进入导入题库

用户反馈点击底栏中央加号可能没有反应。排查发现 `TabBarImportAction` 只有外观和无障碍名称，没有自己的 `onClick`；导航完全依赖 `HdsTabs.onChange` 的槽位选中变化。动作按钮由选择状态变化间接触发，存在同一槽位不再产生变化事件时无法导航的风险。

最终处理：

- `entry/src/main/ets/pages/Index.ets`：中央加号根节点新增直接 `onClick`，单次调用既有 `openImportPage()`；原有 `navigationPending`、错误 Toast 和 `router.pushUrl('pages/ImportBankPage')` 保持不变。
- `HdsTabs.onChange` 遇到 `IMPORT` 槽位时只调用 `tabsController.changeIndex(this.tabBarIndex)` 恢复原槽位，不再执行第二次路由。9.11 又把普通触控在到达该回调前截断；这里仅作为键盘、读屏或系统级选中中央槽位时的兜底。
- `entry/src/test/HomeUiFollowupContracts.test.cjs`：新增直接点击合同和防重复压栈合同，锁定加号拥有 `onClick`，同时禁止 IMPORT 的选择回调再次调用 `openImportPage()`。

| 项目 | 结果 | 证据与说明 |
|---|---|---|
| 直接点击红测试 | **4 tests / 3 pass / 1 fail** | `plus-direct-action-contract-red.tap`；唯一失败准确来自加号没有 `onClick` |
| 防重复压栈红测试 | **4 tests / 3 pass / 1 fail** | `plus-no-double-push-contract-red.tap`；中间实现同时从按钮和 onChange 路由，真机返回一次仍停留导入页；合同准确暴露双压栈 |
| 最终相关 CJS | **8 / 8 pass** | `plus-single-route-related-green.tap`；覆盖 Home UI、MainNavigation、API 24 HdsTabs、NativeNavigation 和 DarkMode |
| 全量客户端 CJS | **295 tests / 294 pass / 1 fail** | `plus-single-route-full-client.tap`；唯一失败仍为已知 `CloudCutoverContracts` server 脏树守卫 |
| ArkTS 逐文件检查 | **0 errors / 0 warnings** | `plus-single-route-arkts.log`，目标为 `entry/src/main/ets/pages/Index.ets` |
| debug build | **BUILD SUCCESSFUL in 10 s 402 ms** | `plus-single-route-debug-build.log`；33 tasks，17 executed，16 up-to-date |
| 真机路由验收 | **通过** | `plus-single-first.json` 为 `pages/ImportBankPage`；返回一次后的 `plus-single-back-once.json` 为 `pages/Index`；再次点击后的 `plus-single-second.json` 为 `pages/ImportBankPage` |
| 真机视觉 | **通过**，深色横屏 2880×1920 | `after-plus-single-route.jpeg`；导入页无重叠或裁切 |

本次只修复中央动作的事件归属和路由次数；未改变导入页业务、JSON/PDF 处理、AI 流程、安全守卫、服务端或 worker。

### 9.10 JSON 格式说明与示例折叠

用户确认方案 A：在 `ImportBankPage.ets` 中保留“选择 JSON 文件”按钮常显，把格式说明与示例合并为一个默认收起的区域。折叠入口使用“JSON 格式与示例”主标签及“展开/收起”状态文字；展开后继续显示现有字段说明、UTF-8 要求和完整单题示例。该调整只减少首屏技术信息，不改变 JSON 解析、登录检查、文件选择、错误状态或 PDF 导入流程。

实施步骤：

- [x] 在 `entry/src/test/UiRemediationContracts.test.cjs` 增加合同：默认 `jsonHelpExpanded = false`，入口达到 48vp，文案与无障碍名称随状态变化，帮助内容只在展开分支中显示。
- [x] 运行合同并确认旧实现因缺少折叠状态和入口而失败。
- [x] 在 `entry/src/main/ets/pages/ImportBankPage.ets` 增加最小折叠状态、切换按钮和条件内容，保持 `startImport()`、`selectPdf()` 及互斥禁用条件不变。
- [x] 执行相关与全量 CJS、`ImportBankPage.ets` 逐文件 ArkTS、debug build、`git diff --check`。
- [x] 安装当前 HAP，验证默认收起、展开、收起，以及选择 JSON 按钮始终可见；截图后回填本节结果。

验证结果：

| 项目 | 结果 | 证据与说明 |
|---|---|---|
| 红测试 | **6 tests / 5 pass / 1 fail** | `json-help-collapse-contract-red.tap`；唯一失败准确来自旧实现缺少默认折叠状态 |
| 相关 CJS | **66 / 66 pass** | `json-help-collapse-related-green.tap`；覆盖 UI 整改、PDF 导入和 Cloud 导入合同，原导入流程与生命周期守卫保持通过 |
| 全量客户端 CJS | **296 tests / 295 pass / 1 fail** | `json-help-collapse-full-client.tap`；唯一失败仍为已知 `CloudCutoverContracts` server 脏树守卫 |
| ArkTS 逐文件检查 | **0 errors / 0 warnings** | `json-help-collapse-arkts.log`，目标为 `entry/src/main/ets/pages/ImportBankPage.ets` |
| debug build | **BUILD SUCCESSFUL in 12 s 633 ms** | `json-help-collapse-debug-build.log`；33 tasks，17 executed，16 up-to-date |
| 默认收起 | **通过** | `after-json-help-collapsed-again.jpeg`、`json-help-collapsed-final.json`；UI 树只有“展开”，没有“JSON 格式说明”和“JSON 示例”正文 |
| 展开与再次收起 | **通过** | `after-json-help-expanded.jpeg`、`json-help-expanded.json`；展开 UI 树包含“收起”、格式说明和示例；再次点击恢复收起状态 |

本次没有选择文件、触发 JSON/PDF 导入、调用 AI、修改账号状态或改动 `server/` 与 worker。

### 9.11 中央加号移除外层残余动画

用户进一步要求点击中央加号后直接进入导入题库，不能先看到底栏选中中央空槽位再回弹。源码排查确认：加号虽然已拥有直接 `onClick`，但触控事件仍会继续冒泡到 HdsTabs；外层组件会尝试选中 `MainTabBarPosition.IMPORT`，随后 `onChange` 又用 `changeIndex` 恢复原标签。路由与标签回弹同时开始，形成导入页外侧残余动画。

最终处理：

- `entry/src/test/HomeUiFollowupContracts.test.cjs`：先更新合同，要求中央动作根节点在直接路由之前拥有明确的触控冒泡拦截，同时继续锁定 48vp 触控尺寸、单次 `openImportPage()` 和 IMPORT 回调不得二次路由。
- `entry/src/main/ets/pages/Index.ets`：在 `TabBarImportAction` 根节点增加 `onTouch((event: TouchEvent) => event.stopPropagation())`，随后由原 `onClick` 单次调用 `openImportPage()`。普通手指或触控板点击不会再传到 HdsTabs，其他四个标签的动画和切换逻辑不变。
- 兼容性排查中先尝试了 `ClickEvent.stopPropagation()`；单文件 checker 错误地报告 0/0，但 compatible API 24 的真实 ArkTS 编译指出 `ClickEvent` 没有该成员。最终改用从 API 7 起提供冒泡控制的 `TouchEvent`，并以成功的全项目编译作为有效结论。
- `HdsTabs.onChange` 的 IMPORT 分支继续保留为非普通触控入口的防御性恢复逻辑，不执行路由，也不会造成重复压栈。

验证结果：

| 项目 | 结果 | 证据与说明 |
|---|---|---|
| 红测试 | **4 tests / 3 pass / 1 fail** | `HomeUiFollowupContracts.test.cjs`；唯一失败准确来自旧实现没有在直接路由前拦截触控冒泡 |
| 相关 CJS | **7 / 7 pass** | Home UI、MainNavigation、NativeNavigation、API 24 HdsTabs 合同全部通过 |
| 全量客户端 CJS | **296 tests / 295 pass / 1 fail** | `ui-review-2026-09-12/plus-no-residual-animation-full-client.tap`；唯一失败仍为已知 `CloudCutoverContracts` server 脏树守卫，未清理、覆盖或回退 server |
| ArkTS 逐文件检查 | **0 errors / 0 warnings** | `ui-review-2026-09-12/plus-no-residual-animation-arkts.log`，最终目标为 `entry/src/main/ets/pages/Index.ets` |
| debug build | **BUILD SUCCESSFUL in 10 s 184 ms** | `ui-review-2026-09-12/plus-no-residual-animation-debug-build.log`；33 tasks，17 executed，16 up-to-date；真实编译验证最终 `TouchEvent` 写法可用于当前 API 配置 |
| 安装 | **exit 0** | debug HAP 已通过 `hdc install -r` 安装到 `HUAWEI MatePad Pro`（`192.168.0.104:35911`）并保留应用数据 |
| 真机直接进入 | **通过**，深色横屏 2880×1920 | 从“我的”标签点击加号后，`plus-direct-import.json` 在 350ms 检测到的唯一应用根页面为 `pages/ImportBankPage`；`plus-direct-import.jpeg` 中主导航已完全退出，没有中央空槽位或外层底栏残留 |
| 单次返回 | **通过** | 点击导入页返回按钮一次后，`plus-return-once.json` 为 `pages/Index`，并保持进入前“我的”标签 selected=true，未出现第二层导入页 |
| `git diff --check` | **exit 0** | 最终代码与当前工作树通过空白错误检查 |

本次只修改中央动作的触控传播边界；未改变导入页面、路由目标、导航防重、JSON/PDF/AI 流程、账号与 HUKS、安全检查、数据结构、`server/` 或 worker，也没有发起 AI 请求。

### 9.12 API Key 后获取云端模型并由用户选择

用户要求移除 AI 视觉识别设置中的静态“推荐视觉模型”，改为输入 API Key 后从对应云端服务读取实际可用模型，再由用户自行选择。静态目录容易与服务端可用性、账号权限和模型下线状态脱节，也会让“推荐”看起来像已经验证可用；本轮改为以当前 API 地址的鉴权结果为准。

交互与状态：

- `AiRecognitionSettingsPage.ets` 不再读取或显示平台目录中的推荐模型。用户输入 Key 后按键盘完成，或输入框失焦时，页面自动请求模型；同时保留“获取模型/重新获取模型”按钮用于重试。
- 获取中显示“正在从云端获取模型…”，按钮和表单进入禁用状态；成功后显示原生 `Select`，用户选择模型后才能保存；空列表与网络、鉴权、格式失败均使用本地稳定文案，不显示远端响应细节。
- API Key 或 API 地址变化时立即清除旧模型和旧列表，防止把上一服务的模型误保存到新配置。平台变化同样清空模型，必须以新的云端结果重新选择。
- 页面打开时不会解密已有 HUKS 密钥。模型发现只使用本次输入框中的 Key；显式保存后才进入既有 HUKS 和配置原子更新流程。清除密钥、替换密钥守卫、连接测试、审核会话、保存幂等和证据图片生命周期保持原逻辑。
- `AiPlatformPickerPage.ets` 将普通云端平台状态统一显示为“云端模型”，移除“未确认视觉模型/视觉”等静态判断；网关和本机标签保持原含义。

实现与安全边界：

- 新增 `entry/src/main/ets/services/ai/AiModelCatalogService.ets`，向规范化后的 `<baseUrl>/models` 发起一次 GET，并严格解析 OpenAI-compatible 的顶层 `data[].id`；结果去重、排序，最多接受 500 个模型，模型 ID 最长 200 字符，未知 JSON 分支深度最多 32。
- `AiProviderConfigValidator.normalizeBaseUrl()` 复用既有 HTTPS/本机私网 HTTP、userinfo、query、hash 和路径限制；模型发现与正式配置共享地址安全规则。
- `AiVisionTransport.getJson()` 继续是唯一的 `Authorization` 持有者，禁止重定向，沿用超时、JSON Content-Type 与最大响应限制，并在 `finally` 中清除请求头文本。临时 Key 会编码为字节并在服务 `finally` 中覆零。
- 模型请求从客户端直达用户选择的 AI 服务，不经过项目业务服务器；本轮没有修改 `server/`、worker、数据库或云同步协议，也没有在合同或真机验收中填写真实 Key 或发起外部 AI 请求。
- 当前兼容契约是 OpenAI-compatible `GET /models`。不提供此接口、使用其他响应结构或只允许服务端代理列举模型的平台会显示稳定失败状态，后续如需适配必须按平台单独设计，不能放宽解析和端点守卫。

准确文件：

- `entry/src/main/ets/pages/AiRecognitionSettingsPage.ets`
- `entry/src/main/ets/pages/AiPlatformPickerPage.ets`
- `entry/src/main/ets/models/ai/AiProviderConfig.ets`
- `entry/src/main/ets/services/ai/AiVisionTransport.ets`
- `entry/src/main/ets/services/ai/AiModelCatalogService.ets`（新增）
- `entry/src/test/AiImportContracts.test.cjs`
- `entry/src/test/AiModelCatalogContracts.test.cjs`（新增）

验证结果：

| 项目 | 结果 | 证据与说明 |
|---|---|---|
| 首轮红测试 | **72 tests / 67 pass / 5 fail** | `ui-review-2026-09-12/ai-cloud-models-contract-red.tap`；失败准确覆盖旧页面仍显示静态推荐、缺少模型服务/GET 与云端选择控件 |
| 旧模型失效补充红测试 | **4 tests / 3 pass / 1 fail** | `ui-review-2026-09-12/ai-cloud-models-reselection-red.tap`；旧实现输入替换 Key 后仍保留上一模型，合同准确失败 |
| 最终相关 CJS | **108 / 108 pass** | `ui-review-2026-09-12/ai-cloud-models-relevant-final.tap`；覆盖模型目录、AI 导入、AI 安全和 UI 整改合同；全部使用 fake transport，不可访问真实提供商 |
| 全量客户端 CJS | **301 tests / 300 pass / 1 fail** | `ui-review-2026-09-12/ai-cloud-models-full-cjs-final.tap`；唯一失败仍为 `CloudCutoverContracts` 的 `server/` 脏树守卫，未清理、覆盖或回退 server |
| ArkTS 逐文件检查 | **5 个生产文件均 0 errors** | `ui-review-2026-09-12/ai-cloud-models-arkts-final.log`；配置与平台页 0 warning，传输/模型服务各含 2 条已声明 `INTERNET` 权限提示；设置页最终复查 0 errors / 52 dependency 与 deprecated warnings，见 `ai-cloud-models-page-arkts-final.log` |
| debug build | **BUILD SUCCESSFUL in 12 s 972 ms** | `ui-review-2026-09-12/ai-cloud-models-build-final.log`；33 tasks，17 executed，16 up-to-date，验证当前 compatible API 24 编译通过 |
| `git diff --check` | **exit 0** | `ui-review-2026-09-12/ai-cloud-models-git-diff-check.log` |
| 真机视觉与状态 | **通过**，深色横屏 2880×1920 | HAP 通过 `hdc install -r` 安装到 `HUAWEI MatePad Pro`；`ai-cloud-model-settings-final.jpeg/json` 显示“云端模型”空状态、空 Key 时禁用“获取模型”，且“推荐视觉模型”节点数为 0 |
| 真机网络请求 | **未执行，符合约束** | 未输入真实或伪造 Key，未触发 `/models`、连接测试或收费识别请求；云端成功列表和选择行为由 fake transport 合同验证 |

### 9.13 清理自定义地址下方说明文字

用户要求删除“自定义地址”按钮下方的全部文字。本轮从 `AiRecognitionSettingsPage.ets` 的服务卡片中移除常驻的密钥地址说明和平台技术备注，因此按钮后直接结束地址区域，不再显示 `supportsStructuredOutput` 等实现字段。明文 HTTP 风险提示属于安全边界，继续按实际地址条件显示，但调整到“自定义地址/完成自定义地址”按钮之前；正常 HTTPS 地址下不会出现。

合同先锁定按钮下方不得残留常驻说明，同时要求明文 HTTP 警告仍存在且位于按钮之前。旧实现运行结果为 **73 tests / 71 pass / 2 fail**，两项失败分别准确来自旧说明仍存在和警告仍在按钮下方；生产代码调整后相关 AI/UI 合同 **108/108 通过**。`AiRecognitionSettingsPage.ets` 逐文件 ArkTS 为 **0 errors / 52 dependency 与 deprecated warnings**，debug build **BUILD SUCCESSFUL in 12 s 310 ms**，`git diff --check` 通过。全量客户端 CJS 为 **301 tests / 300 pass / 1 fail**，唯一失败仍是已知 `CloudCutoverContracts` 的 `server/` 脏树守卫。

真机通过 `hdc install -r` 更新到 `HUAWEI MatePad Pro` 后，深色横屏 UI 树确认“自定义地址”保留 1 个，常驻地址说明 0 个，`supportsStructuredOutput` 技术备注 0 个；截图和 UI 树分别为 `ui-review-2026-09-12/ai-custom-address-clean.jpeg`、`ai-custom-address-clean.json`。本次没有输入 Key、调用模型目录、测试连接或发起 AI 识别，也没有修改 `server/` 或 worker。

### 9.14 修复新 API Key 无法测试连接

用户发现填写 API Key 后，“测试连接”按钮虽然可点击，但 `testConnection()` 会因 `apiKey.length > 0` 直接返回“请先保存新 API Key，再测试连接”，导致新 Key 必须先保存才能验证。这个守卫与新模型发现流程冲突：用户已经用临时 Key 获取并选择模型，却不能在保存前确认该组合是否可用。

修复后，页面根据输入状态选择两条明确路径：

- 输入框存在新 Key：校验当前平台、地址与所选模型后，通过 `AiConnectionTestService.testWithApiKey()` 使用本次临时 Key 测试；成功提示“连接成功，请保存设置”。不读取旧 HUKS 密钥，不要求配置已经保存，也不写入 HUKS。
- 输入框为空：继续执行原有 `requireUsable()`、`hasCredential()` 和 `AiConnectionTestService.test()`，只允许已保存配置与已保存密钥一致时测试。未保存表单仍不得借用旧密钥。
- `testWithApiKey()` 只在请求期间把字符串编码为 `Uint8Array`，并在 `finally` 中覆零；页面保留输入以便用户随后主动保存，离开页面时继续清空输入。

准确文件：

- `entry/src/main/ets/pages/AiRecognitionSettingsPage.ets`
- `entry/src/main/ets/services/ai/AiConnectionTestService.ets`
- `entry/src/test/AiImportContracts.test.cjs`
- `entry/src/test/AiImportSecurityContracts.test.cjs`

验证结果：

| 项目 | 结果 | 证据与说明 |
|---|---|---|
| 红测试 | **准确失败** | `ui-review-2026-09-12/ai-typed-key-connection-red.tap`；旧服务缺少 `testWithApiKey()`，页面合同等待的临时请求不会发生，确认根因是保存前守卫 |
| AI 核心与安全合同 | **99 / 99 pass** | `ui-review-2026-09-12/ai-typed-key-connection-green.tap`；覆盖临时 Key、字节覆零、请求期间互斥、退出清理、已保存密钥路径与配置一致性守卫 |
| 最终相关 CJS | **109 / 109 pass** | `ui-review-2026-09-12/ai-typed-key-connection-related-final.tap`；额外覆盖模型目录和 UI 整改合同 |
| 全量客户端 CJS | **302 tests / 301 pass / 1 fail** | `ui-review-2026-09-12/ai-typed-key-connection-full-cjs.tap`；唯一失败仍是 `CloudCutoverContracts` 的 `server/` 脏树守卫 |
| ArkTS 逐文件检查 | **2 个生产文件均 0 errors** | `ui-review-2026-09-12/ai-typed-key-connection-arkts.log`；服务 33 条、页面 52 条均为依赖异常、`INTERNET` 权限和 deprecated API 警告 |
| debug build | **BUILD SUCCESSFUL in 11 s 562 ms** | `ui-review-2026-09-12/ai-typed-key-connection-build.log`；33 tasks，17 executed，16 up-to-date |
| `git diff --check` | **exit 0** | 最终工作树通过空白错误检查 |
| 授权真机测试 | **通过** | 用户明确提供剪贴板测试 Key 后，MatePad Pro 从云端取得 `deepseek-flash`，保存前“测试连接”显示“连接成功，请保存设置”；截图为 `ai-typed-key-connection-success.jpeg` |
| 密钥清理 | **通过** | 测试成功时页面仍显示“未配置”，未点击保存；退出并重新进入后 API Key 的 `text` 与 `originalText` 长度均为 0，见 `ai-typed-key-reopen.json`；证据目录按剪贴板原值扫描为 0 命中 |

本轮授权真机验证实际发起一次模型目录请求和一次极小连接测试，可能产生极少量模型费用；没有发起 PDF 识别、保存密钥、修改账号状态、调用项目业务服务器或修改 `server/` 与 worker。

### 9.15 重构 AI PDF 导入设置页

本轮延续已确认的 A 方案“原生练习册”，只重构 `PdfAiImportSetupPage.ets` 的界面组织，不改变 PDF 临时文件生命周期、`PdfImportState`、页码校验、账号检查、`AiProviderConfigStore.loadUsable`、HUKS/API Key 检查、进度页路由、审核会话、保存幂等和错误信息安全边界，也没有修改 `server/`、worker 或 AI 请求流程。

页面从多个碎片化卡片收敛为三个连续分组：已选择 PDF、识别服务、题库信息与识别页码。文件区同时显示文件名、文件大小、总页数与本机逐页转图说明；识别服务改用“识别平台”“识别模型”“调整 AI 设置”，平台和模型均限制最多两行；题库名、科目、起始页和结束页处于同一配置流程，并显示“将识别第 1–3 页 · 共 3 页”形式的动态摘要。旧文案“AI 视觉识别（推荐）”“Provider”“Model”“本机直连”已从页面 Builder 移除。

手机和中等宽度使用单列，`WindowSizeClass.EXPANDED` 使用 4:6 双栏；内容限制最大宽度并顶部对齐。错误提示与主操作位于滚动区域之外，主按钮下固定显示“开始后将进入识别进度，识别完成后逐题审核”。主要按钮、设置按钮、科目按钮和输入框均使用至少 `UiStyle.TOUCH_TARGET` 的触控高度；主操作和选中科目使用 `UiStyle.action(this.darkMode)` / `UiStyle.onAction(this.darkMode)`。输入框、卡片、分隔线、错误条和禁用态继续读取主题色，根布局消费 top、bottom、left、right 四边安全区。`pending` 或 `leaving` 时仍禁止返回、调整设置、切换科目和开始识别。

准确文件：

- `entry/src/main/ets/pages/PdfAiImportSetupPage.ets`
- `entry/src/test/UiRemediationContracts.test.cjs`
- `entry/src/test/AiImportContracts.test.cjs`
- `entry/src/test/PdfImportContracts.test.cjs`

验证结果：

| 项目 | 结果 | 证据与说明 |
|---|---|---|
| 初始红测试 | **准确失败** | `ui-review-2026-09-12/pdf-ai-setup-red.tap`；旧 Builder 缺少“已选择 PDF”等新结构。宽屏顶部对齐合同也先在旧实现上失败，再补入 `Alignment.Top` |
| UI 合同 | **7 / 7 pass** | 最终重新运行 `UiRemediationContracts.test.cjs`，覆盖响应式、四边安全区、两行截断、触控目标、主题色、固定反馈与操作区 |
| AI/PDF 相关 CJS | **184 / 184 pass** | `ui-review-2026-09-12/pdf-ai-setup-related-final.tap`；包含 UI、PDF 生命周期、账号/HUKS、安全边界、审核和幂等合同，测试使用 fake transport，不会访问真实服务商 |
| 全量客户端 CJS | **303 tests / 302 pass / 1 fail** | `ui-review-2026-09-12/pdf-ai-setup-full-client.tap`；唯一失败是已知 `CloudCutoverContracts` 的 `server/` 脏树守卫，未清理或修改 `server/` |
| ArkTS 逐文件检查 | **0 errors / 0 warnings** | `ui-review-2026-09-12/pdf-ai-setup-arkts-final.log`；目标为 `PdfAiImportSetupPage.ets` |
| HAP 构建 | **BUILD SUCCESSFUL in 11 s 651 ms** | 33 tasks，17 executed，16 up-to-date；使用 DevEco SDK 环境和 `--no-daemon` 绕过本机残留的失效 daemon 注册；全工程仍有既存异常处理与 deprecated API 警告，目标逐文件检查无警告 |
| `git diff --check` | **exit 0** | 最终工作树无空白错误 |
| 真机布局 | **通过，浅色横屏 2880×1920 EXPANDED** | 最终页见 `ui-review-2026-09-12/pdf-ai-setup-final.jpeg/json`；三分组、双栏、文件元数据、动态页码摘要、底部固定主操作均可见 |
| 真机错误态 | **通过** | 未选择科目时仅触发本地前置校验，`ui-review-2026-09-12/pdf-ai-setup-validation-error.jpeg/json` 显示错误条固定在滚动区外、主按钮上方 |
| 真机 AI 请求 | **未执行，符合约束** | 未选择科目，因此没有进入账号、密钥或网络识别阶段；没有点击识别进度，也没有产生收费请求。验证后已返回上一页以释放应用暂存 PDF，并删除本轮生成的本地及设备测试 PDF |

本轮真机覆盖了二合一/平板的浅色 EXPANDED 布局和错误态；深色配色、手机单列与自由窗口由 ArkTS 主题/响应式分支和合同验证，尚未进行本轮真机截图。后续仍应补读屏、最大字号、手机窄窗、深色模式、二合一自由窗口和不发起真实 AI 的更完整交互矩阵。

### 9.16 重构 AI PDF 识别进度与题目复核页

本轮继续沿用 A 方案“原生练习册”，重构用户截图中的 `PdfAiImportProgressPage.ets` 和 `PdfImportReviewPage.ets`。只新增窗口尺寸观察、展示辅助方法和 ArkUI Builder；识别启动/取消、临时 PDF 清理、账号复核、审核路由、审核适配器、失败页重试/放弃/手动新增、权威状态对账、保存幂等和错误安全边界保持原样。未修改 `server/`、worker 或 AI 请求流程。

识别进度页从屏幕中央的单张大卡改为顶部对齐的任务阶段：标题直接说明“识别进度”，进度条使用真实已完成页数，当前处理页、已完成页数和已识别题目在紧凑窗纵向排列、在中宽/宽屏横向排列。错误提示、取消、清理重试、重新进入审核和返回设置等操作均在滚动内容之外，避免短窗口下不可见；旧文案“AI 视觉识别（推荐）”已移除。

题目复核页移除了内容区内的蓝色“返回”按钮，恢复原生导航返回，同时仍由既有 `onBackPress` 和 `returnToImportPage` 守卫处理放弃确认。题库摘要不再横跨整屏；每题按“题号与来源信息—原题证据—题型与字段编辑—人工复核状态”连续组织。`WindowSizeClass.EXPANDED` 且存在原图时采用 4:6 证据/编辑双栏，手机和中等宽度保持单列；失败页在紧凑窗纵排“重试识别 / 手动新增题目 / 放弃本页”，宽屏横排并以颜色、边框和文字共同表达层级。权威状态未知时只有一个“重新加载审核状态”动作，不再与普通空态恢复同时出现。

两页都消费 top、bottom、left、right 四边安全区，内容最大宽度受限并顶部对齐。输入面、卡片、分隔线、警告、错误和禁用态全部使用现有主题色；主操作使用 `UiStyle.action(this.darkMode)` / `UiStyle.onAction(this.darkMode)`。主要按钮、题型选择和恢复动作均不少于 `UiStyle.TOUCH_TARGET`，补充了关键图片、进度和操作的可访问名称；pending、navigation、cleanup 和 authoritative-state 守卫未放松。

准确文件：

- `entry/src/main/ets/pages/PdfAiImportProgressPage.ets`
- `entry/src/main/ets/pages/PdfImportReviewPage.ets`
- `entry/src/test/UiRemediationContracts.test.cjs`
- `entry/src/test/AiImportContracts.test.cjs`
- `entry/src/test/PdfImportContracts.test.cjs`
- `entry/src/test/CloudImportPageContracts.test.cjs`
- `docs/superpowers/plans/2026-09-13-pdf-progress-review-ui-refactor.md`

验证结果：

| 项目 | 结果 | 证据与说明 |
|---|---|---|
| 初始红测试 | **9 tests / 7 pass / 2 fail** | `ui-review-2026-09-12/pdf-progress-review-ui-red.md`；旧进度页缺少“识别进度”新结构，旧审核页缺少 `WindowSizeObserver` |
| UI 合同 | **9 / 9 pass** | 覆盖响应式观察、四边安全区、顶部布局、固定反馈/操作区、触控目标、主题角色、原生返回和唯一恢复入口 |
| AI/PDF 相关 CJS | **186 / 186 pass** | 测试使用 fake transport；没有访问真实 AI 服务 |
| 云端审核兼容合同 | **12 / 12 pass** | 放宽仅与 Builder 局部变量命名相关的正则，仍验证选项编辑调用和服务端草稿行为 |
| 全量客户端 CJS | **305 tests / 304 pass / 1 fail** | 唯一失败为既知 `CloudCutoverContracts` 的 `server directory has zero uncommitted changes`；未清理或修改 `server/` |
| ArkTS 逐文件检查 | **2 个文件均 0 errors / 0 warnings** | 联合检查 `PdfAiImportProgressPage.ets` 与 `PdfImportReviewPage.ets` |
| HAP 构建 | **BUILD SUCCESSFUL in 13 s 110 ms** | 33 tasks，18 executed，15 up-to-date；全工程仍输出既存异常处理和 deprecated API 警告 |
| `git diff --check` | **exit 0** | 工作树无空白错误 |
| 真机安装与截图 | **未执行：设备未连接** | `hdc list targets` 返回 `[Empty]`；没有安装最终 HAP，也没有生成本轮进度/审核页截图 |
| 真机 AI 请求 | **未执行，符合约束** | 未启动识别、未调用服务商、未修改审核数据，未产生收费请求 |

证据汇总见 `ui-review-2026-09-12/pdf-progress-review-final-verification.md`。后续应在设备恢复后，用已有本地审核草稿只读检查复核页，并为进度页准备不联网的假状态或预览入口再截图；仍需补深色、手机窄窗、最大字号、读屏和二合一自由窗口矩阵。不得为了截图触发真实 AI 识别。

### 9.17 AI PDF 页面顶部起排真机返修

设备重新连接并安装 9.16 的 HAP 后，真机确认 AI PDF 设置页仍有明显布局问题：导航栏结束于 y≈190，但“已选择 PDF”和“题库信息与识别页码”直到 y=539 才出现。源码虽然写有 `.align(Alignment.Top)`，它作用于固有高度 `Column` 的绘制区；该绘制区没有占满剩余视口，短内容仍被 `Scroll` 放在平板可用区域中部。因此原静态合同只能证明存在 modifier，不能证明视觉上真正顶部起排。

先新增回归合同，要求设置页和同构的识别进度页 `ContentArea` 使用顶部起排的单项 `List`，旧实现得到 10 tests / 9 pass / 1 fail，准确失败于设置页仍为 `Scroll`。随后只将两个页面的滚动容器替换为 `List` + `ListItem`，响应式卡片、状态区、底部操作和所有业务方法均未修改。

修复后重新构建、覆盖安装并使用同一个本地 PDF 验证。真机 UI 树中“已选择 PDF”和“题库信息与识别页码”顶部从 y=539 移到 y=264，导航栏下的异常大空白消失；底部主操作仍固定可见。完成截图后通过系统返回键回到 `ImportBankPage`，由既有页面返回流程清理本轮暂存 PDF。没有点击“开始 AI 识别”，未发起服务商请求。

| 项目 | 结果 | 证据 |
|---|---|---|
| 修复前真机 | 主体从 y=539 开始，顶部空白过大 | `ui-review-2026-09-12/pdf-setup-latest-before-fix.jpeg`、`pdf-setup-latest.json` |
| 新增红灯合同 | **10 tests / 9 pass / 1 fail** | `ui-review-2026-09-12/pdf-top-origin-red.md` |
| UI 合同 | **10 / 10 pass** | 新增设置/进度页顶部起排回归合同 |
| ArkTS 逐文件检查 | **2 个文件 0 errors / 0 warnings** | `PdfAiImportSetupPage.ets`、`PdfAiImportProgressPage.ets` |
| HAP 构建 | **BUILD SUCCESSFUL in 11 s 913 ms** | 33 tasks，18 executed，15 up-to-date |
| 真机安装 | **成功** | 目标 `192.168.0.104:35911`，覆盖安装签名 HAP |
| 修复后真机 | 主体从 y=264 开始，顶部起排 | `ui-review-2026-09-12/pdf-setup-top-fixed.jpeg`、`pdf-setup-top-fixed.json` |
| AI/PDF 相关 CJS | **187 / 187 pass** | fake transport，不会访问真实服务商 |
| 全量客户端 CJS | **306 tests / 305 pass / 1 fail** | 唯一失败仍是 `server directory has zero uncommitted changes`；未修改或清理 `server/` |
| `git diff --check` | **exit 0** | 无空白错误 |
| 真实 AI 请求 | **未执行** | 未点击识别，未产生费用 |

### 9.18 AI PDF 识别进度页真机返修

用户澄清本轮问题指向 `PdfAiImportProgressPage.ets`，不是已经验收的导入设置页。真机静态诊断复现出两个独立问题：一是进度页把安全区 padding 放在 `Navigation` 内部的内容 `Column` 上，原生标题栏没有被下移，导致“AI PDF 识别”与状态栏处于同一垂直区域；同仓库中显示正常的设置页则把四边安全区放在整个 `Navigation` 外壳。二是此前的顶部起排返修不适合宽屏单任务进度页，进度卡位于顶部、取消操作位于底部，两者之间出现大面积空白，操作与任务状态失去视觉关联。

本次仅调整进度页展示：将 top、bottom、left、right 安全区从内部 `Column` 移到 `Navigation`；在 `WindowSizeClass.EXPANDED` 下新增居中的 `ExpandedStage`，把进度概览、串行识别说明、错误提示和当前恢复/取消操作放进同一工作区，并把宽屏操作区域限制为 360vp。COMPACT/MEDIUM 仍保留可滚动内容和独立可见的状态/操作区域。识别启动、取消、清理、账号复核、审核路由和错误映射方法均未修改。

为避免真实收费请求，真机验证使用可回退的临时诊断构建：启动后路由到进度页并阻止 `startImport()`，仅渲染默认“准备识别”状态；截图后已撤销诊断入口和静态开关，再构建并安装正常业务版。诊断过程中没有访问 AI 服务、没有保存审核数据，也没有触碰 `server/` 或 worker。

| 项目 | 结果 | 证据 |
|---|---|---|
| 宽屏工作区红灯 | **11 tests / 10 pass / 1 fail** | 缺少 `ExpandedStage`，准确失败于任务与操作未形成同一工作区 |
| 安全区红灯 | **12 tests / 11 pass / 1 fail** | 准确失败于 `SafeAreaUtils` 仍位于 `Navigation` 内容体 |
| UI 合同 | **12 / 12 pass** | 覆盖宽屏聚焦工作区、360vp 操作上限、四边安全区归属与既有恢复动作 |
| AI/PDF 相关 CJS | **189 / 189 pass** | fake transport，不会访问真实服务商 |
| 全量客户端 CJS | **308 tests / 307 pass / 1 fail** | 唯一失败仍是 `server directory has zero uncommitted changes`；未修改或清理 `server/` |
| ArkTS 逐文件检查 | **0 errors / 0 warnings** | `PdfAiImportProgressPage.ets` |
| 最终 HAP 构建 | **BUILD SUCCESSFUL in 11 s 296 ms** | 33 tasks，17 executed，16 up-to-date；全工程仍有既存警告 |
| `git diff --check` | **exit 0** | 工作树无空白错误 |
| 真机修复前 | 标题侵入状态栏；卡片置顶、取消按钮沉底 | `ui-review-2026-09-12/ai-progress-routed-before.jpeg` |
| 真机修复后 | 标题完整位于状态栏下；进度、说明和取消操作构成居中紧凑工作区 | `ui-review-2026-09-12/ai-progress-safearea-after.jpeg` |
| 最终正常业务包 | **覆盖安装成功** | 目标 `192.168.0.104:35911`；启动回到 `pages/Index` 首页，见 `ai-progress-normal-build-home.jpeg` |
| 真实 AI 请求 | **未执行** | 静态诊断构建阻止识别启动；最终包恢复正常入口与 `started = false` |

### 9.19 题目识别复核页真机返修

用户在已完成识别的真机复核页指出布局仍有问题。改造前 2880×1920 浅色 EXPANDED 截图显示：原生标题仍侵入状态栏；失败页把整页证据放进 300vp 高的全宽区域，缩略内容周围留白过多；失败页卡片占据首屏主体，第一道已识别题目被固定保存栏遮住大半。基线保存在 `ui-review-2026-09-12/pdf-review-live-before.jpeg`。

本次继续沿用 A 方案“原生练习册”，仅调整 `PdfImportReviewPage.ets` 的展示 Builder。四边安全区从 `Navigation` 内部内容体移到 `Navigation` 外壳，使原生标题一起避让状态栏。失败页在 EXPANDED 下改为 240×200vp 有界缩略证据与右侧说明/动作两栏；COMPACT/MEDIUM 仍保持单列，证据高度缩短为 180vp。列表增加轻量的“待处理页”和“已识别题目”段落标题，让失败处理与逐题审核保持同一连续阅读流程。既有题目原图/编辑 4:6 双栏、固定错误提示、固定保存操作、主题颜色与 48vp 触控目标继续保留。

未修改 session/adapter 选择、题目编辑持久化、失败页重试/放弃/手动新增、权威状态对账、返回守卫、保存幂等、PDF 生命周期或错误安全边界；未修改 `server/`、worker 和 AI 请求实现。

| 项目 | 结果 | 证据与说明 |
|---|---|---|
| 新增红灯合同 | **14 tests / 12 pass / 2 fail** | `ui-review-2026-09-12/pdf-review-followup-red.tap`；分别准确失败于安全区仍属于内容体、失败证据仍使用全宽 300vp 舞台 |
| UI 合同 | **14 / 14 pass** | 覆盖 Navigation 安全区归属、EXPANDED 失败页双栏、有界缩略图和两个复核段落标题 |
| AI/PDF 相关 CJS | **193 / 193 pass** | `ui-review-2026-09-12/pdf-review-followup-related.tap`；使用 fake transport，不会访问真实服务商 |
| 全量客户端 CJS | **310 tests / 309 pass / 1 fail** | `ui-review-2026-09-12/pdf-review-followup-all-client.tap`；唯一失败仍是 `CloudCutoverContracts` 的 `server directory has zero uncommitted changes`，未清理或修改 `server/` |
| ArkTS 逐文件检查 | **0 errors / 0 warnings** | `ui-review-2026-09-12/pdf-review-followup-arkts-final.log`；最终目标为 `PdfImportReviewPage.ets` |
| 最终 HAP 构建 | **BUILD SUCCESSFUL in 11 s 862 ms** | `ui-review-2026-09-12/pdf-review-followup-debug-build-final.log`；33 tasks，17 executed，16 up-to-date；全工程仍有既存异常处理和 deprecated API 警告 |
| `git diff --check` | **exit 0** | 最终工作树无空白错误 |
| 真机修复前 | 标题侵入状态栏；失败页证据留白过大；题目内容被挤到首屏底部 | `ui-review-2026-09-12/pdf-review-live-before.jpeg` |
| 真机修复后 | 标题完整避让；失败页缩略证据/说明/动作双栏；第一题标题、题型与编辑区进入首屏 | `ui-review-2026-09-12/pdf-review-live-after.jpeg`；使用一次性无网络本地展示数据，截图后夹具已从源码移除 |
| 最终正常业务包 | **覆盖安装成功，未再次启动** | 目标 `192.168.0.104:35911`；最终 HAP 已恢复 `pages/Index` 正常入口，源码无 `fixture` 残留 |
| AI 请求边界 | **展示夹具未访问 AI；正常包首次启动存在不确定性** | 第一次覆盖安装后启动时，系统恢复到既有进度路由，其 `aboutToAppear` 会自动进入 `startImport()`；`ui-review-2026-09-12/pdf-review-app-start.jpeg` 显示仍为 0/3 页、0 题，随后已立即强制停止，未点击任何识别/重试动作。因生产代码禁止记录 Provider 请求，无法证明停止前一定未完成网络派发；为避免重复，最终正常包安装后未再启动 |

真机本轮覆盖了浅色横屏 EXPANDED 主布局。深色模式、手机单列、最大字号、读屏顺序、键盘编辑与使用真实但已完成的离线审核会话仍待补验；不得为了截图重新发起收费识别。其它既有后续 UI 工作（编辑页 48vp 控件、H2 题库子项、H3/H6、启动资源和全局组件替换）维持原计划。

## 10. 暂不处理

本批完成后仍不引入侧栏路由体系、不删除平台目录中的历史能力元数据、不修复自定义地址身份、不改变 AI 图像识别请求与费用策略、不为非 OpenAI-compatible 平台增加专用模型目录适配、不改审核编辑持久化节流、不改 MathContent 的 HTML/安全策略、不做账号或 server/worker 整改。H2 题库子项及 H3、H6、启动资源全局改色与全应用组件替换继续按批次验证。没有真机覆盖的读屏、最大字号、手机窄窗、深色模式、二合一自由窗口和真实导入 E2E 均必须明确标记未验证，不能因静态合同通过而宣称全部完成。
