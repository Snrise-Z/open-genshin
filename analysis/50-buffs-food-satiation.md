# 50 专题：服务器 Buff + 食物饱腹：`satiationParams` 前置门槛 → `ITEM_USE_ADD_SERVER_BUFF` → `PlayerBuffManager` 计时与同步

本文把“食物/药剂”的效果系统拆成两块并合并理解：

1. **饱腹（Satiation）**：决定“能不能吃”，以及“吃撑惩罚”的时间语义；
2. **服务器 Buff（Server Buff）**：决定“吃了有什么效果”，并在运行时维护持续时间、互斥组、过期通知。

这两块在运行时会被 `UseItem` 管线串起来：**先判饱腹，再执行 ItemUseAction 动作列表**。

与其他章节关系：

- `analysis/47-itemuse-dsl-and-useitem-pipeline.md`：饱腹判断发生在 `InventorySystem.useItemDirect` 的动作列表之前，是 UseItem DSL 的一部分。
- `analysis/31-ability-and-skill-data-pipeline.md`：Server Buff 的效果依赖 Ability/Modifier 数据（`BuffData` 指向 `abilityName/modifierName`）。
- `analysis/44-stamina-system.md` / `analysis/45-energy-system.md`：食物/药剂往往影响体力/能量/属性；本仓库目前以“服务器 buff + 少量直接数值修改”为主。

---

## 50.1 食物使用的总流程：先饱腹、再动作、成功才消耗

入口在：

- `Grasscutter/src/main/java/emu/grasscutter/game/systems/InventorySystem.java#useItemDirect`

当 `ItemData.satiationParams` 非空且存在目标角色时，UseItem 会先做：

1. 触发插件事件 `PlayerUseFoodEvent`（可取消）
2. 计算饱腹增量 `satiationIncrease`
3. 调用 `SatiationManager.addSatiation(...)`  
   - 返回 false → 整个 UseItem 失败（不会消耗道具）
4. 之后才进入 `itemUseActions` 的执行（例如治疗、加 buff 等）

对内容设计的影响：

- 饱腹是一个 **PreGate**：你可以把它理解成“食物冷却/吃撑惩罚”的统一门槛。
- 但当前实现存在“前置副作用与是否消耗道具不同步”的边界（见 50.7.3）。

---

## 50.2 饱腹系统：`SatiationManager` 的数据、时间与每秒 tick

文件：`Grasscutter/src/main/java/emu/grasscutter/game/managers/SatiationManager.java`

### 50.2.1 饱腹值的单位与上限

代码注释写：

- 饱腹最大 10000，但在“过量进食”情况下可以超过（用于惩罚）

实现里存在缩放：

- `satiation = round(satiationIncrease * 100)`（把浮点增量转为整数值）
- `avatar.addSatiation(value)` 等方法以整数存储

因此在“玩法编排层”里，你可以把饱腹理解为：

- 一个 **0..10000 的整数刻度**（外加可能溢出部分），由食物参数计算得到

### 50.2.2 时间来源：以 `player.clientTime` 为参考 + 每秒服务器衰减

`SatiationManager.addSatiation` 会先推送：

- `PacketPlayerGameTimeNotify`
- `PacketPlayerTimeNotify`

然后用：

- `playerTime = player.getClientTime() / 1000`

来计算 `finishTime/penaltyTime` 并发送 `PacketAvatarSatiationDataNotify`。

同时，真实的饱腹减少是服务器每秒 tick 做的（见 50.2.5）。  
所以你可以把它抽象成：

- **服务器 authoritative 的衰减** + **客户端 UI 需要的时间戳提示**

### 50.2.3 饱腹增量来源：`ItemData.satiationParams`

在 `InventorySystem.useItemDirect` 中：

- `satiationIncrease = satiationParams[0] + satiationParams[1] / targetMaxHp`

也就是：

- 一个常量项 + 一个“按最大生命值比例”的项（让不同血量角色吃同一种食物时饱腹不同）

### 50.2.4 过量惩罚（Penalty）语义

`SatiationManager.addSatiation` 会在某些情况下设置惩罚：

- 惩罚时间：固定增加 30 秒（代码注释）
- 惩罚值：`3000`（随后每秒按 100 减，约 30 秒清空）

注意：当前实现的阈值判断式存在“重复加当前饱腹”的疑点（潜在 bug），因此如果你要做严谨规则复刻，建议把它当作引擎侧待修正项。

### 50.2.5 每秒衰减：`Player.onTick()` 调 `reduceSatiation()`

