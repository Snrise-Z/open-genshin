# 02 Lua 脚本运行模型：加载、上下文、事件系统与 ScriptLib API

本文对应“第二阶段：脚本层（Lua）运行模型”。它回答三个问题：

1. **Lua 脚本长什么样**（Scene/Block/Group/Gadget/QuestShare）；
2. **事件系统如何把运行时事件映射到 Lua 函数**（Trigger/Condition/Action）；
3. **脚本能调用哪些服务器 API**（`ScriptLib`，以及如何判断哪些 API 真正可用）。

与其他章节关系：

- `analysis/01-overview.md`：整体目录地图与概念关系。
- `analysis/03-data-model-and-linking.md`：脚本里的 ID 如何落到 ExcelBin/BinOutput/TextMap 上。
- `analysis/04-extensibility-and-engine-boundaries.md`：怎么判断“脚本能搞定 vs 必须改引擎”。

---

## 2.1 Lua 引擎与上下文（ScriptLoader）

核心代码在 `Grasscutter/src/main/java/emu/grasscutter/scripts/ScriptLoader.java`。

### 2.1.1 全局注入：脚本能直接用的“常量/枚举/库”

初始化时注入到 Lua 全局环境的关键对象：

- `EventType`：事件 ID 常量（例如 `EVENT_ENTER_REGION`），见 `.../scripts/constants/EventType.java`
- `GadgetState`：机关状态常量（见 `.../scripts/constants/ScriptGadgetState.java`）
- `RegionShape`：区域形状常量（见 `.../scripts/constants/ScriptRegionShape.java`）
- `EntityType / QuestState / ElementType` 等枚举表（把 Java enum 以数字映射给 Lua）
- `ScriptLib`：**Lua 可调用的服务器 API**（Java 对象注入）

### 2.1.2 “context 参数”在 Grasscutter 里是什么？

你会在 Lua 里看到大量官方风格调用：

```lua
ScriptLib.SetGroupVariableValue(context, "stage", 1)
```

在 Grasscutter/LuaJ 里，**触发器函数被调用时传入的 `context` 实际上就是 `ScriptLib` 自己**（为了兼容官方脚本签名）。  
这带来一个非常重要的理解：

- 大多数 `ScriptLib.*` 方法并不真正使用 `context` 里的字段（它不是“关卡上下文结构体”）
- “当前 group / 当前 entity / 当前事件参数”来自 Java 侧在调用前设置的 ThreadLocal（见 `ScriptLib`）

### 2.1.3 require 的工作方式（Common 模块）

Lua 里常见：

```lua
require "V3_3/CoinCollect"
```

在 Grasscutter 中会被解析成 `Common/<name>.lua`，对应磁盘路径：

- `resources/Scripts/Common/V3_3/CoinCollect.lua`

`server.fastRequire`（见 `ConfigContainer.Server.fastRequire`）会影响 require 的实现策略：

- `true`：按文件编译/缓存（快）
- `false`：把 `require` 的目标脚本源码内联拼接进来再编译（慢但更“兼容”某些脚本写法）

---

## 2.2 Scene / Block / Group：三层脚本的结构与作用

这一套是“玩法编排层”的骨架。

### 2.2.1 Scene 元数据脚本：`scene<sceneId>.lua`

示例：`resources/Scripts/Scene/1/scene1.lua`  
典型字段：

- `scene_config`：出生点、地图范围、die_y 等
- `blocks`：区块 id 列表
- `block_rects`：每个区块的 AABB（min/max）
- （可见但引擎未必使用）`dummy_points`、`routes_config`

Java 侧解析：`.../scripts/data/SceneMeta.java`

### 2.2.2 Block 脚本：`scene<sceneId>_block<blockId>.lua`

示例：`resources/Scripts/Scene/1/scene1_block1101.lua`  
核心字段：

- `groups = { { id = ..., pos = ..., refresh_id = ... , dynamic_load = ... }, ... }`

Java 侧解析：`.../scripts/data/SceneBlock.java`

> 你可以把 Block 当成“流式加载的 content chunk”，它只负责告诉引擎：这个空间块里有哪些 group。

### 2.2.3 Group 脚本：`scene<sceneId>_group<groupId>.lua`

示例：

- `resources/Scripts/Scene/1/scene1_group111101067.lua`：纯配置（只有 gadgets，没有 trigger）
- `resources/Scripts/Scene/1/scene1_group111101139.lua`：有 triggers + require Common 模块
- `resources/Scripts/Scene/1/scene1_group111102094.lua`：主要靠 require Common 模块注入逻辑

