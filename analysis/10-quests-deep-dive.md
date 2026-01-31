# 10 任务系统专题：Quest 状态机（数据驱动）与 Lua/场景联动

本文是对 `analysis/03-data-model-and-linking.md` 中“任务/对白（Quest/Talk）”部分的专题扩展，目标是把 **Quest 当成一套“可编排状态机 DSL + 执行器”** 来理解：  
你未来想“只改脚本/数据就能增删改剧情/玩法”，最核心的就是掌握 Quest 的 **条件（Cond/Content）→ 进度 → 执行（Exec）→ 与 Scene/Lua 的粘合点**。

与其他章节关系：

- `analysis/02-lua-runtime-model.md`：Lua 事件系统与 ScriptLib API（Quest 会大量依赖）。
- `analysis/03-data-model-and-linking.md`：Quest/Talk/Trigger/TextMap 的表结构与 ID 映射。
- `analysis/04-extensibility-and-engine-boundaries.md`：哪些 Exec/ScriptLib 缺失会迫使你下潜 Java。

> 读者预期：你不需要先把所有 Java 细节吃透；但需要知道“哪些点是引擎负责、哪些点是数据/脚本可编排”，以及关键的事件契约（evt.param/source 等）。

---

## 10.1 把 Quest 系统当成“状态机 + Side Effects（Exec）”

在 Grasscutter 的实现里，一个子任务（subQuest）可以抽象成：

1. **接取条件（AcceptCond）**：决定“什么时候把这个 subQuest 加进玩家任务列表并置为 UNFINISHED”；
2. **完成/失败条件（FinishCond/FailCond）**：决定“在已接取的前提下，什么时候完成/失败”；
3. **执行器（BeginExec/FinishExec/FailExec）**：在状态变化时做副作用（改 group/suite、发 Lua 事件、传送、给物品、改 questVar…）。

把它画成统一模型就是：

```
QuestAcceptCondition  --(Cond事件触发 & LogicType计算)-->  QuestState = UNFINISHED
QuestContentCondition --(Content事件触发 & LogicType计算)--> QuestState = FINISHED/FAILED
         |                                        |
         +-------------- Exec Side Effects --------+
```

**编排层（你主要要改的）**：

- `resources/ExcelBinOutput/QuestExcelConfigData.json`（核心）
- `resources/BinOutput/Quest/*.json`（主任务元数据、subQuest 顺序/rewind/finishParent 等附加信息）
- `resources/ExcelBinOutput/TriggerExcelConfigData.json`（给 `QUEST_CONTENT_TRIGGER_FIRE` 用）
- `resources/ExcelBinOutput/TalkExcelConfigData.json`（对白驱动）
- `resources/Scripts/Quest/Share/Q*ShareConfig.lua`（偏数据：teleport/rewind）
- `resources/ScriptSceneData/flat.luas.scenes.full_globals.lua.json`（dummy points，供 talk/rewind/传送查坐标）

**引擎层（你只在边界处需要知道）**：

- 任务管理：`Grasscutter/src/main/java/emu/grasscutter/game/quest/QuestManager.java`
- 子任务运行态：`.../game/quest/GameQuest.java`
- 父任务（主任务线）运行态：`.../game/quest/GameMainQuest.java`
- 条件/内容/Exec 派发：`.../game/quest/QuestSystem.java`
- 关键桥：`.../scripts/ScriptLib.java`（Lua→Quest）、`.../game/world/Scene.java`（TriggerFire）、`.../game/player/Player.java`（Enter/LeaveRegion→Quest）

---

## 10.2 数据层：Quest 相关文件“职责分工”

### 10.2.1 `QuestExcelConfigData.json`：subQuest 的“状态机定义”

位置：`resources/ExcelBinOutput/QuestExcelConfigData.json`

你最关心的字段（按“编排意义”整理）：

