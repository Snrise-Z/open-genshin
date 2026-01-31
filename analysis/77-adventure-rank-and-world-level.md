# 77 玩家子系统专题：冒险等阶 & 世界等级（升级曲线 / 解锁 / 怪物等级缩放）

本文从“玩家冒险等级/世界等级”视角，梳理 Grasscutter 的实现：冒险阅历如何累积并升级、世界等级如何随冒险等阶变化、世界等级如何影响怪物等级（大世界/副本差异），以及哪些点目前是硬编码边界。

与其他章节关系：

- OpenState/解锁与进度门槛：`analysis/56-progress-manager-and-unlocks.md`、`analysis/24-openstate-and-progress-gating.md`
- 地脉/树脂等循环（会产出冒险阅历）：`analysis/32-blossom-and-world-events.md`、`analysis/49-resin-and-timegates.md`
- 大世界刷怪与世界等级：`analysis/35-world-resource-refresh.md`

---

## 77.1 玩家视角：这套系统想表达什么？

从玩家侧抽象，它回答三件事：

1. **我现在整体进度到哪了？**（冒险等阶）
2. **大世界难度是多少？**（世界等级）
3. **升级带来什么？**（功能解锁、奖励、敌人强度变化）

在 Grasscutter 中：

- 冒险等阶 = `PlayerProperty.PROP_PLAYER_LEVEL`
- 冒险阅历 = `PlayerProperty.PROP_PLAYER_EXP`
- 世界等级 = `PlayerProperty.PROP_PLAYER_WORLD_LEVEL`

---

## 77.2 数据层：冒险等阶/世界等级用到哪些表？

### 77.2.1 冒险等阶经验与奖励：`PlayerLevelExcelConfigData.json`

文件：`resources/ExcelBinOutput/PlayerLevelExcelConfigData.json`（`PlayerLevelData`）

常见字段：

- `level`：冒险等阶
- `exp`：到下一等阶所需阅历
- `rewardId`：升级奖励（RewardExcel 体系）
- `expeditionLimitAdd`：派遣上限增量（见 `Player.getExpeditionLimit()` 的累计逻辑）
- `unlockWorldLevel`：理论上的“解锁世界等级”字段（**但当前实现不按它更新世界等级**，见 77.4）
- `unlockDescTextMapHash`：解锁说明文案 hash

### 77.2.2 世界等级 → 怪物等级：`WorldLevelExcelConfigData.json`

文件：`resources/ExcelBinOutput/WorldLevelExcelConfigData.json`（`WorldLevelData`）

- `level`：世界等级
- `monsterLevel`：用于大世界怪物等级缩放的目标等级（或基准）

---

## 77.3 运行时：冒险阅历如何升级？

对应逻辑：`Grasscutter/src/main/java/emu/grasscutter/game/player/Player.java`

核心函数：

- `earnExp(exp)`：按 `config.json` 的 `rates.adventureExp` 乘系数后加阅历
- `addExpDirectly(gain)`：循环升级

升级循环的关键语义：

1. 从 `PlayerLevelData[level].exp` 取当前等级所需经验
2. `exp += gain`
3. while `exp >= reqExp`：
   - `exp -= reqExp`
   - `level++`
   - 每次升级都调用 `setLevel(level)`（确保“升级副作用”触发）
4. 最终把剩余 exp 写回 `PROP_PLAYER_EXP`

### 77.3.1 `setLevel` 的副作用（内容作者关心）

`setLevel` 不只是改一个数字，它还会：

- `updateWorldLevel()`（见 77.4）
- `progressManager.tryUnlockOpenStates()`（开放状态自动解锁）
- `questManager.queueEvent(...)`：
  - `QUEST_CONTENT_PLAYER_LEVEL_UP`
  - `QUEST_COND_PLAYER_LEVEL_EQUAL_GREATER`

也就是说：冒险等阶升级会自动推动“解锁/任务条件”这条链路（内容侧常用）。

