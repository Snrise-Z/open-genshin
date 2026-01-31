# 61 内容制作 Cookbook：从 0 做一个“遭遇战房间”（Worktop 开始 → 刷怪 → 清怪解锁宝箱）

本文是一份可直接照做的“最小可玩内容”配方：不依赖任务系统，只用 **Scene/Group Lua** 就能做出一个稳定的遭遇战房间，并能正确处理“重复进入/完成后不再触发/重登持久化”等常见需求。

与其他章节关系：

- `analysis/12-scene-and-group-lifecycle.md`：为什么要用 suite 表达阶段？group 如何加载/卸载？
- `analysis/21-worktop-and-interaction-options.md`：Worktop 选项事件与参数语义。
- `analysis/16-reward-drop-item.md`、`analysis/51-drop-systems-new-vs-legacy.md`：宝箱掉落与掉落栈差异。
- `analysis/26-entity-state-persistence.md`：宝箱/变量持久化的真实边界（避免“做完又刷”）。

---

## 61.1 成品效果（你要做出来的东西）

玩家来到某个点位：

1. 看到一个 **启动机关（Worktop）**，交互选择“开始挑战”（option）
2. 刷出一波怪（或多波），玩家清完
3. 解锁/生成一个宝箱（一次性、可持久化）
4. 房间进入“完成态”（不会再重复刷怪；或提供一个“重置”入口）

---

## 61.2 配方原理：用 Suite + 变量做一个小型 FSM

把 group 当成一个三态状态机：

```
suite1: 待机态(可交互 start)
  └─(SELECT_OPTION)→ suite2: 战斗态(怪物存在)
        └─(清怪)→ suite3: 完成态(宝箱解锁/可领奖)
```

用 group variable（例如 `stage`）做防抖与持久化标记：

- `stage=0`：未开始
- `stage=1`：进行中
- `stage=2`：已完成

---

## 61.3 你需要准备什么（Ingredients）

### 61.3.1 选择场景与坐标

- 选一个你常驻调试的 sceneId（大世界最方便）。
- 找一个空旷坐标点，避免和现有 group 玩法重叠。

### 61.3.2 选择一个 group_id 与 block_id

在 `resources/Scripts/Scene/<sceneId>/` 下：

- 选择一个现有的 `scene<sceneId>_block<blockId>.lua`
- 在该 block 的 `groups = { ... }` 列表里追加你的 group 条目

> 经验法：先找一个“你准备做内容的坐标附近”已经存在的 group（看 `pos`），把你的 group 追加在同一个 block 文件里，通常最省事。

### 61.3.3 选择启动 gadget 与 option_id（强烈建议复用现成组合）

你需要一个“能弹出选项”的 gadget（通常是 worktop/机关台）。

最稳的做法：**直接复用仓库里已经验证过的组合**。例如：

- 参考：`resources/Scripts/Scene/1/scene1_group111101097.lua`
  - `gadget_id = 70360001`（worktop）
  - `option_id = 40`

原因：option 是否能显示，很大程度取决于客户端对该 gadget 的定义；你自选一个 gadget + option，可能出现“脚本调用成功但客户端不显示”的假失败。

### 61.3.4 选择怪物与掉落

怪物部分你只需要：

- `monster_id`：复用现有怪物类型 ID（GM Handbook/怪物表可查）
- `level`：1 起步即可
- 掉落（任选其一）：
  - `drop_id = 1000100`（常见占位，便于验证掉落链路是否通）
  - 或 `drop_tag = "..."`（走另一套掉落栈，见 `analysis/51`）

### 61.3.5 选择宝箱 gadget 与奖励

宝箱常见两种写法：

1) `chest_drop_id + drop_count`（更直观）  
2) `drop_tag`（更“语义化”，但依赖映射）

本配方建议你先用 `chest_drop_id = 1000100, drop_count = 1` 跑通链路。

并且把宝箱做成“一次性 + 持久化”：

- `isOneoff = true`
- `persistent = true`

---

## 61.4 需要改哪些文件（最小改动清单）

你只需要改两处（不涉及 Excel 表）：

1. **把 group 挂进某个 block**
   - `resources/Scripts/Scene/<sceneId>/scene<sceneId>_block<blockId>.lua`
2. **编写 group 脚本**
   - `resources/Scripts/Scene/<sceneId>/scene<sceneId>_group<groupId>.lua`

---

## 61.5 Step-by-step：照做即可跑起来

### Step 1：在 block 文件注册你的 group

打开 `resources/Scripts/Scene/<sceneId>/scene<sceneId>_block<blockId>.lua`，在 `groups = { ... }` 里追加一行（示例）：

```lua
{ id = 199001001, refresh_id = 1, pos = { x = 100.0, y = 200.0, z = -300.0 } },
```

字段说明（够用的最小集）：

- `id`：你的 `group_id`
- `pos`：这个 group 的参考坐标（会影响“附近 group”判定与加载）
- `refresh_id`：可选；很多组都有，但你做第一个内容时不必深入

### Step 2：新建 group 脚本骨架

新建：`resources/Scripts/Scene/<sceneId>/scene<sceneId>_group<groupId>.lua`

你要写的最小结构（示意，不要照抄 ID）：

```lua
local base_info = { group_id = 199001001 }

monsters = { ... }  -- suite2
gadgets  = { ... }  -- suite1/suite3
regions  = { }
triggers = { ... }
variables = { { config_id = 1, name = "stage", value = 0, no_refresh = true } }

init_config = { suite = 1, end_suite = 3, rand_suite = false }

suites = {
  [1] = { gadgets = { START_WORKTOP }, triggers = { "GADGET_CREATE_START", "SELECT_OPTION_START" } },
  [2] = { monsters = { ... }, triggers = { "ANY_MONSTER_DIE_CLEAR" } },
  [3] = { gadgets = { REWARD_CHEST }, triggers = { } }
}
```

