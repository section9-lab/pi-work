# 本地 lint 与钩子

## 为什么是这套

- **SwiftLint**：规则多、能写 `custom_rules`（正则 + `match_kinds` + 按目录生效）、有 `--strict` 和 baseline 机制，是“把团队约定写成可执行检查”最省事的入口。
- **swift-format**（Xcode 自带 `xcrun swift-format`）：只做格式化、没有自定义规则。本仓暂时不启用，避免一次性重排 158 个文件把 blame 冲掉；需要时可以对单个新文件跑 `xcrun swift-format format -i <file>`。
- 没有引入 SwiftFormat（第三方格式化器）：格式化不是当前痛点，多一个依赖只会多一份冲突。

## 文件

- `.swiftlint.yml`：规则配置（默认规则 + 4 条 opt-in + 7 条自定义规则）
- `.swiftlint.baseline.json`：引入规则时已存在的 338 条违规。**只对基线之外的新代码生效**
- `scripts/lint.sh`：`staged` / `all` / `files <paths>` / `baseline` 四种模式
- `scripts/check-local.sh`：复现 release workflow 的 `validate` job（含 tag 与 `MARKETING_VERSION` 一致性检查）
- `.githooks/pre-commit`、`.githooks/pre-push`
- `scripts/install-hooks.sh`：`git config core.hooksPath .githooks`

## 钩子如何工作

`pre-commit`（毫秒~秒级）

1. `git diff --cached --name-only --diff-filter=ACMR -- '*.swift'`
2. `swiftlint lint --config .swiftlint.yml --baseline .swiftlint.baseline.json --strict -- <这批文件>`
3. 有 error 或新 warning 就失败

`pre-push`

- 从 stdin 读 git 给的 ref 列表。`refs/tags/v*` → `scripts/check-local.sh <tag>`；否则 lint 分支相对 `origin/main` 改动的 Swift 文件
- **git 没有 `pre-tag` 钩子**，所以 tag 的检查只能在 push 时做。真正的“打 tag 前”检查请用 `scripts/check-local.sh v0.1.56` 再 `git tag`

## baseline 机制

SwiftLint 的 baseline 记录的是**每条违规的位置与内容哈希**，不是“忽略整个规则”。所以：

- 老文件新增一行违规 → 仍然报
- 老文件改动导致行号漂移 → 可能报旧违规（重新 `scripts/lint.sh baseline` 即可）
- 升级 SwiftLint 后建议重跑一次 baseline，并把 diff 一起提交

主动还债（修掉一批老违规）后也要重跑 baseline，否则修掉的那条会从基线里消失，但下次谁把同样的写法加回来就查不出来了。

## 加一条新规则

1. 在 `.swiftlint.yml` 的 `custom_rules` 里加，例如：

```yaml
  no_hardcoded_timeout:
    name: "No hardcoded timeout"
    regex: 'asyncAfter\(deadline: \.now\(\) \+ 1'
    message: "超时值放进常量，别写魔法数。"
    severity: warning
```

2. `scripts/lint.sh all` 看会报多少
3. 如果存量太多：`scripts/lint.sh baseline`，把基线更新和规则一起提交，并在 `docs/releases/*.md` 里说明
4. 让 AI 遵守：规则只对“新代码”有效，所以同步在 `AGENTS.md` 的硬规则里写一句

## 能力边界

- 自定义规则是**正则**，不能跨行、不看类型信息。需要语义检查（“新的 ViewModel 必须 `@MainActor`”“不许跨层调用某函数”）时，两条路：
  - 写一个基于 SwiftSyntax 的小命令行工具（Apple 官方库），挂到 `scripts/lint.sh` 里
  - 或者沿用本仓已有做法：把架构约束写成 XCTest（例如 `PiWorkTests/SidebarHoverActionsTests.swift:620-623` 直接断言源码结构）
- 目前 SwiftLint 只在本地钩子和手动命令里跑，**还没有进 GitHub Actions**。要进 CI 的话，加一个 `swiftlint` job 并固定版本（0.65.1），否则 baseline 会因版本差异抖动
