# 32 专题：Blossom（地脉/世界事件）管线：SpawnData → Worktop → Challenge → 树脂领奖

本文把“地脉（Blossom）”当成一个典型的 **大世界事件玩法（World Event）** 来拆解：它不是单纯的怪物/宝箱，而是一条完整的“数据驱动链路”——从 Spawn 数据生成交互点、开始挑战、刷怪、结算生成领奖点、消耗树脂领取奖励、并记录该事件点已被消费。

与其他章节关系：

- `analysis/18-dungeon-pipeline.md`：副本的通关/结算；Blossom 虽在大世界，但也走 Challenge/领奖点的思路。
- `analysis/17-challenge-gallery-sceneplay.md`：Challenge/Gallery 作为“玩法结算框架”的心智模型。
- `analysis/21-worktop-and-interaction-options.md`：Blossom 入口交互用 Worktop option（本文会复用其术语）。
- `analysis/35-world-resource-refresh.md`：大世界资源刷新语义（Blossom 的“消耗记录”与刷新缺口强相关）。

---

## 32.1 抽象模型：World Event（地脉）= “入口点 → 事件实例 → 领奖点”

用中性 ARPG 语言描述地脉：

1. **入口点（Entry Point）**：地图上一个可交互的点（通常是一个 gadget）
2. **事件实例（Event Instance）**：开始后进入一个刷怪/计时/保护目标等 Encounter（往往由 Challenge 驱动）
3. **领奖点（Claim Point）**：完成后出现“领奖宝箱/雕像”（可能要消耗资源，如树脂）
4. **消费记录（Consumed Marker）**：领过就标记为“本轮刷新周期内不可再领”

这一范式非常通用：你以后想做“世界随机事件/据点战/护送/地脉变体”，都可以复用这条链路。

---

## 32.2 本仓库的真实实现：`Scene.checkSpawns` 驱动 BlossomManager

Blossom 在本仓库里不是写在 `Scripts/Scene/...` 的 Lua group 里，而是一个 **引擎侧（Java）管理器** 驱动的世界事件：

- `Grasscutter/src/main/java/emu/grasscutter/game/world/Scene.java` 的 `checkSpawns()`
  - 从 `GameDepot.getSpawnLists()`（由 `Spawns.json / GadgetSpawns.json` 构建）取可见 Spawn
  - 生成 `EntityGadget` 时会调用：
    - `blossomManager.initBlossom(gadget)`

因此 Blossom 的“事件点”是 **SpawnDataEntry.gadgetId** 决定的，而不是 SceneGroup 脚本。

---

## 32.3 BlossomManager 的三段式流程（入口 → 挑战 → 领奖）

核心类：`Grasscutter/src/main/java/emu/grasscutter/game/managers/blossom/BlossomManager.java`

### 32.3.1 入口点初始化：把 spawn gadget 变成一个可“开始地脉”的 worktop

`initBlossom(EntityGadget gadget)` 做的事情（抽象成步骤）：

1. 去重/过滤：
   - 已创建过的 gadget 不重复初始化
   - `blossomConsumed`（已消费 spawn entry）会直接跳过
2. 判断类型：
   - 用 `BlossomType.valueOf(gadgetId)` 判断这个 gadgetId 是否属于地脉类型（否则不处理）
3. 把 gadget 当作 Worktop 使用：
   - `gadget.buildContent()`
   - `gadget.setState(204)`（地脉入口的默认状态）
   - 往 `GadgetWorktop` 注入 option：`187`（开始）
   - 设置 `onSelectWorktopOption` 回调：选择 option 后创建并启动地脉挑战

这里的关键点是：**地脉入口不是写在 Lua 里“监听 EVENT_SELECT_OPTION”，而是 Java 直接把回调挂在 GadgetWorktop 上**。

### 32.3.2 开始挑战：随机选怪 → 创建 BlossomActivity → Scene.setChallenge

当玩家选择 option 187 时：

1. 随机生成怪物列表（按“战斗体积 volume”凑满）：
   - 读取 `GameDepot.getBlossomConfig().monsterFightingVolume`
   - 按概率抽“弱/中/强”怪，并从 `monsterIdsPerDifficulty[difficulty]` 随机取 monsterId
2. 创建 `BlossomActivity(gadget, monsters, ..., worldLevel)` 并加入 `blossomActivities`
3. 改入口 gadget 状态：`entityGadget.updateState(201)`
4. 把挑战挂到 scene：
   - `scene.setChallenge(activity.getChallenge())`
5. 从场景移除入口 gadget（视野移除）
6. `activity.start()`

你可以把它当成：

```
玩家点入口 → 事件实例化（生成一份“本次地脉”的怪表） → Challenge 驱动 encounter
```

### 32.3.3 挑战结束与领奖：tick 里生成 chest，领奖时消耗树脂并产出 RewardPreview

`BlossomManager.onTick()` 会轮询 `blossomActivities`：

