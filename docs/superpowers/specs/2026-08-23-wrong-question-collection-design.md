# 错题收集 HarmonyOS 应用设计

## 1. 目标与范围

本项目在现有 HarmonyOS 6.1.1(24) Stage 模型工程中实现一款面向学生的本地错题管理应用。应用使用 ArkTS、ArkUI 声明式 UI 和 HarmonyOS 官方 Kit，不引入 Android、Flutter、React Native、Vue 或 HTML 页面。

首版完成以下闭环：

1. 首次启动自动提供一个可删除的示例单选题库。
2. 用户通过系统文件选择器导入本地 JSON 题库。
3. 用户浏览题库、搜索题目并查看题目详情。
4. 用户把题目加入错题本，且同一题不会重复添加。
5. 用户筛选错题、查看详情、标记掌握或移出错题本。
6. “我的”页面显示题库、错题、已掌握和待复习统计。
7. 关闭并重启应用后，题库和错题仍然存在。

首版只完整支持 `single_choice` 单选题。模型和校验器保留明确的题型字段，以便后续扩展多选、判断、填空和简答题，但本次不实现这些题型的 UI 与判题逻辑。

## 2. 已确认的产品决策

- 视觉方向：鸿蒙原生蓝。使用浅灰蓝页面背景、白色圆角卡片、蓝色主操作按钮、清晰的标题层级和适度留白。
- 数据方案：业务数据使用 `@kit.ArkData` 的 `relationalStore` 本地关系型数据库。
- 首启体验：内置一个可删除的示例题库，仍完整支持用户 JSON 导入。
- 云端边界：首版完全本地可用，不登录、不联网、不申请网络权限，也不接入云数据库、对象存储或跨设备同步。
- 工程边界：保留现有 bundleName、SDK/API、Stage 模型和模块配置，仅在需要注册页面或资源时做最小修改。

## 3. 总体架构

应用按职责分为五层：

1. `pages`：页面组合、状态展示、导航和用户事件入口。
2. `components`：卡片、标题、空状态、统计等可复用 ArkUI 组件。
3. `models`：明确类型的数据模型、筛选条件和统计结果。
4. `services`：数据库初始化、题库导入、题库查询、错题管理和统计聚合。
5. `utils`：JSON 解析校验、日期格式化、标识生成和导航选择状态。

页面只调用服务接口，不直接拼写 SQL 或操作底层文件。服务层统一返回明确结果或抛出可映射为中文提示的业务错误，确保页面逻辑保持轻量。

## 4. 目录结构

```text
entry/src/main/ets/
├── components/
│   ├── AppHeader.ets
│   ├── EmptyState.ets
│   ├── QuestionBankCard.ets
│   ├── QuestionCard.ets
│   ├── SectionTitle.ets
│   ├── StatCard.ets
│   └── WrongQuestionCard.ets
├── models/
│   ├── ImportResult.ets
│   ├── Question.ets
│   ├── QuestionBank.ets
│   ├── Statistics.ets
│   └── WrongQuestion.ets
├── pages/
│   ├── BooksPage.ets
│   ├── ImportBankPage.ets
│   ├── Index.ets
│   ├── MinePage.ets
│   ├── QuestionDetailPage.ets
│   ├── QuestionListPage.ets
│   ├── WrongQuestionDetailPage.ets
│   └── WrongQuestionsPage.ets
├── services/
│   ├── DatabaseService.ets
│   ├── ImportService.ets
│   ├── QuestionBankService.ets
│   ├── SampleDataService.ets
│   ├── StatisticsService.ets
│   └── WrongQuestionService.ets
└── utils/
    ├── DateUtils.ets
    ├── IdUtils.ets
    ├── JsonParser.ets
    └── NavigationState.ets
```

示例题库放在 `entry/src/main/resources/rawfile/sample_question_bank.json`。路由页面同步登记在 `entry/src/main/resources/base/profile/main_pages.json`。

## 5. 数据模型与数据库

### 5.1 ArkTS 模型

`QuestionBank`：

- `id: string`
- `bankName: string`
- `subject: string`
- `questionCount: number`
- `createTime: number`
- `isSample: boolean`
- `questions: Array<Question>`，仅在导入和需要完整题库时使用

`Question`：

- `id: string`
- `bankId: string`
- `type: string`
- `question: string`
- `options: Array<string>`
- `answer: string`
- `analysis: string`

`WrongQuestion`：

- `id: string`
- `questionId: string`
- `bankId: string`
- `subject: string`
- `addTime: number`
- `mastered: boolean`
- `userAnswer: string`，首版允许为空

错题列表使用带题目和题库展示字段的明确查询结果模型，避免 UI 再执行多次查询。

### 5.2 关系表

`question_bank`：

