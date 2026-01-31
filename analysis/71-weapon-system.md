# 71 玩家子系统专题：武器（强化 / 突破 / 精炼 / 被动）

本文从“玩家武器界面”视角，拆解 **武器养成** 在 Grasscutter 的数据层与运行时模型：武器基础属性如何随等级曲线成长、突破如何改上限与加成、精炼如何映射到 `EquipAffix`，以及哪些点能靠“只改数据”稳定实现。

与其他章节关系：

- 角色属性总线：`analysis/70-avatar-progression-and-stats.md`
- 圣遗物系统（同样通过 `EquipAffix` 注入）：`analysis/72-reliquary-system.md`
- Ability/OpenConfig 机制：`analysis/31-ability-and-skill-data-pipeline.md`

---

## 71.1 玩家视角：武器界面的 3 件事

1. **强化（提升等级）**：喂矿石/喂武器 → 消耗摩拉 → 武器等级上升 → 基础值随曲线成长
2. **突破（升阶）**：满级后消耗突破材料 → 提高等级上限 + 获得突破加成属性
3. **精炼（提升精炼阶）**：喂同名武器或精炼材料 → 消耗摩拉 → 被动效果强化（服务端用 `EquipAffix` 表驱动）

在 Grasscutter 中，这三件事主要在：

- **数据**：`WeaponExcel` / `WeaponCurve` / `WeaponPromote` / `WeaponLevel` / `EquipAffix`
- **执行**：`InventorySystem.upgradeWeapon/promoteWeapon/refineWeapon`
- **生效**：`Avatar.recalcStats()` 把武器贡献写入角色面板

---

## 71.2 数据层：武器系统的配表拼图

### 71.2.1 武器基础定义（物品表的一部分）：`WeaponExcelConfigData.json`

文件：`resources/ExcelBinOutput/WeaponExcelConfigData.json`（加载为 `ItemData`，itemType=ITEM_WEAPON）

关键字段（内容作者最常改的）：

- `id`：weapon itemId
- `rankLevel`：星级（影响强化经验曲线、圣遗物/武器升级表索引）
- `weaponType`：武器类型（单手剑/双手剑…）
- `weaponProp[]`：基础属性条目（`propType/initValue/type`）
- `weaponPromoteId`：突破配置引用（见下）
- `weaponBaseExp`：当“喂给别的武器当狗粮”时提供的基础经验
- `skillAffix[]`：武器被动的 affix 组（会映射到 `EquipAffix`）
- `awakenMaterial` + `awakenCosts[]`：精炼材料与精炼摩拉成本

### 71.2.2 武器等级曲线：`WeaponCurveExcelConfigData.json`

文件：`resources/ExcelBinOutput/WeaponCurveExcelConfigData.json`（加载为 `WeaponCurveData`）

用于把 `weaponProp.initValue` 乘上某种倍率：

- `WeaponCurveData.getMultByProp(type)`：按 `weaponProp.type` 查倍率

### 71.2.3 突破配置：`WeaponPromoteExcelConfigData.json`

文件：`resources/ExcelBinOutput/WeaponPromoteExcelConfigData.json`（加载为 `WeaponPromoteData`）

核心字段：

- `weaponPromoteId` + `promoteLevel`
- `unlockMaxLevel`：该突破阶段武器等级上限
- `costItems[]` + `coinCost`：突破消耗
- `addProps[]`：突破额外属性（常见：副词条、基础攻击提升等）

二级 key：`(weaponPromoteId << 8) + promoteLevel`

### 71.2.4 强化经验需求：`WeaponLevelExcelConfigData.json`

文件：`resources/ExcelBinOutput/WeaponLevelExcelConfigData.json`（加载为 `WeaponLevelData`）

- `requiredExps[]`：一个数组，Grasscutter 通过 `rankLevel-1` 取对应星级的每级所需经验

### 71.2.5 武器被动/精炼：`EquipAffixExcelConfigData.json`

文件：`resources/ExcelBinOutput/EquipAffixExcelConfigData.json`（加载为 `EquipAffixData`）

武器被动在 Grasscutter 的核心映射规则：

- 武器 `skillAffix` 存的是“组 ID”（通常一个武器就 1 个）
- 真正生效的 `EquipAffix.id` 通过下式得到：

```
equipAffixId = (skillAffix * 10) + refinement
```

其中：

- `refinement` 在 Grasscutter 里是 **0..4**（0=精炼1，4=精炼5）
- `EquipAffix.addProps`：直接加到角色面板
- `EquipAffix.openConfig`：进一步注入 AbilityEmbryo（见 31）

---

## 71.3 运行时：武器如何贡献到角色面板？

### 71.3.1 武器作为 `GameItem`

武器在数据库里是 `items`（`GameItem`），核心字段：

