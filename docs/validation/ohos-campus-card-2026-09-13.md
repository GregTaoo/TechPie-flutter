# OHOS 校园卡验证记录（2026-09-13）

## 代码同步

- 上游：`HeZeBang/TechPie-flutter` 的 `master`，提交 `9ac73e8c6501d059f76749c7fa3a4113e55a0371`。
- 合并提交：`c27e816`，保留本地校园卡功能及 OHOS 依赖，合入上游课程录播与 Android 发布配置。
- 处理了依赖、功能入口、Android Gradle 配置及 Kotlin 文件迁移冲突；校园卡组件包名和快捷方式跟随上游迁移到 `club.geekpie.techpie`。
- 保留依赖锁文件一致性检查，移除与本次 OHOS 支持直接冲突的“禁止 OHOS 依赖”检查。
- 本地验证不代表远程 GitHub Actions 已运行，也不代表向上游提交或合并了 PR。

## 环境及网络边界

- DevEco Studio：`6.0.1.251`；其已有应用区域配置为 `CN`，未修改 macOS 全局地区。
- 模拟器：Mate 70 Pro，HarmonyOS 6.0.1 / API 21，arm64。
- OHOS Flutter：`br_3.27.4-ohos-1.0.4`，提交 `269265738b3e388113f81f82f5aaa101011f3e18`，工具识别版本 `3.27.5-ohos-1.0.4`，Dart 3.6.2。
- 上游 Flutter 对照：3.27.4 / Dart 3.6.2。
- TechPie 会话接口使用 `http://localhost:3000/api/auth/third-party/ecard`。通过 `hdc rport tcp:3000 tcp:3000` 连接宿主机已有的本地 API。
- 校园卡业务请求仍按项目现有架构直连 `ecard.shanghaitech.edu.cn`。测试入口只允许 localhost、127.0.0.1 和该校园 eCard 域名，拒绝生产 TechPie API 及其他地址。
- OPENID 由仓库外的临时配置注入，没有写入源码或本记录。相机权限及离线授权开通均已得到用户明确允许。没有提交真实支付。

## 发现并修复的问题

1. **OHOS 没有扫码适配器。** 接入 OpenHarmony-SIG 原生扫码实现，保持原有 Android/iOS 的 mobile_scanner 版本；增加 OHOS 相册选择通道。
2. **扫码库的 Dart 解码逻辑拒绝 OHOS。** 实测图片已被原生解码，但 Dart 抛出“Only Android, iOS and macOS are supported”。增加 OHOS 解码适配，测试图片现在可正确识别。
3. **相机启动失败被误判为成功。** mobile_scanner 把失败保存在控制器状态而不抛出；现在检查并传播该状态，允许后续重试。
4. **原生相机异步失败没有回传。** 补充 MethodResult 错误响应，避免启动一直等待。
5. **模拟器不支持闪光灯 API，连带阻断相机。** 去掉启动时无条件关闭闪光灯的调用；不支持的手电筒标记为不可用，不影响预览和解码。
6. **OHOS 联网状态始终被当成在线。** 增加系统网络查询与变化事件通道；原生通道失败不再伪装为在线。
7. **触觉反馈阻塞页面切换。** 复现点击 Activity 不切换；设备日志显示振动权限错误，而 OHOS 引擎异常路径没有回复。补充 VIBRATE 权限并为可选反馈加超时，Activity 标签已能正常切换。

原生扫码源码来源、固定提交及本地调整见 `ohos/entry/src/main/ets/campuscard/scanner/UPSTREAM.md`，源码保留许可证说明。

## 验证结果

| 检查 | 结果及边界 |
| --- | --- |
| localhost OPENID 登录 | 通过，使用用户提供的 OPENID |
| 安全存储读回 | 通过 |
| 系统联网查询与网络事件 | 通过；断网错误分支另有回归测试 |
| 亮度设置及恢复 | 通过 |
| 触觉反馈结束、页面不被阻塞 | 通过；不代表已验证实体振动手感 |
| 相机启动及停止 | 严格检查通过；已在 UI 确认相机预览显示 |
| 二维码图片解码 | 通过，使用不包含支付指令的固定测试字符串 |
| 相册选择器 | 已在 UI 打开并取消，返回扫码页面正常；模拟器相册为空，未完成从相册选择现有照片的整条流程 |
| 卡片及余额 | 通过，并检查了真实付款码页面 |
| 个人资料 | 通过，并检查了详情页 |
| 在线付款码生成及状态轮询 | 通过，UI 显示付款码；未交给收款终端扣款 |
| 流水列表及详情接口 | 通过，Activity 页面切换和列表显示也已复测 |
| 消费限额读取 | 通过，未修改限额 |
| 改密页面初始化 | 通过，未修改密码 |
| 离线授权状态 | 通过 |
| 离线授权开通及生成码 | 通过，凭据保存在测试模拟器 |
| 拒绝所有 HTTP 连接时生成离线码 | 通过；这是应用网络请求层的断网测试，没有断开宿主机网络 |
| 会话恢复 | 通过 |
| OHOS Flutter 完整测试 | 383 项通过 |
| 上游 Flutter 完整测试 | 382 项通过；少一项仅在 OHOS 枚举存在时运行的平台回归 |
| 两套 Flutter 静态分析 | 均无问题 |
| Android Debug APK | 构建通过，覆盖包名迁移后的原生组件编译 |
| OHOS HAP | 已编译并在模拟器安装、运行；使用无签名调试包，未验证真机签名发布 |

最后一轮自动设备检查为 **17 项通过、0 项失败**。相机最终通过发生在开启权限、修复闪光灯兼容性之后；早期宽松的启动检查已被替换，不能作为相机通过依据。

未执行真实扫码扣款、充值下单、改密、修改限额或卡片解绑。这些写操作及实体终端收款、实体设备闪光灯、声音和振动效果不在本次“已通过”范围内。

## 复测入口

`tool/ohos_local_smoke.dart` 在启动前启用 localhost，完成检查后进入普通 TechPie 界面。必须在隔离测试设备使用：

```sh
hdc rport tcp:3000 tcp:3000
flutter build hap --debug \
  --target tool/ohos_local_smoke.dart \
  --dart-define-from-file=/path/outside/repository/ecard-test.json \
  --dart-define=ECARD_TEST_CAMERA=true \
  --dart-define=ECARD_TEST_OFFLINE=true
```

外部 JSON 只需要 `ECARD_TEST_OPENID` 字段。`ECARD_TEST_OFFLINE=true` 会在本机没有授权时开通离线授权，并生成测试码、使用本地离线计数；仅在已获授权时启用。测试包包含编译时注入的凭据，不应分发。

本地模拟器接受 `ohos/entry/build/default/outputs/default/entry-default-unsigned.hap`。Flutter CLI 会提示配置调试签名，但已生成的无签名 HAP 可以在该模拟器安装；这不能推导出真机可安装。

本次已重新构建 `--target lib/main.dart` 且不带测试 define，并在模拟器替换自动测试包。已检查 HAP 的 Dart kernel，不含 `OHOS_SMOKE` 标记或注入的测试 OPENID。已保存的 localhost 开关和校园卡会话保留。
