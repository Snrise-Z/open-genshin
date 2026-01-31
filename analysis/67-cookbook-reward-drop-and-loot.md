# 67 内容制作 Cookbook：奖励/掉落制作（Chest/Monster/DropTable/drop_tag）与多人归属

本文给你一套“内容作者视角”的奖励/掉落制作配方：  
你做遭遇战/解谜/活动时，最终都需要回答：**给玩家什么？怎么给？掉在地上还是直接进背包？多人时归属怎么处理？**

与其他章节关系：

- `analysis/16-reward-drop-item.md`：奖励/掉落/物品链路的系统性拆解。
- `analysis/51-drop-systems-new-vs-legacy.md`：新旧掉落栈并存的真实情况（为什么你会“看起来掉落不生效”）。
- `analysis/36-resource-layering-and-overrides.md`：`resources/Server` 的 DropTable 覆盖层与工程实践。
- `analysis/30-multiplayer-and-ownership-boundaries.md`：多人房主归属边界（宝箱/掉落常见坑）。

---

## 67.1 你能用哪些“发奖方式”？（按内容制作常用程度排序）

### 方式 A：宝箱（Chest Gadget）发奖（最常见）

适用：

- 解谜完成给奖励
- 遭遇战清怪给奖励
- 活动结算给奖励（简化版）

优点：玩法表达直观，生态脚本大量复用；缺点：多人时通常是房主领取。

### 方式 B：怪物掉落（Monster Drop）

适用：

- 纯战斗收益
- 刷怪玩法的材料/经验/货币

优点：天然结合战斗；缺点：掉落表复杂，容易陷入“改了不掉”的排障。

### 方式 C：Quest Exec 发奖/扣物（任务结算）

适用：

- 剧情/任务阶段结算
- 不想在世界里生成掉落物/宝箱

优点：更像“任务系统的副作用”；缺点：取决于 QuestExec handler 覆盖度（见 `analysis/27`）。

> 本 Cookbook 重点覆盖 A/B（对内容作者最通用），并给出 C 的选型建议。

---

## 67.2 先讲清新旧掉落栈：你改的是哪一套？

本仓库运行时存在两条并行路径（简化）：

1) **新掉落系统（DropSystem）**
   - 依赖：`resources/Server/DropTableExcelConfigData.json`（DropTable）
   - `drop_tag` 还会额外依赖：`data/ChestDrop.json` / `data/MonsterDrop.json`（tag → dropId 的映射）
2) **旧掉落系统（DropSystemLegacy / WorldDataSystem handlers）**
   - 依赖：`data/Drop.json`、`data/ChestReward.json`、`data/MonsterDrop.json` 等

新系统是否启用与配置有关（例如 `enableScriptInBigWorld`），但即使启用，新系统“算不出来”时也可能回退到旧系统（尤其宝箱）。

内容作者的实务建议：

- 你在做自制内容时，最好**显式选定一条路径**，并按它的数据结构去配；
- 不要混着写 `drop_id/chest_drop_id/drop_tag` 还指望“总有一个会掉”——那只会让排障更难。

---

## 67.3 配方 A：做一个“可控宝箱奖励”

### 67.3.1 你要在 group 脚本里填哪些字段？

宝箱 gadget（`SceneGadget`）常见字段：

- `gadget_id`：宝箱类型（复用现成）
- `chest_drop_id`：直接指定 DropTable id（新系统）
- `drop_count`：roll 次数（`processDrop` 会按次数重复）
- `drop_tag`：用 tag → dropId（新系统/或回退旧系统）
- `isOneoff=true`：一次性（开过就不再可再次领取）
- `persistent=true`：持久化（配合 group instance 记录）

示例（只示意字段形状）：

```lua
gadgets = {
  { config_id = 90001, gadget_id = 70211111, pos = ..., level = 1,
    chest_drop_id = 20090001, drop_count = 1,
    isOneoff = true, persistent = true }
}
```

### 67.3.2 选择 `chest_drop_id` vs `drop_tag`

选型建议：

- 想要“完全可控、少依赖映射” → 用 `chest_drop_id`
- 想要“复用生态里已有的掉落 tag（按等级区分）” → 用 `drop_tag`

在实现里，宝箱交互（`GadgetChest.onInteract`）的优先级大致是：

1) 有 `drop_tag`：`handleChestDrop(drop_tag, chest.level, gadget)`
2) 否则有 `chest_drop_id`：`handleChestDrop(chest_drop_id, drop_count, gadget)`
3) 仍失败：回退旧宝箱系统（按 gadget jsonName 找 handler）

