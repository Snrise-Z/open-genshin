# 24 专题：OpenState 与进度门槛（Progress Gating）

本文是“玩法编排层专题”之一，讨论一种经常被忽略但极其关键的“编排层能力”：**进度门槛**（某功能/区域/交互在什么条件下对玩家开放）。

在本仓库中，进度门槛主要由四类机制共同构成：

1. **OpenState**：偏“系统/UI/功能入口”的开关（能不能多人、能不能开某个界面、活动入口是否显示等）。
2. **SceneTag**：偏“场景变体/世界状态标签”的开关（客户端根据 tag 选择加载哪个变体，服务端也可查询）。
3. **地图点/区域解锁**：传送点（TransPoint）与区域（SceneArea）的解锁状态。
4. **Quest/全局进度计数**：任务完成、LuaNotify、QuestProgress 等，常用来驱动上述三者的变化。

与其他章节关系：

- `analysis/10-quests-deep-dive.md`：QuestExec 能直接改 OpenState；Quest 条件也能依赖 OpenState/进度。
- `analysis/21-worktop-and-interaction-options.md`：交互选项本质也是“门槛”的一种实现方式（按阶段开放选项）。
- `analysis/26-entity-state-persistence.md`：门槛是否持久化、落库在哪一层。

---

## 24.1 OpenState：它是什么、数据从哪来

### 24.1.1 定义与用途（中性模型）

把 OpenState 当作“功能开关表”即可：

- `open_state_id -> { 默认是否开启, 是否允许客户端自行开启, 开启条件列表, 关联 UI ID }`

它常用于：

- 系统入口/菜单项显隐
- 多人/家园/活动页签等大系统的开放
- 新手引导链路（某些引导步骤本质是 OpenState）

### 24.1.2 数据来源：`OpenStateConfigData.json`

本仓库的数据模型类是 `OpenStateData`（`@ResourceType(name="OpenStateConfigData.json")`），其字段包括：

- `id`
- `defaultState`
- `allowClientOpen`
- `systemOpenUiId`
- `cond`（条件列表）

条件类型枚举（仓库内定义）：

- `OPEN_STATE_COND_PLAYER_LEVEL`
- `OPEN_STATE_COND_QUEST`（子任务完成）
- `OPEN_STATE_COND_PARENT_QUEST`（主任务完成）
- `OPEN_STATE_OFFERING_LEVEL`（供奉等级）
- `OPEN_STATE_CITY_REPUTATION_LEVEL`（声望等级）

---

## 24.2 OpenState 在本仓库的运行逻辑（PlayerProgressManager）

OpenState 的运行时宿主是 `PlayerProgressManager`，它持有/修改 `player.openStates`。

### 24.2.1 登录时发生什么

`PlayerProgressManager.onPlayerLogin()` 会：

1. `tryUnlockOpenStates(false)`：尝试补解锁（用于兼容“之前已满足条件但后来才实现解锁逻辑”的账号）
2. 发送 `PacketOpenStateUpdateNotify`
3. 补齐部分“雕像相关任务”（`addStatueQuestsOnLogin`）
4. 若关闭 questing（`GAME_OPTIONS.questing.enabled == false`），会做一套“强行开放”逻辑（例如自动解锁地图点、设置 OpenState 47 等）

### 24.2.2 自动解锁的策略：DEFAULT/BLACKLIST/IGNORED

本仓库为了“能玩”做了非常强的默认放开策略（这也是你研究时必须心里有数的边界）：

- `BLACKLIST_OPEN_STATES`：永远不自动解锁的集合（例如 `48` 被黑名单）
- `IGNORED_OPEN_STATES`：从默认解锁集合里排除的集合（例如 `1404`）
- `DEFAULT_OPEN_STATES`：会被默认当作已开启的集合（它不仅包含 `defaultState==true` 的项，还包含很多“条件处理不完整的项”）

`tryUnlockOpenStates(sendNotify)` 会遍历所有仍为 0 的 open state：

- 必须 `!allowClientOpen`
- 必须 `areConditionsMet(state)` 通过
- 不能在 blacklist/ignored
- 才会被 `setOpenState(id, 1)`

### 24.2.3 条件判断：哪些是真的判断、哪些是“先放开”

`areConditionsMet(OpenStateData)` 对不同 condType 的处理现状：