| 字段 | 你应该把它当成 | 典型用途 |
|---|---|---|
| `subId` / `mainId` / `order` | 状态机节点 ID / 所属主线 / 顺序 | 串联任务链、回溯、UI 展示 |
| `acceptCond` + `acceptCondComb` | 接取条件列表 + AND/OR/None | “到达某个状态/等级/变量/事件”才接任务 |
| `finishCond` + `finishCondComb` | 完成条件列表 + AND/OR | “进入某区域/对话完成/脚本上报进度/杀怪计数…” |
| `failCond` + `failCondComb` | 失败条件（可选） | “失败地城/超时/离开区域…” |
| `beginExec` / `finishExec` / `failExec` | 状态变更时的副作用 | 驱动 Lua、刷新 suite、传送、改 questVar 等 |
| `guide` / `showGuide` / `guideTipsTextMapHash` | 引导信息 | UI 指引（客户端表现） |
| `gainItems` / `trialAvatarList` | 奖励/试用角色 | 纯数据驱动 |

注意：在本仓库的资源里，很多 subQuest 条目还会带 `json_file: "xxx.json"`（方便回溯来源），对服务端意义不大，但对你做数据治理很有用。

### 10.2.2 `BinOutput/Quest/*.json`：主任务（parent quest）元数据 + 对 subQuest 的附加信息

位置：`resources/BinOutput/Quest/<mainId>.json`，例如 `resources/BinOutput/Quest/352.json`

在 Grasscutter 当前实现里，这类文件会被 `ResourceLoader.loadQuests()` 加载到 `MainQuestData`（见 `.../data/binout/MainQuestData.java`），它主要做两件事：

1) 提供主任务元数据：`series/titleTextMapHash/rewardIdList/suggestTrackMainQuestList...`  
2) 给 subQuest 附加一些“Excel 里可能没有/或以这里为准”的字段：`isRewind/finishParent`（通过 `MainQuestData.onLoad()` → `QuestData.applyFrom(...)`）

> 实务建议：你做“自制任务”时，**不要只改一个文件**。  
> 把 `QuestExcelConfigData` 当“状态机定义”，把 `BinOutput/Quest/<mainId>.json` 当“任务线元数据 + 运行附加信息”，两者一起维护更稳。

### 10.2.3 `TriggerExcelConfigData.json`：把“触发器 ID”映射到“场景/Group/TriggerName”

位置：`resources/ExcelBinOutput/TriggerExcelConfigData.json`

它服务于一种非常关键的 finishCond：`QUEST_CONTENT_TRIGGER_FIRE`。

条目的结构很简单：

| 字段 | 含义 |
|---|---|
| `id` | triggerId（QuestContent/Condition 里引用的那个整数） |
| `sceneId` | 触发发生在哪个 scene |
| `groupId` | 触发器所在的 group（scene group 脚本文件名里那个 groupId） |
| `triggerName` | 触发器名字（通常形如 `ENTER_REGION_<regionConfigId>` / `LEAVE_REGION_<regionConfigId>`） |

### 10.2.4 对话与 dummy point：Talk 表 + 扁平化 ScriptSceneData

对白表：

- `resources/ExcelBinOutput/TalkExcelConfigData.json`（对白节点与 finishExec）

dummy point 来源：

- `resources/ScriptSceneData/flat.luas.scenes.full_globals.lua.json`
  - 内部按 key 保存了诸如：`<sceneId>/scene<sceneId>_dummy_points.lua` 的结构化内容
  - talk/quest 的“传送/回溯”通常会在这里查 `xxx.pos` / `xxx.rot`

对应引擎执行器例子：

- `Grasscutter/src/main/java/emu/grasscutter/game/talk/exec/ExecTransSceneDummyPoint.java`：`TALK_EXEC_TRANS_SCENE_DUMMY_POINT`

---

## 10.3 加载链路：数据如何进到运行时 Map

从 `ResourceLoader.loadAll()` 的角度，任务相关加载可以心算成：

1. Excel 配表加载（GameResource 反射）  
   - `QuestExcelConfigData.json` → `QuestData`（subQuest 状态机）
   - `TriggerExcelConfigData.json` → `TriggerExcelConfigData`（TriggerFire 映射）
   - `TalkExcelConfigData.json` → `TalkConfigData`（对白）
