# 12 Scene/Block/Group 生命周期专题：加载、卸载、Suite 切换与持久化

本文把“大世界/场景玩法”拆成一个可复用的心智模型：  
**Scene（关卡容器）→ Block（空间分块）→ Group（玩法单元）→ Suite（阶段集合）**，并解释它们在 Grasscutter 运行时如何被加载、如何卸载、如何在刷新/重进场景后恢复。

与其他章节关系：

- `analysis/01-overview.md`：目录地图（Scene/Block/Group 的脚本文件在哪里）。
- `analysis/02-lua-runtime-model.md`：触发器（Trigger）与事件系统基本原理。
- `analysis/10-quests-deep-dive.md`：Quest 通过 Exec/TriggerFire 会直接操纵 group/suite，强相关。
- `analysis/11-activities-deep-dive.md`：Common 模块大量依赖 suite/变量/加载时机，强相关。

---

## 12.1 先把“玩法装配层”分四级：Scene → Block → Group → Suite

你可以把这一套当成 ARPG 编排层的“最小装配结构”：

- **Scene**：世界/副本的容器（sceneId），负责：玩家/实体生命周期、tick、视距加载、脚本管理器挂载。
- **Block**：空间分块（blockId），负责：把 Scene 切成若干 chunk，存放 group 列表与空间范围。
- **Group**：玩法单元（groupId），负责：monsters/gadgets/regions/triggers/variables/suites 的集合，是绝大多数玩法编排发生的地方。
- **Suite**：group 内阶段集合（suite index），负责：一组实体+触发器的组合；切 suite = “关卡阶段切换”的常用实现。

对应脚本目录（复习）：

- `resources/Scripts/Scene/<sceneId>/scene<sceneId>.lua`：Scene 元数据
- `resources/Scripts/Scene/<sceneId>/scene<sceneId>_block<blockId>.lua`：Block → groups 列表
- `resources/Scripts/Scene/<sceneId>/scene<sceneId>_group<groupId>.lua`：Group 编排主体（可 `require` Common 模块）

---

## 12.2 运行时主链路鸟瞰：从 Scene tick 到 group 加载/卸载

你可以用这张顺序图心算大世界运行态：

```
Scene.onTick()
  ├─ checkGroups()        # 视距相关：决定哪些 group 该加载/卸载
  ├─ scriptManager.checkRegions()  # region enter/leave 事件判定
  ├─ entity.onTick()      # 实体 tick（含 gadget controller OnTimer、monster live 等）
  └─ ...其他系统（challenge/blossom/tower等）
```

关键代码入口：

- `Grasscutter/src/main/java/emu/grasscutter/game/world/Scene.java:onTick`
- `Grasscutter/src/main/java/emu/grasscutter/game/world/Scene.java:checkGroups`
- `Grasscutter/src/main/java/emu/grasscutter/scripts/SceneScriptManager.java:checkRegions`

> 非常重要的一个“现实”：在当前实现里，**group 是否加载**主要由 `checkGroups()` 决定，而不是你在 block 里写了就永远常驻。

---

## 12.3 “哪些 group 对玩家可见？”：GroupGrids（视距网格）与缓存

### 12.3.1 为什么要有 GroupGrids？

大世界 group 数量巨大，不可能每 tick 全量遍历。

Grasscutter 的做法是：**预先把 group 位置投影到网格（grid）**，并按 vision level 分层，然后玩家只查询“附近网格”就能得到附近 groupId 集合。

主要实现：

- `SceneScriptManager.getGroupGrids()`：构建/读取缓存
- `emu.grasscutter.data.server.Grid`：网格结构与近邻查询（RTree）
- `Scene.getPlayerActiveGroups()`：对玩家位置取附近 group 集合

### 12.3.2 网格怎么生成：从“实体位置”反推 group 的视距层级

生成逻辑（抽象版）：

1) 遍历 Scene 的 blocks
2) 对每个 block：加载 block 数据、遍历 groups
3) 对每个 group：加载 group 脚本，把 **monsters/gadgets/regions 的位置**加入网格
4) 计算该 group 的“最大 vision_level”，并把 group.pos 也加入对应层级

对应代码在 `SceneScriptManager.getGroupGrids()`，里面最关键的一段是：