- `PLAYER_LEVEL`：真实判断（按玩家等级）
- `QUEST`：真实判断（子任务必须 `QUEST_STATE_FINISHED`）
- `PARENT_QUEST`：真实判断（主任务必须 `PARENT_QUEST_STATE_FINISHED`）
- `OFFERING_LEVEL` / `CITY_REPUTATION_LEVEL`：当前实现里 **不做判断**（等价于“直接满足”）

> 这意味着：如果你用 OpenState 做严肃的“进度门槛设计”，要特别小心——很多门槛在本仓库会因为“条件未实现 → 默认放开”而失效。

---

## 24.3 如何从脚本/数据驱动 OpenState（不改引擎）

### 24.3.1 QuestExec：`QUEST_EXEC_SET_OPEN_STATE`

Quest 的 Exec 里存在 `QUEST_EXEC_SET_OPEN_STATE`，对应实现是 `ExecSetOpenState`：

- 执行时会调用 `player.getProgressManager().forceSetOpenState(openStateId, value)`
- 属于“无视条件/权限的强制写入”

因此：**想在剧情节点开放一个系统功能**，最稳的做法通常是：

1. 让 Quest 在某个子任务完成时触发 Exec
2. Exec 写 OpenState
3. 需要的话再发引导/提示（走 Talk/Reminder/Widget 等）

### 24.3.2 客户端请求：`SetOpenStateReq`（仅限 allowClientOpen）

`PlayerProgressManager.setOpenStateFromClient(openState, value)` 只允许：

- 该 OpenState `allowClientOpen == true`
- 且 `areConditionsMet(data)` 通过

否则会返回失败。

> 对玩法编排来说，这更像“客户端自助完成某个 UI 流程”的机制，通常不建议拿它当主要门槛手段（除非你明确知道客户端会在何时发这个请求）。

---

## 24.4 SceneTag：场景标签是“世界状态位”，但本仓库默认不评估其条件

### 24.4.1 数据来源：`SceneTagConfigData.json`

`SceneTagData` 定义了：

- `id / sceneId / sceneTagName`
- `isDefaultValid`
- `cond`（包括：活动开放、任务完成、QuestGlobalVar 等）

### 24.4.2 本仓库的默认行为：把所有 defaultValid 都塞给玩家

`Player.applyStartingSceneTags()` 会：

- 遍历 `SceneTagDataMap`
- 把 `isDefaultValid==true` 的 tag 全部加入 `player.sceneTags[sceneId]`

这说明两点：

1. `SceneTagData.cond` 在本仓库里更多像“设计态信息”，默认不会自动评估并驱动玩家状态改变。
2. 如果你想把 SceneTag 当成严肃的“剧情开关”，通常需要用 Quest/脚本显式 `AddSceneTag/DelSceneTag`（下一节）。

### 24.4.3 ScriptLib 对 SceneTag 的支持（可用）

Lua 侧可以调用：

- `ScriptLib.AddSceneTag(sceneId, sceneTagId)`
- `ScriptLib.DelSceneTag(sceneId, sceneTagId)`
- `ScriptLib.CheckSceneTag(sceneId, sceneTagId)`（布尔）

对应到引擎侧：

- 目前实现是直接改 **房主玩家** 的 `PlayerProgressManager`（多人时这是一个隐含边界：由 host 的标签决定）。
- 每次改动会发送 `PacketPlayerWorldSceneInfoListNotify`，让客户端刷新世界场景信息。

> 直觉：SceneTag 更像“客户端选择加载哪个世界状态/环境变体”的开关；如果你希望它也能影响服务端逻辑，需要在 Lua 里显式 `CheckSceneTag` 并据此走不同分支。

---

## 24.5 地图点与区域：TransPoint/SceneArea 的解锁

除了 OpenState 与 SceneTag，本仓库里另一个非常实用的“进度门槛”是地图解锁：

- **ScenePoint（传送点/七天神像等）**
- **SceneArea（地图区域）**

它们通常比 OpenState 更“可见、可验证、可叙事化”：玩家完成任务→点亮传送点→地图开雾→解锁新区域。

### 24.5.1 解锁传送点：`unlockTransPoint(sceneId, pointId, isStatue)`

`PlayerProgressManager.unlockTransPoint(...)` 的关键行为：

