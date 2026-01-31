# 17 - Challenge / Gallery / ScenePlay：活动与副本的“统一玩法运行时”到底是什么

> 本篇是专题文档，目标是把三个经常被混用的概念拆开：`Challenge`（挑战）、`Gallery`（计分/结算器）、`ScenePlay/MultistagePlay`（多阶段玩法框架）。
>
> - 如果你想“只改脚本/数据就做玩法”，最先该掌握的是 **Challenge**：它在本仓库里有较完整的 Java 支撑。
> - 你在 `Common/Vx_y` 里看到的大量 **Gallery/ScenePlay** 调用，在本仓库属于**未实现/部分实现**的边界；能分析其范式，但想跑起来通常需要补引擎能力。
>
> 关联阅读：
> - `analysis/11-activities-deep-dive.md`：Common/Vx_y 模块注入范式与兼容性问题
> - `analysis/13-event-contracts-and-scriptargs.md`：事件 ABI（`evt.param*` / `evt.source`）与触发器路由规则
> - `analysis/18-dungeon-pipeline.md`（本次新增）：Dungeon/副本全链路（包含 Challenge 与通关条件的关系）

---

## 1. 一句话心智模型：三者各自负责什么？

把它们当成“玩法编排层 DSL 的三个不同运行时组件”更好理解：

1. **Challenge（挑战）**：偏“战斗/目标达成”的**服务器权威**计时器与目标检查器。  
   - 典型：限时杀怪、守护装置血量、时间存活、触发器在时间内触发 N 次。  
   - 产物：对客户端广播挑战开始/结束；对 Lua 抛出 `EVENT_CHALLENGE_SUCCESS/FAIL`；对副本系统抛出“挑战完成”条件。

2. **Gallery（画廊/计分器）**：偏“活动/小游戏”的**计分面板 + 结算协议**。  
   - 典型：收集硬币、射气球、下落躲避、捉迷藏、吃豆人等。  
   - 产物：客户端专用的 Gallery 协议通知（多种 `Gallery*Notify` / `*GallerySettleNotify`），Lua 常通过 `UpdatePlayerGalleryScore` 类接口驱动 UI/结算。
   - **本仓库现状**：大量 API 是 `TODO/unimplemented`，属于“脚本层已写好，运行时缺引擎”。

3. **ScenePlay / MultistagePlay（场景玩法/多阶段玩法）**：偏“复杂活动”的**统一编排框架**。  
   - 典型：一个活动由多个 stage 组成；每个 stage 可能有不同玩法目标、不同 Gallery、不同刷怪/机关组。  
   - 产物：多阶段切换、阶段内/阶段间变量、对客户端同步“当前玩法/队伍实体”等。  
   - **本仓库现状**：除 `ScenePlaySound` 等极少数接口外，大多为 `TODO`。

结论：  
**想在当前仓库里“只靠脚本/数据跑起来”**：优先用 `Challenge + Group(变量/套件) + Dungeon(可选)`；  
**想复用大量 Common 活动模块**：迟早要补 `Gallery/ScenePlay` 的 Java/协议侧能力。

---

## 2. Challenge（挑战）系统：从 Lua 一行调用到 Java 状态机的全链路

### 2.1 Lua 入口：`ScriptLib.ActiveChallenge(...)`

入口在 `Grasscutter/src/main/java/emu/grasscutter/scripts/ScriptLib.java` 的 `ActiveChallenge`：

- 关键行为：
  - 场景级只有一个 `Scene.challenge`，若已有挑战进行中会拒绝创建（日志：`tried to create challenge while one is already in progress`）。
  - 对深境螺旋（Tower）做了一个特殊处理：脚本可能第二次调用 `ActiveChallenge` 传入“上一阶段耗时”，会被换算成“剩余时间/用时差”（这个属于兼容补丁）。
  - 最终通过 `ChallengeFactory.getChallenge(...)` 构建 `WorldChallenge`，`scene.setChallenge(challenge)`，`challenge.start()`。

你可以把 `ActiveChallenge(...)` 当作“创建一个挑战对象 + 把它挂到 Scene 上 + 广播开始协议 + 开始计时/监听”的原子操作。

### 2.2 数据入口：`DungeonChallengeConfigData.json`

