# 13 事件契约专题：EventType → ScriptArgs(evt) → Trigger 选择与参数语义

本文回答一个“写脚本必须吃透”的问题：  
**某个 EventType 到底会给 Lua 传什么 `evt`？trigger 的 `source`/名字/参数应该怎么写才会被命中？**

你可以把它当作“脚本层 DSL 的运行时 ABI（Application Binary Interface）”：

- 事件从哪里触发（Java 哪个点发出）
- `ScriptArgs` 的字段在该事件里的语义是什么（param1/param2/param3/source/source_eid/target_eid）
- Trigger 是如何被筛选与调用的（groupId 与 source 的匹配规则）

与其他章节关系：

- `analysis/02-lua-runtime-model.md`：Lua 函数调用模型（context/evt）、Trigger/Condition/Action 结构。
- `analysis/10-quests-deep-dive.md`：QuestExec 会主动发 `EVENT_QUEST_START/FINISH`。
- `analysis/12-scene-and-group-lifecycle.md`：事件发生时序与 group/suite 生命周期。

---

## 13.1 `evt` 在 Grasscutter 里是什么：`ScriptArgs`

文件：`Grasscutter/src/main/java/emu/grasscutter/scripts/data/ScriptArgs.java`

它就是 Lua 里看到的 `evt` 对象，字段如下：

| 字段 | 类型 | 备注 |
|---|---|---|
| `param1/param2/param3` | int | 事件主参数（随事件类型改变语义） |
| `group_id` | int | 事件目标 group（用于 trigger 筛选） |
| `source` | String | 事件 source（用于 trigger.source 匹配；也被 timer/time_axis 使用） |
| `source_eid` | int | source entity id（部分事件会填） |
| `target_eid` | int | target entity id（部分事件会填） |
| `type` | int | EventType 常量值 |

> 你写脚本的关键不在“记住所有 EventType”，而在“对每个你要用的 EventType，知道它的 evt 字段语义”。

---

## 13.2 Trigger 是怎么被选出来的？（非常重要）

核心代码：`SceneScriptManager.realCallEvent(...)`  
文件：`Grasscutter/src/main/java/emu/grasscutter/scripts/SceneScriptManager.java`

它的筛选规则可以总结为三层过滤：

### 13.2.1 先按事件类型取集合

`currentTriggers` 是 `eventId -> Set<SceneTrigger>` 的索引。

### 13.2.2 再按 group_id 与 source 匹配

- **大多数事件**：
  - 如果 `params.group_id == 0`：不按 group 过滤（广播式）
  - 否则：只匹配 `trigger.currentGroup.id == params.group_id`
  - 且 `trigger.source` 为空或等于 `params.source`

- **ENTER/LEAVE_REGION 特殊分支**：
  - 除了 source 匹配外，还会按 trigger 名字后缀过滤：
    - `ENTER_REGION_68` → `evt.param1` 必须是 `68`
    - 过滤逻辑来自 `trigger.getName().substring(13)`

这解释了两件事：

1) 为什么官方脚本 trigger 名字经常固定成 `ENTER_REGION_<id>`（它不仅是命名约定，还参与了路由匹配）  
2) 为什么你自定义 region trigger 时，最好也遵循这种命名，否则可能根本不命中

### 13.2.3 最后才会调用 condition/action

每个候选 trigger：

1) 调 condition（必须返回 boolean）
2) condition true 才调 action

---

## 13.3 Condition/Action 的返回值语义（和你以为的不完全一样）

### 13.3.1 condition 必须返回 boolean

`evaluateTriggerCondition(...)` 只接受 boolean：

- `ret.isboolean() && ret.checkboolean()`

如果你的 condition 返回 `0/1`（int），会被当成 false（不触发 action）。

### 13.3.2 action 的返回值会影响 trigger 是否被自动注销

调用 action 后，`SceneScriptManager.callTrigger(...)` 会做自动 deregister：

- 若 trigger 被标记 `preserved`（通常是 RefreshGroup 过程为了避免误注销），则先清掉 preserved，不注销
- 否则满足以下任意条件会注销：
  - action 返回 boolean 且为 false
  - action 返回 int 且不等于 0（例如 -1）
  - `trigger_count > 0` 且调用次数达到上限

对脚本编排的含义：

- **想让 trigger 常驻**：action 尽量 `return 0`
- **你用 `return -1` 表示错误时**：它会导致 trigger 被注销（可能不是你想要的）

### 13.3.3 TimerEvent 会被自动取消

如果 trigger.event 是 `EVENT_TIMER_EVENT`：

- action 触发后会 `cancelGroupTimerEvent(groupID, source)`

