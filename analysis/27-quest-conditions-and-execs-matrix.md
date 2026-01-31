# 27 专题：任务系统的 QuestCond / QuestContent / QuestExec「矩阵」

本文是“任务系统专题”的补篇，目标是把任务数据里的三类关键 opcode —— **接任务条件（QuestCond）**、**任务进度/失败条件（QuestContent）**、**执行器（QuestExec）** —— 当成一套“可编排 DSL 的指令集”来拆解：  
**哪些指令在本仓库真实可用？参数怎么填？事件从哪里来？只改脚本/数据时该选哪条链路？**

与其他章节关系：

- `analysis/10-quests-deep-dive.md`：任务系统全链路（Quest/Talk/TriggerFire/LuaNotify/Exec 与 Lua/场景联动）。
- `analysis/13-event-contracts-and-scriptargs.md`：Lua 事件 ABI（`evt.param* / evt.source`）与触发器匹配规则。
- `analysis/21-worktop-and-interaction-options.md`：`WORKTOP_SELECT`、`INTERACT_GADGET` 等常见进度来源。
- `analysis/24-openstate-and-progress-gating.md`：`OPEN_STATE` / `SceneTag` / 进度门槛的选型。

> 重要原则：**不要被 enum 迷惑**。`QuestCond/QuestContent/QuestExec` 枚举列出了“设计态上限”，但真正决定可用性的，是引擎侧是否实现了 handler（`game/quest/conditions|content|exec`）。

---

## 27.1 抽象模型：任务 = 三段式状态机（Accept → Run → Side Effects）

把任务（Quest）用中性 ARPG 语言抽象成三段：

1. **Accept（接取/激活）**
   - 由 `QuestData.acceptCond`（类型 `QuestCond`）决定“什么时候可以自动接取/变为可见/被系统激活”。
   - 事件入口：`QuestManager.triggerEvent(QuestCond, ...)`（由各种系统投递）。
2. **Run（进行中：推进/失败）**
   - 由 `QuestData.finishCond` 与 `QuestData.failCond`（类型 `QuestContent`）决定“什么时候推进到完成/失败”。
   - 事件入口：`QuestManager.triggerEvent(QuestContent, ...)`（同样由各种系统投递）。
3. **Side Effects（执行器）**
   - `QuestData.beginExec / finishExec / failExec`（类型 `QuestExec`）是“状态变化时的副作用脚本”：刷怪、切 group suite、写变量、解锁传送点、通知 Lua、发试用角色等。

你可以把它类比成：

```
Quest:
  accept when  cond(...)
  finish when  content(...)
  on begin     exec(...)
  on finish    exec(...)
  on fail      exec(...)
```

这三类指令就是“只靠数据/脚本就能改剧情与玩法”的核心抓手。

---

## 27.2 数据结构：`QuestExcelConfigData.json` 的字段与组合逻辑

任务数据模型（`QuestData`）关键字段：

- `subId / mainId / order`：子任务 ID、主任务 ID、排序
- `acceptCondComb / finishCondComb / failCondComb`：组合逻辑（`LogicType`，如 AND/OR）
- `acceptCond[]`：`QuestCond` 条件列表（决定接取）
- `finishCond[] / failCond[]`：`QuestContent` 条件列表（决定完成/失败）
- `beginExec[] / finishExec[] / failExec[]`：`QuestExec` 执行器列表（做副作用）

### 27.2.1 条件的参数形态：`param[] + param_str + count`

Accept/Finish/Fail 条件在 JSON 里都长得很像：

```json
{
  "type": "QUEST_CONTENT_LUA_NOTIFY",
  "param": [0, 0],
  "param_str": "701022602",
  "count": 1
}
```

你要记住三点：

1. `param[]` 是 **整型数组**，大多数 handler 只会用到前 1~2 个；
2. `param_str` 是 **字符串参数**（常用来放“进度 key / 触发名 / 特殊编码”）；
3. `count` 是 **阈值/次数**：很多 Content 会把 `count==0` 当成 1。

### 27.2.2 Exec 的参数形态：`param[]` 是字符串数组

Exec 在 JSON 里一般是：