- `id TEXT PRIMARY KEY`
- `bank_name TEXT NOT NULL`
- `subject TEXT NOT NULL`
- `question_count INTEGER NOT NULL`
- `create_time INTEGER NOT NULL`
- `is_sample INTEGER NOT NULL DEFAULT 0`

`question`：

- `id TEXT PRIMARY KEY`
- `bank_id TEXT NOT NULL`
- `type TEXT NOT NULL`
- `content TEXT NOT NULL`
- `options_json TEXT NOT NULL`
- `answer TEXT NOT NULL`
- `analysis TEXT NOT NULL`

`wrong_question`：

- `id TEXT PRIMARY KEY`
- `question_id TEXT NOT NULL UNIQUE`
- `bank_id TEXT NOT NULL`
- `subject TEXT NOT NULL`
- `add_time INTEGER NOT NULL`
- `mastered INTEGER NOT NULL DEFAULT 0`
- `user_answer TEXT NOT NULL DEFAULT ''`

建立 `question.bank_id`、`wrong_question.bank_id`、`wrong_question.subject` 和 `wrong_question.mastered` 索引。删除题库时由 `QuestionBankService` 在一个事务中依次删除相关错题、题目和题库，避免依赖不同 SDK 下外键级联行为的差异。

### 5.3 数据库初始化与示例题库

`DatabaseService` 负责打开数据库、按版本建表和建立索引。首版数据库版本为 1。

`SampleDataService` 首次成功打开数据库后读取 rawfile 示例 JSON，复用与用户导入相同的解析、校验和保存流程。一个仅用于启动引导的 Preferences 布尔标记记录“示例初始化已执行”，业务数据仍全部保存在关系数据库。这样用户删除示例题库后，后续启动不会再次自动生成。

## 6. JSON 导入

接受的首版格式为：

```json
{
  "bankName": "高等数学题库",
  "subject": "数学",
  "questions": [
    {
      "id": "1",
      "type": "single_choice",
      "question": "函数 f(x)=x² 的导数是？",
      "options": ["A. x", "B. 2x", "C. x²", "D. 2"],
      "answer": "B",
      "analysis": "根据幂函数求导公式可得 f'(x)=2x。"
    }
  ]
}
```

导入流程：

1. 使用 HarmonyOS 系统文档选择器选择一个 JSON 文件。
2. 通过沙箱可访问 URI 读取 UTF-8 文本并及时关闭文件句柄。
3. `JsonParser` 解析并逐字段校验数据。
4. 为题库生成应用内唯一 `bankId`；题目主键使用 `bankId + 原始题目 id`，避免不同题库的题号冲突。
5. 在单个数据库事务中写入题库和全部题目。
6. 成功后显示“题库导入成功”，并返回书本页面刷新列表。

校验规则：

- 根对象必须包含非空的 `bankName`、`subject` 和非空 `questions` 数组。
- 每道题必须具有唯一且非空的 `id`。
- `type` 必须为 `single_choice`。
- `question`、`answer` 和 `analysis` 必须为字符串；题目和答案不能为空。
- `options` 至少包含两个非空字符串。
- `answer` 必须能匹配某个选项的字母标识。
- 未识别的额外字段忽略；任何关键字段不合法则整份题库拒绝导入。

用户取消选择时静默返回。文件读取失败、JSON 语法错误、格式错误和数据库写入失败分别显示友好中文提示，不显示底层异常堆栈。

## 7. 页面与导航

### 7.1 根页面

`Index` 使用 `Tabs` 和三个 `TabContent` 实现固定底部导航：

- 书本：书本图标和“书本”。
- 错题收集：收藏或笔记图标和“错题收集”。
- 我的：用户图标和“我的”。

当前 Tab 使用蓝色图标和文字高亮。三个根页面作为组件嵌入 `Index`，不单独登记为路由页面。

### 7.2 独立路由页面

- `ImportBankPage`
- `QuestionListPage`
- `QuestionDetailPage`
- `WrongQuestionDetailPage`

这些页面使用 HarmonyOS `router` 打开和返回。为遵守严格 ArkTS 类型规则并避免不安全类型断言，当前题库 ID、题目 ID和题目顺序由 `NavigationState` 以明确类型保存，页面路由本身不传递未约束的动态对象。

### 7.3 页面内容

`BooksPage`：标题“我的题库”、右上角“导入题库”、题库卡片列表和无题库空状态。卡片显示科目、名称、题目数量和导入时间。

`ImportBankPage`：格式说明、选择 JSON 文件按钮、导入进度和错误提示。页面不直接解析或写库。

`QuestionListPage`：题库名称、搜索框和题目卡片列表。搜索匹配题目正文，首版在本地内存中过滤当前题库结果。

`QuestionDetailPage`：题型、题目、选项、正确答案和解析。底部提供上一题、加入错题、下一题；位于边界时禁用相应切换按钮。已加入时按钮显示“已加入错题”并禁用重复写入。

