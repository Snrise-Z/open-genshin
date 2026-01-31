# 26 专题：实体状态持久化边界（GroupInstance / 变量 / 机关状态 / 死亡记录）

本文是“玩法编排层专题”之一，目标是回答一个决定你能否“只靠脚本/数据做长期玩法”的核心问题：

> **哪些状态会被保存并在重进场景/重连/重启后恢复？哪些只存在于内存，离开场景就没了？**

在 ARPG 的玩法编排里，这个边界决定了：

- 你能不能把一个 Puzzle/剧情分支做成“做过就永久改变”
- 你能不能做“分阶段副本/塔防”，中途掉线还能恢复
- 你做的“生态刷新/刷怪点”是否会在重启后回到初始状态

与其他章节关系：

- `analysis/12-scene-and-group-lifecycle.md`：Group/Suite 的加载/卸载机制是“何时保存/何时丢失”的触发条件。
- `analysis/24-openstate-and-progress-gating.md`：OpenState/SceneTag/地图点属于玩家级持久化，不是 group 级。
- `analysis/25-npc-and-spawn-pipeline.md`：SpawnData/NPC Born 的状态多为 scene 级内存，持久化边界不同。

---

## 26.1 三层状态：玩家级 / 世界(房主)级 / 场景内存级

为了避免混淆，建议把状态按“归属”分三层来理解：

1. **玩家级（Player Save）**  
   典型：OpenState、SceneTag、已解锁传送点/区域、任务进度、背包等。  
   特点：跟随账号持久，通常跨场景/跨重启都在。

2. **世界(房主)级（GroupInstance / Host-owned）**  
   典型：`SceneGroupInstance`（group 的 suite/变量/机关持久状态）。  
   特点：绑定房主 UID；多人世界里通常以 host 为准。

3. **场景内存级（Scene Runtime Only）**  
   典型：SpawnData 的 `spawnedEntities/deadSpawnedEntities`、NPC Born 的 `npcBornEntrySet`、当前挑战/怪潮 service、scheduler 的定时任务等。  
   特点：离开场景/销毁 scene 后通常丢失，重启更不保证。

本文重点分析第 2、3 层，因为它们最容易被误判。

---

## 26.2 SceneGroupInstance：玩法“可持久化编排”的核心载体

### 26.2.1 数据模型（你应该把它当成“Group 的存档槽”）

`SceneGroupInstance`（落库集合名：`group_instances`）关键字段：

| 字段 | 含义 | 脚本作者应如何理解 |
|---|---|---|
| `ownerUid` | 归属玩家（房主） | 多人世界里，group 状态以 host 为准 |
| `groupId` | 对应的 group id | `scene*_group<groupId>.lua` 的那一个 |
| `activeSuiteId` | 当前激活 suite | “当前阶段/房间状态”最重要的一个整数 |
| `targetSuiteId` | 目标 suite（过渡用） | 用于处理 `ban_refresh` 等特殊刷新语义 |
| `cachedVariables` | group 变量表 | `Get/SetGroupVariableValue` 操作的实际存储 |
| `cachedGadgetStates` | 机关状态缓存（仅 persistent） | 让机关状态在卸载/重载后能恢复 |
| `deadEntities` | “已死亡实体”的 config_id 集合 | 主要用于 oneoff+persistent gadget 的不重生 |
| `isCached` | 当前是否处于“仅缓存、未加载”状态 | group 卸载后会置为 cached 并保存 |
| `lastTimeRefreshed` | 最近刷新时间 | 目前更多用于记录/调试或未来扩展 |

### 26.2.2 什么时候会创建/加载/保存

**创建/加载（常见路径）**：

- Group 第一次被加载时：
  - 若数据库已有该 `ownerUid+groupId` 的 instance → 读出并挂回 `luaGroup`
  - 否则新建一个 instance，并立刻保存

**保存（你做玩法时必须知道的时机）**：

