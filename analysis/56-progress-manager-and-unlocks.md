# 56 专题：PlayerProgressManager/解锁与进度驱动：OpenState + ScenePoint/Area + SceneTag + PlayerProgress（任务/脚本触发器）

本文把“进度/解锁”当成一套通用的 **Gating & Progress Subsystem** 来拆：  
它负责把“玩家等级/任务完成/地图点位/场景标签”等状态，转换成：

- UI/系统功能的开放（OpenState）
- 地图点位/区域的解锁（ScenePoint/Area）
- 场景可见性/分歧路线（SceneTag）
- 任务条件的触发（QuestCond/QuestContent）
- Lua 事件的触发（如 `EVENT_UNLOCK_TRANS_POINT`）

与其他章节关系：

- `analysis/24-openstate-and-progress-gating.md`：OpenState/SceneTag 的宏观心智模型与只改数据的选型建议。
- `analysis/10-quests-deep-dive.md` / `analysis/27-quest-conditions-and-execs-matrix.md`：ProgressManager 会主动 `queueEvent(...)` 触发任务条件/内容计数。
- `analysis/13-event-contracts-and-scriptargs.md`：`EVENT_UNLOCK_TRANS_POINT` 等事件的参数语义属于事件 ABI。

---

## 56.1 模块入口：`PlayerProgressManager` 在登录与升级时被调用

文件：`Grasscutter/src/main/java/emu/grasscutter/game/player/PlayerProgressManager.java`

### 56.1.1 登录：`Player.onLogin()` 调 `progressManager.onPlayerLogin()`

文件：`Grasscutter/src/main/java/emu/grasscutter/game/player/Player.java`

登录包序列中（简化）：

- 先发 Player/Avatar/Quest/Codex/Widget 等数据包
- 然后 `progressManager.onPlayerLogin()`：
  - 尝试解锁 open states
  - 发 OpenStateUpdateNotify
  - 注入“解锁七天神像”相关任务（303 系列）

### 56.1.2 升级：`Player.setLevel()` 触发 open state 解锁与任务事件

文件：`Player.java#setLevel`

当等级变化成功后：

- `progressManager.tryUnlockOpenStates()`
- `questManager.queueEvent(QUEST_CONTENT_PLAYER_LEVEL_UP, level)`
- `questManager.queueEvent(QUEST_COND_PLAYER_LEVEL_EQUAL_GREATER, level)`

因此“等级→解锁/任务推进”在本仓库里是一个明确的自动链路。

---

## 56.2 OpenState：功能开关的“数据驱动条件系统”

### 56.2.1 OpenState 数据来源：`OpenStateConfigData.json`

文件：`Grasscutter/src/main/java/emu/grasscutter/data/excels/OpenStateData.java`

加载自：

- `resources/ExcelBinOutput/OpenStateConfigData.json`

关键字段：

- `id`
- `defaultState`：默认开启
- `allowClientOpen`：是否允许客户端主动 set
- `cond: List<OpenStateCond>`：
  - `condType`（PLAYER_LEVEL / QUEST / PARENT_QUEST / OFFERING_LEVEL / CITY_REPUTATION_LEVEL）
  - `param/param2`

`OpenStateData.onLoad()` 会把自己加入 `GameData.openStateList`，供 ProgressManager 遍历。

### 56.2.2 玩家侧状态：`Player.openStates: Map<openStateId, value>`

ProgressManager 的 `getOpenState(openState)`：

- `return player.openStates.getOrDefault(openState, 0)`

内部 setOpenState 的额外副作用（非常关键）：

- 若值变化：
  - 写入 map
  - `questManager.queueEvent(QUEST_COND_OPEN_STATE_EQUAL, openState, value)`
  - 可选发送 `PacketOpenStateChangeNotify(openState, value)`

所以 OpenState 不只是 UI 开关，也能作为任务条件触发器。

### 56.2.3 条件判定：`areConditionsMet(OpenStateData)`

当前实现覆盖：

- PLAYER_LEVEL：`player.level >= param`
- QUEST：子任务必须 finished
- PARENT_QUEST：主任务必须 finished
- OFFERING_LEVEL / CITY_REPUTATION_LEVEL：TODO（未实现）

这就是“内容可配置边界”的典型例子：表里有，但引擎条件分支没做，就等于不可用。

### 56.2.4 自动解锁：`tryUnlockOpenStates(sendNotify)`

它会扫描所有未解锁的 open states（value==0），并满足以下条件才会自动解锁：

1. `!state.allowClientOpen`
2. `areConditionsMet(state)`
3. 不在 `BLACKLIST_OPEN_STATES`
4. 不在 `IGNORED_OPEN_STATES`

然后 set 为 1（可选发包）。

这套逻辑让“服务器侧条件解锁”成为可能，但也引入了两个现实妥协：

- `BLACKLIST_OPEN_STATES`（例如 48）用于临时屏蔽一些“引擎还没支持”的状态
- `DEFAULT_OPEN_STATES` 会把某些“官方应当后期解锁”的系统提前开（见源码注释，属于兼容策略）

### 56.2.5 客户端主动设置：`setOpenStateFromClient`

它只允许：

- 该 openState 存在
- `allowClientOpen==true`
- 且条件已满足

否则回 `RET_FAIL`。

这属于“客户端驱动的 UI 行为开关”，常见于教学/引导类 openState。

---

