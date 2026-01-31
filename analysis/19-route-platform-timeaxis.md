# 19 - Route / MovingPlatform / TimeAxis：路线、移动平台与“时间轴”节拍器

> 本篇专题聚焦三类“驱动玩法节奏”的基础设施：
>
> 1) **Route（路线数据）**：一条由多个点组成的路径（位置 + 速度 + 是否触发到点事件）。  
> 2) **Moving Platform（移动平台/移动机关）**：把某个 gadget 挂到 Route 上，按时间推进到下一个点，并在关键点抛 Lua 事件。  
> 3) **TimeAxis（时间轴）**：Lua 侧常用的“延迟/节拍器”，用于在若干秒后触发事件（比如延迟刷怪、延迟清场、延迟播放演出）。
>
> 关联阅读：
> - `analysis/13-event-contracts-and-scriptargs.md`：`EVENT_PLATFORM_REACH_POINT` / `EVENT_TIME_AXIS_PASS` 的事件字段语义
> - `analysis/12-scene-and-group-lifecycle.md`：scene tick / scheduler / group 生命周期对路线调度的影响

---

## 1. 两套“路线/平台”体系：ConfigRoute（已实现） vs PointArray（缺资源）

在脚本里你会看到两类写法：

1. gadget 直接写 `route_id = xxx`（或在元数据里带 routeId）  
   ⇒ **ConfigRoute**（本仓库已实现并会在服务端调度移动、触发到点事件）

2. gadget 写 `is_use_point_array = true`，然后 Lua 调 `SetPlatformPointArray(...)` 设置路线  
   ⇒ **PointArrayRoute**（本仓库明确标注“缺少资源/未实现”，兼容性风险更高）

这两套的关键差异：
- ConfigRoute：路线点数据在服务端 `BinOutput/LevelDesign/Routes/*.json`，服务端按速度/距离计算到点时间并更新平台位置。
- PointArrayRoute：服务端缺少 point array 数据源与移动逻辑（`PointArrayRoute` 类注释写明 “read from missing resources”），目前主要是“记住 pointArrayId + 发换路线通知”，很难保证脚本按预期触发。

---

## 2. Route 数据从哪里来：`BinOutput/LevelDesign/Routes/*.json`

### 2.1 加载入口：`ResourceLoader.loadRoutes()`

服务端会在启动加载资源时，从：

- `resources/BinOutput/LevelDesign/Routes/*.json`

读取 `SceneRoutes`，并把每个 `Route(localId → route)` 放进：

- `GameData.sceneRouteData[sceneId][routeLocalId]`

然后在 `Scene` 构造时：
- `scene.sceneRoutes = GameData.getSceneRoutes(sceneId)`

### 2.2 Route 的结构（你能改的）

典型路线文件长这样：

- `sceneId`
- `routes[]`：
  - `localId`：routeId（平台引用的就是它）
  - `name`：可读名（脚本/调试用）
  - `points[]`：
    - `pos`：目标位置
    - `targetVelocity`：期望速度（服务端用它算到点时间）
    - `hasReachEvent`：到这个点时是否抛 `EVENT_PLATFORM_REACH_POINT`
  - `rotAngleType` 等旋转参数（当前服务端主要用于协议/客户端表现）

> 对玩法编排层最关键的是：`localId`、`points[].pos`、`points[].targetVelocity`、`hasReachEvent`。

---

## 3. Moving Platform：服务端如何调度移动 + 如何给 Lua 抛事件？

### 3.1 路线状态对象：`BaseRoute` / `ConfigRoute` / `PointArrayRoute`

代码位置：

- `Grasscutter/src/main/java/emu/grasscutter/game/entity/gadget/platform/BaseRoute.java`
- `.../ConfigRoute.java`
- `.../PointArrayRoute.java`

#### ConfigRoute（route_id 驱动）

`ConfigRoute` 的核心状态：
- `routeId`
- `startIndex`：从第几个点开始
- `scheduledIndexes`：平台移动过程中，在 scheduler 上挂了哪些延时任务（用于 stop/换路线时取消）

#### PointArrayRoute（is_use_point_array 驱动）

`PointArrayRoute` 只有：
- `pointArrayId`
- `currentPoint`

并且明确写了 `TODO implement point array routes, read from missing resources`。

### 3.2 启动/停止：Lua API 到实体方法

Lua：
- `ScriptLib.StartPlatform(configId)`
- `ScriptLib.StopPlatform(configId)`

实现上会找到当前 group 内该 `configId` 对应的 `EntityGadget`，再调用：
- `EntityGadget.startPlatform()`
- `EntityGadget.stopPlatform()`

### 3.3 ConfigRoute 的移动逻辑（核心！）

`EntityGadget.startPlatform()` 对 `ConfigRoute` 做了完整调度：

