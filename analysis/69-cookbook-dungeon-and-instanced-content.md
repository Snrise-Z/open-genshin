# 69 内容制作 Cookbook：副本/实例内容（Dungeon 进入 → Challenge 驱动通关 → DungeonSettle 收尾）

本文给你一套“实例内容”的落地配方：利用本仓库已有的 Dungeon 系统，把一段玩法放进副本场景里，并用 **Challenge 完成**作为通关条件，让 `DungeonManager` 自动结算（触发 `EVENT_DUNGEON_SETTLE`）。

与其他章节关系：

- `analysis/18-dungeon-pipeline.md`：Dungeon 管线总览（入口点/结算/退出）。
- `analysis/62-cookbook-timed-challenge-and-waves.md`：Challenge 玩法骨架（你在 dungeon 里也会复用）。
- `analysis/17-challenge-gallery-sceneplay.md`：Challenge 的参数语义与实现边界（决定“通关判定”靠什么）。

---

## 69.1 你要做出来的“体验”

1. 用命令进入某个 dungeonId（开发期最方便）
2. 进入副本后开始一段挑战（限时/清怪/计分等）
3. 挑战成功 → dungeon 自动结算（EVENT_DUNGEON_SETTLE）
4. 挑战失败 → 手动失败（`CauseDungeonFail`）或让条件不满足（由玩家退出）

---

## 69.2 开发期最实用入口：`/dungeon <dungeonId>`

本仓库内建命令：

- `/dungeon <dungeonId>`（别名：`/enter_dungeon`）

它会：

- 根据 `DungeonExcelConfigData` 找到 dungeonData
- 把玩家转移到 dungeonData.sceneId 对应的场景
- 为该 scene 挂上 `DungeonManager`

这对内容制作的意义是：

> 你可以先不管“世界里的入口点/UI/解锁条件”，只专注做副本内玩法脚本。

---

## 69.3 关键机制：Dungeon 在本仓库里如何判定“通关”？

本仓库的 `DungeonManager` 通过 `passCond`（`DungeonPassExcelConfigData`）判定是否结束：

- 引擎在运行时触发 `scene.triggerDungeonEvent(condType, params...)`
- `DungeonManager` 收到事件后按 passCondHandlers 判断条件是否完成
- 条件完成后会调用 `finishDungeon()`，并广播 `EVENT_DUNGEON_SETTLE`

对内容作者最重要的两个触发源：

1) **挑战完成触发**：`DungeonChallenge.done()` 会触发  
   - `DUNGEON_COND_FINISH_CHALLENGE`，params = `(challengeId, challengeIndex)`
2) **击杀计数触发**：`Scene.killEntity` 会递增 killedMonsterCount 并触发  
   - `DUNGEON_COND_KILL_MONSTER_COUNT`

其中“最可控、最像玩法编排层”的路线是：**用 Challenge 完成驱动通关**。

---

## 69.4 配方：用 Challenge 完成驱动 dungeon 通关（推荐）

### 69.4.1 选择一个 passCond（或创建一个）

`DungeonPassExcelConfigData.json` 里存在大量：

- `condType = DUNGEON_COND_FINISH_CHALLENGE`
- `param[0] = X`

实现里（`ConditionFinishChallenge`）的匹配规则是：

> 当 `challengeId == X` 或 `challengeIndex == X` 时，条件成立

因此你有两种选型策略：

1) **复用现有 passCond**：找一个你要用的 dungeonId，其 passCond 已经是 FINISH_CHALLENGE  
   - 然后把你脚本里的 `challengeId/challengeIndex` 设计成能命中它的 `param[0]`
2) **创建你自己的 passCond**（更直观，但需要改表）
   - 在 `DungeonPassExcelConfigData.json` 新增一条 id
   - `conds` 里只放一个 FINISH_CHALLENGE，param[0] 填你要用的 challengeId（或 index）
   - 再让你的 dungeonData.passCond 指向它（见 69.5）

开发期建议：优先复用现成 passCond + 调整 challengeId/index，让链路跑通；再考虑做干净的自定义 passCond。

### 69.4.2 在 dungeon 场景里写一个“挑战 group”