2. `loadQuests()`：加载 `BinOutput/Quest/*.json` → `MainQuestData`（主任务线元数据），并把 subQuest 的附加字段 apply 到 `QuestData`
3. `loadQuestShareConfig()`：执行 `Scripts/Quest/Share/Q*ShareConfig.lua`，把 `quest_data/rewind_data` 反序列化进 `GameData.teleportDataMap/rewindDataMap`
4. `loadScriptSceneData()`：加载 `ScriptSceneData/*.json`（包含 dummy points 的扁平化数据）

你想定位“某张表到底有没有被用到”，最可靠的方法是从 `ResourceLoader` 反查（`analysis/01-overview.md` 已有总览入口）。

---

## 10.4 运行态对象：QuestManager / GameMainQuest / GameQuest

### 10.4.1 QuestManager（玩家侧任务管理器）

文件：`Grasscutter/src/main/java/emu/grasscutter/game/quest/QuestManager.java`

你需要的理解：

- 每个 Player 一个 `QuestManager`
- 它持有玩家当前的 `mainQuests`（每个主任务线一个 `GameMainQuest`）
- **事件驱动**：任何“会影响任务的行为”都会被转成 `queueEvent(...)` → `triggerEvent(...)` 的形式
- 事件执行是异步的：`QuestManager.eventExecutor`（线程池）

### 10.4.2 GameMainQuest（父任务/任务线运行态）

文件：`Grasscutter/src/main/java/emu/grasscutter/game/quest/GameMainQuest.java`

关键点：

- 它是“任务线容器”：持有所有 childQuests（subQuestId → `GameQuest`）
- 有 `questVars[5]` 与 `timeVar[10]`（很多“剧情分支/阶段”靠它们表达）
- 负责在 `tryFinishSubQuests / tryFailSubQuests` 中遍历子任务并计算 LogicType
- 持久化：Morphia entity（存库）

### 10.4.3 GameQuest（子任务运行态）

文件：`Grasscutter/src/main/java/emu/grasscutter/game/quest/GameQuest.java`

除了 state/时间戳外，最关键的两个“编排层接口”是：

1) **Finish/Fail 进度列表**：`finishProgressList` / `failProgressList`  
   - 每个 finishCond/failCond 条目对应一个进度位（0/1）  
   - `LogicType.calculate(...)` 用它们决定是否完成/失败

2) **TriggerFire 的运行态缓存**：`triggerData` + `triggers`  
   - `triggerData`: `triggerName -> TriggerExcelConfigData`  
   - `triggers`: `triggerName -> boolean`（是否已触发）

它们共同支撑了最重要的 finishCond：`QUEST_CONTENT_TRIGGER_FIRE`（下文专门展开）。

---

## 10.5 “接任务”是怎么发生的：AcceptCond 的索引与触发

### 10.5.1 beginCondQuestMap：把 acceptCond 做成倒排索引（非常关键）

文件：`Grasscutter/src/main/java/emu/grasscutter/data/excels/quest/QuestData.java`

`QuestData.onLoad()` 会把每个 subQuest 的 `acceptCond` 加进 `GameData.beginCondQuestMap`：

- key 由 `QuestData.questConditionKey(type, param[0], param_str)` 拼出来
- value 是可能被这个条件触发接取的 `QuestData` 列表

对应查询：

- `GameData.getQuestDataByConditions(condType, params[0], paramStr)`（见 `Grasscutter/src/main/java/emu/grasscutter/data/GameData.java`）

这意味着一件事：**AcceptCond 的性能与结构很依赖 `param[0]` 与 `param_str` 的“可索引性”**。  
如果你写的 acceptCond 把关键信息塞进 `param[1..]`，那么它很可能根本不会被索引命中。

### 10.5.2 triggerEvent(QuestCond)：事件 → 候选任务 → Condition handler → LogicType

文件：`QuestManager.triggerEvent(QuestCond condType, String paramStr, int... params)`

可心算流程：

1) 外界发生一件事（例如玩家升级/某 questVar 变化/脚本上报等）  
2) 引擎转成 `queueEvent(condType, paramStr, params...)`
3) 通过倒排索引取出“可能被接取的任务列表”
4) 对每个候选任务：
   - 逐条 acceptCond 调 `QuestSystem.triggerCondition(...)`
   - 把结果写到 `acceptProgressLists[subQuestId][i]`
   - `LogicType.calculate(acceptCondComb, acceptProgressList)` 决定是否接取
