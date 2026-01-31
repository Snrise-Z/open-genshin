# 28 专题：成就 / Watcher（触发器计数）/ 战令（BattlePass）

本文把 **Achievement、Activity Watcher、BattlePass Mission** 这三套“计数型玩法系统”放在同一张图里理解：它们本质上都是 **“事件触发 → 条件匹配 → 累加进度 → 发奖励/解锁”** 的数据驱动管线，只是落在不同的数据表与不同的持久化对象上。

与其他章节关系：

- `analysis/11-activities-deep-dive.md`：活动/小游戏的 Common/Vx_y 模块范式（本文是“计数型活动条件/奖励”的更底层视角）。
- `analysis/17-challenge-gallery-sceneplay.md`：挑战/结算框架；`TRIGGER_FINISH_CHALLENGE` 等 Watcher 事件来源。
- `analysis/16-reward-drop-item.md`：RewardData、掉落与奖励体系（本文涉及“奖励发放点”，不重复展开 Reward 表细节）。

---

## 28.1 抽象模型：Watcher = “事件驱动的计数器”（可复用积木）

把 Watcher 当成一个中性模型：

- **输入**：一个事件 `TriggerType`，外加若干参数（`paramList`）用于过滤/匹配
- **状态**：`curProgress / totalProgress`
- **输出**：当 `curProgress >= totalProgress` → 标记完成 → 可领取奖励（或触发下一阶段）

你可以把它理解成“比 Quest 更轻量”的玩法单元：

- Quest 更擅长“链式剧情/阶段编排/脚本联动”
- Watcher 更擅长“统计/次数/积分/阈值奖励”（成就、战令、活动挑战任务）

---

## 28.2 三套系统的差异一览（先建立心智模型）

| 系统 | 数据来源（主要） | 持久化对象 | 触发入口 | 典型用途 |
|---|---|---|---|---|
| Achievement（成就） | `resources/ExcelBinOutput/AchievementExcelConfigData.json` + `AchievementGoalExcelConfigData.json` | `Achievements`（DB: `achievements`） | **本仓库目前缺少“自动触发”桥接**（更多靠指令/手动） | 成就页、一次性奖励 |
| Activity Watcher（活动计数） | `resources/ExcelBinOutput/NewActivityWatcherConfigData.json` + ActivityConfig/Cond | `PlayerActivityData`（DB: `activities`） | `ActivityManager.triggerWatcher(...)` | 活动内的“挑战任务/里程碑奖励” |
| BattlePass Mission（战令任务） | `resources/ExcelBinOutput/BattlePassMissionExcelConfigData.json` + `BattlePassRewardExcelConfigData.json` | `BattlePassManager`（DB: `battlepass`） | `BattlePassSystem.triggerMission(...)` | 日/周/周期任务 → BP 点数/等级/奖励 |

> 结论：如果你想“只改数据就能跑起来”，目前最稳的是 **Activity Watcher** 和 **BattlePass**；成就数据表虽然齐，但“触发桥”在本仓库里不完整。

---

## 28.3 统一的触发字典：`WatcherTriggerType`

触发类型枚举：`Grasscutter/src/main/java/emu/grasscutter/game/props/WatcherTriggerType.java`

它非常大（覆盖官方所有 Watcher 触发点），但 **“枚举存在 ≠ 引擎真的会发这个事件”**。  
你需要关心的是：当前仓库哪些地方在真实调用 trigger。

### 28.3.1 当前仓库里“确实会触发”的 WatcherTriggerType（实用清单）

从代码里能看到明确触发的类型主要包括（用于 BattlePass 与部分活动）：