```json
{
  "type": "QUEST_EXEC_REFRESH_GROUP_SUITE",
  "param": ["3", "133008009,2"],
  "count": "0"
}
```

注意：这里 `param` 是 **字符串数组**，需要按每个 `QuestExec` 的 handler 约定去填写（比如 `"sceneId"`, `"groupId,suiteId;..."`）。

---

## 27.3 事件投递模型：为什么「param[0]」在 Accept 阶段特别关键

### 27.3.1 Accept（QuestCond）是“按键索引的候选集”

本仓库为了性能，会把所有任务的 acceptCond 建一个缓存索引：

- `QuestData.questConditionKey(type, firstParam, paramStr)`
- 其中 `firstParam` = `condition.param[0]`

运行时触发 Accept 事件时：

1. `QuestManager.triggerEvent(QuestCond condType, String paramStr, int... params)`
2. 先用 `params[0]` + `paramStr` 去索引 `beginCondQuestMap` 找“候选任务”
3. 再对候选任务逐条调用 handler 去判断是否满足

所以 **Accept 事件必须保证有 `params[0]`**，否则会直接越界/失效；并且你的 `queueEvent` 的 `params[0] + paramStr` 必须能命中当初建索引时的 key。

> 经验法则：当你想“只改数据”时，优先选那些 **param_str 为空且索引只依赖 param[0]** 的 QuestCond（例如 `OPEN_STATE_EQUAL`、`PLAYER_LEVEL_EQUAL_GREATER`、`STATE_EQUAL`）。

### 27.3.2 Run（QuestContent）是“遍历评估”

`QuestManager.triggerEvent(QuestContent, ...)` 的路径不同：

- 它不会走 `beginCondQuestMap` 索引（因为“进行中的任务集合”本身就不大）
- 直接遍历玩家的 active main quests，逐个 `tryFailSubQuests / tryFinishSubQuests`

这意味着：

- 你在 Lua 里调用 `ScriptLib.AddQuestProgress`（见 10.8）这种“上报进度”非常稳，因为它最终会让 QuestContent handler 重新评估；
- 但 Accept 阶段那类“靠事件触发接任务”的玩法，要格外注意 `params[0]` 与 `param_str` 的匹配。

---

## 27.4 如何判定「本仓库实际可用矩阵」

真正的可用性由 `QuestSystem` 的 handler 注册决定：

- 条件 handler：`Grasscutter/src/main/java/emu/grasscutter/game/quest/conditions/*`
- 进度 handler：`Grasscutter/src/main/java/emu/grasscutter/game/quest/content/*`
- Exec handler：`Grasscutter/src/main/java/emu/grasscutter/game/quest/exec/*`

它通过反射扫描带注解的类：

- `@QuestValueCond(QuestCond.X)`
- `@QuestValueContent(QuestContent.X)`
- `@QuestValueExec(QuestExec.X)`

因此你在设计任务数据时，建议把“指令集”理解为：

> **enum = 协议字典**（很多未实现）  
> **handlers = 当前引擎真正支持的 DSL 子集**（你能直接靠数据/脚本跑起来的部分）

---

## 27.5 QuestCond（接任务条件）可用清单（本仓库实现的 handler）

下面按“只改数据/脚本最常用”的角度整理（不是 enum 全量）。

