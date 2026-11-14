# Apple 开发者申请与签名准备

执行对象：负责账号、公司材料和签名凭据的同事。目标是取得 iOS 真机分发与 TestFlight 所需的资格和材料，并为后续 macOS 正式分发做好准备。当前 GitHub 流程先生成 iOS 模拟器包，不需要等会员申请完成；本指南准备的签名材料尚未接入测试工作流。

所有真实姓名、公司材料、账号、Team ID、密钥、证书私钥、密码和描述文件都应保存在组织认可的私密位置，不得填写到这份公开文档、Git、Issue、PR 或构建日志中。

## 一 选择注册主体

申请标准 **Apple Developer Program**。同一会员可用于 iOS 和 macOS 分发，无须为两个平台各买一次。当前标准年费为 **99 美元**，当地价格及税费以 Apple 付款页为准。不要为公开发行误买面向符合条件组织内部员工分发的 Enterprise Program。[会员权益](https://developer.apple.com/programs/)

| 事项 | 个人 | 组织 |
| --- | --- | --- |
| App Store 销售方 | 个人法定姓名 | 组织法定名称 |
| 身份材料 | 本人身份验证资料 | 法人实体资料、授权联系人等 |
| D-U-N-S 编号 | 不需要 | 通常需要，政府组织有例外 |
| 适用情况 | 个人独立开发 | 产品归公司所有并由团队维护 |

公司产品建议由公司申请，员工受邀加入，避免由外包或员工个人持有产品账号。组织需有公开可访问的网站、组织域名工作邮箱，以及有权代表组织签署协议的申请人。具体身份核验材料以 Apple 实际要求为准。[注册要求](https://developer.apple.com/help/account/membership/program-enrollment/)

## 二 申请会员

1. 准备长期由主体控制的 Apple Account，开启双重认证；账号本人完成身份验证，勿共用密码或验证码。
2. 组织申请先核对 D-U-N-S 编号，确保名称和地址与主体资料一致。通过 Apple 提供的查询入口查找或申请；不要把第三方付费加急当成必要步骤。[D-U-N-S 官方入口说明](https://developer.apple.com/help/account/membership/D-U-N-S/)
3. 打开 [Apple 注册入口](https://developer.apple.com/programs/enroll/)，按网页或 Apple Developer App 提示选择个人或组织，填写真实信息。
4. 完成身份、组织和授权核验，按要求补充资料并接受协议。
5. 获准后付款，确认开发者账户显示会员有效且能进入 **Certificates, Identifiers & Profiles**；付款完成不应作为唯一验收依据。
6. 在私密交接记录中保存到期时间和续费负责人；后续新协议由 Account Holder 及时处理。

## 三 确认应用标识和功能

由技术负责人先确定正式 Bundle ID，例如 `com.example.botone`，这里的 `example` 只是占位符。不要直接照搬上游标识，也不要把当前测试包的 `dev.botone.preview` 当成已经确定的正式标识。

进入 [开发者账户](https://developer.apple.com/account/) → **Certificates, Identifiers & Profiles → Identifiers**，创建显式 App ID。当前移动端有以下目标，需在同一团队下准备：

| 目标 | Bundle ID 示例 |
| --- | --- |
| 主应用 | `com.example.botone` |
| 实时活动 Widget | `com.example.botone.widgets` |
| 分享扩展 | `com.example.botone.expo-sharing-extension` |
| 通知扩展 | `com.example.botone.notifications` |

创建分享用 App Group，例如 `group.com.example.botone`，将它关联到主应用和分享扩展。再与技术负责人核对推送通知、Associated Domains、Time Sensitive Notifications、Communication Notifications 等实际启用的能力。以最终工程的 entitlements 为准，不要为每个扩展盲目开启所有能力。

标识、能力、团队和描述文件必须匹配；修改能力后需要重新生成相应描述文件。[描述文件更新说明](https://developer.apple.com/help/account/provisioning-profiles/edit-download-or-delete-profiles/)

## 四 制作 iOS 分发证书

推荐由有权限的同事在受控 Mac 上操作。会员注册本身不要求拥有 Mac；没有受控 Mac 时，可由技术负责人另外使用 OpenSSL 制作 CSR 与私钥。

1. 打开 Mac 的 **钥匙串访问 Keychain Access**。
2. 菜单选择 **证书助理 → 从证书颁发机构请求证书**。
3. 输入申请邮箱和方便内部识别的名称，CA 邮箱留空，选择保存到磁盘，得到 `.certSigningRequest`。制作 CSR 时生成的私钥留在该 Mac 钥匙串中。[创建 CSR](https://developer.apple.com/help/account/certificates/create-a-certificate-signing-request/)
4. 开发者账户进入 **Certificates → +**，选择 **Apple Distribution**，上传 CSR，生成并下载 `.cer`。如无创建权限，由 Account Holder 或具备权限的 Admin 操作。[证书类型与权限](https://developer.apple.com/help/account/certificates/certificates-overview/)
5. 在生成 CSR 的同一台受控 Mac 上导入 `.cer`。在钥匙串的“我的证书”中展开，确认下面带有对应私钥。
6. 选中证书及私钥，导出为 `.p12`，设置独立强密码，放入私密凭据保管处；密码通过单独的受控方式交接。

**只交 `.cer` 不够。** CI 签名需要私钥，通常通过受密码保护的 `.p12` 交付。导入其他机器前应在受控环境确认 `.p12` 同时包含证书和私钥，不要把密码写到命令行历史或文档中。

## 五 制作 iOS 描述文件

面向 TestFlight 和 App Store：

1. **Profiles → + → Distribution → App Store Connect**。
2. 选择主应用的显式 App ID。
3. 选择上一步的分发证书，填写内部名称并生成，下载 `.mobileprovision`。
4. 为三个扩展分别选择对应 App ID，重复上述步骤，取得各自的描述文件。不要把主应用描述文件复制给扩展。
5. 将四份文件与证书私密交接给技术负责人，记录有效期。工程使用自动签名时，也可以让 Xcode 管理描述文件，但需要另行配置 CI 授权。

这类包用于上传 TestFlight/App Store，不能直接把 IPA 发给任意 iPhone 安装。若需要通过文件分发给指定测试设备，另行准备 Ad Hoc 描述文件并登记设备 UDID。[Apple 描述文件步骤](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile/)

## 六 创建商店应用和上传 API Key

1. 登录 [App Store Connect](https://appstoreconnect.apple.com/)，进入 **My Apps → + → New App**，选择 iOS，填写名称、主要语言、Bundle ID 和内部 SKU，创建应用记录。
2. 在应用信息中记录系统生成的数字 Apple ID。它和 Bundle ID、Team ID 是不同的值，不要混用。
3. Account Holder 如遇 API 访问申请提示，先完成访问申请。
4. **Users and Access → Integrations → App Store Connect API → Team Keys**，创建专用 CI Key。仅上传构建时按所需最小权限选择；若还要自动提交 App Review，准备具有 **App Manager** 权限的 Key。
5. 下载 `.p8`，并私密保存 **Key ID、Issuer ID、`.p8` 文件**。私钥只能下载一次；遗失后需要撤销并重新创建。
6. Team Key 的作用域覆盖团队应用，不是只对某个应用授权；技术负责人接入前确认权限范围。[API Key 官方说明](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api)

`.p8` API Key 用于 API 认证，不能代替 `.p12` 分发证书。只取得 API Key 还不足以完成手动签名。

首次先上传 TestFlight、邀请测试者并确认真机行为。App Store 正式上架还要补充审核资料、截图、隐私信息、支持地址及必要的审核账号；内部和外部 TestFlight 的审核要求也有区别，不要承诺“上传成功即公开上线”。

## 七 准备 macOS 正式分发

本项目的桌面安装包走 Mac App Store 以外分发，需准备 **Developer ID Application** 证书，不是 iOS 的 Apple Distribution 证书。

1. 由 Account Holder 按开发者后台权限要求，进入 **Certificates → + → Developer ID Application**。
2. 使用新的 CSR，下载 `.cer`，在生成 CSR 的 Mac 导入并带私钥导出 `.p12`，设置独立密码。
3. 私密交接 `.p12` 和密码，用于签名 `.app`；后续流水线再执行 Apple 公证。
4. 预留可用于公证的 App Store Connect API Key，按最小权限创建，或经负责人确认后复用兼容 Key。正式接入时由技术负责人验证公证权限。

当前 DMG/ZIP 分发不需要为了签 `.app` 再申请 Developer ID Installer；只有以后分发需要签名的 `.pkg` 安装器时才评估该证书。系统通行密钥等额外能力还可能需要专门的 Developer ID 描述文件。[Developer ID 申请说明](https://developer.apple.com/help/account/certificates/create-developer-id-certificates)

## 八 私密交接清单

下表只用于检查材料是否齐全，真实内容不要填回本文件。GitHub 管理员接入正式签名时，再按最终工作流确定 Secret 名称；当前测试构建不读取这些材料。

| 材料 | 交接要求 |
| --- | --- |
| 会员主体、状态和续费日期 | 私密记录，负责人明确 |
| 团队信息与 Team ID | 私密记录，可由技术负责人核对权限 |
| 正式主应用及三个扩展 Bundle ID、App Group | 与最终工程一致 |
| iOS Apple Distribution `.p12` | 包含私钥；密码单独保管 |
| iOS 主应用及三个扩展 `.mobileprovision` | 团队、证书、能力、有效期均匹配 |
| App Store 应用数字 ID | 已有对应应用记录 |
| API Key `.p8`、Key ID、Issuer ID | 权限已确认，私钥已备份 |
| macOS Developer ID Application `.p12` | 与 iOS 证书分开，密码独立保管 |

交接完成后，由技术负责人把需要的值写入 GitHub Secrets，验证一次签名构建和 TestFlight 上传。账号密码、验证码和私钥不通过公开聊天或代码评审传递；不要为申请新证书随意撤销已有生产证书。