- `addGridPositionToMap(map, group_id, vision_level, position)`：把坐标映射到 `GridPosition(x,z,width)`，再把 groupId 塞到该格子的集合里
- `getGadgetVisionLevel(gadget_id)`：通过 `GadgetData.visionLevel` 与 `server.game.visionOptions` 名称匹配，决定 gadget 的 vision 层级

### 12.3.3 缓存文件：`cache/scene<id>_grid.json`

为了避免每次启动都生成网格（很慢），它会把结果写到缓存：

- 路径形如：`cache/scene<sceneId>_grid.json`

触发与禁用条件（重要）：

- 如果 scene 有 override（`SceneMetaLoadEvent` 覆盖了 group），会设置 `noCacheGroupGridsToDisk=true`，避免把“临时覆盖”的网格写入磁盘。
- 配置项 `server.game.cacheSceneEntitiesEveryRun` 会影响是否每次重算。

### 12.3.4 魔改提示：你新增/移动 group 后，为什么“进游戏看不到”？

最常见原因不是你没写脚本，而是 **网格缓存没更新**。

排查/修复建议：

1) 删除对应缓存：`cache/scene<sceneId>_grid.json`
2) 或打开 `server.game.cacheSceneEntitiesEveryRun`
3) 重启服务器，让它重新生成网格

否则：`checkGroups()` 根本不会把你的新 groupId 算进 visible 集合里，自然不会加载。

---

## 12.4 group 加载：从 groupId 到“实体/触发器/变量”落地

### 12.4.1 Scene.checkGroups 的装配逻辑

`Scene.checkGroups()`（简化理解）：

1) 计算所有玩家可见的 groupId 集合 `visible`
2) 对已加载的 groups：
   - 不可见且不是 dynamic_load 且不是 dontUnload → `unloadGroup(...)`
3) 对 `visible` 里尚未加载的 groupId：
   - 扫描 blocks，找到该 group 所属 block 并确保 block 已加载
   - 收集要加载的 `SceneGroup` 列表
4) `onLoadGroup(toLoad)`
5) 如果加载了动态 group 且涉及 group replacement，则 `onRegisterGroups()`

关键点：

- `group.dynamic_load == true` 的 group 不会被“不可见卸载”（用于动态内容）
- `group.dontUnload == true` 会强制常驻（QuestExec 会用它，见 12.8）

### 12.4.2 onLoadGroup：脚本解析、实例恢复、初始 suite 装配

`Scene.onLoadGroup(List<SceneGroup> groups)` 做了几件关键事：

1) `scriptManager.loadGroupFromScript(group)`
   - `group.load(sceneId)`：eval `sceneX_groupY.lua`
   - 解析 monsters/gadgets/regions/triggers/suites/variables
   - 创建/复用 `SceneGroupInstance`（见 12.6）
2) `scriptManager.refreshGroup(groupInstance, 0, false)`
   - “0 suite”表示按官方做法：让脚本自己决定初始 suite（实现细节在 refreshGroup 内）
3) 把 group 加进 `loadedGroups`
4) `callEvent(EVENT_GROUP_LOAD)`（对每个 group）

你应该记住的抽象语义：

> **加载 group = 加载脚本 + 恢复实例 + 装配 suite（实体/触发器/区域）+ 发 GROUP_LOAD 事件。**

---

## 12.5 suite 的意义：用集合切换表达“关卡阶段”

### 12.5.1 suite 由哪三类内容组成？

在 Grasscutter 的实现里，一个 suite 大体包含：

- `sceneMonsters`
- `sceneGadgets`
- `sceneRegions`
- `sceneTriggers`

当 suite 被 add 时：

- triggers 先注册（让“实体 spawn 后立刻可响应事件”）
- 再创建实体（CreateMonster/CreateGadget）
- 最后注册 regions

见 `SceneScriptManager.addGroupSuite(...)`。

### 12.5.2 刷新 suite 的核心函数：refreshGroup / refreshGroupSuite

你会在 QuestExec 与 Lua 中频繁用到：

- `SceneScriptManager.refreshGroupSuite(groupId, suiteId)`
- `ScriptLib.RefreshGroup({group_id=..., suite=...})`（注意：脚本侧实现被标注为“不完整/粗糙”，见 14.10）

