# 53 专题：Codex/图鉴系统：入包触发解锁 → 击杀计数 → 全量同步（实现子集与 ID 语义）

本文把 Codex 当成一个典型的 **收藏/图鉴（Collection / Encyclopedia）** 系统来拆：  
它的本质是“当玩家第一次获得/看到/击杀某个对象时，记录一条解锁状态，并在 UI 中展示进度与条目”。

本仓库的 Codex 主要靠两类触发：

1. **物品入包**：武器/材料/圣遗物套装等
2. **击杀怪物**：动物图鉴（kill count）

与其他章节关系：

- `analysis/16-reward-drop-item.md`：Codex 的“入包触发”依赖奖励/掉落最终落地为物品。
- `analysis/51-drop-systems-new-vs-legacy.md`：怪物死亡会触发 Codex 动物计数（`Scene.killEntity`）。
- `analysis/10-quests-deep-dive.md`：任务完成也会影响 Codex（Quest type 的条目在全量同步中由已完成主线推导）。

---

## 53.1 抽象模型：Codex = Category(TypeValue) + UnlockedSet/Counts + Sync

从中性 ARPG 引擎角度，Codex 可以拆成：

1. **分类（Category）**：武器/材料/动物/任务/圣遗物套装等
2. **解锁状态（Unlocked）**：
   - 集合类：`Set<id>`（获得过一次即可）
   - 计数类：`Map<id, count>`（击杀/捕获次数）
3. **同步（Sync）**：
   - 登录全量 `FullNotify`
   - 解锁时增量 `UpdateNotify`
   - 某些计数按需查询（如 kill num 查询包）

本仓库基本符合这个结构，但在“id 语义”上存在一些需要谨慎理解的细节（见 53.6）。

---

## 53.2 玩家持久化结构：`PlayerCodex`（存档）与字段语义

文件：`Grasscutter/src/main/java/emu/grasscutter/game/player/PlayerCodex.java`

它是 Morphia entity（会跟随 Player 持久化），并包含：

- `unlockedWeapon: Set<Integer>`：**存 itemId（武器）**
- `unlockedMaterial: Set<Integer>`：**存 itemId（材料）**
- `unlockedAnimal: Map<Integer, Integer>`：动物计数（key 的语义见 53.6）
- `unlockedReliquary: Set<Integer>`：圣遗物（会把 itemId 归一化到 “0 副词条形态”）
- `unlockedReliquarySuitCodex: Set<Integer>`：套装图鉴条目 id
- 以及 book/tip/view 等集合（当前实现基本未填充）

关键辅助逻辑：

- `setPlayer(player)` 会调用 `fixReliquaries()` 做旧存档迁移（把非规范化 id 归一）
- `checkUnlockedSuits(reliquaryId)`：当集齐某套装的所有部件，自动解锁套装 codex 条目

---

## 53.3 触发点 A：物品入包 → `checkAddedItem` 解锁图鉴

触发入口在背包 putItem：

- `Grasscutter/src/main/java/emu/grasscutter/game/inventory/Inventory.java#putItem`
  - `player.getCodex().checkAddedItem(item)`

这意味着一个很实用的语义：

> Codex 的“物品解锁”发生在 **该 itemId 第一次进入背包存储结构** 时；材料堆叠的后续加数量不会重复触发（但也不需要）。

`checkAddedItem(GameItem item)` 的规则（简化）：

- Weapon：`CodexWeaponDataIdMap.get(itemId)` 非空且 `unlockedWeapon.add(itemId)` 成功  
  → 保存玩家并发送 `PacketCodexDataUpdateNotify(type=2, id=codexWeapon.getId())`
- Material：只对特定 materialType（FOOD/WIDGET/EXCHANGE/AVATAR_MATERIAL/NOTICE_ADD_HP）进行 codex 解锁  
  → `PacketCodexDataUpdateNotify(type=4, id=codexMaterial.getId())`
- Reliquary：归一化 `reliquaryId = (itemId/10)*10`，加入 `unlockedReliquary`，并尝试解锁套装 codex（type=8）

从内容层角度，这给出一个“可控触发器”：

- 你只要让某个 itemId 能以正常方式入包，就能触发 codex 解锁与 UI 更新（无需 Lua）。

---

## 53.4 触发点 B：怪物死亡 → `checkAnimal` 计数（Kill）

怪物死亡触发在：

- `Grasscutter/src/main/java/emu/grasscutter/game/world/Scene.java#killEntity`

逻辑（简化）：

- 如果 attacker 是 Avatar（或某些 ClientGadget 的 owner 是 Avatar）：
  - `player.getCodex().checkAnimal(target, CountType.KILL)`

`PlayerCodex.checkAnimal(...)`：

