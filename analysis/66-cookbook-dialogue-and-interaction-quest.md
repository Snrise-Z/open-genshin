# 66 内容制作 Cookbook：对白/交互驱动的轻量任务（CompleteTalk vs Worktop/LuaNotify）

本文给你两条“轻量任务推进”配方：

1) **对白驱动**：玩家与 NPC 对话完成（CompleteTalk）→ 子任务完成  
2) **交互驱动（推荐）**：玩家点机关/选选项（SelectOption）→ `AddQuestProgress(key)` → 子任务完成

之所以给两条，是因为：在本仓库的实现里，Talk 系统更像“事件触发器”，对白内容大多仍由客户端资源决定；而交互/LuaNotify 更容易做到**只改脚本/数据**就可控推进。

与其他章节关系：

- `analysis/10-quests-deep-dive.md`：Quest 条件/执行器与 Lua 粘合点。
- `analysis/20-talk-cutscene-textmap.md`：TalkExec 覆盖与对白/叙事的工程边界。
- `analysis/21-worktop-and-interaction-options.md`：交互事件与参数语义（option/param1/param2）。
- `analysis/25-npc-and-spawn-pipeline.md`：如果你需要“自定义 NPC 出生点”，必须理解 Spawn 管线。

---

## 66.1 先讲清现实边界：Talk ≠ 你写的对白内容

在本仓库中，`TalkExcelConfigData.json` 被加载为 `TalkConfigData`，当前实现实际只使用：

- `id`（talkId）
- `questId`
- `npcId`（允许触发该 talk 的 NPC id 列表）
- `finishExec`（一小段服务端执行器）

对白文本本身往往仍由客户端决定：  
因此你“新增一个 talkId”如果客户端不认识，通常无法呈现你期望的剧情内容。

结论（内容作者视角）：

- **把 Talk 当成“玩家触发了一个叙事节点事件”**更准确  
  （你可以用它推进任务/触发脚本，但别期待它承载完整文本叙事，除非你同步改客户端资源）

---

## 66.2 配方 A：对白驱动（CompleteTalk → 完成子任务）

### 66.2.1 适用场景

- 你愿意复用现有 NPC 与现有 talkId（客户端已经有对白）
- 或你的环境允许你同时改客户端资源

### 66.2.2 数据联动关系（你必须对齐的 ID）

```
QuestExcel.finishCond: QUEST_CONTENT_COMPLETE_TALK(param[0]=talkId)
          ↑
TalkExcelConfigData.id == talkId
          ↑
玩家与 npcEntity 交互时触发 talkId（客户端发送）
```

并且：

- `TalkConfigData.npcId` 必须包含“NPC 实体的 configId”（实现里用这个做白名单匹配）

### 66.2.3 最小实现步骤

1) 在 `QuestExcelConfigData.json` 为 subId 写 finishCond：

```json
{ "type": "QUEST_CONTENT_COMPLETE_TALK", "param": [100001, 0], "param_str": "" }
```

2) 在 `TalkExcelConfigData.json` 确保存在 talkId=100001 的条目，并填：

- `id = 100001`
- `questId = <mainId>`（建议显式填；若不填且 questId<=0，会按“去掉末两位”推导）
- `npcId = [<npcId>]`

3) 确保世界里真的存在该 NPC（否则客户端无法发起对话）

### 66.2.4 常见坑

- **你写了 TalkExcel，但对话不计入任务完成**
  - `npcId` 不匹配 NPC 实体 id
  - `finishCond.param[0]` 写的不是 talkId
- **你新增了 talkId，但客户端没反应**
  - 客户端根本不知道这个 talkId（需要客户端资源/脚本支持）

---

## 66.3 配方 B（推荐）：交互驱动（SelectOption → LuaNotify → 完成子任务）

### 66.3.1 适用场景

- 你希望“只改服务端脚本/数据”就能做出可控任务推进
- 你不想依赖客户端对白资源

核心套路：

1) Quest finishCond 用 `QUEST_CONTENT_LUA_NOTIFY(key)`
2) group 脚本在玩家交互成功时调用 `AddQuestProgress(key)`

### 66.3.2 最小实现步骤

**Step 1：QuestExcel 写 finishCond（LuaNotify）**

```json
{
  "type": "QUEST_CONTENT_LUA_NOTIFY",
  "param": [0, 0],
  "param_str": "CQ_90000001_INTERACT"
}
```

**Step 2：group 脚本写交互 trigger**

- `EVENT_SELECT_OPTION` 条件：`evt.param1 == worktopConfigId` 且 `evt.param2 == optionId`
- action：`ScriptLib.AddQuestProgress(context, "CQ_90000001_INTERACT")`

示意：

```lua
function action_select_option(context, evt)
  ScriptLib.AddQuestProgress(context, "CQ_90000001_INTERACT")
  return 0
end
```

**Step 3：任务开始/阶段切换（可选，但很实用）**

你可以用 `QUEST_EXEC_NOTIFY_GROUP_LUA(sceneId, groupId)` 在任务开始/完成时给 group 发：

- `EVENT_QUEST_START`
- `EVENT_QUEST_FINISH`

让 group 自动打开/关闭交互点位。

### 66.3.3 为什么推荐它？

- 交互点（worktop gadget）完全由服务端控制：你能保证“交互一定发生”
- LuaNotify key 是纯字符串：不依赖客户端表
- 调试简单：你能在日志里直接 grep key

---

## 66.4 选型建议：什么时候用 Talk，什么时候用交互？

| 需求 | 推荐方案 |
|---|---|
| 只是要“跟某个 NPC 讲话一下就算完成” | Talk（CompleteTalk） |
| 需要“对话后触发复杂玩法/刷怪/切阶段” | Talk 触发 + group/quest exec 驱动（但对白内容仍依赖客户端） |
| 想做原创叙事但不改客户端 | 不建议强依赖 Talk；改用交互 + 提示/玩法表达 |
| 想完全可控地推进任务阶段 | 交互 + LuaNotify（最稳） |

---

## 66.5 调试与排障

- `/quest add <mainId>`：快速把任务挂到角色
- `/quest triggers <subId>`：确认 finishCond/handler 是否存在（以及是否命中）
- 如果你走 Talk：
  - 先验证 NPC 是否存在、能触发对话
  - 再验证 `TalkExcelConfigData` 的 `npcId` 是否匹配
- 如果你走 LuaNotify：
  - 重点查 key 是否一致、是否真的调用到了 `AddQuestProgress`

---

## 66.6 小结

- 在本仓库里把 Talk 当成“事件触发器”更合理；对白内容通常不是服务端脚本层能完全控制的。
- 想要高确定性的“轻量任务推进”，优先用 **交互 + LuaNotify**。
- 需要 NPC 出生点与对白链路时，再进入 Spawn/Talk 的更深层专题。

---

## Revision Notes

- 2026-01-31：首次撰写本配方；对比 CompleteTalk 与 SelectOption+LuaNotify 两种推进路径，并明确 Talk 在当前实现中的数据字段子集与客户端依赖边界。

