# 版本 1.0.3 验证记录

1.0.3 修复边栏在 Zotero 本地化时被替换为空白的问题。标题使用 Fluent 的 `.label` 属性，导航图标使用 `.tooltiptext` / `.aria-label`，打开边栏使用 Zotero 原生 `getPane()`。插件 ID 和凭据存储方式保持一致。

## 故障复现

用新增的界面可见性检查运行 1.0.2，在真实 Zotero 10.0.7 中文界面中重现了用户反馈：只剩“AI 阅读助手”文字，图标文字竖排，表单已经脱离窗口。报告中的 `panel_connected` 和 `live_question` 均为 `false`。

- [1.0.2 失败报告](tests/reports/regression-1.0.2-localization-zh-CN.json)
- [1.0.2 故障截图](tests/reports/images/1.0.2-blank-zh-CN.png)

此前 1.0.2 的检查只验证持有的控件对象和注册状态，没有验证本地化完成后它们仍在页面中，漏掉了这个问题。新版测试等待实际本地化，再检查连接状态、可见尺寸和窗口中的输入框，并通过界面按钮操作。

## 原生验证

使用官方 Linux 版 Zotero 10.0.7，在隔离 Debian 容器和独立临时配置中运行；容器不连接外网，AI 端点使用容器内模拟服务。

- 中文 `zh-CN` 和英文 `en-US` 界面各通过 **50 项**检查。
- 使用实际 AddonManager 安装 XPI，结果 `error: 0`、`compatible: true`；旧 1.0.1 仍作为安装失败负向对照。
- 文献库和 PDF 阅读器均经过 Fluent 本地化后再检查，表单仍连接到窗口、具有可见尺寸，标题和图标提示正确。
- 在真实边栏中切换材料，输入问题并点击发送，确认回答出现在窗口中；点击复制并读取原生剪贴板，点击存为笔记并检查真实子笔记，点击停止并验证请求中断，点击设置并验证表单加载。
- 同时检查原生密码管理器、流式 / 非流式 HTTP、错误脱敏、PDF 文本提取、选区转入、文献隔离、密钥删除和停用清理。

报告：[中文](tests/reports/runtime-10.0.7-zh-CN.json)、[英文](tests/reports/runtime-10.0.7-en-US.json)。`runtime-10.0.7.json` 为中文报告副本。每份报告记录了实际测试 XPI 的 SHA-256：

```text
4dc7b377a08a56515cdd5255e575b4d42aee4e568bdb4c7a32283c382bc2b6da
```

生成的示例截图：[文献库边栏](tests/reports/images/1.0.3-library-zh-CN.png)、[阅读器输入和操作区](tests/reports/images/1.0.3-reader-controls-zh-CN.png)。截图中的文献、选段、模型和服务地址均为测试夹具，不含用户资料。

## 其他检查和范围

9 项核心测试、23 项浏览器界面与模拟 HTTP 检查通过。检查 XPI 必填清单字段、XHTML XML、JavaScript 语法、ZIP CRC、更新清单和 SHA-256。发布包不包含测试工具、测试凭据或第三方 Zotero 运行时。

原生测试来自 **Linux 桌面版 Zotero 10.0.7**，尚未进行 Windows 实机验证，也未实测其他 Zotero 大版本。没有使用真实服务密钥发起付费模型调用；安装后可通过“保存并测试连接”检查自己的服务。测试资料为生成的 PDF 和模拟响应，未使用用户文献库内容。