玩家 tick 入口：

- `Grasscutter/src/main/java/emu/grasscutter/game/player/Player.java#onTick`

每秒执行（对每个 avatar）：

- 若有惩罚：按 1/s 速度减惩罚（`reduceSatiationPenalty(100)`）
- 否则：按 0.3/s 速度减饱腹（`reduceSatiation(30)`）

并且为了让客户端 UI 正常刷新，代码采取了一个“粗暴但有效”的策略：

- 每 tick 对每个有饱腹的 avatar 调一次 `addSatiation(avatar, 0, 0)` 来发包

这说明饱腹 UI 的刷新依赖持续推送，而不是客户端纯本地倒计时。

---

## 50.3 服务器 Buff：`PlayerBuffManager` 的互斥组、持续时间与过期同步

文件：`Grasscutter/src/main/java/emu/grasscutter/game/player/PlayerBuffManager.java`

### 50.3.1 一个关键边界：BuffManager 是 transient（不持久化）

在 `Player` 中：

- `@Getter private transient PlayerBuffManager buffManager;`

意味着：

- 服务器 buff 目前是 **在线运行态**（重登一般会消失）
- `BuffData.isPersistent` 虽然存在，但当前 manager 逻辑并未据此做持久化恢复

这对做“活动增益/长效状态”的内容非常关键：很多看似“应该持久”的 buff，在当前实现里更像“临时效果”。

### 50.3.2 关键结构：按 `groupId` 存储（互斥组）

核心字段：

- `buffs: Int2ObjectMap<PlayerBuff>`，key 是 **`BuffData.groupId`**

语义：

- 同一个 `groupId` 的 buff 会互相替换（先 remove 再 add）

因此在内容层做“叠加/互斥”时，**groupId** 是最重要的设计变量之一。

### 50.3.3 `addBuff(buffId, duration, target)` 做了什么？

流程（压缩版）：

1. 从 Excel 取 `BuffData`（`GameData.getBuffDataMap().get(buffId)`）
2. 尝试解析 Ability/Modifier，并执行 `onAdded` 动作  
   - 当前实现里显式处理了 `HealHP`（会对 target 直接回血）
3. 决定持续时间：
   - `duration < 0` 时用 `buffData.time`
   - 若 `duration <= 0`：直接返回（**不会把 buff 放进 manager**）
4. `removeBuff(buffData.groupId)`（互斥）
5. 创建 `PlayerBuff(uid, buffData, duration)`，记录 `endTime`
6. 发送 `PacketServerBuffChangeNotify(ADD)`

### 50.3.4 一个关键边界：注释说“duration=0 表示无限”，但实现并不支持

`PlayerBuffManager.addBuff` 的 Javadoc 写：

- “duration=0 for infinite buff”

但代码是：

- `if (duration <= 0) return ...;`（不会 add 到 `buffs`）

所以当前实现里：

- **duration=0 不会产生持续 buff**（更像“只跑 onAdded 的一次性效果”）

### 50.3.5 过期与删除：`onTick()` 每秒清理并下发 DEL

`Player.onTick()` 每秒调用 `buffManager.onTick()`：

- 当前时间 > buff.endTime → 从 map 移除，并放入 `pendingBuffs`
- `pendingBuffs` 非空 → 发送 `PacketServerBuffChangeNotify(DEL, pendingBuffs)`

因此 server buff 是一个标准的“定时过期状态机”。

---

## 50.4 道具如何加 buff/回血？（ItemUseAction 侧的落点）

### 50.4.1 `ITEM_USE_ADD_SERVER_BUFF`

实现：

- `Grasscutter/src/main/java/emu/grasscutter/game/props/ItemUseAction/ItemUseAddServerBuff.java`

参数约定：

- `useParam[0]`：buffId
- `useParam[1]`：duration 秒（可缺省）

执行：

- `params.player.getBuffManager().addBuff(buffId, duration, params.targetAvatar)`

### 50.4.2 `ITEM_USE_ADD_CUR_HP`

实现：

- `Grasscutter/src/main/java/emu/grasscutter/game/props/ItemUseAction/ItemUseAddCurHp.java`

它会根据是否“实际回血”返回 true/false（满血可能返回 false）。  
因此如果你的食物只有 `ADD_CUR_HP`，在某些情况下可能因为“无效治疗”而导致道具不被消耗（见 47 章 OR 聚合语义）。

### 50.4.3 `ITEM_USE_RELIVE_AVATAR`

