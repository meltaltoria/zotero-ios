# iPad 翻译功能：真机安装与验收

## 已通过的自动验证

提交 `dbe59e1b1666bcefbaf249382292f5f1e8903f1d` 的两条 CI 均已通过：

- [iPad Pro 13-inch (M5)，iOS 26.5](https://github.com/meltaltoria/zotero-ios/actions/runs/38868129348)
- [iPhone 17，iOS 26.5](https://github.com/meltaltoria/zotero-ios/actions/runs/38868129266)

这两条任务构建应用并执行 XCTest。iPad 任务使用 `Test` 配置，启用项目原有的 `TESTING` 标记；模拟器采用不需要开发者证书的 ad-hoc 签名。纯文本日志和 `.xcresult` 测试结果分别保存在 iPad 任务的 Artifacts 中。

模拟器测试结果不包含可直接安装到 iPad 的设备应用。以下步骤需要一台运行 Xcode 26.5 的 Mac、一台 iPad，以及能够为所需 App Groups 和 iCloud 能力签名的 Apple 开发团队。实际真机验收尚未执行。

## 准备源码

```sh
git clone --recursive https://github.com/meltaltoria/zotero-ios.git
cd zotero-ios
git checkout feature/pdf-translate-ios
git submodule update --init --recursive
brew install swiftgen swiftlint
./scripts/setup.sh
open Zotero.xcodeproj
```

PSPDFKit 使用项目的试用许可，或将自己的许可填入 `licenses/licenses.plist`。在真机上验证 PDF 打开与选文操作时，也需要确认许可可用。

## 配置自己的签名与标识符

在 Xcode 中选择 `Zotero` scheme，分别检查 `Zotero` 与 `ZShare` target 的 Signing & Capabilities，选择自己的 Team，开启自动签名。

为测试版选择自己团队拥有的独立标识符，避免与正式版使用同一个应用标识符。例如：

| 配置位置 | 测试版示例 |
| --- | --- |
| Zotero 的 Bundle Identifier | `com.example.ZoteroTranslate` |
| ZShare 的 Bundle Identifier | `com.example.ZoteroTranslate.ZShare` |
| 两个 target 共用的 App Group | `group.com.example.ZoteroTranslate` |
| Zotero 的 iCloud container | `iCloud.com.example.ZoteroTranslate` |

将示例中的 `com.example` 换为自己团队可用的名称。以下配置必须保持一致：

1. `Zotero/Zotero.entitlements` 和 `ZShare/ZShare.entitlements` 的 App Group。
2. `Zotero/Models/AppGroup.swift` 返回的 App Group 标识符。
3. Zotero target 的两个 iCloud container entitlement，使用自己团队创建的同一容器。
4. 主应用与分享扩展的 Bundle Identifier，以及 Xcode 为它们生成的 provisioning profile。

若 Xcode 提示团队不支持所需能力，需要先解决团队或 provisioning profile 的能力配置；模拟器 ad-hoc 签名不能用于真机安装。

## 安装到 iPad

1. 将 iPad 连接到 Mac，完成“信任此电脑”，并按系统提示开启开发者模式。
2. 在 Xcode 运行目标中选择这台 iPad，确认 scheme 为 `Zotero`、Run 配置为 `Debug`。
3. 执行 Product → Run，等待构建、签名和安装完成。
4. 在测试版中登录，准备一份测试 PDF 和一个可编辑的测试笔记。

## 功能验收

| 操作 | 预期结果 |
| --- | --- |
| 选择一段 PDF 文本，点击 Translate，使用 Google 服务 | 显示原文和译文，Copy 可以复制译文。需要设备能连接 Google 翻译服务。 |
| 翻译超过 1,800 字符的测试选文 | 长文本分段处理，结果完整，无崩溃。 |
| 翻译进行中点击 Cancel | 等待界面关闭，稍后不会再次弹出该请求的译文或错误。 |
| 翻译一条没有评论的测试高亮，点击 Annotation | 译文保存到该高亮的评论，并能重新打开查看。 |
| 同一窗口中有可编辑且可见的笔记时点击 Note | 原文和译文插入该笔记；重新打开笔记后内容仍存在。 |
| 只有只读笔记、隐藏笔记或其他窗口中的笔记 | 不提供向这些笔记写入译文的按钮。 |
| 在设置中更改目标语言或学术提示词，再翻译相同文本 | 使用新设置，缓存不会复用旧设置的结果。 |
| 配置自己的 OpenAI 兼容 endpoint、model 和 API key | 可以翻译；重新打开设置后配置仍存在。不要在验收记录中填写 API key。 |
| 服务不可达或认证失败 | 显示可读的失败提示，关闭后可以重试。 |
| iPadOS 18+ 使用 Apple 服务翻译选文 | 出现系统翻译界面。将 Apple 翻译直接保存到批注评论目前不支持，应显示对应说明。 |
| 横竖屏切换、深色模式和分屏 | 结果与操作按钮可访问，弹出框不会超出当前窗口。 |
| 从系统分享菜单向测试版保存条目 | 分享扩展可以正常保存，用于验证主应用和扩展的 App Group 配置。 |

## 记录验收结果

记录实际提交 SHA、iPad 型号、iPadOS 版本、翻译服务、目标语言，以及每项的通过或失败。复现失败时附上操作步骤和错误文字；移除 API key、授权头和不准备分享的文献正文。

真机验收完成前，PR 继续保持草稿状态。模拟器 CI 通过不等同于上述真机项目已完成。