典型结构（简化骨架）：

```lua
local base_info = { group_id = 111101139 }
local defs = { ... }          -- 可选：给 Common 模块的参数
local defs_miscs = { ... }    -- 可选：复杂参数（表/映射）

monsters  = { ... }   -- SceneMonster 列表（或 map）
gadgets   = { ... }   -- SceneGadget 列表（或 map）
regions   = { ... }   -- SceneRegion 列表（或 map）
triggers  = { ... }   -- SceneTrigger 列表
variables = { ... }   -- SceneVar 列表（group variable 定义）

init_config = { suite = 1, end_suite = 0, rand_suite = false }
suites = {
  { monsters={...}, gadgets={...}, regions={...}, triggers={...}, rand_weight=100 },
  ...
}

function condition_EVENT_...(context, evt) ... end
function action_EVENT_...(context, evt) ... end

require "SomeCommonModule"
```

Java 侧解析：`.../scripts/data/SceneGroup.java`（注意：group 脚本 eval 后，是从 bindings 里把 `monsters/gadgets/...` 读出来反序列化成 Java 对象）

---

## 2.3 Common 模块：用“注入”做可复用玩法组件

示例：`resources/Scripts/Common/BlackBoxPlay/MagneticGear.lua`、`resources/Scripts/Common/V3_3/CoinCollect.lua`

这类脚本常见模式：

1. group 脚本里提前定义 `defs/defs_miscs/base_info/gadgets/...` 等“参数表”
2. `require` Common 模块
3. Common 模块通过 `LF_Initialize_Group(...)` 把：
   - `extraTriggers` 插入 `triggers`
   - 把 trigger 名称挂到某个 suite（通常 suite 1）的 `suites[x].triggers`
   - `extraVariables` 插入 `variables`
4. 模块自己实现 `action_*` / `condition_*` 函数

这种写法的本质：**把 Lua 当成一个“可编排 DSL + 宏系统”**。  
你的自制玩法如果想长期可维护，也建议沿用这个范式：把“关卡实例参数”留在 group 脚本里，把“通用逻辑”做成 Common 模块。

---

## 2.4 Gadget Controller 脚本：实体级回调（非 group trigger）

目录：`resources/Scripts/Gadget/*.lua`  
示例：`resources/Scripts/Gadget/BadmintonBall.lua`、`resources/Scripts/Gadget/LaserSwitch.lua`

### 2.4.1 Controller 是怎么绑定到 gadgetId 的？

绑定来自 `resources/Server/GadgetMapping.json`：

- `gadgetId` → `serverController`（例如 `"LaserSwitch"`）
- 引擎会加载 `Scripts/Gadget/LaserSwitch.lua` 并缓存

关键 Java：

- `EntityControllerScriptManager`：扫描 `Scripts/Gadget/*.lua` 并缓存 bindings
- `EntityGadget`：构造时根据 `GadgetMapping` 找 controllerName，再取对应 controller

### 2.4.2 Controller 能写哪些函数？

引擎会调用（见 `EntityController`）：

- `OnClientExecuteReq(context, param1, param2, param3)`：客户端请求（常用于“机关旋转/切换状态”等）
- `OnDie(context, elementType, ...)`
- `OnBeHurt(context, elementType, ..., isHost)`
- `OnTimer(context, now)`

并且在 Controller 回调中，`ScriptLib` 通过 ThreadLocal 能拿到“当前 entity”，因此可以用：

- `ScriptLib.SetGadgetState(context, GadgetState.XXX)`：作用在当前 gadget 实体上

> 这层更像“ECS 里的组件脚本”，和 group trigger 是两条并行的脚本通路。

---

## 2.5 Quest Share Config：Lua 当“数据文件”加载

目录：`resources/Scripts/Quest/Share/Q*ShareConfig.lua`  
示例：`resources/Scripts/Quest/Share/Q352ShareConfig.lua`

它不是 trigger 驱动脚本，更接近“结构化配置”：

- `main_id`、`sub_ids`
- `quest_data[...]`：校验/生成用数据（npcs、transmit_points…）
- `rewind_data[...]`：断线重连恢复数据

Java 侧加载：`ResourceLoader.loadQuestShareConfig()`  
加载方式：逐个 `eval`，然后把 `quest_data/rewind_data` 反序列化进 `GameData.getTeleportDataMap()/getRewindDataMap()`。

---

## 2.6 事件系统：Event → Trigger → Condition → Action

核心实现：`Grasscutter/src/main/java/emu/grasscutter/scripts/SceneScriptManager.java`

