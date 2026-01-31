# 65 内容制作 Cookbook：任务驱动动态 Group（Quest Exec 注册/卸载 + LuaNotify 推进）

本文是一份“把 Quest 当上层编排状态机”的实战配方：  
用 Quest 的 Exec 在运行时 **注册/卸载动态 group**，让一段场景玩法（遭遇战/房间/机关）成为任务流程的一部分，并用 **LuaNotify（AddQuestProgress）** 作为脚本→任务的稳定桥接。

与其他章节关系（强烈建议配合阅读）：

- `analysis/10-quests-deep-dive.md`：Quest 作为状态机 DSL 的全景。
- `analysis/27-quest-conditions-and-execs-matrix.md`：QuestCond/QuestContent/QuestExec 可用子集与参数语义（选型配方）。
- `analysis/12-scene-and-group-lifecycle.md`：动态 group 的加载/卸载与 suite 记录（QuestGroupSuites）。
- `analysis/60-content-authoring-cookbook-overview.md`：脚本缓存/持久化污染与调试工具箱（尤其 `/quest` 命令）。

---

## 65.1 你要做出来的“体验”

一个最典型的“任务驱动动态 group”内容：

1. `/quest add <mainId>` 或满足 Accept 条件后，任务开始
2. Quest beginExec：
   - 注册一个动态 group（把房间/玩法加载进场景）
   - （可选）通知 group：任务已开始（EVENT_QUEST_START）
3. 玩家在该 group 内完成目标（清怪/交互/区域达成…）
4. group 脚本通过 `ScriptLib.AddQuestProgress(key)` 上报
5. Quest finishCond（`QUEST_CONTENT_LUA_NOTIFY(key)`）命中，子任务完成
6. Quest finishExec：
   - （可选）通知 group：任务已完成（EVENT_QUEST_FINISH）
   - 卸载动态 group，清理现场

---

## 65.2 先把“数据分工”讲清楚：新增任务至少要动两类数据

在本仓库中：

### 65.2.1 主任务元数据：`resources/BinOutput/Quest/<mainId>.json`

由 `ResourceLoader.loadQuests()` 加载为 `MainQuestData`，当前实现只关心：

- `id/series/titleTextMapHash/rewardIdList...`（主线元信息）
- `subQuests[]`（子任务列表的 `subId/order/isMpBlock/isRewind/finishParent`）

**注意**：这个文件里即使有 acceptCond/finishCond 等字段，也会被 Gson 忽略（`MainQuestData.SubQuestData` 并不声明它们）。

### 65.2.2 子任务状态机：`resources/ExcelBinOutput/QuestExcelConfigData.json`

由 `QuestData` 加载，**这是你真正写 DSL 的地方**：

- `acceptCond/finishCond/failCond`（条件）
- `beginExec/finishExec/failExec`（副作用）

结论（内容作者必须记住）：

> 新增自制任务时，至少需要：  
> 1) 新增/修改 `BinOutput/Quest/<mainId>.json` 让系统知道 subId 列表  
> 2) 在 `QuestExcelConfigData.json` 里新增对应 subId 的 QuestData 条目，定义条件与 Exec

---

## 65.3 本配方的核心桥接：`QUEST_CONTENT_LUA_NOTIFY` + `AddQuestProgress(key)`

这是“只改脚本/数据”时最稳的任务推进套路之一：

1. 在 `QuestExcelConfigData.json` 的 `finishCond` 里写：
   - `type = QUEST_CONTENT_LUA_NOTIFY`
   - `param_str = <你的 key>`
2. 在 Lua（group 脚本）完成目标时调用：
   - `ScriptLib.AddQuestProgress(context, "<同一个 key>")`

ScriptLib 实现会：

- 给玩家 `PlayerProgress` 的 `questProgressCountMap[key]` +1
- 同时投递 `QUEST_COND_LUA_NOTIFY` 与 `QUEST_CONTENT_LUA_NOTIFY` 事件（见 `analysis/27` 的语义提醒）

因此你可以把 `key` 当作一个“脚本侧可控的信号名”。

---

## 65.4 最小可行配方（MVP）：一个子任务加载动态 group，完成后卸载

### 65.4.1 设计你的 ID 与 key

建议你先确定四个东西：

- `sceneId`：动态 group 所在场景
- `groupId`：玩法房间的 group
- `mainId/subId`：任务 ID（建议用你自己的命名空间）
- `key`：LuaNotify key（例如 `CQ_<subId>_DONE`）

### 65.4.2 在场景里准备好你的 group（动态 group 的“素材”）

1. 把 group 写进某个 block：`resources/Scripts/Scene/<sceneId>/scene<sceneId>_block<blockId>.lua`
2. group 脚本文件：`resources/Scripts/Scene/<sceneId>/scene<sceneId>_group<groupId>.lua`

关键建议：

- 若你希望该 group 在任务期间不要被“视野流式卸载”，把 group 条目加上：
  - `dynamic_load = true`
- 若你希望它遵循普通大世界卸载规则，则不要设置 `dynamic_load`（更省心，但可能走远就卸载）

### 65.4.3 group 脚本里：完成时上报 `AddQuestProgress(key)`

你只需要在“完成条件达成”的 action 里加一行：

```lua
ScriptLib.AddQuestProgress(context, "CQ_90000001_DONE")
```

建议把 key 做成常量，避免错拼：

```lua
local QUEST_KEY_DONE = "CQ_90000001_DONE"
```

