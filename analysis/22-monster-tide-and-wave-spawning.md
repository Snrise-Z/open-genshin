# 22 专题：怪潮（MonsterTide）与波次刷怪编排

本文是“玩法编排层专题”之一，专注于 **怪潮/波次刷怪** 这一类常见 ARPG 玩法：在一个 Encounter/房间里，以“同屏上限 + 总量/顺序 + 事件回调”的方式持续刷怪，并用 Trigger/变量把它串成挑战、计分、转阶段、掉落等流程。

与其他章节关系：

- `analysis/12-scene-and-group-lifecycle.md`：Group/Suite 的加载与切换（怪潮通常发生在某个 group 的 suite 生命周期内）。
- `analysis/13-event-contracts-and-scriptargs.md`：事件 ABI（尤其是 `EVENT_MONSTER_TIDE_DIE` 的 `evt` 参数语义）。
- `analysis/17-challenge-gallery-sceneplay.md`：怪潮常与 `ActiveChallenge`/Challenge 结算绑定。
- `analysis/14-scriptlib-api-coverage.md`：可用/缺失的怪潮相关 ScriptLib API（Pause/End 等）。

> 重要前提：本仓库的怪潮实现是 **Grasscutter 引擎侧的一个简化版本**，能跑通基础“刷怪 + 回调”，但与上游脚本（`Common/Vx_y`）期望的语义存在差异（本文会明确标注差异与踩坑点）。

---

## 22.1 抽象模型：把 MonsterTide 当成“受控并发的刷怪队列”

你可以用一个中性 ARPG 模型来心算：

- **输入**：一组怪物模板（在本仓库里是 *group 内 monsters 的 config_id 列表*），外加：
  - `total`：总共刷多少只（包括首批）；
  - `concurrency`：场上最多同时存活多少只；
  - `order`：按什么顺序刷（可重复/可回退到最后一个）。
- **运行时状态**：
  - `alive`：当前存活数；
  - `spawnRemaining`：剩余可刷数；
  - `killCount`：已击杀数（用于触发阶段节点）。
- **输出/回调**：每死一只 →（可能补刷）→ 触发事件 `MONSTER_TIDE_DIE(killCount, source)`。

把它当成“可编排层 DSL”的意义在于：你不需要改 Java 就能写出 *刷怪波次→转阶段→发奖励* 的大量玩法变体。

---

## 22.2 脚本侧写法：如何在 Lua 里“起怪潮 + 接回调 + 转阶段”

### 22.2.1 起怪潮：`ScriptLib.AutoMonsterTide`

Lua 侧常见调用形态（简化）：

```lua
-- tide_id 通常用 1/2/3...，也会作为 trigger 的 source 过滤条件
-- group_id 是“怪物配置所在 group”
-- monster_cfg_ids 是一串 group 内 monsters 的 config_id（不是 monster_id）
-- total/min/max 在上游脚本里常这样命名，但本仓库只真正用到 total 与 min
ScriptLib.AutoMonsterTide(context, tide_id, group_id, monster_cfg_ids, total, min, max)
```

你在自己的 Encounter 里通常会：

1. 把“每波要刷哪些怪”定义成 `suites[x].monsters`（或自建数组）。
2. 在某个事件触发（开关、进区域、开始挑战）时调用 `AutoMonsterTide`。

### 22.2.2 接回调：`EVENT_MONSTER_TIDE_DIE`

Group 里会写一个 trigger：

- `event = EventType.EVENT_MONSTER_TIDE_DIE`
- `source = "1"` / `"2"` / ...（匹配 tide_id 转成的字符串）

回调里常见用法：

- `evt.param1`：已击杀数量（killCount）
- `evt.source`：字符串形式的 tide_id（比如 `"1"`）

典型节点逻辑（伪代码）：