---

## 77.4 世界等级更新：当前是硬编码阈值（重要边界）

`Player.updateWorldLevel()` 的实现是一个固定阈值表：

- AR>=20 → WL=1
- AR>=25 → WL=2
- AR>=30 → WL=3
- AR>=35 → WL=4
- AR>=40 → WL=5
- AR>=45 → WL=6
- AR>=50 → WL=7
- AR>=55 → WL=8

这带来两个结论：

1. `PlayerLevelExcelConfigData.unlockWorldLevel` 字段 **当前不会驱动 WL**
2. 如果你只改数据把升级曲线/等级上限改得很离谱，世界等级仍按上述阈值跳变，可能出现“不符合你设计”的难度曲线

把它归类为“引擎边界”会更稳：想要完全数据驱动 WL，需要改 Java。

---

## 77.5 世界等级如何影响怪物等级？

世界等级影响主要出现在 Scene 侧（大世界刷怪/生成实体）：

### 77.5.1 大世界：`Scene.getLevelForMonster(...)`

当不在副本（`DungeonManager == null`）且 `worldLevel > 0` 时：

- 取 `WorldLevelData[worldLevel].monsterLevel`
- 用它作为怪物等级（或 override 基准）

### 77.5.2 生成公式：`Scene.getEntityLevel(baseLevel, worldLevelOverride)`

部分刷怪路径会用一个公式把“配置等级”与“世界等级怪物等级”揉在一起：

```
level = (worldLevelOverride > 0) ? (worldLevelOverride + baseLevel - 22) : baseLevel
level = clamp(level, 1..100)
```

作者提示：

- 这意味着世界等级的 `monsterLevel` 并不总是“直接等于怪物等级”，有时它是参与计算的 override
- 如果你要做非常精确的难度曲线，光改表可能不够，需要结合实际刷怪路径验证

### 77.5.3 副本：DungeonManager 优先

副本里往往走 `DungeonManager.getLevelForMonster(configId)`，世界等级可能不再是决定因素（详见 dungeon 专题）。

---

## 77.6 只改数据能做什么？哪些必须改引擎？

### 77.6.1 只改数据能做的（稳定）

- 改冒险等阶升级曲线：`PlayerLevelExcelConfigData.exp`
- 改升级奖励：`PlayerLevelExcelConfigData.rewardId` → RewardExcel
- 改世界等级对应怪物等级：`WorldLevelExcelConfigData.monsterLevel`

### 77.6.2 高概率要改引擎的

- 让 `unlockWorldLevel` 真正生效（替换硬编码阈值）
- 做“可逆世界等级/手动下调/阶段解锁”更复杂规则（涉及客户端 UI 与状态机）
- 统一/改写怪物等级缩放公式（目前分散在多处）

---

## 77.7 调试与排查建议

- 观察升级副作用：
  - 升级是否触发 OpenState 解锁（见 56）
  - 任务条件是否被满足（QUEST_COND_PLAYER_LEVEL_EQUAL_GREATER）
- 观察世界等级影响：
  - 大世界怪物是否随 WL 改变等级
  - 副本怪物是否不受 WL 影响（优先走副本逻辑）

---

## 77.8 小结

冒险等阶/世界等级在 Grasscutter 的“玩法编排层”里是一个很典型的边界系统：

- 冒险阅历与等级曲线是数据驱动（PlayerLevelExcel）
- 世界等级的“更新规则”目前是硬编码
- 世界等级对怪物等级的影响存在多条路径（大世界/副本不同）

因此你想把它当 ARPG 引擎使用时：

- **先用数据做曲线**（exp/monsterLevel）
- **再决定是否需要改引擎**（WL 规则与缩放公式）

---

## Revision Notes

- 2026-01-31：初稿。指出世界等级更新逻辑当前不读取 `unlockWorldLevel` 的硬编码边界，并总结 WL→怪物等级的两种常见路径。