1. `route = scene.getSceneRouteById(routeId)`，取 `Route.points[]`
2. 根据 `startIndex` 决定从哪个点继续
3. 计算每一段的累计耗时：
   - `time += distance(prevPos, nextPos) / nextPoint.targetVelocity`
4. 对每个即将到达的点，向 `scene.scheduler` 注册延迟任务：
   - 到达时：
     - 若 `hasReachEvent && I > currIndex`：抛 Lua 事件 `EVENT_PLATFORM_REACH_POINT`
     - 更新 `startIndex = I`
     - `entity.position = points[I].pos`
     - 若到最后一个点：`started=false`（停止）

#### `EVENT_PLATFORM_REACH_POINT` 的 ScriptArgs 形态

在 `startPlatform` 的调度代码中，构造参数是：

- `group_id`：平台所属 group
- `evt.param1`：平台 `configId`
- `evt.param2`：`routeId`
- `evt.param3`：点序号 `I`
- `evt.source`：平台 `configId`（字符串）

一个很容易踩的点：
- 当 `startIndex==0` 且首次启动时，代码会先抛一次 `EVENT_PLATFORM_REACH_POINT`，并且把 `param3=0`。  
  这常被用作“开始移动/进入路线”的信号，而不是真的“到达第 0 个点”。

### 3.4 换路线：`SetPlatformRouteId`

Lua 可调用：
- `ScriptLib.SetPlatformRouteId(configId, routeId)`

服务端会：
- 取消旧 `scheduledIndexes` 中的所有任务
- 重置 `startIndex=0`、`started=false`
- 广播 `PacketPlatformChangeRouteNotify`

玩法编排层常用套路：
- “某个机关被激活” → 换路线 → `StartPlatform` → 到点触发机关状态变化/刷怪/推进剧情。

---

## 4. PointArrayRoute：为什么很多脚本“看起来要动但动不起来”？

你在大量脚本里会看到：

- gadget 配置：`is_use_point_array = true`
- `defs.routes = { [1]={route=310600001, points={...}}, ... }`
- 在某个事件里调用 `ScriptLib.SetPlatformPointArray(...)` 或相关封装模块

但在本仓库：

1. `PointArrayRoute` 缺少“点数据来源”和“按点移动”的实现。  
2. `ScriptLib.SetPlatformPointArray(...)` 当前主要做的是：
   - 给 gadget 挂/更新一个 `PointArrayRoute`
   - 写入 `pointArrayId`
   - 广播 `PacketPlatformChangeRouteNotify`
   - **并且返回值目前是 `-1`（即使成功），这会让很多 Lua `if 0 ~= ... then` 误判失败。**

因此，PointArray 玩法在这里更像“协议层/客户端可能会动、服务端不保证事件与状态”，属于典型引擎边界。

> 如果你要自制/魔改路线玩法，优先选 **ConfigRoute**，不要用 PointArray 体系，除非你准备补 Java 侧缺失能力。

---

## 5. TimeAxis：Lua 最常用的“节拍器”，但本仓库实现是简化版

### 5.1 Lua 侧使用方式

Lua 常见写法：

- `ScriptLib.InitTimeAxis(context, "axis_name", {3, 8, 12}, false)`
- 触发器监听：
  - `event = EVENT_TIME_AXIS_PASS`
  - `source = "axis_name"`
  - `condition_EVENT_TIME_AXIS_PASS_xxx` 通常会判断：
    - `evt.source_name == "axis_name"`
    - `evt.param1 == 节点序号（1/2/3...）`

一个可以直接观察的例子：

- `resources/Scripts/Scene/3/scene3_group133106134.lua`
  - `InitTimeAxis("killlightriver", {3}, false)`
  - 条件里判断 `evt.param1 == 1`

### 5.2 服务端实现：`SceneTimeAxis`（单延迟版）

实现位置：
- `Grasscutter/src/main/java/emu/grasscutter/scripts/SceneTimeAxis.java`
- 初始化入口：`ScriptLib.InitTimeAxis(...)`

当前实现只做了：
- 用 `java.util.Timer` 安排一个单次/循环任务
- 到时发 `ScriptArgs(groupId, EVENT_TIME_AXIS_PASS).setEventSource(identifier)`

它有两个关键差异（会影响大量脚本兼容性）：

1. **只使用了 `delays[0]`**  
   也就是说 `{3, 8, 12}` 在这里等价于 `{3}`。

2. **不会设置 `evt.param1` 为节点序号**  
   所以 `evt.param1` 默认是 0，这会导致大量脚本里 `if 1 ~= evt.param1 then return false end` 永远不成立。

你可以把当前 TimeAxis 当成：
> “一个按固定间隔触发 `EVENT_TIME_AXIS_PASS` 的计时器（只有 source_name 有意义）”

