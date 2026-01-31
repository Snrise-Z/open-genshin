# 18 - Dungeon（副本）全链路：入口点 → 场景切换 → 通关条件 → 结算/奖励 → 退出/重开

> 本篇专题把 Dungeon 当成一个“关卡引擎容器”来拆解：它不是单纯的传送点，而是一条可数据驱动的流水线（进入、规则、通关、结算、回收）。
>
> 你会在这里看到三条主线如何耦合：
> - **Scene**：副本本质上是一个特殊 Scene（`SCENE_DUNGEON`）
> - **Challenge**：很多副本通关条件本质是“某个挑战成功”（见 `analysis/17-challenge-gallery-sceneplay.md`）
> - **Quest**：副本进入/失败/完成会向任务系统投递事件（见 `analysis/10-quests-deep-dive.md`）
>
> 关联阅读：
> - `analysis/12-scene-and-group-lifecycle.md`：Scene/Group 生命周期（副本内加载/卸载 group 的机制一致）
> - `analysis/16-reward-drop-item.md`：掉落/奖励管线（副本奖励 statue 与掉落表链路）

---

## 1. 核心对象：把 Dungeon 看成“数据驱动的场景状态机”

在本仓库里，Dungeon 主要由这些对象组成（按层次）：

### 1.1 数据层（你能改的）

- `resources/ExcelBinOutput/DungeonExcelConfigData.json` → `DungeonData`
- `resources/ExcelBinOutput/DungeonPassExcelConfigData.json` → `DungeonPassConfigData`
- `resources/ExcelBinOutput/DungeonEntryExcelConfigData.json` → `DungeonEntryData`
- `resources/ExcelBinOutput/DailyDungeonConfigData.json` → `DailyDungeonData`（每日随机副本池）
- `resources/BinOutput/Scene/Point/scene*_point.json` → `PointData`（入口点/复活点/传送点都在这里）

### 1.2 运行时（引擎层，Lua 只能“触发/监听”）

- `DungeonSystem`：处理进入/退出/重开请求
- `DungeonManager`：副本内“通关条件追踪 + 结算/奖励 + 复活点”
- `Scene(SceneType=SCENE_DUNGEON)`：副本场景本体，承载 group 脚本、实体、计时、挑战

你可以把它抽象成：

```
入口点(PointData.dungeonIds) + DungeonData(sceneId, passCond, reward)
  -> 进入副本(切 Scene)
  -> DungeonManager.startDungeon()（QuestEnter + TrialTeam）
  -> 事件驱动的通关条件(passCond)
  -> 结算(EVENT_DUNGEON_SETTLE) + 奖励(statue/drop)
  -> 退出/重开(回到 prevScene/prevPoint)
```

---

## 2. 数据层怎么拼起来：DungeonId 从哪来、指向哪、驱动什么？

### 2.1 `DungeonExcelConfigData.json`（DungeonData）：副本的“主配置”

对应类：`Grasscutter/src/main/java/emu/grasscutter/data/excels/dungeon/DungeonData.java`

**对脚本/玩法最关键的字段：**

- `id`：dungeonId（全链路的主键）
- `sceneId`：副本所在场景（进入后会切到这个 scene）
- `type / playType`：副本类型（影响 TrialTeam、战令统计等）
- `passCond`：通关条件配置 id（指向 `DungeonPassExcelConfigData`）
- `passJumpDungeon`：通关后自动跳转到下一个 dungeon（连战/塔）
- `showLevel / limitLevel / reviveMaxCount`：显示/限制与复活相关
- `passRewardPreviewID`：通关预览奖励（用于 fallback）
- `statueCostID/statueCostCount/statueDrop`：领取“副本奖励 statue”时的消耗与掉落（见第 6 节）

运行时补充：
- `DungeonData.onLoad()` 会把 `passRewardPreviewID` 解析成 `rewardPreviewData`（服务端用于 fallback 掉落/显示）。

### 2.2 `DungeonPassExcelConfigData.json`（DungeonPassConfigData）：通关条件（非常重要）

对应类：`Grasscutter/src/main/java/emu/grasscutter/data/excels/dungeon/DungeonPassConfigData.java`

结构要点：
- `id`
- `logicType`：条件组合逻辑（AND/OR/...），可能为空
- `conds[]`：每个元素是 `{condType, param[]}`，但原始表会混入一些 `condType=null` 的占位项；`onLoad()` 会过滤掉无效项

