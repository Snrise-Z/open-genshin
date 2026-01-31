# 29 专题：GadgetContent 类型谱系（交互 → 事件 → 掉落/奖励）

本文聚焦 **EntityGadget 的“内容组件”（GadgetContent）**：当一个 gadget 实体生成到场景里时，引擎会根据 `GadgetExcelConfigData.type`（本仓库用 `EntityType` 表示）挂载不同的内容组件，从而决定：

- 它能不能交互、交互会发生什么；
- 会不会触发 Lua 事件（如 `EVENT_GATHER`）；
- 会不会走掉落/奖励链路；
- 是否受“多人/房主”限制（与 `analysis/30` 强相关）。

与其他章节关系：

- `analysis/15-gadget-controllers.md`：Server/GadgetMapping → `Scripts/Gadget/*.lua` 的“控制器脚本”体系（本文讲的是 **Java 侧内置 content**，不是 controller）。
- `analysis/21-worktop-and-interaction-options.md`：Worktop 选项与 `EVENT_SELECT_OPTION`（本文只把 Worktop 放回 GadgetContent 谱系中）。
- `analysis/16-reward-drop-item.md`：掉落/Reward 的数据链路（本文在 gadget 端说明“何时触发掉落”）。
- `analysis/26-entity-state-persistence.md`：gadget 状态/死亡记录的持久化边界（本文会引用这些结论）。

---

## 29.1 抽象模型：Gadget = 类型（gadgetId）+ 实例（config_id）+ 内容组件（content）

在脚本/数据层你经常同时看到两类 ID：

- `gadget_id`：全局类型 ID（去 Excel/BinOutput 查“它是什么”）
- `config_id`：group 内实例 ID（Trigger/事件里定位“是哪一个实例”）

运行时 `EntityGadget` 会做两步关键绑定：

1. 根据 `gadget_id` 查 `GadgetData`（来自 `GadgetExcelConfigData.json`）
2. 根据 `GadgetData.type`（即 `EntityType`）选择并构造 `GadgetContent`

核心入口：`Grasscutter/src/main/java/emu/grasscutter/game/entity/EntityGadget.java` 的 `buildContent()`。

---

## 29.2 内容组件的选择规则：`GadgetExcelConfigData.type → GadgetContent`

本仓库目前的映射（来自 `EntityGadget.buildContent()`）：

| `GadgetData.type`（EntityType） | 内容组件 | 典型用途 |
|---|---|---|
| `GatherPoint` | `GadgetGatherPoint` | 采集点生成“子采集物” |
| `GatherObject` | `GadgetGatherObject` | 直接采集物（拾取入包 + `EVENT_GATHER`） |
| `Worktop` / `SealGadget` | `GadgetWorktop` | 工作台/交互选项（选项处理见 `analysis/21`） |
| `RewardStatue` | `GadgetRewardStatue` | 副本奖励雕像/结算点 |
| `Chest` | `GadgetChest` | 宝箱/世界 boss 宝箱（掉落/树脂） |
| `Gadget` | `GadgetObject` | 通用 gadget 的临时交互兜底（目前偏“当成采集物”） |
| 其他 | `null` | 不挂内容组件：要么不可交互，要么依赖 controller/Trigger/客户端表现 |

> 关键结论：想“只改脚本/数据”快速做玩法，优先选这张表里有明确 content 的 gadget 类型；否则你要么依赖 `Scripts/Gadget` 控制器脚本，要么要在引擎侧补能力。

---

## 29.3 每个 GadgetContent 的行为剖面（交互/事件/掉落）

下面按组件逐个拆开（只保留对编排最关键的行为点）。

### 29.3.1 `GadgetGatherObject`：采集物（入包）+ `EVENT_GATHER`

入口类：`Grasscutter/.../GadgetGatherObject.java`

关键行为：

- 初始化时确定 `itemId`：
  - 若该 gadget 来自 `SpawnDataEntry`（大世界 Spawn），优先用 `spawnEntry.getGatherItemId()`
  - 否则走 `GatherData`：`GameData.getGatherDataMap().get(gadget.getPointType())`
