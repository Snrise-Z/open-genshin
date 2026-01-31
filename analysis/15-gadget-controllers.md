# 15 Gadget 控制器脚本专题：`Scripts/Gadget/*`（按 gadgetId 挂载的服务端行为组件）

本文聚焦一种经常被忽略、但对“只改脚本就能魔改玩法”很关键的脚本层：**Gadget Controller（实体控制器脚本）**。

它与 Scene group 脚本的关系可以一句话概括：

- `Scene/<sceneId>/scene<sceneId>_group<groupId>.lua`：**关卡编排脚本**（玩法单元、suite、triggers、regions）
- `Gadget/<ControllerName>.lua`：**实体组件脚本**（某类 gadget 的服务端行为回调）

与其他章节关系：

- `analysis/02-lua-runtime-model.md`：Lua 上下文与 ScriptLib 注入方式。
- `analysis/12-scene-and-group-lifecycle.md`：gadget 实体生命周期与事件触发顺序。
- `analysis/14-scriptlib-api-coverage.md`：controller 依赖的 ScriptLib API 是否可用（很多 controller/活动脚本会踩坑）。

---

## 15.1 Gadget Controller 是什么：按 gadgetId 绑定的一段“服务端组件逻辑”

你可以把它当作 ARPG 引擎里的“Entity Component Script”：

- 它不是挂在某个 group 上，而是挂在 **某个 gadget 类型（gadgetId）** 上
- 当该 gadget 实体在服务端发生某些事情（客户端请求/受伤/死亡/tick），引擎会调用 controller 的回调函数

它最适合做：

- “这个机关收到客户端某个 execute 请求后，服务端如何改状态/触发后续？”
- “这个机关按时间自动循环状态”
- “这个机关受伤/死亡时要额外做什么（比如触发掉落、改变量、标记状态）”

---

## 15.2 数据入口：`Server/GadgetMapping.json`（gadgetId → serverController）

位置：`resources/Server/GadgetMapping.json`

条目结构：

```json
{ "gadgetId": 70210001, "serverController": "Chest_Interact" }
```

含义：

- `gadgetId`：Excel 层的 gadget 类型 ID（group 脚本里写的那个 `gadget_id`）
- `serverController`：控制器脚本名（对应 `resources/Scripts/Gadget/<serverController>.lua`）

例如你能在文件头部看到：

- `70210001..702100xx` → `Chest_Interact`
- `7013000x` → `SetGadgetState`

> 这层映射属于“Server 补丁层”，你可以通过改它来把某类 gadget 的行为完全替换为你自己的 controller。

---

## 15.3 加载与缓存：所有 `Scripts/Gadget/*.lua` 会在启动时被 eval

加载入口：

- `EntityControllerScriptManager.load()`  
  文件：`Grasscutter/src/main/java/emu/grasscutter/scripts/EntityControllerScriptManager.java`

行为：

- 扫描 `resources/Scripts/Gadget/*.lua`
- 对每个文件：
  - `ScriptLoader.getScript("Gadget/<file>.lua")`
  - `ScriptLoader.eval(cs, bindings)`
  - 缓存为 `EntityController`（保存编译脚本与 bindings）

这意味着：

- controller 是全局缓存（不是每个实体一份）
- 修改 controller 通常需要重启（除非你自己做热重载机制）

---

## 15.4 controller 是什么时候挂到实体上的？

挂载点在 `EntityGadget` 构造函数：

- 文件：`Grasscutter/src/main/java/emu/grasscutter/game/entity/EntityGadget.java`
- 逻辑：
  - 如果 `GameData.gadgetMappingMap` 包含 gadgetId：
    - 取出 controllerName
    - `EntityControllerScriptManager.getGadgetController(controllerName)`
    - `this.setEntityController(...)`

因此只要满足：

1) 你的 group 脚本生成了某个 gadgetId 的实体
2) `GadgetMapping.json` 有映射
3) 对应的 `Scripts/Gadget/<name>.lua` 存在且能成功加载

那该实体就会带 controller。

---

## 15.5 controller 的回调 ABI：可用的函数名与参数语义

文件：`Grasscutter/src/main/java/emu/grasscutter/scripts/data/controller/EntityController.java`

它会尝试在 controller bindings 里查找以下函数名：

| 回调函数名（Lua） | 由谁调用 | 触发语义 | 参数（除 context 外） |
|---|---|---|---|
| `OnClientExecuteReq` | 客户端请求 | gadget 执行 Lua（通常是 abilityRequest/交互） | `param1, param2, param3`（来自协议 ExecuteGadgetLuaReq） |
| `OnTimer` | 服务端 tick | 每 tick 调一次（sceneTimeSeconds） | `now` |
| `OnBeHurt` | 受伤回调 | 任意 EntityDamageEvent 后 | `elementType, 0, isHost`（当前实现里 isHost 固定 true） |
| `OnDie` | 死亡回调 | entity death event 后 | `elementType, 0` |

注意：

- `context` 在 Grasscutter 里仍然是 ScriptLib（由 `EntityController` 调用时传 `ScriptLoader.getScriptLibLua()`）
- controller 内部会 `ScriptLib.setCurrentEntity(entity)`，所以你能用 `ScriptLib.SetGadgetState(...)` 等“当前实体语义”的 API

---

## 15.6 调用链路：从网络包到 Lua 回调（你排错时很有用）

### 15.6.1 OnClientExecuteReq：来自 `ExecuteGadgetLuaReq`

触发点：