刷新过程会：

1) 移除旧 suite（removeGroupSuite）
2) add 新 suite（addGroupSuite）
3) 根据 `SceneVar.no_refresh` 决定是否重置变量
4) 触发 `EVENT_GROUP_REFRESH`

### 12.5.3 常见“阶段化”写法建议

你未来做新玩法时，优先用这三件事搭一个 FSM：

- `variables`：存 stage/计数/是否完成（no_refresh 决定是否跨刷新持久）
- `suites`：每个阶段要加载的实体集合
- `AddExtraGroupSuite/RemoveExtraGroupSuite/RefreshGroupSuite`：阶段切换的“装配动作”

---

## 12.6 group 的持久化：SceneGroupInstance（非常关键）

文件：`Grasscutter/src/main/java/emu/grasscutter/game/world/SceneGroupInstance.java`

你可以把它当成 group 的“运行时存档”：

| 字段 | 作用 |
|---|---|
| `activeSuiteId/targetSuiteId` | 当前 suite 与刷新过程控制 |
| `cachedVariables` | group variable 的持久化载体（被 ScriptLib 读写） |
| `cachedGadgetStates` | gadget 状态缓存（只对 `persistent=true` 的 gadget 生效） |
| `deadEntities` | 已死亡/消失的 oneoff/persistent 实体 config_id（防止重刷） |
| `isCached` | group 当前是否“未加载但缓存实例仍存在”（卸载后会标记） |

### 12.6.1 变量：`variables`（脚本定义）→ `cachedVariables`（实例保存）

加载 group 时，`loadGroupFromScript` 会把脚本定义的 variables 初始化到 `cachedVariables`：

- 如果实例里没有该变量，就写默认值

刷新 group（refreshGroup）时：

- 对 `no_refresh=false` 的变量，会重置到默认值
- 对 `no_refresh=true` 的变量，会保留实例值（跨刷新/跨卸载）

### 12.6.2 gadget 状态：persistent 才会缓存

`SceneGroupInstance.cacheGadgetState` 只在 `SceneGadget.persistent == true` 时写入：

- gadget.updateState(...) → instance.cacheGadgetState(metaGadget, newState)

然后 suite 重新加载时，会用 `getCachedGadgetState` 作为初始 state。

这对“机关解谜存档”很重要：  
**如果你希望机关状态跨离开场景/重登仍存在，确保 `persistent=true`**。

### 12.6.3 deadEntities：oneoff/persistent 物件为什么不会重刷？

当 monster/gadget 死亡：

- `EntityMonster.onDeath` / `EntityGadget.onDeath` 会把其 `meta*.config_id` 加到 `deadEntities`

suite 装配时，对 gadget 的过滤条件里有一条：

- `(!m.isOneoff || !m.persistent || !deadEntities.contains(config_id))`

含义（直觉版）：

- 普通非 oneoff 的实体可以反复刷
- oneoff + persistent 的实体（例如大多数宝箱）死了就别再刷

这也是你做“可重复挑战”时必须注意的点：  
不要误把可重复内容标成 oneoff/persistent，否则刷新 suite 也回不来。

---

## 12.7 group 卸载：实体清理、触发器注销、挑战失败、副作用

卸载入口：`Scene.unloadGroup(SceneBlock block, int group_id)`

主要动作：

1) 移除该 group 在该 block 中的实体（Monster/Gadget/等），并广播 `SceneEntityDisappear`
2) deregister triggers、deregister regions
3) 如果当前有 challenge 且它的 group == 被卸载 group → challenge.fail()
4) 维护 `loadedGroupSetPerBlock`、`loadedGroups` 集合
5) 广播 `PacketGroupUnloadNotify`
6) `scriptManager.unregisterGroup(group)`：从运行态 Map 移除，并把对应实例标记为 cached

### 12.7.1 重要缺口：`EVENT_GROUP_WILL_UNLOAD` 在当前实现里没有触发

虽然 `EventType` 里有 `EVENT_GROUP_WILL_UNLOAD`，但在代码中没有看到它被 `callEvent`。  
这意味着：

- 某些 Common 模块用它做“卸载兜底清理”在本实现里可能不会生效（见 `analysis/11` 中 CoinCollect 的注释背景）。

