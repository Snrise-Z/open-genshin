# 45 专题：Energy/元素能量系统：技能产球/怪物掉球/普攻概率 → 能量球道具 → 充能倍率

本文把“元素能量（Energy）”当成一个典型的 ARPG 战斗资源系统来拆：  
它由 **能量来源（Sources）** 与 **能量结算（Gain/Consume）** 两部分构成，并且与“掉落物实体（EntityItem）”和“ItemUseAction”强关联。

与其他章节关系：

- `analysis/31-ability-and-skill-data-pipeline.md`：技能产球走 Ability invoke（`AbilityActionGenerateElemBall`），属于 Ability 管线的一部分。
- `analysis/16-reward-drop-item.md`：能量球本质是 Item 掉落实体，被拾取时走 ItemUse 行为。

---

## 45.1 抽象模型：Energy = 多源输入 + 队伍分配 + 充能倍率 + 爆发消耗

中性 ARPG 视角下，你可以把它拆成：

1. **Sources（来源）**
   - 技能产球（按角色与技能）
   - 普攻/重击产能（按武器类型概率）
   - 怪物掉球（按怪物血量阈值/击杀）
2. **Carrier（载体）**
   - 能量球/能量微粒作为“可拾取的掉落实体”
3. **Distribution（分配）**
   - 场上角色获得全额，后台角色获得折算
   - 同元素获得更多，不同元素更少（由道具 useParam 决定）
4. **Scaling（倍率）**
   - 能量球通常受“充能效率（Energy Recharge）”影响
5. **Consume（消耗）**
   - 释放爆发时清空/扣除能量

本仓库的一个关键设计点是：**“拾取能量球＝使用一个特殊道具”**，能量的分配与同/异元素倍率被做进了 ItemUseAction。

---

## 45.2 数据层入口：两份 `data/*.json` 控制产球数量与怪物掉球

### 45.2.1 `data/SkillParticleGeneration.json`：技能产球数量概率

加载入口：`EnergyManager.initialize()`

结构（从 `SkillParticleGenerationEntry` 反推）：

```text
[
  {
    "avatarId": <int>,
    "amountList": [
      { "value": <int>, "chance": <int> },
      ...
    ]
  }
]
```

语义：

- 当某角色技能触发 `AbilityActionGenerateElemBall` 时：
  - 先 roll 一个 0..99
  - 按 amountList 的 chance 累加区间选出 `value` 作为“生成多少个球”
- 若找不到该 avatarId 的配置：
  - 默认生成 2 个，并记录 warn 日志

### 45.2.2 `data/EnergyDrop.json`：怪物掉球映射表（dropId → ballId/count 列表）

结构（从 `EnergyDropEntry` 反推）：

```text
[
  {
    "dropId": <int>,
    "dropList": [
      { "ballId": <itemId>, "count": <int> },
      ...
    ]
  }
]
```

语义：

- 怪物的 `hpDrops/killDropId`（来自怪物数据）给出一个 dropId
- `EnergyDrop.json` 把 dropId 翻译成“在怪物位置生成哪些能量球道具”

注意：

- `ballId` 必须能在 `GameData.getItemDataMap()` 找到，否则会被跳过（不会生成实体）

---

## 45.3 引擎侧核心类：`EnergyManager`

文件：`Grasscutter/src/main/java/emu/grasscutter/game/managers/energy/EnergyManager.java`

它在服务器启动时初始化（`GameServer` 中调用 `EnergyManager.initialize()`），并在运行时提供四类能力：

1. 技能产球：`handleGenerateElemBall(AbilityInvokeEntry)`
2. 普攻/重击产能：`handleAttackHit(EvtBeingHitInfo)`
3. 怪物掉球：`handleMonsterEnergyDrop(monster, hpBefore, hpAfter)`
4. 爆发消耗：`handleEvtDoSkillSuccNotify(session, skillId, casterId)` → `handleBurstCast`

---

## 45.4 技能产球：`AbilityActionGenerateElemBall` → 角色元素 → 生成对应能量球 itemId

入口：`EnergyManager.handleGenerateElemBall(invoke)`

关键步骤：

1. 解析 action：`AbilityActionGenerateElemBall.parseFrom(invoke.getAbilityData())`
2. 找到“真正的施法者 avatar”：
   - `getCastingAvatarEntityForEnergy(invokeEntityId)`
   - 支持 `EntityClientGadget`：通过 `getOriginalOwnerEntityId()` 追溯到角色实体
3. 决定产球数量：
   - `amount = getBallCountForAvatar(avatarId)`（来自 `SkillParticleGeneration.json`）
4. 决定能量球 itemId（按元素映射）：
   - Fire/Water/Grass/Electric/Wind/Ice/Rock → `2017..2023`
   - None/未知 → `2024`
5. 在 action.pos 位置生成 `amount` 个 `EntityItem`

这条链路的意义在于：**“技能产球数量”被彻底数据化了**（SkillParticleGeneration），而“球的元素类型”由角色元素决定。

---

## 45.5 普攻/重击产能：按武器类型的概率爬升模型（近似实现）

入口：`EnergyManager.handleAttackHit(EvtBeingHitInfo hitInfo)`

筛选条件（实现非常关键）：

- 攻击者必须是当前前台角色
- 目标必须是怪物（普通/BOSS）
- `AttackResult.abilityIdentifier == defaultInstance`  
  - 这被当作“普通/重击”的近似判定（代码注释承认不完全准确，尤其对部分重击与法器普攻）

能量生成逻辑：`generateEnergyForNormalAndCharged(EntityAvatar attacker)`

核心机制：

- 为每个角色实体维护一个“当前概率”：
  - `avatarNormalProbabilities: Map<EntityAvatar, int>`
