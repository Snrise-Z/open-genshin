# 70 玩家子系统专题：角色（等级 / 突破 / 属性面板）

本文从“玩家在角色界面看到的子系统”视角，拆解 **角色养成（等级、突破、属性计算）** 在 Grasscutter/AGS 资源层的实现：哪些是纯数据驱动、哪些是引擎（Java）硬编码、以及你作为内容作者“只改脚本/数据”能改到什么程度。

与其他章节关系：

- 更偏“战斗/技能底层数据管线”：`analysis/31-ability-and-skill-data-pipeline.md`
- 武器/圣遗物对属性的贡献：`analysis/71-weapon-system.md`、`analysis/72-reliquary-system.md`
- 天赋/命座对属性与能力的贡献：`analysis/73-talent-proudskill-skilldepot.md`、`analysis/74-constellation-and-openconfig.md`
- 进度门槛（OpenState/解锁）：`analysis/56-progress-manager-and-unlocks.md`

---

## 70.1 玩家视角：你在“角色”界面做了什么？

从客户端 UI 行为抽象出最核心的 3 个动作：

1. **升级（等级）**：消耗经验书/材料 + 摩拉 → 角色等级上升 → 角色基础三维随等级曲线增长
2. **突破（升阶/突破等级）**：到达等级上限后，消耗突破材料 + 摩拉 → 解锁更高的等级上限，同时获得“突破加成属性”
3. **看属性面板**：面板展示的是一个“最终汇总值”，来自：
   - 角色基础属性（随等级曲线增长）
   - 突破加成（固定加成/百分比加成）
   - 武器（基础值曲线 + 突破加成 + 精炼/被动）
   - 圣遗物（主词条 + 副词条多段 roll + 套装效果）
   - 天赋/命座/被动（通常通过 OpenConfig → AbilityEmbryo 注入）

在 Grasscutter 的实现里，“升级/突破”基本都落在 **InventorySystem + Avatar.recalcStats()**；Lua 脚本通常不直接参与（除非你在玩法脚本里额外改属性/加 Buff，但那又会回到 Ability 系统专题）。

---

## 70.2 数据层：角色养成用到哪些表？

### 70.2.1 角色基础定义：`AvatarExcelConfigData.json`

文件：`resources/ExcelBinOutput/AvatarExcelConfigData.json`（加载为 `AvatarData`）

你关心的“可控字段”主要是：

- `id`：角色 ID（avatarId）
- `hpBase/attackBase/defenseBase`：基础三维（会乘以成长曲线）
- `critical/criticalHurt/chargeEfficiency`：基础暴击/暴伤/充能等
- `propGrowCurves[]`：告诉引擎“HP/ATK/DEF 分别用哪条曲线”
- `avatarPromoteId`：突破配置引用（见下）
- `skillDepotId` / `candSkillDepotIds`：技能仓库（影响元素类型、技能列表；见 73/75）
- `initialWeapon` / `weaponType`：初始武器类型与默认武器

### 70.2.2 等级成长曲线：`AvatarCurveExcelConfigData.json`

文件：`resources/ExcelBinOutput/AvatarCurveExcelConfigData.json`（加载为 `AvatarCurveData`）

关键点：

- 曲线是按 **level → 一组 curveInfos(type,value)** 存的；
- `AvatarData.onLoad()` 会把 `propGrowCurves` 中声明的 growCurve，映射到每个 level 的倍率数组：
  - `hpGrowthCurve[level]`
  - `attackGrowthCurve[level]`
  - `defenseGrowthCurve[level]`

因此角色基础三维在服务端的核心就是：

```
BaseHP(level)  = hpBase  * hpGrowthCurve[level]
BaseATK(level) = atkBase * atkGrowthCurve[level]
BaseDEF(level) = defBase * defGrowthCurve[level]
```

如果某些 level 缺曲线数据，Grasscutter 会 fallback 到不乘曲线（直接用 base）。

