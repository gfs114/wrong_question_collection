# AI PDF 页面顶部起排回归合同红灯

日期：2026-09-13

命令：`node --test entry/src/test/UiRemediationContracts.test.cjs`

结果：10 tests / 9 pass / 1 fail。

失败合同：`short AI PDF setup and progress content starts at the top of the available pane`。

失败原因：`PdfAiImportSetupPage` 的 `ContentArea` 仍使用短内容 `Scroll`；真机中即使子 `Column` 声明 `.align(Alignment.Top)`，主体仍从 y=539 开始并在导航栏下留下明显空白。该失败发生在修改生产页面之前。
