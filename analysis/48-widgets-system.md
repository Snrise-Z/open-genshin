# 48 专题：Widget/小道具系统：槽位绑定 → 快速使用/DoBag → 载具生成（当前实现偏“桩”）

本文把 Widget 当成“随身工具/快捷小道具”的系统来分析：  
在官方语境里，它通常覆盖 **罗盘/种子/风之翼、便携锅、NRE（便携食物）、四叶印/载具召唤** 等。  
而在本仓库中，Widget 系统目前属于 **“能跑 UI/能回包，但大量效果缺失”** 的状态：更像一个待补齐的模块骨架。

与其他章节关系：

- `analysis/47-itemuse-dsl-and-useitem-pipeline.md`：理想情况下，Widget 的“快速使用”应当复用 UseItem 管线；当前实现并未接入。
- `analysis/19-route-platform-timeaxis.md`：WidgetDoBag 可生成载具实体（`EntityVehicle`），载具/平台类移动玩法通常会与路线系统产生交集。
- `analysis/30-multiplayer-and-ownership-boundaries.md`：Widget/载具在多人房间里通常涉及归属/共享/可见性；本仓库只实现了很小的一段。

---

## 48.1 抽象模型：Widget = Slot（装备）+ ClientAction（使用）+ ServerEffect（生成/触发）

从“玩法编排层”角度，一个完整 Widget 系统一般包含：

1. **槽位模型**：玩家可以装备/卸下/切换 widget（常见是多个槽位或多 tag）。
2. **全量同步**：登录/切场景/切换 widget 时，要把 widget 数据（冷却、绑定、实体列表等）同步给客户端。
3. **使用路径**（至少两种）：
   - **QuickUse**：按键触发“消耗/生效”（如罗盘扫描、投掷道具、NRE 自动吃食物）
   - **DoBag**：带坐标/朝向/位置的数据包，请求在世界中生成一个实体（如召唤载具、放置 gadget）
4. **冷却系统**：按 widget 或 cooldown group 计时，客户端展示 UI 冷却。

本仓库目前只覆盖了：**单一 widgetId 绑定 + QuickUse 只扣数量 + DoBag 仅硬编码两种载具**。

---

## 48.2 槽位绑定：`SetWidgetSlotReq` 把一个 `materialId` 写进 `Player.widgetId`

### 48.2.1 写入点

文件：`Grasscutter/src/main/java/emu/grasscutter/server/packet/recv/HandlerSetWidgetSlotReq.java`

核心行为非常简单：

- `player.setWidgetId(req.getMaterialId())`
- 先发一个 `WidgetSlotChangeNotify(DETACH)`
- 如果 op 是 `ATTACH` 再发 `WidgetSlotChangeNotify(materialId)`
- 回包 `SetWidgetSlotRsp(materialId)`

这透露出两点“当前实现假设”：

1. **只有一个 widget 处于激活状态**（用一个 int `widgetId` 表示）。
2. 服务器对“槽位结构/标签”基本不建模，更多是让客户端 UI 能“看起来装上了”。

### 48.2.2 查询点：`GetWidgetSlotReq/Rsp`

- recv：`Grasscutter/src/main/java/emu/grasscutter/server/packet/recv/HandlerGetWidgetSlotReq.java`
- send：`Grasscutter/src/main/java/emu/grasscutter/server/packet/send/PacketGetWidgetSlotRsp.java`

回包逻辑：

- `widgetId == 0`：返回空 slotList
- 否则返回两个 slotList：
  1. `isActive=true + materialId=widgetId`
  2. `tag=WIDGET_SLOT_TAG_ATTACH_AVATAR`（没有 materialId）

从“可编排层”角度，这更像是为了满足客户端 proto 结构，而不是一个可扩展的槽位模型。

---

## 48.3 全量同步：`AllWidgetDataNotify` 基本是 TODO（且存在一个 opcode 级 bug）

### 48.3.1 `AllWidgetDataNotify`：几乎全是占位

文件：`Grasscutter/src/main/java/emu/grasscutter/server/packet/send/PacketAllWidgetDataNotify.java`

现状：

- LunchBoxData、冷却组、锚点、采集探测器等字段基本都是空 list / build()。
- slotList 的拼法与 `GetWidgetSlotRsp` 类似（同样只用 `Player.widgetId`）。

这意味着：

> 目前登录/切线/切场景时，客户端拿不到“真实 widget 状态”，只能靠局部回包维持 UI。

### 48.3.2 `WidgetGadgetAllDataNotify` 的 opcode 写错

文件：`Grasscutter/src/main/java/emu/grasscutter/server/packet/send/PacketWidgetGadgetAllDataNotify.java`

它构造的是 `WidgetGadgetAllDataNotify` proto，但 `super(...)` 用了：

- `PacketOpcodes.AllWidgetDataNotify`

这在协议层属于“发错包号”的硬错误：客户端可能完全收不到/解析不到预期数据。

