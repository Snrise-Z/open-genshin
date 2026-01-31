# 72 玩家子系统专题：圣遗物（词条生成 / 强化 / 套装 / 强匣衔接）

本文从“玩家圣遗物界面”视角，拆解 Grasscutter 的 **圣遗物数据模型与强化算法**：主词条/副词条是如何从 depot + 权重生成的，强化时“开新词条/升级词条”在服务端具体做了什么，套装效果如何通过 `EquipAffix` 注入到角色属性/能力里。

与其他章节关系：

- 角色属性总线：`analysis/70-avatar-progression-and-stats.md`
- 武器被动同样走 `EquipAffix`：`analysis/71-weapon-system.md`
- Strongbox/强匣作为“圣遗物回收循环”：`analysis/41-combine-and-compound.md`
- 掉落系统（你怎么获得圣遗物）：`analysis/16-reward-drop-item.md`、`analysis/51-drop-systems-new-vs-legacy.md`

---

## 72.1 玩家视角：圣遗物系统的“真实核心”

玩家看到的圣遗物玩法，抽象成 4 个机制：

1. **部位**：花/羽/沙/杯/冠（对应 equipType/slot）
2. **主词条**：决定一条“主属性随等级增长”的曲线
3. **副词条**：最多 4 条“随机属性”，强化到关键等级会“新增/升级”一次
4. **套装**：2 件/4 件触发一组效果（可能是加面板，也可能注入能力）

Grasscutter 的实现把它拆到多个表，并在运行时做了两件很关键的事：

- **生成**：创建圣遗物时，根据 depot + weight 抽主词条与副词条
- **强化**：达到某些等级点时，执行一次“新增副词条 or 给已有副词条加一次 roll”

---

## 72.2 数据层：圣遗物配表的拼装关系

### 72.2.1 圣遗物基础定义：`ReliquaryExcelConfigData.json`

文件：`resources/ExcelBinOutput/ReliquaryExcelConfigData.json`（加载为 `ItemData`，itemType=ITEM_RELIQUARY）

你最需要关注的字段：

- `id`：圣遗物 itemId
- `equipType`：部位（决定 slot：1..5）
- `rankLevel`：星级（影响经验曲线/主词条成长表）
- `mainPropDepotId`：主词条候选池（depot）
- `appendPropDepotId`：副词条候选池（depot）
- `appendPropNum`：初始副词条数量（常见 3 或 4）
- `addPropLevels[]`：强化到哪些等级时触发一次“副词条增长”（例如 4/8/12/16/20）
- `maxLevel`：等级上限
- `baseConvExp`：当此圣遗物被喂掉时提供的基础经验（亦用于摩拉成本计算）
- `setId`：套装 ID（用于 2/4 件识别）

### 72.2.2 主词条：`ReliquaryMainPropExcelConfigData.json`

文件：`resources/ExcelBinOutput/ReliquaryMainPropExcelConfigData.json`（`ReliquaryMainPropData`）

- `id`：主词条定义 ID（圣遗物实例会把它存为 `mainPropId`）
- `propDepotId`：属于哪个主词条池（对应 `ItemData.mainPropDepotId`）
- `propType`：对应 `FightProperty`
- `weight`：抽取权重

### 72.2.3 副词条（roll）：`ReliquaryAffixExcelConfigData.json`

文件：`resources/ExcelBinOutput/ReliquaryAffixExcelConfigData.json`（`ReliquaryAffixData`）

- `id`：某一次 roll 的“具体条目”（注意：不同 roll 可能是不同 id，但 propType 相同）
- `depotId`：属于哪个副词条池（对应 `ItemData.appendPropDepotId`）
- `propType` + `propValue`：这次 roll 加什么、加多少
- `weight`：当“新增副词条”时的抽取权重
- `upgradeWeight`：当“升级已有副词条”时的抽取权重

### 72.2.4 主词条随等级的成长：`ReliquaryLevelExcelConfigData.json`