1. 只处理 `target instanceof EntityMonster`
2. 取 `monsterId = monster.getMonsterData().getId()`
3. 用 `GameData.getCodexAnimalDataMap().get(monsterId)` 找图鉴配置
4. 若配置的 countType 与本次触发不匹配则忽略
5. `unlockedAnimal.merge(monsterId, 1, +1)`
6. 保存并发送 `PacketCodexDataUpdateNotify(type=3, id=monsterId)`

因此动物图鉴属于“计数类 Codex”：它会随击杀增长，而不是“一次解锁后就不再变”。

---

## 53.5 同步：`CodexDataFullNotify` + `CodexDataUpdateNotify` + KillNum 查询

### 53.5.1 登录全量：`PacketCodexDataFullNotify`

文件：`Grasscutter/src/main/java/emu/grasscutter/server/packet/send/PacketCodexDataFullNotify.java`

它会构造多个 `CodexTypeData(typeValue)`，并填充：

- type=1 Quests：遍历已完成主线（mainQuest finished）→ `codexQuest.getId()`
- type=2 Weapons：遍历 `unlockedWeapon(itemId)` → `codexWeapon.getId()`
- type=3 Animals：遍历 `unlockedAnimal(key, count)` → `codexAnimal.getId()`（见 53.6）
- type=4 Materials：遍历 `unlockedMaterial(itemId)` → `codexMaterial.getId()`
- type=8 Reliquary suit：遍历 `unlockedReliquarySuitCodex` → 直接作为 codexId

当前实现对 book/tip/view 等类型基本是空壳（type=5/6/7 未填）。

### 53.5.2 增量更新：`PacketCodexDataUpdateNotify`

文件：`Grasscutter/src/main/java/emu/grasscutter/server/packet/send/PacketCodexDataUpdateNotify.java`

它的 proto 仅包含：

- `typeValue`
- `id`

由各触发点负责决定 id 的语义（武器/材料/套装是 codexId，动物目前直接发送 monsterId）。

### 53.5.3 击杀数查询：`QueryCodexMonsterBeKilledNumReq/Rsp`

- recv：`HandlerQueryCodexMonsterBeKilledNumReq`
- send：`PacketQueryCodexMonsterBeKilledNumRsp`

Rsp 会对请求的 id 列表逐个检查：

- 若 `player.codex.unlockedAnimal` 包含该 key：
  - 返回 `beKilledNum = count`
  - `beCapturedNum` 固定 0

这意味着 kill count 并不在 FullNotify 里携带，而是客户端按需查询。

---

## 53.6 一个必须意识到的坑：不同 type 的 “id” 语义并不完全统一

在 `PlayerCodex` 里有一句注释：

> itemId is not codexId!

当前实现里确实存在多种 “id”：

- 对武器/材料：内部集合存 itemId，但 UpdateNotify/FullNotify 发的是 `codexData.getId()`
- 对动物：内部 map 的 key 是 monsterId，UpdateNotify 直接发 monsterId；FullNotify 则发 `codexAnimal.getId()`

如果 `codexAnimal.getId()` 与 monsterId **恰好一致**，那么这套实现是自洽的；  
但如果它们不同，就会出现：

- FullNotify 给了 A（codexId），QueryKilledNum 却在 map 里找 A（但 map 存的是 monsterId）→ 查不到计数

由于我们在这里只做“结构化拆解”，建议你把它当作一个需要验证的数据约束：

- 检查你资源包里的 `CodexAnimalData.id` 是否等于 monsterId（若不等，建议引擎侧统一 id 语义）

---

## 53.7 引擎边界与可扩展性判断

### 53.7.1 只改数据/资源能做的

- 通过“让物品能正常入包”来驱动武器/材料/套装解锁（无需 Lua）
- 通过“怪物可被击杀”来驱动动物计数

### 53.7.2 必须改引擎才能做的

- 完整实现 book/tip/view 等类别的解锁触发与同步
- 实现 `ITEM_USE_UNLOCK_CODEX`（当前 `ItemUseUnlockCodex.useItem()` 直接返回 false）
- 统一/严格化 codexId 的语义，避免不同 type 的 id 语义混乱
- 捕获（captured）计数（当前 `beCapturedNum` 固定 0）

---

## 53.8 小结

- Codex 是一个典型的“被动解锁系统”：背包入包与怪物击杀驱动解锁/计数，登录全量同步 + 增量更新 + 按需查询补充计数。
- 目前实现覆盖了武器/材料/动物/任务/圣遗物套装的一个可用子集，但在“id 语义统一性”和“其它类别完善”方面仍有明显引擎边界。

---

## Revision Notes

- 2026-01-31：首次撰写本专题；梳理 Codex 的入包/击杀触发、Full/Update/Query 同步方式，并标注“动物类 id 语义可能不一致”这一需要验证的边界点。

