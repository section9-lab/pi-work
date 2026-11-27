# PiWork — 开发与 AI 协作规则

本文件是仓库里所有自动化（人、pi、其它 agent）的共同约定。**改完代码必须自己跑下面“完成标准”里对应的命令**，不要等 CI。

## 仓库结构

- `PiWork/`：macOS 应用（SwiftUI，少量 AppKit 互操作）
- `AgentHost/`：TypeScript（Bun）实现的 agent host，通过 stdio 上的 ACP 协议与应用通信
- `PiWorkTests/`：XCTest；`AgentHost/tests/`：`bun test`
- `scripts/`：打包、检查、发布脚本
- `project.yml`：XcodeGen 工程定义。`*.xcodeproj` 是生成物，**不要提交**

## 常用命令

标签：命令

- 生成工程：`xcodegen generate`
- 编译：`xcodebuild -project pi-work.xcodeproj -scheme PiWork -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedDataStore build`
- 单个测试类：`xcodebuild test -project pi-work.xcodeproj -scheme PiWork -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedDataStore -only-testing:PiWorkTests/SessionStoreTests`
- 全量原生测试：同上，去掉 `-only-testing`
- Host 检查：`cd AgentHost && bun run typecheck && bun test`
- Lint（只查暂存文件）：`scripts/lint.sh`
- Lint（全仓）：`scripts/lint.sh all`
- Lint（指定文件）：`scripts/lint.sh files PiWork/Foo.swift`
- 重写基线（仅在主动还债后）：`scripts/lint.sh baseline`
- 复现 CI validate：`scripts/check-local.sh`（加 `WITH_TESTS=1` 再跑原生测试）
- 安装 git 钩子：`scripts/install-hooks.sh`

## 硬规则（由 `.swiftlint.yml` 强制，新代码不允许新增违规）

- 禁止 `print(`：用 `os.Logger` / `Logger`
- 禁止 `try!`、`as!`：用 `do/catch`、`try?`、`as?` + `guard`
- 禁止 `AnyView(`：用 `@ViewBuilder`、泛型或具体返回类型
- 不写 `DispatchQueue.main.async`：用 `@MainActor` / `await MainActor.run`
- 不留 `TODO(` / `FIXME(`：要么清掉，要么写成带 issue 链接的注释
- `PiWork/Features/` 里不许写死 UI 文案：走 `L10n.string("key")`，并在 6 个 `Localizable.strings` 里补齐
- 行长警告 160 / 错误 400；单文件警告 1200 / 错误 2500；函数体警告 180 / 错误 400

新增规则：改 `.swiftlint.yml` 的 `custom_rules`，然后 `scripts/lint.sh baseline` 把存量记进基线。细节见 `docs/lint.md`。

## 代码约定（评审会看，lint 查不到）

- 状态与视图分离：`SessionStore` 这类 `@MainActor` store 负责状态，View 只做投影
- 会话/列表类逻辑必须对“host 目录”负责：本地行只能来自“用户当前正在看的会话”，其余以 host 返回的列表为准（参考 `SessionStore.reconcileSessions`）
- 写文件、动网络、跑子进程的路径要能被取消（`Task.checkCancellation()`）
- 新增字符串必须同时出现在 `en/es/ja/ko/zh-Hans/zh-Hant` 六种语言里，`PiWorkTests/LocalizationTests.swift` 会检查
- 新增依赖前先说明理由和收益；能用系统框架就不要引入第三方库

## 完成标准

- 只改 Swift：`scripts/lint.sh` 通过 + 相关测试类通过
- 改了 `AgentHost/`：`cd AgentHost && bun run typecheck && bun test`
- 改了发布链路（`project.yml`、`scripts/`、`.github/`）：`scripts/check-local.sh`
- 要发版：`project.yml` 的 `MARKETING_VERSION` + `docs/releases/<version>.md` + tag，`pre-push` 会自动跑 `scripts/check-local.sh`

## Git 钩子

`scripts/install-hooks.sh` 会把 `core.hooksPath` 指到 `.githooks/`：

- `pre-commit`：只 lint 暂存中的 Swift 文件（秒级）
- `pre-push`：推 `v*` tag 时跑 `scripts/check-local.sh`；推分支时只 lint 该分支改动的文件

git 没有 `pre-tag` 钩子，所以“打 tag 前检查”只能落在 `pre-push` 或发布脚本上。绕过的办法只有 `git push --no-verify`，请在 PR 里说明原因。
