# 35 专题：大世界资源刷新语义（oneoff / persistent / respawn）与当前实现缺口

本文聚焦一个非常“玩法工程化”的问题：  
**大世界资源（怪、采集物、宝箱、调查点、机关）到底怎么刷新？“一次性（oneoff）”与“可刷新（respawn）”的边界在哪里？这套仓库的实现到什么程度？**

这对你“只改脚本/数据”非常关键：因为你想做的很多玩法（世界事件、采集循环、日常）都依赖刷新语义。

与其他章节关系：

- `analysis/23-vision-and-streaming.md`：Vision/流式加载决定“实体何时出现/消失”，是刷新语义的一半。
- `analysis/26-entity-state-persistence.md`：GroupInstance 的持久化边界（另一半决定“消失后是否记得”）。
- `analysis/32-blossom-and-world-events.md`：Blossom 的“消费记录”就是一种刷新语义样例。
- `analysis/29-gadget-content-types.md`：采集/宝箱等资源的交互与删除方式。

---

## 35.1 先把名词讲清楚：Streaming ≠ Refresh

很多人第一次看会把两件事混在一起：

1. **Streaming（流式加载）**
   - 玩家走近 → 实体生成
   - 玩家走远 → 实体移除（为了省资源/省同步）
2. **Refresh（刷新/重生）**
   - 实体被击杀/采集/领取后，是否会在“某个周期/条件”下再次出现

Streaming 解决的是“视野与性能”，Refresh 解决的是“资源循环与世界持续性”。

本仓库目前实现了比较明确的 Streaming，但 Refresh（周期性重生）不完整。

---

## 35.2 两条资源生成管线：SpawnData vs SceneGroup（Lua）

你要先分清：资源是从哪条管线来的，因为刷新语义不同。

### A) SpawnData（`Spawns.json / GadgetSpawns.json`）

入口：

- `ResourceLoader.loadSpawnData()` → `GameDepot.getSpawnLists()`
- `Scene.checkSpawns()` 会根据玩家所在网格动态生成/移除实体

特点：

- 更像“静态分布的世界生态”（散落的怪、采集物、地脉入口等）
- 由引擎侧统一管理，不走 Lua group script 的 suites/triggers

### B) SceneGroup（`resources/Scripts/Scene/.../scene*_group*.lua`）

入口：

- Scene/Block/Group 脚本加载 → `SceneScriptManager` 生成 `SceneGroupInstance`
- suite 决定实体集合，trigger 决定事件响应

特点：

- 更像“关卡玩法单元”（Encounter/Puzzle/Room）
- 有变量、切 suite、事件系统，适合编排
- 有一定持久化（绑定 host 存档）

结论：你想要“可控的刷新语义”，通常更容易在 SceneGroup 管线里做（因为你有变量与 suite 机制）。

---

## 35.3 SpawnData 管线的刷新语义：当前是“死了就不再刷（仅场景内存）”

核心逻辑在 `Scene.checkSpawns()`：

1. 计算玩家附近网格 block 列表（loadedGridBlocks）
2. 合并这些网格里的 spawn entries 得到 `visible`
3. 对每个 visible entry：
   - 若不在 `spawnedEntities` 且不在 `deadSpawnedEntities` → 生成实体并加入 scene
4. 对场景中已有实体：
   - 若其 spawnEntry 不在 visible（走远）→ 视野移除，并从 `spawnedEntities` 去掉

关键状态集合：

- `spawnedEntities`：当前已生成过（且仍在“可见网格内”）的 spawn entries
- `deadSpawnedEntities`：被杀/被采集/被摧毁过的 spawn entries（“本场景生命周期内不再生成”）

### 35.3.1 “死亡/采集”是怎么把 entry 放进 deadSpawnedEntities 的？

典型：

- `EntityMonster.onDeath`：`Optional.ofNullable(getSpawnEntry()).ifPresent(scene.getDeadSpawnedEntities()::add)`
- `EntityGadget.onDeath`：同理（且还会给 groupInstance 记 deadEntities）

这意味着：

- 只要是 SpawnData 生成出来的实体，一旦死亡/采集，会把 spawn entry 标死；
- 即便你走远让它 streaming 移除，再走回来，它也不会再刷（因为 deadSpawnedEntities 仍在）。

### 35.3.2 这个“死了不刷”是持久化的吗？

当前看起来 **不是**（至少在 Scene 实例生命周期内成立）：

- `deadSpawnedEntities` 是 `Scene` 的内存集合
- 服务器重启/场景重建后，这个集合会重置