| QuestCond | 典型参数（condition.param / param_str） | 事件从哪来（谁 queueEvent） | 备注（编排建议） |
|---|---|---|---|
| `QUEST_COND_NONE` | `param=[0,0]` | `QuestManager.enableQuests()` 会触发一次 | 用于“默认可接取”的任务；常见在隐藏任务/测试任务 |
| `QUEST_COND_PLAYER_LEVEL_EQUAL_GREATER` | `param[0]=minLevel` | `enableQuests()` 触发 `>=1`；后续升级也可能触发 | “等级门槛”的最稳方案 |
| `QUEST_COND_OPEN_STATE_EQUAL` | `param[0]=openStateId, param[1]=requiredState` | 进度系统变更 openstate 时触发（或主动触发） | 搭配 `analysis/24` 做“功能解锁/地图门槛” |
| `QUEST_COND_PACK_HAVE_ITEM` | `param[0]=itemId, param[1]=needCount(0→1)` | 物品变化时可触发（或主动触发） | 适合“持有某物后触发任务” |
| `QUEST_COND_ITEM_NUM_LESS_THAN` | `param[0]=itemId, param[1]=threshold` | 同上 | 适合“交付/消耗后触发任务” |
| `QUEST_COND_STATE_EQUAL` | `param[0]=questId, param[1]=questStateValue` | `enableQuests()` 会为缓存里的 questId 触发 | 用于“前置任务状态门槛”（最常见的链式任务） |
| `QUEST_COND_STATE_NOT_EQUAL` | 同上 | 同上 | 常见在“没完成/没开始某任务才触发” |
| `QUEST_COND_QUEST_VAR_EQUAL/GREATER/LESS` | `param[0]=varIndex, param[1]=target` | `GameMainQuest.triggerQuestVarAction` 会投递 | 适合“主任务内的 FSM 状态/计数门槛” |
| `QUEST_COND_QUEST_GLOBAL_VAR_EQUAL/GREATER/LESS` | `param[0]=globalVarId, param[1]=target` | `QuestManager.setQuestGlobalVarValue` 会投递 | 适合跨主任务共享的全局门槛 |
| `QUEST_COND_COMPLETE_TALK` | `param[0]=talkId` | Talk 结束时投递 | 适合“对白驱动接任务/推进剧情” |
| `QUEST_COND_PERSONAL_LINE_UNLOCK` | `param[0]=personalLineId` | 解锁个人线时投递 | 偏剧情系统 |
| `QUEST_COND_ACTIVITY_COND` | `param[0]=activityCondId, param[1]=targetState(当前仅用1)` | `ActivityHandler.triggerCondEvents` | 活动系统与任务系统的桥 |
| `QUEST_COND_ACTIVITY_OPEN` | `param[0]=activityId` | 活动开放/关闭时投递 | 用于“活动期间出现的任务” |
| `QUEST_COND_ACTIVITY_END` | `param[0]=activityId` | 同上 | 同上 |
| `QUEST_COND_IS_DAYTIME` | `param[0]=min?, param[1]=max?`（见 handler） | 游戏时间变化时投递 | 适合“昼夜门槛” |
| `QUEST_COND_TIME_VAR_GT_EQ / PASS_DAY` | `param[0]=mainQuestId 或 timeVarId` | `QuestManager` 的 tick/检查逻辑 | 适合“跨天/计时”门槛 |
| `QUEST_COND_MAIN_COOP_START` | `param[0]=chapterId, param[1]=savePoint?` | `HandlerStartCoopPointReq` | 偏协作剧情 |

### 27.5.1 特别提醒：`QUEST_COND_LUA_NOTIFY` 在本仓库语义不一致（慎用）

本仓库存在一个“数据语义与 handler 实现不匹配”的典型点：

- `QuestExcelConfigData.json` 里的 `QUEST_COND_LUA_NOTIFY` 常见形态：  
  `param[0]=<数字触发器ID>, param_str=""`
- 但 `ConditionLuaNotify` 的实现目前尝试 `Integer.parseInt(paramStr)`（使用事件的 `paramStr`），与缓存索引 key（使用条件自身的 `param_str`）对不上。

结果是：**只改数据很难把它跑通**。如果你确实要“Lua 上报 → 自动接任务”，建议：

- 不走 Accept LuaNotify，而是改用更稳的 Accept 条件（如 `STATE_*` / `OPEN_STATE_*` / `PLAYER_LEVEL_*`），然后用 `QUEST_CONTENT_LUA_NOTIFY + ScriptLib.AddQuestProgress` 推进（见 `analysis/10-quests-deep-dive.md`）。
- 或者接受需要下潜修复 handler（属于“引擎边界”，见 `analysis/04`）。

---

## 27.6 QuestContent（完成/失败条件）可用清单与触发来源

QuestContent 的大部分 handler 都是“事件触发后重新评估”，但它们的输入来源可以分成几类：

### A. 实体/战斗事件驱动

