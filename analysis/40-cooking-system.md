# 40 专题：Cooking/烹饪系统：Recipe → QTE 品质 → 熟练度 → 特色料理替换

本文把“烹饪（Cooking）”当成一个典型的 **配方转换系统（Recipe Transform）+ 轻度成长（熟练度）** 来拆：  
它和锻造/炼金相比更偏“即时行为”（带 QTE 品质），同时还有一个非常内容化的机制：**角色特色料理替换**。

与其他章节关系：

- `analysis/16-reward-drop-item.md`：烹饪产出与消耗都是 Item（`payItems` 与 `addItem`）。
- `analysis/41-combine-and-compound.md`：对比“炼金（Compound）”的计时队列；烹饪本身是即时结算。

---

## 40.1 抽象模型：Cooking = Recipe + Quality + Proficiency + Specialty

用中性 ARPG 语言描述，一个“烹饪”系统一般包含：

- **Recipe（配方）**：输入材料 → 输出（通常分多种品质）
- **Quality（品质）**：一次操作的表现（QTE/自动烹饪/完美等）决定用哪一档输出
- **Proficiency（熟练度）**：玩家对该配方的成长值（影响自动/完美率、解锁等；本仓库目前只做“记录+上限”）
- **Specialty（特色料理）**：由“辅助角色”触发，把部分产出替换成特殊料理

本仓库的实现把这些拆得很清楚：Recipe/Bonus 主要来自 ExcelBinOutput，玩家状态是一个 `Map<recipeId, proficiency>`。

---

## 40.2 数据依赖清单：配方与特色都在 ExcelBinOutput

### 40.2.1 `resources/ExcelBinOutput/CookRecipeExcelConfigData.json`

对应资源类：`Grasscutter/src/main/java/emu/grasscutter/data/excels/CookRecipeData.java`

关键字段：

- `id`：`recipeId`
- `rankLevel`：料理星级（也会影响特色概率，见 40.6）
- `isDefaultUnlocked`：是否默认解锁（见 40.4）
- `maxProficiency`：熟练度上限
- `inputVec: List<ItemParamData>`：输入材料
- `qualityOutputVec: List<ItemParamData>`：按品质分档的输出列表

### 40.2.2 `resources/ExcelBinOutput/CookBonusExcelConfigData.json`

对应资源类：`Grasscutter/src/main/java/emu/grasscutter/data/excels/CookBonusData.java`

它按 `avatarId` 索引（`getId()` 返回 avatarId），常用字段：

- `avatarId`：触发特色的角色
- `recipeId`：该角色对应的配方
- `paramVec[0]`：替换产出的 itemId（`getReplacementItemId()`）

你可以把 CookBonus 视为一个非常通用的“**角色-配方挂钩器**”：  
它把“角色特色”数据化，而不是写死在技能或脚本里。

---

## 40.3 引擎侧核心类：`CookingManager`

文件：`Grasscutter/src/main/java/emu/grasscutter/game/managers/cooking/CookingManager.java`

它做三类事：

1. **初始化默认解锁集合**
   - `CookingManager.initialize()` 在服务器启动时执行（见 `GameServer`）
   - 扫描所有 `CookRecipeData`，把 `isDefaultUnlocked=true` 的 recipeId 放进 `defaultUnlockedRecipies`
2. **维护玩家的解锁与熟练度**
   - `Player.unlockedRecipies: Map<recipeId, proficiency>`
3. **处理烹饪请求与下发 UI 数据**
   - `sendCookDataNotify()`：登录/进入烹饪界面时下发已解锁配方与熟练度
   - `handlePlayerCookReq(PlayerCookReq)`：执行一次烹饪并结算

---

## 40.4 配方解锁：默认解锁 + 道具解锁（完全可数据化）

### 40.4.1 默认解锁：`isDefaultUnlocked`

`sendCookDataNotify()` 会先调用 `addDefaultUnlocked()`：

- 把 `defaultUnlockedRecipies` 中缺失的 recipeId 补进玩家的 `unlockedRecipies`（熟练度=0）

这意味着：

- 你只要把某个 recipe 配成 `isDefaultUnlocked=true`，玩家第一次登录/同步烹饪数据时就会自动拥有它。

### 40.4.2 道具解锁：`ItemUseUnlockCookRecipe`

文件：`Grasscutter/src/main/java/emu/grasscutter/game/props/ItemUseAction/ItemUseUnlockCookRecipe.java`

它提供了一个非常内容友好的入口：

- 道具 useParam 携带 `recipeId`
- 使用后 `postUseItem()` 调 `player.getCookingManager().unlockRecipe(recipeId)`

因此你可以“只改数据/脚本”去编排配方解锁：

- 任务奖励发“食谱道具”
- 商店售卖“食谱道具”（见 `analysis/38`）
- 活动兑换“食谱道具”

