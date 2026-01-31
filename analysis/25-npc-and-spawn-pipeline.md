# 25 专题：NPC 与 Spawn 管线（SceneNpcBorn / GroupSuiteNotify / Spawns.json）

本文是“玩法编排层专题”之一，专门回答两个你做玩法/剧情时绕不开的问题：

1. **NPC 到底是怎么“出现在场景里”的？**（为什么很多时候看起来不是服务端生成实体）
2. **大世界那些“固定刷怪点/采集点/机关点”怎么来的？**（它们和 Lua Group 的 monsters/gadgets 是两套体系吗？）

结论先说在前面（本仓库很关键的实现边界）：

- **NPC（大多数）**：是通过 `SceneNpcBorn` 数据 + `GroupSuiteNotify` 通知客户端“加载某个 group 的某个 suite”来实现的；服务端 `EntityNPC` 基本不作为主要路径。
- **固定刷怪/机关（大世界生态）**：来自 `Spawns.json`/`GadgetSpawns.json` 的 SpawnData 管线，由服务端按距离流式刷出/刷掉。
- **Lua Group（monsters/gadgets/regions/triggers/suites）**：依然是“玩法编排”的主战场，但它不是大世界生态刷新的唯一来源。

与其他章节关系：

- `analysis/23-vision-and-streaming.md`：从“显隐/流式加载”角度解释三条管线；本文更侧重“数据模型与改法”。
- `analysis/12-scene-and-group-lifecycle.md`：Group/Suite 生命周期（NPC Born 还会依赖 groupInstance.activeSuiteId）。
- `analysis/20-talk-cutscene-textmap.md`：任务对白会间接影响 NPC/组套件加载（Talk/Quest 与 GroupSuiteNotify 的关系）。

---

## 25.1 先把 NPC 分三类（否则一定会混乱）

### A 类：SceneNpcBorn 驱动的“客户端 NPC 套件”

这是本仓库最主流的 NPC 出生方式：

- 数据在 `resources/BinOutput/Scene/SceneNpcBorn/*.json`
- 服务端按玩家位置查询邻域 entry
- 通过 `PacketGroupSuiteNotify` 告诉客户端：“请把 groupId → suiteId 的套件加载出来”

> 直觉：NPC 是“客户端加载的场景内容”，服务端只发“加载哪个套件”的指令，并不一定生成实体。

### B 类：Lua Group 脚本里声明的 `npcs = { ... }`

你会在很多 `scene*_group*.lua` 里看到：

- 顶层 `npcs = { {config_id=..., npc_id=..., pos=..., ...}, ... }`
- suite 里也可能出现 `npcs = { 2001, 2002 }`

但在本仓库当前实现中：

- `SceneGroup` 会把顶层 `npcs` 解析进内存（用于索引/统计等）
- **`SceneSuite` 并没有 `npcs` 字段**，所以 `suites[x].npcs` 这类写法不会被 suite 初始化/创建实体流程消费
- `SceneScriptManager.addGroupSuite(...)` 也不会创建 `EntityNPC`

因此你应该把它当成：

- “资源包里保留的上游结构”，或“未来扩展点”
- 而不是当前可依赖的“NPC 必然会被服务端生成并同步”的机制

### C 类：Quest Teleport/Rewind 数据中的 NPC（任务态）

任务系统里有 `TeleportData/RewindData` 这样的结构（字段包括 npc script、pos、scene_id、alias 等），它们通常用于：

- 任务回滚（rewind）
- 任务传送/过场切换时的引导与定位

它更偏“任务引擎驱动客户端加载/摆放”的范畴，建议和 A 类一起理解：**很多 NPC 是客户端侧资源加载的结果**。

---

## 25.2 管线 A：SceneNpcBorn（NPC 出生数据）怎么加载与生效

### 25.2.1 数据结构：SceneNpcBornData / SceneNpcBornEntry

每个 scene 有一个 `SceneNpcBornData`：

- `sceneId`
- `bornPosList: List<SceneNpcBornEntry>`
- `index`：空间索引（RTree，启动时构建）

每条 `SceneNpcBornEntry` 关键字段：

| 字段 | 含义（实践语义） |
|---|---|
| `pos/rot` | 用于空间索引与候选筛选（位置） |
| `groupId` | 要通知客户端加载的 group |
| `suiteIdList` | 允许加载的 suite 列表（与 groupInstance.activeSuiteId 匹配） |
| `configId/id` | 在本仓库的 NPC Born 管线里不直接影响 suite 选择，更多像原始资源字段 |

### 25.2.2 运行时流程：`Scene.loadNpcForPlayer(player)`

核心逻辑（概念化）：

1. 用玩家位置在 `SceneNpcBornData.index` 查询邻域 entry（半径 `loadEntitiesForPlayerRange`）
2. 过滤掉已在 `npcBornEntrySet` 的 entry（避免重复通知）
3. 对每个候选 entry：
   - 找到 `groupId` 的 `SceneGroupInstance`
   - 若 entry 有 `suiteIdList`，且 **不包含** `groupInstance.activeSuiteId` → 跳过
4. 将通过筛选的 entry 批量组装成 `PacketGroupSuiteNotify` 并广播

因此出现一个非常关键的耦合点：

> **NPC 是否“可加载”取决于该 group 当前 active suite 是多少。**  
> 也就是说：你用 `RefreshGroupSuite`（或任务驱动的 group suite 切换）不仅影响怪/机关/触发器，还会影响 NPC Born 这条管线的结果。

### 25.2.3 为什么说 `EntityNPC` “不重要”

