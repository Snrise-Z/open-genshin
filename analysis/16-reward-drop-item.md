# 16 奖励/掉落/物品专题：从“触发点”到“发放/掉落”的数据驱动链路

本文把奖励与掉落看成编排层的重要输出端：  
玩法脚本/任务系统的最终目的是“改世界状态/给玩家东西”。  
而“给东西”在资源体系里并不是一个点，而是一条链：**触发 → reward/drop id → 配表 → 物品列表 → 发放/掉落表现**。

与其他章节关系：

- `analysis/03-data-model-and-linking.md`：Reward/Drop/Item 的数据目录分层与 ID 映射（本文做深入）。
- `analysis/10-quests-deep-dive.md`：Quest 完成时发主线 rewardIdList/gainItems（本文会解释 RewardExcel 如何落地）。
- `analysis/12-scene-and-group-lifecycle.md`：实体死亡/交互发生在 Scene tick 与实体生命周期里（掉落触发点依赖它）。
- `analysis/14-scriptlib-api-coverage.md`：如果你想用脚本直接发奖励/控制掉落，需要先看 ScriptLib 是否支持。

---

## 16.1 先区分两种“给东西”的模型：Reward vs Drop

在引擎/数据层里它们的差异非常重要：

### Reward（直接发放）

- 输入：`rewardId`
- 输出：一组 `ItemParamData(itemId, count)`
- 结果：直接进背包（Inventory.addItem/addItems）

典型来源：

- 任务线完成奖励（MainQuestData.rewardIdList）
- 成就、活动结算、等级奖励等

### Drop（掉落/掉落表）

- 输入：`dropId` 或 `drop_tag`
- 输出：可能是：
  - 直接给背包（autoPick / fallToGround=false）
  - 或在世界里生成掉落实体（fallToGround=true）

典型来源：

- 怪物死亡掉落
- 宝箱开启掉落
- 可破坏物/采集物的 subfield 掉落

> 魔改角度：Reward 更“稳定、确定”；Drop 更“复杂、有权重、有层级递归”。

---

## 16.2 RewardExcel：奖励表的核心（rewardId → item 列表）

### 16.2.1 数据文件与 Java 映射

- 数据：`resources/ExcelBinOutput/RewardExcelConfigData.json`
- Java：`Grasscutter/src/main/java/emu/grasscutter/data/excels/RewardData.java`

结构（简化）：

```json
{
  "rewardId": 100351,
  "rewardItemList": [
    {"itemId": 102, "itemCount": 225},
    {"itemId": 202, "itemCount": 975},
    {"itemId": 101, "itemCount": 500}
  ]
}
```

注意：文件中常见 `{}` 空对象占位，加载时会被过滤掉（`RewardData.onLoad()`）。

### 16.2.2 Reward 在任务系统里的落地方式（最常见）

主线（parent quest）完成时：

- `GameMainQuest.finish()` 会读取 `MainQuestData.rewardIdList`
- 对每个 rewardId：
  - `RewardData rewardData = GameData.getRewardDataMap().get(rewardId)`
  - `inventory.addItemParamDatas(rewardData.rewardItemList, ActionReason.QuestReward)`

对应代码：

- `Grasscutter/src/main/java/emu/grasscutter/game/quest/GameMainQuest.java`

魔改建议：

1) 想改主线奖励：改 `BinOutput/Quest/<mainId>.json` 的 `rewardIdList` + `RewardExcelConfigData.json`
2) 想改某个“节点奖励”（不是主线结算）：优先看 subQuest 的 `gainItems` 或相关系统的 rewardId 字段

---

## 16.3 DropTable：掉落表（支持权重与递归）

### 16.3.1 两套 DropTable 数据入口（容易混淆）

在本仓库里你会看到两种“掉落表结构”：

1) **GameResource 掉落表**（给 `DropSystem` 用）
   - Java：`emu.grasscutter.data.excels.DropTableData`
   - ResourceType：`DropTableExcelConfigData.json` / `DropSubTableExcelConfigData.json`
2) **Server/DropTableExcelConfigData.json 的直读结构**（给 subfield drop 用）
   - Java：`emu.grasscutter.data.server.DropTableExcelConfigData`
   - 加载：`ResourceLoader.loadSubfieldMappings()` 里读 `resources/Server/DropTableExcelConfigData.json`

它们字段语义很接近：`randomType/dropVec/fallToGround/...`。  
差异主要是“读取方式/使用处不同”。你改数据时，建议把它们当同一个来源：`resources/Server/DropTableExcelConfigData.json`。

### 16.3.2 核心字段（dropId → dropVec）

以 `resources/Server/DropTableExcelConfigData.json` 的结构为例（字段名一致性最高）：

