# 64 内容制作 Cookbook：机关解谜（GadgetState/变量/计时）→ 解锁/生成宝箱

本文是一份“机关解谜内容”的通用配方：用 **gadget 状态机（GadgetState）+ group 变量 + 事件触发器** 实现一个可重复测试、可重置、可持久化的解谜，并在完成时解锁/生成宝箱。

与其他章节关系：

- `analysis/15-gadget-controllers.md`：当你需要“通用机关实体行为”时，GadgetMapping + 控制器脚本是更可维护的落点。
- `analysis/21-worktop-and-interaction-options.md`：机关交互（SelectOption / Interact）与参数语义。
- `analysis/19-route-platform-timeaxis.md`：计时/节奏控制（TimerEvent/TimeAxis）在解谜里很常见。
- `analysis/29-gadget-content-types.md`：不同 GadgetContent 的交互/掉落/多人归属差异。
- `analysis/26-entity-state-persistence.md`：解谜完成态要不要持久化？怎么避免“重登复原/重复领奖”？

参考现成案例（本仓库就有）：

- `resources/Scripts/Scene/1/scene1_group111101147.lua`：包含大量机关状态变化、计时器与“完成后刷宝箱”的典型写法

---

## 64.1 你要做出来的解谜类型（最常见三类）

1) **状态解谜**：按顺序点亮/切换机关（`GADGET_STATE_CHANGE` 驱动）  
2) **目标解谜**：摧毁/命中若干靶标（`ANY_GADGET_DIE`/`ANY_MONSTER_DIE` 驱动）  
3) **计时解谜**：限时完成，否则重置（`TIMER_EVENT`/`TIME_AXIS_PASS` 驱动）

它们本质都可以归一成：

```
事件 → 条件判断 → 写变量/改 gadget state/切 suite → 下一事件…
```

---

## 64.2 推荐的“可维护结构”：编排（Group） vs 行为（Controller）

你可以把机关解谜拆成两层：

- **编排层（Group Lua）**：这个解谜有几个阶段？完成条件是什么？失败怎么重置？奖励怎么发？
- **行为层（Gadget Controller）**：某个 gadget 自身如何响应 ExecuteReq/被击中/定时器？（通用可复用）

如果你的解谜只在一个 group 里用一次，直接写在 group 脚本里最省事；  
如果你要在多个地图点复用同一类机关行为，建议下沉到 controller（见 `analysis/15`）。

---

## 64.3 最小可行配方（MVP）：3 个靶标 → 全部被摧毁 → 刷宝箱

### 64.3.1 Suite 设计

建议 3 个 suite：

- suite1（待机）：开关/提示 gadget（可选）+ 靶标（可选是否先隐藏）
- suite2（进行中）：靶标（如果 suite1 没放）、计时器触发器等
- suite3（完成）：宝箱（一次性）

### 64.3.2 变量设计

最少 2 个变量：

- `killed`：已摧毁数量
- `stage`：0 未开始 / 1 进行中 / 2 已完成

```lua
variables = {
  { config_id = 1, name = "stage", value = 0, no_refresh = true },
  { config_id = 2, name = "killed", value = 0, no_refresh = false },
}
```

> `stage` 建议 `no_refresh=true`，用于“完成后不再重复开始”；`killed` 是否持久化取决于你要不要“断线继续”。

### 64.3.3 触发器设计

最少 2 个 trigger：

- `ANY_GADGET_DIE`：靶标被摧毁计数
- `VARIABLE_CHANGE`：当 `killed` 达到阈值，进入完成态

---

## 64.4 Step-by-step：实现细节

### Step 1：用 `ANY_GADGET_DIE` 给 `killed` 计数

你需要在 condition 里筛选“是不是我的靶标”，常见做法是：

- 用 config_id 列表/范围判断
- 或者在 gadgets 表里给靶标加自定义字段（Lua 表字段）标注类型（更工程化，但需要你维护）

示意（用列表筛选）：

```lua
local TARGETS = { 20001, 20002, 20003 }

function condition_target_die(context, evt)
  if ScriptLib.GetGroupVariableValue(context, "stage") ~= 1 then return false end
  for _, cid in ipairs(TARGETS) do
    if evt.param1 == cid then return true end
  end
  return false
end

function action_target_die(context, evt)
  ScriptLib.ChangeGroupVariableValue(context, "killed", 1)
  return 0
end
```