本仓库的 `PacketGroupSuiteNotify` 里有非常直白的注释：它才是真正控制 NPC suite 加载的方式。你可以把这个设计理解成：

- NPC 的大部分表现由客户端资源决定（模型、动画、AI/对话入口等）
- 服务端只需要告诉客户端“加载哪个 group suite”

这也解释了很多“脚本里写了 npc 但服务端看起来没生成实体”的现象。

---

## 25.3 管线 B：SpawnData（固定刷怪/机关点）怎么加载与生效

### 25.3.1 数据来源：`Spawns.json` 与 `GadgetSpawns.json`

资源加载器会尝试读取两个文件（文件名固定）：

- `Spawns.json`
- `GadgetSpawns.json`

解析为一组 `SpawnGroupEntry`，每个 entry 持有：

- `sceneId`
- `groupId`
- `blockId`
- `spawns: List<SpawnDataEntry>`

每个 `SpawnDataEntry` 关键字段（常用）：

- `monsterId` 或 `gadgetId`（二选一）
- `configId`（局部实例 id）
- `pos/rot`
- `level`（怪物等级基准）
- `poseId`（怪物姿态）
- `gadgetState`（机关初始状态）
- `gatherItemId`（采集物类型，常由 gadget content 消费）

### 25.3.2 运行时流程：`Scene.checkSpawns()`

概念化流程：

1. 把所有玩家的位置映射成“相邻 GridBlockId”集合（每个 scale 取 5×5）
2. 从 `GameDepot.spawnLists` 取出这些块内的 `SpawnDataEntry`，形成 `visible`
3. 对 `visible` 中“没生成过且没被标记死亡”的 entry：
   - 生成 `EntityMonster` 或 `EntityGadget`
   - 将 entry 记入 `spawnedEntities`
4. 对已生成但不再可见的实体：移除并同步消失

死亡标记：

- `EntityMonster.onDeath` / `EntityGadget.onDeath` 都会把其 `spawnEntry` 加入 `scene.deadSpawnedEntities`

> 这会阻止它在同一 scene 生命周期内再次刷出，但是否跨重启持久化取决于场景生命周期与存档策略（见 `analysis/26-entity-state-persistence.md`）。

### 25.3.3 一个实现缺口：scale 计算目前是 TODO

`SpawnDataEntry.GridBlockId.getScale(int gadgetId)` 在本仓库里返回 `0`（TODO），意味着：

- 所有 spawn entry 在分桶时都会落到 scale=0 的块（`BLOCK_SIZE[0]`）
- `checkSpawns()` 虽然会按多个 scale 查询相邻块，但 scale>0 的查询通常取不到数据

对玩法编排的影响：

- 大多数情况下仍能“刷出来”，但空间分桶精度与性能可能与设计不一致
- 如果你要大量依赖 SpawnData 做生态/采集，需要留意这一点（属于引擎层边界）

---

## 25.4 实战：我想“只改脚本/数据”做这些事，该改哪里

### 25.4.1 做一个“固定刷怪点/采集点”

优先选 SpawnData 管线：

1. 在 `Spawns.json` 或 `GadgetSpawns.json` 增加对应 `SpawnGroupEntry`/`SpawnDataEntry`
2. 填好 `sceneId/groupId/configId/pos/rot` 与 `monsterId` 或 `gadgetId`
3. 确认该怪/机关的类型数据在 `ExcelBinOutput`/`BinOutput` 中可被解析（否则服务端会创建失败）

适用：生态类内容、大世界填充、无需复杂 FSM 的点。

### 25.4.2 做一个“剧情阶段才出现的 NPC”

本仓库更推荐走 NPC Born + suite gating：

1. 找到该 NPC 所在的 `SceneNpcBorn`（或新增 entry）
2. 让它绑定某个 `groupId`，并设置 `suiteIdList`
3. 通过任务/脚本在合适时机把该 group 切到对应 suite（`refreshGroupSuite` 或任务驱动）

注意：NPC 的资源/表现主要在客户端；服务端只负责通知加载套件。

### 25.4.3 做一个“玩法房间里的 NPC/演员”

如果你希望像怪/机关一样由服务端生成 `EntityNPC` 并参与脚本事件，目前属于引擎能力缺口：

- 虽然有 `EntityNPC` 类，但 group suite 并不会创建 NPC 实体
- `suites[x].npcs` 也不会被消费

在“只改脚本/数据”的限制下，你更现实的方案是：

- 把 NPC 表现做成 gadget/演员机关（例如交互点、剧情装置），用 Talk/Cutscene 驱动叙事（见 `analysis/20-talk-cutscene-textmap.md`）
- 或者把它视为客户端侧资源加载，由 `GroupSuiteNotify`/任务系统驱动

---

## 25.5 小结

本专题最重要的“心智结论”是把 NPC/刷怪来源拆开：

- **Lua Group**：最强的玩法编排 DSL（怪、机关、触发器、变量、suite/FSM）。
- **SpawnData**：大世界生态/固定刷点（距离驱动、简单稳定，但编排能力弱）。
- **SceneNpcBorn + GroupSuiteNotify**：NPC 的主要出现机制（客户端套件加载，强依赖 group 的 active suite）。

你一旦把这三条管线在脑子里分清，就能更快判断“该改脚本还是该改数据”“为什么改了 group 但 NPC 没动”“为什么生态点不受 suite 影响”等问题。

---

## Revision Notes

- 2026-01-31：首次撰写本专题（基于 `SceneNpcBornData/loadNpcForPlayer`、`ResourceLoader.loadSpawnData`、`Scene.checkSpawns` 与 `PacketGroupSuiteNotify` 行为）。