- `level/exp/totalExp/promoteLevel`
- `refinement`（0..4）
- `affixes`（来自 `WeaponExcel.skillAffix`，过滤掉 0）

### 71.3.2 `Avatar.recalcStats()` 中的武器段落（作者必记）

`Avatar.recalcStats()` 对武器做了 3 类叠加：

1. **基础属性（随等级曲线）**
   - 取 `WeaponCurveData[level]`
   - 对每条 `weaponProp` 做：
     - `propType += initValue * curve.multByProp(type)`
2. **武器突破属性**
   - 取 `WeaponPromoteData(weaponPromoteId, promoteLevel).addProps`
3. **武器被动/精炼（EquipAffix）**
   - 对每个 `affixGroup`：
     - `affixId = affixGroup*10 + refinement`
     - 叠加 `EquipAffix.addProps`
     - 注入 `EquipAffix.openConfig`

这解释了一个很实用的“改表策略”：

- 你想改“副词条数值/突破加成” → 改 `WeaponPromoteExcel`
- 你想改“被动效果” → 改 `EquipAffixExcel`（以及其 `openConfig` 链路）

---

## 71.4 强化 / 突破 / 精炼：服务端执行语义

### 71.4.1 强化：`InventorySystem.upgradeWeapon(...)`

关键语义：

- 经验来源有两类：
  1) 喂武器：`weaponBaseExp + (food.totalExp * 4/5)`
  2) 喂矿石等材料：通过 `ItemUseAction.ITEM_USE_ADD_WEAPON_EXP`
- 摩拉消耗：`moraCost = expGain / 10`
- 等级上限：取当前突破阶段 `WeaponPromoteData.unlockMaxLevel`
- 超出经验会退回矿石（`getLeftoverOres` 通过“weapon exp stone”物品的 exp 值反推）

### 71.4.2 突破：`InventorySystem.promoteWeapon(...)`

突破的关键校验：

- 必须满级：`weapon.level == currentPromoteData.unlockMaxLevel`
- 支付 nextPromoteData 的材料 + coinCost
- 然后 `promoteLevel++`，并触发装备者角色 `recalcStats()`

### 71.4.3 精炼：`InventorySystem.refineWeapon(...)`

精炼规则（重要，容易和“游戏名词”混淆）：

- Grasscutter 内部字段 `refinement` 从 0 开始：
  - `0 = 精炼 1`
  - `4 = 精炼 5`
- 若 `awakenMaterial == 0`：要求喂 **同名武器**
- 若 `awakenMaterial != 0`：要求喂 **精炼材料**（itemId = awakenMaterial）
- 精炼消耗摩拉：`awakenCosts[currentRefinement]`
- 目标精炼等级计算：

```
target = min(oldRefine + feed.refinement + 1, 4)
```

也就是说：服务端允许“喂一把本身已精炼过的武器”，会一次跳更多级（这对自定义资源/GM 流程很常见）。

---

## 71.5 只改数据能做什么？哪些必须改引擎？

### 71.5.1 只改数据能做的（稳定）

- 改基础攻击/副词条曲线：`weaponProp` + `WeaponCurve`
- 改突破上限、突破材料、突破属性：`WeaponPromote`
- 改精炼消耗：`awakenCosts`、`awakenMaterial`
- 改被动效果数值（直接加面板）：`EquipAffix.addProps`

### 71.5.2 高概率需要改引擎的

- 新增一种完全不同的精炼规则（例如多材料、多阶段）
- 让武器被动产生复杂逻辑（如事件触发、条件判断）而不仅是“加属性/注入能力”
  - 这种通常要落到 Ability 系统支持范围；若 Ability 缺口大，就得下潜 Java 或补齐脚本接口

---

## 71.6 常见坑与排查

1. **被动不生效**
   - 排查 `skillAffix` 是否为 0；`EquipAffix.id` 是否存在（按 `affixGroup*10+refinement`）
2. **精炼等级看起来错位**
   - 记住 Grasscutter `refinement` 从 0 开始（0=精1）
3. **强化到一半卡住上限**
   - 上限来自“当前突破阶段”的 `unlockMaxLevel`，不是硬写 90
4. **改了表但不生效**
   - 资源启动时加载并缓存；需要重启服务端（参见 `analysis/02-lua-runtime-model.md`）

---

## 71.7 小结

武器系统在 Grasscutter 的“可编排层”主要体现为：**大量数值都在 ExcelBinOutput，且通过固定映射规则（curve/promote/affix）进入角色属性 pipeline**。  
当你想把它当 ARPG 引擎使用时，武器玩法的“数据可塑性”很强；但想做更复杂的“触发型被动”，仍然要看 Ability/OpenConfig 的覆盖度。

---

## Revision Notes

- 2026-01-31：初稿。明确 `EquipAffix.id = affixGroup*10+refinement(0..4)` 的映射与精炼跳级规则，并把可改点与引擎边界分开说明。

