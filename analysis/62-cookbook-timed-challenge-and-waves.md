# 62 内容制作 Cookbook：限时挑战 + 波次刷怪（Challenge + Suite/Wave + 结算）

本文给你一份“活动/小玩法”里最常见的配方：**限时挑战**（成功/失败回调）+ **波次刷怪**（清波推进）+ **结算态**（给奖励/刷宝箱/切阶段）。  
它比 `analysis/61` 更像“可复用玩法模板”，也是很多 Common/Vx_y 模块的底层骨架。

与其他章节关系：

- `analysis/17-challenge-gallery-sceneplay.md`：Challenge/Gallery 的框架与实现边界（理解 param 语义差异）。
- `analysis/22-monster-tide-and-wave-spawning.md`：怪潮/波次系统（含 EVENT_MONSTER_TIDE_DIE 的事件语义）。
- `analysis/13-event-contracts-and-scriptargs.md`：trigger 的 `source/tag/evt.param*` 匹配规则（挑战成功/失败、怪潮事件都依赖 source）。
- `analysis/14-scriptlib-api-coverage.md`：判断 `ActiveChallenge/AutoMonsterTide` 及其依赖是否可用。

参考现成案例（本仓库就有）：

- `resources/Scripts/Scene/1/scene1_group111101097.lua`：worktop 开始 → ActiveChallenge → AutoMonsterTide → CHALLENGE_SUCCESS/FAIL 收尾

---

## 62.1 你要做出来的“体验”

1. 玩家交互开始挑战（worktop option）
2. 挑战开始计时（例如 30 秒）
3. 期间刷怪（单波或多波）
4. 成功：切到结算态（刷宝箱/机关状态变化/提示）
5. 失败：回滚到待机态（允许重新开始）

---

## 62.2 关键机制 1：Challenge 事件如何映射到 Lua trigger？

在脚本层你需要记住两个强约定：

1) **CHALLENGE_SUCCESS/FAIL 的 trigger 需要正确填写 `source`**  
   - 通常写成你的 `challengeId` 的字符串：`source = "874"`  
2) 引擎触发事件时会把 event source 写入 `ScriptArgs.eventSource`，触发器筛选会按 `trigger.source` 匹配（见 `analysis/13`）。

因此，最小触发器形状通常是：

```lua
{ name = "CHALLENGE_SUCCESS_X", event = EventType.EVENT_CHALLENGE_SUCCESS, source = "874", action = "action_success" }
{ name = "CHALLENGE_FAIL_X",    event = EventType.EVENT_CHALLENGE_FAIL,    source = "874", action = "action_fail" }
```

> 这也是为什么很多脚本里 `source` 不是空字符串：它不是“随便填的”，它是事件路由的一部分。

---

## 62.3 关键机制 2：波次刷怪两种实现路线（强烈建议先用 Suite 波次）

本仓库存在两种常见“波次”做法：

### 路线 A（推荐）：用 suite 当波次（稳定、可控、易排障）

- suite2 = 第一波怪
- suite3 = 第二波怪（或结算）
- 每波清完（`GetGroupMonsterCountByGroupId == 0`）就切到下一 suite

优点：

- 不依赖 `AutoMonsterTide` 的实现细节
- 清理与重置最干净（`GoToGroupSuite` 一把梭）

缺点：

- 没有“怪潮专用事件”（`EVENT_MONSTER_TIDE_DIE`）带来的节奏钩子

### 路线 B：用 `AutoMonsterTide`（有 EVENT_MONSTER_TIDE_DIE，但要接受当前实现边界）

`ScriptLib.AutoMonsterTide(context, sourceId, groupId, {configIds...}, tideCount, min, max)` 会：

- 启动一个 `ScriptMonsterTideService`（scene 级别单例）
- 根据怪物死亡回调继续补刷
- 触发 `EVENT_MONSTER_TIDE_DIE`，其 `source` = `sourceId`（字符串）

但需要注意的实现边界：

- `KillMonsterTide` 在 ScriptLib 中目前是 TODO（没有稳定的 Lua 侧“停止怪潮”API）
- `ScriptMonsterTideService` 目前的监听/计数实现较粗糙，**不建议在同一场景同时跑多个潮**  
  （更稳的做法是：一次挑战只开一个潮，结束后通过 `GoToGroupSuite/RefreshGroup` 做硬重置）