`ChallengeFactory` 会用 `challengeDataId`（Lua 里第二个参数）查表：

- 数据文件：`resources/ExcelBinOutput/DungeonChallengeConfigData.json`
- 字段重点：
  - `id`：挑战配置 id（Lua 第二参）
  - `challengeType`：挑战类型枚举（决定用哪种 ChallengeFactoryHandler）
  - `target/progressTextTemplateTextMapHash`：客户端 UI 文案模板（服务端通常不解析文本，只传协议/由客户端自己显示）

### 2.3 构建器：`ChallengeFactory` + `ChallengeFactoryHandler`

构建逻辑在：

- `Grasscutter/src/main/java/emu/grasscutter/game/dungeons/challenge/factory/ChallengeFactory.java`
- 以及各个 `*ChallengeFactoryHandler.java`

它做的事是：
1. `challengeDataId` → 查表得 `challengeType`
2. 根据 `challengeType` 选择 handler
3. handler 将 `ActiveChallenge` 的 6 个整数参数解释成不同含义，拼出：
   - `timeLimit`
   - `goal`（比如杀怪数）
   - `paramList`（用于协议/日志/未来扩展）
   - `challengeTriggers`（Kill/Time/Guard/Trigger 等触发器组合）

### 2.4 运行时对象：`WorldChallenge`

核心类：`Grasscutter/src/main/java/emu/grasscutter/game/dungeons/challenge/WorldChallenge.java`

它是一个小型状态机：

- `start()`：
  - `progress=true`
  - 记录 `startedAt=sceneTimeSeconds`
  - 广播 `PacketDungeonChallengeBeginNotify`
  - 调用各 `ChallengeTrigger.onBegin`

- `done()`（成功）：
  - `finish(true)`：广播 `PacketDungeonChallengeFinishNotify`，清怪（`removeMonstersInGroup`）
  - Lua 事件：`EVENT_CHALLENGE_SUCCESS`
    - `group_id`：挑战所属 group
    - `evt.source`：`challengeIndex`（字符串）
    - `evt.param2`：`finishedTime`（耗时）
  - Dungeon 条件：`scene.triggerDungeonEvent(DUNGEON_COND_FINISH_CHALLENGE, challengeId, challengeIndex)`

- `fail()`（失败）：
  - Lua 事件：`EVENT_CHALLENGE_FAIL`
    - `evt.source`：同上

并且它会接收实体回调：
- `onMonsterDeath`：由 `EntityMonster` 在死亡/结算路径里触发
- `onGadgetDeath`：由 `EntityGadget.onDeath` 触发
- `onGroupTriggerDeath`：由 `SceneTrigger` 相关逻辑触发（用于 “在时间内触发某 trigger N 次”）

> 重要理解：**Lua 不负责“挑战目标是否达成”的核心判断**，Lua 更多是在 “挑战开始/成功/失败” 这些节点上做玩法编排（刷下一波、开门、发奖励、切套件）。

---

## 3. Challenge 参数语义：不同 `challengeType` 解释同一组 6 个整数

`ScriptLib.ActiveChallenge(challengeId, challengeIndex, p3, p4, p5, p6)` 的“参数语义”随挑战类型变化。

下面是“本仓库已实现 handler 的类型”与其参数解释（按 `ChallengeFactoryHandler` 代码反推）：

| ChallengeType（来自 DungeonChallengeConfigData） | 典型含义 | ActiveChallenge 参数解释（经验模型） |
|---|---|---|
| `CHALLENGE_KILL_COUNT` | 杀怪数量达标 | `p3=groupId`（刷怪 group），`p4=goal`（杀怪数） |
| `CHALLENGE_KILL_COUNT_IN_TIME` | 限时杀怪 | `p3=timeLimit`（秒），`p4=groupId`，`p5=goal` |
| `CHALLENGE_KILL_COUNT_FAST` | 限时杀怪 + 杀怪加时/刷新计时（实现里带 `KillMonsterTimeIncTrigger`） | 同上，且额外触发器根据 `timeLimit`/策略更新 |
| `CHALLENGE_SURVIVE` | 存活到时间结束 | `p3=timeToSurvive`，其余未用 |
| `CHALLENGE_KILL_MONSTER_IN_TIME` | 限时击杀指定 cfgId 的怪（更像“击杀目标怪”） | `p3=timeLimit`，`p4=groupId`，`p5=targetCfgId` |
| `CHALLENGE_TRIGGER_IN_TIME` | 限时触发某 tag 的 trigger N 次 | `p3=timeLimit`，`p5=triggerTag`，`p6=triggerCount` |
| `CHALLENGE_KILL_COUNT_GUARD_HP` | 杀怪数量 + 守护某 gadget 血量 | `p3=groupId`，`p4=monstersToKill`，`p5=gadgetCfgId` |

