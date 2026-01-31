# 44 专题：Stamina/体力系统：MotionState 分类 → 200ms Tick 消耗/恢复 → 溺水与载具耐力

本文把“体力（Stamina）”当成一个典型的 **移动状态机驱动资源条** 来拆：  
它的输入是“玩家/载具的 MotionState 与技能事件”，输出是“体力变化（消耗/恢复）+ 特殊惩罚（溺水死亡）”。

与其他章节关系：

- `analysis/31-ability-and-skill-data-pipeline.md`：体力与技能/Ability 的交互点（MixinCostStamina、技能成功事件）在实现上有明显耦合与缺口。

---

## 44.1 抽象模型：Stamina = Resource + StateMachine + Tick Integrator

用中性 ARPG 模型描述：

- **Resource（资源条）**：当前值、最大值（通常以 100 倍存储，UI 再除以 100 显示）
- **StateMachine（状态机）**：RUN/CLIMB/SWIM/FLY/... 不同状态对应不同消耗/恢复曲线
- **Tick Integrator（定时积分器）**：每隔 Δt 计算一次“本 tick 应该变化多少”
- **Immediate Cost（一次性消耗）**：例如冲刺起步/攀爬起步/攀爬跳
- **Penalties（惩罚）**：例如游泳体力耗尽导致溺水

本仓库的实现非常直观：`StaminaManager` 基本就是“把 MotionState 分类 → 映射到 ConsumptionType → 每 200ms 更新一次体力”。

---

## 44.2 核心文件与入口

### 44.2.1 `StaminaManager`

文件：`Grasscutter/src/main/java/emu/grasscutter/game/managers/stamina/StaminaManager.java`

关键职责：

- 维护当前 motion state 与坐标（用于判断“是否移动”）
- 在 Timer 中以固定频率计算持续消耗/恢复
- 在状态切换时执行一次性消耗
- 处理溺水与载具耐力
- 提供 before/after listener（给插件/扩展用）

### 44.2.2 体力变化的“基本单位”：`Consumption` / `ConsumptionType`

文件：

- `Grasscutter/src/main/java/emu/grasscutter/game/managers/stamina/Consumption.java`
- `Grasscutter/src/main/java/emu/grasscutter/game/managers/stamina/ConsumptionType.java`

`ConsumptionType` 定义了每 tick 的默认变化量（负数=消耗，正数=恢复）。  
由于 tick 周期是 200ms（5Hz），所以这些数值本质上是“每 200ms 变化多少”。

> 体力的存储通常是“显示值 × 100”，因此 `-150` 可以理解为“每 tick -1.5 点显示体力”（具体视客户端显示规则）。

---

## 44.3 驱动源：MotionState 与坐标差分（判断是否移动）

### 44.3.1 MotionState 分类表（实现内置）

`StaminaManager` 内部维护了一个 `MotionStatesCategorized` 映射，把大量 MotionState 分组为：

- CLIMB / DASH / FLY / RUN / WALK / STANDBY / SWIM / SKIFF / OTHER / NOCOST_NORECOVER / IGNORE

你不需要背完整列表，但要记住它的用途：

- **先按 MotionState 找“属于哪个大类”**
- **再用该类选择对应的消耗计算器**

### 44.3.2 是否移动：`isPlayerMoving()`

体力的持续消耗（例如攀爬）通常要求“角色在动”。  
实现用“坐标差分阈值”判断：

- `|Δx| > 0.3` 或 `|Δy| > 0.2` 或 `|Δz| > 0.3`

坐标来源于：

- `handleCombatInvocationsNotify(session, moveInfo, entity)` 里读 `motionInfo.pos`

---

## 44.4 200ms Tick：持续消耗/恢复的主循环（SustainedStaminaHandler）

`startSustainedStaminaHandler()` 会启动一个 Timer：

- `scheduleAtFixedRate(..., 0, 200)` → 每 200ms tick

tick 内部的大致逻辑：

1. 若玩家在移动、或体力未满（角色或载具） → 计算消耗/恢复
2. 根据当前 state 选一个 `Consumption`：
   - CLIMB → `getClimbConsumption()`
   - DASH → `getDashConsumption()`
   - FLY → `getFlyConsumption()`
   - RUN/WALK/STANDBY → 恢复（+500）
   - SWIM → `getSwimConsumptions()`（并可能触发溺水）
   - SKIFF → 载具耐力（角色/载具二选一的更新路径）
   - OTHER/NOCOST/IGNORE → 特殊处理或直接跳过