### 2.6.1 触发器是怎么注册的？

- group 被加载后（或 RefreshGroup）会把当前 suite 的 entities 生成进 Scene
- 同时把当前 suite 的 triggers 注册到 `SceneScriptManager`（Trigger 是按 eventType 分桶存储的）

### 2.6.2 运行时事件如何命中 trigger？

伪代码（抽象化）：

```text
callEvent(evt):
  candidates = triggersByEvent[evt.type]
  candidates = filter by groupId（或 evt.group_id==0 表示全局）
  candidates = filter by trigger.source（如果有）
  if evt is ENTER/LEAVE_REGION:
      - name <= 12: 认为是“通配 region trigger”（对所有 region 生效）
      - name > 12: 取 name 的后缀数字，必须等于 evt.param1（region config_id）
  for each trigger:
      set ScriptLib.currentGroup = trigger.currentGroup
      set ScriptLib.callParams   = evt
      if trigger.condition 为空或 condition(...) 返回 true:
          action(...)
          根据 trigger_count / action 返回值决定是否自动注销 trigger
```

### 2.6.3 命名约定：只是约定，不是强制

Lua 里常见命名：

- `condition_EVENT_ENTER_REGION_94015`
- `action_EVENT_ANY_MONSTER_DIE_1234`

但注意：**Java 侧实际是按 trigger 表里的字符串字段去查函数**，并不要求你一定用这套命名；命名主要用于可读性、以及对齐官方脚本风格。

---

## 2.7 `evt`（ScriptArgs）字段与常见事件参数约定

Lua 中 `evt` 是 `ScriptArgs`（见 `.../scripts/data/ScriptArgs.java`），常用字段：

- `evt.type`：事件类型（EventType）
- `evt.group_id`：groupId（有时为 0 表示不限定）
- `evt.param1/param2/param3`：事件参数（不同事件含义不同）
- `evt.source`：字符串 source（变量名、timer source、time axis identifier…）
- `evt.source_eid / evt.target_eid`：相关实体 entityId（部分事件会填）

常见事件在本仓库里的典型赋值（以实际 Java 调用点为准）：

| 事件 | 关键字段含义（常见） |
|---|---|
| `EVENT_GROUP_LOAD` | `param1 = group_id` |
| `EVENT_ANY_MONSTER_DIE` | `param1 = monster.config_id` |
| `EVENT_ANY_MONSTER_LIVE` | `param1 = monster.config_id`（每 tick 触发，注意性能/刷屏） |
| `EVENT_GADGET_STATE_CHANGE` | `param1 = newState`, `param2 = gadget.config_id`, `param3 = oldState` |
| `EVENT_VARIABLE_CHANGE` | `param1 = newValue`, `param2 = oldValue`, `source = 变量名`（由 SetGroupVariableValue 触发） |
| `EVENT_ENTER_REGION / EVENT_LEAVE_REGION` | `param1 = region.config_id`, `source_eid = regionEntityId`, `target_eid = 进入/离开实体`, `source = entityTypeId(字符串)` |
| `EVENT_TIME_AXIS_PASS` | `source = timeAxis identifier`（param* 通常为 0） |
| `EVENT_TIMER_EVENT` | `source = timer source`（param* 通常为 0） |

> 建议写脚本时：把每个事件的 `param*` 语义当作“接口契约”，不确定就回到 Java 里 grep `new ScriptArgs(..., EventType.XXX, ...)` 看赋值点。

---

## 2.8 ScriptLib API 清单（按“玩法编排能力”分组）

**核心文件：** `Grasscutter/src/main/java/emu/grasscutter/scripts/ScriptLib.java`  
重要现实：ScriptLib 里有大量 `TODO/unimplemented/unchecked` 方法，说明 **官方脚本接口并未全量实现**。写玩法时，务必以本仓库的 `ScriptLib.java` 为准。

下面列的是“编排层最常用、且在本仓库里能看到明确实现逻辑的一批 API”（按类别整理，便于当作 DSL 的标准库使用）。

### A. 日志/调试

- `PrintContextLog(msg)`：带 groupId 的 trace 日志
- `PrintLog(msg)`：通用 trace 日志

### B. Group/Suite 编排（类似“关卡状态机”）

