# 41 专题：制造三兄弟：Combine（即时合成）/Compound（炼金队列）/Strongbox（强匣分解）

本文把本仓库里“制造相关”的三条管线放在一起讲清楚，因为它们在内容层往往会一起被你拿来做玩法编排：

1. **Combine（即时合成）**：一次请求，立刻扣材料并给产出（偏“工作台合成”）
2. **Compound（炼金/转化）**：投入材料进队列，按时间产出，按组领取（偏“炼金台”）
3. **Strongbox/Decompose（强匣分解）**：消耗一批装备，随机换出新装备（偏“回收再抽”）

与其他章节关系：

- `analysis/16-reward-drop-item.md`：三条管线本质都在“消耗 Item → 发放 Item”。
- `analysis/39-forging-pipeline.md`：锻造也是计时队列，但队列模型与 Compound 不同（并行槽位 vs 按配方累计队列）。
- `analysis/36-resource-layering-and-overrides.md`：强匣/部分数据表来自 `data/`，若缺失会回退 jar defaults，可通过覆盖实现魔改。

---

## 41.1 抽象模型：三类制造系统各自解决什么问题？

用中性 ARPG 模型对齐：

### 41.1.1 Combine（即时合成）

适用：把“材料 A/B/C”立刻转成“产物 X”，常用于：

- 升阶材料合成
- 简单炼金（非计时）
- 兑换型合成

特点：**同步请求-同步结算**，无需队列持久化。

### 41.1.2 Compound（炼金队列）

适用：强调“等待/计划”的制造行为：

- 投入材料 → 一段时间后产出
- 可以同时排队多个配方
- UI 常以“分组”组织（例如按材料类型/分类页）

特点：**需要持久化一个随时间可计算的队列状态**。

### 41.1.3 Strongbox（强匣分解）

适用：做“回收 → 随机再抽”的经济闭环：

- 消耗一批装备/材料
- 从一个候选池里随机生成若干产物

特点：**输入与输出数量关系固定，但具体产物随机**。

---

## 41.2 数据依赖清单（内容主要从这些表/数据来）

### 41.2.1 Combine：`resources/ExcelBinOutput/CombineExcelConfigData.json`

对应资源类：`Grasscutter/src/main/java/emu/grasscutter/data/excels/CombineData.java`

关键字段（从类定义反推）：

- `combineId`：配方 id
- `playerLevel`：所需冒险等级
- `combineType/subCombineType`：分类（更多是 UI/组织用途）
- `resultItemId/resultItemCount`：固定产出
- `scoinCost`：Mora 成本（202）
- `materialItems`：消耗材料
- `randomItems`、`recipeType`：存在字段但当前实现未充分使用（见 41.4）

### 41.2.2 Compound：`resources/ExcelBinOutput/CompoundExcelConfigData.json`

对应资源类：`Grasscutter/src/main/java/emu/grasscutter/data/excels/CompoundData.java`

关键字段：

- `id`：compoundId（配方 id）
- `groupID`（反序列化到 `groupId`）：分组 id（UI/领取按组）
- `isDefaultUnlocked`：默认解锁
- `costTime`：单件耗时（秒）
- `queueSize`：同一 compoundId 的最大排队数量
- `inputVec/outputVec`：输入/输出 ItemParam 列表

### 41.2.3 Strongbox：`data/ReliquaryDecompose.json`（可覆盖）

读取入口：`CombineManger.initialize()`

- 用户目录 `data/` 若没有，会回退到 jar 默认：`Grasscutter/src/main/resources/defaults/data/ReliquaryDecompose.json`
- 结构：`configId → items[]`（items 是“可能产出 itemId 列表”）

---

## 41.3 引擎侧入口总览：哪些类负责哪条管线？

### 41.3.1 Combine/Strongbox：`CombineManger`（系统级）

文件：`Grasscutter/src/main/java/emu/grasscutter/game/combine/CombineManger.java`

- 初始化：`CombineManger.initialize()`（服务器启动时调用，见 `GameServer`）
  - 加载强匣数据到 `reliquaryDecomposeData: Map<configId, List<itemId>>`
