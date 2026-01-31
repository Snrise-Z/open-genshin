# 47 专题：ItemUseAction/道具行为 DSL：`ItemExcel*` → `useOp/useParam[]` → `InventorySystem.useItem` 执行管线

本文把“背包道具使用（UseItem）”当成一门 **小型 DSL（数据驱动动作列表）** 来拆：  
道具是否可用、用在哪个目标、会触发哪些效果，主要由 **ExcelBinOutput 的物品字段（`itemUse`/`useTarget`/`satiationParams`）** 决定；Java 侧则提供 **统一执行器**（校验目标、处理饱腹、按动作列表执行、决定是否消耗道具）。

与其他章节关系：

- `analysis/10-quests-deep-dive.md`：部分道具可直接 `ITEM_USE_ACCEPT_QUEST` 启动任务，属于“道具→任务编排”的入口之一。
- `analysis/39-forging-pipeline.md` / `analysis/40-cooking-system.md` / `analysis/41-combine-and-compound.md`：大量“图纸/配方/功能解锁道具”最终都落在 ItemUseOp（如 `UNLOCK_FORGE/COOK_RECIPE/COMBINE`）上。
- `analysis/38-shop-economy-and-refresh.md`：`ITEM_USE_OPEN_RANDOM_CHEST` 实际走的是 ShopChest.v2（把“礼包”做成商店箱子抽取）。
- `analysis/50-buffs-food-satiation.md`：食物的饱腹与服务器 Buff 是 UseItem 管线里最重要的“前置门槛 + 效果”组合。

---

## 47.1 抽象模型：UseItem = Targeting + PreGate（饱腹等）+ ActionList + Consume + PostHook

用中性 ARPG 语言描述，一个“可用道具”通常可以拆成：

1. **Targeting（目标约束）**：对“用在谁身上/队伍/当前角色”的硬性要求。
2. **PreGate（前置门槛）**：例如饱腹、冷却、次数、开放状态等——决定“能不能用”。
3. **ActionList（动作列表）**：一组可组合的效果动作（治疗、加 buff、给物品、解锁系统…）。
4. **Consume（消耗）**：动作成功后才真正从背包扣除（这点非常关键）。
5. **PostHook（消耗后回调）**：某些动作在“扣除成功后”才执行真正的状态改变（如解锁图纸）。

本仓库的核心伪代码可以近似为：

```text
UseItemReq(targetGuid, itemGuid, count, optionId) →
  resolve itemData
  if !targeting_ok(itemData.useTarget, targetGuid): fail
  if itemData.satiationParams: if !addSatiation(...): fail
  ok = OR_reduce( action.useItem(params) for action in itemData.itemUseActions )
  if ok:
     inventory.remove(itemGuid, count)
     for action in itemData.itemUseActions: action.postUseItem(params)
     success
  else:
     fail (and item NOT consumed)
```

其中两处“编排层要牢记的语义”：

- **“成功判定”是 OR 聚合**：只要动作列表里 *至少一个* 返回 `true`，就算“使用成功”，道具才会被消耗。
- **动作不会短路**：即使前面的动作已经返回 `true`，后续动作仍会执行（可能产生副作用/性能问题）。

---

## 47.2 数据层入口：`ItemData` 的 `useTarget / itemUse[] / satiationParams`

### 47.2.1 物品数据从哪里来？

`ItemData` 同时承载材料/武器/圣遗物/家具等多类资源，加载入口在：

- `Grasscutter/src/main/java/emu/grasscutter/data/excels/ItemData.java`
- `@ResourceType` 指向：
  - `MaterialExcelConfigData.json`
  - `WeaponExcelConfigData.json`
  - `ReliquaryExcelConfigData.json`
  - `HomeWorldFurnitureExcelConfigData.json`

“道具使用 DSL”相关字段（只列与编排强相关的）：

- `useTarget: ItemUseTarget`：目标类型（NONE / 指定角色 / 指定存活角色 / 指定死亡角色 / 当前角色 / 当前队伍）
- `itemUse: List<ItemUseData>`：动作列表的原始数据（**useOp + useParam[]**）
- `itemUseActions: List<ItemUseAction>`：动作列表的运行时对象（由 `itemUse` 转换）
- `satiationParams: int[]`：食物饱腹参数（见 47.5）
- `maxUseCount`、`useOnGain` 等：目前实现中**基本未参与** UseItem 行为（属于“数据存在但引擎没接上”的典型）

### 47.2.2 `ItemUseData`：DSL 的最小语法单元

文件：`Grasscutter/src/main/java/emu/grasscutter/data/common/ItemUseData.java`

结构非常简单：

```text
ItemUseData {
  useOp: ItemUseOp   // 枚举（数值来自 Excel）
  useParam: String[] // 参数数组（字符串；由各动作自行解释）
}
```

