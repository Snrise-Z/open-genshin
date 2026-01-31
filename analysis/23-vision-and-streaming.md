# 23 专题：Vision/流式加载（Streaming）与实体显隐

本文是“玩法编排层专题”之一，目标是把 **大世界内容为什么会“靠近才出现、远离就消失”** 这件事拆成你能心算的模型，并明确：

- 服务端到底在“流式加载”什么（Block/Group、SpawnData、NPC GroupSuite）；
- 网络上的 `VisionType` 在本仓库里是怎么被使用的；
- Lua 脚本想控制“显隐/视野”时，哪些 ScriptLib API 可用、哪些缺口会导致模块跑不起来。

与其他章节关系：

- `analysis/12-scene-and-group-lifecycle.md`：更侧重 Group/Suite 的生命周期；本文更侧重“距离/范围驱动的加载/卸载”。
- `analysis/13-event-contracts-and-scriptargs.md`：Region/Trigger 的事件契约；本文会引用 Enter/Leave 与实体出现/消失的触发条件。
- `analysis/25-npc-and-spawn-pipeline.md`：NPC Born 与 SpawnData 的更详细数据管线；本文主要讲“显隐策略与可控边界”。

---

## 23.1 抽象模型：Streaming = 空间索引 → 可见集合 → 增量同步

在一个支持大世界的 ARPG 引擎里，Streaming 通常分三步：

1. **空间索引（Index）**：把内容（groups / spawns / npc born entries）放进空间结构里（RTree/Grid）。
2. **可见集合（Visible Set）**：根据玩家位置 + 配置范围算出“应该在视野/内存中的内容集合”。
3. **增量同步（Delta）**：对比上一次的集合，生成 `toAdd` / `toRemove`，然后用网络包（带 `VisionType`）通知客户端。

本仓库就是这么做的，只是把“内容”分成三条并行管线：**脚本 Group**、**SpawnData 静态刷怪/机关**、**NPC Born（GroupSuite 通知）**。

---

## 23.2 管线 A：脚本 Group 的流式加载（Scene → Block → Group）

### 23.2.1 “玩家附近有哪些 Group”怎么计算

核心在 `Scene.getPlayerActiveGroups(Player)`：

- `SceneScriptManager.getGroupGrids()` 预先把 group 映射到多个“网格层”（按 `vision_level` 分层）
- 对每个 `vision_level`，用 `Grid.getNearbyGroups(level, playerPos)` 得到附近 groupId 集合
- 合并得到该玩家的 `activeGroups`

网格的参数来源于服务端配置（从代码可见字段名）：

- `server.game.visionOptions[level].gridWidth`：每层网格尺寸
- `server.game.visionOptions[level].visionRange`：这一层的可视半径（用于选“最大 vision_level”的落点策略）
- `server.game.loadEntitiesForPlayerRange`：块/索引查询常用的邻域半径（后面 Spawn/NPC 也用）

> 直觉：**vision_level 越大，grid 越粗，覆盖越远**。Group 内每个实体（monster/gadget/npc/region）可以带 `vision_level`，从而影响“这个 group 在哪一层网格里被发现”。

### 23.2.2 `Scene.checkGroups()`：加载/卸载的决策逻辑

`Scene.checkGroups()` 里做的事情非常“教科书”：

1. 计算全场景可见 group 集合：
   - `visible = union(allPlayers.activeGroups)`
2. 对已加载的 group：
   - 若 `group.id` 不在 `visible`
   - 且 `!group.dynamic_load`
   - 且 `!group.dontUnload`
   - → 执行 `unloadGroup(...)`
3. 对需要加载的 group：
   - `visible` 中那些“还没 loaded” 的 groupId → 找到其所在 block → `onLoadGroup(toLoad)` → `onRegisterGroups()`

因此：

- **`dynamic_load`** 的 group 不会被“距离驱动自动卸载/加载”，它更像“脚本手动管理的玩法实例”（例如活动房间/临时玩法）。
- **`dontUnload`** 则是硬保活：不管距离都不卸载（适合做“全局状态机关/核心逻辑 group”）。

### 23.2.3 Group 加载时发生了什么（与脚本最相关）

`Scene.onLoadGroup(groups)`（简化）：

1. `SceneScriptManager.loadGroupFromScript(group)`：解析 `scene*_group*.lua`
2. 建立/恢复 `SceneGroupInstance`（会从数据库读出上次缓存的 suite/变量/机关状态，见 `analysis/26-entity-state-persistence.md`）
3. `SceneScriptManager.refreshGroup(groupInstance, 0, false)`：执行“官方式”的 init suite 选择与 suite 实体创建
4. 触发 `EVENT_GROUP_LOAD`

