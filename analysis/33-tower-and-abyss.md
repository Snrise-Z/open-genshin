# 33 专题：Tower（深境螺旋）管线：选队 → 进副本 → Challenge 星级 → 结算与记录

本文把 Tower（常见理解为“深境螺旋/爬塔”）当成一个“**计划表驱动的多层副本系统**”来拆解：  
它本质上是 **Dungeon + Challenge + 选队/换队 + 星级条件 + 赛季/日程（Schedule）** 的组合。

与其他章节关系：

- `analysis/18-dungeon-pipeline.md`：Tower 关卡实际是 dungeon（handoffDungeon、settle listener）。
- `analysis/17-challenge-gallery-sceneplay.md`：星级计算依赖 Challenge 的时间/血量等统计。
- `analysis/30-multiplayer-and-ownership-boundaries.md`：Tower 在实现上大量以 `scene.getPlayers().get(0)` 作为权威玩家。

---

## 33.1 抽象模型：Tower = 赛季（Schedule）+ Floor + Level（1~3）+ 星级记录

用中性 ARPG 心智模型描述：

- **Schedule（赛季/期次）**：决定当前开放哪些楼层（floors）
- **Floor（楼层）**：一个楼层由 1~3 个 Level（关卡段）组成
- **Level（关卡段）**：对应一个 dungeonId（进入副本），由 challenge 决定胜负与星级
- **Record（记录）**：玩家在每个 floor 的每个 level 的星级最好成绩

你可以把它当成一种“多段挑战副本”的模板，未来移植到你自己的 ARPG 项目里也很自然。

---

## 33.2 数据依赖清单（Tower 的“内容”主要落在这些表/文件）

### 33.2.1 赛季与楼层编排

- `data/TowerSchedule.json`
  - 当前仓库用它指定“当前 scheduleId”，以及起止时间
- `resources/ExcelBinOutput/TowerScheduleExcelConfigData.json`
  - scheduleId → entrance floors + schedule floors 列表
- `resources/ExcelBinOutput/TowerFloorExcelConfigData.json`
  - floorId → levelGroupId（决定这一楼的关卡段属于哪个 level group）

### 33.2.2 每段关卡的 dungeon 与星级条件

- `resources/ExcelBinOutput/TowerLevelExcelConfigData.json`
  - levelGroupId + levelIndex → TowerLevelData（关键字段包括 `dungeonId`、`monsterLevel`、星级条件）

最终玩法脚本落在 dungeon 自己的场景/group 脚本里（见 `analysis/18`、`analysis/12`）。

---

## 33.3 引擎侧的两大核心类：`TowerSystem` 与 `TowerManager`

### 33.3.1 `TowerSystem`：全服的“赛季调度器”

文件：`Grasscutter/src/main/java/emu/grasscutter/game/tower/TowerSystem.java`

- 启动时读取 `data/TowerSchedule.json`
- 用 `scheduleId` 去查 `TowerScheduleExcelConfigData`
- 提供：
  - `getAllFloors()`：入口 floors + 赛季 floors
  - `getNextFloorId(floorId)`：楼层推进关系

你可以把它理解成：**一个数据驱动的“关卡列表路由器”**。

### 33.3.2 `TowerManager`：每玩家的“当前进度与星级记录”

文件：`Grasscutter/src/main/java/emu/grasscutter/game/tower/TowerManager.java`

它维护：

- `TowerData`（挂在 Player 上的持久数据，记录 currentFloorId/currentLevel/currentLevelId/recordMap 等）
- `inProgress/currentTimeLimit/currentPossibleStars`（运行时状态）

核心动作：

1. **选队（teamSelect）**
   - 设置当前 floorId、currentLevelId、currentLevel（从 Excel 反推第一段）
   - 记录 entryScene（进塔前所在场景，保证能正确退出）
   - 调 `TeamManager.setupTemporaryTeam(towerTeams)` 保存镜像队伍
2. **进关（enterLevel）**
   - 取 `TowerLevelData.dungeonId`
   - `DungeonSystem.handoffDungeon(player, dungeonId, towerDungeonSettleListener)`
   - 强制使用临时队伍（`useTemporaryTeam(0)`）
   - 下发进入/星级条件通知
3. **星级实时检查（onTick）**
   - 若有 challenge 在跑，会计算当前星级并在失败时通知客户端
4. **结算（通过 settle listener）**
   - 见下节 33.4

---

## 33.4 Tower 的结算点：`TowerDungeonSettleListener`

文件：`Grasscutter/src/main/java/emu/grasscutter/game/dungeons/TowerDungeonSettleListener.java`

它在 dungeon 结束时：

