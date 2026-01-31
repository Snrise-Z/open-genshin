# 31 专题：Ability / 技能数据管线（BinOutput → AbilityManager → Lua/实体行为）

本文把“战斗/技能”这一层尽量当成 **数据驱动系统** 来理解：  
在 Grasscutter 中，Ability 并不只是“一个 Java 技能函数”，而是从 `BinOutput/Ability`、`BinOutput/Talent`、`ExcelBinOutput/*Skill*` 等资源加载出来的一套“动作/修饰器图（actions/modifiers）”，再由 `AbilityManager` 在运行时执行。

你关心它的原因是：  
**很多看似要改 Java 的战斗玩法，其实可以（部分）通过改 Ability/Talent/OpenConfig 等数据实现**；并且 Ability 系统还提供了少量“回调到 Lua”的桥梁（非常适合把战斗行为接回玩法编排层）。

与其他章节关系：

- `analysis/02-lua-runtime-model.md`：ScriptLib 与事件系统（本文会提到 Ability 如何调用 Lua）。
- `analysis/15-gadget-controllers.md`：Entity Controller（Ability 的某些 action 会调用 gadget controller）。
- `analysis/30-multiplayer-and-ownership-boundaries.md`：AbilityManager 在多人里绑定 Host（重要边界）。

---

## 31.1 抽象模型：Ability = “动作/修饰器图” + “事件/Invoke 驱动执行器”

你可以用一个中性模型心算 Ability 系统：

1. **数据侧定义**
   - Ability（能力）有一组“事件钩子”：`onAdded / onRemoved / ...`
   - 还有一组 Modifier（修饰器）：
     - Modifier 自己也有 `onAdded/onRemoved/onThinkInterval/...` 等动作序列
2. **运行时执行**
   - 客户端/服务器触发某个钩子 → 形成 `AbilityInvokeEntry` 或内部调用
   - 引擎根据“localId → action/mixin”的映射找到具体动作
   - 分发给对应的 ActionHandler（Java 实现）执行

因此它像一个“数据驱动的行为图执行器”，而不是传统“技能写死在代码里”。

---

## 31.2 关键数据位置（你改数据主要改哪里）

### 31.2.1 Ability 数据（核心）

- `resources/BinOutput/Ability/Temp/*.json`
  - `ResourceLoader.loadAbilityModifiers()` 会递归加载这里的所有 JSON
  - 每个文件通常包含 `AbilityConfigData.Default`（里面是 `AbilityData`）

### 31.2.2 Avatar 的能力列表（Ability Embryos）

两种来源：

- 缓存：`data/AbilityEmbryos.json`（若存在，优先读取）
- 否则从：
  - `resources/BinOutput/Avatar/ConfigAvatar_*.json` 里提取 `abilities` 列表
  - 以及 `resources/BinOutput/AbilityGroup/AbilityGroup_Other_PlayerElementAbility.json`（玩家元素能力组）

### 31.2.3 天赋/命座与 OpenConfig（“注入额外能力/改技能点数”的桥）

- `resources/BinOutput/Talent/AvatarTalents/**/*.json`
- `resources/BinOutput/Talent/EquipTalents/*.json`

`ResourceLoader.loadTalents()` 会加载 TalentData；`loadOpenConfig()` 会从 Talent 文件里提取 `OpenConfigData[]`，转成 `OpenConfigEntry`：

- `AddAbility`：给角色额外能力（`extraAbilityEmbryos`）
- `talentIndex`：命座提供技能等级 +3 的标记
- `ModifySkillPoint`：技能充能次数/点数修改

---

## 31.3 引擎侧加载链路（从资源到 GameData 缓存）

核心入口：`Grasscutter/src/main/java/emu/grasscutter/data/ResourceLoader.java`

加载顺序（与 Ability 相关的部分）：

1. `loadAbilityEmbryos()`
   - 生成 `GameData.abilityEmbryoInfo`（avatarName → abilityName[]）
