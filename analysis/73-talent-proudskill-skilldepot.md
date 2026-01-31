# 73 玩家子系统专题：天赋（技能仓库 SkillDepot / 天赋等级 ProudSkill / 固有天赋）

本文从“玩家天赋界面（普通攻击/元素战技/元素爆发/被动）”视角，拆解 Grasscutter 的天赋系统：**SkillDepot 如何定义一个角色的技能集合**、天赋等级如何映射到 `ProudSkill` 表、突破如何解锁固有天赋，以及这些数据如何进入 Ability 管线与角色属性计算。

与其他章节关系：

- 角色属性总线（天赋 addProps 如何影响面板）：`analysis/70-avatar-progression-and-stats.md`
- 命之座（会对天赋等级/技能次数产生额外修饰）：`analysis/74-constellation-and-openconfig.md`
- Ability 管线（abilityName/openConfig 最终怎么“变成技能效果”）：`analysis/31-ability-and-skill-data-pipeline.md`

---

## 73.1 玩家视角：天赋界面到底在操作什么？

玩家在天赋界面常做的事：

1. 查看技能说明（文案/图标/冷却/充能）
2. 升级技能等级（消耗材料 + 摩拉，受突破阶段限制）
3. 随突破解锁“固有天赋/被动”（不消耗材料或消耗很少，但需要达到某突破阶段）

在 Grasscutter 中：

- “技能列表属于谁”由 **SkillDepot** 决定
- “升级到几级的效果”由 **ProudSkill** 决定
- “固有天赋解锁条件”由 **SkillDepot.inherentProudSkillOpens** 决定

---

## 73.2 数据层：三张主表 + 两个桥

### 73.2.1 技能仓库：`AvatarSkillDepotExcelConfigData.json`

文件：`resources/ExcelBinOutput/AvatarSkillDepotExcelConfigData.json`（`AvatarSkillDepotData`）

关键字段：

- `id`：skillDepotId（角色表引用它）
- `skills[]`：通常包含普通攻击、元素战技等（具体含义看角色）
- `energySkill`：通常是元素爆发（Grasscutter 用它推断元素类型）
- `subSkills[]` / `extraAbilities[]`：额外技能/能力（更多偏底层）
- `inherentProudSkillOpens[]`：固有天赋解锁表（按突破阶段）
  - `proudSkillGroupId`
  - `needAvatarPromoteLevel`
- `skillDepotAbilityGroup`：用于注入一组 ability embryos（玩家技能组）
- `talents[]`：命之座 talentId 列表（本章不展开，见 74）

### 73.2.2 技能基础信息：`AvatarSkillExcelConfigData.json`

文件：`resources/ExcelBinOutput/AvatarSkillExcelConfigData.json`（`AvatarSkillData`）

你关心的是它如何把“技能”与“天赋等级配置”连起来：

- `id`：skillId
- `abilityName`：能力名（进入 Ability 管线）
- `proudSkillGroupId`：天赋升级的“组 id”（桥接 ProudSkill）
- `maxChargeNum`：技能可用次数（命座可能修改它）
- `costElemType/costElemVal/cdTime`：元素与冷却等（更多偏战斗）

### 73.2.3 天赋等级配置：`ProudSkillExcelConfigData.json`

文件：`resources/ExcelBinOutput/ProudSkillExcelConfigData.json`（`ProudSkillData`）

这是“天赋升级”真正的数值与消耗来源：

- `proudSkillGroupId`：组 id（来自 AvatarSkillData）
- `level`：等级（1..）
- `breakLevel`：突破门槛（promoteLevel 不够不能升）
- `costItems[]` + `coinCost`：升级消耗
- `addProps[]`：升级带来的属性加成（有些天赋会加面板）
- `openConfig`：更重要：注入 ability embryos（技能效果变化、增益等）
- `paramList/paramDescList`：用于描述与参数（很多能力会读 param）

Grasscutter 访问 ProudSkill 的惯例 id：

```
proudSkillId = proudSkillGroupId * 100 + level
```

### 73.2.4 两个“桥”：Ability 与 OpenConfig

从“可编排层”的角度，把天赋系统理解成两条支路：

- `AvatarSkillData.abilityName`：告诉 Ability 系统“这个技能要加载/使用哪个能力配置”
- `ProudSkillData.openConfig`：告诉 OpenConfig/AbilityEmbryo 系统“额外附加哪些能力/修正”

这两条最终都会汇入 Ability 管线（详见 31）。

---

## 73.3 运行时：天赋等级在 Avatar 里怎么存？

对应类：`Grasscutter/src/main/java/emu/grasscutter/game/avatar/Avatar.java`

关键结构：

- `skillLevelMap: Map<skillId, level>`：天赋等级（按 skillId 存）
  - `getSkillLevelMap()` 会只返回当前 skillDepot 的技能，并对缺失项默认填 1
  - 这意味着：**切换 SkillDepot（例如主角换元素）会出现一批新的 skillId，默认 1；旧技能的等级仍保存在 skillLevelMap 里**