- group 被注册/反注册时：`setCached(true/false)` 会触发一次 `save()`
- 玩家离开 scene 时：`Scene.removePlayer(...)` 最后会调用 `scene.saveGroups()`
- scene 被 world deregister 时：`World.deregisterScene(scene)` 会调用 `scene.saveGroups()`
- world 保存时：`World.save()` 会遍历 scene 调 `saveGroups()`

> 直觉：只要你的玩法状态落在 `SceneGroupInstance`（变量/机关状态/activeSuiteId），它就很可能在“离开场景”这一类事件后被写回数据库。

---

## 26.3 Group 变量：`variables` 表如何映射到持久化，以及 `no_refresh` 的真实含义

### 26.3.1 初始化：变量只会“补齐缺失”，不会每次覆盖

当 group 脚本加载时（`loadGroupFromScript`），会把脚本里声明的 `variables = {...}` 做一次“补齐”：

- 如果 `cachedVariables` 里没有这个 `name` → 写入默认 `value`
- 如果已经有 → 不覆盖

这非常适合做“长期状态位”：

- 第一次进入房间：变量初始化
- 后续重进：沿用旧值

### 26.3.2 刷新：`no_refresh=false` 会在 RefreshGroup 时被重置

`refreshGroup(...)`（切 suite/初始化 suite 也走它）会执行：

- 对 group 脚本声明的每个 variable：
  - 若 `no_refresh == false` → 把 `cachedVariables[name]` 重置为默认 `value`
  - 若 `no_refresh == true` → 不动（保留运行时值）

因此你在写玩法 FSM 时应有明确策略：

- `no_refresh=false`：适合“本次战斗/本次房间”的临时计数（刷新=重开）
- `no_refresh=true`：适合“剧情分支/宝箱是否已开/永久机关状态位”等长期状态

### 26.3.3 修改：ScriptLib 对变量的写入会触发 `EVENT_VARIABLE_CHANGE`

变量相关 ScriptLib（已实现）：

- `SetGroupVariableValue` / `SetGroupVariableValueByGroup`
- `ChangeGroupVariableValue` / `ChangeGroupVariableValueByGroup`
- `GetGroupVariableValue` / `GetGroupVariableValueByGroup`

它们会：

- 写入 `SceneGroupInstance.cachedVariables`
- 触发事件 `EVENT_VARIABLE_CHANGE`，并把 `evt.source` 设为变量名

> 这就是为什么很多上游脚本用 `VARIABLE_CHANGE` 做 FSM：你改变量，就等价于“发状态机事件”。

---

## 26.4 机关状态持久化：`persistent` 与 `cachedGadgetStates`

### 26.4.1 什么时候会缓存机关状态

`SceneGroupInstance.cacheGadgetState` 的规则非常明确：

- 只缓存 `SceneGadget.persistent == true` 的 gadget

缓存触发点包括：

- gadget 状态变化时（`EntityGadget.setState` 内会写回）
- group suite 创建 gadget 时（创建后会把当前 state 再缓存一遍）

### 26.4.2 什么时候会用缓存状态恢复

当 group suite 创建 gadget 时，会用：

- `groupInstance.getCachedGadgetState(sceneGadget)` 来决定初始 state

因此如果你希望“离开房间再回来机关保持原样”，你需要：

1. 在脚本 gadget 配置里把 `persistent=true`
2. 用 `SetGadgetStateByConfigId`/`ChangeGroupGadget` 等手段改变 state（触发缓存写回）

---

## 26.5 `deadEntities`：哪些会被记“死”，以及它现在主要影响什么

### 26.5.1 记录来源

当实体死亡时：

- `EntityMonster.onDeath`：会把该实体的 `spawnEntry` 记入 `deadSpawnedEntities`（场景内存），并把其 `metaMonster.config_id` 加入 groupInstance.deadEntities（若存在 groupInstance）
- `EntityGadget.onDeath`：同样会把 `metaGadget.config_id` 加入 groupInstance.deadEntities

