<div align="center">
  <img src="PiWork/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="112" alt="pi-work app icon">
  <h1>pi-work</h1>
  <p><strong>Let pi work for you.</strong></p>
  <p>A calm, native macOS home for AI conversations, project work, skills, extensions, and scheduled tasks.</p>
  <p>
    <a href="https://github.com/section9-lab/pi-work/releases/download/v0.1.9/PiWork-0.1.9-macos-arm64.dmg"><strong>Download for Apple Silicon</strong></a>
    &nbsp;&nbsp;·&nbsp;&nbsp;
    <a href="https://github.com/section9-lab/pi-work/releases/download/v0.1.9/PiWork-0.1.9-macos-x86_64.dmg"><strong>Download for Intel</strong></a>
    &nbsp;&nbsp;·&nbsp;&nbsp;
    <a href="https://github.com/section9-lab/pi-work/releases/latest">Latest release</a>
  </p>
</div>

![The pi-work Work screen](docs/images/work.png)

## A lighter desktop agent

Codex and Claude are broad agent platforms with connected tools, parallel workflows, and expanding product ecosystems. That breadth is valuable when you want the full experience of a single vendor. pi-work makes a different tradeoff: it keeps the desktop layer focused and puts the essential loop first — choose a project, describe the outcome, and review the work.

- **Simple by default.** Chat, Work, Skills, Extensions, and Schedule are easy to find without turning the app into a dashboard.
- **Lightweight by design.** A native SwiftUI interface, restrained chrome, and progressive disclosure keep the product small in scope and easy to navigate.
- **Built to stay responsive.** Agent execution sits behind a quiet, focused interface instead of filling the screen with permanent panels and controls.
- **Open model choice.** Connect any provider supported by pi rather than tying your desktop workflow to one model vendor.

## Stay focused on the work

pi-work gives [pi coding agent](https://github.com/badlogic/pi-mono) a native Mac interface. Start a casual conversation, or connect a local project folder and let pi work inside a clear workspace, Git branch, and access boundary.

- **Chat and Work** keep everyday conversations separate from project tasks while preserving the context of every session.
- **Your choice of models** lets you connect OAuth or API key providers supported by pi, then choose a model and thinking effort for each session.
- **Skills and Extensions** make it easy to discover, install, and manage capabilities from the open pi ecosystem.
- **Schedule** automates recurring work and keeps every run in view. Scheduled tasks run while pi-work is open.
- **Made for macOS** with light, dark, and system appearances, plus English, Simplified Chinese, Traditional Chinese, Japanese, Korean, and Spanish interfaces.

## Download

pi-work requires macOS 13 Ventura or later.

| Your Mac | Download v0.1.9 |
| --- | --- |
| Apple Silicon — M1, M2, M3, M4, or newer | [PiWork-0.1.9-macos-arm64.dmg](https://github.com/section9-lab/pi-work/releases/download/v0.1.9/PiWork-0.1.9-macos-arm64.dmg) |
| Intel Mac | [PiWork-0.1.9-macos-x86_64.dmg](https://github.com/section9-lab/pi-work/releases/download/v0.1.9/PiWork-0.1.9-macos-x86_64.dmg) |

[Browse all releases](https://github.com/section9-lab/pi-work/releases) · [Verify your download with SHA256SUMS.txt](https://github.com/section9-lab/pi-work/releases/download/v0.1.9/SHA256SUMS.txt)

Not sure which Mac you have? Open the Apple menu and choose **About This Mac**. If you see **Chip**, download the Apple Silicon version. If you see **Processor**, download the Intel version.

### Install

1. Download the DMG that matches your Mac.
2. Open the DMG and drag **PiWork** into your Applications folder.
3. Launch PiWork from Applications, sign in, and connect your preferred model provider in Settings.

> [!IMPORTANT]
> Current builds are ad-hoc signed and are not notarized by Apple. On first launch, macOS may say it cannot verify the developer. In Finder, open Applications, Control-click PiWork, choose **Open**, then confirm once more. Only download pi-work from this repository's Releases page.

## Extend pi as you go

Browse Skills and Extensions without leaving the app. Search or filter the catalogs, find the capability you need, and install it directly into pi-work's isolated environment. Your terminal pi configuration is left untouched.

<p align="center">
  <img src="docs/images/skills.png" width="49%" alt="The pi-work Skills Catalog">
  <img src="docs/images/extensions.png" width="49%" alt="The pi-work Extensions Catalog">
</p>

## Start your first task

1. Choose **Chat** for a conversation without a project, or choose **Work** to connect a local project folder.
2. Select a model, thinking effort, and access level.
3. Describe the outcome you want. pi-work keeps tool calls, execution progress, and approval requests together in the same session.

Found a problem or have an idea? [Open an issue](https://github.com/section9-lab/pi-work/issues).