## 56.3 地图解锁：ScenePoint / Area 与任务、脚本联动

### 56.3.1 自动注入“解锁七天神像”任务（303）

`onPlayerLogin()` 里会调用 `addStatueQuestsOnLogin()`：

- 确保主线 303 存在（若没有则 add 30302）
- 把未完成的子任务设为 active（通过 addQuest）

这属于“用任务系统来驱动地图解锁引导”的典型策略。

### 56.3.2 解锁传送点/神像：`unlockTransPoint(sceneId, pointId, isStatue)`

关键步骤：

1. 校验 ScenePointEntry 存在且未解锁
2. 写入 `player.unlockedScenePoints(sceneId).add(pointId)`
3. 给奖励：
   - `Primogem(201) * 5`
   - `AdventureExp(102) * (isStatue ? 50 : 10)`
4. 触发任务事件：
   - `questManager.queueEvent(QUEST_CONTENT_UNLOCK_TRANS_POINT, sceneId, pointId)`
5. 触发 Lua 事件：
   - `scene.scriptManager.callEvent(new ScriptArgs(0, EVENT_UNLOCK_TRANS_POINT, sceneId, pointId))`
6. 发包：
   - `PacketScenePointUnlockNotify(sceneId, pointId)`

从“玩法编排层”角度，这是一条非常关键的“数据驱动链路”：

> 点位解锁 → 同时驱动任务条件与 Lua 事件  
> （你可以在 Lua group 脚本里监听 `EVENT_UNLOCK_TRANS_POINT` 做额外编排）

### 56.3.3 解锁地图区域：`unlockSceneArea(sceneId, areaId)`

当前逻辑较简单：

- 写入 `player.unlockedSceneAreas(sceneId).add(areaId)`
- 发包 `PacketSceneAreaUnlockNotify(sceneId, areaId)`

它没有附带奖励/任务事件（如果你需要类似“解锁区域给奖励”，要在引擎或脚本层补齐）。

---

## 56.4 SceneTag：场景分支标签（可用于内容显隐/路线分歧）

ProgressManager 提供：

- `addSceneTag(sceneId, sceneTagId)`：写入 `player.sceneTags[sceneId]` 并发 `PacketPlayerWorldSceneInfoListNotify`
- `delSceneTag(...)`
- `checkSceneTag(...)`

SceneTag 在官方常用于：

- 地图分区显隐
- 剧情推进后的“世界状态切换”
- 特定机关/区域是否可交互

本仓库提供的是“玩家侧标签集合 + 同步”，具体如何影响内容，还要结合脚本/资源对 SceneTag 的引用方式（见 24 章）。

---

## 56.5 PlayerProgress：更通用的“历史与计数存档”（任务 Exec 的落点）

文件：`Grasscutter/src/main/java/emu/grasscutter/game/player/PlayerProgress.java`

它持久化了更广义的进度：

- `itemHistory`：某 itemId 获得次数累计
- `completedDungeons`：一次性副本完成集合
- `questProgressCountMap`：`EXEC_ADD_QUEST_PROGRESS` 的累计值（供 CONTENT_ADD_QUEST_PROGRESS 使用）
- `itemGivings/bargains`：与剧情/交易相关的记录（后续可扩展）

ProgressManager 提供了两个常用桥接方法：

- `addQuestProgress(id, count)`：
  - 更新 `questProgressCountMap`
  - `queueEvent(QUEST_CONTENT_ADD_QUEST_PROGRESS, id, newCount)`
- `addItemObtainedHistory(id, count)`：
  - 更新 `itemHistory`
  - `queueEvent(QUEST_COND_HISTORY_GOT_ANY_ITEM, id, newCount)`

这让任务系统可以把某些“跨任务共享的计数器”放在 PlayerProgress 里，而不是散落在每个 Quest 实例中。

---

## 56.6 引擎边界与“只改数据”的判断标准

### 56.6.1 只改数据/脚本通常能搞定的

- 用 OpenState（已实现的 condType）做功能开关/任务条件
- 用 `unlockTransPoint` 驱动“解锁点位→触发任务/Lua”
- 用 SceneTag 做内容分支（前提是资源/脚本确实引用这些 tag）

### 56.6.2 需要下潜引擎的典型情况

- 想新增/完善 OpenState 条件类型（OFFERING_LEVEL / CITY_REPUTATION_LEVEL 等）
- 想让 SceneArea 解锁也触发奖励/任务/Lua（当前只有发包）
- 想更严格/更真实地复刻官方的“默认开放/黑名单/忽略列表”策略  
  （现在很多是为兼容/省事做的默认放开）

---

## 56.7 小结

- `PlayerProgressManager` 是“解锁与进度驱动”的枢纽：OpenState/Point/Area/SceneTag/PlayerProgress 在这里被串成可触发任务与脚本的链路。
- 对玩法编排层而言，最有价值的是：`unlockTransPoint` 同时触发任务事件与 Lua 事件，是一个非常干净的“数据驱动钩子”。
- 目前的主要边界在 OpenState 条件覆盖度、默认开放策略（黑名单/忽略）、以及部分解锁缺少奖励/事件联动。

---

## Revision Notes

- 2026-01-31：首次撰写本专题；梳理 ProgressManager 的 OpenState 条件系统、点位/区域解锁与任务/Lua 事件联动、SceneTag 同步与 PlayerProgress 作为跨任务计数存档的落点。