注意两点“坑”：
1. **触发器 source 匹配**：很多 Lua 触发器会写 `source="1"` / `"2"`。在本仓库里 `EVENT_CHALLENGE_SUCCESS/FAIL` 的 `evt.source` 来自 `WorldChallenge.getChallengeIndex()`，而这个值在实践上更贴近“Lua 调用的第一个参数（本地挑战编号）”。  
   - 你写脚本时：把 `source` 当作 “ActiveChallenge 第一参” 来对齐，兼容性更好。
2. **Stop/Pause**：`ScriptLib.StopChallenge` 目前是 `unimplemented`；若你需要“主动结束挑战”，在现状下只能用“让挑战自然成功/失败”或“切组/退副本”绕开。

---

## 4. 事件与 Lua 编排：用 Challenge 拼一个“可复用挑战模板”

一个非常 ARPG 的“玩法编排模板”是：

1. `EVENT_GROUP_LOAD / EVENT_ENTER_REGION`：
   - 初始化变量
   - 刷第一波怪/激活装置
   - `ActiveChallenge(...)`

2. `EVENT_CHALLENGE_SUCCESS`：
   - 开门/刷奖励 gadget
   - `AddQuestProgress(...)` 或设变量标记完成
   - 切换 suite（下一阶段）

3. `EVENT_CHALLENGE_FAIL`：
   - 清理当前波（`KillGroupEntity`）
   - 重置机关状态
   - `RefreshGroup` 回到初始 suite

伪代码示意（强调结构，不强调具体 API 名字）：

```lua
function on_start(context)
  init_vars()
  spawn_wave(1)
  ScriptLib.ActiveChallenge(context, 1, CHALLENGE_CFG_ID, 60, group_id, 10, 0)
end

function on_success(context, evt)
  open_gate()
  give_reward()
  ScriptLib.GoToGroupSuite(context, group_id, 2)
end

function on_fail(context, evt)
  cleanup()
  ScriptLib.RefreshGroup(context, {group_id=group_id, suite=1})
end
```

这套模板的价值在于：**只要你保证“刷怪 group / gadget cfg / 触发器 tag”这些 data 引用正确**，挑战的核心目标检查由 Java 负责。

---

## 5. Gallery：Common 活动脚本最爱用、但本仓库缺失的“计分/结算器”

### 5.1 Lua 侧的典型用法长什么样？

你会在大量 `Common/*.lua` 或活动 group 脚本中看到：

- `ScriptLib.StartGallery(context, gallery_id)`
- `ScriptLib.StopGallery(context, gallery_id, is_succ)`
- `ScriptLib.UpdatePlayerGalleryScore(context, gallery_id, {...})`
- `ScriptLib.InitGalleryProgressScore / AddGalleryProgressScore / GetGalleryProgressScore ...`
- 以及事件触发器：`EVENT_GALLERY_START` / `EVENT_GALLERY_STOP`

这类脚本把 Gallery 当作：
> “一个可命名的计分板（带 UI），我往里塞分数/状态，最后让它结算并推送奖励/结果。”

例如 `resources/Scripts/Common/FleurFair_Parachute.lua` 会注册 `EVENT_GALLERY_START/STOP`，并在流程中调用 `StartGallery/StopGallery/UpdatePlayerGalleryScore`。

### 5.2 本仓库现状：接口大多未实现

在 `ScriptLib.java` 中：

- `StartGallery` / `StopGallery` / `UpdatePlayerGalleryScore` 都是 `unimplemented`
- 大量 Gallery 相关方法是 `TODO`（在 `analysis/14-scriptlib-api-coverage.md` 已统计过热点）