- `HandlerExecuteGadgetLuaReq`  
  文件：`Grasscutter/src/main/java/emu/grasscutter/server/packet/recv/HandlerExecuteGadgetLuaReq.java`

流程：

1) 客户端发 `ExecuteGadgetLuaReq`（带 `sourceEntityId + param1/2/3`）
2) 服务端取实体（必须是 EntityGadget）
3) 调 `gadget.onClientExecuteRequest(param1, param2, param3)`
4) `GameEntity.onClientExecuteRequest` → `entityController.onClientExecuteRequest`
5) 执行 Lua `OnClientExecuteReq(context, param1, param2, param3)`

返回值：

- 若 Lua 返回 int 且为 1，会让 handler 返回 result=1（表示某种失败/拒绝语义）
- 否则返回 0

### 15.6.2 OnTimer：来自 Scene tick

触发点：

- `Scene.onTick()` 会遍历 entities 调 `entity.onTick(sceneTime)`
- `GameEntity.onTick` 若有 entityController 则 `controller.onTimer(entity, sceneTime)`

意味着：

- controller 的 OnTimer 频率非常高（每 tick）
- 适合做轻量状态机，不适合做重逻辑（容易性能炸）

### 15.6.3 OnBeHurt / OnDie：来自伤害与死亡事件

触发点（受伤）：

- `GameEntity.runLuaCallbacks(EntityDamageEvent event)` → `entityController.onBeHurt(...)`

触发点（死亡）：

- `GameEntity.onDeath(...)` 里会 `entityController.onDie(...)`

> controller 级回调发生在实体层，而 group trigger（如 `EVENT_ANY_GADGET_DIE`）发生在场景脚本层；两者可以配合使用。

---

## 15.7 controller 与 group 脚本怎么协作？（推荐的组合套路）

controller 最常见的“桥接动作”是改 gadget 状态：

- controller：`ScriptLib.SetGadgetState(context, GadgetState.Action01)`

一旦状态改变：

- `EntityGadget.updateState` 会触发 group 事件：
  - `EVENT_GADGET_STATE_CHANGE`（见 `analysis/13`）

于是你可以把逻辑分层：

- controller 负责“这个 gadget 自己的状态机/响应客户端请求”
- group 脚本负责“当某个 gadget 进入某状态时，整个玩法单元怎么推进”（切 suite、刷怪、开门、给奖励…）

这是一种非常引擎化的写法：实体组件驱动关卡编排。

---

## 15.8 看两个最小例子：Chest_Interact 与 SetGadgetState

### 15.8.1 `SetGadgetState.lua`（最小可用 controller）

文件：`resources/Scripts/Gadget/SetGadgetState.lua`

- 只有一个函数：
  - `OnClientExecuteReq(context, param1, param2, param3)`
- 行为：
  - `ScriptLib.SetGadgetState(context, param1)`（把 param1 当作目标 gadget state）

这个例子很适合你做“服务端开关门/切机关状态”的原型。

### 15.8.2 `Chest_Interact.lua`（按请求复位状态）

文件：`resources/Scripts/Gadget/Chest_Interact.lua`

- 当 `param1 == 0` 时把宝箱状态设回 Default

它展示了一个典型模式：

> 用 `OnClientExecuteReq` 把客户端的一次“执行请求”翻译成服务端状态改变。

---

## 15.9 controller 编写注意事项（结合 ScriptLib 覆盖度现实）

### 15.9.1 不是所有 controller 里用的 ScriptLib API 都已实现

例如仓库里一些 controller 会调用：

- `ScriptLib.GetGadgetArguments(...)`

但在当前 `ScriptLib.java` 中并未找到该方法（属于 missing）。  
因此你遇到 controller 不工作时，不要先怀疑脚本写法，先按 `analysis/14` 的流程做 API 覆盖审计。

### 15.9.2 OnTimer 很容易引起“隐藏性能问题”

建议：

- 不要在 OnTimer 里频繁做全局扫描（找实体/遍历全 players）
- 尽量基于“状态 begin time + 当前 state”做 O(1) 判断
- 或者用 group 的 TimeAxis/TimerEvent 替代 entity tick（更可控）

### 15.9.3 controller 的“返回值语义”与 group trigger 不一样

controller 的 OnClientExecuteReq 返回 int 1 时会让请求结果为 1（通常表示失败/拒绝）。

而 group trigger action 的返回值（0/-1）会影响 trigger 是否被注销（见 `analysis/13`）。

不要混淆两者。

---

## 15.10 如何新增一个自定义 controller（推荐流程）

1) 新增脚本文件：`resources/Scripts/Gadget/MyController.lua`
   - 实现你需要的回调（至少 `OnClientExecuteReq` 或 `OnTimer`）
2) 在 `resources/Server/GadgetMapping.json` 增加映射：
   - `{ "gadgetId": <你的gadgetId>, "serverController": "MyController" }`
3) 在某个 group 脚本里放置该 gadgetId 的 gadget（或通过 ScriptLib.CreateGadget 生成）
4) 重启服务器（controller 在启动时缓存）
5) 验证：
   - 触发客户端 execute 请求（若你的 gadget 会发 ExecuteGadgetLuaReq）
   - 或观察 OnTimer/OnBeHurt/OnDie 的效果

排错重点：

- 日志是否出现 “Gadget controller X not found.”（脚本没加载/命名不一致）
- 你的 controller 是否调用了 missing/unimplemented ScriptLib API（见 `analysis/14`）

---

## Revision Notes

- 2026-01-31：创建本文档（Gadget 控制器脚本专题初版）。