因此这是一个“临时刷新语义”，并不是你期待的“每日刷新/每周刷新”。

---

## 35.4 SceneGroup（Lua）管线的刷新语义：更接近“可持久化的关卡状态”

在 `analysis/26` 已经讨论过：

### 35.4.1 变量与 suite 是“持久化编排”的基础

- group variables 会存在 `SceneGroupInstance`
- group instance 会按 host 存档持久化（DB）
- 切 suite 会决定实体集合变化

这给了你一种“可控刷新”的能力：

- 你可以在变量里记录“已完成/已领取”
- 在 group 加载时（或 `GROUP_LOAD`）根据变量决定加载哪个 suite
- 从而实现“一次性/可重置/可重复”的关卡单元

### 35.4.2 `SceneGadget.isOneoff` 的语义与现实

`SceneGadget` 数据类里有字段 `isOneoff`，并且有注释：

- `isOneoff=true`：交互后永久消失（如多数宝箱）
- `isOneoff=false`：交互后暂时消失，下一次“大世界资源刷新例程”会再出现

但当前仓库里：

- “大世界资源刷新例程”并没有一个明确的周期性实现
- 所以 `isOneoff=false` 更像是一个“语义占位”，脚本层不能指望它自动重生

实战上你更应该用：

- group variables + suite 切换来表达“是否重生/何时重生”

---

## 35.5 对玩法编排的直接影响（你会遇到的现象）

1. **你用 SpawnData 布了一堆怪/采集物**
   - 玩家击杀/采集后，在同一次场景生命周期内不会再刷
   - 重启后又全回来 → 看起来像“刷新了”，但其实是“状态没持久化”
2. **你在 Lua group 里放了宝箱/机关**
   - 是否“永久消失/永久打开”更容易做到（写变量/持久化 gadget state）
   - 但“按周期重生”仍需要你自己实现（时间变量/跨天判断等）
3. **Blossom 这种世界事件**
   - 也只有内存级消费记录（`blossomConsumed`），不保证跨重启

---

## 35.6 只改脚本/数据：你能做的“刷新策略”（务实方案）

这里给你几套可落地的方案，按“侵入性/实现成本”排序：

### 方案 A：把需要刷新语义的内容尽量放进 SceneGroup（而不是 SpawnData）

原因：

- SceneGroup 有变量与 suite，可以表达状态机
- 持久化边界更清晰（绑定 host）

做法：

- 用 group scripts 做“刷怪/采集点/领奖点”
- 通过 `AddExtraGroupSuite` / `RefreshGroup` / `GoToGroupSuite` 控制“重生”

### 方案 B：用“时间变量/跨天判定”在脚本层重置变量

你可以在 group variables 里存：

- `last_reset_day`（或 `last_reset_time`）

在 `GROUP_LOAD` 或定时 tick 时：

- 若跨天 → 重置变量 → 切 suite / 重新生成实体

这能模拟“每日刷新”，不依赖 SpawnData 的死表语义。

### 方案 C：如果必须用 SpawnData：接受它是“场景内存级”刷新，并用重启/重载作为刷新手段

这不是理想方案，但在私有学习环境里可能够用：

- 把 SpawnData 当成“静态分布”
- 把“刷新周期”当成“重启服务器/重建场景”

---

## 35.7 什么时候必须下潜引擎？

当你想要真正的“大世界资源刷新系统”，通常需要 Java：

- 把 `deadSpawnedEntities` 持久化（按 spawnEntry 维度存时间戳/刷新周期）
- 实现一个周期性 refresh routine（每日/每周/地区）
- 让 `SceneGadget.isOneoff=false` 真正生效（按规则重生）
- 更细粒度的“对不同玩家的世界状态不同”（联机/单人差异）

这些属于“世界生态系统”的核心机制。

---

## 35.8 小结

- 本仓库当前实现更像：**Streaming 已做，Refresh 只做到“本场景生命周期内死了不刷”**。
- SpawnData 管线的死表状态不持久化；SceneGroup 管线更容易表达持久化关卡状态。
- 想在“只改脚本/数据”的前提下做刷新玩法，最佳策略是：  
  **用 group variables + suite 来模拟刷新**，不要指望 SpawnData 自动重生。

---

## Revision Notes

- 2026-01-31：首次撰写本专题；对比 SpawnData 与 SceneGroup 两条生成管线的刷新语义与缺口，并给出脚本层可落地的刷新策略。

