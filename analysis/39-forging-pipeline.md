# 39 专题：Forging/锻造系统：`ForgeExcelConfigData` → 队列/锻造点 → 产出/取消/战令

本文把“锻造（Forging）”当成一个标准的 **带队列的计时制造系统（Queued Timed Crafting）** 来拆：  
它和“合成/炼金”（见 `analysis/41`）最大的区别是：锻造以 **“多个并行队列 + 逐个产出时间点”** 为核心玩法。

与其他章节关系：

- `analysis/16-reward-drop-item.md`：锻造产出最终走统一的 Item 入包逻辑。
- `analysis/28-achievement-watcher-battlepass.md`：领取锻造产出会触发战令 `TRIGGER_DO_FORGE`。
- `analysis/41-combine-and-compound.md`：对比“即时合成/炼金队列/强匣分解”的另一条制造管线。

---

## 39.1 抽象模型：锻造 = 配方（Recipe）+ 队列（Queue）+ 资源（Cost）+ 时间（Time）

中性 ARPG 模型可以这样抽象：

- **ForgeRecipe（锻造配方）**：输入材料 + 金币成本 + 锻造点成本 + 单件耗时 + 产出
- **ForgeQueue（队列槽位）**：最多 N 个并行槽位，每个槽位里有一条正在进行的“批量锻造任务”
- **ActiveForge（运行态任务）**：配方 id、开始时间、单件耗时、数量、协助角色（avatarId）
- **Claim（领取）**：按“已完成数量”发放产物；未完成部分继续排队
- **Cancel（取消）**：在未完成时返还材料/金币/锻造点

本仓库的实现几乎就是这个模型的直接映射，非常适合作为你自己引擎的参考实现。

---

## 39.2 数据依赖清单：锻造的“内容”主要在 `ForgeExcelConfigData`

### 39.2.1 `resources/ExcelBinOutput/ForgeExcelConfigData.json`

对应资源类：`Grasscutter/src/main/java/emu/grasscutter/data/excels/ForgeData.java`

关键字段（从 `ForgeData` 反推）：

- `id`：`forgeId`（配方 id）
- `playerLevel`：所需冒险等级（注意：部分 UI/解锁逻辑可能依赖它）
- `showItemId`：UI 展示用 itemId（有时也会作为产出兜底）
- `resultItemId` / `resultItemCount`：产出 itemId 与数量
- `forgeTime`：单件耗时（秒）
- `scoinCost`：金币成本（Mora，itemId=202）
- `forgePoint`：锻造点成本（PlayerProperty）
- `materialItems`：材料列表（ItemParamData）

### 39.2.2 玩家侧关键属性/持久化

锻造点：

- `PlayerProperty.PROP_PLAYER_FORGE_POINT`（见 `Player.getForgePoints()` / `setForgePoints()`）

持久化结构：

- `Player.unlockedForgingBlueprints: Set<Integer>`：已解锁配方
- `Player.activeForges: List<ActiveForgeData>`：进行中的队列任务

---

## 39.3 引擎侧核心类：`ForgingManager` + `ActiveForgeData`

### 39.3.1 `ForgingManager`：玩家侧锻造系统

文件：`Grasscutter/src/main/java/emu/grasscutter/game/managers/forging/ForgingManager.java`

它承担四类职责：

1. **解锁配方（Blueprint Unlock）**
   - `unlockForgingBlueprint(id)`
   - 写入 `unlockedForgingBlueprints`
   - 下发 `PacketForgeFormulaDataNotify`
2. **下发锻造数据（登录/打开 UI）**
   - `sendForgeDataNotify()`
   - `handleForgeGetQueueDataReq()`
3. **开始锻造**
   - `handleForgeStartReq(ForgeStartReq)`
4. **队列操作：领取/取消**
   - `handleForgeQueueManipulateReq(...)`
   - `obtainItems(queueId)` / `cancelForge(queueId)`

### 39.3.2 `ActiveForgeData`：队列任务的最小持久化单元

文件：`Grasscutter/src/main/java/emu/grasscutter/game/managers/forging/ActiveForgeData.java`

它用非常少的字段表达“计时队列”：

- `forgeId` / `avatarId` / `count`
- `startTime` / `forgeTime`

并通过纯计算得到：

- `getFinishedCount(now)`：`(now-startTime)/forgeTime` clamp 到 `count`
- `getTotalFinishTimestamp()`：`startTime + forgeTime*count`
- `getNextFinishTimestamp(now)`：下一件完成时间点（或总完成时间）

这意味着：**没有“逐件计时器”**，完全可以离线计算，非常适合服务端持久化。

---

## 39.4 队列槽位数：不是表里来的，而是“冒险等级分段”

`ForgingManager.determineNumberOfQueues()` 的规则：

- AR ≥ 15 → 4
- AR ≥ 10 → 3
- AR ≥ 5 → 2
- 否则 → 1

注意：`ForgeData.queueNum` 字段在当前实现里并不用于决定“玩家可用队列数”。  
如果你想做更复杂的“解锁更多槽位”机制（建筑/任务/会员），这就是明确的引擎扩展点。

---