在“引擎边界”视角里，这类 bug 会直接导致你很难用“只改脚本/数据”的方式完成 widget 系统，因为连基础同步都不稳定。

---

## 48.4 使用路径 A：`QuickUseWidgetReq` 只做“扣数量”，明确写了“无效果”

文件：`Grasscutter/src/main/java/emu/grasscutter/server/packet/recv/HandlerQuickUseWidgetReq.java`

代码注释直接写明：

- “Known Bug: No effects after using item but decrease.”
- 当前实现只是把 `player.widgetId` 对应的 material 在背包里 `removeItem(item, 1)`
- 然后回一个 `QuickUseWidgetRsp(retcode, materialId)`

对玩法编排层的结论：

- **Widget 快速使用并没有接入任何效果系统**（既没走 `InventorySystem.useItem`，也没触发脚本事件）。
- 你如果想做“投掷炸弹/罗盘扫描/一键吃食物”等，必须下潜到引擎层补齐。

---

## 48.5 使用路径 B：`WidgetDoBagReq`：硬编码两个 materialId → 生成载具 `EntityVehicle`

文件：`Grasscutter/src/main/java/emu/grasscutter/server/packet/recv/HandlerWidgetDoBagReq.java`

行为：

1. 从请求里读 `WidgetCreatorInfo.LocationInfo`（pos/rot）
2. `switch (req.getMaterialId())`：
   - `220026` → `spawnVehicle(gadgetId=70500025)`，并发送冷却通知（还发了两次）
   - `220047` → `spawnVehicle(gadgetId=70800058)`
3. 最后回 `PacketWidgetDoBagRsp()`

`spawnVehicle(...)` 的核心：

- `new EntityVehicle(scene, player, gadgetId, 0, pos, rot)`
- `scene.addEntity(entity)`
- `session.send(new PacketWidgetGadgetDataNotify(gadgetId, entityId))`

这给内容层一个“很具体但很窄”的入口：

- 如果你只想在私有实验里“能召唤出载具”，且 materialId 恰好是这两个之一，那么现在就能用。
- 如果你想支持更多 widget 类型/更多载具/更多 gadget 行为，就需要把 `switch(materialId)` 扩展成数据驱动（或脚本驱动）。

---

## 48.6 LunchBox（便携食物/NRE）相关：只做了“回包”

文件：

- recv：`Grasscutter/src/main/java/emu/grasscutter/server/packet/recv/HandlerSetUpLunchBoxWidgetReq.java`
- send：`Grasscutter/src/main/java/emu/grasscutter/server/packet/send/PacketSetUpLunchBoxWidgetRsp.java`

行为是：客户端发什么 lunchBoxData，服务端就原样回。

它没有：

- 保存 lunchBoxData 到 Player
- 在 `AllWidgetDataNotify` 中同步
- 在 `QuickUseWidgetReq` 中自动“选食物→走 UseItem 管线”

所以从“玩法编排层”看，LunchBox 目前是一个**协议层 stub**。

---

## 48.7 作为“可编排模块”时，你能做什么 & 不能做什么？

### 48.7.1 只改数据/脚本能做的（很有限）

- 基本只能“让 UI 看起来装备了一个 widget”（因为 `SetWidgetSlotReq` 生效）。
- 对 DoBag 的两个硬编码 materialId，你可以把它们当“固定召唤器”来用（不推荐长期依赖）。

### 48.7.2 必须改引擎才能做的（这才是 widget 的主战场）

要把 widget 当成成熟 ARPG 引擎模块，至少要补齐：

1. **QuickUse → Effect**：把 `QuickUseWidgetReq` 接入 `InventorySystem.useItemDirect`（或一个 widget 专用效果系统）。
2. **全量同步**：实现 `AllWidgetDataNotify` 的关键字段（槽位、冷却、实体列表）。
3. **冷却组/逻辑冷却**：`WidgetCoolDownNotify` 的 groupId 与时钟语义需要统一（现在甚至出现同一包发送两次）。
4. **可数据化的映射**：`materialId → 行为` 不应写死在 switch 里，应该在表/脚本里可配置（否则“只改数据”永远做不了新 widget）。

---

## 48.8 小结

- Widget 在本仓库目前是“壳子系统”：槽位绑定能跑，但 QuickUse 没有效果，DoBag 只支持极少数硬编码载具。
- 对“只改脚本/数据实现玩法”的目标而言，Widget 是一个典型的 **引擎边界**：它的核心价值在“交互→生成实体/效果→冷却→同步”，需要引擎层系统性实现。
- 如果你准备未来扩展，建议把它当作一个独立专题模块：先补全“全量同步 + 正确 opcode + 统一效果入口”，再谈内容编排。

---

## Revision Notes

- 2026-01-31：首次撰写本专题；梳理 Widget 槽位绑定（`Player.widgetId`）、QuickUse/DoBag 两条使用路径与缺口，并记录 `PacketWidgetGadgetAllDataNotify` opcode 错误这一关键同步 bug。