5) 若满足则 `addQuest(QuestData)` → `GameQuest.start()`

> 这解释了为什么很多任务的 acceptCond 都是“某 subQuest 已完成/已接取/某 questVar 值”等：它们天然可被索引，并且能用少量事件驱动整个任务树。

---

## 10.6 “完成/失败”是怎么发生的：Content 事件对 active quests 的评估

与 Accept 不同：Finish/Fail 是在“已接取的 active quests”上做评估，不需要倒排索引。

入口：`QuestManager.triggerEvent(QuestContent condType, String paramStr, int... params)`

逻辑：

1) 遍历所有未结束的 mainQuests
2) `mainQuest.tryFailSubQuests(...)`
3) `mainQuest.tryFinishSubQuests(...)`

在 `tryFinishSubQuests` 内：

- 对每个 active subQuest：
  - 找出 finishCond 中 type == `condType` 的条目
  - 对每条调用 `QuestSystem.triggerContent(...)`（对应 Content handler）
  - 更新 `finishProgressList[i]`
  - `LogicType.calculate(finishCondComb, finishProgressList)` 决定是否完成

完成后 `GameQuest.finish()` 会：

- 置 state FINISHED、发任务更新包
- 执行 `finishExec`
- 触发一些“任务状态相关的 Content/Cond”（例如 `QUEST_CONTENT_QUEST_STATE_EQUAL`）用于解锁后续
- 发 `QUEST_CONTENT_FINISH_PLOT` 等（某些剧情/地城联动）
- 加发放物品 `gainItems`
- 若 `finishParent = true`，会连带 `GameMainQuest.finish()` 发主线奖励

---

## 10.7 关键粘合点 A：`QUEST_CONTENT_TRIGGER_FIRE`（进入/离开区域驱动任务）

这是 Grasscutter 任务系统里最“脚本/关卡编排味”的一条链路：  
**Quest 表里只写一个 triggerId，但运行时会把它关联到某个 scene/group 的 region，然后当玩家进出 region 时自动算任务进度。**

### 10.7.1 这条链路由三段契约拼起来

#### ① QuestExcel 的 finishCond 写 triggerId

例子：`resources/ExcelBinOutput/QuestExcelConfigData.json` 中 `subId=35200`：

- `finishCond.type = QUEST_CONTENT_TRIGGER_FIRE`
- `finishCond.param[0] = 1021`

#### ② TriggerExcel 把 triggerId 映射到 scene/group/triggerName

例子：`resources/ExcelBinOutput/TriggerExcelConfigData.json` 中 `id=1021`：

- `sceneId = 3`
- `groupId = 133003901`
- `triggerName = "ENTER_REGION_68"`

#### ③ SceneGroup 脚本里确实存在这个 trigger/region

例子：`resources/Scripts/Scene/3/scene3_group133003901.lua`：

- `triggers` 里有 `name="ENTER_REGION_68"`
- `regions` 里有 `config_id = 68`

### 10.7.2 运行时发生了什么（按时间顺序）

把引擎侧关键点串起来：

1) subQuest 接取：`GameQuest.start()`（`.../game/quest/GameQuest.java`）
   - 找出本任务所有 `QUEST_CONTENT_TRIGGER_FIRE` 条件
   - 对每条条件：
     - `TriggerExcelConfigData trigger = GameData.getTriggerExcelConfigDataMap().get(triggerId)`
     - `quest.triggerData[triggerName] = trigger`
     - `quest.triggers[triggerName] = false`
     - `Scene.loadTriggerFromGroup(group, triggerName)` **注册 trigger 与 region**

2) 玩家进入 region：`Player.onEnterRegion(SceneRegion region)`（`.../game/player/Player.java`）
   - 计算 `enterRegionName = "ENTER_REGION_" + region.config_id`
   - 遍历 active quests：
     - 如果 `quest.triggers` 包含这个 name，且 `region.groupId == triggerData.groupId`
     - 且它之前没触发过：把 `quest.triggers[enterRegionName]` 置 true
     - 然后 `queueEvent(QUEST_CONTENT_TRIGGER_FIRE, triggerId, 0)`