而不是完整的“多节点时间轴”。

### 5.3 结束与暂停

已实现：
- `ScriptLib.EndTimeAxis(identifier)` → `SceneScriptManager.stopTimeAxis(identifier)`

未实现（常见于活动 Common）：
- `PauseTimeAxis` / `ResumeTimeAxis`
- `EndAllTimeAxis`

---

## 6. GroupTimerEvent vs TimeAxis：两个计时器体系怎么选？

你还会看到另一套 API：

- `ScriptLib.CreateGroupTimerEvent(groupId, source, time)`
- 触发 `EVENT_TIMER_EVENT`（source 为 timer 名）

它的实现走的是 `SceneScriptManager.createGroupTimerEvent(...)`：

- 基于服务器 `Scheduler`（而不是 `java.util.Timer`）
- 会把 `(source, taskId)` 记录到 `activeGroupTimers[groupId]`，便于取消
- 可以通过 `ScriptLib.CancelGroupTimerEvent(groupId, source)` 取消（会在 `activeGroupTimers` 里查找并 cancel）

**对玩法编排的建议：**

- 写新玩法、需要“延迟/循环触发某个事件”：优先用 **GroupTimerEvent**  
  理由：行为更简单、取消更可控、跑在 Scene scheduler 上（能被 pause、也能随 scene 销毁统一回收）。

- 跑现成脚本、已经写死 `EVENT_TIME_AXIS_PASS`：不得不用 **TimeAxis**  
  但要接受它在本仓库是“简化版”，并准备做兼容（改脚本条件或补引擎）。

---

## 7. 一个完整的“路线驱动机关”玩法模板（推荐：ConfigRoute）

这个模板适合做：

- 电梯/平台/移动机关到点触发机关状态变化
- 到点刷怪/开门/播放提示
- 多段路线切换（启动 → 到点 → 换路线 → 再到点）

### 7.1 数据准备（路线 + gadget）

1. 在目标 scene 的路线文件中新增/修改 route：
   - 路径：`resources/BinOutput/LevelDesign/Routes/scene{sceneId}_..._routes.json`
   - 关键：`routes[].localId`（routeId）、`points[].pos`、`points[].targetVelocity`、`points[].hasReachEvent`

2. 在 group 脚本（或 gadget 元数据）里让平台 gadget 走 `ConfigRoute`：
   - 最直观：gadget 配置含 `route_id = routeId`
   - 其次：确保其 `SceneGadget.route_id != 0`（由资源/元数据决定）

3. 需要到点事件的点，记得 `hasReachEvent=true`。

### 7.2 Lua 编排（事件驱动）

推荐的“只改脚本就能跑”的组合：

- 启动：`ScriptLib.StartPlatform(context, platform_config_id)`
- 监听：`EVENT_PLATFORM_REACH_POINT`
  - `evt.param1` = 平台 configId
  - `evt.param2` = routeId
  - `evt.param3` = 点序号（0/1/2/...）

编排习惯：
- 把 `param3==0` 当成“平台开始移动/刚启动”的信号
- 把某个 `param3==k` 当成关键节点：开门、刷怪、切路线、触发剧情

### 7.3 切路线 / 停止 / 暂停

- `ScriptLib.SetPlatformRouteId(configId, newRouteId)`：
  - 会取消旧路线的调度任务并重置 `startIndex`
- `ScriptLib.StopPlatform(configId)`：
  - 会取消调度任务并广播停止
- Scene pause：
  - `Scene.onTick()` 在 `isPaused==true` 时不会跑 scheduler ⇒ 到点回调会停  
  - 适合做“暂停时间”的玩法，但要注意对现成脚本（依赖 tick）的副作用

---

## 8. 常见坑与定位方法

1. **平台不动**
   - gadget 是否真的走到了 `ConfigRoute`？（`route_id != 0`）
   - 路线数据是否被加载？（路线文件是否在 `BinOutput/LevelDesign/Routes/`）
   - 是否调用了 `StartPlatform`？是否被 Lua 条件拦截？
   - Scene 是否处于 pause？

2. **到点事件不触发**
   - 该点的 `hasReachEvent` 是否为 true
   - 你监听的点序号是否把 `0` 当成第一个“真实点”（它在这里更像启动信号）

3. **PointArray 相关脚本误判失败**
   - `SetPlatformPointArray` 当前返回 `-1`，很多脚本会 `if 0 ~= ret then ...` 直接走错误分支
   - 即使绕过返回值，`PointArrayRoute` 也缺少服务端移动与多点事件语义

4. **TimeAxis 条件永远不成立**
   - 脚本写了 `evt.param1==1/2/...`，但本仓库实现不会填 `param1`
   - 兼容手段：改脚本条件、或补 TimeAxis 多节点实现（含 Pause/Resume）