这使得 TimerEvent 更像“一次性到点执行”，哪怕底层调度是 repeating。

---

## 13.4 常用事件的 `evt` 契约表（以本仓库实际触发点为准）

下面只列“在当前实现里明确被触发”的高频事件（足以覆盖大多数玩法脚本）。

### 13.4.1 GROUP_LOAD / GROUP_REFRESH / 变量变化

| EventType | 触发点 | evt 关键字段 | 你在 Lua 里常用的判断 |
|---|---|---|---|
| `EVENT_GROUP_LOAD` | `Scene.onLoadGroup` | `group_id=groupId`, `param1=groupId` | 用于初始化/恢复（读变量、补实体、开 time axis） |
| `EVENT_GROUP_REFRESH` | `SceneScriptManager.refreshGroup` | `group_id=groupId`（param 通常为 0） | 常见于刷新后重建状态（注意本实现未触发 WILL_REFRESH） |
| `EVENT_VARIABLE_CHANGE` | `ScriptLib.SetGroupVariableValue*` | `param1=new`, `param2=old`, `source=varName` | `if evt.source_name == "stage" and evt.param1 == 1 then ... end`（官方常用写法） |

> `EVENT_GROUP_WILL_UNLOAD / EVENT_GROUP_WILL_REFRESH` 在当前代码中未发现触发点（属于缺口，见 `analysis/14`）。

### 13.4.2 ENTER/LEAVE_REGION（Region 判定来自服务端几何计算）

触发点：`SceneScriptManager.checkRegions()`（每 tick 扫 regions）

| EventType | evt 字段语义 |
|---|---|
| `EVENT_ENTER_REGION` | `group_id=region所属group`, `param1=regionConfigId`, `source_eid=regionEntityId`, `target_eid=进入者实体id`, `source=进入者EntityType数值(字符串)` |
| `EVENT_LEAVE_REGION` | 同上（leave） |

附加行为（非常关键）：  
当 ENTER/LEAVE 的 trigger action 被执行后，`callTrigger` 还会调用：

- `Player.onEnterRegion(metaRegion)` / `Player.onLeaveRegion(metaRegion)`

这会进一步驱动 Quest 的 `QUEST_CONTENT_TRIGGER_FIRE`（见 `analysis/10`）。  
因此你可以把 region trigger 理解为“两段式副作用”：

1) Lua action（关卡脚本逻辑）
2) Quest triggerFire（任务系统逻辑）

### 13.4.3 GADGET 相关：创建/状态/死亡/采集/选项

| EventType | 触发点 | evt 字段语义 |
|---|---|---|
| `EVENT_GADGET_CREATE` | `EntityGadget.onCreate` | `param1=config_id` |
| `EVENT_GADGET_STATE_CHANGE` | `EntityGadget.updateState` | `param1=newState`, `param2=config_id`, `param3=oldState` |
| `EVENT_ANY_GADGET_DIE` | `EntityGadget.onDeath` | `param1=config_id` |
| `EVENT_GATHER` | `GadgetGatherObject.onInteract` | `param1=config_id`, `source=string(config_id)`（常等于自身） |
| `EVENT_SELECT_OPTION` | `HandlerSelectWorktopOptionReq` | `param1=worktop config_id`, `param2=option_id` |

### 13.4.4 MONSTER 相关：死亡、按 tick “live”、血量变化

| EventType | 触发点 | evt 字段语义 | 备注 |
|---|---|---|---|
| `EVENT_ANY_MONSTER_DIE` | `EntityMonster.onDeath` | `param1=config_id` | 这里是 monster 实例 config_id，不是 monster_id |
| `EVENT_ANY_MONSTER_LIVE` | `EntityMonster.onTick` | `param1=config_id` | 注意：本实现是“每 tick 发一次”，语义偏离“spawn/出现”直觉，谨慎使用 |
| `EVENT_SPECIFIC_MONSTER_HP_CHANGE` | `EntityMonster.runLuaCallbacks` | `param1=config_id`, `param2=monster_id`, `param3=cur_hp`, `source_eid=entityId`, `source=string(config_id)` | 适合做“血量阈值触发” |

### 13.4.5 GADGET 血量变化（可用于护送/塔防目标）

触发点：`EntityBaseGadget.runLuaCallbacks`

| EventType | evt 字段语义 |
|---|---|
| `EVENT_SPECIFIC_GADGET_HP_CHANGE` | `param1=config_id`, `param2=gadget_id`, `param3=cur_hp`, `source_eid=entityId`, `source=string(config_id)` |