**本仓库一个非常关键的实现细节：**
- `LogicType.calculate(logicType, finishedConditions)` 中，如果 `logicType==null`，只会看 `progress[0]`（即“第一条条件”）。  
  这意味着：你改表时如果没填 `logicType`，在服务端语义上很可能退化成“只要第一个 cond 满足就通关”。

### 2.3 `scene*_point.json`（PointData）：入口点 / 复活点 / 回城点

加载逻辑在 `Grasscutter/src/main/java/emu/grasscutter/data/ResourceLoader.java` 的 `loadScenePoints()`。

`PointData`（`Grasscutter/src/main/java/emu/grasscutter/data/common/PointData.java`）里和 Dungeon 直接相关的字段：

- `id`：pointId
- `$type`：点类型（常见：DungeonEntry/WayPoint/TransPoint 等）
- `dungeonIds[]`：这个点可进入的 dungeonId 列表
- `dungeonRandomList[]`：每日随机池（会被 `updateDailyDungeon()` 展开成实际 `dungeonIds[]`）
- `tranPos`：从入口点传送后的落点（用于退回/复活/返回）
- `size`：交互/触发范围（客户端用途更多）

注意：服务器在 `PacketDungeonEntryInfoRsp` 里只回 `pointId + dungeonId 列表`，客户端用自己的表显示 UI。

---

## 3. 进入副本：从客户端请求到 DungeonManager.startDungeon()

### 3.1 请求路径：`PlayerEnterDungeonReq`

入口 handler：`Grasscutter/src/main/java/emu/grasscutter/server/packet/recv/HandlerPlayerEnterDungeonReq.java`

它直接调用：

- `DungeonSystem.enterDungeon(player, pointId, dungeonId, savePrevious=true)`

### 3.2 `DungeonSystem.enterDungeon`：切场景 + 挂 DungeonManager

见：`Grasscutter/src/main/java/emu/grasscutter/game/dungeons/DungeonSystem.java`

关键动作：
1. `dungeonId` → `GameData.getDungeonDataMap().get(dungeonId)`（缺数据就失败）
2. 取 `DungeonData.sceneId` 并 `world.transferPlayerToScene(player, sceneId, dungeonData)`
3. 在新 scene 上 `scene.setDungeonManager(new DungeonManager(scene, dungeonData))`
4. 记录 `prevScene`/`prevScenePoint`（用于退出返回）

> 这里的“进入”只是把 Scene/DungeonManager 架起来；真正的“副本开始（QuestEnter/TrialTeam）”发生在下一步。

### 3.3 副本开始时机：`PostEnterSceneReq` 触发 `DungeonManager.startDungeon()`

见：`Grasscutter/src/main/java/emu/grasscutter/server/packet/recv/HandlerPostEnterSceneReq.java`

当场景类型是 `SCENE_DUNGEON` 时：
- `scene.getDungeonManager().startDungeon()`

`DungeonManager.startDungeon()`（`Grasscutter/src/main/java/emu/grasscutter/game/dungeons/DungeonManager.java`）会：

- 记录 `startSceneTime`
- 对每个玩家：
  - `QuestManager.queueEvent(QUEST_CONTENT_ENTER_DUNGEON, dungeonId)`
  - `applyTrialTeam(p)`（活动试用角色副本会临时塞入试用角色）

---

## 4. 通关条件是怎么被“事件驱动”满足的？

### 4.1 DungeonManager 的条件追踪模型

`DungeonManager` 里有：
- `passConfigData`：来自 `DungeonPassConfigData`
- `finishedConditions[]`：与 `conds` 一一对应的 0/1 数组

当外部触发 `DungeonManager.triggerEvent(conditionType, params...)` 时：
1. 遍历 `passConfigData.conds`
2. 找 `cond.condType == conditionType`
3. 调 `DungeonSystem.triggerCondition(cond, params)` → 对应的 `Condition*` handler 判断是否满足
4. 满足则把对应 `finishedConditions[i]=1`
5. `LogicType.calculate(...)` 判断整体是否通关；通关则 `finishDungeon()`

### 4.2 谁在触发 `triggerEvent`？

主要来源（本仓库已实现）：

1. **怪物死亡 → 多种通关条件**
   - `EntityMonster` 死亡时触发：
     - `DUNGEON_COND_KILL_GROUP_MONSTER`（param0=groupId）
     - `DUNGEON_COND_KILL_TYPE_MONSTER`（param0=monsterType）
     - `DUNGEON_COND_KILL_MONSTER`（param0=monsterId）
   - `Scene.killEntity` 在任何实体死亡时递增 `killedMonsterCount` 并触发：
     - `DUNGEON_COND_KILL_MONSTER_COUNT`（param0=累计死亡数）

