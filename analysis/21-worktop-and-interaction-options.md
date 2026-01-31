# 21 - Worktop / 交互选项：从“操作台按钮”到 Lua 事件与任务推进

> Worktop 是玩法编排层里最常用的交互范式之一：一个 gadget 在玩家靠近/满足条件时出现选项（option），玩家点选后服务端触发事件，脚本据此刷怪、开门、推进任务、切套件。
>
> 本篇专题专门回答：
> - `EVENT_SELECT_OPTION` 的参数到底是什么？
> - `SetWorktopOptions / DelWorktopOption` 为什么有“隐式版本”和 “ByGroupId 显式版本”？
> - Worktop 与 Quest（`QUEST_CONTENT_WORKTOP_SELECT`）如何联动？
>
> 关联阅读：
> - `analysis/13-event-contracts-and-scriptargs.md`：事件 ABI（`evt.param1/2` 与 trigger 路由）
> - `analysis/10-quests-deep-dive.md`：任务系统如何消费“交互事件”

---

## 1. Worktop 的心智模型：一个“带按钮的 gadget”

把 Worktop 当作一个简化 UI：

- gadget（实体）有一个 **option list**（一组 int）
- 客户端把它显示成“可交互按钮列表”
- 玩家选中某个 option → 客户端发 `SelectWorktopOptionReq` → 服务端：
  - 可选：让 Java 系统先处理（例如某些活动/采集/花树系统）
  - 必做：抛给 Lua（`EVENT_SELECT_OPTION`），以及抛给 Quest（`QUEST_CONTENT_WORKTOP_SELECT`）

---

## 2. 运行时链路：SelectWorktopOptionReq 如何变成 `EVENT_SELECT_OPTION`

### 2.1 入口 handler：`HandlerSelectWorktopOptionReq`

位置：`Grasscutter/src/main/java/emu/grasscutter/server/packet/recv/HandlerSelectWorktopOptionReq.java`

它的执行顺序非常关键：

1. `scene.selectWorktopOptionWith(req)`  
   - 这是 **Java 侧 Worktop handler** 的入口（见第 6 节）
2. Lua 事件：`scene.getScriptManager().callEvent(new ScriptArgs(...))`
3. Quest 事件：`questManager.queueEvent(QUEST_CONTENT_WORKTOP_SELECT, configId, optionId)`
4. 最后无论如何都会回包 `SelectWorktopOptionRsp`

### 2.2 `EVENT_SELECT_OPTION` 的 ScriptArgs 字段语义

Handler 里构造的是：

- `group_id`：该 worktop gadget 所在 group（`entity.getGroupId()`）
- `evt.param1`：gadget 的 `config_id`（`entity.getConfigId()`）
- `evt.param2`：optionId（`req.getOptionId()`）

它不会设置 `evt.source`（因此大多数脚本把 trigger.source 留空）。

你在 Lua 条件里最常见的写法就是：

```lua
if evt.param1 ~= WORKTOP_CONFIG_ID then return false end
if evt.param2 ~= OPTION_ID then return false end
return true
```

> 结论：**`param1=哪个操作台`，`param2=点了哪个选项`**。

---

## 3. Worktop 选项的存储与同步：`GadgetWorktop` + `WorktopOptionNotify`

### 3.1 Worktop 选项存储在实体内容里

当 gadget 类型是 `Worktop/SealGadget` 时，`EntityGadget` 会创建内容：
- `GadgetWorktop`（`Grasscutter/src/main/java/emu/grasscutter/game/entity/gadget/GadgetWorktop.java`）

它内部维护：
- `worktopOptions: Set<Integer>`

并且在实体生成时会把 optionList 放进 `SceneGadgetInfo.worktop`（客户端初始就能看到）。

### 3.2 动态改选项需要通知客户端

脚本用 ScriptLib 修改 options 后，会广播：
- `PacketWorktopOptionNotify`（携带 gadgetEntityId + optionList）

因此“玩法编排层”的原则是：

> 只要你在服务端改了 options，就必须让客户端知道，否则 UI 不会刷新。

本仓库在 ScriptLib 里已经把“改 options + 发 notify”打包好了。

---

## 4. ScriptLib API：为什么有“隐式版本”和“显式版本”？

你会看到两类 API：

### 4.1 显式版本（推荐写新脚本时优先用）

- `SetWorktopOptionsByGroupId(context, groupId, configId, {options...})`
- `DelWorktopOptionByGroupId(context, groupId, configId, optionId)`

它们不依赖“当前事件”，可读性强，适合做跨 group 修改或在非事件上下文调用。

### 4.2 隐式版本（大量官方脚本在用）

- `SetWorktopOptions(context, {options...})`
- `DelWorktopOption(context, optionId)`

它们的特点是：**不显式传 configId**，而是依赖 ScriptLib 的“当前事件参数”：

- ScriptLib 内部有一个 `callParams: ScriptArgs`（由脚本运行时在触发器调用 action/condition 时注入）
- 例如在 `EVENT_GADGET_CREATE` 中，`callParams.param1` 就是被创建 gadget 的 configId
- 在 `EVENT_SELECT_OPTION` 中，`callParams.param1/param2` 就分别是 configId/optionId