## 39.5 开始锻造：扣材料/扣金币/扣锻造点 → 写入 `activeForges`

入口：`ForgingManager.handleForgeStartReq(ForgeStartReq req)`

关键步骤：

1. **队列满则拒绝**：`activeForges.size() >= determineNumberOfQueues()`
2. **读取配方**：`ForgeData forgeData = GameData.getForgeDataMap().get(req.getForgeId())`
3. **校验锻造点**：`forgePoint * forgeCount <= player.getForgePoints()`
4. **扣材料与 Mora**
   - `materialItems + ItemParamData(202, scoinCost)`
   - `player.getInventory().payItems(material, forgeCount, ActionReason.ForgeCost)`
5. **扣锻造点**：`player.setForgePoints(player.getForgePoints() - requiredPoints)`
6. **创建任务**：`ActiveForgeData(forgeId, avatarId, count, startTime=now, forgeTime=forgeData.forgeTime)`
7. **下发队列变化**：`PacketForgeQueueDataNotify` + `PacketForgeStartRsp`

把它抽象成 DSL 就是：

```text
enqueue(forgeId, count, assistAvatar):
  assert queueFree
  assert forgePointsEnough
  pay(materials * count + mora * count)
  forgePoints -= forgePoint * count
  activeForges.add({forgeId, count, startTime=now})
```

---

## 39.6 领取产出：按“已完成数量”发放，并对剩余部分重排队

入口：`obtainItems(queueId)`

逻辑要点：

- 计算 `finished` 与 `unfinished`
- 若 `finished<=0`：直接返回（还没到时间）
- 产出 itemId 的选择：
  - `resultId = (resultItemId > 0) ? resultItemId : showItemId`
- 发放数量：`resultItemCount * finished`
- 触发事件与战令：
  - `PlayerForgeItemEvent`（插件可改奖励）
  - `BattlePassManager.triggerMission(TRIGGER_DO_FORGE, 0, finished)`
- 若还有未完成：
  - 用同一个 forgeId/forgeTime
  - 把 `startTime` 往后推 `finished*forgeTime`（让时间轴连续）
- 否则：移除该队列槽

这段实现很适合作为“队列制造系统”的通用模板：**领取=发放已完成部分 + 重新归并剩余任务**。

---

## 39.7 取消锻造：仅在“无已完成产出”时允许，返还材料/金币/锻造点

入口：`cancelForge(queueId)`

关键约束：

- 如果 `getFinishedCount(now) > 0`：直接返回（不允许取消，必须先领完已完成部分）

返还规则（实现视角）：

1. 返还材料：`materialItems * count`
2. 返还 Mora：`scoinCost * count`
3. 返还锻造点：`forgePoint * count`，但总锻造点上限 clamp 到 `300_000`

对做内容的人来说，这里最重要的是：

- **锻造点是“可回收资源”**，且有硬上限；如果你用脚本/任务发锻造点，最好考虑上限与溢出体验。

---

## 39.8 “只改数据”怎么扩展锻造内容？

### 39.8.1 新增配方（Recipe）

只改数据层的最小步骤：

1. 在 `ForgeExcelConfigData.json` 新增一条 `ForgeData`
2. 确保 `resultItemId/showItemId/materialItems` 都是资源包里存在的 itemId

### 39.8.2 解锁配方（Blueprint Unlock）的数据化入口：`ItemUseUnlockForge`

文件：`Grasscutter/src/main/java/emu/grasscutter/game/props/ItemUseAction/ItemUseUnlockForge.java`

它把“解锁锻造配方”做成了一个标准 item-use 行为：

- 道具的 useParam 携带 `forgeId`
- 使用后 `postUseItem()` 调 `player.getForgingManager().unlockForgingBlueprint(forgeId)`

因此你可以用“只改数据/脚本”的方式解锁配方：

- 做一个“图纸道具”（ItemExcel 配置 `ITEM_USE_UNLOCK_FORGE`）
- 通过任务奖励/活动奖励/商店售卖发放该图纸

这就是典型的“把系统解锁抽象成可发放道具”的内容范式。

---

## 39.9 明显的引擎边界

锻造系统当前实现中，以下需求更像“改引擎”而非“改配表”：

- 队列槽位数的更复杂解锁逻辑（目前硬编码按冒险等级）
- 更细的产出规则（暴击锻造、概率双倍、角色天赋影响产量等）
- 更严谨的服务端校验/反作弊（例如客户端伪造请求、跨时区刷新问题）

---

## 39.10 小结

- 锻造是一个非常标准的“计时制造系统”：`ForgeData` 定义内容，`ActiveForgeData` 表示运行态，`ForgingManager` 管理队列与结算。
- “只改数据”的关键抓手是：把解锁做成 item-use（`ItemUseUnlockForge`），从而能用任务/活动/商店去编排解锁节奏。
- 战令触发点在“领取产出”而不是“开始锻造”，这对你设计任务目标（做/领）很关键。

---

## Revision Notes

- 2026-01-31：首次撰写本专题；梳理 `ForgeExcelConfigData → ForgingManager → ActiveForgeData 时间计算 → 领取/取消返还 → 战令触发`，并补充“图纸道具解锁”的可编排范式。