### 13.4.6 TIME_AXIS_PASS 与 TIMER_EVENT（两套计时工具，source 语义不同）

| EventType | 触发点 | evt 字段语义 | 适合 |
|---|---|---|---|
| `EVENT_TIME_AXIS_PASS` | `SceneTimeAxis.Task`（由 `ScriptLib.InitTimeAxis` 建立） | `source=identifier`，其他 param 常为 0 | 节奏控制、轮询检查（但本实现只支持单段 delay） |
| `EVENT_TIMER_EVENT` | `SceneScriptManager.createGroupTimerEvent` | `source=timerName` | “到点触发一次”型逻辑（触发后会自动 cancel） |

### 13.4.7 PLATFORM_REACH_POINT（路线/平台）

触发点：`EntityGadget.startPlatform`（移动平台按路线点到达）

| EventType | evt 字段语义 |
|---|---|
| `EVENT_PLATFORM_REACH_POINT` | `param1=platform config_id`, `param2=route_id`, `param3=point_index`, `source=string(config_id)` |

### 13.4.8 CHALLENGE_SUCCESS/FAIL（挑战结算）

触发点：`WorldChallenge.done/fail`  
文件：`Grasscutter/src/main/java/emu/grasscutter/game/dungeons/challenge/WorldChallenge.java`

| EventType | evt 字段语义 | 备注 |
|---|---|---|
| `EVENT_CHALLENGE_SUCCESS` | `group_id=challenge所在group`, `source=challengeIndex`, `param2=finishedTime` | `param1` 常为 0；脚本常用 source 匹配 index |
| `EVENT_CHALLENGE_FAIL` | `group_id=challenge所在group`, `source=challengeIndex` | 目前未填 `param2` |

### 13.4.9 QUEST_START / QUEST_FINISH（任务驱动 Lua）

触发点：`QUEST_EXEC_NOTIFY_GROUP_LUA`  
文件：`Grasscutter/src/main/java/emu/grasscutter/game/quest/exec/ExecNotifyGroupLua.java`

| EventType | evt 字段语义 |
|---|---|
| `EVENT_QUEST_START` | `group_id=目标group`, `param1=subQuestId`, `param2=0`, `source=string(subQuestId)` |
| `EVENT_QUEST_FINISH` | `group_id=目标group`, `param1=subQuestId`, `param2=1`, `source=string(subQuestId)` |

脚本侧典型写法（提醒）：

- trigger.source 写 `"7166204"`（字符串）与 `evt.source` 匹配
- 或者在 condition/action 中直接用 `evt.param1` 判断 subQuestId

### 13.4.10 UNLOCK_TRANS_POINT（解锁传送点）

触发点：`PlayerProgressManager.unlockTransPoint`

| EventType | evt 字段语义 | 备注 |
|---|---|---|
| `EVENT_UNLOCK_TRANS_POINT` | `group_id=0`, `param1=sceneId`, `param2=pointId` | 同时也会触发 QuestContent `UNLOCK_TRANS_POINT` |

---

## 13.5 编排建议：写 Trigger 的 4 条硬规则

1) **region 触发器命名尽量用 `ENTER_REGION_<id>` / `LEAVE_REGION_<id>`**  
   因为引擎在筛选时会用名字后缀与 `evt.param1` 进行匹配。

2) **trigger.source 只在你明确需要“分流同一事件”时使用**  
   例如：
   - `EVENT_TIME_AXIS_PASS`：source=时间轴名字
   - `EVENT_TIMER_EVENT`：source=timer 名字
   - `EVENT_QUEST_*`：source=subQuestId
   - `EVENT_CHALLENGE_*`：source=challengeIndex  
   否则 source 留空更稳。

3) **condition 必须返回 boolean**  
   不要返回 `0/1`。

4) **action 尽量返回 0**  
   否则可能导致 trigger 被自动注销（尤其是 `return -1`）。

---

## 13.6 排错：事件触发了但 trigger 不跑，怎么查？

按这个顺序效率最高：

1) group 是否加载？（看是否触发过 GROUP_LOAD；见 `analysis/12`）
2) eventType 是否真的被触发？（从 Java 触发点反查）
3) trigger 是否被筛选掉？重点看：
   - group_id 是否一致（非 0 的事件只在对应 group 里找 trigger）
   - source 是否匹配（trigger.source 不为空时必须匹配 evt.source）
   - region trigger 名字后缀是否匹配 param1
4) condition 是否返回 boolean true？
5) action 是否因为返回非 0 导致被注销？（一次触发后就没了）

---

## Revision Notes

- 2026-01-31：创建本文档（事件契约专题初版）。