### 47.2.3 `ItemUseOp`：动作枚举（并不等于“都可用”）

文件：`Grasscutter/src/main/java/emu/grasscutter/game/props/ItemUseOp.java`

它定义了大量 op（如 `ADD_CUR_HP / ADD_SERVER_BUFF / UNLOCK_FORGE / ...`），但**是否真的生效**取决于下一节的 mapping（有些 op 会被映射成 `null`，相当于“引擎不支持”）。

### 47.2.4 从 `itemUse[]` 到 `itemUseActions[]`：支持度决定“能不能用”

核心转换发生在：

- `Grasscutter/src/main/java/emu/grasscutter/data/excels/ItemData.java#onLoad`

逻辑要点：

1. `itemUse` 非空才会构建 `itemUseActions`
2. 过滤掉 `ITEM_USE_NONE`
3. `ItemUseAction.fromItemUseData(...)` 会把不支持的 op 映射为 `null`
4. `null` 会被过滤掉

这会带来一个非常容易踩坑的差异：

- **没有 `itemUse` 字段（`itemUseActions == null`）**：`useItemDirect` 会直接 `return true` → 道具会被消耗（哪怕没有效果）。
- **有 `itemUse`，但全部映射失败导致 `itemUseActions == []`（空列表）**：OR 聚合的初值是 `false`，空流会返回 `false` → 道具无法被使用（不会被消耗）。

做“只改数据”的内容时，一定要能区分这两种状态，否则会出现“同样看起来没有动作，但一个会被吃掉、一个用不了”的怪现象。

---

## 47.3 运行时入口：`UseItemReq` → `InventorySystem.useItem/useItemDirect`

### 47.3.1 协议入口

文件：`Grasscutter/src/main/java/emu/grasscutter/server/packet/recv/HandlerUseItemReq.java`

它从客户端包里取：

- `targetGuid`：使用目标（角色 guid）
- `guid`：道具实例 guid
- `count`：使用数量
- `optionIdx`：选项（用于“选择礼包/奖励”等）

然后直接调用：

- `GameServer.getInventorySystem().useItem(...)`

### 47.3.2 主执行器：`InventorySystem.useItem`

文件：`Grasscutter/src/main/java/emu/grasscutter/game/systems/InventorySystem.java`

关键语义：

1. 从背包取 `GameItem`，拿到 `ItemData`
2. 构造 `UseItemParams(player, useTarget, targetAvatar, count, optionId, isEnterMpDungeonTeam)`
3. **先**调用 `useItemDirect(itemData, params)` 判断是否“使用成功”
4. 成功后才：
   - `inventory.removeItem(item, count)` 真正扣道具
   - 对每个 action 调 `postUseItem(params)`
   - 回包 `PacketUseItemRsp(...)`

所以这个系统的正确心智模型是：

> 道具使用并不是“先扣再做效果”，而是“先试跑效果 → 成功才扣 → 扣完再做 postUseItem”。

---

## 47.4 Targeting（目标约束）目前非常“轻”

目标校验在 `InventorySystem.useItemDirect(...)` 的 `switch (params.itemUseTarget)` 中完成。

当前实现只做了最基本的存在性/存活性判断：

- `ITEM_USE_TARGET_SPECIFY_AVATAR`：必须提供目标
- `ITEM_USE_TARGET_SPECIFY_ALIVE_AVATAR`：目标必须存活
- `ITEM_USE_TARGET_SPECIFY_DEAD_AVATAR`：目标必须死亡
- `ITEM_USE_TARGET_NONE`：不校验
- `ITEM_USE_TARGET_CUR_AVATAR / CUR_TEAM`：目前没有额外约束（基本等于“信任客户端”）

对编排层的意义：

- 你如果想做“只能给当前角色用”“只能给队伍成员用”等更严格语义，**仅改数据不够**，需要补齐引擎侧的 target 校验。

---

## 47.5 食物的特殊前置：`satiationParams` 与 `PlayerUseFoodEvent`

当 `itemData.satiationParams` 非空，且 `targetAvatar` 存在时，会走“食物前置门槛”：

1. 触发插件事件：`PlayerUseFoodEvent`（可取消）
2. 计算 `satiationIncrease`（与最大生命值相关）
3. `SatiationManager.addSatiation(...)` 成功才允许继续

代码入口：

- `InventorySystem.useItemDirect(...)`
- `Grasscutter/src/main/java/emu/grasscutter/server/event/player/PlayerUseFoodEvent.java`
- `Grasscutter/src/main/java/emu/grasscutter/game/managers/SatiationManager.java`

一个对“玩法编排”很关键的细节：

- **饱腹是在动作列表之前结算的。**  
  如果后续所有 `itemUseActions` 都返回 `false`，道具不会被消耗，但饱腹可能已经增加（属于“前置副作用与消耗判定不一致”的潜在 bug/边界）。