| 字段 | 作用 |
|---|---|
| `id` | dropId（掉落表 ID） |
| `randomType` | 随机类型：0=抽一个；1=每项按概率独立抽取 |
| `dropVec[]` | 掉落项列表：`itemId/countRange/weight` |
| `fallToGround` | true=生成掉落实体；false=直接给背包（由 DropSystem 决策） |
| `dropLevel/nodeType/sourceType/...` | 更细的语义字段（部分在当前实现中未完全用到） |

### 16.3.3 “递归掉落表”：dropVec.itemId 可以是另一个 dropId

`DropSystem.processDrop(...)` 有一段关键逻辑：

- 如果 dropVec 里的 `itemId` 同时也是一个 dropId（dropTable.containsKey(itemId)）
  - 则递归处理该 dropId

这让掉落表可以分层组合（非常像 DSL）：

```
DropTable A
  ├─ itemId = 104001 (直接物品)
  └─ itemId = 460002311 (其实是子 drop 表 id) → 继续展开
```

因此你魔改掉落时要注意：

- `itemId` 不一定真的是物品 id；它可能是“引用另一个 drop 表”

---

## 16.4 DropTag：用字符串把“怪物/宝箱类型”映射到 dropId（按等级分段）

`DropSystem` 除了直接吃 dropId，还支持吃 `drop_tag`：

- `drop_tag` 是一个字符串 key（例如怪物类型名、宝箱玩法类型名）
- 服务端会在 `data/MonsterDrop.json` / `data/ChestDrop.json` 里，根据 `minLevel` 选一个最合适的 dropId

对应代码：

- `Grasscutter/src/main/java/emu/grasscutter/game/drop/DropSystem.java`
  - `queryDropData(dropTag, level, monsterDrop/chestReward)`

数据文件：

- `data/MonsterDrop.json`
- `data/ChestDrop.json`

结构示例（ChestDrop）：

```json
{
  "minLevel": 1,
  "index": "搜刮点解谜通用蒙德",
  "dropId": 20000000
}
```

选择规则（直觉版）：

- 对同一个 `index`（drop_tag），挑 `minLevel <= 当前等级` 的最大 minLevel 条目

魔改意义：

- 你可以不改每个 group 脚本的 dropId，而是改 `drop_tag → dropId` 的映射规则
- 适合做“按世界等级/怪物等级分段”的掉落方案

---

## 16.5 掉落触发点：在哪些行为上会发生 Drop？

### 16.5.1 怪物死亡（大世界）

触发点：`Scene.killEntity(...)`

- 若 target 是 `EntityMonster` 且非 dungeon scene：
  - 优先走新掉落系统：`DropSystem.handleMonsterDrop(monster)`
  - 如果无法解析（dropId 不存在等），fallback 到 legacy：`DropSystemLegacy.callDrop(monster)`

`handleMonsterDrop` 的 dropId 决策优先级：

1) 如果 `SceneMonster.drop_tag` 存在 → 用 `data/MonsterDrop.json` 映射
2) 否则如果 `SceneMonster.drop_id` 存在 → 直接用
3) 否则 fallback 到 `MonsterData.killDropId`

结果：

- 如果掉落表 `fallToGround=true`：生成掉落实体（可见/拾取）
- 否则：直接加到背包（对 scene 玩家）

### 16.5.2 gadget 被击杀/销毁（破坏物掉落）

同样在 `Scene.killEntity(...)`：

- 若 target 是 `EntityGadget` 且 metaGadget 存在：
  - `DropSystem.handleChestDrop(metaGadget.drop_id, metaGadget.drop_count, gadget)`

注意这里用的是 **SceneGadget.drop_id / drop_count**，它更像“击杀掉落”，不等同于“开宝箱掉落”。

### 16.5.3 宝箱开启（交互掉落）

触发点：`GadgetChest.onInteract(...)`

当 `server.game.enableScriptInBigWorld=true` 时，会优先走新掉落逻辑：

- 普通宝箱：
  - 若 `SceneGadget.drop_tag` 存在 → `handleChestDrop(drop_tag, chest.level, bornFrom)`
  - 否则若 `SceneGadget.chest_drop_id != 0` → `handleChestDrop(chest_drop_id, drop_count, bornFrom)`
  - 否则 fallback 到 legacy chest 系统

- boss 宝箱：
  - 依赖 `drop_tag`，并包含树脂/周次数限制等额外逻辑（当前实现仍有 TODO）

> 这解释了为什么 SceneGadget 上同时存在 `drop_id` 与 `chest_drop_id`：  
> 前者偏“击杀/破坏掉落”，后者偏“开启宝箱掉落”。

### 16.5.4 Subfield 掉落（碎裂物/采集物的“部位掉落”）

触发点：`GameEntity.dropSubfield(subfieldName)`  
文件：`Grasscutter/src/main/java/emu/grasscutter/game/entity/GameEntity.java`

它会走三张 Server 映射表：