- `TRIGGER_LOGIN`：玩家登录（`Player` 登录流程）
- `TRIGGER_GACHA_NUM`：抽卡次数（`GachaSystem`）
- `TRIGGER_COST_MATERIAL`：消耗材料（`Inventory`/`ResinManager` 等）
- `TRIGGER_OBTAIN_MATERIAL_NUM`：获得材料数量（`Inventory`）
- `TRIGGER_DO_FORGE`：锻造完成次数（`ForgingManager`）
- `TRIGGER_FINISH_DUNGEON`：副本完成（`DungeonManager`）
- `TRIGGER_MONSTER_DIE`：怪物死亡（`EntityMonster`）
- `TRIGGER_WORLD_BOSS_REWARD`：世界 boss 奖励（`GadgetChest` 的 boss chest 分支）
- `TRIGGER_FINISH_CHALLENGE`：挑战完成（`WorldChallenge` → `ActivityManager.triggerWatcher`，偏活动）
- `TRIGGER_FLEUR_FAIR_MUSIC_GAME_REACH_SCORE`：音乐小游戏分数（`HandlerMusicGameSettleReq` 触发活动 watcher）

> 如果你在数据里配置了一个触发类型，但引擎没有任何地方发它，那它就永远不会进度变化。  
> 这也是“只改数据/脚本”的边界判定标准之一（见 `analysis/04`）。

---

## 28.4 BattlePass（战令）系统：数据 → 缓存触发器 → 玩家任务进度

### 28.4.1 主要数据表

- `resources/ExcelBinOutput/BattlePassMissionExcelConfigData.json`
  - 每条任务：`id / triggerConfig / progress / addPoint / refreshType ...`
- `resources/ExcelBinOutput/BattlePassRewardExcelConfigData.json`
  - 每级奖励：`indexId / level / freeRewardIdList / paidRewardIdList`

奖励本体依然来自 Reward 表（见 `analysis/16`）。

### 28.4.2 运行时模型（你可以这么心算）

```
BattlePassSystem(全服)
  cachedTriggers: TriggerType -> [MissionData...]

BattlePassManager(每玩家)
  missions[id] = (progress, status)
  point / level / cyclePoints
```

触发链路：

1. 游戏内事件发生（例如 `EntityMonster.onDeath`）
2. 调用 `player.getBattlePassManager().triggerMission(triggerType, param, progressDelta)`
3. 进入 `BattlePassSystem.triggerMission(...)`：
   - 找到该 triggerType 对应的任务列表
   - param 非 0 时做 mainParams 过滤（取自 missionData.triggerConfig.paramList[0] 解析）
   - 任务进度累加，达到阈值则变为 FINISHED
   - 保存 DB 并下发更新包

### 28.4.3 `triggerConfig.paramList` 的“真实含义”

战令任务的 `triggerConfig` 形态（简化）：

```json
"triggerConfig": {
  "triggerType": "TRIGGER_COST_MATERIAL",
  "paramList": ["106", "", "", ""]
}
```

在 `BattlePassMissionData` 中：

- `triggerType` 会映射为 `WatcherTriggerType`
- `paramList[0]` 经常是：
  - 单个数字（如物品 id）
  - 或 `id;id;id` 的分号列表（会被解析成 `mainParams`）
  - 有时还夹带“可联机”这类注释字符串（不影响解析，但建议别这么写）

因此你在“只改数据”时的规则是：

1. 优先选 **引擎确实会触发的 TriggerType**（见 28.3.1）。
2. 如果想做“过滤到某些 id”，把它们写进 `paramList[0]`（用 `;` 分隔）。
3. `progress` 是完成阈值；`addPoint` 是领取后加的 BP 点数。

### 28.4.4 只改数据能做什么？

- 改/增战令任务：改 `BattlePassMissionExcelConfigData.json`（注意触发类型必须存在）
- 改/增战令奖励：改 `BattlePassRewardExcelConfigData.json` 以及 Reward 表
- 调整周期：主要受 `GameConstants` 等影响（周期刷新规则更偏引擎侧）

---

## 28.5 Activity Watcher（活动计数）：更“玩法化”的 Watcher

### 28.5.1 数据位置

- `resources/ExcelBinOutput/NewActivityWatcherConfigData.json`
  - 字段常见：`id / triggerConfig / progress / rewardID / rewardPreview / tipsTextMapHash ...`