### 65.4.4 写 `resources/BinOutput/Quest/<mainId>.json`（主任务骨架）

最小可用结构示意（字段可按需补充）：

```json
{
  "id": 900000,
  "series": 9999,
  "titleTextMapHash": 0,
  "rewardIdList": [],
  "subQuests": [
    { "subId": 90000001, "order": 1, "isRewind": true, "finishParent": true }
  ]
}
```

要点：

- `subQuests[].subId/order` 是必需的（决定子任务序）
- `finishParent=true` 可以让“子任务完成后主任务也视为完成”（适合 MVP）

### 65.4.5 在 `QuestExcelConfigData.json` 增加 subId 条目（状态机定义）

你需要新增一个对象（示意，字段可精简，但数组字段建议至少给空数组，避免 null）：

```json
{
  "subId": 90000001,
  "mainId": 900000,
  "order": 1,
  "acceptCond": [],
  "finishCond": [
    { "type": "QUEST_CONTENT_LUA_NOTIFY", "param": [0, 0], "param_str": "CQ_90000001_DONE" }
  ],
  "failCond": [],
  "beginExec": [
    { "type": "QUEST_EXEC_REGISTER_DYNAMIC_GROUP", "param": ["3", "199001001"], "param_str": "" },
    { "type": "QUEST_EXEC_NOTIFY_GROUP_LUA", "param": ["3", "199001001"], "param_str": "" }
  ],
  "finishExec": [
    { "type": "QUEST_EXEC_NOTIFY_GROUP_LUA", "param": ["3", "199001001"], "param_str": "" },
    { "type": "QUEST_EXEC_UNREGISTER_DYNAMIC_GROUP", "param": ["199001001", "0"], "param_str": "" }
  ],
  "failExec": [
    { "type": "QUEST_EXEC_UNREGISTER_DYNAMIC_GROUP", "param": ["199001001", "0"], "param_str": "" }
  ]
}
```

几个关键语义（来自当前实现）：

- `QUEST_EXEC_REGISTER_DYNAMIC_GROUP` 的 `param=["sceneId","groupId"]`  
  会调用 `scene.loadDynamicGroup(groupId)` 并把初始 suite 记录进 `mainQuest.questGroupSuites`。
- `QUEST_EXEC_NOTIFY_GROUP_LUA` 的 `param=["sceneId","groupId"]`  
  会向该 group 发 `EVENT_QUEST_START/FINISH`（eventSource=subId），适合让 group 做初始化/收尾。
- `QUEST_EXEC_UNREGISTER_DYNAMIC_GROUP` 的 `param=["groupId","unknown(0/1)"]`  
  目前第二个参数语义未明；实践中常填 `"0"`。注意它使用的是**玩家当前所在 scene**来卸载 group。

> 重要提醒：Quest Excel 是整表加载，新增条目意味着你要编辑这个巨大文件。  
> 工程化建议：在你自己的内容仓库里维护“拆分 JSON”，再用脚本合并生成最终文件（本仓库目前未内建该管线）。

---

## 65.5 调试与验收（必须掌握）

### 65.5.1 用 `/quest` 命令快速验证

1. `/quest add 900000`：把主任务加入玩家
2. `/quest triggers 90000001`：确认子任务注册了哪些触发器/条件
3. `/quest debug 900000`：打开主任务日志（看事件投递/命中）

### 65.5.2 验收清单

- 任务开始时：动态 group 被加载（可用 `/quest grouptriggers <groupId>` 验证 group 触发器存在）
- 在 group 内达成完成条件后：Lua 调用了 `AddQuestProgress(key)`，子任务完成
- 子任务完成后：动态 group 被卸载（或至少不再残留影响）

---

## 65.6 常见坑与边界（非常关键）

1. **动态 group 卸载失败**
   - `UNREGISTER_DYNAMIC_GROUP` 使用玩家当前 scene 卸载；如果玩家不在目标 scene，卸载会失败  
     → 设计上确保“完成事件”发生在该 scene 内；或让 group 自身在完成后进入“无实体态”以降低残留成本
2. **Quest Excel 新条目写了但不生效**
   - ScriptLoader/资源加载都是启动期行为：修改后重启服务器
   - 字段漏了导致 NPE（例如 beginExec/finishExec 为 null）：确保数组字段存在（即便是 `[]`）
3. **finishCond 不触发**
   - key 拼错：Lua 的 `AddQuestProgress(key)` 与 QuestExcel 的 `param_str` 必须完全一致
   - 你用了 Accept 阶段的 `QUEST_COND_LUA_NOTIFY` 想“上报就接任务”：本仓库语义有坑，优先走 `QUEST_CONTENT_LUA_NOTIFY`（见 `analysis/27`）

---

## 65.7 小结

- Quest 是“可存档阶段机”，动态 group 是“可加载的玩法房间”。两者用 Exec 串起来，就是最强的内容编排武器之一。
- 最稳的脚本→任务推进桥是：`QUEST_CONTENT_LUA_NOTIFY(key)` + `AddQuestProgress(key)`。
- 动态 group 的清理要保守：注意 `UNREGISTER_DYNAMIC_GROUP` 对 scene 的假设，设计上尽量让完成发生在目标场景内。

---

## Revision Notes

- 2026-01-31：首次撰写本配方；明确 Quest 数据分工（BinOutput 主任务 vs QuestExcel 子任务状态机）、动态 group 注册/卸载 Exec 的参数语义与边界，并给出 LuaNotify 推进的最小可行实现与调试清单。

