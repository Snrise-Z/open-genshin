# 51 专题：Drop/掉落系统双栈：`DropTableExcel*` + `ChestDrop/MonsterDrop.json`（新）vs `Drop.json`（旧）与触发点语义

本文把“掉落”当成一个可复用的 **概率奖励生成器（Loot Generator）** 来拆：  
它是很多玩法系统的“最后一公里”（怪物死、宝箱开、副本领奖 → 给物品/生成掉落实体）。

本仓库同时存在两套掉落系统：

- **新系统**：`DropSystem`（表驱动 DropTable + drop_tag 映射）
- **旧系统**：`DropSystemLegacy`（`data/Drop.json`，按 monsterId 定义权重区间）

两套系统并存的结果是：你做内容时需要知道“现在这个掉落走的是哪条链路”，否则很容易出现“我改了表但没生效/走了 fallback”。

与其他章节关系：

- `analysis/16-reward-drop-item.md`：从奖励/物品的抽象角度理解掉落（ActionReason、入包/落地、掉落提示）。
- `analysis/29-gadget-content-types.md`：宝箱/采集物/碎裂物等 gadget 的内容类型决定“掉落 vs 直接入包”的差异。
- `analysis/30-multiplayer-and-ownership-boundaries.md`：掉落的“共享/归属/可见性”在多人房间里尤为重要，本仓库实现较简化。
- `analysis/49-resin-and-timegates.md`：树脂领奖（地脉/boss/副本）常与掉落结算绑定。

---

## 51.1 双栈结构：新旧掉落系统分别是什么？

### 51.1.1 新系统 `DropSystem`：DropTable（Excel）为核心

文件：`Grasscutter/src/main/java/emu/grasscutter/game/drop/DropSystem.java`

数据来源：

1. `DropTableExcelConfigData.json` + `DropSubTableExcelConfigData.json`  
   - 映射为 `DropTableData`（`randomType/dropVec/fallToGround/...`）
2. `data/ChestDrop.json`：`drop_tag` → `dropId`（带 `minLevel`）
3. `data/MonsterDrop.json`：`drop_tag` → `dropId`（带 `minLevel`）

它支持：

- 嵌套掉落表（dropVec 中的 id 既可能是 itemId 也可能是 dropTableId）
- 两种随机模式（见 51.3）
- “落地掉落实体 vs 直接入包”（由 `fallToGround` 与 DropMaterialData/虚拟物品规则共同决定）

### 51.1.2 旧系统 `DropSystemLegacy`：按 monsterId 写死的 Drop.json

文件：`Grasscutter/src/main/java/emu/grasscutter/game/drop/DropSystemLegacy.java`

数据来源：

- `data/Drop.json`（按 monsterId → DropDataList）

它的随机方式更像“权重区间抽签”：

- 先 roll `1..10000`
- 命中 `minWeight..maxWeight` 的区间才掉
- 掉落数量在 `minCount..maxCount` 区间随机

它还负责生成 `EntityItem`（落地物），并处理 `give/share` 组合导致的“直接入包”。

---

## 51.2 新系统的数据层：DropTable + `drop_tag` 映射（Chest/Monster）

### 51.2.1 `DropTableData` 结构（ExcelBinOutput）

文件：`Grasscutter/src/main/java/emu/grasscutter/data/excels/DropTableData.java`

关键字段：

- `id`：dropTableId
- `randomType`：随机模式（0/1）
- `dropVec: List<DropItemData>`：候选条目（`id + countRange + weight`）
- `fallToGround: boolean`：是否生成掉落实体（否则直接给背包）
- `everydayLimit/historyLimit/activityLimit`：限额字段（当前实现未处理）

`DropItemData`（`countRange/weight`）：

- `countRange` 支持三种字符串格式（见 51.3.3）

### 51.2.2 `data/ChestDrop.json` / `data/MonsterDrop.json`：把 `drop_tag` 变成 dropTableId

`DropSystem` 在构造时会尝试加载：

- `ChestDrop.json`（用 `ChestDropData` 解析）
- `MonsterDrop.json`（用 `BaseDropData` 解析）

其中共有字段来自：

- `BaseDropData`：`minLevel`, `index`, `dropId`, `dropCount`

你可以把它理解成一个“多档位映射表”：