- `RefreshGroup({ group_id=..., suite=... })`：把 group 刷到指定 suite（会触发实体/trigger 的增删）
- `GetGroupSuite(groupId)`：查询当前激活 suiteId
- `GoToGroupSuite(groupId, suite)`：切 suite（内部会 refresh）
- `AddExtraGroupSuite(groupId, suite)`：把某个 suite 追加进当前 group（常用于“刷怪波次/后续机关”）
- `RemoveExtraGroupSuite(groupId, suite)`：移除 suite
- `KillExtraGroupSuite(groupId, suite)`：清理某 suite 的实体（偏“强制清场”）

### C. 实体生成/移除（以 config_id 为核心）

- `CreateMonster({ config_id=..., delay_time=... })`：按当前 group 的 monster config 生成实体
- `CreateGadget({ config_id=... })`：按当前 group 的 gadget config 生成实体
- `RemoveEntityByConfigId(groupId, entityType, configId)`：移除实体（不一定等价 kill）
- `KillEntityByConfigId({ group_id=..., entity_type=..., config_id=... })`：杀死实体（会触发 die 相关逻辑）
- `KillGroupEntity({ group_id=..., kill_policy=... })` / `KillGroupEntity({ group_id=..., monsters={...}, gadgets={...} })`：批量处理（取决于实现分支）

> 这里 `config_id` 来自 group 脚本里的 `monsters/gadgets` 配置对象；`entityType` 通常用 `EntityType.GADGET / EntityType.MONSTER`。

### D. Gadget 状态/交互（机关是玩法编排的主力）

- `SetGadgetStateByConfigId(configId, gadgetState)`：修改当前 group 内 gadget 状态（会触发 `EVENT_GADGET_STATE_CHANGE`）
- `SetGroupGadgetStateByConfigId(groupId, configId, gadgetState)`：跨 group 修改 gadget 状态
- `GetGadgetStateByConfigId(groupId, configId)`：查询 gadget 当前状态
- `SetGadgetEnableInteract(groupId, configId, enable)`：开关交互
- （Controller 环境）`SetGadgetState(gadgetState)`：对“当前 gadget 实体”改状态（常见于 `Scripts/Gadget/*.lua`）

### E. Group Variables（持久状态/计数器）

- `GetGroupVariableValue(var)`：取当前 group 的变量
- `SetGroupVariableValue(var, value)`：设置当前 group 变量，并自动触发 `EVENT_VARIABLE_CHANGE`（source=varName）
- `ChangeGroupVariableValue(var, delta)`：对当前变量做增量
- `GetGroupVariableValueByGroup(var, groupId)` / `SetGroupVariableValueByGroup(var, value, groupId)`：跨 group 操作

### F. 定时器（TimeAxis 与 GroupTimer）

- `InitTimeAxis(identifier, delays[], shouldLoop)`：启动 time axis（会触发 `EVENT_TIME_AXIS_PASS`，source=identifier）
- `EndTimeAxis(identifier)`：停止 time axis
- `CreateGroupTimerEvent(groupId, source, timeSeconds)`：启动 group timer（会触发 `EVENT_TIMER_EVENT`，source=source）
- `CancelGroupTimerEvent(groupId, source)`：停止 group timer

> 注意：有些官方常用的 `PauseTimeAxis/ResumeTimeAxis` 在本仓库里标了 TODO（脚本可能调用但不会生效）。

### G. 查询/工具（把“世界状态”喂给条件判断）

- `GetEntityIdByConfigId(configId)`：从当前 group 的 configId 找 entityId
- `GetEntityType(entityId)`：entityId → EntityType
- `GetMonsterIdByEntityId(entityId)` / `GetGadgetIdByEntityId(entityId)`：entityId → monsterId/gadgetId
- `GetRegionEntityCount({ region_eid=..., entity_type=... })`：区域内实体计数（常用于 enter region 条件）
- `GetServerTime()`：服务器时间（秒）

### H. 任务/进度（更像“游戏状态机的外部输入”）

- `AddQuestProgress(key)`：对玩家当前进度键 +1，并向任务系统派发 `LUA_NOTIFY` 类事件（用于脚本驱动任务推进）
- `GetHostQuestState(questId)`：查询主机玩家某 quest 状态

---

## 2.9 写脚本时的“现实约束”（非常重要）

1. **资源脚本很多来自官方/社区，但引擎实现并不齐**：Common 模块里可能调用了 `ScriptLib` 的 TODO 方法（例如 `CreateGadgetByConfigIdByPos`、`PauseTimeAxis` 等），这类逻辑在当前引擎里可能不会生效。
2. 因此建议把玩法开发分两步：
   - 先用“已实现 API”拼出可运行的核心 loop
   - 再决定：是绕开缺失 API（重写 Common 模块），还是去 Java 侧补齐 ScriptLib（见第 4 章）