1. 做一个特殊判断：如果某些 group variables 中存在 `stage==1`，则直接 return（不结算）  
   - 这对应 Tower 的“镜像/分段”脚本常见写法：某些中间段不立即结算
2. 从 `scene.getPlayers().get(0)` 取到 TowerManager（再次体现“权威玩家”）
3. 计算 stars：`towerManager.getCurLevelStars()`
4. 若通关：
   - `notifyCurLevelRecordChangeWhenDone(stars)` 更新记录
   - 广播 `PacketTowerFloorRecordChangeNotify`
5. 构造 dungeon result：
   - 通关用 `TowerResult`
   - 失败用 `BaseDungeonResult`
6. 广播 `PacketDungeonSettleNotify`

> 结论：Tower 的“结算与记录”是引擎侧固定逻辑；你在数据层主要能改的是“每段用哪个 dungeon、星级条件是什么、奖励是什么”。

---

## 33.5 星级条件是怎么计算的？（TowerLevelData → Challenge 统计）

`TowerManager.getCurLevelStars()` 会从 `TowerLevelData` 读取每颗星的条件类型，目前主要支持：

- `TOWER_COND_CHALLENGE_LEFT_TIME_MORE_THAN`：剩余时间 ≥ 阈值
- `TOWER_COND_LEFT_HP_GREATER_THAN`：守护目标血量 ≥ 阈值

计算依赖：

- `challenge.getTimeLimit()` 与 `scene.getSceneTimeSeconds()`
- `challenge.getGuardEntityHpPercent()`

并且在 ScriptLib 的 `ActiveChallenge(...)` 中，对 Tower 做了一个特殊兼容：

- Tower 脚本可能在镜像关卡里调用 `ActiveChallenge` 两次
- 第二次传入的时间不是“time limit”，而是上一段消耗时间
- 引擎用 `towerManager.getCurrentTimeLimit() - timeLimitOrGroupId` 做修正

文件入口：`Grasscutter/src/main/java/emu/grasscutter/scripts/ScriptLib.java` 的 `ActiveChallenge(...)`。

---

## 33.6 Tower 脚本侧常见接口：`TowerMirrorTeamSetUp`

`ScriptLib.TowerMirrorTeamSetUp(team, ...)` 的实现会：

- `unloadCurrentMonsterTide()`（避免怪潮残留）
- 调 `TowerManager.mirrorTeamSetUp(team - 1)` 切换临时队伍

意义：

- 你在 dungeon 的 group Lua 脚本里可以在“分段/镜像”节点切队伍
- 这也是 Tower 玩法“多段挑战”的关键体验点之一

---

## 33.7 只改数据/脚本能做哪些“爬塔变体”？

### 33.7.1 只改数据：换一套楼层列表与 dungeon 组合

1. 改 `data/TowerSchedule.json` 的 `scheduleId`
2. 在 `TowerScheduleExcelConfigData.json` 配该 scheduleId 的 floor 列表
3. 在 `TowerFloorExcelConfigData.json` 配 floorId → levelGroupId
4. 在 `TowerLevelExcelConfigData.json` 配 levelGroupId + levelIndex → dungeonId/条件

你就能做出“自定义赛季/自定义楼层/自定义关卡段”。

### 33.7.2 只改脚本：改每个 dungeon 内的玩法（刷怪/机关/胜负条件）

Tower 的每段本质就是 dungeon：

- 你可以在 dungeon 的场景 group Lua 里写：
  - `ActiveChallenge`
  - 怪潮、波次、机关、计时
  - `stage` 变量控制“是否中段结算”

这部分完全落在“玩法编排层 DSL”里（见 `analysis/12`、`analysis/22`、`analysis/17`）。

---

## 33.8 哪些需求一看就要下潜引擎？

典型包括：

- 更复杂的星级条件（例如“无角色倒下”“触发某种反应次数”）
- 多人爬塔/协作爬塔（当前实现强依赖单一权威玩家）
- 更完整的赛季刷新/重置逻辑与奖励结算（更多是系统机制）

---

## 33.9 小结

- Tower 是“Schedule 数据驱动的多段 dungeon 系统”，用 `TowerManager` 维护玩家记录，用 settle listener 做结算。
- 你在“只改数据/脚本”时的主战场是：
  - Excel：楼层/关卡段/dungeonId/星级条件
  - Lua：每段 dungeon 的玩法编排（挑战、刷怪、机关、阶段）
- 多人权威、星级条件扩展、赛季机制属于更明显的引擎边界。

---

## Revision Notes

- 2026-01-31：首次撰写本专题；梳理 Tower 的 schedule/level 数据依赖与 `TowerManager + settle listener + ScriptLib` 的真实运行链路。