`WrongQuestionsPage`：全部、已掌握、待复习统计；横向科目筛选；错题卡片列表；无错题空状态。首版只实现科目筛选，但服务接口预留掌握状态、题库和时间范围条件。

`WrongQuestionDetailPage`：题目、选项、正确答案、解析、题库和科目；用户答案为空时不显示。提供标记掌握和移出错题本，删除前二次确认。

`MinePage`：默认头像、“学习中心”、四张统计卡片以及数据管理、清空错题和关于应用。清空错题必须二次确认。

页面通过 `onPageShow` 或组件可见生命周期重新从服务层加载数据，因此从详情页返回、切换 Tab 或修改错题状态后，书本、错题和统计保持同步。

## 8. 可复用 ArkUI 组件

- `AppHeader`：统一标题、返回和右侧操作区域。
- `QuestionBankCard`：题库名称、科目、数量和时间。
- `QuestionCard`：题号、题型和题目摘要。
- `WrongQuestionCard`：科目、内容、加入时间和掌握状态。
- `StatCard`：统计名称、数值和配色。
- `EmptyState`：空状态标题、说明和可选行动按钮。
- `SectionTitle`：页面分区标题和可选辅助文字。

组件只接收明确的展示字段和事件回调。列表键统一使用稳定业务 ID，不使用可变数组索引。

## 9. 状态、反馈与异常处理

应用使用同一套反馈原则：

- 成功导入：“题库导入成功”。
- 加入错题：“已加入错题本”。
- 移出错题：“已移出错题本”。
- 标记掌握：“已标记为掌握”。
- 格式不合法：“题库格式错误，请检查 JSON 文件”。
- 本地数据库初始化失败：“本地数据初始化失败，请重启应用”。

异步操作期间禁用重复点击并显示加载状态。服务层只在事务成功后返回成功结果。危险操作使用 `AlertDialog` 二次确认；普通成功和错误反馈使用 ArkUI Toast。

## 10. 适配与视觉规范

- 页面背景为浅灰蓝，内容卡片为白色。
- 主色使用鸿蒙风格蓝色，危险操作使用红色语义色，已掌握使用绿色语义色。
- 卡片圆角、内边距和页面左右边距采用统一常量。
- 标题、卡片标题、正文和辅助文字形成稳定字号层级。
- 使用安全区域和自适应宽度，不固定为某一手机像素尺寸。
- 手机保持单列；更宽设备允许统计卡片增加列数，但不改变功能层级。
- 所有主要功能使用 ArkUI 原生组件完成，不嵌入 Web 视图。

## 11. 测试与验证

### 11.1 自动检查

- 为 JSON 校验、答案匹配和日期格式化编写本地单元测试。
- 对所有新增或修改的 `.ets` 文件运行 `harmonyos-dev` 提供的 ArkTS 检查脚本。
- 使用 DevEco Studio 自带 Node 和 hvigor 执行完整 debug HAP 构建。
- 出现 ArkTS 编译错误时，先按错误文本读取 `harmonyos-dev` 中最窄的错误修复参考，再修改代码并重新检查。

### 11.2 交互验收

在模拟器或真机可用时验证：

1. 首启出现示例题库。
2. 导入合法 JSON 后题库立即出现，重启应用后仍存在。
3. 非法 JSON 不产生残留题库，并显示友好提示。
4. 搜索可以缩小题目列表。
5. 题目详情能前后切换，边界按钮状态正确。
6. 同一题重复点击不会生成重复错题。
7. 错题页能按科目筛选。
8. 标记掌握后错题卡片与“我的”统计同步。
9. 移出和清空错题均需要确认，取消时数据不变。
10. 删除题库后，其题目和关联错题一并删除。

没有可用设备时，只声明 ArkTS 检查和 HAP 构建结果，不把未执行的真机交互描述为已验证。

## 12. 云端说明

首版不需要任何云端能力，也不需要网络权限。题库 JSON 由用户在设备上选择，数据库、示例题库和统计均保存在本机。

后续若增加以下能力，才需要云端：

- 账号登录：需要认证服务。
- 多设备同步：需要云数据库、冲突解决策略和同步任务。
- 云端题库市场：需要后端 API、对象存储、内容审核和版本管理。
- 云备份恢复：需要加密上传、用户授权和数据迁移策略。

未来可在现有服务层之上增加 `SyncService`，保持页面和本地数据库作为离线优先的数据源。本次不创建占位云接口或申请多余权限。

## 13. 不在首版范围内

- 登录、注册和账号体系。
- 云同步、云备份和在线题库下载。
- OCR、拍照识题和图片题目。
- 多选、判断、填空、简答题的完整交互。
- 用户作答、自动判分、复习计划和学习曲线。
- 按时间和题库筛选的可见 UI；仅保留服务扩展能力。