### 70.2.3 突破（升阶）配置：`AvatarPromoteExcelConfigData.json`

文件：`resources/ExcelBinOutput/AvatarPromoteExcelConfigData.json`（加载为 `AvatarPromoteData`）

这是“突破系统”的主表，核心字段：

- `avatarPromoteId`：与角色表对应
- `promoteLevel`：突破阶段（0,1,2...）
- `unlockMaxLevel`：该突破阶段允许的等级上限（例如 20/40/50/60/70/80/90）
- `costItems[]` + `scoinCost`：突破消耗（材料+摩拉）
- `addProps[]`：突破给予的附加属性（例如生命%、攻击%、元素伤等）
- `requiredPlayerLevel`：字段存在，但 **当前实现不校验**（见 70.4.2）

Grasscutter 将其做成二级 key：`(avatarPromoteId << 8) + promoteLevel`。

### 70.2.4 等级经验需求：`AvatarLevelExcelConfigData.json`

文件：`resources/ExcelBinOutput/AvatarLevelExcelConfigData.json`（加载为 `AvatarLevelData`）

- `level` → `exp`：每级所需经验
- Grasscutter 提供 `GameData.getAvatarLevelExpRequired(level)` 查询

经验书/经验材料本身并不是“写死 ID”，而是看物品表的 `ItemUseAction`：

- 材料（`MaterialExcelConfigData.json` 由 `ItemData` 统一承载）
- 其中某些物品会带 `ITEM_USE_ADD_EXP`，用于角色升级（见 70.4.1）

---

## 70.3 运行时：Avatar 的属性是怎么算出来的？

### 70.3.1 两张表：`fightProperties` 与 “复合属性”

Grasscutter 的 `Avatar` 里维护了一张 `fightProperties`（`FightProperty` → float），并在 `recalcStats()` 时重算。

最关键的实现特征：

- 先写入 **Base**（FIGHT_PROP_BASE_HP/ATK/DEF）等，再叠加各来源的 flat/percent；
- 最后统一计算“复合属性”：

```
Result = Flat + Base * (1 + Percent)
```

这意味着：

- 你在配表里改 `addProps`（突破/套装/武器被动）时，要清楚它是加在 **Flat** 还是 **Percent**；
- 同一个属性可能同时存在 base/flat/percent 三条口径（例如生命值）。

### 70.3.2 `recalcStats()` 的“作者心智模型”

把 `Avatar.recalcStats()` 抽象成一个固定 pipeline（伪代码）：

```
recalcStats():
  1) 清空 fightProperties
  2) 写入角色基础三维(随等级曲线)
  3) 叠加突破 addProps
  4) 叠加圣遗物：主词条/副词条
  5) 叠加圣遗物套装：EquipAffix(addProps + openConfig)
  6) 叠加武器：曲线属性 + 突破属性 + 精炼/被动(EquipAffix)
  7) 解锁并叠加“固有天赋”(inherent proud skills)
  8) 叠加 proud skills/被动(openConfig + addProps)
  9) 叠加命座(openConfig)
 10) 计算复合属性(Flat + Base*(1+Percent))
 11) 发送战斗属性与能力变更通知
```

你会发现：**角色升级/突破只负责改变“第 2/3 步的输入”**，最终面板仍然要经过全 pipeline 才是你看到的结果。

---

## 70.4 升级/突破：服务端到底做了什么（关键边界）

### 70.4.1 升级：`InventorySystem.upgradeAvatar(...)`

对应代码路径：`Grasscutter/src/main/java/emu/grasscutter/game/systems/InventorySystem.java`

服务端升级的关键语义：

- 经验来源：通过物品的 `ItemUseAction` 找到 `ITEM_USE_ADD_EXP`，按数量累计 `expGain`
- 摩拉消耗：`moraCost = expGain / 5`
- 等级上限：来自“当前突破阶段”的 `unlockMaxLevel`
- 升级循环：按 `AvatarLevelExcelConfigData` 的每级 `exp` 逐级扣减

