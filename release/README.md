# 安装包

| 文件 | 大小 | 说明 |
|---|---|---|
| `dsh-mobile-3.0.0-signed.hap` | 6.00 MB | 当前版本 3.0.0（versionCode 3000000）；已签名，**只能装在签名证书 profile 里列出的设备上** |
| `dsh-mobile-2.0.0-signed.hap` | 2.75 MB | 旧版 2.0.0（versionCode 2000000）；已签名，**只能装在签名证书 profile 里列出的设备上** |
| `dsh-mobile-1.0.0-20261120-signed.hap` | 1.19 MB | 旧版 1.0.0，已签名，**只能装在签名证书 profile 里列出的设备上** |
| `dsh-mobile-1.0.0-20261120-unsigned.hap` | 1.12 MB | 旧版 1.0.0，未签名，需用自己的证书签名后再装 |

构建于 2026-11-26（3.0.0），`compatibleSdkVersion` / `targetSdkVersion` = 26.0.0，bundle 名 `com.dsh.mobile`。

## 为什么已签名包不一定能装

HarmonyOS 的调试证书（`.p7b` profile）里写死了允许安装的设备 UDID 列表。这份 signed HAP 是用开发者本机的调试证书签的，所以：

- 在作者自己已登记的设备上可以直接 `hdc install`；
- 换一台手机装会报 `9568289 / signature verify failed` 之类的错误。

## 用自己的证书签名（两种方式）

1. **DevEco Studio**：打开 `remote/app-shell` 工程，`File > Project Structure > Signing Configs` 勾选 `Automatically generate signature`（需登录华为账号），然后 `Build > Build Hap(s)`。
2. **命令行**：用 `hap-sign-tool.jar` 对自己生成的 `.p12` / `.cer` / `.p7b` 签名未签名包：

```bash
java -jar hap-sign-tool.jar sign-app \
  -keyAlias "<alias>" -signAlg "SHA256withECDSA" \
  -mode "localSign" -appCertFile "<your>.cer" -profileFile "<your>.p7b" \
  -inFile "dsh-mobile-1.0.0-20261120-unsigned.hap" \
  -keystoreFile "<your>.p12" -outFile "dsh-mobile-signed.hap" \
  -keyPwd "<keyPassword>" -keystorePwd "<storePassword>"
```

## 安装

```bash
hdc list targets                        # 确认设备
hdc install -r dsh-mobile-signed.hap
hdc shell aa start -a EntryAbility -b com.dsh.mobile
```

首次启动会直接进入配对向导：先在电脑的 DSH「设置 > 手机连接」面板里拿到二维码或 6 位配对码，再扫码或手输地址连接。安装包内不含任何服务器地址或令牌。

详细构建步骤见 [../docs/BUILD.md](../docs/BUILD.md)。