2. `loadTalents()`
   - 生成 `GameData.talents`（多个 TalentData map）
3. `loadOpenConfig()`
   - 生成 `GameData.openConfigEntries`（openConfigName → OpenConfigEntry）
4. `loadAbilityModifiers()`
   - 生成：
     - `GameData.abilityDataMap`（abilityName → AbilityData）
     - `GameData.abilityHashes`（hash → abilityName）

> 对“只改数据”来说，这意味着：你只要把文件放进对应目录，并保证 JSON 结构能被解析，就能被加载进运行时缓存。

---

## 31.4 运行时注入：Ability 是怎么挂到实体上的？

实体创建时通常会把自己的 ability data 挂上去（简化理解）：

- `EntityAvatar / EntityMonster / EntityGadget / EntityWeapon ...` 在创建时会调用：
  - `world.getHost().getAbilityManager().addAbilityToEntity(entity, data)`

这有两个含义：

1. Ability 的“执行器”在本仓库里是 **按 Host 绑定** 的（多人边界，见 `analysis/30`）。
2. 你改能力数据后，实体在生成时就会带上新的行为图（前提是客户端也能配合/不冲突）。

---

## 31.5 AbilityManager：action/mixin 的分发与覆盖度

入口类：`Grasscutter/src/main/java/emu/grasscutter/game/ability/AbilityManager.java`

它的核心机制是：

- 反射注册所有 `AbilityActionHandler`：
  - 通过注解 `@AbilityAction(AbilityModifierAction.Type.X)`
  - 放到 `actionHandlers` 映射
- 当收到 `AbilityInvokeEntry` 时：
  - 定位 ability / modifier / localId
  - 找到 `AbilityModifierAction`
  - 丢进线程池执行 handler

### 31.5.1 当前仓库已实现的 action（重要清单）

在 `game/ability/actions/` 目录能看到实际覆盖的动作类型主要包括：

- `ApplyModifier`
- `AvatarSkillStart`
- `CopyGlobalValue`
- `CreateGadget`
- `DebugLog`
- `ExecuteGadgetLua`（回调 gadget controller，非常重要）
- `GenerateElemBall`
- `HealHP`
- `KillSelf`
- `LoseHP`
- `Predicated`
- `ServerLuaCall`（直接调用 group Lua 函数，非常重要）
- `SetGlobalValue`
- `SetGlobalValueToOverrideMap`
- `SetRandomOverrideMapValue`
- `Summon`

其他未实现的 action 类型会被忽略/记录缺失（可通过日志观察）。

### 31.5.2 mixin：本仓库目前几乎是空壳

`game/ability/mixins/` 目录只有基类/注解，暂无具体 mixin 实现。  
所以你在数据里配了很多 mixin，运行时大概率不会生效（属于“数据存在但引擎缺口”的典型）。

---

## 31.6 Ability → Lua 的两条关键桥梁（把战斗接回玩法编排层）

这部分对“把它当 ARPG 引擎”非常关键：  
如果你能让能力系统在某些条件下回调 Lua，你就能用 Lua 继续编排“刷怪/机关/任务/奖励”。

### 31.6.1 `ExecuteGadgetLua`：回调 gadget controller（实体控制器脚本）

实现：`ActionExecuteGadgetLua`

行为：

- 如果 ability 的 owner 实体存在 `EntityController`（由 `Server/GadgetMapping.json` 挂载）
- 则调用：
  - `controller.onClientExecuteRequest(owner, param1, param2, param3)`

意义：

- 你可以通过 Ability 数据驱动“触发某个 gadget controller 的回调”，实现复杂机关的技能交互。

### 31.6.2 `ServerLuaCall`：直接调用 group 脚本函数

实现：`ActionServerLuaCall`

行为：

- 找到目标 group 的 bindings
- 取出 `functionName`
- 直接 `luaFunction.call(ScriptLibLua)`