- 当某个 activity `getPass()` 为 true：
  - 把 chest 实体 add 到 scene
  - `scene.setChallenge(null)`
  - 把 activity 移入 `activeChests`
  - 从活动列表移除

领奖逻辑在 `onReward(Player player, EntityGadget chest, boolean useCondensedResin)`：

1. 匹配 chest 是否属于某个 `activeChests` 的活动
2. 消耗资源：
   - 浓缩：`useCondensedResin(1)`
   - 普通：`useResin(20)`
3. 根据世界等级选择奖励预览：
   - `BlossomRefreshExcelConfigData`（`resources/ExcelBinOutput/BlossomRefreshExcelConfigData.json`）
   - 每个 worldLevel 对应一条 `dropVec`，取 `previewReward`
   - 再从 `RewardPreviewExcelConfigData` 取出 `previewItems`
4. 生成物品列表：
   - 浓缩树脂会把每个条目的 count *2（代码里写了 `Double!`）
5. 标记消费：
   - `blossomConsumed.add(gadget.getSpawnEntry())`
   - 回收/更新 UI（`notifyIcon()`）

> 重要：`blossomConsumed` 是 **内存列表**，当前实现没有把它持久化到数据库，这意味着“重启/重载场景后”可能恢复可领（见 `analysis/35`）。

---

## 32.4 数据依赖清单（你要改地脉玩法主要改这些）

### 32.4.1 Spawn 点：地脉入口在哪里出现？

入口来自 Spawn 数据（数据目录在 `data/`）：

- `data/Spawns.json`
- `data/GadgetSpawns.json`

加载入口：`ResourceLoader.loadSpawnData()` → `GameDepot.addSpawnListById(...)`

因此：

- 你可以通过改 spawn 数据来增删地脉入口点（位置/朝向/level/config_id/groupId 等）
- 前提是 spawn 里的 `gadgetId` 必须能被 `BlossomType.valueOf(gadgetId)` 识别（否则不会初始化）

### 32.4.2 随机怪表：这轮地脉刷什么怪？

- `data/BlossomConfig.json`
  - `monsterFightingVolume`：一轮事件里目标“战斗体积”
  - `monsterIdsPerDifficulty`：每个难度的 monsterId 列表

这完全是数据文件，属于“只改数据就能改刷怪生态”的典型点。

### 32.4.3 奖励：世界等级 → 领奖预览 → 物品列表

涉及两层表：

- `resources/ExcelBinOutput/BlossomRefreshExcelConfigData.json`
  - 负责把 blossomChestId + worldLevel 映射到 `previewReward`
- `resources/ExcelBinOutput/RewardPreviewExcelConfigData.json`
  - `previewReward` → `previewItems[]`（物品 + 数量）

世界等级来源：

- `resources/ExcelBinOutput/WorldLevelExcelConfigData.json`（决定怪物等级、部分奖励分段）

---

## 32.5 “只改脚本/数据”能做的地脉变体（实战建议）

### 32.5.1 只改数据：做“不同生态的地脉”

- 改 `data/BlossomConfig.json`：
  - 把难度 0/1/2 的 monsterId 列表换成你想要的生态
  - 调整 `monsterFightingVolume` 让事件更短/更长
- 改 `BlossomRefreshExcelConfigData.json` / `RewardPreviewExcelConfigData.json`：
  - 调整不同世界等级的奖励预览与产出

### 32.5.2 只改数据：在世界各处“布点”

- 在 `Spawns.json / GadgetSpawns.json` 增加 gadget spawn
- 选择一个能被 BlossomType 识别的 `gadgetId`
- 填合理的 `sceneId/pos/rot/level/configId`

### 32.5.3 需要引擎：你想改的可能是“规则”，不是“内容”

以下很可能需要 Java：

- 树脂消耗数值（当前硬编码 20）
- BlossomType 的 gadgetId 列表/映射规则（valueOf）
- `blossomConsumed` 的持久化与刷新周期（每日/每周/跨世界等级变化）
- 从“随机选怪”改成“按地脉点位/地区/主题选怪”

这类问题属于“系统机制”，不是“内容编排”（见 `analysis/04-extensibility-and-engine-boundaries.md`）。

---

## 32.6 小结

- Blossom 是本仓库里一个非常典型的“世界事件”实现：SpawnData 负责布点，Java 管理器负责实例化与奖励，Challenge 负责 Encounter 结算。
- 它提供了一个可迁移的范式：  
  **入口点（worktop option）→ 事件实例（怪表/挑战）→ 领奖点（树脂/奖励）→ 消费记录**
- 数据层可控的部分很大（怪表、奖励预览、布点），但“规则层”（树脂、刷新周期、持久化）仍是引擎边界。

---

## Revision Notes

- 2026-01-31：首次撰写本专题；基于 `Scene.checkSpawns` 与 `BlossomManager` 实现整理地脉事件的完整数据驱动链路与可扩展边界。