| QuestContent | 参数语义（condition.param / count） | 事件来源（当前仓库） | 备注 |
|---|---|---|---|
| `QUEST_CONTENT_MONSTER_DIE` | `param[0]=monsterId` | `EntityMonster.onDeath` | 会对场景内所有玩家投递 |
| `QUEST_CONTENT_KILL_MONSTER` | `param[0]=monsterId` | `EntityMonster.onDeath` | 目前与 MONSTER_DIE 语义相近 |
| `QUEST_CONTENT_CLEAR_GROUP_MONSTER` | `param[0]=groupId` | `EntityMonster.onDeath` | handler 实际会去检查 group 是否已清怪 |
| `QUEST_CONTENT_DESTROY_GADGET` | `param[0]=gadgetId? / config?` | `EntityGadget.onDeath` 等 | 与 `analysis/29` 联动 |
| `QUEST_CONTENT_INTERACT_GADGET` | `param[0]=configId?` | gadget 交互链路 | 常与 Worktop/Chest/调查点联动 |

### B. 副本/房间/场景事件驱动

| QuestContent | 参数语义 | 事件来源 | 备注 |
|---|---|---|---|
| `QUEST_CONTENT_ENTER_DUNGEON` | `param[0]=dungeonId` | 进副本时 | `analysis/18` |
| `QUEST_CONTENT_FINISH_DUNGEON` | `param[0]=dungeonId` | 副本结算 | |
| `QUEST_CONTENT_FAIL_DUNGEON` | `param[0]=dungeonId` | 副本失败 | |
| `QUEST_CONTENT_ENTER_ROOM` | `param[0]=roomId` | 房间切换/逻辑房间 | |
| `QUEST_CONTENT_LEAVE_SCENE` | `param[0]=sceneId?` | 离开场景 | 可做“离开即失败/推进” |

### C. 剧情/对白驱动

| QuestContent | 参数语义 | 事件来源 | 备注 |
|---|---|---|---|
| `QUEST_CONTENT_COMPLETE_TALK` | `param[0]=talkId` | Talk 结束 | |
| `QUEST_CONTENT_COMPLETE_ANY_TALK` | `param[0]=npcId?` | Talk 结束 | 更宽松的对白完成条件 |
| `QUEST_CONTENT_FINISH_PLOT` | `param[0]=plotId` | Cutscene/剧情播放完成 | `analysis/20` |
| `QUEST_CONTENT_NOT_FINISH_PLOT` | 同上 | 失败分支 | 需要事件支持 |

### D. 物品/交付/使用驱动

| QuestContent | 参数语义 | 事件来源 | 备注 |
|---|---|---|---|
| `QUEST_CONTENT_OBTAIN_ITEM` | `param[0]=itemId, count=需要数量(0→1)` | 物品变化（或任意事件触发后重算） | handler 直接查背包 |
| `QUEST_CONTENT_ITEM_LESS_THAN` | `param[0]=itemId, param[1]=threshold` | 同上 | 常用于“交付后满足” |
| `QUEST_CONTENT_USE_ITEM` | `param[0]=itemId` | 使用物品时 | |
| `QUEST_CONTENT_FINISH_ITEM_GIVING` | `param[0]=givingId` | 交付系统完成时 | |

### E. “脚本上报/玩家进度 key”驱动（最适合只改脚本/数据）

| QuestContent | 参数语义 | 事件来源 | 为什么重要 |
|---|---|---|---|
| `QUEST_CONTENT_LUA_NOTIFY` | `param_str=<进度key>, count=阈值(0→1)` | `ScriptLib.AddQuestProgress(key)` | 最通用：Lua 任意事件都能上报 |
| `QUEST_CONTENT_ADD_QUEST_PROGRESS` | `param[0]=progressId(数字), count=阈值` | `QUEST_EXEC_ADD_QUEST_PROGRESS` | 更偏“任务 exec 推动”而不是 Lua 直接推 |
| `QUEST_CONTENT_TRIGGER_FIRE` | `param[0]=triggerId` | 场景 group 触发 `EVENT_TRIGGER_FIRE` | 适合“用场景触发器控制任务” |

### F. Quest 变量/状态驱动

| QuestContent | 参数语义 | 事件来源 | 备注 |
|---|---|---|---|
| `QUEST_CONTENT_QUEST_VAR_*` | `param[0]=varIndex, param[1]=target` | `GameMainQuest.triggerQuestVarAction` | 与 Accept 同构 |
| `QUEST_CONTENT_QUEST_STATE_EQUAL/NOT_EQUAL` | `param[0]=questId, param[1]=state` | 任务状态变化时 | 适合“等另一个任务到某状态” |