- `proudSkillList: Set<proudSkillId>`：固有天赋（按 proudSkillId 存）
- `proudSkillBonusMap`：命座带来的“天赋等级额外 +3”（按 proudSkillGroupId 存，见 74）
- `skillExtraChargeMap`：命座带来的“技能额外次数”（按 skillId 存，见 74）

---

## 73.4 天赋升级：服务端校验与消耗

入口：`Avatar.upgradeSkill(skillId)`

核心校验：

1. `newLevel = old + 1`，且 `newLevel <= 10`（这是升级接口的硬上限）
2. 找 `AvatarSkillData(skillId)`，取 `proudSkillGroupId`
3. 组装 `proudSkillId = groupId*100 + newLevel`，找 `ProudSkillData`
4. 校验突破门槛：`avatar.promoteLevel >= proudSkill.breakLevel`
5. 支付消耗：`proudSkill.getTotalCostItems()`（会把 `coinCost` 自动折成摩拉 itemId=202）

成功后调用 `setSkillLevel(skillId, newLevel)`，并下发技能变更通知。

### 73.4.1 “等级上限到底是多少？”

有两个不同口径：

- `upgradeSkill` 把升级操作限制到 10
- `setSkillLevel` 允许 0..15，但会检查“该 skillId 已知的合法等级集合”
  - 这个合法集合来自 `ResourceLoader.cacheTalentLevelSets()`：按 `ProudSkill` 表中出现过的 level 生成

因此你在做自定义资源时：

- 若你的 ProudSkill 数据里确实有 11..15，且你用 GM/指令直接 setSkillLevel，是可能成功的；
- 但走“正常升级按钮”还是会卡在 10（除非你改引擎逻辑）。

---

## 73.5 固有天赋（被动）：如何随突破解锁？

固有天赋来自 `AvatarSkillDepotData.inherentProudSkillOpens[]`：

- 当 `needAvatarPromoteLevel <= avatar.promoteLevel` 时解锁
- 解锁后得到一个 proudSkillId：

```
proudSkillId = proudSkillGroupId * 100 + 1
```

在 `Avatar.recalcStats()` 中：

- 会把这些 proudSkill 的 `addProps` 叠加到角色面板
- 并把 proudSkill 的 `openConfig` 注入到 extra ability embryos（使其产生更复杂的效果）

作者提示：这就是为什么“只改数据”能做出很多被动效果——只要你的 `openConfig` 在当前实现可用范围内（见 31）。

---

## 73.6 与 Ability 系统的联动：你应该怎么理解？

把“天赋”看成两层：

- **面板层**：`addProps`（直接加属性）
- **行为层**：`openConfig` 与 `abilityName`（驱动技能行为、Buff、事件反应等）

当你发现：

- “天赋等级升了但技能表现没变”

往往不是 ProudSkill 表的问题，而是：

- `openConfig` 指向的能力/配置在服务端未实现或缺失；
- 或 Ability 管线里没有对应 ability 文件/Action 支持；

这类问题应按 `analysis/31-ability-and-skill-data-pipeline.md` 的审计方法排查。

---

## 73.7 只改数据能做什么？哪些必须改引擎？

### 73.7.1 只改数据能做的（稳定）

- 改天赋升级消耗：`ProudSkill.costItems/coinCost`
- 改突破门槛：`ProudSkill.breakLevel`
- 改天赋等级带来的面板加成：`ProudSkill.addProps`
- 改固有天赋的解锁阶段：`SkillDepot.inherentProudSkillOpens.needAvatarPromoteLevel`

### 73.7.2 高概率要改引擎的

- 改“正常升级”上限（10→更高）
- 让天赋升级影响更多服务端逻辑（若 openConfig/ability 覆盖不足）

---

## 73.8 调试与制作建议（强烈建议你用）

- GM 指令：
  - `/talent getid`：打印当前出战角色的技能 id、名称、描述
  - `/talent (n|e|q|all) <level>`：直接设置天赋等级（绕过正常升级按钮限制）
- 验证策略：
  1) 先让 `addProps` 生效（面板可见），确认 pipeline 通
  2) 再做 `openConfig`（行为层），用 Ability 专题的手段逐项验证

---

## 73.9 小结

天赋系统的“稳定骨架”是：

```
SkillDepot 决定技能集合
AvatarSkill 提供 skillId → proudSkillGroupId 的桥
ProudSkill 决定每级消耗/门槛/加成/开放能力(openConfig)
```

对内容作者而言：你可以把 ProudSkill + OpenConfig 当成一个“技能效果 DSL”，而 SkillDepot 则是“把一组 DSL 绑定到角色”的容器。

---

## Revision Notes

- 2026-01-31：初稿。重点解释 `proudSkillId = groupId*100+level` 映射、升级上限的两种口径（upgradeSkill vs setSkillLevel）、以及固有天赋随突破解锁的真实实现。