3. 应用一些全局修饰：
   - 特定 team resonance（id=10301）对消耗做 0.85 系数（仅负消耗）
4. 处理“恢复延迟”：
   - 非 POWERED_* 的恢复会延迟 1 秒（5 ticks）才开始
5. `updateStaminaRelative(session, consumption, isCharacterStamina)`

这个 tick 循环就是体力系统的“运行时核心”。

---

## 44.5 一次性消耗：状态切换触发（Immediate Costs）

在 `handleCombatInvocationsNotify` 更新 `currentState` 后，会调用：

- `handleImmediateStamina(session, motionState)`

它目前对一些状态做“一次性扣体力”，例如：

- 开始攀爬：`CLIMB_START`
- 冲刺起步：`SPRINT`（对应 `MOTION_STATE_DASH_BEFORE_SHAKE`）
- 攀爬跳：`CLIMB_JUMP`
- 游泳冲刺起步：`SWIM_DASH_START`

并且有一个关键保护：

- 如果 `previousState == currentState`，则不重复触发（避免 double dip）

---

## 44.6 溺水惩罚：体力低于阈值且不在 SWIM_IDLE → 直接死亡

`getSwimConsumptions()` 里会调用 `handleDrowning()`：

- 当 `currentCharacterStamina < 10` 且 `currentState != MOTION_STATE_SWIM_IDLE`
  - 调 `killAvatar(..., PlayerDieType.PLAYER_DIE_TYPE_DRAWN)`

这说明体力系统不仅是“资源条”，也是“死亡条件”的一部分。  
如果你未来要写更复杂的“水下玩法/氧气条”，这类逻辑往往就是引擎边界。

---

## 44.7 载具耐力（Skiff/Waverider）：角色与载具两套体力槽

`StaminaManager` 同时维护：

- 角色体力：`PlayerProperty.PROP_CUR_PERSIST_STAMINA`
- 载具体力：`vehicleStamina`（本地变量）+ `vehicleId`

进入/离开载具由：

- `handleVehicleInteractReq(session, vehicleId, vehicleInteractType)`

当进入载具时会：

- 记录 `vehicleId`
- 把角色体力与载具体力都重置到 max（避免“上船后立刻掉水溺死”）

载具体力更新时会发包：

- `PacketVehicleStaminaNotify(vehicleId, newStamina/100f)`

---

## 44.8 插件拦截点：Before/After Update Stamina Listener（但语义需谨慎）

接口文件：

- `Grasscutter/src/main/java/emu/grasscutter/game/managers/stamina/BeforeUpdateStaminaListener.java`
- `Grasscutter/src/main/java/emu/grasscutter/game/managers/stamina/AfterUpdateStaminaListener.java`

`StaminaManager` 提供：

- `registerBeforeUpdateStaminaListener(name, listener)`
- `registerAfterUpdateStaminaListener(name, listener)`

但需要注意一个实现细节：

- `updateStaminaAbsolute/Relative` 当前的逻辑更像“**如果 listener 返回不同值，就取消更新**”，而不是“覆盖为新值”  
  （相当于把“override”当成了“intercept/cancel”的信号）

因此如果你未来写插件或扩展体力规则，建议先把这个拦截语义当成“取消钩子”来理解，而不是“改写钩子”。

---

## 44.9 配置开关：全局禁用/个人无限体力

体力最终写入在 `setStamina(...)`：

- 若 `Configuration.GAME_OPTIONS.staminaUsage=false` 或 `player.isUnlimitedStamina()==true`
  - 直接把 newStamina 强制为最大值（等价无限体力）

这也是“只改配置/不改表”的最简单魔改方式：

- 私有环境想做“纯剧情/纯探索”：可以直接关体力消耗

---

## 44.10 小结

- 体力系统在本仓库是一个“MotionState → ConsumptionType → 200ms tick”的状态机积分器，并且包含溺水与载具耐力两条支线。
- 内容层可控点不多（主要是配置开关与玩家属性）；更精细的“食物减耗/技能减耗/充能规则”目前仍有 TODO 或实现缺口。
- 如果你要把它当可复用引擎模块，建议把“更严谨的事件来源（技能/动作区分）、更完备的减耗数据加载、拦截钩子语义”列为引擎层增强项。

---

## Revision Notes

- 2026-01-31：首次撰写本专题；按“MotionState 分类 → 200ms tick → 一次性消耗/恢复延迟 → 溺水/载具”梳理体力系统，并标注插件拦截点的当前语义风险。