2. **Quest 完成**
   - `GameQuest.finish()` 会触发：
     - `DUNGEON_COND_FINISH_QUEST`（param0=subQuestId）

3. **Challenge 成功**
   - `WorldChallenge.done()` 会触发：
     - `DUNGEON_COND_FINISH_CHALLENGE`（param0=challengeId, param1=challengeIndex）

### 4.3 非常重要的“语义差异/简化”：某些条件是“触发即满足”

本仓库的部分 `pass_condition` 实现是**简化版**：

- `DUNGEON_COND_KILL_GROUP_MONSTER`：只判断 `params[0] == cond.param[0]`  
  ⇒ **杀掉这个 group 的任意一只怪就算满足**（并非“清空该 group 的所有怪”）。

这会直接影响你“只改数据就做副本”的体验：  
如果你希望“杀光一波才通关”，在当前实现中更稳的是：
- 用 `DUNGEON_COND_KILL_MONSTER_COUNT`（杀怪总数达到阈值），或者
- 用 `Challenge`（让挑战系统负责计数/限时），然后用 `DUNGEON_COND_FINISH_CHALLENGE` 通关。

---

## 5. 结算：成功/失败/退出分别发生什么？Lua 能在哪插入逻辑？

### 5.1 三种结束方式

在 `DungeonManager` 中对应：

- `finishDungeon()`：通关成功
- `failDungeon()`：失败
- `quitDungeon()`：主动退出

它们都会调用：
- `notifyEndDungeon(successfully)`
- `endDungeon(endReason)`

### 5.2 `EVENT_DUNGEON_SETTLE`：Lua 最重要的“结算回调”

`DungeonManager.notifyEndDungeon(successfully)` 会调用：

- `scene.scriptManager.callEvent(new ScriptArgs(0, EVENT_DUNGEON_SETTLE, successfully?1:0))`

要点：
- `group_id=0`：意味着**这是一个“全局事件”**，场景内所有 group 里注册了 `EVENT_DUNGEON_SETTLE` 的 trigger 都可能收到。
- `evt.param1`：1=成功，0=失败/退出（脚本里常用 `if 1 ~= evt.param1 then return false end`）

典型用法可以参考：
- `resources/Scripts/Scene/40400/scene40400_group240400009.lua`：成功时点亮 statue、解锁其他 group 的机关；领奖后再改回状态。

### 5.3 失败的 Lua 主动触发：`ScriptLib.CauseDungeonFail()`

`ScriptLib.CauseDungeonFail()` 已实现，会直接 `dungeonManager.failDungeon()`。

对比：
- `CauseDungeonSuccess` 在本仓库是 `TODO`  
  ⇒ 如果你想“脚本决定成功结算”，更推荐走 **passCond** 或 **finish challenge** 这条数据驱动路径。

### 5.4 额外：战令、进度与自动跳转

结算时还会发生：
- 成功：`PlayerProgress.markDungeonAsComplete(dungeonId)`（用于解锁/记录）
- 失败：`QuestManager.queueEvent(QUEST_CONTENT_FAIL_DUNGEON, dungeonId)`
- 若 `passJumpDungeon != 0`：通关后自动进入下一个 dungeon（连战式体验）

---

## 6. 奖励：副本奖励 statue / 消耗体力 / 掉落系统

### 6.1 “领奖点”如何触发掉落？

副本里常见一种 gadget：**RewardStatue**（或类似领奖交互物件）。

在 `DungeonManager.getStatueDrops(player, useCondensed, groupId)` 中：
1. 必须已通关成功
2. 检查是否已经领过（`rewardedPlayers`）
3. 消耗（树脂/浓缩树脂）检查
4. 调用 `DropSystem.handleDungeonRewardDrop(dungeonData.statueDrop, useCondensed)`  
   - 若失败会 fallback 到 `rewardPreviewData`
5. 发包 `PacketGadgetAutoPickDropInfoNotify` 让客户端展示拾取结果
6. 发 Lua 事件 `EVENT_DUNGEON_REWARD_GET`（groupId 由调用点传入）

### 6.2 Lua 的奖励后处理：`EVENT_DUNGEON_REWARD_GET`

很多副本脚本会在领奖后做 UI/机关状态切换（例如把 statue 改成不可领奖状态）。