3) Content handler 评估：`ContentTriggerFire.execute(...)`（`.../game/quest/content/ContentTriggerFire.java`）
   - 根据 condition.param[0]（triggerId）反查 triggerName
   - 返回 `quest.triggers[triggerName] == true`

最终结果：`finishProgressList[i]=1`，LogicType 满足则任务完成。

### 10.7.3 你写自制任务时的“落地检查清单”

`QUEST_CONTENT_TRIGGER_FIRE` 不生效时，按下面顺序排：

1. **TriggerExcel 里 id 存在吗？**（`TriggerExcelConfigData.json`）
2. **sceneId/groupId/triggerName 指向的 group 脚本存在吗？**（`Scripts/Scene/<sceneId>/scene<sceneId>_group<groupId>.lua`）
3. **group 脚本里 region config_id 是否与 triggerName 后缀一致？**
   - `ENTER_REGION_68` → 必须有 `regions` 的 `config_id = 68`
4. **该 group 是否会被加载/或至少 trigger 被注册？**
   - 任务接取时 `loadTriggerFromGroup` 会“只注册 trigger/region”，不要求整个 group suite 被加载
5. **是否存在“同名但不在同 group”的 region？**
   - Grasscutter 在 `onEnterRegion` 里做了 groupId 校验（必须与 TriggerExcel 指向的 group 一致）

> 经验：TriggerFire 更像“Quest 系统自己管 region”，而不是依赖 group 脚本的 action。  
> group 脚本里 trigger 的 action 常常是空的——因为真正的“完成判断”在 QuestContent handler 中完成。

---

## 10.8 关键粘合点 B：`QUEST_CONTENT_LUA_NOTIFY` + `ScriptLib.AddQuestProgress`（脚本上报进度）

这是“玩法脚本（Lua）→ 任务系统（Quest）”最常用的桥：  
当你的玩法逻辑发生（怪物死/机关解开/计数到达/玩家交互），Lua 通过一个字符串 key 上报，Quest 表用 `param_str` 接住。

### 10.8.1 数据侧怎么写：finishCond 用 `param_str` 做 key

例子：`resources/ExcelBinOutput/QuestExcelConfigData.json` 中 `subId=7166206`：

- `finishCond.type = QUEST_CONTENT_LUA_NOTIFY`
- `finishCond.param_str = "2450580022"`
- `finishCond.count = 1`

> `count` 表示需要累计到多少（未填/为 0 时一般按 1 处理）。

### 10.8.2 脚本侧怎么写：在 action 里 `AddQuestProgress(key)`

例子：`resources/Scripts/Scene/45058/scene45058_group245058002.lua`（简化）

```lua
function action_EVENT_ANY_GADGET_DIE_2006(context, evt)
  ScriptLib.AddQuestProgress(context, "2450580022")
  return 0
end
```

### 10.8.3 引擎侧发生了什么

Lua 调用入口：`Grasscutter/src/main/java/emu/grasscutter/scripts/ScriptLib.java`

- `AddQuestProgress(String key)` 会：
  - `player.getPlayerProgress().addToCurrentProgress(key, 1)`（累加进度）
  - `player.getQuestManager().queueEvent(QUEST_CONTENT_LUA_NOTIFY, key)`（触发任务系统去重新评估）

对应 Content handler：`ContentLuaNotify.execute(...)`（`.../game/quest/content/ContentLuaNotify.java`）

- 取 `condition.param_str` 对应的进度值，与 `condition.count` 比较
- 满足则返回 true

这条链路的好处是：

- 你可以完全在 Lua 中编排复杂条件，然后只在“达成时刻”上报一次
- `param_str` 本质是你自定义的 DSL key：**可读性与唯一性取决于你自己的命名策略**

### 10.8.4 自制任务的 key 命名建议（非常实用）

推荐把 key 当成“跨表的稳定事件名”，而不是随手写个数字：

- 最低配：`"<groupId><阶段/序号>"`（仓库里常见，例如 `2450580022`）
- 更可维护：`"Q<mainId>_<subId>_<Milestone>"`（例如 `Q71662_7166206_PUZZLE_DONE`）

只要你保证：