你在 dungeon 的 scene 脚本目录下写一个 group（与大世界完全一样）：

- `resources/Scripts/Scene/<dungeonSceneId>/scene<dungeonSceneId>_group<groupId>.lua`
- 并把它挂进对应 block 的 `groups` 列表

然后在 group 脚本里：

1) 通过 worktop/GroupLoad 触发 `ActiveChallenge`
2) 在成功/失败时切 suite、清理现场（见 `analysis/62`）

关键点：**让你的挑战完成时，DungeonChallenge 能触发 DUNGEON_COND_FINISH_CHALLENGE**。  
只要 passCond 匹配上，dungeon 就会自动结算。

### 69.4.3 失败处理：用 `CauseDungeonFail` 主动失败（可选但常用）

当你希望“挑战失败立刻判副本失败”时：

```lua
ScriptLib.CauseDungeonFail(context)
```

这会走 `DungeonManager.failDungeon()`，并触发 `EVENT_DUNGEON_SETTLE`（successfully=0）。

> 注意：本仓库 ScriptLib 里没有 `CauseDungeonSuccess`，所以成功不要靠它；成功靠 passCond/Challenge 更稳。

### 69.4.4 收尾：监听 `EVENT_DUNGEON_SETTLE`

Dungeon 结算时会广播：

- `EventType.EVENT_DUNGEON_SETTLE`
- `evt.param1 = 1/0`（成功/失败）

你可以在任意已加载 group 里监听它（groupId=0 会让事件广播给所有 group 的 triggers）：

```lua
{ name = "DUNGEON_SETTLE", event = EventType.EVENT_DUNGEON_SETTLE, action = "action_dungeon_settle" }
```

在 action 里常见用途：

- 成功时刷结算宝箱/提示
- 失败时做清理/提示

---

## 69.5 进阶：如果你要做“真正自定义 dungeonId”

要做一个全新的 dungeonId（不仅仅是改脚本），你通常要动至少两张表：

1) `resources/ExcelBinOutput/DungeonExcelConfigData.json`
   - 新增 dungeonData：sceneId、type、passCond、reward 等
2) `resources/ExcelBinOutput/DungeonPassExcelConfigData.json`
   - 新增 passCond：FINISH_CHALLENGE / KILL_MONSTER_COUNT 等

并且你还要处理“如何让客户端看到入口/可进入/显示 UI”等更上层的问题（这往往涉及客户端资源与更多表，超出本 Cookbook 的最小范围）。

实务建议：

- 开发期先用 `/dungeon <id>` 直进，把副本内玩法打磨成熟
- 再回头补“入口点/解锁/奖励/文本表现”等系统集成

---

## 69.6 常见坑与边界

1. **副本永远不结算**
   - passCond 不匹配你的 challengeId/challengeIndex
   - 或你根本没创建 DungeonChallenge（挑战类型不对）
2. **想用“杀光某个 group 的怪”做通关条件但不靠谱**
   - 本仓库当前 `DUNGEON_COND_KILL_GROUP_MONSTER` 的 handler 过于简化：它可能在“杀第一只怪”就满足  
     → 推荐改用 FINISH_CHALLENGE 或 KILL_MONSTER_COUNT
3. **计时/复杂副本机制缺口**
   - `DUNGEON_COND_IN_TIME` 等在实现里存在 TODO  
     → 需要下潜引擎层或用 Challenge 自己实现计时与失败

---

## 69.7 小结

- 做实例内容的最稳路线：`/dungeon` 进入 → Challenge 驱动通关 → `EVENT_DUNGEON_SETTLE` 收尾。
- 不要依赖未完整实现的 passCond 类型；优先用 FINISH_CHALLENGE 这种“实现闭环”的条件。
- 想做“完整新 dungeonId + 入口点 + UI”，会牵扯更大的数据与客户端层面集成，建议在玩法成熟后再做。

---

## Revision Notes

- 2026-01-31：首次撰写本配方；给出以 Challenge 完成驱动 DungeonSettle 的最小闭环流程，补充 passCond 的实际匹配规则与当前实现的常见边界（例如 KILL_GROUP_MONSTER 的简化问题）。