### 26.5.2 目前的主要用途：阻止 oneoff+persistent gadget 重生

`SceneScriptManager.getGadgetsInGroupSuite` 在创建 gadget 前有一条过滤规则：

- 只有当 **`isOneoff && persistent && deadEntities.contains(config_id)`** 时，才会跳过创建

因此当前版本下：

- 宝箱类/一次性机关如果同时标记为 persistent，有机会做到“死过就不再刷”
- 但 **oneoff 但不 persistent** 的 gadget 可能会在刷新/重载后再次出现（语义与上游资源期望可能不一致）

### 26.5.3 对怪物的持久化目前并不完整

`getMonstersInGroupSuite` 里对 `deadEntities` 的处理目前是注释/TODO。现实结果是：

- 刷新 group/suite 可能会把怪物重新刷出来
- 如果你需要“击杀永久清空某房间怪”，应当用：
  - group 变量记录“已清空”
  - 切 suite 把怪移走
  - 或在 `ANY_MONSTER_DIE` 时判断并做 `KillGroupEntity`/`RemoveEntityByConfigId` 等收尾

---

## 26.6 场景内存级状态：哪些离开就没了（以及对你写玩法的影响）

以下状态目前主要存在于 `Scene` 内存对象里：

- `spawnedEntities` / `deadSpawnedEntities`：SpawnData 的刷出/死亡记录
- `npcBornEntrySet`：已通知过的 NPC Born entry（避免重复通知）
- 当前 `challenge`、`DungeonManager` 的一部分运行时状态
- `ScriptMonsterTideService`（怪潮 service）以及 scheduler 里的定时任务（TimeAxis/平台路线等）

这意味着：

- SpawnData 的“死过不再刷”通常只在同一 scene 生命周期内成立；重进/重启可能重置
- 怪潮/计时器/平台路线这类运行时服务，掉线/销毁场景后不一定能无缝恢复（除非你把关键进度落到 group variables 并在 `GROUP_LOAD` 里重建）

一个实践建议：

> **所有你希望“可恢复”的玩法进度，都必须落到可持久化的数据面**：  
> - 玩家级：任务/进度计数/OpenState/SceneTag/地图解锁  
> - group 级：variables + activeSuiteId + persistent gadget state

---

## 26.7 面向“只改脚本/数据做玩法”的设计建议

1. **把玩法当作 FSM**：用 `variables` 明确写出阶段（`stage`）与关键计数（`killed`/`score`），并用 `VARIABLE_CHANGE` 驱动转移。
2. **用 suite 做“内容显隐”而不是“if 大量分支”**：阶段切换 = 切 suite；可读性与可维护性更强。
3. **长期状态用 `no_refresh=true`**：例如“宝箱是否开过”“剧情分支是否已选择”“机关是否永久激活”。
4. **机关要持久化就标 `persistent=true`**：并确保你的行为通过 `SetGadgetState...` 走到缓存写回路径。
5. **怪物“永久清空”不要指望 deadEntities**：目前怪物持久化缺口较大，建议用 suite/变量显式表达。

---

## 26.8 小结

本仓库的“可持久化玩法编排”主轴非常清晰：

- **GroupInstance（房主归属）**：suite + variables + persistent gadget state + deadEntities（主要对 gadget 生效）
- **玩家存档**：OpenState/SceneTag/地图点/任务进度
- **Scene 内存**：SpawnData/NPC Born/怪潮/定时器等运行时状态（不保证跨离开恢复）

只要你把状态放在正确的层上，就能在不改引擎的情况下，写出“可重进、可恢复、可长期演进”的玩法与剧情编排。

---

## Revision Notes

- 2026-01-31：首次撰写本专题（基于 `SceneGroupInstance`、`SceneScriptManager.refreshGroup`、`EntityGadget/EntityMonster` 状态写回与 `Scene.saveGroups` 调用点）。

