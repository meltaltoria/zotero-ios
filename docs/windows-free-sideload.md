# Windows 免费账号安装翻译版 Zotero

适用目标：运行 iOS/iPadOS 18.7.8 的 arm64 iPhone 或 iPad，普通 Apple 账号，没有付费开发者证书。设备构建由 GitHub Actions 的 Mac 完成，Windows 只负责下载、签名和安装。

## 下载设备 IPA

在仓库的 Actions 中找到 **Free Account IPA**，打开与所需提交对应、已成功结束的任务。在 Artifacts 中下载 **Zotero-Translate-Free-unsigned**，解压外层 ZIP，取得：

`Zotero-Translate-Free-unsigned.ipa`

这是需要个人签名的设备包。不要使用模拟器 `.app`，也不要把构建日志或 `.xcresult` 当作安装包。**Zotero-Translate-Free-manifest** 产物记录源提交、SHA-256、arm64/iPhoneOS 平台及最低系统版本检查结果；它不代表已通过真机验证。

## 免费侧载版的区别

- 桌面显示名称为 **Zotero Translate**，使用独立的应用标识符，与 App Store 原版分开保存数据。
- 文件、设置、登录凭据和 Cookie 使用应用自己的存储，避免依赖官方 App Group。
- 包内不包含 `ZShare` 分享扩展，也不申请 App Group、iCloud 容器权限。
- PDF 翻译、应用内文件操作、Zotero 账号同步和 WebDAV 路径仍保留；这些功能的真机表现需要安装后验收。
- 不会自动读取原版的本地数据库或登录凭据。需要在测试版中重新登录，通过同步或应用内导入取得文献。
- PSPDFKit 仍受项目所用许可或试用期限约束；侧载不提供额外的 PDF SDK 许可。

## Windows 签名与安装

推荐从 [Sideloadly 官网](https://sideloadly.io/)安装 Windows 版。其[官方 FAQ](https://sideloadly.io/faq.html)说明了设备识别、免费账号签名、开发者模式和自动续签。

1. 使用数据线连接设备与 Windows，解锁设备，选择“信任此电脑”。若软件无法识别设备，按官方 FAQ 安装或修复 Apple 驱动组件。
2. 打开 Sideloadly，选择目标设备，导入 `.ipa` 文件。
3. 在本机软件中输入自己的 Apple 账号，按提示完成认证，执行安装。保持同一 Apple 账号及相同应用标识符，方便后续覆盖更新。
4. 若系统提示不受信任的开发者，进入“设置 → 通用 → VPN 与设备管理”，信任用于签名的账号。
5. 按系统提示在“设置 → 隐私与安全性 → 开发者模式”中开启开发者模式，完成重启与确认。如果安装前没有该入口，先尝试签名安装，再检查系统提示。
6. 在桌面打开 **Zotero Translate**，重新登录自己的 Zotero 账号，先使用测试 PDF 验证。

也可尝试爱思助手的“工具箱 → IPA 签名 → Apple ID 签名”，完成签名后安装输出目录中的已签名 IPA；具体菜单与服务是否可用，以当前爱思版本为准。参见[爱思官方教程](https://www.i4.cn/news_detail_38195.html)。未经签名的本产物不能通过“导入安装”直接运行。

免费账号签名通常为 7 天有效，并受侧载应用数量限制。可以按 Sideloadly 的官方流程开启自动刷新；续签需要 Windows 电脑能够通过 USB 或 Wi-Fi 连接设备。更新或续签前先完成文献同步，使用相同账号和标识符覆盖安装，避免主动删除保存有本地文件的测试版。

## 使用翻译

1. 在测试版 Zotero 的设置中打开 **Translation**，选择 Google、Apple 或 OpenAI-compatible 服务，设置目标语言。
2. Google 不需要 API key，但要求设备网络能连接该服务。Apple 系统翻译需要 iOS/iPadOS 18+。OpenAI-compatible 需要用户自己的 endpoint、model 和 API key。
3. 打开 PDF，选择文本，点击 **Translate**。在结果中复制译文，或在有合适笔记编辑器时写入笔记。
4. 对测试高亮使用 **Translate Annotation**；Google 和 OpenAI-compatible 的译文可以保存为该批注评论。Apple 系统翻译暂不支持直接保存到批注评论。
5. 检查翻译取消、PDF 长文本、关闭重开后的登录状态及文献同步。完整功能验收见[验收指南](ipad-translation-verification.md#功能验收)。

真实 iOS 18.7.8 上的安装、登录、同步和翻译需要用户设备验证；云端模拟器测试不能替代这一步。