- 解锁合成配方：`unlockCombineDiagram(player, combineId)`
  - 写入 `Player.unlockedCombines`
  - 下发 `PacketCombineFormulaDataNotify`
- 执行合成：`combineItem(player, combineId, count)`
- 执行强匣：`decomposeReliquaries(player, configId, targetCount, guidList)`

### 41.3.2 Compound：`CookingCompoundManager`（玩家级）

文件：`Grasscutter/src/main/java/emu/grasscutter/game/managers/cooking/CookingCompoundManager.java`

初始化：`CookingCompoundManager.initialize()`（服务器启动时调用）

- 读 `CompoundData`：
  - `defaultUnlockedCompounds`
  - `compoundGroups: Map<groupId, Set<compoundId>>`
- 维护队列：`Player.activeCookCompounds: Map<compoundId, ActiveCookCompoundData>`
- 登录下发：`onPlayerLogin()` → `PacketCompoundDataNotify`
- 两个核心请求：
  - `handlePlayerCompoundMaterialReq`：投入材料进队列
  - `handleTakeCompoundOutputReq`：按组领取已完成产出

队列状态结构：`ActiveCookCompoundData`（见 41.6）。

---

## 41.4 Combine（即时合成）管线：请求 → 扣材料 → 发产出

### 41.4.1 客户端入口：`CombineReq`

文件：`Grasscutter/src/main/java/emu/grasscutter/server/packet/recv/HandlerCombineReq.java`

它把 `combineId/combineCount` 转给：

- `server.getCombineSystem().combineItem(player, combineId, combineCount)`

并把返回的 `CombineResult` 填进 `PacketCombineRsp`。

### 41.4.2 合成执行：`CombineManger.combineItem(...)`

核心步骤：

1. 校验配方存在：`GameData.getCombineDataMap().containsKey(cid)`
2. 校验玩家等级：`combineData.playerLevel <= player.level`
3. 构造成本：
   - `materialItems + Mora(202, scoinCost)`
4. 扣成本：`inventory.payItems(material, count, ActionReason.Combine)`
5. 发产出：`addItem(resultItemId, resultItemCount * count)`

返回的 `CombineResult` 在当前实现里比较“薄”：

- `material/back/extra` 多数为空（留了 TODO）
- 暂未实现“幸运角色”“随机额外产物”等更复杂逻辑

### 41.4.3 一个需要你注意的实现缺口：失败路径可能仍然下发成功包

从代码走读可见：

- `combineItem()` 在扣款失败时会先 `player.sendPacket(new PacketCombineRsp(RET_ITEM_COMBINE_COUNT_NOT_ENOUGH))`
- 但它并没有立即 `return`，后续仍可能继续发放产物并返回 `CombineResult`
- `HandlerCombineReq` 对 `CombineResult` 的回包构造会使用 `PacketCombineRsp` 的“成功构造器”（retcode=SUCC）

结论：如果你把它用于更严肃的经济系统，这属于必须修补的引擎层问题；  
在私有学习环境里，你至少要知道“当前 Combine 的失败路径不够严谨”。

---

## 41.5 Combine 配方解锁的可编排入口：`ItemUseUnlockCombine`

文件：`Grasscutter/src/main/java/emu/grasscutter/game/props/ItemUseAction/ItemUseUnlockCombine.java`

这提供了一个和烹饪/锻造类似的内容范式：

- 合成配方解锁可以做成“图纸道具”
- 图纸道具使用后：
  - 写入 `Player.unlockedCombines`
  - 下发 `CombineFormulaDataNotify`

并且玩家登录时会同步：

- `PacketCombineDataNotify(this.unlockedCombines)`（见 `Player.onLogin`）

因此你能用任务/活动/商店把“合成系统的解锁节奏”完全编排出来。

---

## 41.6 Compound（炼金队列）管线：投入 → 计时 → 按组领取

### 41.6.1 队列数据结构：`ActiveCookCompoundData`

文件：`Grasscutter/src/main/java/emu/grasscutter/game/managers/cooking/ActiveCookCompoundData.java`

它用“可计算的时间轴”表达队列：

- `compoundId`
- `costTime`（单件耗时）
- `totalCount`
- `startTime`

关键公式：