1. 校验 `ScenePointEntry` 存在且未解锁
2. `player.unlockedScenePoints[sceneId].add(pointId)`
3. 发放解锁奖励（物品/冒险经验）
4. 触发任务系统事件：
   - `QuestContent.QUEST_CONTENT_UNLOCK_TRANS_POINT(sceneId, pointId)`
5. 额外发一个脚本事件：
   - `scene.getScriptManager().callEvent(new ScriptArgs(0, EVENT_UNLOCK_TRANS_POINT, sceneId, pointId))`
6. 发送 `PacketScenePointUnlockNotify(sceneId, pointId)`

> 注意：脚本事件的 `groupId` 传的是 `0`。这意味着它不天然绑定某个具体 group；只有当你的脚本系统/触发器显式处理这种“全局事件路由”时它才有意义。实践中更可靠的是用 QuestContent 去驱动任务阶段与后续行为。

### 24.5.2 解锁区域：`unlockSceneArea(sceneId, areaId)`

`unlockSceneArea` 当前实现较简单：

- 写入 `player.unlockedSceneAreas[sceneId].add(areaId)`
- 发送 `PacketSceneAreaUnlockNotify(sceneId, areaId)`

如果你要用它做“剧情开雾”，通常需要你自己在 Quest/Lua 中决定“何时解锁哪个 area”。

---

## 24.6 “门槛工具箱”速查表：只改脚本/数据时你到底该用哪个

| 机制 | 适合管什么 | 驱动方式（脚本/数据） | 持久化位置（直觉） |
|---|---|---|---|
| OpenState | 系统/功能入口 | QuestExec `SET_OPEN_STATE`、GM 命令、少量 client open | 玩家存档（player.openStates） |
| SceneTag | 世界状态/场景变体 | `ScriptLib.Add/DelSceneTag` + `CheckSceneTag` 分支 | 玩家存档（player.sceneTags） |
| ScenePoint/SceneArea | 地图解锁/旅行能力 | `unlockTransPoint / unlockSceneArea`（通常由任务驱动） | 玩家存档（unlocked points/areas） |
| Group Variable | 玩法 FSM 状态 | `Set/ChangeGroupVariableValue` + `VARIABLE_CHANGE` trigger | group instance（见 `analysis/26`） |
| Group Suite | 内容显隐/阶段切换 | `refreshGroupSuite`/`RefreshGroup`/AddExtraSuite | group instance.activeSuiteId（见 `analysis/26`） |
| Worktop Option | 交互门槛（局部） | `SetWorktopOptions/DelWorktopOption` + `SELECT_OPTION` | 通常由实体状态/变量决定 |

一个经验性的选型建议：

- **想“玩家能不能用某功能/UI”** → OpenState
- **想“世界处于哪个变体/阶段（客户端也要变）”** → SceneTag + 任务驱动
- **想“玩法房间/关卡内的阶段推进”** → Group Variable + Suite（最稳）
- **想“地图/旅行路线随剧情开放”** → ScenePoint/SceneArea（配合任务与文本）

---

## 24.7 已知边界与踩坑点

1. **OpenState 的“默认放开策略”很强**：供奉/声望相关条件未实现，很多状态会被视为满足条件；不要把它当成严格的进度系统。
2. **SceneTag 的 cond 默认不评估**：`SceneTagConfigData` 里的条件更多是“设计态信息”；想严格使用，需要你自己写驱动逻辑（任务完成→Add/Del tag）。
3. **多人世界的归属问题**：当前 ScriptLib 的 SceneTag 操作走 host 的 ProgressManager。你如果要做“每个玩家不同的世界状态”，会遇到引擎层边界。

---

## 24.8 小结

本专题的核心结论是：在“只改脚本/数据”的约束下，你仍然有一套足够强的进度门槛工具箱：

- 玩法内部推进：Group Variable/Suite（可控、可编排、可调试）
- 世界/系统级开放：OpenState/SceneTag/地图点（更偏进度系统，但实现语义存在简化）

只要你明确哪些“条件”在本仓库是严格评估的、哪些只是默认放开，就能把它当作通用 ARPG 引擎的“进度编排层”来使用。

---

## Revision Notes

- 2026-01-31：首次撰写本专题（基于 `PlayerProgressManager`、`OpenStateData`、`SceneTagData` 与 ScriptLib 的 SceneTag API）。

