# {{TITLE}} · 复杂 Markdown 压力文档

这是第 **{{INDEX}}** 条回答，内容标记为 `{{SALT}}`。同一份正文包含中文、English、数字 0123456789、emoji 🧭，以及 **粗体**、*斜体*、~~删除线~~、`inline_code()` 和 [本地概念链接](#pipeline)。不请求远程图片或网络资源。

## 1. 渲染管线与边界条件 {#pipeline}

> 第一层引用：增量输入不能打断历史阅读。
>
> > 第二层引用：窗口的身份、正文内容和滚动位置应分别管理。
> >
> > - 在 fenced code 未闭合时保持可读。
> > - 完成输出后立即刷新，不能遗漏最后一个字符。

### 1.1 嵌套列表与任务清单

1. 获取会话快照
   - 保留全部消息的稳定 ID。
   - 区分 **内容变化** 与 **结构变化**。
     1. 初次出现的新消息需要插入列表。
     2. 已有回复的正文增量只更新当前回复。
        - 深层项目包含 `revision += 1` 和 *条件说明*。
2. 加载旧历史
   - [x] 分页响应按修订号验证
   - [x] 锚点恢复后不自动跳回底部
   - [ ] 图片和超大工具输出另行评估

#### 1.1.1 Swift：有泛型、异步与错误处理的代码

```swift
actor ReplyBuffer<Element: Sendable> {
    private var values: [Element] = []
    func append(_ value: Element) { values.append(value) }
    func drain() async throws -> [Element] {
        try Task.checkCancellation()
        defer { values.removeAll(keepingCapacity: true) }
        return values
    }
}
let messageID = "message-{{INDEX}}-{{SALT}}"
let result = try await service.load(sessionID: messageID)
```

##### 1.1.1.1 TypeScript：联合类型、字符串与长行

```typescript
type Event = { kind: "text"; delta: string } | { kind: "insert"; id: string };
const reduce = (state: ReadonlyMap<string, string>, event: Event) => {
  if (event.kind !== "text") return state;
  const next = new Map(state);
  next.set("{{INDEX}}", `${next.get("{{INDEX}}") ?? ""}${event.delta}`);
  return next;
};
const deliberatelyLongLine = "长行不应该改变旁边消息的宽度；0123456789_abcdefghijklmnopqrstuvwxyz_ABCDEFGHIJKLMNOPQRSTUVWXYZ_{{SALT}}_{{INDEX}}";
```

###### 1.1.1.1.1 六级标题：解析边界仍需正确

代码块后继续出现一段带有 **粗体嵌套 *强调*** 的正文，用来检查块间间距、换行与布局高度。对照组和候选组收到完全相同的内容，而不是给候选组简化后的文档。

## 2. 表格、对齐与多种语言

| 模块 | 输入类型 | 是否改变消息 ID | 处理方式 | 说明 |
| :--- | :---: | ---: | :--- | :--- |
| 当前回复 | `text.delta` | 否 | 局部订阅 | 中文 mixed English |
| 历史分页 | `history.page` | 是 | 更新窗口 | 保留重叠消息 |
| 工具结果 | `tool.result` | 可能 | 保守地通知 | 不作错误的静默优化 |
| 会话切换 | `session.select` | 是 | 重建身份 | 取消旧订阅 |
| 输出完成 | `turn.done` | 否 | 立即刷新 | 末尾不能丢失 |
| 输出失败 | `turn.error` | 可能 | 保留正文 | 展示可恢复状态 |

```python
from dataclasses import dataclass
@dataclass(frozen=True)
class Window:
    start: int
    end: int
    def contains(self, index: int) -> bool:
        return self.start <= index < self.end
assert Window(0, 100).contains(99)
```

```sql
WITH recent AS (
  SELECT id, role, revision FROM messages
  WHERE session_id = :session_id
  ORDER BY created_at DESC LIMIT 100
)
SELECT role, COUNT(*) AS count FROM recent GROUP BY role;
```

```json
{
  "session": "{{SALT}}",
  "message": {{INDEX}},
  "window": { "size": 100, "overlap": 40 },
  "features": ["streaming", "history", "stable-anchor"],
  "nested": { "enabled": true, "fallback": null }
}
```

## 3. 差异、命令与最终检查

```diff
- invalidateEntireConversation(event)
+ if (event.isContentOnly) updateCurrentReply(event)
+ else invalidateWindowStructure(event)
```

```bash
set -euo pipefail
printf '%s\n' "session={{SALT}} message={{INDEX}}"
for scenario in open history streaming; do
  run_benchmark --scenario "$scenario" --configuration Release
done
```

---

**结论段落**：窗口上限与数据获取页大小不是同一个概念。历史消息可以继续缓存，挂载范围只覆盖需要展示的 100 条。主线程采样间隔不是 GPU FPS，进程内 Host fixture 也不代表真实磁盘和网络时延。最后再放一行转义字符：\*不是强调\*、\[不是链接\]、路径 `src/render_pipeline/{{INDEX}}.swift`。

> 收尾引用：先验证正确性，再比较同一复杂度、同一输入频率下的 CPU 和布局耗时。