更完整的饱腹与 Buff 语义建议结合阅读：`analysis/50-buffs-food-satiation.md`。

---

## 47.6 动作 DSL：`ItemUseAction.fromItemUseData` 的“已实现子集”

动作映射表在：

- `Grasscutter/src/main/java/emu/grasscutter/game/props/ItemUseAction/ItemUseAction.java`

你可以把它当作“脚本 API 清单”的同类东西：**它定义了内容层（Excel）能驱动的玩法能力边界**。

下面按类别总结“已实现且常用”的 op（并标注典型参数约定；`useParam[]` 由字符串解析为 int/float）：

### 47.6.1 数值成长类（升级材料）

- `ITEM_USE_ADD_EXP`：角色经验（`[amount]`）
- `ITEM_USE_ADD_WEAPON_EXP`：武器经验（`[amount]`）
- `ITEM_USE_ADD_RELIQUARY_EXP`：圣遗物经验（`[amount]`）

### 47.6.2 能量/体力类（部分实现）

- `ITEM_USE_ADD_ALL_ENERGY`、`ITEM_USE_ADD_ELEM_ENERGY`：加能量（细节依赖实现类）
- `ITEM_USE_ADD_CUR_STAMINA`：加当前体力（`[amount, icon?]`）

> 注意：`ADD_PERSIST_STAMINA / ADD_TEMPORARY_STAMINA` 等 op 在 mapping 里是 `null`（当前不可用）。

### 47.6.3 “给东西/开箱子/选择奖励”

- `ITEM_USE_ADD_ITEM`：给固定物品（`[itemId, count]`）
- `ITEM_USE_GAIN_AVATAR`：给角色卡（`[avatarId]`）
- `ITEM_USE_GAIN_NAME_CARD / GAIN_FLYCLOAK / GAIN_COSTUME`：外观类（实现较薄，有 TODO）
- `ITEM_USE_OPEN_RANDOM_CHEST`：礼包/商店箱子（`[chestId]` → `ShopSystem.getShopChestData`）
- `ITEM_USE_CHEST_SELECT_ITEM` / `ITEM_USE_ADD_SELECT_ITEM` / `ITEM_USE_GRANT_SELECT_REWARD`：
  - 依赖 `UseItemParams.optionId`（选第几个）
  - 本质是“把选中的 itemId 以一定数量给到玩家”

### 47.6.4 食物效果类

- `ITEM_USE_RELIVE_AVATAR`：复活（复活食物链路的常见第一步）
- `ITEM_USE_ADD_CUR_HP`：治疗（`[amount, icon]`；返回值与是否实际回血有关）
- `ITEM_USE_ADD_SERVER_BUFF`：加服务器 buff（`[buffId, durationSeconds]`）
- `ITEM_USE_MAKE_GADGET`：生成 gadget（常用于投掷物/临时物；细节依赖实现类）

### 47.6.5 “解锁类”（图纸/配方/系统开关）

这类动作有个共同点：很多实现把真正的“解锁”放在 `postUseItem`，以确保“先扣道具再解锁”。

- `ITEM_USE_UNLOCK_FORGE`：解锁锻造图纸（`[blueprintId]`，在 `postUseItem` 调 ForgingManager）
- `ITEM_USE_UNLOCK_COOK_RECIPE`：解锁食谱（`[recipeId]`，在 `postUseItem`）
- `ITEM_USE_UNLOCK_COMBINE`：解锁合成配方（`[combineId]`，在 `postUseItem`）
- `ITEM_USE_UNLOCK_FURNITURE_FORMULA / SUITE`：家园配方/套装解锁
- `ITEM_USE_UNLOCK_HOME_BGM`：家园 BGM 解锁

> 注意：`ITEM_USE_UNLOCK_CODEX` 虽然有类，但 `useItem()` 直接返回 `false`（等于“没有后端”）。

### 47.6.6 任务/账号类

- `ITEM_USE_ACCEPT_QUEST`：直接 `QuestManager.addQuest(questId)`（`[questId]`）
- `ITEM_USE_GAIN_CARD_PRODUCT`、`ITEM_USE_UNLOCK_PAID_BATTLE_PASS_NORMAL`：账号侧功能（实现依赖其它系统）

### 47.6.7 明确不可用（映射为 `null`）的 op（举例）

在 `ItemUseAction.fromItemUseData` 末尾，有一批 op 明确返回 `null`，包括：

- `ITEM_USE_DEL_SERVER_BUFF`
- `ITEM_USE_TRIGGER_ABILITY`
- `ITEM_USE_GAIN_RESIN_CARD_PRODUCT`
- `ITEM_USE_ADD_DUNGEON_COND_TIME`（小游戏碎片类）
- `ITEM_USE_ADD_CHANNELLER_SLAB_BUFF`（活动 buff 类）
- `ITEM_USE_ADD_REGIONAL_PLAY_VAR`（区域玩法变量类）