这类脚本属于“玩法编排层”的典型职责：  
**奖励发放由引擎完成，领奖后的关卡状态/机关演出由 Lua 完成。**

（更深的掉落表链路见 `analysis/16-reward-drop-item.md`）

---

## 7. 退出与重开：如何回到原世界、如何清理临时队伍

### 7.1 主动退出：`PlayerQuitDungeonReq`

handler：`Grasscutter/src/main/java/emu/grasscutter/server/packet/recv/HandlerPlayerQuitDungeonReq.java`

直接调用：
- `DungeonSystem.exitDungeon(player)`

### 7.2 `exitDungeon`：回到 `prevScene` + `prevScenePoint.tranPos`

`DungeonSystem.exitDungeon` 做的关键事：

- 计算 `prevScene`（默认回到 3）
- 找到 `prevScenePoint` 对应的 `ScenePointEntry`，取 `tranPos` 作为回城位置
- 若副本未成功，调用 `dungeonManager.quitDungeon()`
- 清理临时队伍（trial team/临时队伍）
- 延迟 200ms 传送回世界（避免“连点传送导致双重传送”）

### 7.3 重开：`DungeonRestartReq`

handler：`Grasscutter/src/main/java/emu/grasscutter/server/packet/recv/HandlerDungeonRestartReq.java`

最终走 `DungeonSystem.restartDungeon(player)`：
- 会销毁并重新创建 scene，从而“重置脚本状态”（这点对玩法编排非常关键）

---

## 8. 面向“只改脚本/数据”的落地建议：如何做一个最小可用自制副本？

在当前仓库能力约束下（`CauseDungeonSuccess` 未实现、部分 pass_cond 语义简化），我推荐这样做：

### 8.1 选择一个可靠的通关驱动方式

优先级建议：

1. **Challenge 驱动通关**（推荐）
   - 副本脚本里 `ActiveChallenge(...)`
   - passCond 选 `DUNGEON_COND_FINISH_CHALLENGE`
   - 好处：计时/计数由 Challenge 负责，Lua 只编排阶段与收尾

2. **KillMonsterCount 驱动通关**
   - passCond 用 `DUNGEON_COND_KILL_MONSTER_COUNT`（达到阈值）
   - 注意：它是全局累计击杀（由 `Scene.killEntity` 递增），不是“某 group 清空”

不建议（除非你接受简化语义）：
- `DUNGEON_COND_KILL_GROUP_MONSTER`（当前实现是“杀到任意一只就算满足”）

### 8.2 数据与脚本最小集合

- 新 dungeonId：追加到 `DungeonExcelConfigData.json`（至少要有 `id/sceneId/passCond`）
- 通关条件：在 `DungeonPassExcelConfigData.json` 加一条 passCond（并确保 `logicType` 与 `conds` 符合你的期望）
- 场景与脚本：确保 `sceneId` 对应的 SceneMeta/Group 脚本存在且能刷出你的玩法实体
- 入口点：在某个世界 scene 的 `scene*_point.json` 增加一个 `DungeonEntry` 点，`dungeonIds` 包含你的 dungeonId

### 8.3 Lua 编排推荐用的事件点

- `EVENT_GROUP_LOAD`：初始化
- `EVENT_ENTER_REGION`：开始挑战/开始刷怪
- `EVENT_CHALLENGE_SUCCESS/FAIL`：阶段切换/收尾
- `EVENT_DUNGEON_SETTLE`：成功/失败后的世界状态改动（开门、解锁机关、记录变量等）
- `EVENT_DUNGEON_REWARD_GET`：领奖后的机关状态切换

---

## 9. 常见坑与定位方式

1. **“我改了 DungeonPass 但通关条件怪怪的”**
   - 优先检查 `logicType` 是否为空（为空时只看第一条 cond）
   - 再检查 cond 的 handler 是否是简化实现（例如 kill group monster）

2. **“脚本里调用 StartGallery/ScenePlay 相关 API 在副本里没效果”**
   - 这属于引擎边界（Gallery/ScenePlay 大多未实现），不要把问题归咎于 dungeon。

3. **“进入副本后没有触发 QuestEnter/TrialTeam”**
   - 确认客户端是否发了 `PostEnterSceneReq`（服务端在该 handler 里调用 `startDungeon()`）

4. **“退出副本回不到期望位置”**
   - `prevScenePoint` 的 `tranPos` 是否配置正确（在 `scene*_point.json`）