```lua
function action_EVENT_MONSTER_TIDE_DIE_xxx(context, evt)
  if evt.param1 == 11 then
    -- 波次完成：切 suite、发奖励、起下一波、结束挑战等
    ScriptLib.SetGroupVariableValue(context, "stage", 2)
  end
  return 0
end
```

> 建议：把“阶段/节点”显式落在 group `variables` 里（`stage`、`wave`、`killed`），不要只依赖 `evt.param1`，这样更利于存档/重连恢复与调试。

---

## 22.3 引擎侧真实链路：从 Lua 到怪潮服务再回到 Trigger

本仓库实现链路（关键入口）：

1. `ScriptLib.AutoMonsterTide(...)`
2. `SceneScriptManager.startMonsterTideInGroup(source, group, ordersConfigId, tideCount, sceneLimit)`
3. `ScriptMonsterTideService`：
   - 注册 `onMonsterCreated` 与 `onMonsterDead` 监听
   - 先刷首批 `sceneLimit` 只
   - 每死一只：若还有剩余 → 补刷下一只 → `callEvent(EVENT_MONSTER_TIDE_DIE)`

### 22.3.1 关键状态变量（服务端）

`ScriptMonsterTideService` 内部维护：

- `monsterSceneLimit`：同屏上限（由 Lua 的第 6 参数传入）
- `monsterTideCount`：剩余可刷数量（由 Lua 的第 5 参数传入，且会在“怪物创建时”递减）
- `monsterKillCount`：击杀计数（每次死亡递增）
- `monsterConfigOrders`：按 `ordersConfigId` 排队的 config_id 队列
- `source`：事件源字符串（Lua 的 tide_id）

### 22.3.2 回调事件的构造方式

当怪物死亡时，服务端发事件：

- `event = EVENT_MONSTER_TIDE_DIE`
- `param1 = monsterKillCount`（击杀数）
- `source = source`（字符串 tide_id）

这就是为什么 Lua 侧能用 trigger 的 `source="1"` 精准区分“第几路怪潮”。

---

## 22.4 参数语义对照表（非常重要：本仓库与上游脚本存在语义差异）

> 这部分是“让你不踩坑”的核心：很多 `Common/Vx_y` 模块以为的 `total/min/max`，在本仓库实现里并不完全成立。

| Lua 形参（常见命名） | 本仓库真实用途 | 关键差异/坑 |
|---|---|---|
| `tide_id`（第2参） | 转成字符串作为 `evt.source` | trigger 的 `source` 需要写 `"1"` 这种字符串 |
| `group_id`（第3参） | 找到怪物配置所在 `SceneGroup` | 必须保证该 group 的 `monsters` 表已加载且包含对应 config_id |
| `monster_cfg_ids`（第4参） | 刷怪顺序队列（config_id） | 不是 `monster_id`；若队列不足，会反复使用“最后一个 config_id” |
| `total`（第5参） | 总刷怪数（`monsterTideCount`） | **`total=0` 不代表无限**：会在创建首批怪时递减为负数，之后不会补刷 |
| `min`（第6参） | 同屏上限（`monsterSceneLimit`） | 实际表现更像“并发数”，不是“下限”；也不会用到 `max` |
| `max`（第7参） | **未使用**（param6 被忽略） | 上游脚本常把它当“并发上限”，但这里完全不生效 |

补充差异：

- **延迟刷怪未实现**：`SceneScriptManager.spawnMonstersByConfigId(..., delayTime)` 里 `delayTime` 是 TODO；很多脚本期待的“延迟/分批”需要用 TimeAxis/变量自行编排（见 `analysis/19-route-platform-timeaxis.md`）。
- **暂停/结束接口缺失**：`PauseAutoMonsterTide/EndMonsterTide/AutoPoolMonsterTide` 等在 `ScriptLib` 里仍是 TODO；Common 模块里常见调用可能只是注释或无效。
- **多怪潮并行的风险**：`SceneScriptManager` 只保存一个 `scriptMonsterTideService` 引用；且 `AutoMonsterTide` 不会自动卸载旧 service 的监听器。理论上重复启动可能导致“旧监听器仍然在收事件”的副作用（计数错乱/重复触发）。如果你要写复杂波次，建议把“多路怪潮”转为**同一套逻辑内的多 source**，或者在脚本中规避重复启动。