```text
index = drop_tag
minLevel = 阈值（由调用方传入的 level 与之比较）
dropId = 选择的 DropTableId
dropCount = 调用方是否用得到（新系统多数场景直接传 count 参数）
```

`queryDropData(dropTag, level, rewards)` 的规则是：

- 在同一个 `drop_tag` 下，找出 `minLevel <= level` 且 `minLevel` 最大的那条，取其 `dropId`

因此你要做“随等级提升掉更好”的掉落曲线，就在一个 drop_tag 下写多条 minLevel 档位。

---

## 51.3 新系统的核心算法：两种随机模式 + 嵌套表

### 51.3.1 `randomType == 0`：加权抽 1 个（One-of-N）

逻辑：

- 计算所有条目的 weightSum
- roll `[0, weightSum)`
- 落在某个区间时选中该条目

若条目的 `id` 也是一个 dropTableId，则递归处理（实现“表中套表”）。

### 51.3.2 `randomType == 1`：逐条独立 roll（Many-of-N）

逻辑：

- 对每个条目 roll `rand(0..9999) < weight`
- 命中则掉落该条目（同样支持递归 dropTable）

这更接近“每个候选都有独立概率”的掉落表。

### 51.3.3 `countRange` 的三种语法

`DropSystem.calculateDropAmount` 支持：

1. `"a;b"`：整数闭区间随机（含 b）
2. `"x.y"`：期望值小数（整数部分 + 小数概率进 1）
3. `"n"`：固定整数

对内容层非常实用：你可以用 `"1.5"` 做出“50% 多掉 1 个”的常见配置。

---

## 51.4 掉落在运行时“从哪里被触发”？（决定你该改哪套数据）

### 51.4.1 大世界怪物死亡：`Scene.killEntity` →（新系统失败时）fallback 旧系统

文件：`Grasscutter/src/main/java/emu/grasscutter/game/world/Scene.java#killEntity`

触发条件（注意它非常具体）：

- `target instanceof EntityMonster`
- `sceneType != DUNGEON`
- `monster.getMetaMonster() != null`

然后：

1. 先尝试 `DropSystem.handleMonsterDrop(monster)`
2. 若返回 false，则打印 log 并 `DropSystemLegacy.callDrop(monster)` 作为 fallback

这带来一个“内容层要警惕的边界”：

- **只有 metaMonster 非空时才会走掉落**。  
  如果你用某种方式生成了没有 metaMonster 的怪（例如某些临时生成/脚本缺口场景），即使 `handleMonsterDrop` 本身支持从 `MonsterData.killDropId` 取 dropId，这里也不会调用它。

### 51.4.2 宝箱开启：`GadgetChest.onInteract`（脚本大世界路径）优先新系统

文件：`Grasscutter/src/main/java/emu/grasscutter/game/entity/gadget/GadgetChest.java`

当 `enableScriptInBigWorld=true` 时：

- **普通宝箱**：
  - 只允许房主开（`player == world.host`）
  - 优先 `drop_tag`（按 `chest.level` 选档位）或 `chest_drop_id + drop_count`
  - 成功则更新状态并发 `WorldChestOpenNotify`
- **Boss 宝箱**：
  - 支持两步交互（START/FINISH）
  - 扣树脂（`boss_chest.resin`）后，按 drop_tag 走 `handleBossChestDrop`

若新系统无法处理，会 warn 并 fallback 到 legacy chest handler（见下一节）。

### 51.4.3 宝箱开启：legacy WorldDataSystem chest handlers

当 `enableScriptInBigWorld=false` 或新系统失败时，`GadgetChest` 会走：

- `WorldDataSystem.getChestInteractHandlerMap()`  
  用 `gadgetData.jsonName` 找对应 handler

这里的掉落配置更偏“旧时代的 chest 类型表 + handler 逻辑”，与 `drop_tag`/DropTable 的关系较弱。

### 51.4.4 副本领奖：`DungeonManager.getStatueDrops` 优先新系统，失败 fallback

文件：`Grasscutter/src/main/java/emu/grasscutter/game/dungeons/DungeonManager.java`

流程：

