# 04 可扩展性与引擎边界：只改脚本/数据能做什么？什么时候必须下潜 Java？

本文对应“第四阶段：可扩展性分析”。目标是把你未来的想法快速分类：

- **脚本/数据层可解**：主要通过 `resources/Scripts/*` + `resources/*BinOutput*` + `resources/Server/*` 完成
- **必须改引擎层**：需要补齐 ScriptLib、扩展事件/实体/同步、改战斗或存档等

---

## 4.1 只改脚本/数据：可以“很轻松”做的事情（典型清单）

前提：需求能用现有 `EventType` + 已实现的 `ScriptLib` API 表达，且客户端已有对应资源表现（模型/动画/UI）。

### A. 新建/改造“挑战房/解谜/遭遇战”（Group 级玩法）

你可以做：

- 新建一个 group：写 `sceneX_groupYYYY.lua`，定义 monsters/gadgets/regions/triggers/suites
- 在 block 脚本里把这个 group 的 id 加进 `groups` 列表，让它在对应区域加载
- 用 `variables + suites` 做有限状态机（FSM）：进区域 → 刷怪 → 计数 → 开宝箱/传送 → 结束

最常用的脚本能力组合：

- 事件：`ENTER_REGION / ANY_MONSTER_DIE / GADGET_STATE_CHANGE / VARIABLE_CHANGE / TIME_AXIS_PASS`
- 编排：`AddExtraGroupSuite / RemoveExtraGroupSuite / RefreshGroup`
- 实体：`CreateMonster / CreateGadget / SetGadgetStateByConfigId`
- 状态：`SetGroupVariableValue / ChangeGroupVariableValue`

### B. 调整掉落/奖励/数值（纯数据改动）

典型改法：

- 修改 `ExcelBinOutput/*Reward*`、`Drop*`、`Item*` 等表
- 或优先用 `Server/` 放覆盖表（因为 `getExcelPath` 会优先找 Server）

### C. 改机关的服务端行为（不用动 Java）

如果你的需求属于“这个 gadget 在服务端收到某个客户端请求时怎么变状态/怎么触发后续”：

- 在 `Scripts/Gadget/` 新增/修改 controller 脚本（实现 `OnClientExecuteReq` 等）
- 在 `Server/GadgetMapping.json` 把某些 gadgetId 指向你的 controllerName

这相当于给某类 gadget 加了一个“服务端组件脚本”。

### D. 把现有 Common 模块当作玩法积木复用

你可以把 `resources/Scripts/Common/` 里的模块当作“玩法组件库”，通过：

- 在 group 脚本里写 `defs/defs_miscs`（参数）
- `require "Vx_y/SomeModule"`

来复用成熟逻辑（注意：见 4.2，部分模块可能依赖未实现的 ScriptLib API）。

---

## 4.2 一看就要下潜 Java/引擎层的需求（以及为什么）

### A. 你想调用的 ScriptLib API 在引擎里是 TODO

这是最常见的“被迫下潜”原因。  
在 `ScriptLib.java` 里大量函数直接 `logger.warn("[LUA] Call unimplemented ...")`，或者只有注释没有实现。

如果你的玩法依赖这些函数（例如某些 Common 模块调用的 API），要么：

- 重写/改写 Lua（绕开缺失 API）
- 要么补齐 Java 实现（下潜引擎层）

### B. 新的事件类型 / 新的同步语义

脚本层只能消费已有 `EventType`。如果你需要：

- 一个全新的事件（例如“连击达成/特定元素反应完成/客户端 UI 点击某按钮”）
- 或者现有事件的参数语义不够（缺字段）

那通常要改 Java：在合适的时机 `callEvent(new ScriptArgs(...))`，并决定 param/source/eid 的契约。

### C. 新的实体类型/组件系统/网络协议

脚本层能做的是“编排已有实体与能力”。如果你需要：

- 新的 entity 类型、或新的能力系统组件（客户端/服务端都要理解）
- 改客户端同步规则、网络包结构、Authority/Vision 逻辑

这已经越过编排层边界，必须动引擎。

### D. 深改战斗公式/数值结算/存档结构

这些属于核心 runtime：

- 战斗计算、属性成长、伤害结算
- 存档结构、持久化字段、跨版本迁移
- 大量系统性修改（比如“把战斗变成回合制/弹幕射击”）

脚本/数据层能做的是“触发/生成/切状态”，不是“改底层物理/数值内核”。

---

## 4.3 快速判断标准：脚本能搞定还是必须改引擎？

建议你每次冒出一个新点子，都按下面的“4 问”快速判定：

1. **我需要的“钩子”是否存在？**  
   - 能否用现有 `EventType`（进区域/死亡/交互/计时/变量变化…）捕获触发时机？
2. **我需要的“动作”是否存在？**  
   - `ScriptLib` 里有没有实现对应能力（刷怪/改状态/加 suite/传送/给奖励/加进度）？
3. **我需要的实体/表现是否已存在？**  
   - 是否有现成 gadgetId/monsterId/ability/config 可以复用？客户端是否有资源？
4. **我需要的数据是否能落在现有表结构里？**  
   - 能否通过编辑 ExcelBinOutput/BinOutput/Server 映射实现，而不需要新增“全新数据通道”？

只要这四问里有两项明确是“否”，就该预期需要下潜 Java（至少补齐 ScriptLib/事件/数据加载）。

---

## 4.4 抽象成“通用 ARPG 引擎脚本层模型”（不提具体游戏）

把本仓库的脚本/数据层抽象掉具体名词后，可以得到一套很通用的编排层模型：

### 4.4.1 核心对象

- `Level`（Scene）：一张关卡/地图
- `Chunk`（Block）：流式加载的空间块
- `Encounter`（Group）：最小玩法单元（房间/谜题/波次）
- `Suite`（State Snapshot）：Encounter 的阶段集合（刷怪波次/机关组合）
- `EntityArchetype`（monster_id/gadget_id）：实体“类型定义”
- `EntityInstance`（config_id）：实体“实例”
- `Region`：空间触发器（进入/离开）
- `Trigger`：事件订阅（Event → condition/action）
- `State`（Variables）：Encounter 的持久状态
- `StdLib`（ScriptLib）：脚本能调用的运行时能力边界

### 4.4.2 通用流程图

```
World State Change
  └─> Event Bus (EventType + evt params)
        └─> Trigger Router (filter by group/source/name)
              ├─> Condition(context, evt) -> bool
              └─> Action(context, evt) -> (return code)
                    └─> StdLib calls
                          ├─> spawn/despawn entities
                          ├─> change entity state
                          ├─> move between suites
                          ├─> mutate variables (FSM)
                          └─> push progress/reward
```

### 4.4.3 对你做“原创 ARPG 引擎”的启发

1. **把玩法表达限制在“事件 + 有限状态 + 标准库动作”**，就能获得很强的可组合性。
2. 用 `Suite` 把“关卡配置对象集”做成可切换快照，是最简单可维护的关卡状态机表达。
3. 为脚本提供一个“明确边界”的 `StdLib`（可调用 API），比让脚本随意访问引擎内部对象更可控。
4. 单实体 Controller（类似 ECS 组件脚本）与 Encounter Trigger（关卡编排脚本）并行存在，可以减少“所有逻辑都堆在关卡脚本”的复杂度。