因此你会看到两类现象：
1. Lua 逻辑“看起来完整”，但调用后只打日志，没有协议/状态变化 → 客户端无 UI/无结算。
2. 依赖 `EVENT_GALLERY_*` 的 trigger 不会触发（因为没有 gallery runtime 产生这些事件）。

### 5.3 作为玩法编排层的结论

- **你可以把 Gallery 当作“高级 UI+结算框架”的概念模型来理解与复用**（写新玩法时沿用同样的结构与字段命名），但在本仓库里它是引擎边界。
- 如果你的目标是“把 Common 模块跑起来”，Gallery 往往是必须补的那一层：  
  不只是补 `ScriptLib.StartGallery`，还要补：
  - Gallery 的生命周期/状态机
  - 各种 Gallery 类型的协议通知与结算包
  - 多人同步与计分更新

---

## 6. ScenePlay / MultistagePlay：更上层的“活动编排框架”（同样属于边界）

### 6.1 Lua 侧会出现哪些 API？

在 `ScriptLib.java` 里可看到大量 `TODO`：

- `InitSceneMultistagePlay`
- `StartSceneMultiStagePlayStage` / `EndSceneMultiStagePlayStage`
- `PrestartScenePlayBattle` / `AddScenePlayBattleProgress` / `FailScenePlayBattle`
- `SetScenePlayBattleUidValue` / `GetScenePlayBattleUidValue` 等

这些接口通常对应“一个活动的多阶段流程 + 每阶段一套规则/计分/队伍控制”。

### 6.2 本仓库中少数已实现：`ScenePlaySound`

`ScenePlaySound`（`ScriptLib.java`）会广播 `PacketScenePlayerSoundNotify`，用于活动过程中的音效提示。  
这说明 ScenePlay 体系在协议层有一些基础设施，但玩法核心（多阶段状态机、结算等）仍缺失。

---

## 7. 给“想写新玩法的人”的实践建议（在当前仓库能力约束下）

如果你希望“尽量不改 Java”，我建议把目标分成两档：

### A 档：只用 Challenge（可落地）

适合：
- 世界挑战/战斗挑战/小型试炼
- 副本内“通关条件就是挑战成功”
- 需要稳定触发 `EVENT_CHALLENGE_SUCCESS/FAIL`

你需要准备的数据与脚本：
- `Group`（`resources/Scripts/Scene/.../scene*_group*.lua`）：monsters/gadgets/triggers/suites
- `DungeonChallengeConfigData`：选一个已实现类型对应的 `challengeIndex`
- Lua 逻辑：用 `ActiveChallenge` 启动；用事件回调编排

### B 档：复用活动 Common（需要补引擎）

适合：
- 强依赖 Gallery UI/计分/结算的活动
- 强依赖 MultistagePlay/ScenePlay 的多阶段活动

你需要的不是“改一点 Lua”，而是：
- 补 `ScriptLib` 缺失 API（并匹配脚本期待的参数结构）
- 补 Gallery/ScenePlay 的服务端状态机与协议推送
- 补事件发射（例如 `EVENT_GALLERY_START` 的触发时机）

---

## 8. 快速排障清单（Challenge/Gallery/ScenePlay）

### Challenge 相关

- `ActiveChallenge: tried to create challenge while one is already in progress`
  - 场景里已有挑战未结束；检查是否缺少 `EVENT_CHALLENGE_*` 的收敛逻辑，或缺少失败路径。
- `EVENT_CHALLENGE_SUCCESS` 不触发
  - 目标触发器是否正确（杀怪是否在对应 group、守护 gadget cfgId 是否匹配、triggerTag 是否匹配）？
  - 触发器 `source` 是否与 `ActiveChallenge` 第一参一致？

### Gallery/ScenePlay 相关

- 日志出现 `[LUA] Call unimplemented StartGallery/StopGallery/UpdatePlayerGalleryScore`
  - 这是“引擎能力缺失”的信号，不是脚本写错。
- `EVENT_GALLERY_START/STOP` 永远不触发
  - 需要 Gallery runtime 在 Java 侧发事件；纯 Lua 侧无法凭空产生。