1. QuestExcel 的 `param_str` 与 Lua 上报的 key 完全一致
2. 同一个 key 不要被两个不同语义的任务复用（否则会串进度）

---

## 10.9 关键粘合点 C：`QUEST_EXEC_NOTIFY_GROUP_LUA`（Quest 状态变化 → Lua 事件）

当你希望“任务阶段变化驱动场景玩法变化”（例如：接任务刷怪、交任务开门、任务完成卸载机关），最通用的做法不是把逻辑塞进 QuestExec（Java），而是：

**QuestExec 只负责“发一个 Lua 事件”，然后在 group 脚本里用 Trigger 做玩法编排。**

### 10.9.1 数据侧怎么写：finishExec/beginExec 填 `QUEST_EXEC_NOTIFY_GROUP_LUA`

例子：`resources/ExcelBinOutput/QuestExcelConfigData.json` 中 `subId=7166204`：

```json
"finishExec": [
  {
    "type": "QUEST_EXEC_NOTIFY_GROUP_LUA",
    "param": ["45058", "245058002"]
  }
]
```

含义：

- param[0]：sceneId
- param[1]：groupId

### 10.9.2 引擎侧契约：会发哪些 EventType？evt 参数是什么？

执行器：`Grasscutter/src/main/java/emu/grasscutter/game/quest/exec/ExecNotifyGroupLua.java`

它会在 **同 scene** 内对指定 group 触发：

- 任务开始时：`EventType.EVENT_QUEST_START`
- 任务完成时：`EventType.EVENT_QUEST_FINISH`

并设置 ScriptArgs（你可以把它当成 Lua 侧 `evt`）：

- `evt.param1 = subQuestId`
- `evt.param2 = 1/0`（完成时 1，开始时 0）
- `evt.source`（eventSource）= subQuestId（字符串）

### 10.9.3 脚本侧怎么接：Trigger 监听 QUEST_START / QUEST_FINISH

例子：`resources/Scripts/Scene/45058/scene45058_group245058002.lua` 里有：

- `event = EventType.EVENT_QUEST_FINISH`
- `source = "7166204"`

对应你自制任务时的写法范式：

```lua
triggers = {
  { name="QUEST_START_...", event=EventType.EVENT_QUEST_START, source="7166204", action="..." },
  { name="QUEST_FINISH_...", event=EventType.EVENT_QUEST_FINISH, source="7166204", action="..." },
}
```

这样你就把“剧情/任务推进”与“玩法单元（group）”解耦：

- Quest 表只负责“阶段变化与通知”
- group 脚本负责“怎么刷怪/开门/给奖励/切 suite”

---

## 10.10 Group/Suite 与任务阶段：`QUEST_EXEC_REFRESH_GROUP_SUITE` / 动态 group

Quest 系统除了“通知 Lua”，还支持直接操纵 group：

### 10.10.1 刷新 suite：`QUEST_EXEC_REFRESH_GROUP_SUITE`

执行器：`Grasscutter/src/main/java/emu/grasscutter/game/quest/exec/ExecRefreshGroupSuite.java`

参数格式（注意它把多个条目塞到一个字符串里）：

- param[0]：sceneId
- param[1]：`"groupId,suiteId;groupId,suiteId;..."`

执行效果：

1) 调 `SceneScriptManager.refreshGroupSuite(groupId, suiteId, quest)`  
2) 把 `(scene, group, suite)` 记录到 `quest.mainQuest.questGroupSuites`
3) 并将 `group.dontUnload = true`（防止被卸载）

### 10.10.2 动态加载/卸载 group：`REGISTER_DYNAMIC_GROUP / UNREGISTER_DYNAMIC_GROUP`

执行器：

- `ExecRegisterDynamicGroup`：加载 dynamic group，并记录 QuestGroupSuite
- `ExecUnregisterDynamicGroup`：卸载并移除 QuestGroupSuite

这类 Exec 的“设计意图”是：任务阶段驱动“动态内容”出现/消失（而不是常驻在 block 的 groups 列表里）。

### 10.10.3 进场景恢复：QuestGroupSuite 的持久化意义

进场景时（`HandlerEnterSceneDoneReq`）会：

