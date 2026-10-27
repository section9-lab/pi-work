<div align="center">
  <img src="PiWork/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="112" alt="pi-work 应用图标">
  <h1>pi-work — Pi Coding Agent 原生 macOS 桌面端</h1>
  <p><strong>让 Pi 为你工作。</strong></p>
  <p>使用 Swift 和 SwiftUI 构建的轻量 Pi Coding Agent 图形客户端（GUI）。在简洁的 Mac 原生界面中完成 AI 对话、编程任务、技能与扩展管理，以及定时工作。</p>
  <p>
    <a href="https://github.com/section9-lab/pi-work/releases/latest"><strong>下载 macOS 版</strong></a>
    &nbsp;&nbsp;·&nbsp;&nbsp;
    <a href="#下载安装">安装说明</a>
  </p>
  <p><a href="README.md">English</a> · <strong>简体中文</strong></p>
</div>

![在 pi-work 原生 macOS 桌面界面中使用 Pi Coding Agent](docs/images/work.png)

## 在 Mac 桌面上使用 Pi Coding Agent

[Pi Coding Agent](https://github.com/earendil-works/pi) 提供编程代理的命令行工具和 SDK。pi-work 为它提供原生 macOS 桌面界面：选择项目、描述目标，然后在图形界面中查看执行过程和结果。

这个项目的出发点，是让 Pi 拥有极简、流畅、资源占用小的 Mac 客户端。界面使用 Swift 和 SwiftUI 编写，代理在应用内置的独立进程中运行。Chat、Work、Skills、Extensions 和 Schedule 围绕日常工作展开，让常用功能容易找到。

## 可以做什么

- **与 Pi 对话和编程**：在 Chat 中进行日常对话，或在 Work 中关联本地项目文件夹，为任务选择 Git 分支和访问级别。
- **选择模型服务商**：使用应用中提供的 OAuth 或 API Key 方式连接服务商，为每个会话选择模型和思考强度。
- **管理技能和扩展**：浏览、安装和管理 Pi 生态中的 Skills 与 Extensions。
- **安排定时任务**：自动执行重复工作并查看每次运行。定时任务需要 pi-work 保持运行。
- **使用原生 Mac 界面**：支持浅色、深色和跟随系统外观，提供英语、简体中文、繁体中文、日语、韩语和西班牙语界面。

## 下载安装

**[从 GitHub Releases 下载最新 macOS 版本](https://github.com/section9-lab/pi-work/releases/latest)。** 系统要求为 macOS 13 Ventura 或更高版本，分别提供 Apple Silicon 和 Intel 的 DMG 安装包。

在最新版本页面的 **Assets** 中选择适合你的文件。下表文件名中的 `VERSION` 代表版本号。

| Mac 类型 | DMG 安装包 |
| --- | --- |
| Apple Silicon — M 系列芯片 | `PiWork-VERSION-macos-arm64.dmg` |
| Intel Mac | `PiWork-VERSION-macos-x86_64.dmg` |

[查看所有版本](https://github.com/section9-lab/pi-work/releases)。每个版本还提供 `SHA256SUMS.txt`，用于校验下载文件。

不确定自己的 Mac 类型？打开苹果菜单，选择**关于本机**。如果显示**芯片**，请选择 Apple Silicon 版；如果显示**处理器**，请选择 Intel 版。

### 安装步骤

1. 下载适合你的 Mac 的 DMG 文件。
2. 打开 DMG，将 **PiWork** 拖入 Applications 文件夹。
3. 从 Applications 启动 PiWork，登录后在设置中连接你想使用的模型服务商。

> [!IMPORTANT]
> 当前构建使用临时签名（ad-hoc signing），尚未经过 Apple 公证。首次启动时，macOS 可能提示无法验证开发者。在 Finder 中打开 Applications，按住 Control 键点按 PiWork，选择**打开**并再次确认。请仅从本仓库的 Releases 页面下载安装包。

## 按需扩展 Pi

在应用中浏览 Skills 和 Extensions，搜索或筛选目录，找到需要的能力并直接安装到 pi-work 的独立环境中。终端中已有的 Pi 配置保持不变。

<p align="center">
  <img src="docs/images/skills.png" width="49%" alt="在 pi-work Mac 客户端中浏览和安装 Pi 技能">
  <img src="docs/images/extensions.png" width="49%" alt="在 pi-work 中管理 Pi Coding Agent 扩展">
</p>

## 开始第一个任务

1. 选择 **Chat** 开始不关联项目的对话，或选择 **Work** 关联本地项目文件夹。
2. 选择模型、思考强度和访问级别。
3. 描述你希望完成的目标。在同一个会话中查看工具调用、执行进度和授权请求。

发现问题或有建议？欢迎[提交 Issue](https://github.com/section9-lab/pi-work/issues)。

## 常见问题

### 可以不用终端使用 Pi Coding Agent 吗？

可以。pi-work 是 Pi 在 macOS 上的图形桌面客户端。安装应用、连接模型服务商后，即可开始对话或项目任务。

### 需要先安装 Pi、Node.js 或 Bun 吗？

不需要。应用内置代理宿主和运行时，使用下载的安装包无需另行安装命令行工具。

### 会与终端中的 Pi 共用配置吗？

pi-work 使用独立的代理环境来保存设置、服务商连接、技能和扩展。即使你已在终端中使用 Pi，也需要在应用内配置服务商。

### pi-work 属于上游 Pi 项目吗？

pi-work 是基于 Pi Coding Agent SDK 构建的独立桌面客户端。底层代理框架和命令行工具请参阅[上游 Pi 仓库](https://github.com/earendil-works/pi)。

### 支持 Windows 或 Linux 吗？

pi-work 目前面向 macOS。Apple Silicon 和 Intel 版本均可从 [GitHub Releases](https://github.com/section9-lab/pi-work/releases/latest) 下载。