1) `resources/Server/SubfieldMapping.json`
   - `entityId (gadgetId)` → `subfieldName` → `drop_id`
2) `resources/Server/DropSubfieldMapping.json`
   - `dropId` → `itemId`（这里的 itemId 实际是 drop table id）
3) `resources/Server/DropTableExcelConfigData.json`
   - dropTableId → dropVec（权重/数量范围）

最终效果：

- 在世界中生成 `EntityItem` 掉落（位置在实体附近）

这是“只改数据就能改采集/碎裂掉落”的典型链路。

---

## 16.6 对脚本层最重要的字段：SceneMonster/SceneGadget 的 drop 相关字段

这些字段来自 group 脚本（Lua）：

### 16.6.1 SceneMonster（怪物实例）

Java 结构：`emu.grasscutter.scripts.data.SceneMonster`

| 字段 | 含义 |
|---|---|
| `drop_tag` | 字符串映射 key（走 `data/MonsterDrop.json`） |
| `drop_id` | 直接指定 dropId（走 drop table） |

### 16.6.2 SceneGadget（机关/物件实例）

Java 结构：`emu.grasscutter.scripts.data.SceneGadget`

| 字段 | 常见用途 |
|---|---|
| `drop_id` / `drop_count` | 破坏/击杀 gadget 的掉落（Scene.killEntity 会用） |
| `chest_drop_id` | 开宝箱掉落（GadgetChest 会用） |
| `drop_tag` | 开宝箱掉落（走 `data/ChestDrop.json`），也用于 boss chest |
| `boss_chest` | boss chest 的特殊信息（树脂/怪物绑定等） |

---

## 16.7 魔改工作流：只改数据/脚本怎么改奖励与掉落？

### 16.7.1 改任务线奖励（Reward）

目标：改“完成某主线给什么”

步骤：

1) 找到该 mainQuest 的 `resources/BinOutput/Quest/<mainId>.json`，查看 `rewardIdList`
2) 在 `resources/ExcelBinOutput/RewardExcelConfigData.json` 里修改对应 `rewardId` 的 `rewardItemList`

### 16.7.2 改某个宝箱/机关的掉落（Drop）

目标：改某个具体实例的掉落

路径选择：

- 如果它是“宝箱开启掉落”：
  - 改 `SceneGadget.drop_tag` 或 `SceneGadget.chest_drop_id`
- 如果它是“破坏/击杀掉落”：
  - 改 `SceneGadget.drop_id` / `drop_count`

然后确保：

- 你引用的 dropId 在 drop table 中存在（`resources/Server/DropTableExcelConfigData.json` / `DropSubTable...`）
- 或 drop_tag 在 `data/ChestDrop.json` 有映射

### 16.7.3 改某类怪物的掉落（按 drop_tag 分段）

目标：改“史莱姆/某类怪物掉什么”，并按等级分段

步骤：

1) 确认怪物实例使用了 `drop_tag`（在 group 脚本的 monsters 配置里，或由资源生成器写入）
2) 修改 `data/MonsterDrop.json` 中该 `index` 的 dropId 分段表
3) 如需改掉落内容，再去改 drop table（dropId 对应的 dropVec）

### 16.7.4 改采集/碎裂掉落（Subfield）

目标：改“砍树/挖矿/碎木箱掉什么”

步骤（按 16.5.4 链路）：

1) `resources/Server/SubfieldMapping.json`：
   - 找到 `entityId=gadgetId` 以及 subfieldName（例如 `WoodenObject_Broken`）
   - 改 `drop_id`
2) `resources/Server/DropSubfieldMapping.json`：
   - 把 `dropId` 指向你想要的 dropTableId（字段名叫 itemId）
3) `resources/Server/DropTableExcelConfigData.json`：
   - 改对应 dropTableId 的 dropVec（权重/数量）

---

## 16.8 常见坑与现实约束

1) **enableScriptInBigWorld 开关影响掉落系统路径**
   - 宝箱开启掉落在 `GadgetChest` 中会根据该开关选择新/旧系统
   - 怪物掉落也会在解析失败时 fallback legacy（日志会提示）

2) **drop_id/chest_drop_id/drop_tag 容易混用**
   - 开宝箱优先看 `drop_tag/chest_drop_id`
   - 破坏 gadget 看 `drop_id/drop_count`

3) **drop table 文件是 minified 一行 JSON，不易手改**
   - 你可以用 `jq` 做格式化/局部查询（注意别把整个文件格式化后提交成巨大 diff）
   - 或者用“覆盖表策略”：把你改过的条目抽成更小的自定义加载（需要下潜引擎支持）

4) **掉落递归表要小心循环引用**
   - `DropSystem.processDrop` 是递归的；数据层如果构成循环会造成灾难

---

## Revision Notes

- 2026-01-31：创建本文档（奖励/掉落/物品专题初版）。