这类差异属于“脚本层范式 vs 引擎实现覆盖度”问题，应纳入你对模块可用性的判断（见 `analysis/14`）。

---

## 12.8 dynamic group、dontUnload 与 Quest 的关系

### 12.8.1 dynamic_load：不会被视距逻辑卸载

`Scene.checkGroups()` 卸载时会跳过：

- `group.dynamic_load == true`

这类 group 通常用于：

- 任务阶段才出现的内容
- 活动玩法的临时 group

### 12.8.2 dontUnload：QuestExec 强制常驻

`QuestExecRefreshGroupSuite` 在刷新 suite 后会：

- `scriptManager.getGroupById(groupId).dontUnload = true`

意图很明确：  
**任务驱动的关键 group 不应该因为玩家暂时离开视距而被卸载**，否则任务阶段会错乱。

### 12.8.3 loadDynamicGroup / unregisterDynamicGroup

Scene 支持：

- `loadDynamicGroup(groupId)`：加载并返回 init_config.suite
- `unregisterDynamicGroup(groupId)`：卸载该 group

QuestExec：

- `REGISTER_DYNAMIC_GROUP` / `UNREGISTER_DYNAMIC_GROUP` 会用它们，并把 `(scene, group, suite)` 记录到 `QuestGroupSuite`，用于进场景恢复（见 `analysis/10`）。

---

## 12.9 group replacement（高级）：用动态 group 替换一批旧 group

如果你把某些 group 当作“地图状态的版本”，那 group replacement 就是一个强工具：

- 新 group 加载后，按照规则卸载一批旧 group，实现“世界状态变更”

数据来源：

- `resources/Scripts/Scene/groups_replacement.lua`（Lua 数据表 `replacements = {...}`）

加载入口：

- `ResourceLoader.loadGroupReplacements()`：eval 该 Lua，写入 `GameData.groupReplacements`

触发时机：

- `Scene.loadDynamicGroup()`：如果加载的 groupId 在 replacements map 中，则 `onRegisterGroups()`

判断条件（关键）：

- 被替换 group 必须有 `is_replaceable` 配置，且版本/开关满足规则
- 替换顺序使用拓扑排序（Kahn），避免“先卸载了还依赖的组”

你可以把它理解为：

> **把“地图状态切换”也做成数据驱动，而不是靠硬编码。**

---

## 12.10 给魔改者的实操：如何“稳定地把新玩法装进世界”

下面是一套尽量不踩坑的流程：

1) 选 sceneId 与空间位置（确保玩家能到）
2) 新建 group：`resources/Scripts/Scene/<sceneId>/scene<sceneId>_group<groupId>.lua`
   - 先做最小闭环：一个 region + ENTER_REGION trigger + PrintContextLog
3) 把 group 加进某个 block：`scene<sceneId>_block<blockId>.lua` 的 `groups` 列表
4) 清理/重建 group 网格缓存（否则可能永远不加载）
   - 删除 `cache/scene<sceneId>_grid.json`（或打开强制重算配置）
5) 重启服务器，进场景验证：
   - 能否触发 GROUP_LOAD
   - 能否触发 ENTER_REGION
   - suite/变量刷新是否如预期

> 先跑通“加载/触发/切 suite”三件事，再把怪物/机关/活动模块慢慢加进去，会比一上来塞满脚本更高效。

---

## 12.11 常见坑与对策（总结）

1) **改了 group 但游戏里没出现**：优先怀疑 `cache/sceneX_grid.json` 没更新（12.3.4）。
2) **oneoff/persistent 搭配导致无法重刷**：检查 `isOneoff` 与 `persistent`（12.6.3）。
3) **依赖 GROUP_WILL_UNLOAD 的模块清理不执行**：当前实现未触发该事件（12.7.1）。
4) **某些事件“触发太频繁”导致性能/逻辑问题**：例如 `EVENT_ANY_MONSTER_LIVE` 是按 tick 触发（见 `analysis/13`）。
5) **Quest 驱动的 group 被卸载**：需要 `dontUnload` 或动态 group + QuestGroupSuite 恢复（12.8）。

---

## Revision Notes

- 2026-01-31：创建本文档（Scene/Block/Group 生命周期专题初版）。