文件：`resources/ExcelBinOutput/ReliquaryLevelExcelConfigData.json`（`ReliquaryLevelData`）

这里同时承载两类信息：

- `exp`：每级所需经验（按 rank+level 索引）
- `addProps[]`：某 rank/level 下，各 `FightProperty` 对应的“主词条数值”

Grasscutter 的 key 规则：`(rankLevel << 8) + level`

### 72.2.5 套装：`ReliquarySetExcelConfigData.json` + `EquipAffixExcelConfigData.json`

文件：

- `resources/ExcelBinOutput/ReliquarySetExcelConfigData.json`（`ReliquarySetData`）
  - `setNeedNum[]`：例如 `[2,4]`
  - `equipAffixId`：套装效果的基底 id
- `resources/ExcelBinOutput/EquipAffixExcelConfigData.json`（`EquipAffixData`）
  - 真实效果条目 id 规则：

```
affixId = (equipAffixId * 10) + setIndex
```

其中 `setIndex` 从 0 开始：

- `0`：2 件套
- `1`：4 件套

---

## 72.3 生成：圣遗物实例是怎么“随机出来”的？

对应代码：`Grasscutter/src/main/java/emu/grasscutter/game/inventory/GameItem.java`

当服务端创建一个 `ITEM_RELIQUARY` 的 `GameItem` 时：

1. **主词条**：`GameDepot.getRandomRelicMainProp(mainPropDepotId)`
   - `GameDepot.load()` 会把 `ReliquaryMainPropData` 按 `propDepotId` 组织成带权重的随机池
2. **副词条（初始 N 条）**：`addAppendProps(appendPropNum)`
   - 若当前副词条数量 `<4`：走 “新增副词条”
   - 若已经 `>=4`：走 “升级副词条”（追加一次 roll）

### 72.3.1 “新增副词条”的黑名单逻辑

新增时会排除：

- 已经存在的副词条属性（propType）
- 主词条的 propType（防止主副重复）

然后按 `ReliquaryAffix.weight` 做带权重抽取。

### 72.3.2 “升级副词条”的白名单逻辑（非常关键）

升级并不是“把某条副词条的数值改大”，而是：

1. 先收集当前已有的副词条 propType 作为白名单
2. 在该 depot 的所有 `ReliquaryAffix` 里，挑出 propType 在白名单内的条目
3. 按 `upgradeWeight` 抽一个 affix id，再 **追加到 appendPropIdList**

因此一个“被升级很多次的副词条”，在服务端表现为：

- `appendPropIdList` 里出现多次相同的 propType（但可能不同 id / 不同 propValue）
- 计算面板时把这些 roll 全部累加（见 72.4.3）

这对内容作者很重要：它决定了你做自定义圣遗物时，应该如何设计 `ReliquaryAffix` 的“离散 roll 档位”。

---

## 72.4 强化：圣遗物升级的服务端算法

对应代码：`Grasscutter/src/main/java/emu/grasscutter/game/systems/InventorySystem.java`（`upgradeRelic`）

### 72.4.1 经验来源与摩拉成本

经验来源：

- 喂圣遗物：`expGain += food.baseConvExp`，并额外继承 `food.totalExp*4/5`
- 喂经验瓶：通过 `ItemUseAction.ITEM_USE_ADD_RELIQUARY_EXP`

摩拉成本（注意口径）：

- `moraCost` 按“未加成的 expGain”累加（圣遗物 baseConvExp 与经验瓶经验是 1:1 转摩拉）
- 之后才会做“随机加成倍率”（见下一节）

### 72.4.2 随机倍率：2 倍/5 倍加成

Grasscutter 这里实现了一个“随机暴击升级”：

- `boost == 100` → `rate = 5`
- `boost <= 9` → `rate = 2`
- 否则 `rate = 1`

然后 `expGain *= rate`。

内容作者要注意：