- `outputCount = floor((now - startTime) / costTime)` clamp 到 `totalCount`
- `waitCount = totalCount - outputCount`
- `outputTime = startTime + (outputCount+1)*costTime`（若全部完成则 0）

这使得队列完全可以离线恢复：**只要持久化 startTime/totalCount 就够了**。

### 41.6.2 投入材料：`PlayerCompoundMaterialReq`

入口：`CookingCompoundManager.handlePlayerCompoundMaterialReq`

逻辑：

1. 校验该 compoundId 是否“可用”（当前实现用一个 `static unlocked` 集合，见 41.7）
2. 校验队列容量：
   - 同一 `compoundId` 的 `totalCount + count <= queueSize`
3. 扣输入材料：
   - `inventory.payItems(compound.inputVec, count)`（注意：目前未见 Mora 成本）
4. 写入/更新 `activeCookCompounds[compoundId]`
5. 回包一个 `CompoundQueueData`（包含 outputCount/outputTime/waitCount）

### 41.6.3 按组领取：`TakeCompoundOutputReq`（客户端按 groupId 领取）

入口：`CookingCompoundManager.handleTakeCompoundOutputReq`

注意：代码注释明确指出：

- 客户端不会设置 compoundId，而是设置 `compoundGroupId`

领取算法：

1. 遍历 `compoundGroups[groupId]` 下的所有 compoundId
2. 对每个 active 的队列：
   - `quantity = takeCompound(now)`（取走“已完成数量”）
   - 叠加 `outputVec * quantity` 到总奖励
3. 若至少一个队列产出 >0：
   - `inventory.addItems(allRewards, ActionReason.Compound)`
   - 回包成功
4. 否则回 `RET_COMPOUND_NOT_FINISH`

你可以把它理解成一个“组内批量收菜”机制：UI 上的一键领取对应服务端的“遍历组内队列”。

---

## 41.7 Compound 解锁状态的当前实现：全局 static（一个很典型的引擎边界）

`CookingCompoundManager` 目前把 `unlocked` 做成了 `static`：

- 由 `isDefaultUnlocked=true` 的配方构成
- 另外还会把 `groupId==3` 的配方全解锁（注释里说是因为 fishing 未实现）
- TODO 注释也承认：这应该绑定到 player，而不是 manager

结论：

- 如果你只做内容：可以通过改 `isDefaultUnlocked` 与 group 组织来控制“全服默认可用的炼金配方”
- 如果你要做“按玩家解锁/任务解锁炼金配方”：这是非常明确的引擎层工作

---

## 41.8 Strongbox（强匣分解）：消耗 3 件 → 随机出 1 件

入口：`CombineManger.decomposeReliquaries(player, configId, count, inputGuids)`

关键规则（从实现直接读出）：

1. `configId` 必须存在于 `reliquaryDecomposeData`
2. 输入 guid 数量必须等于 `count * 3`（硬编码 3→1）
3. 服务端会校验每个 guid 确实在玩家背包里
4. 删除输入装备
5. 对每个目标产出：
   - 从 `possibleDrops` 随机抽一个 itemId
   - `new GameItem(itemId, 1)` 加入背包
6. 回包产出 guid 列表

强匣的可改点几乎都在数据层：

- 改 `configId → drops[]` 即可换池子内容
- 改 `targetCount` 的限制与“3→1”比例则需要改引擎

---

## 41.9 小结

- Combine/Compound/Strongbox 是三种典型制造系统模板：同步合成、计时队列、回收随机再抽。
- 内容层最重要的抓手是“解锁的道具化”：
  - Combine 有 `ItemUseUnlockCombine`
  -（对比）Cooking 有 `ItemUseUnlockCookRecipe`，Forging 有 `ItemUseUnlockForge`
- Compound 当前的“解锁状态”是全局 static，不适合做精细的剧情/任务解锁；如果你要把它当正经引擎用，这是需要优先改的边界点之一。

---

## Revision Notes

- 2026-01-31：首次撰写本专题；统一梳理 Combine/Compound/Strongbox 三条制造管线的数据入口、运行态结构与可改点，并标注 Combine 失败路径与 Compound 解锁静态化的实现缺口。