> 你会发现：**只改脚本/数据**时，最稳的推进手段依然是 `QUEST_CONTENT_LUA_NOTIFY + ScriptLib.AddQuestProgress`，因为它几乎不依赖引擎对某个具体事件的支持。

---

## 27.7 QuestExec（执行器）可用清单：把任务状态变化“落到世界里”

下面列出本仓库已有 handler 的常用 Exec（同样不是 enum 全量）。

### 27.7.1 世界/Group 编排类（最像“关卡脚本编排”）

| QuestExec | `param[]`（字符串） | 行为 | 编排用途 |
|---|---|---|---|
| `QUEST_EXEC_NOTIFY_GROUP_LUA` | `["sceneId","groupId"]` | 发送 `EVENT_QUEST_START/FINISH` 到目标 group | 任务 ↔ 场景脚本桥（最重要） |
| `QUEST_EXEC_REFRESH_GROUP_SUITE` | `["sceneId","groupId,suiteId;..."]` | 刷新 group 到某 suite（并标记 dontUnload） | 用任务驱动“关卡阶段切换” |
| `QUEST_EXEC_REFRESH_GROUP_MONSTER` | `["sceneId","groupId"]` | 让 group 重刷怪（依赖实现） | 常用于“任务开始刷怪” |
| `QUEST_EXEC_REGISTER_DYNAMIC_GROUP` | `["sceneId","groupId"]` | 动态加载 group（返回 suite 记录到 QuestGroupSuite） | 任务开始时注入玩法单元 |
| `QUEST_EXEC_UNREGISTER_DYNAMIC_GROUP` | `["sceneId","groupId"]` | 卸载动态 group | 任务结束清场 |

### 27.7.2 进度/变量类（更像“任务内部脚本”）

| QuestExec | `param[]` | 行为 | 备注 |
|---|---|---|---|
| `QUEST_EXEC_ADD_QUEST_PROGRESS` | `["progressId","delta"]` | 增加数字进度 key | 对应 `QUEST_CONTENT_ADD_QUEST_PROGRESS` |
| `QUEST_EXEC_SET_QUEST_VAR / INC / DEC / RANDOM` | `["index","value"...]` | 修改主任务 questVars | 会触发 QuestCond/QuestContent 的 QUEST_VAR_* 重新评估 |
| `QUEST_EXEC_SET_QUEST_GLOBAL_VAR / INC / DEC` | `["varId","value"]` | 修改玩家全局任务变量 | 会触发 QUEST_GLOBAL_VAR_* 重新评估 |
| `QUEST_EXEC_INIT_TIME_VAR / CLEAR_TIME_VAR` | `["mainQuestId", "..."]` | 初始化/清理计时变量 | 配合 TIME_VAR 条件 |

### 27.7.3 玩家状态/资源类（偏系统能力）

| QuestExec | 行为 | 备注 |
|---|---|---|
| `QUEST_EXEC_UNLOCK_POINT / UNLOCK_AREA` | 解锁传送点/区域 | 与 `analysis/24` 联动 |
| `QUEST_EXEC_SET_OPEN_STATE` | 修改 OpenState | 用于功能解锁/剧情推进后的系统开关 |
| `QUEST_EXEC_DEL_PACK_ITEM / DEL_PACK_ITEM_BATCH` | 扣物品 | 常见交付/消耗 |
| `QUEST_EXEC_GRANT_TRIAL_AVATAR / REMOVE_TRIAL_AVATAR` | 给/收试用角色 | 与副本/挑战联动 |
| `QUEST_EXEC_SET_IS_FLYABLE / SET_IS_GAME_TIME_LOCKED` | 改玩家能力/时间锁 | 有明显“引擎边界”味道（兼容性） |
| `QUEST_EXEC_ADD_CUR_AVATAR_ENERGY` | 给当前角色充能 | 与战斗编排联动 |
| `QUEST_EXEC_START_BARGAIN / STOP_BARGAIN` | 讨价还价系统 | 仅在相关内容里使用 |

---