支持两种目标：

- `FromGroup`：从实体所属 group 调用
- `SpecificGroup`：从 action 参数指定 groupId 调用

意义：

- 这是一条“能力系统 → 玩法编排 DSL（Group Lua）”的硬桥。
- 你可以把它当成“战斗触发器”：当某个技能命中/某个 modifier 生效时，直接调用 Lua 进入玩法阶段机。

> 注意：这类桥梁很强，但也很危险：它把战斗系统与关卡脚本强耦合，调试时要特别关注调用时机与线程池异步执行。

---

## 31.7 Skill/Talent/OpenConfig：如何“只改数据”影响技能表现（可操作建议）

### 31.7.1 技能数据（ExcelBinOutput）

你会频繁用到这些表：

- `resources/ExcelBinOutput/AvatarSkillExcelConfigData.json`：技能基础定义（maxChargeNum 等）
- `resources/ExcelBinOutput/AvatarSkillDepotExcelConfigData.json`：技能组/skill depot（角色 E/Q/普攻等 slot）
- `resources/ExcelBinOutput/ProudSkillExcelConfigData.json`：技能等级数据（消耗/倍率等）
- `resources/ExcelBinOutput/AvatarTalentExcelConfigData.json`：天赋/命座，含 `openConfig`

### 31.7.2 OpenConfig：命座/天赋如何“注入能力”

在 `Avatar` 的实现中（`Avatar.addToExtraAbilityEmbryos` / `calcConstellation`）：

- 读取 `AvatarTalentData.openConfig` → 查 `GameData.openConfigEntries`
- 若 `OpenConfigEntry.addAbilities` 非空 → 把 abilityName 加到 `extraAbilityEmbryos`
- 这些 extra embryos 会导致客户端收到 `PacketAbilityChangeNotify`

这给了你一个“只改数据”的抓手：

- 你可以通过修改 Talent/OpenConfig 的数据，让某个角色额外拥有某些 ability
- 前提是这些 ability 的 action 类型在本仓库实现覆盖内（见 31.5.1）

### 31.7.3 技能等级 +3 / 额外充能次数

`OpenConfigEntry.extraTalentIndex` 与 `skillPointModifiers` 会影响：

- 特定技能的额外等级（+3）
- 技能最大充能次数（`skillExtraChargeMap`）

这部分属于“角色成长系统”的数据驱动点，通常比直接改 Java 更稳。

---

## 31.8 可扩展性边界：哪些战斗玩法能靠改数据做？哪些做不了？

**更可能只改数据就能做的：**

- 给某类实体增加/替换 ability 列表（Embryos/OpenConfig）
- 调整部分 action 的参数（如 Heal/LoseHP/CreateGadget/Summon）
- 通过 `ServerLuaCall` 把战斗触发接回 Lua（编排奖励、阶段切换）

**大概率需要改 Java 的：**

- 未实现的 action/mixin 类型（数据写了也不会执行）
- 复杂的命中判定/元素反应/仇恨/AI 等（属于战斗核心）
- 更细粒度的多人同步与权限（AbilityManager 绑定 host 的问题）

---

## 31.9 小结

- Ability 系统是“数据驱动行为图 + 引擎执行器”的组合；关键数据在 `BinOutput/Ability/Temp`、`BinOutput/Talent` 与 `ExcelBinOutput/*Skill*`。
- 本仓库 action 覆盖有限，但提供了两条非常关键的 Ability → Lua 桥梁：
  - `ExecuteGadgetLua`（回调 gadget controller）
  - `ServerLuaCall`（直接调用 group Lua 函数）
- 当你想做“战斗触发玩法编排”，优先利用这两条桥，而不是一上来就改 Java。

---

## Revision Notes

- 2026-01-31：首次撰写本专题；梳理了 Ability/Talent/OpenConfig 的资源加载链路、action 覆盖清单，以及 Ability → Lua 的两条关键桥梁。