### 67.3.3 多人归属：为什么“只有房主能开宝箱”？

在新掉落系统路径里，普通宝箱有一个硬限制：

- **只有 world host 才能开启**（否则直接 return false）

这会直接影响你做多人玩法时的奖励体验：

- 如果你希望“全员都能拿到奖励”，宝箱不是好载体  
  （你需要改成掉落直接入包、或按玩家各刷一个实例化奖励点，或下潜引擎层改规则）

---

## 67.4 配方 B：做一个“可控怪物掉落”

### 67.4.1 你在 group 脚本里有哪些入口？

怪物配置（`SceneMonster`）常用字段：

- `drop_id`：直接指定 DropTable id（新系统）
- `drop_tag`：tag → dropId（通过 `data/MonsterDrop.json`）

示例：

```lua
monsters = {
  { config_id = 20001, monster_id = 21010101, pos = ..., level = 1, drop_tag = "史莱姆" }
}
```

### 67.4.2 `drop_tag` 的优势：按等级映射 dropId

新系统里，`drop_tag` 会先在 `data/MonsterDrop.json` 里按 `minLevel` 选一个最合适的 dropId：

```json
{ "minLevel": 1, "index": "史莱姆", "dropId": 300000000, "dropCount": 1 }
```

这允许你：

- 同一个 tag（同类怪）在不同等级掉不同表
- 内容作者只需要在脚本里写一个语义化 tag

### 67.4.3 `drop_id` 的优势：最直接、最可控

如果你希望“这个遭遇战房间掉固定奖励”，直接给怪写 `drop_id` 往往更直观：

- 不依赖 MonsterDrop.json 的 tag 映射
- 不受怪物等级段影响（除非你在 DropTable 里自己做分层）

---

## 67.5 DropTableExcelConfigData：如何新增一个自定义 DropTable（核心）

DropTable（`resources/Server/DropTableExcelConfigData.json`）是一张大表（JSON 数组）。每条记录大致长这样：

```json
{
  "id": 20090001,
  "randomType": 1,
  "dropVec": [
    { "itemId": 202, "countRange": "500", "weight": 10000 },
    { "itemId": 104011, "countRange": "3", "weight": 10000 }
  ],
  "fallToGround": true
}
```

你需要理解的关键字段：

- `id`：DropTable id（脚本里的 `drop_id/chest_drop_id` 最终要指到它）
- `randomType`：
  - `0`：从 dropVec 按权重抽 1 项
  - `1`：dropVec 每项独立按概率触发（weight/10000）
- `countRange`：
  - `"3"`：固定 3
  - `"1;3"`：1..3 随机
  - `"2.4"`：期望值（小数部分用概率决定是否 +1）
- `fallToGround`：
  - `true`：生成掉落物（需要拾取/自动拾取逻辑）
  - `false`：直接入包（怪物掉落会对场景内玩家循环入包；宝箱掉落只给房主）

工程建议：

- 不要手工编辑一行超长 JSON；用脚本/格式化工具在内容仓库里维护拆分版本，再生成最终文件。
- 优先把你自制的 DropTable id 放在一个连续区间（方便 grep 与回滚）。

---

## 67.6 常见坑与排障（按优先级）

1. **宝箱打开了但没任何奖励**
   - 你用了 `chest_drop_id`，但 DropTable 里没有这个 id
   - 或 DropTable 里 dropVec 为空/weightSum 为 0
2. **怪物不掉东西**
   - 新系统 `handleMonsterDrop` 返回 false 会回退旧系统（大世界场景）；你以为你改的是新系统，其实在跑旧系统
   - `drop_tag` 在 `MonsterDrop.json` 里没有对应 index（dropId=0）
3. **多人体验不符合预期**
   - 宝箱：默认房主开启、房主得奖
   - 掉地掉落：归属/拾取权限由 dropItems 决定，可能与你想象不同（需要读 `analysis/30` 与 DropSystem 实现）

---

## 67.7 小结

- 内容作者最常用的发奖方式是“宝箱/怪物掉落”，但必须先选定你在用的新/旧掉落栈。
- `drop_tag` 适合语义化与等级分段；`drop_id/chest_drop_id` 适合精确可控。
- 多人归属是硬边界：宝箱在新系统里基本是房主奖励；想做“全员奖励”通常要换载体或下潜引擎。

---

## Revision Notes

- 2026-01-31：首次撰写本配方；从内容作者视角梳理宝箱/怪物掉落的配置入口、新旧掉落栈与回退路径、DropTable 的关键字段语义及多人归属的核心限制。