## 27.8 只改脚本/数据时：如何选用这套矩阵（配方）

这里给你 3 套“稳定可复用”的编排套路（不依赖新增 Java）：

### 配方 1：Lua 事件驱动任务推进（最通用）

目标：任意场景事件（进区域/选项/怪死）→ 推任务进度 → 触发任务 finishExec

1. 在任务数据里：
   - `finishCond: QUEST_CONTENT_LUA_NOTIFY`，`param_str = "<你的key>"`，`count = 1/2/...`
2. 在场景 group Lua 里：
   - 在合适的 action 中调用 `ScriptLib.AddQuestProgress(context, "<你的key>")`
3. 如需“任务开始/结束改场景”：
   - 在任务的 `beginExec/finishExec` 里加 `QUEST_EXEC_NOTIFY_GROUP_LUA` 或 `REFRESH_GROUP_SUITE`

这套就是 `analysis/10` 里强调的“最稳 glue”。

### 配方 2：QuestExec 驱动关卡阶段（任务是主控，场景是从属）

目标：任务开始时刷出一整套 Encounter，任务完成时清掉/切阶段

- `beginExec: QUEST_EXEC_REGISTER_DYNAMIC_GROUP`（或 `REFRESH_GROUP_SUITE`）
- group 内用变量/触发器自洽跑玩法
- `finishExec: QUEST_EXEC_UNREGISTER_DYNAMIC_GROUP`（或切回空 suite）

关键点：**Group 是“玩法单元”**，QuestExec 是“把玩法单元挂到世界上”的安装/卸载指令。

### 配方 3：QuestVar/GlobalVar 做“剧情状态机”

目标：不用改 Lua 也能在任务数据层表达“分支/阶段门槛”

- 用 `QUEST_EXEC_SET_QUEST_VAR/INC/DEC` 改变量
- 用 `QUEST_COND_QUEST_VAR_*` 做接任务门槛
- 用 `QUEST_CONTENT_QUEST_VAR_*` 做完成/失败门槛

优点：变量变更会自动触发重新评估（`triggerQuestVarAction`），适合写“数据驱动剧情状态机”。

---

## 27.9 排障：你写任务最容易踩的坑

1. **Accept 条件不生效**
   - 事件 `queueEvent(QuestCond, ...)` 没带 `params[0]`（Accept 阶段会按 `params[0]` 索引候选集）
   - `params[0] + paramStr` 与任务数据中 `param[0] + param_str` 对不上
2. **Finish 条件看似写了但永远不完成**
   - 用了 enum 有值但 handler 缺失的 `QuestContent`
   - 或事件根本没人投递（例如你以为有“采集触发”，但引擎没实现）
3. **用 `QUEST_COND_LUA_NOTIFY` 想“上报就接任务”**
   - 如 27.5.1 所述，本仓库目前语义不一致；建议改用更稳的 Accept 条件 + `QUEST_CONTENT_LUA_NOTIFY`
4. **Worktop/交互推进不触发**
   - 检查是否走了 `SelectWorktopOption` 流程与 `EVENT_SELECT_OPTION`（见 `analysis/21`）
5. **Exec 触发了但场景没变化**
   - 目标 group 未加载/不在该 scene
   - `REFRESH_GROUP_SUITE` 的 `"groupId,suiteId"` 写错分隔符（本仓库用 `;` 分多条，`,` 分组与 suite）

---

## 27.10 小结

- `QuestCond/QuestContent/QuestExec` 是任务系统的“指令集/DSL”，但 **handlers 决定真实可用子集**。
- **Accept 阶段是按 key 索引候选任务**，`params[0]` 与 `param_str` 的匹配是成败关键。
- **只改脚本/数据**时，最稳的推进路线仍然是：  
  `QUEST_CONTENT_LUA_NOTIFY(param_str=key)` + `ScriptLib.AddQuestProgress(key)`  
  再配 `QUEST_EXEC_NOTIFY_GROUP_LUA / REFRESH_GROUP_SUITE` 做世界编排。

---

## Revision Notes

- 2026-01-31：首次撰写本专题；整理了本仓库的 QuestCond/QuestContent/QuestExec handler 覆盖与“只改脚本/数据”的选型配方。