---

## 22.5 玩法编排配方：只改脚本/数据做一个“标准波次战斗房间”

下面给你一个“可复用模板”（不依赖未实现 API）：

### 22.5.1 数据准备（Group 内）

1. 在 `monsters = { ... }` 里定义所有可能刷的怪（每个怪有 `config_id` 与 `monster_id`）。
2. 把波次按 suite 拆：
   - `suites[2].monsters = { 1001, 1002, 1003 }`（第1波的 config_id 列表）
   - `suites[3].monsters = { 2001, 2002 }`（第2波）
3. 准备变量：
   - `stage`：当前阶段（推荐 `no_refresh=false`，刷新会重置）
   - `killed`：累计击杀（推荐 `no_refresh=true`，避免刷新丢进度，或你自己决定）

### 22.5.2 事件编排（Trigger）

- 起怪潮：在 `EVENT_GADGET_STATE_CHANGE / EVENT_ENTER_REGION / EVENT_CHALLENGE_SUCCESS` 等动作里调用：
  - `AutoMonsterTide(context, 1, group_id, suites[2].monsters, total, concurrency, ignored_max)`
- 接回调：注册 `EVENT_MONSTER_TIDE_DIE`，source 填 `"1"`。

### 22.5.3 转阶段策略（推荐两种）

**策略 A：按击杀数转阶段**（最稳定）

- `if evt.param1 == total then` → 切到下一个 suite、起下一波、发奖励。

**策略 B：按“场上怪物数为 0”转阶段**

- 在 `EVENT_ANY_MONSTER_DIE` 或 `EVENT_MONSTER_TIDE_DIE` 里检查 `GetGroupMonsterCount()` 是否为 0。
- 注意：怪潮会补刷，只有当 `total` 用尽且场上清空才会为 0。

---

## 22.6 排障清单（你一上来最容易卡的点）

1. **完全不刷怪**
   - `group_id` 填错/该 group 未加载（大世界脚本可能被配置禁用）
   - `monster_cfg_ids` 里有 config_id 但 group.monsters 不包含（队列会 fallback，甚至刷 null）
   - `total=0` 或 `min=0`（同屏上限为 0 会导致不刷首批，也不会发回调）
2. **回调不触发**
   - trigger 的 `source` 没写 `"1"` 而写了 `1`
   - trigger `group_id`/加载状态不对（group 没在 active suite / 没注册 trigger）
3. **并发数量“不像脚本期望”**
   - 上游脚本传了 `min/max`，但本仓库只用 `min` 当并发上限，`max` 不生效
4. **想暂停/结束怪潮但找不到 API**
   - 这是引擎缺口：需要脚本侧通过变量 + 不再补刷的条件来“软结束”（例如 `total` 用尽后自然结束），或下潜实现 `EndMonsterTide`。

---

## 22.7 小结

在本仓库中，怪潮是一个可用但简化的“刷怪队列服务”。如果你的目标是“只改脚本/数据写玩法”，建议把它当成：

- **可用的基础积木**：`AutoMonsterTide` + `EVENT_MONSTER_TIDE_DIE`；
- **需要绕开的差异点**：`max` 参数无效、`total=0` 非无限、暂停/结束 API 缺失、延迟刷怪 TODO；
- **最佳实践**：用 group variables 把波次状态机写清楚，把“节点”做成可复用套路，而不是依赖隐含语义。

---

## Revision Notes

- 2026-01-31：首次撰写本专题（基于当前仓库的 `ScriptLib.AutoMonsterTide` 与 `ScriptMonsterTideService` 实现）。