而不需要写任何 Java。

---

## 40.5 一次烹饪请求的结算：扣材料 → 选品质 → 发放产出 → 增加熟练度

入口：`CookingManager.handlePlayerCookReq(PlayerCookReq req)`

关键步骤（按执行顺序）：

1. 读取请求参数：
   - `recipeId`
   - `qteQuality`（品质）
   - `cookCount`（次数）
   - `assistAvatar`（辅助角色，用于特色）
2. 取配方：`CookRecipeData recipeData`
3. 取玩家熟练度：`proficiency = unlockedRecipies.getOrDefault(recipeId, 0)`
4. 扣材料：
   - `player.getInventory().payItems(recipeData.getInputVec(), count, ActionReason.Cook)`
5. 按品质选输出（见 40.6）：
   - `resultParam = qualityOutputVec[qualityIndex]`
6. 处理特色替换（见 40.7）：
   - 统计 `specialtyCount`
   - 输出分成“普通产出 + 特色产出”
7. 熟练度增长：
   - 仅当 `qteQuality == 3`（手动完美）才 `proficiency++`，并 clamp 到 `maxProficiency`
8. 回包：`PacketPlayerCookRsp`

你可以把它抽象成：

```text
cook(recipeId, quality, count, assistAvatar):
  pay(inputVec * count)
  output = qualityOutput[quality] * count
  output' = applySpecialty(output, assistAvatar)
  if quality == PERFECT: proficiency++
  give(output')
```

---

## 40.6 品质（QTE）与 `qualityOutputVec` 的索引规则：一个容易踩坑的点

实现中的索引计算：

- `qualityIndex = (quality == 0) ? 2 : (quality - 1)`

含义（从代码行为反推）：

- `qteQuality=1` → 取 `qualityOutputVec[0]`
- `qteQuality=2` → 取 `qualityOutputVec[1]`
- `qteQuality=3` → 取 `qualityOutputVec[2]`
- `qteQuality=0` → 也取 `qualityOutputVec[2]`（当成“最高档输出”）

因此你在配表时最好保证：

- `qualityOutputVec` 至少有 3 个元素

否则会出现越界或异常表现（客户端/服务端版本差异也可能导致 quality 取值变化）。

---

## 40.7 特色料理（CookBonus）：按次数独立抽取，按星级给概率

特色机制在 `CookingManager.getSpecialtyChance(ItemData cookedItem)`：

- 1★：25%
- 2★：20%
- 3★：15%
- 其他：0

触发条件：

1. `bonusData = GameData.getCookBonusDataMap().get(assistAvatar)`
2. 且 `recipeId == bonusData.recipeId`

触发方式：

- 对每一次烹饪（`count` 次）独立 roll
- 命中的次数计为 `specialtyCount`
- 被替换的产出使用：
  - `replacementItemId = bonusData.paramVec[0]`
  - 数量仍用 `resultParam.count`

这套写法的好处是：

- 特色料理完全是“数据驱动 + 少量通用逻辑”，不会让角色系统与烹饪系统强耦合
- 你给新角色加特色，只需要补 CookBonus 表，不需要改代码

---

## 40.8 “只改数据”可以轻松做的扩展

### 40.8.1 新增配方

最常见的两种方案：

1. **默认解锁配方**：在 CookRecipe 表把 `isDefaultUnlocked=true`
2. **食谱道具解锁**：做一个带 `ITEM_USE_UNLOCK_COOK_RECIPE` 的道具，useParam 指向 recipeId（见 40.4.2）

### 40.8.2 新增/修改特色料理

在 CookBonus 表新增：

- `avatarId`
- `recipeId`
- `paramVec[0]=replacementItemId`

即可把某个配方挂到某个角色上。

---

## 40.9 明显的引擎边界（如果你想更“像官方”）

当前实现里，以下方向更像引擎层工作：

- 更严谨的“品质判定”与防作弊（目前服务端直接使用客户端传来的 `qteQuality`）
- 熟练度对自动烹饪/完美率的影响（目前仅记录并增长，不参与概率）
- 更多维度的特色规则（例如不同角色不同概率、或影响额外产量而非替换）

---

## 40.10 小结

- 烹饪系统的内容几乎都在两张表：CookRecipe（配方）+ CookBonus（特色），玩家侧只存 `recipeId → proficiency`。
- 解锁路径是“可数据化”的：默认解锁 + 食谱道具（ItemUseUnlockCookRecipe）。
- 如果你把它当作 ARPG 引擎模块，烹饪是一个很好的“轻系统”案例：规则简单、数据驱动明显、与脚本层耦合极低。

---

## Revision Notes

- 2026-01-31：首次撰写本专题；梳理 CookRecipe/CookBonus 的数据模型、`CookingManager` 的请求结算流程，并补充“食谱道具解锁”作为可编排入口。