因此作为内容作者，你如果只改数据：

- 改“经验书给多少经验”= 改物品的 itemUse（不是改这段 Java）
- 改“每级所需经验”= 改 `AvatarLevelExcelConfigData.json`
- 改“某阶段等级上限”= 改 `AvatarPromoteExcelConfigData.json.unlockMaxLevel`

### 70.4.2 突破：`InventorySystem.promoteAvatar(...)`

突破的关键校验（当前实现）：

- **必须满级**：`avatar.level == currentPromoteData.unlockMaxLevel`
- **支付材料 + 摩拉**：来自 nextPromoteData 的 `costItems + coinCost`
- 然后 `avatar.promoteLevel++`，并 `recalcStats(true)`

注意：`AvatarPromoteExcelConfigData.json` 里的 `requiredPlayerLevel` 字段 **存在但这里没有校验**。  
也就是说：如果你想做“冒险等阶不够不能突破”的规则，当前版本要么改引擎层，要么在内容层通过任务/开放状态把“突破按钮”逻辑从玩法侧规避（但客户端 UI 行为未必完全可控）。

---

## 70.5 作为内容作者：只改数据能做什么？哪些必须改引擎？

### 70.5.1 只改数据能做的（稳定）

- 调整某个角色“手感/强度”的大部分入口：
  - 基础三维与成长曲线（AvatarExcel + AvatarCurve）
  - 突破材料、突破属性、每段等级上限（AvatarPromote）
  - 每级所需经验（AvatarLevel）
- 让某些角色“突破更早/更晚/更贵/更便宜”
- 通过改 `addProps` 做出“突破给新属性”的效果（例如多给暴击/元素精通）

### 70.5.2 必须改引擎层的（高概率）

- 新增一种完全不同的“等级/突破规则”（例如多分支升阶、动态等级上限）
- 让 `requiredPlayerLevel` 真正生效（当前是硬缺口）
- 让升级/突破行为可被 Lua 编排（目前升级是系统协议 + Java 处理）

---

## 70.6 常见坑与排查清单

1. **曲线缺失导致属性不对**
   - 现象：某些等级突然属性异常（接近 base，不随等级增长）
   - 排查：`AvatarCurveExcelConfigData.json` 是否包含对应 level；`propGrowCurves` 是否引用了存在的 curve 名
2. **突破后面板不变**
   - 现象：`promoteLevel` 变了，但属性没变
   - 排查：`AvatarPromoteExcelConfigData.json.addProps` 是否为空；是否正确绑定 `avatarPromoteId`
3. **只改表但服务端无变化**
   - 现象：改了 ExcelBinOutput，重启前无效
   - 原因：资源在启动时加载并缓存（见 `analysis/02-lua-runtime-model.md` 的“缓存/重载”段落）
4. **客户端显示与服务端不一致**
   - 原因：客户端自身也有一套展示/校验；服务端改得太离谱可能出现 UI 异常或被客户端拒绝请求
   - 建议：优先“温和改动 + 小步验证”

---

## 70.7 小结

“角色养成”在 Grasscutter 里是一个非常典型的 **数据驱动 + 固定 pipeline**：

- 升级/突破改变输入数据（等级、突破阶段、材料/消耗）
- 最终面板由 `recalcStats()` 汇总（并且被武器/圣遗物/天赋/命座强烈影响）

对于“把它当 ARPG 引擎用”的改造路线：角色养成优先从 **ExcelBinOutput** 入手；只有当你需要改变规则本身（如冒险等阶限制、复杂升阶分支）才考虑下潜引擎层。

---

## Revision Notes

- 2026-01-31：初稿。聚焦角色升级/突破与属性计算 pipeline，并标出 `requiredPlayerLevel` 目前未校验的实现边界。