- `resources/ExcelBinOutput/NewActivityExcelConfigData.json` / `NewActivityEntryConfigData.json` / `NewActivityCondExcelConfigData.json`
  - 定义活动本体、开放时间、条件组等（在 `analysis/11` 有更完整的范式讨论）
- `resources/Server/ActivityCondGroups.json`
  - 条件组映射（由 `ResourceLoader.loadActivityCondGroups` 加载）

### 28.5.2 运行时模型

```
ActivityConfigItem(静态配置)
  -> ActivityHandler(每活动类型的 handler)
      watchersMap: TriggerType -> [ActivityWatcher...]

PlayerActivityData(每玩家每活动)
  watcherInfoMap[id] = (curProgress, totalProgress, isTakenReward)
```

触发链路：

1. 引擎在某处调用 `player.getActivityManager().triggerWatcher(triggerType, params...)`
2. `ActivityManager` 会把所有活动的 watchersMap 里挂在该 triggerType 的 watcher 收集起来
3. 逐个 `watcher.trigger(playerActivityData, params...)`：
   - watcher 自己实现 `isMeet(params...)` 决定是否累加
4. 累加后下发 `PacketActivityUpdateWatcherNotify`

### 28.5.3 “为什么 Activity Watcher 比 BattlePass 更像玩法积木？”

因为 Activity Watcher 允许：

- **按活动类型注入不同的 watcher 实现类**
  - 例如 `MusicGameScoreTrigger`、`TrialAvatarActivityChallengeTrigger`
- watcher 的 `isMeet` 可以解释更复杂的参数语义（比如分数阈值、挑战 id 匹配）

但代价是：想新增一种全新的 watcher 逻辑，通常还是需要 Java（添加一个 `ActivityWatcher` 子类）。

---

## 28.6 Achievement（成就）：数据齐全，但“自动触发桥”不完整

### 28.6.1 数据表

- `resources/ExcelBinOutput/AchievementExcelConfigData.json`
  - 字段常见：`id / goalId / descTextMapHash / finishRewardId / triggerConfig / progress ...`
- `resources/ExcelBinOutput/AchievementGoalExcelConfigData.json`
  - 成就分组（Goal）与目标奖励

`triggerConfig` 的形态与战令很像：`triggerType + paramList`。

### 28.6.2 本仓库当前实现的现状（务实结论）

- `Achievements` 类负责：
  - 初始化所有 `AchievementData`（used 的）
  - 修改进度、完成状态、领奖
  - 下发 `PacketAchievementUpdateNotify`
- 但它 **没有** 像 BattlePass 那样的 `triggerAchievement(triggerType, ...)` 管线；
  也没有像 Activity 那样的 `ActivityManager.triggerWatcher(...)` 去驱动成就。

所以：

- **只改数据新增成就条目**：客户端可能能看到，但进度不会自动变化（除非你用 GM/指令手动推进）。
- 想要“成就随事件自动增长”，需要补齐引擎侧的 watcher 桥接（属于引擎层改动）。

---

## 28.7 只改数据/脚本的选型建议（非常实用）

当你想做“计数/里程碑奖励”时：

1. **优先用 Activity Watcher**（如果它属于活动/小游戏）  
   - 优点：有活动框架、可绑定玩法结算、奖励领取路径清晰
2. **其次用 BattlePass Mission**（如果它属于“全局任务/日周任务”）  
   - 优点：触发点少但稳定；实现成熟
3. **成就不要作为首选承载**（在本仓库里）  
   - 除非你愿意下潜补齐“自动触发桥”

---

## 28.8 小结

- WatcherTriggerType 是“事件字典”，但可用性取决于引擎是否真的触发它。
- BattlePass 与 Activity Watcher 在本仓库中是 **可通过改数据直接扩展** 的计数系统。
- Achievement 数据表齐，但自动触发管线缺失；适合先当“奖励/展示容器”，不适合当“事件驱动系统”。

---

## Revision Notes

- 2026-01-31：首次撰写本专题；整理了 WatcherTriggerType 的“实际触发清单”，并对比 Achievement / Activity Watcher / BattlePass 三套计数系统的可扩展边界。