1) `questGroupSuites = player.getQuestManager().getSceneGroupSuite(sceneId)`
2) `player.getScene().loadGroupForQuest(questGroupSuites)`
3) `PacketGroupSuiteNotify(questGroupSuites)` 通知客户端

这让你可以把“任务阶段控制的 suite”当成一种持久状态：  
玩家下线/换场景再回来，仍然能把关卡恢复到正确阶段。

---

## 10.11 Talk/剧情 与 Quest 的关系（你需要的最小闭环）

### 10.11.1 对话完成会触发哪些 QuestContent？

玩家触发对话时：`TalkManager.triggerTalkAction(talkId, npcEntityId)` 会：

- 执行 talk 的 `finishExec`（TalkSystem）
- 然后对 QuestManager 触发：
  - `QUEST_CONTENT_COMPLETE_ANY_TALK`
  - `QUEST_CONTENT_COMPLETE_TALK`
  - `QUEST_COND_COMPLETE_TALK`（accept 侧也可能用）

因此你在 QuestExcel 里经常会看到：

- `finishCond.type = QUEST_CONTENT_COMPLETE_TALK`
- `finishCond.param[0] = talkId`

### 10.11.2 传送到 dummy point：TalkExec `TRANS_SCENE_DUMMY_POINT`

TalkExec 执行器：`ExecTransSceneDummyPoint`

它会：

- 从 `flat.luas.scenes.full_globals.lua.json` 找到对应 `scene*_dummy_points.lua` 的 dummyPoints
- 取 `dummyPointName.pos`，然后 `transferPlayerToScene(sceneId, pos)`

这套设计的抽象意义是：

- “剧情/对白想传送到哪”是数据驱动的（talk exec param）
- 坐标不是 hardcode 在 Java，而是来自脚本资源（dummy points 的扁平化结果）

---

## 10.12 QuestVar / TimeVar：任务线内部的“轻量存储 + 条件触发器”

### 10.12.1 questVars：主任务线上的 5 个整型槽位

`GameMainQuest.questVars` 固定长度为 5（默认全 0），典型用途：

- 分支选择、阶段标记、计数器（比 group variable 更“任务线级别”）
- 与 accept/finish 条件绑定：`QUEST_COND_QUEST_VAR_*`、`QUEST_CONTENT_QUEST_VAR_*`

当 questVar 变化时 `triggerQuestVarAction(...)` 会自动触发一组 Cond/Content 事件，并向客户端同步 questVar。

### 10.12.2 timeVar：任务线上的 10 个时间槽位

`GameMainQuest.timeVar` 长度 10，用于：

- 记录“某个阶段开始时刻”
- 配合 `GAME_TIME_TICK` / 超时判断等内容条件

相关 Exec：

- `QUEST_EXEC_INIT_TIME_VAR` / `QUEST_EXEC_CLEAR_TIME_VAR`

> 实务建议：如果你做“限时挑战”玩法，优先用 **group 的 time axis + variables** 实现；  
> 只有当它必须与任务线状态绑定（可回溯/可持久化）时，再考虑 timeVar。

---

## 10.13 自制任务工作流（只改数据/脚本的“最小闭环”）

下面给一套“从 0 到 1”的模板思路：你可以把它当成 **ARPG 引擎编排层的 Quest DSL 使用手册**。

### 10.13.1 选一个你要驱动的玩法单元（group）

你需要一个 group 来承载玩法（刷怪/机关/区域/交互/奖励）：

- 新建或复用 `resources/Scripts/Scene/<sceneId>/scene<sceneId>_group<groupId>.lua`
- 用 `variables + suites` 表达玩法阶段（FSM）
- 用 Trigger+Action 处理事件（ENTER_REGION / SELECT_OPTION / ANY_MONSTER_DIE…）

### 10.13.2 在 QuestExcel 里定义 subQuest：用哪种 finishCond 取决于你要的“触发方式”

最常用的两类：

1) **TriggerFire（进/出区域）**：  
   - finishCond：`QUEST_CONTENT_TRIGGER_FIRE` → 引用 TriggerExcel 的 triggerId  
   - 适合：到达某点/走到某区域就推进剧情

