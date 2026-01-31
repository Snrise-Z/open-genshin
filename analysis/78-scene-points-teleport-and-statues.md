# 78 玩家子系统专题：传送锚点 / 七天神像 / 秘境入口（ScenePoint 与供奉）

本文从“玩家地图与探索”视角，拆解 Grasscutter 的 **场景点位（ScenePoint）** 系统：传送锚点/秘境入口/部分地图交互点如何由 `BinOutput/Scene/Point` 驱动，传送点解锁如何进入任务与 Lua 事件链路，以及七天神像供奉（神瞳→体力上限/奖励）在服务端如何实现。

与其他章节关系：

- 地图解锁/OpenState：`analysis/24-openstate-and-progress-gating.md`
- Dungeon/秘境：`analysis/18-dungeon-pipeline.md`
- 任务与解锁点：`analysis/10-quests-deep-dive.md`、`analysis/27-quest-conditions-and-execs-matrix.md`

---

## 78.1 玩家视角：你在地图上点的“锚点/神像/秘境门”是什么？

从玩家侧看，这些点位有共同点：

- 它们是“地图上的可交互点”，可以：
  - 传送（锚点/神像）
  - 进入副本（秘境入口）
  - 触发某些玩法（例如塔入口、个人场景跳转等）
- 许多点位有“解锁状态”（靠靠近、任务、剧情等）
- 解锁会给奖励（原石/冒险阅历等），并可能触发任务条件

在 Grasscutter 的数据层，这类点位集中在 **BinOutput ScenePoint 文件**，而不是 Lua group 脚本。

---

## 78.2 数据层：ScenePoint 文件结构与 PointData

### 78.2.1 ScenePoint 文件位置与命名

目录：`resources/BinOutput/Scene/Point/`

命名格式：`scene<sceneId>_point.json`

加载器会用正则 `scene([0-9]+)_point\\.json` 扫描并解析。

### 78.2.2 根结构：`{ "points": { pointId: PointData, ... } }`

典型文件（如大世界 scene3）：根是一个 `points` map。

每个点位（PointData）常见字段：

- `$type`：点位类型（客户端/服务端都用它做分类）
  - 常见：`SceneTransPoint`、`VirtualTransPoint`、`DungeonEntry`、`DungeonExit`、`SceneBuildingPoint`…
- `pos/rot`：点位展示位置
- `tranPos/tranRot`：传送落点与朝向（传送锚点/秘境入口常用）
- `areaId`：属于哪个区域（用于城市/神像供奉联动）
- `gadgetId`：客户端交互外观（很关键：选错可能 UI 不显示）
- `dungeonIds[]` / `dungeonRandomList[]`：若是秘境入口，指向 dungeonId
- `groupIDs[]`：与某些玩法 group 关联（部分类型会用）
- `forbidSimpleUnlock/unlocked`：影响“地图一键解锁”等行为（见 78.7）

> 作者提示：ScenePoint 是“地图与世界结构”的核心数据之一；它不是脚本 DSL，但它会触发脚本事件与任务内容条件（见 78.4）。

---

## 78.3 运行时：ScenePoint 的加载与查询

加载发生在启动期：`ResourceLoader.loadScenePoints()`

它会：

1. 读取每个 `scene*_point.json`
2. 遍历 `points`：
   - 构造 `ScenePointEntry(sceneId, pointData)`
   - `pointData.id = pointId`
   - 写入 `GameData.scenePointEntryMap[(sceneId<<16)+pointId]`
   - 记录 `GameData.scenePointsPerScene[sceneId] = [pointId...]`
3. 对点位调用 `pointData.updateDailyDungeon()`（用于每日秘境随机列表）

后续查询统一走：

- `GameData.getScenePointEntryById(sceneId, pointId)`

---

## 78.4 解锁传送点：奖励、任务条件与 Lua 事件

### 78.4.1 玩家解锁状态存在哪里？

玩家对象里有：

- `Player.unlockedScenePoints: Map<sceneId, Set<pointId>>`
- `Player.unlockedSceneAreas: Map<sceneId, Set<areaId>>`

### 78.4.2 解锁流程：`PlayerProgressManager.unlockTransPoint(...)`

解锁传送点做了几件事（作者视角很重要）：

1. 校验点位存在且未解锁：`ScenePointEntry != null && not contains(pointId)`
2. 写入 `unlockedScenePoints`
3. 发放奖励（当前实现硬编码）：
   - `addItem(201, 5)`（原石）
   - `addItem(102, isStatue?50:10)`（冒险阅历/经验类道具）
4. 触发任务事件：
   - `questManager.queueEvent(QUEST_CONTENT_UNLOCK_TRANS_POINT, sceneId, pointId)`
5. 触发 Lua 事件：
   - `scene.scriptManager.callEvent(EVENT_UNLOCK_TRANS_POINT, sceneId, pointId)`
