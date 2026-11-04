# mithka-build

把 [iebb/mithka](https://github.com/iebb/mithka)（Flutter 写的 Telegram 客户端）在上游源码上重新打包，产出**自己签名、自己发行**的 APK，并让 App 直接从本仓库的 Release 里下载安装更新。

## 这个仓库做了什么

构建时从上游仓库拉取指定 tag 的源码，由 `patches/apply.py` 打上四类改动，然后编译：

| 改动 | 位置 |
| :--- | :--- |
| `applicationId`（包名）改成 `org.telegram.messenger` | `android/app/build.gradle.kts` |
| 检查更新指向本仓库的 Release | `lib/update/release_feed.dart` |
| 版本号改成 `<上游版本>.<构建序号>`，并按四段比较 | 同上 |
| 应用内更新：下载 APK → 校验 SHA-256 → 拉起系统安装器 | `lib/update/update_checker.dart` + `overlay/lib/update/android_apk_installer.dart` |

`overlay/` 里是新增文件，其余都是对上游源码的精确替换。上游一旦改动这些位置，构建会在打补丁阶段直接失败并报出是哪一处，不会产出半成品。

## 触发方式

- **每天 03:17 自动**：查上游最新正式 release，如果这个版本还没构建过就构建；构建过就跳过。
- **手动**：Actions → `Build APK` → Run workflow
  - `upstream_ref`：留空 = 上游最新正式版；也可以填 tag / 分支 / commit，强制重新构建。
  - `application_id`：默认 `org.telegram.messenger`。
  - `app_name`：桌面图标名，默认 `Mithka`。
  - `publish`：是否发布成 Release。

产物：`mithka-<版本>-android-arm64-v8a.apk` 与 `...-armeabi-v7a.apk`，外加 `update.json`（含每个包的 SHA-256）。

## 必须配置的 Secrets

| Secret | 说明 |
| :--- | :--- |
| `ANDROID_KEYSTORE_BASE64` | 签名用的 keystore，`base64 -i release.jks \| pbcopy` 的结果 |
| `ANDROID_KEYSTORE_PASSWORD` | keystore 密码 |
| `ANDROID_KEY_ALIAS` | key 别名 |
| `ANDROID_KEY_PASSWORD` | key 密码（可与 keystore 相同） |
| `TELEGRAM_API_ID` | 自己的 api_id，https://my.telegram.org 申请 |
| `TELEGRAM_API_HASH` | 对应的 api_hash |

`TELEGRAM_API_ID` / `TELEGRAM_API_HASH` 缺失时仍会构建，但 App 无法登录，并且**不会**发布 Release（避免自动构建推一个用不了的包上去）。

## 包名的两个后果

1. `org.telegram.messenger` 与官方 Telegram 相同、签名不同，**两者不能共存**。安装前需要先卸载官方 Telegram（或本包的旧版本）。
2. 系统、其他 App 都会把它当官方 Telegram 看（分享目标、`tg://` 链接、包名白名单等）。这是改包名的预期效果，也是代价。

## 关于 FCM 推送

改包名**不会**让这个 APK 用上 Telegram 的 FCM 推送，原因有三条，都是硬性的：

1. FCM token 绑定在生成它的 Firebase 项目上。Telegram 服务端只会往它自己项目签发的 token 推送，别人的 token 发不出去。
2. Google Play Services 校验 app 的签名指纹是否登记在该 Firebase 项目里。我们的 APK 用自签 keystore，不在 Telegram 的项目里。
3. 上游 Android 端根本没接 FCM：`pubspec.yaml` 只有 `firebase_core` / `firebase_analytics`，没有 `firebase_messaging`，也没有 `FirebaseMessagingService`。`lib/notifications/push_device_registrar.dart` 里第一行就是 `if (!Platform.isIOS) return;`，Android 走的是 TDLib 自己的长连接，进程被杀就没有通知。

要真正拿到「杀后台也能收消息」，可选项是：给上游加 `firebase_messaging` + 自建 Firebase 项目 + 一个推送中转（TDLib 的 `setPushReceiverEndpoint` 把推送打到自己的服务端，再由服务端发 FCM）。这是一个独立工程，不是改个包名能解决的。

## 版本号规则

- Release tag：`v<上游版本>.<序号>`，例如上游 `v1.10.3` 的第一次构建是 `v1.10.3.1`，同版本再构建一次是 `v1.10.3.2`。
- `versionName` 与 tag 一致；`versionCode` = `1900000000 + run_number`，只增不减。
- App 内的更新检查比较四段版本号，所以「同上游版本但重打过补丁」的包也会被提示更新。

## 签名密钥

keystore 只存在于这个仓库的 Secrets 里。**丢了这个 keystore，后续构建的包就无法覆盖安装旧包**（需要卸载重装）。要备份，用：

```bash
gh secret list --repo <owner>/mithka-build   # 只能看到名字，看不到值
```

值读不回来，所以请在首次生成时自行另存一份 `release.jks` 与密码。
