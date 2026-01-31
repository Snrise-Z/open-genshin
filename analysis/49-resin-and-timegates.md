# 49 专题：Resin/树脂与时间门槛：`resinOptions` → 充能/上限 → 副本/地脉/周本领奖的统一扣费点

本文把“树脂（Resin）”当成一个典型的 **时间门槛货币（Time-gated Currency）** 来拆：  
它在玩法层的作用是“限制某些奖励的领取频率”，因此会出现在 **副本结算、地脉领奖、Boss 宝箱** 等关键节点。

本仓库的实现有一个非常重要的开关：`resinUsage=false` 时会把树脂当成“开发模式”，几乎所有消耗都会被跳过。

与其他章节关系：

- `analysis/18-dungeon-pipeline.md`：副本通关后的“雕像领奖/结算”会调用 `DungeonManager.handleCost()` 扣树脂/浓缩树脂。
- `analysis/32-blossom-and-world-events.md`：地脉（Blossom）领奖时固定扣 20 树脂（或 1 浓缩），并影响奖励倍率。
- `analysis/28-achievement-watcher-battlepass.md`：树脂消耗会触发战令任务（`TRIGGER_COST_MATERIAL`，materialId=106）。
- `analysis/51-drop-systems-new-vs-legacy.md`：Boss/副本/宝箱掉落与树脂扣费常常一起出现（“扣费→发奖励”）。

---

## 49.1 数据模型：树脂是“虚拟物品（Virtual Item）”，浓缩树脂是“普通材料”

### 49.1.1 树脂（Resin）= itemId 106（Virtual）

在本仓库里，树脂的“物品 ID”约定为：

- `itemId = 106`

但它不是背包里的真实材料堆叠，而是挂在玩家属性上的数值：

- `PlayerProperty.PROP_PLAYER_RESIN`

`Inventory.getVirtualItemCount(106)` 会直接读该属性，因此很多“扣费系统”只要写成本物品为 106，就能复用树脂。

文件入口：

- `Grasscutter/src/main/java/emu/grasscutter/game/inventory/Inventory.java`（virtual item 106）

### 49.1.2 浓缩树脂（Condensed Resin）= itemId 220007（Material）

浓缩树脂在本仓库被当作普通材料：

- `useCondensedResin(amount)` 实际调用 `player.getInventory().payItem(220007, amount)`

它的存在/数量来自 `MaterialExcelConfigData.json` 等常规资源与背包存档。

---

## 49.2 配置开关：`GAME_OPTIONS.resinOptions`

树脂系统的核心配置在：

- `Grasscutter/src/main/java/emu/grasscutter/config/ConfigContainer.java` → `GameOptions.ResinOptions`

字段：

- `resinUsage: boolean`：是否启用树脂消耗/充能（默认 false）
- `cap: int`：树脂上限（默认 160）
- `rechargeTime: int`：每 1 点树脂的充能间隔（秒，默认 480 = 8 分钟）

对“玩法编排层”的意义：

- 这是一个非常实用的“研究/调试开关”：当 `resinUsage=false` 时，你可以把树脂相关玩法当成“无限体力模式”，方便跑通流程。
- 但也要注意：它会让很多“奖励领取”失去门槛，行为更像沙盒。

---

## 49.3 核心执行器：`ResinManager`（扣费/加树脂/充能/购买）

文件：`Grasscutter/src/main/java/emu/grasscutter/game/managers/ResinManager.java`

### 49.3.1 扣树脂：`useResin(amount)`

关键语义：

- 若 `resinUsage=false`：直接 `return true`（跳过扣费）
- 否则：
  1. 检查玩家当前树脂是否够
  2. 扣除 `PROP_PLAYER_RESIN`
  3. 如果扣费后低于上限且 `nextResinRefresh==0`，启动充能计时
  4. 发送 `PacketResinChangeNotify`
  5. 触发战令：`TRIGGER_COST_MATERIAL, 106, amount`

这说明“树脂扣费”在系统层是一个 **可观测事件**：它会影响战令/统计。

### 49.3.2 扣浓缩树脂：`useCondensedResin(amount)`

- 若 `resinUsage=false`：`return true`
- 否则：`inventory.payItem(220007, amount)`

### 49.3.3 充能：`rechargeResin()`

树脂的“离线补充/在线补充”统一靠 `Player.nextResinRefresh` 实现：

- `Player.onTick()`（每秒）会调用 `player.getResinManager().rechargeResin()`
- `rechargeResin` 会：
  - 判断 `currentTime >= nextResinRefresh`
  - 计算本次应补充的点数（允许一次补多点，用于离线补偿）
  - 更新 `PROP_PLAYER_RESIN`
  - 更新 `nextResinRefresh`（达到上限则置 0）
  - 发 `PacketResinChangeNotify`

这套逻辑的优点：

- 不需要“每 8 分钟定时器”，只要 1 秒 tick 就能实现充能。
- 支持离线补偿（通过计算 `currentTime - nextResinRefresh`）。

### 49.3.4 登录处理：`onPlayerLogin()`

关键点：