- 交互 `onInteract`：
  1. `player.getInventory().addItem(itemId, 1, ActionReason.Gather)`
  2. 调用脚本事件：
     - `EventType.EVENT_GATHER`
     - `param1 = config_id`
  3. 广播交互响应包
  4. 返回 `true` → `EntityGadget.onInteract` 会删除该实体（`scene.killEntity(this)`）

**脚本侧怎么用：**

- 在 group gadget 配置里填：
  - `point_type`：指向 `GatherExcelConfigData` 的采集类型（决定产出 item）
- 写 `EVENT_GATHER` trigger，把采集行为串到任务/掉落/阶段机：

```lua
triggers = {
  { name = "gather_1", event = EventType.EVENT_GATHER, source = "", condition = "", action = "action_gather_1" }
}
```

> 多人注意：采集物入包是给“交互者本人”，相对友好；但是否允许客人采集，受 `GatherData.isForbidGuest` 影响（仍需看更完整的权限链路）。

### 29.3.2 `GadgetGatherPoint`：采集点（Spawner）

入口类：`Grasscutter/.../GadgetGatherPoint.java`

它会在构造时：

- 读取 `GatherData` 得到 `gadgetId/itemId`
- 创建一个“子 EntityGadget”（gatherObjectChild），继承父实体的 `groupId/configId/pos/rot/state/metaGadget`
- `scene.addEntity(gatherObjectChild)`

意义：

- 你在脚本上看是一个“点”，引擎实际会生成一个可采集的子实体
- 这也是 Vision/流式加载时容易出现“看见一个，交互另一个”的调试陷阱（见 `analysis/23`）

### 29.3.3 `GadgetWorktop`：工作台/选项容器（交互事件的“接口层”）

入口类：`Grasscutter/.../GadgetWorktop.java`

它本身的 `onInteract` 返回 `false`（不处理“按 F 交互”），关键在于：

- 它维护 `worktopOptions`（`optionId` 集合）
- 通过 `setOnSelectWorktopOptionEvent(handler)` 设置“选项回调”
- 当客户端发送 `SelectWorktopOptionReq` 时，会调用回调

脚本编排要点：

- Worktop 的玩法核心其实是：  
  **给选项 → 玩家选择 → 触发 `EVENT_SELECT_OPTION`（或等效路径）→ action 执行**
- 详见 `analysis/21-worktop-and-interaction-options.md`

### 29.3.4 `GadgetChest`：宝箱 / boss 宝箱（掉落 + 房主限制）

入口类：`Grasscutter/.../GadgetChest.java`

它有两套模式（取决于 `server.game.enableScriptInBigWorld`）：

#### A) 新掉落系统（更偏“脚本数据驱动”）

当启用 `enableScriptInBigWorld` 时：

- 读取 `SceneGadget`（来自 group 脚本的 gadget 配置）
- 根据字段决定掉落：
  - 普通宝箱：`drop_tag` 或 `chest_drop_id`
  - boss 宝箱：`boss_chest` + `drop_tag`（并消耗树脂）
- **多人限制**：普通宝箱有明确 “仅房主可开”（`player != world.getHost()` 直接 return）

开箱成功时：

- 调用 DropSystem 处理掉落
- `updateState(ChestOpened)` 触发 `EVENT_GADGET_STATE_CHANGE`
- 下发开箱相关 packet

#### B) 旧掉落系统（按 chest 类型分发 handler）

未启用新掉落时，会走 `WorldDataSystem` 的 chest interact handler 映射（更偏历史兼容）。

**脚本/数据侧怎么做：**

- 想控制宝箱奖励：优先走新掉落系统
  - 给宝箱 gadget 配 `drop_tag`（推荐）或 `chest_drop_id/drop_count`
  - 掉落具体内容落在 `Server/DropTableExcelConfigData.json` 与 data 的掉落配置（见 `analysis/16`）
- 想做“boss 奖励点”：用 `boss_chest` 字段 + `drop_tag`

> 多人注意：宝箱强绑定“房主归属”，这会影响你设计“联机可完成”的玩法（见 `analysis/30`）。