因此，做自制内容时建议：

> 先用 Suite 波次把玩法跑通；确实需要怪潮事件节奏时再引入 AutoMonsterTide，并把“重置/收尾”写成更保守的形式。

---

## 62.4 最小可行配方（MVP）：worktop → challenge → 两波怪 → 结算宝箱

### 62.4.1 Suite 设计

建议 3 个 suite：

- suite1（待机）：worktop（开始选项）
- suite2（战斗）：第一波怪
- suite3（结算）：宝箱/机关状态

如果你要两波怪，可以扩成 4 个 suite（suite2/3 为两波，suite4 为结算）。

### 62.4.2 Trigger 设计（最小集）

待机态：

- `EVENT_GADGET_CREATE`：给 worktop 配 option
- `EVENT_SELECT_OPTION`：开始挑战、进入战斗态

战斗态：

- `EVENT_ANY_MONSTER_DIE`：判断本波是否清完，推进到下一波或结算

结算/失败：

- `EVENT_CHALLENGE_SUCCESS` / `EVENT_CHALLENGE_FAIL`：统一收尾（成功/失败都要能“把现场收干净”）

---

## 62.5 Step-by-step：实现细节（按“稳定优先”写法）

### Step 1：开始挑战（ActiveChallenge）

在 `action_select_start` 里调用：

```lua
-- 注意：Lua 调用会多一个 context 参数；这里展示的是“context 后面的 6 个 int”
ScriptLib.ActiveChallenge(context,
  CHALLENGE_ID,
  CHALLENGE_INDEX,
  TIME_LIMIT,
  PARAM4,
  PARAM5,
  PARAM6
)
```

重要说明：

- ScriptLib 的参数名是“占位命名”（`timeLimitOrGroupId/groupId/objectiveKills/param5`），**真实语义取决于 challengeIndex**（见 `analysis/17`）。
- 最稳的做法：找到仓库里用同一个 `challengeIndex` 的脚本，照着它的参数形状填（例如 `scene1_group111101097.lua` 的 `205`）。

### Step 2：刷第一波怪（Suite 波次推荐写法）

开始挑战后：

```lua
ScriptLib.GoToGroupSuite(context, base_info.group_id, 2)  -- 进入第一波
ScriptLib.SetGroupVariableValue(context, "wave", 1)
```

### Step 3：清波推进（ANY_MONSTER_DIE）

核心是：

- 波次推进不要依赖 `evt` 本身（它只告诉你“死了一个”）
- 用 `GetGroupMonsterCountByGroupId` 做“清波判定”

示意：

```lua
function condition_wave_clear(context, evt)
  return ScriptLib.GetGroupMonsterCountByGroupId(context, base_info.group_id) == 0
end

function action_wave_clear(context, evt)
  local wave = ScriptLib.GetGroupVariableValue(context, "wave")
  if wave == 1 then
    ScriptLib.SetGroupVariableValue(context, "wave", 2)
    ScriptLib.GoToGroupSuite(context, base_info.group_id, 3) -- 第二波或结算
  else
    -- 已是最后一波：你可以直接“等挑战成功”或主动触发收尾逻辑
  end
  return 0
end
```

> 如果你把 suite3 用作“结算态”，那就把“第二波怪”放在 suite2，并在 action 里直接切到 suite3。

### Step 4：成功/失败收尾（CHALLENGE_SUCCESS/FAIL）

无论你用 Suite 波次还是 AutoMonsterTide，都建议把“成功/失败”的收尾逻辑写得**幂等**（重复执行不会把状态搞坏），因为：

- 你可能在“清最后一波”时已经切到结算 suite
- 随后又收到 CHALLENGE_SUCCESS，再次触发结算

**成功 action 建议做这些事：**

1. 标记完成（`stage=2` 或 `finished=1`）
2. 清理战斗现场（最稳：`GoToGroupSuite` 到结算 suite）
3. 生成/解锁奖励（宝箱/机关）

示意：