> `evt.param1` 在 `ANY_GADGET_DIE` 中通常是“死亡 gadget 的 config_id”。如果你发现不一致，优先查 `analysis/13` 的事件契约小节。

### Step 2：用 `VARIABLE_CHANGE` 做“达到阈值 → 完成态”

```lua
function condition_killed_reach(context, evt)
  if ScriptLib.GetGroupVariableValue(context, "stage") ~= 1 then return false end
  return ScriptLib.GetGroupVariableValue(context, "killed") >= 3
end

function action_killed_reach(context, evt)
  ScriptLib.SetGroupVariableValue(context, "stage", 2)
  ScriptLib.GoToGroupSuite(context, base_info.group_id, 3) -- 刷宝箱
  return 0
end
```

### Step 3（可选）：加一个“开始开关”（Worktop option 或 GadgetState）

很多解谜会要求玩家先交互开关才开始计数：

- stage 从 0 → 1
- 必要时把靶标从隐藏/不可交互变成可用（切 suite 或改 gadget state）

这部分可以复用 `analysis/61` 的 Worktop 开始写法。

### Step 4（可选）：计时失败与重置（TimerEvent/TimeAxis）

做“限时解谜”时，你通常需要：

- 开始时启动 timer/time axis
- 超时触发 reset：清理靶标、复原变量、回到 suite1

由于不同脚本对 TimeAxis/Timer 的封装差异较大，本配方只给出抽象建议：

- 开发期先用“硬重置”：`RefreshGroup({group_id, suite=1})`
- 稳定后再把重置拆成：Kill/Respawn gadgets + reset variables + re-enable options

---

## 64.5 持久化策略：解谜完成态到底该不该存？

你需要先回答一个设计问题：

- 这是“一次性解谜”（做完永远不再出现）？
- 还是“可重复解谜”（每日/每次进入都能做）？

对应策略：

1) 一次性解谜
   - 宝箱：`isOneoff=true` + `persistent=true`
   - `stage`：持久化为 2（`no_refresh=true`）
   - 进入 group 时如果 `stage==2`：不再给开始选项，不再刷靶标
2) 可重复解谜
   - 不要用 isOneoff 宝箱；改为掉落 gadget/奖励直接发放（或用每日重置驱动）
   - `stage/killed` 不持久化，或在 `GROUP_LOAD` 强制归零

持久化边界细节见 `analysis/26`。

---

## 64.6 什么时候该用 Gadget Controller（而不是在 group 里堆触发器）？

判断标准（经验法）：

- 你需要拦截/实现 `OnClientExecuteReq`、`OnBeHurt` 这类“实体级回调”  
  → 倾向 controller
- 你希望同一类机关行为被 N 个 group 复用  
  → controller + `resources/Server/GadgetMapping.json` 映射
- 你只是做一次性解谜编排（状态机/阶段/奖励）  
  → group 脚本足够

---

## 64.7 常见坑与排障

1. **ANY_GADGET_DIE 不触发**
   - 你摧毁的对象不是 gadget（可能是装饰/不可破坏）
   - 或 gadget 的死亡不是通过“kill”路径产生（检查 gadget 类型）
2. **变量变了但 VARIABLE_CHANGE 不触发**
   - 你用的是 `SetGroupVariableValue`（它不会产生“旧值/新值”差异判断？）  
     更稳：用 `ChangeGroupVariableValue` 让系统自然产生 variable_change 事件
3. **完成态不持久化**
   - 变量 `no_refresh` / gadget `persistent/isOneoff` 设置不一致
   - group instance 被 RefreshGroup 重置了：你在 reset 里把 stage 清掉了

---

## 64.8 小结

- 机关解谜的通用骨架：事件（die/state_change/select_option）→ 变量阶段机 → 切 suite/改 state → 结算宝箱。
- 开发期优先“能重置干净”，稳定后再优化持久化与精细清理。
- 需要复用或需要实体级行为回调时，考虑下沉到 Gadget Controller + Mapping。

---

## Revision Notes

- 2026-01-31：首次撰写本配方；给出机关解谜的事件/变量/阶段机骨架、完成态与持久化策略、以及何时应引入 Gadget Controller 的判断标准。

