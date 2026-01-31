# 30 专题：多人（Co-op）与“房主归属”边界（脚本/数据层必须知道的规则）

本文专门解决一个非常现实的问题：  
**当你把 Grasscutter 当成 ARPG 引擎来写玩法时，多人模式到底“谁是权威”？哪些状态是世界共享？哪些 API 默认只看房主？哪些奖励/掉落会强行归到房主？**

这些边界决定了你是否能“只改脚本/数据”就做出可联机的玩法，还是必须下潜改引擎。

与其他章节关系：

- `analysis/02-lua-runtime-model.md`：Lua 运行时与 ScriptLib（本文会把部分 API 按“作用域”重新分类）。
- `analysis/29-gadget-content-types.md`：Chest/掉落/采集等“多人差异”集中爆发点。
- `analysis/26-entity-state-persistence.md`：GroupInstance/变量/死亡记录的持久化边界（本文会把它放到多人视角下看）。
- `analysis/31-ability-and-skill-data-pipeline.md`：AbilityManager 的 host 归属（多人时经常踩坑）。

---

## 30.1 心智模型：World 有房主（Host），很多系统以 Host 为“世界所有者”

在本仓库里：

- `World.getHost()` 是多人世界的“拥有者”
- `World.isMultiplayer()` 表示当前世界是否为多人（由 `MultiplayerSystem` 创建）
- 同一个 `Scene` 里可以有多个 `Player`，但很多“世界状态/脚本状态/权限判定”会默认以 Host 为基准

关键入口：

- `Grasscutter/.../game/systems/MultiplayerSystem.java`：加入/离开/踢人，决定 host 与 world 组成

---

## 30.2 最重要的三类“状态作用域”

你写玩法时，建议把所有状态按作用域分三类，否则必踩坑：

### A) 世界共享状态（World/Scene 级）

典型包括：

- Group/Suite 的加载与激活（整个 scene 共享）
- Group variables（`ScriptLib.Get/SetGroupVariableValue`）—— **是 group instance 的状态，不是“每玩家一份”**
- Gadget state（`updateState`）—— 会广播给 scene 内所有玩家
- 大世界 Spawn（`Scene.checkSpawns`）与实体是否已被杀/采集（多是 scene 内存状态）

含义：你在 Lua 里做的“关卡阶段机”，天然更像 **世界共享的 FSM**。

### B) 玩家私有状态（Player 级）

典型包括：

- 背包/货币/经验
- QuestManager 的任务列表与任务变量（每玩家一份）
- BattlePass/ActivityData/Achievements（每玩家一份）
- 角色队伍、能量、天赋等

含义：你想做“每个玩家独立推进”的玩法，需要靠这些系统（但脚本层可控性有限）。

### C) Host 视角状态（“看起来像世界共享，但实现上绑定 Host”）

这类最危险，因为它会让你误以为“可对所有玩家生效”，但实际上只读/只写 Host：

- **SceneGroupInstance 的持久化加载**：从 DB 读取 group instance 时使用 `scene.getWorld().getHost()`  
  见 `SceneScriptManager.getCachedGroupInstanceById(...)` / `loadGroupFromScript(...)`
- **部分 ScriptLib API**：直接取 `world.getHost()` 去查询/修改（见下文）
- **部分掉落/奖励归属**：掉落默认发给 host 或 scene.getPlayers().get(0)

含义：多人场景里，你做一些“世界行为”，最终可能只影响房主的数据存档。

---

## 30.3 ScriptLib 在多人世界中的“作用域雷区”

下面列出一些典型例子（不是全量），帮助你快速判断“这个 API 对谁生效”。

### 30.3.1 明确只看 Host 的例子

在 `ScriptLib.java` 中能看到一些函数直接：

- `val player = scene.getWorld().getHost();`

例如：

- `GetHostQuestState(questId)`：读房主的 quest state
- `GetQuestState(entityId, questId)`：当前实现也直接读房主（并未使用 entityId）
- `AddSceneTag(sceneId, sceneTagId)`：写房主的进度管理器（sceneTag/openstate 等）

**影响：**

- 你在 group 脚本里用 `GetQuestState` 来做门槛时，本质是在“按房主门槛”驱动世界玩法；
- 联机客人可能看见世界状态变化，但自己的任务状态并不一定一致。

### 30.3.2 会对“场景内所有玩家”广播/生效的例子

典型代表：`ScriptLib.AddQuestProgress(key)`

当前实现会：

- 遍历 `scene.getPlayers()`，对每个玩家：
  - `playerProgress.addToCurrentProgress(key, 1)`
  - 投递 `QUEST_CONTENT_LUA_NOTIFY` 等任务事件

**影响：**

- 这让很多“联机一起推进任务”的内容变得容易（所有人一起涨进度）
- 但也可能与你希望的“只给交互者推进”相悖（脚本层缺少细粒度控制）

