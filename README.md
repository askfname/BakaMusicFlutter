# BakaMusicFlutter

BakaMusicFlutter 是 [BakaMusicAndroid](https://github.com/askfname/BakaMusicAndroid) 的 Flutter 重构版本。该项目是基于插件的音乐播放器，不内置音源，搜索、榜单、歌曲详情、播放链接和歌词等数据由用户安装的 JS 音源插件提供。

## 功能

- 首页每日推荐，可切换音源与榜单。
- 按音源搜索歌曲，支持分页、搜索历史、收藏、下载和加入歌单。
- 播放器支持播放队列、顺序/单曲循环/随机模式、音质选择及解析失败后的低音质重试。
- 支持 LRC、QRC、YRC 等歌词格式，提供同步滚动和全屏歌词视图。
- 支持收藏歌曲、添加歌单、歌单导入、搜索历史。
- 可从本地文件或 HTTPS 地址安装插件，也可使用订阅批量安装/更新；插件支持启用、禁用和排序。
- Android 后台播放、媒体通知与锁屏控制。

## 技术栈

- Flutter / Dart，Material 风格界面
- 播放与后台媒体控制：`just_audio`、`audio_service`
- JS 插件运行：`quickjs_engine`
- 本地偏好与会话：`shared_preferences`
- 网络图片：`cached_network_image`
- 其他：`path_provider`、`crypto`、`pointycastle`、`enough_convert`

## 插件说明

- JS 插件在 QuickJS worker 中运行，通过宿主提供的接口访问音源能力；插件路由按照启用状态和优先级选择音源。
- 远程插件安装地址要求 HTTPS。插件文件最大 5 MiB，网络响应最大 16 MiB；安装清单提供 SHA-256 时会校验该值。也支持本地文件安装。
- 插件可通过宿主网络接口访问 HTTP(S) 服务。网络请求会限制响应大小、检查私网地址及重定向目标。
- 音质选项和可用功能由插件实现决定；解析失败时播放器会尝试较低音质。

请仅安装并使用可信插件，并遵守音源服务的条款及所在地法律法规。

## 环境要求

- Flutter SDK（Dart 版本需满足 `pubspec.yaml` 中的 SDK 约束：`^3.13.4`）
- Android SDK
- JDK 17

Android Gradle 插件、Kotlin 插件和 Gradle Wrapper 由项目配置管理。SDK 平台/NDK 版本由 Flutter Android 构建配置提供；首次构建需要联网下载 Dart/Gradle/Maven 依赖。请先安装 Flutter 与 Android 工具链，并确认 `flutter doctor` 检查通过。

## 获取依赖与运行

在项目根目录执行：

```sh
flutter pub get
flutter run
```

也可以在 Android Studio 或 VS Code 中打开项目。Android 平台目录中的 `local.properties` 是本机 SDK 路径配置，不要直接复用其他开发机的绝对路径。

## 测试与构建

运行 Dart 单元及 widget 测试：

```sh
flutter test
```

构建 Android Debug APK：

```sh
flutter build apk --debug
```

Android 集成测试位于 `integration_test/`，`network_install_test.dart` 会访问外部网络及第三方服务，测试结果可能受网络和服务可用性影响。

构建 Release APK：

```sh
flutter build apk --release
```

Release 构建需要按 `android/app/build.gradle.kts` 的配置提供 `android/key.properties` 和对应 keystore。

## 项目结构

```text
lib/
	data/       本地数据仓库、歌曲模型与播放会话存储
	models/     媒体数据模型
	plugin/     JS/LX 插件运行、安装、网络访问与路由
	service/    音源服务和播放服务
	ui/         页面、视图模型、播放器组件与主题
	util/       播放、歌词、下载及通用工具
	main.dart   应用入口与依赖初始化
android/      Android 宿主、原生下载和平台通道
test/         单元与 widget 测试
integration_test/  插件与平台集成测试
```