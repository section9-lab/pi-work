# 本地 lint 与钩子

## 为什么是这套

- **SwiftLint**：规则多、能写 `custom_rules`（正则 + `match_kinds` + 按目录生效）、有 `--strict` 和 baseline 机制，是“把团队约定写成可执行检查”最省事的入口。
- **swift-format**（Xcode 自带 `xcrun swift-format`）：只做格式化、没有自定义规则。本仓暂时不启用，避免一次性重排 158 个文件把 blame 冲掉；需要时可以对单个新文件跑 `xcrun swift-format format -i <file>`。
- 没有引入 SwiftFormat（第三方格式化器）：格式化不是当前痛点，多一个依赖只会多一份冲突。

## 文件

- `.swiftlint.yml`：规则配置（默认规则 + 4 条 opt-in + 7 条自定义规则）
- `scripts/lint-budget.json`：存量违规预算，按「规则 + 文件 → 条数」记录（当前 121 组 / 330 条）。**只对预算之外的新违规生效**
- `scripts/lint_gate.py`：读 SwiftLint 的 JSON 报告，跟预算比条数；`check` / `write` 两个动作
- `scripts/test_lint_gate.py`：预算闸自身的单测（`scripts/check-local.sh` 会跑）
- `scripts/lint.sh`：`staged` / `all` / `files <paths>` / `baseline` 四种模式
- `scripts/check-local.sh`：复现 release workflow 的 `validate` job（含 tag 与 `MARKETING_VERSION` 一致性检查）
- `.githooks/pre-commit`、`.githooks/pre-push`
- `scripts/install-hooks.sh`：`git config core.hooksPath .githooks`

## 钩子如何工作

`pre-commit`（毫秒~秒级）

1. `git diff --cached --name-only --diff-filter=ACMR -- '*.swift'`
2. `swiftlint lint --config .swiftlint.yml --reporter json --output <tmp> -- <这批文件>`
3. `python3 scripts/lint_gate.py check --partial --report <tmp>`：这批文件里出现预算之外的违规就失败（error 和 warning 都算）

`pre-push`

- 从 stdin 读 git 给的 ref 列表。`refs/tags/v*` → `scripts/check-local.sh <tag>`；否则 lint 分支相对 `origin/main` 改动的 Swift 文件
- **git 没有 `pre-tag` 钩子**，所以 tag 的检查只能在 push 时做。真正的“打 tag 前”检查请用 `scripts/check-local.sh v0.1.56` 再 `git tag`

## 预算机制（为什么不用 SwiftLint 自带的 baseline）

SwiftLint 的 `--baseline` 按**文件 + 行号 + 消息文本**匹配，这对尺寸类规则是错的：

- `file_length` 的违规报在**文件最后一行**，消息里写着「currently contains 5767 lines」
- 于是文件少一行（5765），行号和文本同时变 → 这条存量违规就被当成新违规
- 同一个坑还有 `type_body_length`、`function_body_length`、`cyclomatic_complexity`：被测的东西一改大小，文本就变

实测过：给一个带存量 `file_length` 的文件尾部加一行注释，旧机制立刻红；`ChatView.swift` 那三条就是这么一直卡着 `scripts/check-local.sh` 的。

所以改成**按条数**记预算：`scripts/lint-budget.json` 里每个 `规则|文件` 一个数字。

- 同规则、同文件、条数不超 → 放行，行号和消息怎么漂都无所谓
- 多一条，或出现了从没有过的「规则 + 文件」→ 失败，并打印预算/当前条数
- 部分文件模式（`staged` / `files`）加 `--partial`，不会把没 lint 的文件误报成“债还清了”

已知取舍：**在同一文件同一规则下修掉一条、又加一条，会被放过**。因为键里不含行号和文本，这是为了让 key 稳定必须付的代价；这种交换只能靠 code review。

主动还债后跑 `scripts/lint.sh baseline` 收紧预算，把 diff 一起提交。升级 SwiftLint 后也建议重跑一次并与升级分开提交，便于看清版本差异带来的条数变化。

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
3. 如果存量太多：`scripts/lint.sh baseline`，把预算更新和规则一起提交，并在 `docs/releases/*.md` 里说明
4. 让 AI 遵守：规则只对“新代码”有效，所以同步在 `AGENTS.md` 的硬规则里写一句

## 能力边界

- 自定义规则是**正则**，不能跨行、不看类型信息。需要语义检查（“新的 ViewModel 必须 `@MainActor`”“不许跨层调用某函数”）时，两条路：
  - 写一个基于 SwiftSyntax 的小命令行工具（Apple 官方库），挂到 `scripts/lint.sh` 里
  - 或者沿用本仓已有做法：把架构约束写成 XCTest（例如 `PiWorkTests/SidebarHoverActionsTests.swift:620-623` 直接断言源码结构）
- 目前 SwiftLint 只在本地钩子和手动命令里跑，**还没有进 GitHub Actions**。要进 CI 的话，加一个 `swiftlint` job 并固定版本（0.65.1），否则预算会因版本差异抖动