```lua
function action_challenge_success(context, evt)
  ScriptLib.SetGroupVariableValue(context, "stage", 2)
  ScriptLib.GoToGroupSuite(context, base_info.group_id, SUITE_SETTLE)
  return 0
end
```

**失败 action 建议做这些事：**

1. 清理现场（同样推荐 `GoToGroupSuite` 到待机 suite）
2. 重置变量（`stage=0,wave=0`）
3. 重新允许开始（重新设置 worktop option）

示意：

```lua
function action_challenge_fail(context, evt)
  ScriptLib.SetGroupVariableValue(context, "stage", 0)
  ScriptLib.SetGroupVariableValue(context, "wave", 0)
  ScriptLib.GoToGroupSuite(context, base_info.group_id, 1)
  return 0
end
```

> 如果你想在失败后“延迟几秒再重置”，需要 Timer/TimeAxis（见 `analysis/19-route-platform-timeaxis.md`）。

---

## 62.6 可选：接入 AutoMonsterTide（当你确实需要 EVENT_MONSTER_TIDE_DIE）

如果你要用怪潮做节奏（例如：每杀 5 只怪提示一次/加压一次），你需要：

1. `AutoMonsterTide` 的 `sourceId`（整数）  
2. 一个监听 `EVENT_MONSTER_TIDE_DIE` 的 trigger，并把 `source` 填成 `tostring(sourceId)`

示意：

```lua
-- 开潮
ScriptLib.AutoMonsterTide(context, 1, base_info.group_id, { 2001,2002,2003 }, 15, 3, 3)

-- 监听潮击杀事件
{ name = "MONSTER_TIDE_DIE", event = EventType.EVENT_MONSTER_TIDE_DIE, source = "1",
  condition = "condition_tide_die", action = "action_tide_die" }
```

在 `action_tide_die` 里，你通常只需要读 `evt.param1`（已击杀数/或计数器），然后：

- 提示（`ShowReminder`）
- 或切阶段变量（`SetGroupVariableValue` → `EVENT_VARIABLE_CHANGE` 驱动后续）

实现边界提醒：

- 当前 ScriptLib 没有可用的 `KillMonsterTide`（TODO），怪潮停止更依赖“挑战结束后重置 group/suite”来硬清理现场。
- 不要在同一场景同时开多个潮（尤其不同 group 同时开），否则监听计数可能互相干扰。

---

## 62.7 验收清单

1. 开始挑战后，能稳定收到挑战成功/失败事件（trigger 的 `source` 匹配正确）
2. 成功：进入结算态，不再刷怪，奖励可领取
3. 失败：回到待机态，可再次开始，且不会残留上一局的怪/机关状态
4. 反复开始/失败/成功 N 次，变量与 suite 不会跑飞（幂等）

---

## 62.8 常见坑与排障

1. **CHALLENGE_SUCCESS/FAIL 永远不触发**
   - 你写了 trigger 但 `source` 没填或填错（最常见）
   - 你在同一场景已经有一个挑战进行中（`ActiveChallenge` 会拒绝再次创建）
2. **成功后还有怪残留**
   - 你用 `AddExtraGroupSuite` 刷怪，但成功后没 `GoToGroupSuite` 回收
   - 或你用 AutoMonsterTide，潮仍在监听补刷：建议在成功/失败都 `GoToGroupSuite(1/settle)` 做硬重置
3. **波次推进不稳定**
   - 你用 `evt.param1` 当“剩余怪数”了（不是）
   - 改用 `GetGroupMonsterCountByGroupId` 做清波判定
4. **想用 KillMonsterTide 清理，但没效果**
   - 本仓库 ScriptLib 里该函数目前是 TODO；不要把它当可靠收尾手段

---

## 62.9 小结

- Challenge 的关键在 `source`：它决定成功/失败事件是否能路由到你的 trigger。
- 波次最稳的实现是“Suite 波次 + 清波判定 + GoToGroupSuite 收尾”。
- AutoMonsterTide 可以用，但要承认当前实现边界：把它当“可用但需保守收尾”的工具。

---

## Revision Notes

- 2026-01-31：首次撰写本配方；总结 Challenge 的 source 路由约定、Suite 波次与 AutoMonsterTide 两种实现路线，并给出“稳定优先”的收尾/重置范式与排障清单。
