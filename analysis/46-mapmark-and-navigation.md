# 46 专题：MapMark/地图标记与导航：MarkMapReq → 持久化标记 → `fishhookTeleport` 调试传送

本文把“地图标记（MapMark）”当成一个典型的 **玩家侧导航数据（Player‑authored Navigation Data）** 来拆：  
它不是玩法脚本系统的一部分，但它经常被拿来做“内容引导/调试传送/采集点记录”等外围能力。

与其他章节关系：

- `analysis/36-resource-layering-and-overrides.md`：MapMark 属于玩家持久化数据（DB），不走资源覆盖；适合做“玩家个性化数据”的研究样本。

---

## 46.1 抽象模型：MapMark = 玩家自定义 POI（point of interest）+ 少量元数据

中性 ARPG 模型描述：

- **MarkPoint**：场景 id + 坐标 + 名称 + 类型
- **MarkType**：普通标记/怪物标记/任务标记/钓鱼点标记…
- **Persistence**：随玩家存档保存
- **Sync**：客户端请求增删改，服务端返回全量列表

本仓库实现还额外塞了一个非常“工程化”的能力：  
把某类标记当成“调试传送入口”（`fishhookTeleport`）。

---

## 46.2 引擎侧核心：`MapMarksManager` 与 `MapMark`

### 46.2.1 `MapMarksManager`

文件：`Grasscutter/src/main/java/emu/grasscutter/game/managers/mapmark/MapMarksManager.java`

职责：

- 处理 `MarkMapReq`（ADD/MOD/DEL/GET）
- 维护 mapMarks 的最大数量（150）
- 在每次操作后回包 `PacketMarkMapRsp`（全量标记列表）
- 可选：钓鱼点标记触发传送（见 46.5）

### 46.2.2 `MapMark`（玩家存档实体）

文件：`Grasscutter/src/main/java/emu/grasscutter/game/managers/mapmark/MapMark.java`

字段（从构造器读出）：

- `sceneId`
- `name`
- `position`（只存 x/y/z）
- `mapMarkPointType`
- `monsterId`
- `mapMarkFromType`
- `questId`

这说明 MapMark 可以承载“与怪物/任务关联的标记”，即使当前 manager 没有额外逻辑去解释它们。

---

## 46.3 玩家持久化结构：`Player.mapMarks`

玩家字段：

- `Player.mapMarks: HashMap<String, MapMark>`

getter：

- `Player.getMapMarks()`（若为 null 会创建空 map）

注意：

- MapMarksManager 在 ADD/MOD/DEL 后会 `save()`，因此标记会随玩家存档落库

---

## 46.4 请求处理：ADD/MOD/DEL 的行为与 key 设计（一个重要实现细节）

入口：`MapMarksManager.handleMapMarkReq(MarkMapReq req)`

### 46.4.1 key 的生成方式：只用 X/Z 的整数部分

`getMapMarkKey(Position position)`：

- key = `"x" + (int)x + "z" + (int)z`

含义：

- y 坐标完全不参与 key
- x/z 会被强制转成 int（截断小数）

因此你需要意识到一个后果：

- 两个坐标只要落在同一个整数格子的 x/z，就会发生覆盖/冲突

这对“做精确 POI 标记”的体验会有影响；  
如果你要把 MapMark 当成更严谨的导航系统，这属于引擎边界（需要改 key 策略）。

### 46.4.2 OPERATION_ADD

- 构造 `MapMark(req.getMark())`
- 若未触发 fishhookTeleport（见 46.5）：
  - 若当前数量 < 150：`mapMarks.put(key, mapMark)`

### 46.4.3 OPERATION_MOD

- 用 `req.getOld()` 构造 oldMark，按 old position 的 key 删除
- 用 `req.getMark()` 构造 newMark，再添加

### 46.4.4 OPERATION_DEL

- 用 `req.getMark()` 构造 mark，按 position 的 key 删除

### 46.4.5 回包策略：非增量，而是全量

无论 ADD/MOD/DEL/GET：

- 都会发送 `PacketMarkMapRsp(this.getMapMarks())`

这让实现简单但也意味着：标记数量越多，单次同步包越大。

---

## 46.5 `fishhookTeleport`：把“钓鱼点标记”当作调试传送门（非常实用的工程技巧）

触发条件：

- `Configuration.GAME_OPTIONS.fishhookTeleport == true`
- 且新增的标记类型为：
  - `MapMarkPointType.MAP_MARK_POINT_TYPE_FISH_POOL`

行为：

1. 读取 y：
   - `Float.parseFloat(mapMark.getName())`
   - 若失败：默认 y=300
2. `world.transferPlayerToScene(player, sceneId, TeleportType.MAP, new Position(x, y, z))`
3. 广播 `PacketSceneEntityAppearNotify(player)` 让玩家实体在新场景出现

你可以把它理解成一种“开发者工具链”的做法：

- 不改客户端 UI
- 借用一个已有的“标记类型”作为隐藏指令通道
- 用标记 name 传参（这里传 y）

如果你未来要做更多调试/GM 工具，这个模式非常值得复用。

---

## 46.6 “只改数据/脚本”能做什么？哪些需要改引擎？

### 46.6.1 只改配置就能做

- 开关调试传送：`GAME_OPTIONS.fishhookTeleport`

### 46.6.2 需要改引擎的典型方向

- 更精确的 key（把 y/小数纳入，或改为 GUID）
- 服务端主动下发“系统标记”（当前主要是客户端驱动；若要做任务引导标记，可能需要新增 API/协议路径）
- 标记数量上限与增量同步（目前是全量回包 + 150 上限）

---

## 46.7 小结

- MapMark 是一个很好的“玩家个性化数据”样本：结构简单、持久化清晰、同步策略直观。
- 当前实现有两个关键特性：
  - key 只用 int(x/z)（会冲突）
  - 全量回包（实现简单但不够高效）
- `fishhookTeleport` 展示了一个很实用的工程范式：用既有系统（标记）承载调试功能，几乎零内容成本。

---

## Revision Notes

- 2026-01-31：首次撰写本专题；梳理 MapMark 的持久化与同步机制，并记录 key 截断与 `fishhookTeleport` 作为调试通道的工程范式。