2) **LuaNotify（玩法脚本上报）**：  
   - finishCond：`QUEST_CONTENT_LUA_NOTIFY` + `param_str = <你的key>`  
   - 适合：解谜/战斗/小游戏完成后推进任务（Lua 决定“完成时刻”）

### 10.13.3 用 Exec 把“任务阶段变化”接到“场景玩法变化”

推荐优先级：

1) `QUEST_EXEC_NOTIFY_GROUP_LUA`：让 group 自己决定怎么变（最灵活、最脚本化）
2) `QUEST_EXEC_REFRESH_GROUP_SUITE`：阶段很明确就是切 suite（更硬但更省事）
3) `REGISTER_DYNAMIC_GROUP`：需要“任务阶段才加载这个 group”（内容量大/想省常驻）

### 10.13.4 需要回溯/传送时：再碰 ShareConfig 与 dummy points

只有当你要做：

- 任务回溯（rewind）到某个点
- 对话/任务阶段推进带传送

才需要：

- `resources/Scripts/Quest/Share/Q*ShareConfig.lua`（quest_data/rewind_data）
- `flat.luas.scenes.full_globals.lua.json` 或对应 dummy points 来源

先把“玩法编排闭环”跑通，再补这些“体验层”资源，效率更高。

---

## 10.14 排错：任务不接/不推/不触发时怎么查？

### 10.14.1 先把问题分类：是 Accept 失败还是 Finish 失败？

- **问题 A：任务根本没出现在任务列表**  
  → 查 acceptCond 是否会被事件触发（倒排索引 key 是否命中）

- **问题 B：任务已接但不完成**  
  → 查 finishCond 的事件是否触发、Content handler 是否返回 true、LogicType 是否满足

### 10.14.2 TriggerFire 排错（最常见）

按 10.7.3 的清单查；尤其注意：

- triggerName 后缀必须能解析成 region config_id（Grasscutter 用 `triggerName.substring(13)` 取数字）
- `TriggerExcelConfigData.groupId` 必须与 region 所属 group 一致（Player.onEnterRegion 会校验）

### 10.14.3 LuaNotify 排错（最常见）

检查三件事：

1) QuestExcel 的 `param_str` 是否与 Lua 上报 key 完全一致（大小写/下划线/数字）
2) `count` 是否为你期望的累计次数
3) Lua 的 action 是否真的跑到了（可以临时加 `ScriptLib.PrintContextLog`）

### 10.14.4 ExecNotifyGroupLua 排错

- sceneId 必须与玩家当前 scene 相同（`ExecNotifyGroupLua` 里会校验）
- groupId 必须是要接事件的那个 group
- group 脚本里的 trigger `source` 字符串要对齐 subQuestId（通常写 `"7166204"`）

### 10.14.5 ScriptLib API 缺失导致“脚本跑了但效果没发生”

很多 Common/Quest 相关脚本会调用一些 `ScriptLib` 方法，而它们在 `ScriptLib.java` 里可能是 `TODO/unimplemented`。  
遇到这类情况按 `analysis/04-extensibility-and-engine-boundaries.md` 的原则处理：

- 要么改 Lua 绕开缺失 API
- 要么补 Java（并把它当成“引擎层扩展点”管理）

---

## 10.15 小结：把 Quest 当成 ARPG 编排 DSL 的“使用方式”

如果你只记住三件事就能开始魔改：

1) **Accept 用倒排索引**：acceptCond 的 `type + param[0] + param_str` 是“可被触发的键”
2) **Finish 事件评估 active quests**：finishCond 的 type 对应 Content handler；LogicType 决定是否完成
3) **三条粘合桥足够覆盖 80% 场景**：
   - TriggerFire（区域驱动推进）
   - LuaNotify（玩法脚本上报推进）
   - NotifyGroupLua（任务阶段驱动 group 脚本编排）

当你能用这三条桥做出一个“接任务 → 进区域 → 解谜/刷怪 → 上报进度 → 完成任务 → 切场景玩法阶段”的闭环时，你就已经在把它当作“ARPG 引擎的玩法编排层”使用了。

---

## Revision Notes

- 2026-01-31：创建本文档（任务系统专题初版）。  