对内容层的结论就是：**Excel 里写了也不会生效**（会被过滤掉）。

---

## 47.7 成功判定与“是否消耗道具”的细粒度语义（很重要）

### 47.7.1 OR 聚合且不短路

`useItemDirect` 的返回值是：

- `actions.stream().map(use -> use.useItem(params)).reduce(false, (a,b) -> a || b)`

两个影响内容设计的点：

1. **不短路**：后续 action 一定会执行（即使前面已经成功）。
2. **不回滚**：任何 action 的副作用都不会因为“最后整体失败”而回滚。

### 47.7.2 只有 “useItemDirect == true” 才会扣道具

`InventorySystem.useItem(...)` 只有在 `useItemDirect(...) == true` 时才会：

- `inventory.removeItem(item, count)`
- `postUseItem(...)`

这意味着：

- 想做“必定消耗”的道具：至少保证一个 action *稳定返回 true*。
- 想做“条件消耗”（例如治疗没生效不消耗）：让 action 在无效时返回 false。

### 47.7.3 `postUseItem` 的失败不会阻止消耗

`postUseItem` 是在扣除道具之后执行的；即使它返回 `false`，道具也已经消耗，且没有补偿逻辑。  
因此解锁类道具如果 `postUseItem` 失败，会出现“道具没了但没解锁”的体验问题——这属于引擎层需要完善的事务语义。

---

## 47.8 “只改数据”能做的道具范式配方

下面给出几个尽量不改 Java 的可行配方（假设资源表里能找到对应 itemId/blueprintId 等）：

1. **固定礼包**：`ITEM_USE_ADD_ITEM`（给一组固定物品）  
   - 适合“登录礼包/补偿礼包/活动兑换包”
2. **选择礼包**：`CHEST_SELECT_ITEM` / `ADD_SELECT_ITEM`（依赖 `optionId`）  
   - 适合“自选材料/自选武器胚子”等
3. **配方解锁道具**：`UNLOCK_FORGE / UNLOCK_COOK_RECIPE / UNLOCK_COMBINE`  
   - 用道具驱动系统侧“解锁列表”
4. **任务触发道具**：`ACCEPT_QUEST`  
   - 让“道具→任务线”成为一种剧情入口
5. **食物/药剂（弱版）**：`ADD_CUR_HP + ADD_SERVER_BUFF`  
   - 注意让至少一个 action 稳定返回 true，否则可能出现“饱腹加了但道具没扣”的边界

做内容时的实用建议：

- **优先挑“已实现 op”**，把 `useParam` 写成最小正确值（避免解析失败导致 action 返回 false）。
- 若你想做“更像官方”的复杂道具（冷却、次数、跨系统联动、直接触发 Lua），就要把它当作引擎层扩展点（见下一节）。

---

## 47.9 引擎边界与待补点（把它当可扩展 DSL 的 TODO 列表）

站在“把它当 ARPG 引擎玩法编排层”的角度，这个 UseItem DSL 目前的关键边界包括：

1. **大量 ItemUseOp 未实现**：Excel 能写，但引擎会过滤掉（`null`），导致“用不了/没效果”。
2. **`useOnGain` 未接入**：无法做到“获得即自动使用”的奖励/解锁流程（需要引擎在入包处触发）。
3. **目标校验偏弱**：CUR_AVATAR/CUR_TEAM 等几乎没约束，更多靠客户端 UI。
4. **前置门槛与消耗判定可能不一致**：饱腹先结算，动作全失败时可能出现“免费增加饱腹”的副作用。
5. **缺少事务语义**：`postUseItem` 失败不补偿，道具会丢失。

如果你未来要把它当“可控 DSL”，建议把下面两个改动优先级提到前面：

- 给 `useItemDirect` 增加“短路/事务”选项（至少对解锁类道具更安全）。
- 把 “冷却/次数/OpenState” 这类门槛统一抽象成 PreGate（可配置），避免每种道具散落实现。

---

## 47.10 小结

- 本仓库的道具使用可以视为一门 **数据驱动动作 DSL**：`itemUse(useOp/useParam)` 决定效果组合，`InventorySystem.useItem` 决定执行与消耗语义。
- 最需要记住的两条运行时规律：**OR 聚合决定是否消耗**、**动作不短路且不回滚**。
- 只改数据能做的“礼包/配方解锁/任务触发/基础食物”已经够用；更复杂的体验（冷却、自动使用、触发脚本）需要下潜到引擎层补齐。

---

## Revision Notes

- 2026-01-31：首次撰写本专题；梳理 `ItemData.itemUse → ItemUseAction` 映射、`UseItemReq → InventorySystem.useItem` 执行与消耗语义，并标注“不短路/不回滚/饱腹先结算”等关键边界。