### 30.3.3 取决于“交互者/请求者”的例子

例如采集物（`GadgetGatherObject`）：

- 入包是给 **交互者本人**
- 相对更符合联机直觉

但宝箱（见下节）则是另一套规则。

---

## 30.4 掉落/奖励的多人归属：Chest vs Monster vs “落地掉落”

### 30.4.1 宝箱（Chest）：强房主归属

在 `GadgetChest` 的“普通宝箱新掉落系统”分支里有明确逻辑：

- **只有房主可以开普通宝箱**：`if (player != player.getWorld().getHost()) return false;`

并且 `DropSystem.handleChestDrop(...)` 的归属也偏向 host：

- 不落地：直接加到 `world.getHost().inventory`
- 落地：也以 host 作为掉落拥有者/拾取归属

结论：如果你设计“联机可跑的开箱玩法”，需要：

- 接受“房主专属”这条规则；或
- 自己改脚本/引擎实现“按交互者发奖励”的箱子（通常需要下潜）。

### 30.4.2 怪物掉落：两种模式

在 `DropSystem.handleMonsterDrop`：

- 若掉落配置 `fallToGround=true`：
  - 会把掉落“落地”，并把拥有者设为 `monster.getScene().getPlayers().get(0)`（通常是房主）
- 若不落地：
  - 会直接给 scene 内 **所有玩家** 加到背包

结论：这会导致多人下的怪物掉落体验与配置强相关：

- 想“人人都有”：配置成不落地（或用奖励包方式）
- 想“按拾取/归属”：你需要更完整的掉落所有权模型（引擎侧能力）

### 30.4.3 世界 boss 奖励：按“领奖者本人”

boss chest 的新掉落分支里：

- 会消耗 **交互者** 的树脂（`player.getResinManager().useResin(...)`）
- 并把掉落直接加到交互者背包

这类“个人领奖点”反而更适合联机。

---

## 30.5 GroupInstance 的持久化与多人：为什么“世界 FSM”天然绑定房主存档

`SceneScriptManager` 在加载 group 时会：

- 从 DB 按 `(groupId, hostPlayer)` 读取/保存 `SceneGroupInstance`
- group variables、deadEntities、cached gadget state 等都挂在这个 instance 上

含义：

- 多人世界里，**世界状态的持久化** 通常写进房主存档
- 客人离开世界后，这份世界状态不会跟着客人走

对玩法编排的建议：

- 把 group variables 当成“房主世界的关卡状态”
- 不要把“客人个人进度”存进 group variables（否则会产生跨玩家污染）

---

## 30.6 设计层面的“多人友好”策略（只改脚本/数据能做到的）

这里给一套可操作的策略清单：

1. **把多人玩法拆成两层：世界层 + 个人奖励层**
   - 世界层（group variables / suite / gadget state）：决定“玩法进行到哪一步”
   - 个人层（Quest/BP/ActivityData/Inventory）：决定“谁拿到什么奖励”
2. **奖励尽量走“个人领奖点”**
   - 类似 boss chest / 副本结算点：交互者触发、资源消耗与奖励都在个人侧
3. **推进机制优先使用“全员同步”或“只看房主”两种极端**
   - 全员同步：`ScriptLib.AddQuestProgress`、非落地掉落等
   - 只看房主：`GetQuestState/GetHostQuestState`、宝箱等
   - 中间态（只给交互者推进）在脚本层往往很难优雅实现
4. **明确在玩法文案/规则里“房主权威”**
   - 比如：只有房主能开关机关/领取箱子，但客人可参与战斗/挑战

---

## 30.7 什么时候必须下潜到引擎层？

当你需要以下能力时，通常很难只靠脚本/数据：

- “每个玩家独立的世界状态”（客人自己的机关/宝箱状态）
- “按交互者发箱子奖励、并且支持多人共享开箱但不重复领取”
- “落地掉落的真实归属/拾取权限（每个掉落有 owner/可见性/拾取者）”
- “脚本 API 能精确指定 uid/peer 的奖励与任务推进”

这些属于“多人同步/归属模型”的核心问题，通常要改 Java（见 `analysis/04` 的边界判断）。

---

## 30.8 小结

- 多人世界不是“所有人平等”，很多系统默认以 Host 为世界所有者。
- 你写玩法时要把状态分清楚：世界共享 / 玩家私有 / Host 绑定。
- 宝箱与部分掉落强房主归属；而任务推进（如 AddQuestProgress）又可能默认全员同步。
- 多人友好的玩法设计，往往需要把“世界进度”与“个人奖励”拆层处理。

---

## Revision Notes

- 2026-01-31：首次撰写本专题；从 ScriptLib/DropSystem/GroupInstance 持久化等角度总结多人/房主边界与脚本侧可行策略。