Group 卸载时（`Scene.unloadGroup`）则会：

- 把该 group 的实体从 Scene 移除（并发 `VISION_TYPE_REMOVE` 的消失包）
- 反注册 triggers/regions
- 广播 `PacketGroupUnloadNotify`
- `SceneScriptManager.unregisterGroup(group)`：把 group instance 标记为 cached 并保存

> 结论：**脚本层能靠 Group/Suite 来控制“内容出现/消失”**，而且它是本仓库最可靠的“显隐开关”之一。

---

## 23.3 管线 B：SpawnData 静态刷怪/机关的流式加载（非 Lua Group）

### 23.3.1 数据来源与定位

SpawnData 不来自 `Scripts/Scene/...` 的 group 定义，而是由资源加载器从 `Spawns.json` / `GadgetSpawns.json` 读入，构建：

- `SpawnGroupEntry`（sceneId/groupId/blockId/spawns）
- `SpawnDataEntry`（monsterId/gadgetId/configId/pos/rot/level/state/...）

这些 entry 会按“格子块坐标（GridBlockId）”分桶缓存到 `GameDepot.spawnLists`。

### 23.3.2 `Scene.checkSpawns()`：刷与不刷只看“玩家周围哪些块”

`Scene.checkSpawns()` 的决策逻辑（简化）：

1. 对每个玩家：计算其周围 5×5 的相邻 grid blocks（并对每个 scale 都算一遍）
2. 合并所有玩家的 `loadedGridBlocks`，与上一次比：
   - 若块集合没变化 → 直接 return（不重算）
3. 从 `GameDepot.spawnLists` 取出这些块的 entry 合并为 `visible`
4. `visible - spawnedEntities - deadSpawnedEntities` → 生成 `toAdd`
5. `spawnedEntities` 中那些不在 `visible` 的实体 → 生成 `toRemove`
6. 对 `toAdd`：`PacketSceneEntityAppearNotify(..., VISION_TYPE_BORN)`
7. 对 `toRemove`：`PacketSceneEntityDisappearNotify(..., VISION_TYPE_REMOVE)`

因此 SpawnData 的特征是：

- 纯“距离/块”驱动：**不受 Lua suite/trigger 控制**
- 适合做大世界“常驻生态/采集点/怪点”
- 但它的“可编排性”弱：你只能改 spawn 数据，不能像 group 那样轻松写 FSM

> 注意：`deadSpawnedEntities` 是 Scene 内存集合，重启/换场景通常会丢失；如果你指望“击杀后永久不刷”，要看 `analysis/26-entity-state-persistence.md` 里哪些东西真的落库。

---

## 23.4 管线 C：NPC Born 的“显隐”是一种特殊的 GroupSuite 通知

本仓库里 NPC 的主流加载方式不是“生成 `EntityNPC`”，而是：

1. 从 `BinOutput/Scene/SceneNpcBorn/*.json` 加载 `SceneNpcBornData`
2. 为每个 scene 建一个空间索引（RTree）
3. 玩家靠近时：
   - `Scene.loadNpcForPlayer(player)` 查邻域 entry
   - 检查 entry 的 `groupId` 对应的 `SceneGroupInstance.activeSuiteId`
   - 若 entry 的 `suiteIdList` 包含当前 active suite → 广播 `PacketGroupSuiteNotify`

关键含义：

- `GroupSuiteNotify` 在这里更像“告诉客户端：请把某个 group 的某个 suite 作为 NPC 套件加载出来”
- 服务端甚至在注释里写明了：这才是“真正控制 NPC suite” 的方式，而 `EntityNPC` “没用”

对脚本作者的启示：

- 你如果想用“切 suite”控制 NPC 的出现/消失，本仓库 **更依赖** `SceneNpcBorn` 的 suiteIdList 与 groupInstance.activeSuiteId 的匹配，而不是 Lua 里 `suites[x].npcs = {...}`（后者在当前实现里并不会被 suite 处理，见 `analysis/25-npc-and-spawn-pipeline.md`）。

---

## 23.5 `VisionType` 在本仓库的使用语义（你写脚本时能间接影响哪些）

`VisionType` 是网络层的“出现/消失原因”。本仓库常见用法（以“出现/消失包”的发送点为准）：