> 你会看到本仓库的很多 group 脚本还会定义 `npcs/garbages` 等；对这个配方不是必需。

### Step 3：用 `EVENT_GADGET_CREATE` 设置 Worktop 选项

原因：保证 gadget 实体已经在场景里生成。

触发器定义（示意）：

```lua
triggers = {
  { config_id = 1199001, name = "GADGET_CREATE_START", event = EventType.EVENT_GADGET_CREATE,
    condition = "condition_gadget_create_start", action = "action_gadget_create_start" },
}
```

条件与动作（示意）：

```lua
function condition_gadget_create_start(context, evt)
  return evt.param1 == START_WORKTOP
end

function action_gadget_create_start(context, evt)
  -- 已完成则不再给选项
  if ScriptLib.GetGroupVariableValue(context, "stage") == 2 then
    return 0
  end
  return ScriptLib.SetWorktopOptionsByGroupId(context, base_info.group_id, START_WORKTOP, { 40 })
end
```

### Step 4：用 `EVENT_SELECT_OPTION` 进入战斗态（切到 suite2）

触发器：

```lua
{ name = "SELECT_OPTION_START", event = EventType.EVENT_SELECT_OPTION,
  condition = "condition_select_start", action = "action_select_start" }
```

关键点：

- `evt.param1`：gadget config_id
- `evt.param2`：option_id

动作建议包含三件事：

1) 删除选项（避免重复触发）  
2) 置 `stage=1`  
3) 加载战斗内容（`AddExtraGroupSuite` 或 `GoToGroupSuite`）

示意：

```lua
function condition_select_start(context, evt)
  return evt.param1 == START_WORKTOP and evt.param2 == 40
end

function action_select_start(context, evt)
  ScriptLib.DelWorktopOptionByGroupId(context, base_info.group_id, START_WORKTOP, 40)
  ScriptLib.SetGroupVariableValue(context, "stage", 1)

  -- 方式 A：加一个战斗 suite（更像“在待机态上叠加”）
  ScriptLib.AddExtraGroupSuite(context, base_info.group_id, 2)

  return 0
end
```

### Step 5：清怪后进入完成态（切到 suite3 / 解锁宝箱）

你需要监听 `EVENT_ANY_MONSTER_DIE`：

- condition：`GetGroupMonsterCountByGroupId(context, group_id) == 0` 且 `stage==1`
- action：`stage=2`、`GoToGroupSuite(group_id, 3)`

参考同类型实现：`resources/Scripts/Scene/1/scene1_group111102013.lua`

示意：

```lua
function condition_all_monsters_dead(context, evt)
  if ScriptLib.GetGroupVariableValue(context, "stage") ~= 1 then return false end
  return ScriptLib.GetGroupMonsterCountByGroupId(context, base_info.group_id) == 0
end

function action_all_monsters_dead(context, evt)
  ScriptLib.SetGroupVariableValue(context, "stage", 2)
  ScriptLib.GoToGroupSuite(context, base_info.group_id, 3)
  return 0
end
```

> 备注：你也可以选择“宝箱一直存在但锁着”，然后在 action 里 `SetGadgetStateByConfigId(CHEST, GadgetState.Default)` 解锁；两种都可。

---

## 61.6 验收清单（你如何判断它真的做对了）

1. 重启服务器（避免脚本缓存影响）
2. 传送到目标 scene，走到你放置的坐标附近
3. 用 `/quest grouptriggers <groupId>` 确认 group 已加载且 triggers 存在
4. 看到 worktop，并出现 option 40
5. 选择 option 后刷怪
6. 清怪后宝箱出现/解锁
7. 打开宝箱后重登/离开再回来：宝箱不再回到“未开启”状态（一次性生效）

---

## 61.7 常见坑与排障

1. **option 不显示**
   - 先确认你复用了“可用组合”（例如 `70360001 + option 40`）
   - 再确认 `SetWorktopOptionsByGroupId` 返回值为 0（可以 PrintContextLog 打印）
2. **清怪后不进入完成态**
   - 你监听的是 `ANY_MONSTER_DIE` 但 `GetGroupMonsterCountByGroupId` 写错 groupId
   - 或你把怪刷在别的 group（例如用 CreateMonster 但 groupId 不对）
3. **完成后又能重复开始**
   - 没把 `stage` 持久化（`no_refresh` 配置 + 变量写入）
   - 或你在完成态又把 worktop 重新 Create 出来了
4. **改脚本没生效**
   - ScriptLoader 缓存；重启（见 `analysis/60` 的 60.5）

---

## 61.8 变体（下一步你可以怎么扩展）

- **多波次**：把 suite2 拆成 suite2/3/4，按怪死光或变量推进 `AddExtraGroupSuite` / `RemoveExtraGroupSuite`
- **区域失败条件**：加一个 region，`LEAVE_REGION` 触发重置（见 `analysis/63` 预告）
- **奖励多样化**：把“宝箱掉落”换成“Quest Exec 发奖/掉落表驱动”（见 `analysis/67` 预告）
- **多人归属**：决定是“房主驱动”还是“全员可交互”，并针对掉落做归属校验（见 `analysis/30`）

---

## Revision Notes

- 2026-01-31：首次撰写本配方；给出最小遭遇战房间的 suite/FSM 模型、必需触发器与 ScriptLib 调用、以及验证与排障清单。