因此官方脚本经常这样写：

- 在 `GADGET_CREATE` action 中：`SetWorktopOptions(context, {7})`
- 在 `SELECT_OPTION` action 中：`DelWorktopOption(context, evt.param2)`

> 结论：隐式版本更“DSL 化”，但对你写新玩法来说更容易踩“上下文不对就失效”的坑。

---

## 5. 典型脚本范式：进入区域显示按钮 → 点按钮启动玩法

一个非常经典的样例（建议你对照阅读）：

- `resources/Scripts/Scene/40661/scene40661_group240661001.lua`

它做了：

1. `ENTER_REGION`：
   - `SetWorktopOptionsByGroupId(..., 240661001, 1001, {7})`
   - `SetGadgetStateByConfigId(1001, GadgetState.Default)`

2. `SELECT_OPTION`（只接受 configId=1001 且 optionId=7）：
   - 开始刷怪/玩法逻辑（例：`AutoMonsterTide(...)`）
   - 删除按钮：`DelWorktopOptionByGroupId(..., 1001, 7)`（或用隐式 `DelWorktopOption`）
   - 把 gadget 状态改回 `GearStop`
   - `RefreshGroup` 切换到另一组 suite

### 5.1 最小模板（结构示意）

```lua
-- 入口：让玩家看到按钮
function on_enter(context, evt)
  ScriptLib.SetWorktopOptionsByGroupId(context, group_id, worktop_cfg, {option})
  ScriptLib.SetGadgetStateByConfigId(context, worktop_cfg, GadgetState.Default)
end

-- 点击：消费按钮并推进玩法
function on_select(context, evt)
  if evt.param1 ~= worktop_cfg or evt.param2 ~= option then return 0 end
  ScriptLib.DelWorktopOptionByGroupId(context, group_id, worktop_cfg, option)
  ScriptLib.SetGadgetStateByConfigId(context, worktop_cfg, GadgetState.GearStop)
  -- do gameplay: spawn, challenge, suite switch, quest progress...
end
```

---

## 6. Java 侧 Worktop handler：有些系统会“先吃掉一次交互”

`Scene.selectWorktopOptionWith(req)` 会检查：

- 实体是否 `EntityGadget`
- 内容是否 `GadgetWorktop`
- 是否注册了 `WorktopWorktopOptionHandler`

如果注册了 handler，就会先调用它，handler 可选择返回 `shouldDelete` 来删除实体。

典型例子：
- `BlossomManager` 会给某些 worktop 绑定 handler（用于“地脉花/花树”一类系统的交互）

**这对玩法编排层的含义：**

- 你写 Lua 脚本时，即使 Java handler 先执行了，Lua 的 `EVENT_SELECT_OPTION` 仍会被调用（handler 调用在前）。
- 但如果你复用某个已有 gadgetId/系统，可能会和 Java handler 逻辑冲突（例如按钮点了以后实体被删、选项被系统改写）。

建议：
- 自制玩法优先选“没有系统绑定”的 gadget 类型/ID，或在理解 Java handler 的前提下复用。

---

## 7. Worktop 与 Quest：`QUEST_CONTENT_WORKTOP_SELECT`

在 `HandlerSelectWorktopOptionReq` 中，除了 Lua 事件，还会投递：

- `QuestContent.QUEST_CONTENT_WORKTOP_SELECT`，参数为 `(configId, optionId)`

对应实现：
- `Grasscutter/src/main/java/emu/grasscutter/game/quest/content/ContentWorktopSelect.java`

判断逻辑（简化版）是：
- `condition.param[0] == configId` **或**
- `condition.param[1] == optionId`

这意味着你可以在任务表里写一个“交互条件”，让任务在玩家点了某个操作台/某个按钮后推进。

同时也要注意：
- 这是一种“宽松匹配”，如果你只填 optionId，可能会因为其他地方也用了同 optionId 而误触发。
- 更稳的做法通常是：同时约束 configId 与 optionId（或用 Lua 自己 `AddQuestProgress` 精确推进）。

---

## 8. 常见坑与排障

1. **点了按钮没触发 `EVENT_SELECT_OPTION`**
   - 检查 gadget 是否真的是 Worktop 类型（`EntityGadget` 内容是否 `GadgetWorktop`）
   - 检查客户端是否真的发了 `SelectWorktopOptionReq`（有些交互是 `GadgetInteractReq`，不是 worktop）

2. **`SetWorktopOptions`/`DelWorktopOption` 返回非 0**
   - 可能不在事件上下文（`callParams` 为 null），或当前 group 未设置
   - 或目标 gadget 不是 Worktop
   - 新脚本优先用 `*ByGroupId` 版本减少隐式依赖

3. **按钮重复出现/可被重复点击**
   - 记得在处理后删除 option（或切 gadget state / 切 suite / 设变量）
   - `trigger_count` 是否需要设为 0（可重复触发）或 1（一次性）

4. **任务意外推进**
   - `QUEST_CONTENT_WORKTOP_SELECT` 是“或匹配”，只约束 optionId 容易误命中
   - 用更严格的条件或改走 `AddQuestProgress("key")`