### 29.3.5 `GadgetRewardStatue`：副本奖励雕像（挑战结算节点）

入口类：`Grasscutter/.../GadgetRewardStatue.java`

行为要点：

- 只在 `scene.getChallenge() instanceof WorldChallenge` 时处理
- 会调用 `DungeonManager.getStatueDrops(...)` 发放奖励（可能消耗浓缩树脂等）
- 不会删除实体（返回 `false`）

用途：

- 这是“副本/挑战玩法”里常见的“结算交互点”
- 数据上你更关注副本/挑战的掉落与结算规则（见 `analysis/18`、`analysis/17`）

### 29.3.6 `GadgetObject`：通用 gadget 的交互兜底（当前实现偏“采集物”）

入口类：`Grasscutter/.../GadgetObject.java`

目前逻辑非常“临时”：

- 尝试从 `GatherData(point_type)` 找到 itemId
- 交互后直接入包 + 触发 `EVENT_GATHER`

这意味着：

- 如果你随便找一个 `EntityType.Gadget` 的 gadgetId，且 `point_type` 没对上 gather 配置，它可能就“无法交互/无产出”；
- 真正复杂的 gadget 行为更应该用：
  - group 脚本 Trigger + ScriptLib（`analysis/02`）
  - 或 `Scripts/Gadget` 控制器脚本（`analysis/15`）

### 29.3.7 `GadgetAbility`：能力 gadget（用于能力系统的 Proto 结构）

入口类：`Grasscutter/.../GadgetAbility.java`

它主要负责在 `SceneGadgetInfo` 里填 `AbilityGadgetInfo`（camp/targetEntityId 等），用于能力/战斗系统的数据结构；对玩法编排而言，通常不是你“改脚本就能直接用”的主入口，但它与 `analysis/31`（Ability 系统）有关。

---

## 29.4 GadgetContent 与 Lua 事件：哪些事件是“默认会发”的？

即使你不写 controller 脚本，`EntityGadget` 也会在关键生命周期发一些 Lua 事件（只要 group/scriptManager 已初始化）：

- `EVENT_GADGET_CREATE`：`EntityGadget.onCreate`
- `EVENT_GADGET_STATE_CHANGE`：`EntityGadget.updateState`（会带 oldState）
- `EVENT_ANY_GADGET_DIE`：`EntityGadget.onDeath`
- `EVENT_GATHER`：`GadgetGatherObject/GadgetObject` 的采集交互

这些事件是你把 gadget 行为接到“关卡阶段机/任务推进”的稳定接口。

---

## 29.5 只改脚本/数据时的选型建议（如何挑 gadgetId）

一个实用的“选型树”：

1. 你要“按 F 交互就给物品/触发事件” → 选 `GatherObject/GatherPoint`（并配置 `point_type`）
2. 你要“选项式交互（开始挑战/开门/切阶段）” → 选 `Worktop/SealGadget`（并维护 optionId）
3. 你要“开箱/领奖点” → 选 `Chest` 或 `RewardStatue`（注意多人归属）
4. 你要“机关行为复杂且可复用” → 走 `Server/GadgetMapping.json` + `Scripts/Gadget/*.lua` 控制器（`analysis/15`）
5. 你要“纯触发器/区域驱动的玩法单元” → gadget 只做表现，逻辑尽量写在 group triggers 里（更通用）

---

## 29.6 小结

- GadgetContent 是 Java 侧“内置内容组件”，决定了一部分 gadget 的交互与事件语义。
- 对“只改脚本/数据”来说，最值钱的是：
  - `Gather*`（采集 → `EVENT_GATHER`）
  - `Worktop`（选项交互 → `EVENT_SELECT_OPTION`）
  - `Chest/RewardStatue`（奖励节点，但有房主/树脂等边界）
- 超出这套 content 覆盖范围的 gadget 行为，通常需要转向：
  - group trigger + ScriptLib
  - 或 `Scripts/Gadget` 控制器脚本体系。

---

## Revision Notes

- 2026-01-31：首次撰写本专题；基于 `EntityGadget.buildContent` 的实际分支，整理了 GadgetContent 类型谱系与脚本/掉落联动要点。