6. 下发点位解锁通知：`PacketScenePointUnlockNotify(sceneId, pointId)`

这意味着：你可以用 Lua 在 `EVENT_UNLOCK_TRANS_POINT` 上做“解锁联动玩法”（例如弹提示、刷怪、触发支线）。

### 78.4.3 任务如何解锁点位：`QUEST_EXEC_UNLOCK_POINT`

QuestExec：`QUEST_EXEC_UNLOCK_POINT` 会调用 `unlockTransPoint(sceneId, pointId, isStatue)`

但这里有一个现实边界：

- `isStatue` 当前是按 mainQuestId 硬编码判断（例如 303/352）
- 这意味着“解锁神像 vs 解锁普通锚点”的奖励差异，暂时不是纯数据驱动

如果你要做大量自定义“神像类点位”，可能需要改引擎（或接受奖励不区分）。

---

## 78.5 七天神像供奉：神瞳 → 城市等级 → 体力上限/奖励

对应管理器：`SotSManager`（Statue of The Seven）

### 78.5.1 数据：`StatuePromoteExcelConfigData.json`

文件：`resources/ExcelBinOutput/StatuePromoteExcelConfigData.json`（`StatuePromoteData`）

关键字段：

- `cityId`：属于哪座城市/区域
- `level`：供奉等级
- `costItems[]`：每级需要的神瞳数量（实现里主要用第 0 个）
- `stamina`：该级增加的体力上限（服务端用 `stamina * 100` 写入属性）
- `rewardIdList[]`：升到该级给哪些奖励（RewardExcel）

key 规则：`(cityId << 8) + level`

### 78.5.2 运行时流程：`SotSManager.levelUpSotS(areaId, sceneId, itemNum)`

供奉的逻辑核心：

1. 由 `areaId` 找到所属 `cityId`（通过 `CityConfigData` 的 areaIdVec）
2. 取玩家 `CityInfoData`（保存城市供奉等级与已投神瞳数）
3. 找下一等级的 `StatuePromoteData`
4. 扣除神瞳（当前实现用 `costItems[0]`）
5. 若累计神瞳达到阈值：
   - `cityLevel++`，剩余神瞳数回卷
   - 增加最大体力：`PROP_MAX_STAMINA += stamina*100`
   - 发放 rewardIdList 对应奖励
   - 发送 `PacketSceneForceUnlockNotify(1, true)`（与探索/强制解锁相关）
6. 发送 `PacketLevelupCityRsp(...)` 更新客户端 UI

作者提示：

- 供奉是一个典型的“玩家属性系统”入口：它直接改 PlayerProperty，而不是 Lua 变量
- 如果你想用它做自定义探索循环，主要工作在数据表与奖励表（以及客户端展示）上

---

## 78.6 只改数据能做什么？哪些必须改引擎？

### 78.6.1 只改数据能做的（相对稳定）

- 调整某点位的传送落点、入口位置：改 `scene*_point.json` 的 `tranPos/tranRot`
- 调整秘境入口挂载的 `dungeonIds`（前提：dungeon 本体存在且客户端支持入口）
- 调整供奉所需神瞳、奖励、体力提升：改 `StatuePromoteExcelConfigData.json`

### 78.6.2 高概率需要改引擎的

- 在任务解锁点位时正确识别“是否神像”（当前硬编码 mainQuestId）
- 支持多种 costItems（当前实现主要用第 0 个）
- 更复杂的“区域/点位解锁规则”（客户端 UI 与协议会参与）

---

## 78.7 常见坑与排查

1. **/unlock map 后仍有点位没解锁**
   - 原因：`forbidSimpleUnlock=true` 或某些 `SceneBuildingPoint` 标记为 locked
   - `SetPropCommand.unlockMap` 会把这类点过滤掉（避免强行解锁）
2. **点位存在但客户端不显示/不能交互**
   - `gadgetId` 与 `$type` 对客户端至关重要；服务端能读到不代表客户端会显示
3. **点位解锁没有触发 Lua**
   - 只有走 `unlockTransPoint` 才会触发 `EVENT_UNLOCK_TRANS_POINT`；单纯把点塞进 unlocked 集合不一定触发事件

---

## 78.8 小结

ScenePoint 是“地图交互点位”的数据底座：

- 传送锚点/秘境入口/部分特殊入口都在这里
- 解锁点位会触发奖励、任务条件与 Lua 事件
- 七天神像供奉通过 cityId+level 的表驱动，直接改玩家属性与发奖励

对内容作者而言：它不是 Lua DSL，但它是“世界结构 DSL”。把 ScenePoint 与任务/Lua 事件结合，是做探索型玩法的高性价比路线。

---

## Revision Notes

- 2026-01-31：初稿。明确 ScenePoint 的数据结构、解锁事件链（任务+Lua），并补充七天神像供奉与 `StatuePromote` 的真实实现细节与边界。