复活食物链路通常是：

- `RELIVE_AVATAR`（让死亡角色复活）+ `ADD_CUR_HP`（给复活后生命值）

---

## 50.5 数据侧关键表：`BuffExcelConfigData.json`（BuffData）+ Ability/Modifier

`BuffData` 定义在：

- `Grasscutter/src/main/java/emu/grasscutter/data/excels/BuffData.java`

加载自：

- `resources/ExcelBinOutput/BuffExcelConfigData.json`

关键字段（内容层最关心的）：

- `serverBuffId`：buffId（对外的 id）
- `groupId`：互斥组
- `time`：默认持续时间
- `serverBuffType`：客户端展示/分类相关
- `abilityName` / `modifierName`：把 buff 连接到 ability 系统的“效果定义”
- `isPersistent`：数据层声明“是否持久”，但当前 `PlayerBuffManager` 未实现持久化恢复

从引擎抽象看，这是经典设计：

> Buff 只是“引用 + 参数 + 时长 + 互斥组”，真正效果来自 Ability/Modifier 的可组合动作。

但当前实现里，Ability/Modifier 的执行覆盖度有限（至少 `HealHP` 有处理），所以你需要按需做“哪些 buff 真有效”的审计。

---

## 50.6 内容编排配方：如何做一个“稳定可消耗”的食物/药剂？

结合 47 章的 UseItem 消耗语义，这里给出几条经验公式：

### 50.6.1 食物建议至少包含一个“稳定返回 true 的 action”

原因：

- `InventorySystem` 以 OR 聚合决定是否消耗
- `ADD_CUR_HP` 可能因为满血而返回 false

因此你可以：

- “治疗 + 加 buff”并存（`ADD_CUR_HP` + `ADD_SERVER_BUFF`）  
  让 `ADD_SERVER_BUFF` 作为“稳定成功”的兜底（前提是 buffId 能被加载）。

### 50.6.2 复活食物的常见组合

- `RELIVE_AVATAR` + `ADD_CUR_HP` +（可选）`ADD_SERVER_BUFF`

其中复活通常需要目标是死亡角色（`useTarget` 设为 `SPECIFY_DEAD_AVATAR`）。

### 50.6.3 Buff 的互斥与叠加：用 groupId 设计“同类互斥”

- 同 groupId：后吃的覆盖前吃的（互斥）
- 不同 groupId：可以并存（叠加）

如果你在自制内容里想做“同一类药剂只能保留一个”，就让它们共享一个 groupId。

---

## 50.7 引擎边界与潜在坑（内容作者需要知道）

### 50.7.1 无限 buff 不可用（duration=0 不生效）

这会影响很多“持续型系统”设计：例如你想做一个长期状态（地区祝福、活动增益），仅靠 `ITEM_USE_ADD_SERVER_BUFF` 很难做到“永久”。

### 50.7.2 Ability/Modifier 覆盖度决定 buff 真实效果

即使 BuffData 存在，如果能力系统没有对该 modifier/action 做到位处理，效果可能非常有限。  
这类问题应该按 `analysis/31-ability-and-skill-data-pipeline.md` 的方法做覆盖审计。

### 50.7.3 饱腹与消耗判定可能脱钩（前置副作用）

饱腹在动作列表之前结算：  
若后续动作全部失败，道具不被消耗，但饱腹可能已增加——这属于“引擎事务语义缺失”导致的边界。

### 50.7.4 每秒推送饱腹数据可能较重

当前实现为了让客户端 UI 正常，采用了“每 tick 对有饱腹的 avatar 强制发包”的策略；当你做大量食物测试时可能出现网络包量异常（属于工程优化点）。

---

## 50.8 小结

- 食物/药剂在本仓库的关键链路是：`satiationParams` 做前置门槛 → 通过 ItemUseAction 执行效果 → `PlayerBuffManager` 维护持续状态。
- 饱腹是“可配置门槛”，Server Buff 是“可配置持续效果”，两者组合构成了一个通用 ARPG 的 Consumable 模块雏形。
- 目前最重要的引擎边界包括：buff 不持久化、无限 buff 不支持、Ability 覆盖度有限、饱腹与消耗判定可能不一致。

---

## Revision Notes

- 2026-01-31：首次撰写本专题；梳理饱腹系统的计时/衰减与发包、服务器 buff 的 groupId 互斥与过期清理，并指出 buff 不持久化与 duration=0 不会产生无限 buff 等关键边界。