- 若 `resinUsage=false`：登录时直接把树脂设为上限、`nextResinRefresh=0`
- 如果管理员调整了 `cap`，且玩家当前树脂低于 cap 但 refresh=0，会在登录时重启充能
- 登录必发一次 `PacketResinChangeNotify`

### 49.3.5 购买树脂：`buy()` + 日重置

购买入口：

- `HandlerBuyResinReq` → `ResinManager.buy()`

购买规则（当前实现）：

- 每日最多 `MAX_RESIN_BUYING_COUNT = 6`
- 花费 `HCOIN(201)`，价格曲线 `HCOIN_NUM_TO_BUY_RESIN`
- 每次增加 `AMOUNT_TO_ADD = 60` 树脂
- `resinBuyCount` 会在 `Player.doDailyReset()` 中重置为 0（每日刷新）

---

## 49.4 树脂的主要消费点（在哪里扣？扣多少？）

### 49.4.1 副本领奖：`DungeonManager.handleCost(...)`

文件：`Grasscutter/src/main/java/emu/grasscutter/game/dungeons/DungeonManager.java`

规则：

- `resinCost = dungeonData.statueCostCount != 0 ? statueCostCount : 20`
- `useCondensed=true` 时：
  - 只允许 `resinCost == 20`
  - 扣 `useCondensedResin(1)`
- 否则如果 `dungeonData.statueCostID == 106`：
  - 扣 `useResin(resinCost)`
- 其它 costId：直接放行（相当于“非树脂成本”或未实现）

对内容层的意义：

- 副本树脂成本主要由 `DungeonExcelConfigData`（或等价表）驱动：`statueCostID / statueCostCount / statueDrop`。
- 如果你想让某个副本“不要树脂”或“更贵/更便宜”，改表就能生效（前提是 costId 与引擎逻辑匹配）。

### 49.4.2 地脉领奖：`BlossomManager.onReward(...)` 固定 20 树脂

文件：`Grasscutter/src/main/java/emu/grasscutter/game/managers/blossom/BlossomManager.java`

规则硬编码：

- 普通：`useResin(20)`
- 浓缩：`useCondensedResin(1)`，并把奖励数量直接“双倍”

这是一个典型“引擎硬编码成本”的点：

- 你改数据表能改奖励内容（RewardPreview），但**改不了成本**（除非改 Java）。

### 49.4.3 Boss 宝箱领奖：`GadgetChest`（脚本大世界路径）按 `boss_chest.resin` 扣费

文件：`Grasscutter/src/main/java/emu/grasscutter/game/entity/gadget/GadgetChest.java`

当 `enableScriptInBigWorld=true` 且是 boss chest：

- 扣 `useResin(chest.boss_chest.resin)`
- 然后 `dropSystem.handleBossChestDrop(drop_tag, player)`

这给内容层一个很有用的可配置点：

- Boss 宝箱的树脂成本来自 **场景脚本 gadget 元数据**（`boss_chest.resin`），因此“只改脚本/数据”就能调成本（前提是你的资源包里这类字段齐全）。

在 legacy 路径里，`BossChestInteractHandler` 还会读取客户端 `resinCostType` 来决定是否使用浓缩树脂（语义见 `GadgetInteractReq.resinCostType`）。

---

## 49.5 “只改脚本/数据”的调整清单（实用）

1. **调全局体验（最直接）**：改 `config.json` 的 `resinOptions`  
   - `resinUsage=false`：开发/研究模式（几乎无限领奖）
   - `cap/rechargeTime`：改曲线（上限/回充速度）
2. **调副本成本**：改 Dungeon 相关 ExcelBin（`statueCostID/statueCostCount`）  
3. **调 boss 宝箱成本**：改 `Scripts/Scene/*_group*.lua` 的 `boss_chest.resin`（如果资源结构提供）  
4. **调地脉成本**：当前需要改 Java（成本写死 20）  
5. **调浓缩树脂逻辑**：目前“仅允许 cost==20 的副本使用浓缩”，也是引擎硬逻辑（要放宽需要改 Java）

---

## 49.6 引擎边界与注意事项

- `resinUsage=false` 会让很多系统“短路成功”，但也可能导致：
  - `addResin` 变成 no-op（你“加树脂”可能不会改变任何东西，因为根本不需要）
  - 某些 UI/日志/战令触发仍会发生或不发生（需按具体代码审计）
- 地脉成本硬编码、周本次数/领奖限制未实现等，都属于“真实服规则”缺口，而不是脚本层能补的。

---

## 49.7 小结

- 树脂在本仓库是一个标准的“时间门槛货币模块”：配置（cap/回充）+ 扣费点（副本/地脉/boss）+ 日重置（购买次数）。
- **树脂是虚拟物品 106**，因此可以被很多成本系统复用；**浓缩树脂是普通材料 220007**。
- 只改数据能调的点主要集中在“副本成本表 + boss 宝箱元数据 + 全局配置”；地脉等仍存在引擎硬编码边界。

---

## Revision Notes

- 2026-01-31：首次撰写本专题；梳理 `ResinManager`（扣费/回充/购买）、树脂虚拟物品语义，以及 Dungeon/Blossom/BossChest 三大消费点的扣费规则与可改边界。