- 支付摩拉发生在倍率之前，因此倍率是“白赚的经验”；
- 这会让“圣遗物强化成本曲线”与官方体验不同（如果你很在意一致性，属于引擎层需要调整的点）。

### 72.4.3 触发“副词条增长”的等级点

强化循环每升一级，会检查：

- 当前圣遗物的 `ItemData.addPropLevels` 是否包含该 level

包含则计数 `upgrades++`。

强化结束后调用：

- `relic.addAppendProps(upgrades)`

也就是：一次强化可能跨越多个关键等级点，于是会追加多次 roll。

### 72.4.4 面板如何读取这些 roll？

在 `Avatar.recalcStats()` 中：

- 主词条：用 `mainPropId` 找 `ReliquaryMainPropData.fightProp`，再用 `ReliquaryLevelData.getPropValue(fightProp)` 找数值
- 副词条：遍历 `appendPropIdList`，每个 affix 都做一次 `fightProp += propValue`

因此“副词条升级”在数值上天然支持多段叠加。

---

## 72.5 套装：2/4 件效果如何生效？

套装生效链路（作者视角）：

1. 每件圣遗物都有 `ItemData.setId`
2. `Avatar.recalcStats()` 统计各 setId 件数
3. 若件数达到 `ReliquarySetData.setNeedNum[setIndex]`：
   - `affixId = equipAffixId*10 + setIndex`
   - 叠加 `EquipAffix.addProps`
   - 注入 `EquipAffix.openConfig`（作为额外能力胚）

重要差异点：

- 圣遗物套装的 `openConfig` 注入是 **forceAdd=true**：即便 OpenConfigEntries 里没有该键，也会把字符串放进能力列表（是否真有效取决于 Ability 管线是否识别）。

---

## 72.6 只改数据能做什么？哪些必须改引擎？

### 72.6.1 只改数据能做的（稳定）

- 改主词条权重：`ReliquaryMainProp.weight`
- 改副词条池与 roll 档位：`ReliquaryAffix.propValue/weight/upgradeWeight`
- 改“哪些等级点触发副词条增长”：`ItemData.addPropLevels`
- 改主词条数值随等级曲线：`ReliquaryLevelExcelConfigData.addProps`
- 改套装效果：`EquipAffix.addProps/openConfig`

### 72.6.2 高概率需要改引擎的

- 完全重写“副词条升级算法”（例如官方那种“升级只在已有 4 条里随机 +1 档”更复杂的规则）
- 改强化倍率逻辑、或让倍率与消耗联动
- 做“动态副词条上限/特殊词条行为”（目前实现基本固定）

---

## 72.7 常见坑与排查

1. **权重缺失导致生成异常**
   - `GameDepot.load()` 会在权重池为空时报错：主词条/副词条权重缺失
2. **自定义圣遗物出现主副重复**
   - 排查：你的 `ReliquaryMainProp` 与 `ReliquaryAffix` 是否在同一 `FightProperty` 上过于密集；新增副词条有黑名单，但若 depot 配置本身异常仍可能出问题
3. **套装不生效**
   - 排查：`setId` 是否正确；`ReliquarySetExcel` 是否存在该 setId；`equipAffixId*10+index` 是否在 `EquipAffix` 中存在
4. **改了表不生效**
   - 资源启动时加载；且 `GameDepot` 会缓存主副词条随机池 → 改完需要重启

---

## 72.8 小结

圣遗物系统在 Grasscutter 中非常“数据化”：

- 生成完全由 depot + weight 决定
- 强化在固定等级点追加 roll（以“appendPropIdList 追加条目”的方式表达升级）
- 套装通过 `EquipAffix` 进入角色属性与能力 pipeline

这套设计非常像一个小 DSL：你只要掌握 “depot/weight/affixId 规则”，就能稳定做出大量自定义装备内容。

---

## Revision Notes

- 2026-01-31：初稿。把“新增副词条 vs 升级副词条”明确为黑名单/白名单 + 权重抽取，并指出升级是“追加 roll”而不是就地增量。