- 概率按武器类型决定：
  - `WeaponType.getEnergyGainInitialProbability()`
  - `WeaponType.getEnergyGainIncreaseProbability()`
- 每次命中 roll：
  - 成功 → `avatar.addEnergy(1.0f, PropChangeReason.ABILITY, isFlat=true)` 并重置概率
  - 失败 → 概率 += increase（下一次更容易触发）

注意：这是一个“近似复刻官方描述”的实现，注释里也列出了多个 open questions（概率重置时机/切人/命中计数等）。

---

## 45.6 怪物掉球：基于血量阈值（HpDrops）与击杀掉落（KillDropId）

入口：`EnergyManager.handleMonsterEnergyDrop(monster, hpBefore, hpAfter)`

流程：

1. 只处理 MonsterType 为 ORDINARY/BOSS 的实体
2. 计算伤害前后血量比例 `thresholdBefore/thresholdAfter`
3. 遍历怪物数据里的 `hpDrops`：
   - 若某个 `hpPercent` 被跨越（before > threshold >= after）
   - 用 `dropId` 去 `EnergyDrop.json` 找 `dropList`
   - 在怪物位置生成对应能量球实体
4. 若被击杀且 `killDropId!=0`：同样生成一次 kill 掉球

对内容层而言，这条链路意味着：

- 你可以通过改怪物数据（hpDrops/killDropId）+ 改 `EnergyDrop.json` 来调“掉球类型与数量”

---

## 45.7 能量球如何“加到角色身上”？关键在 ItemUseAction（不是 EnergyManager）

能量球/能量微粒作为 `EntityItem` 被拾取后，最终会走“使用道具”的逻辑。  
能量增加与队伍分配在这里完成：

### 45.7.1 通用基类：`ItemUseAddEnergy`

文件：`Grasscutter/src/main/java/emu/grasscutter/game/props/ItemUseAction/ItemUseAddEnergy.java`

关键语义：

- `ITEM_USE_TARGET_CUR_AVATAR`：只给前台
- `ITEM_USE_TARGET_CUR_TEAM`：给全队
  - 前台全额
  - 后台按队伍人数折算（2 人 0.8、3 人 0.7、4 人 0.6）

并且能量球会使用：

- `PropChangeReason.PROP_CHANGE_REASON_ENERGY_BALL`

### 45.7.2 同/异元素倍率：`ItemUseAddElemEnergy`

文件：`Grasscutter/src/main/java/emu/grasscutter/game/props/ItemUseAction/ItemUseAddElemEnergy.java`

useParam 语义（从构造器读出）：

- `useParam[0]`：元素类型值（ElementType）
- `useParam[1]`：同元素获得的能量值
- `useParam[2]`：异元素获得的能量值

这正是“同元素吃球更赚”的官方范式。

### 45.7.3 充能倍率（Energy Recharge）

能量实际写入在：

- `EntityAvatar.addEnergy(amount, reason, isFlat)`

当 `isFlat=false`（能量球路径就是 false）：

- `amount *= FIGHT_PROP_CHARGE_EFFICIENCY`

也就是说：**充能效率是通过“拾取能量球时的加能量”实现的**。

---

## 45.8 爆发能量消耗：释放技能成功时清空能量

入口：

- `EnergyManager.handleEvtDoSkillSuccNotify(session, skillId, casterId)`

最终在 `handleBurstCast(avatar, skillId)`：

- 若开启能量系统（全局 `GAME_OPTIONS.energyUsage` 且玩家 `energyUsage=true`）
- 且 skillId 被判定为 burst（两条路径）：
  - `skillId == avatar.skillDepot.energySkill`
  - 或 `AvatarSkillData.costElemVal > 0`（用于状态切换导致 skillId 变化的情况）
- 则 `avatar.getAsEntity().clearEnergy(ChangeEnergyReason.SKILL_START)`

这条链路告诉你一个核心事实：  
**“能量是否消耗”主要是系统开关与技能识别逻辑决定的，不在配表里。**

---

## 45.9 “只改数据”能做什么？哪些要下潜引擎？

### 45.9.1 只改数据可做

- 技能产球数量曲线：改 `data/SkillParticleGeneration.json`
- 怪物掉球映射：改 `data/EnergyDrop.json`
-（更进一步）能量球的同/异元素能量值与分配方式：
  - 主要在 item use action（`ItemUseAddElemEnergy/ItemUseAddAllEnergy`）的 useParam 与 useTarget
  - 这通常意味着要改 ItemExcel/Item 数据（属于资源/表层工作）

### 45.9.2 明显引擎边界

- 更准确的“普攻/重击识别”与武器/角色差异（目前是近似实现）
- 武器被动产能（代码注释明确 TODO）
- 能量系统的反作弊/一致性（例如重复 invoke、切人时机、离线同步）

---

## 45.10 小结

- 本仓库把“能量球”当作 Item 掉落实体，拾取后用 ItemUseAction 完成同/异元素倍率与队伍分配，这是非常可迁移的设计。
- `SkillParticleGeneration.json` 与 `EnergyDrop.json` 给了你两个最重要的“内容调参口”：技能产球数量与怪物掉球映射。
- 普攻产能与武器被动产能目前属于“近似/未完备”实现；如果你要把它当成通用 ARPG 引擎模块，这两块是优先的引擎增强点。

---

## Revision Notes

- 2026-01-31：首次撰写本专题；梳理 `EnergyDrop/SkillParticleGeneration → EnergyManager（三种产能来源）→ EntityItem 能量球 → ItemUseAddEnergy（分配/同异元素）→ 充能倍率与爆发清空` 的完整链路。