| 场景 | 典型调用 | `VisionType` |
|---|---|---|
| SpawnData 新刷出来 | `checkSpawns()` | `VISION_TYPE_BORN` |
| SpawnData 离开范围移除 | `checkSpawns()` | `VISION_TYPE_REMOVE` |
| Group suite 创建实体 | `SceneScriptManager.addEntities()`（默认） | 多数走 `VISION_TYPE_BORN` |
| “遇见”式批量加入 | `SceneScriptManager.meetEntities()` | `VISION_TYPE_MEET` |
| “离开区域/卸载组”式移除 | `removeMonstersInGroup / removeGadgetsInGroup` 等 | 常见 `VISION_TYPE_MISS` 或 `VISION_TYPE_REMOVE` |
| 刷新式移除（不一定代表真正删除） | `SceneScriptManager.removeEntities()` | `VISION_TYPE_REFRESH` |
| 实体死亡移除 | `Scene.removeEntity(..., VISION_TYPE_DIE)` | `VISION_TYPE_DIE` |

给脚本层一个更实用的结论：

- 你不需要直接操作 `VisionType`，但你做的 **“创建/移除实体”** 会被映射成某个 `VisionType`，进而影响客户端表现（例如消失动画/刷新逻辑）。
- 如果你发现某些玩法脚本依赖“特定 VisionType 的客户端副作用”，那就属于“脚本层想要更强控制力”的需求，可能需要下潜实现相关 ScriptLib（见下一节）。

---

## 23.6 Lua 侧“视野/显隐控制”API 的实现现状（缺口会影响 Common 模块可跑性）

`ScriptLib` 中与“玩家视野/组视野”相关的接口，在本仓库里有明显缺口：

- `AddPlayerGroupVisionType` / `DelPlayerGroupVisionType`：当前标注为 unimplemented
- `ForbidPlayerRegionVision` / `RevertPlayerRegionVision`：TODO
- `SetPlayerGroupVisionType`：TODO

这会导致一些上游活动脚本（尤其是需要“只对某些玩家显示/隐藏某些 group 内容”的玩法）无法按预期运作。

在“只改脚本/数据”的约束下，你可用的替代手段通常是：

1. **用 group suite 做显隐**：把要隐藏/显示的 gadgets/monsters 放到不同 suite，通过 `RefreshGroupSuite`/`AddExtraGroupSuite` 进行切换。
2. **用实体删除/重建做显隐**：例如 `RemoveEntityByConfigId` + `CreateGadget/CreateMonster`（但要注意持久化与 oneoff 语义）。
3. **用 SceneTag/OpenState 做客户端侧 gating**：适用于“UI/场景变体”的控制，但它偏进度系统，不是纯渲染显隐（见 `analysis/24-openstate-and-progress-gating.md`）。

---

## 23.7 设计建议：把“显隐问题”拆成你能解决的 3 类

当你想做一个玩法点时，先判断它属于哪类显隐需求：

1. **全体玩家、基于距离的内容出现/消失**  
   - 首选：脚本 Group（受 `checkGroups()` 管控），或者 SpawnData（受 `checkSpawns()` 管控）。
2. **基于剧情阶段/任务阶段的内容出现/消失**  
   - 首选：Group/Suite + 变量；必要时配合 Quest Exec/GroupSuiteNotify（见 `analysis/10-quests-deep-dive.md`）。
3. **仅对部分玩家可见（多人差异化显隐）**  
   - 这是本仓库当前的弱项：缺少 `PlayerGroupVisionType`/RegionVision 的实现。  
   - 若坚持“只改脚本/数据”，往往只能改成“所有人一致”或“房主决定”的玩法；否则就需要改引擎层实现 API/协议包。

---

## 23.8 小结

本仓库的 Streaming 可以用一句话概括：

- **Group（Lua）**：最强编排能力的显隐机制（suite/trigger/变量齐全），也是做自制玩法房间的主力。
- **SpawnData**：大世界生态的距离刷出/刷掉，简单、稳定，但可编排性弱且持久化有限。
- **NPC Born**：通过 `GroupSuiteNotify` 让客户端加载 NPC 套件，是“NPC 显隐”的主路径；不要默认 `EntityNPC` 会像怪/机关一样被服务端生成并同步。

---

## Revision Notes

- 2026-01-31：首次撰写本专题（基于 `Scene.checkGroups/checkSpawns/loadNpcForPlayer` 与 ScriptLib 的 Vision 类 API 状态）。