- 先 `handleCost`（树脂/浓缩，见 49 章）
- 新系统：`dropSystem.handleDungeonRewardDrop(dungeonData.statueDrop, doubleReward)`
- 若为空则 fallback 到 legacy `rollRewards()`（基于 DungeonDropData 或 previewItems）

### 51.4.5 Gadget 被“击杀/销毁”：`Scene.killEntity` 的 gadget 分支

`Scene.killEntity` 对 `EntityGadget` 有一个简单分支：

- 若 `gadget.getMetaGadget() != null`，直接 `handleChestDrop(meta.drop_id, meta.drop_count, gadget)`

这更像是“把某些 gadget 当宝箱处理”的简化路径，和 `GadgetChest.onInteract` 的“真正宝箱开启流程”并不完全一致。

---

## 51.5 掉落是“落地实体”还是“直接入包”？

新系统里有两层共同决定：

1. `DropTableData.fallToGround`：表级开关
2. `DropMaterialData.autoPick` / 虚拟物品规则：物品级开关  
   - `DropMaterialData` 来自 `DropMaterialExcelConfigData.json`
   - 若物品是虚拟物品且 `gadgetId==0`，也会被直接入包

`DropSystem.dropItem(...)` 的语义是：

- autoPick/虚拟 → 直接 `giveItem`（入包 + DropHintNotify）
- 否则 → `scene.addDropEntity(...)` 生成拾取物实体

多人共享（share）目前实现很简化：

- `share=true` 时，直接给场景内每个玩家入包并发提示
- “谁能看见掉落实体、谁能拾取”这类精细规则尚未完备

---

## 51.6 内容侧的“新系统掉落编排”工作流（只改数据/脚本）

如果你想尽量使用新系统（DropTable + drop_tag），一个稳定流程是：

1. **选一个 `drop_tag`（字符串）**  
2. 在 `data/ChestDrop.json` 或 `data/MonsterDrop.json` 里为该 `drop_tag` 配置多档位：
   - `minLevel`：阈值（与调用方传入 level 比较）
   - `dropId`：对应 `DropTableExcelConfigData` 的表 id
3. 在 `DropTableExcelConfigData.json`（或 DropSubTable）里创建/修改 `dropId` 对应条目：
   - 选择 `randomType`
   - 配 `dropVec`（itemId 或 子 dropTableId）
   - 配 `countRange/weight`
4. 在场景脚本里引用：
   - 怪物：`SceneMonster.drop_tag`
   - 宝箱：`SceneGadget.drop_tag`（以及 `level`）

排障技巧（非常实用）：

- 如果日志里出现 “Can not solve ... Falling back to legacy drop system.”  
  说明你的 drop_tag 或 dropId 没被正确解析/加载（优先查 `data/*.json` 是否存在、DropTable 是否有该 id）。

---

## 51.7 引擎边界与缺口清单（掉落系统的“真实性”差异来源）

1. **DropTable 的 limit 字段未实现**：`everydayLimit/historyLimit/activityLimit` 目前只是数据，不会限制掉落。
2. **Boss level 表是硬编码**：`DropSystem.bossLevel[]` 用 wiki 硬编码（并不可靠）。
3. **怪物掉落触发依赖 metaMonster**：可能导致部分生成方式的怪没有掉落。
4. **多人共享语义简化**：share 的“可见/拾取/归属”未完整实现。
5. **宝箱系统存在多条并行路径**：脚本大世界 vs legacy handler；你需要先确定当前服务器配置（`enableScriptInBigWorld`）与资源是否匹配。

---

## 51.8 小结

- 掉落系统是本仓库“脚本/数据层”研究里的关键底座：它把场景脚本（drop_tag/drop_id）与奖励表（DropTable）串成一个可配置的 Loot Generator。
- 目前新旧双栈并存，导致内容编排必须先确认“触发点走哪条路径”，否则改表可能不生效。
- 如果你要把它抽象成通用 ARPG 引擎模块，建议把“触发点统一化 + DropTable 限额/归属/多人语义补齐”列为引擎层优先工作。

---

## Revision Notes

- 2026-01-31：首次撰写本专题；梳理 DropSystem（DropTable+drop_tag 映射）与 DropSystemLegacy（Drop.json）双栈结构、随机算法与触发点，并标注 metaMonster 依赖、限额未实现、多人语义简化等关键边界。

