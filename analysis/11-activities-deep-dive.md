# 11 活动/小游戏专题：Common/Vx_y 模块范式（注入式玩法组件库）

本文是对 `analysis/02-lua-runtime-model.md` 中 Common 模块的专题扩展，目标是把 `resources/Scripts/Common/` 当成一套 **“玩法组件库（Gameplay Component Library）”** 来研究：  
你不是在“写一个个 group 脚本”，而是在用 **group 脚本当实例配置（Instance Config）**，用 **Common 模块当可复用玩法逻辑（Reusable Behavior）**。

与其他章节关系：

- `analysis/02-lua-runtime-model.md`：Lua require、Trigger/Condition/Action、ScriptLib API 覆盖度判断方法。
- `analysis/04-extensibility-and-engine-boundaries.md`：Common 模块常依赖未实现 ScriptLib；如何判断要不要下潜引擎层。
- `analysis/10-quests-deep-dive.md`：很多活动/小游戏会用 `EVENT_QUEST_START/FINISH` 或 `QUEST_CONTENT_LUA_NOTIFY` 做阶段驱动。

---

## 11.1 Common/Vx_y 的定位：把“玩法逻辑”做成可复用模块

在本工作区里，最典型的“活动/小游戏”写法不是把逻辑写进每个 `sceneX_groupY.lua`，而是：

1) group 脚本只负责：
   - `base_info/defs/defs_miscs`
   - gadgets/regions/suites 的“素材与实例参数”
2) `require "Vx_y/SomeModule"`（或 `BlackBoxPlay/SomePuzzle`）
3) 模块在加载时把 triggers/variables（甚至 suites）**注入**到 group 的全局表里
4) 运行时由事件系统驱动模块内的 `condition_*/action_*` 或模块自定义函数

这是一种非常“引擎编排层”的设计：  
**Common 模块 ≈ 玩法 DSL 的标准库；group 脚本 ≈ DSL 的实例化配置。**

---

## 11.2 require 与“注入式模块”的本质：同一脚本环境里的表改写

### 11.2.1 require 的路径约定（Common 根）

在 group 脚本里常见：

```lua
require "V3_3/CoinCollect"
```

在 Grasscutter 中它会被解析到磁盘：

- `resources/Scripts/Common/V3_3/CoinCollect.lua`

（细节见 `analysis/02-lua-runtime-model.md` 的 require 小节）

### 11.2.2 “注入式模块”为什么能工作？

因为模块在 `require` 时执行，它能直接读写 group 脚本里已经定义好的全局表：

- `triggers / suites / variables / gadgets / regions`
- 以及“参数表”：`base_info / defs / defs_miscs`

于是模块可以做类似“宏注入”的事：

```lua
-- 在模块里：
table.insert(triggers, extraTriggers[i])
table.insert(suites[1].triggers, extraTriggers[i].name)
table.insert(variables, extraVariables[i])
```

最终效果：**group 脚本的结构被模块“补全”**，运行时引擎看到的是合并后的 triggers/suites/variables。

### 11.2.3 这套范式带来的“工程化收益”

- 复用：一套活动逻辑可以被 N 个 group 实例复用（不同地图点位/不同 gadget 配置）
- 参数化：玩法差异通过 `defs/defs_miscs` 控制，而不是复制粘贴代码
- 分层：group 脚本更像“关卡 prefab”，模块更像“行为组件”

代价也很明显：

- 模块对 group 的表结构有强假设（表是 map 还是 array？suite[1] 是否存在？）
- 模块依赖的 ScriptLib API 若缺失，就会“跑不起来”（下文会给审计方法）

---

## 11.3 Common/Vx_y 模块的“标准接口契约”（你写/改模块时必须对齐）

把常见模块需要的输入按重要性分层：

### 11.3.1 必须存在的全局对象（几乎所有模块都会用）

- `base_info = { group_id = ... }`
- `triggers = { ... }`
- `suites = { ... }`
- `init_config = { suite = 1, ... }`（部分模块用 `init_config.suite`）

### 11.3.2 高频参数表：`defs` 与 `defs_miscs`

典型约定：

- `defs`：标量/少量字段（时长、挑战 ID、关键 region config_id、galleryId…）
- `defs_miscs`：复杂结构（映射表、列表、分组关系、关卡图结构…）

例子：`resources/Scripts/Common/V3_3/CoinCollect.lua` 头部注释就给了 `defs/defs_miscs` 的模板。

### 11.3.3 配置表形状（这是最容易踩坑的点）

不同 group 脚本生成器会让 `gadgets/regions` 变成两种形态：

1) **map 形式**（Key 为 config_id）
   - `gadgets = { [94001] = {config_id=94001,...}, ... }`
2) **array 形式**（顺序数组）
   - `gadgets = { {config_id=94001,...}, {config_id=94002,...}, ... }`

模块往往假设其中一种。

例如 `CoinCollect` 会写：

```lua
gadgets[v[j]]["specialCoin"] = i
```

这要求 `gadgets` 是 map，且能用 `gadgets[config_id]` 直接取到 gadget 表。

> 实务建议：你在“复用某个模块”前，先看它如何访问 `gadgets/regions/suites`，再决定你的 group 配置该用 map 还是 array。

---

## 11.4 事件系统视角：模块在吃哪些 EventType？

Common/Vx_y 模块本质是“事件驱动的状态机”。它们最常用事件可以按用途归类：

| 事件 | 常见用途 |
|---|---|
| `EVENT_GROUP_LOAD` | 初始化/恢复状态、补 spawn、启动 time axis |
| `EVENT_ENTER_REGION` / `EVENT_LEAVE_REGION` | 开始/结束玩法区域、断线重连恢复、离开判失败 |
| `EVENT_GADGET_CREATE` / `EVENT_GADGET_STATE_CHANGE` | 交互台、机关状态推进 |
| `EVENT_SELECT_OPTION` | worktop 选项驱动（开始、重置、进入编辑模式…） |
| `EVENT_VARIABLE_CHANGE` | 用 group variable 做 FSM 的“状态迁移边” |
| `EVENT_TIME_AXIS_PASS` / `EVENT_TIMER_EVENT` | 计时器驱动（分段、提示、节奏控制、CD） |
| `EVENT_CHALLENGE_SUCCESS/FAIL` | 挑战结算（常与 gallery/UI 绑定） |
| `EVENT_GALLERY_START/STOP` | 玩法会话开始/结束（客户端 UI/计分） |
| `EVENT_GROUP_WILL_UNLOAD` | 保底清理（很多活动会先卸载 group 再结束 gallery） |
| `EVENT_QUEST_START/FINISH` | 用任务阶段驱动活动流程（见 `analysis/10`） |
| `EVENT_CUSTOM_DUNGEON_*` | UGC/定制地城的特殊事件流（UGCDungeon） |

你可以把模块写成：

```
事件 (EventType) → 读变量/读状态 → 写变量/切 suite/刷实体/发 UI → 下一事件…
```

---

## 11.5 “注入式模块”的核心结构模板（可复用写法）

把最常见模式抽象成模板：

```lua
-- Common/Vx_y/MyModule.lua
local extraTriggers = {
  { config_id = 9000001, name = "GROUP_LOAD", event = EventType.EVENT_GROUP_LOAD, action = "action_group_load" },
  { config_id = 9000002, name = "ENTER_REGION", event = EventType.EVENT_ENTER_REGION, action = "action_enter_region" },
}

local extraVariables = {
  { config_id = 9000101, name = "stage", value = 0, no_refresh = false },
}

local function LF_Initialize_Group(triggers, suites, variables)
  for _, t in ipairs(extraTriggers) do
    table.insert(triggers, t)
    table.insert(suites[1].triggers, t.name) -- 或 suites[init_config.suite]
  end
  for _, v in ipairs(extraVariables) do
    table.insert(variables, v)
  end
end

function action_group_load(context, evt)
  -- 读 defs/base_info，初始化 gadget/变量
  return 0
end

function action_enter_region(context, evt)
  -- 开始玩法：开计时器/切 suite/开始 gallery
  return 0
end

LF_Initialize_Group(triggers, suites, variables)
```

group 侧只需要：

```lua
local base_info = { group_id = 123 }
local defs = { ... }
local defs_miscs = { ... }
-- 配 gadgets/regions/suites
require "Vx_y/MyModule"
```

这就是 Common 模块范式的“最小可用骨架”。

---

## 11.6 代表性模块拆解（从“范式”到“可落地理解”）

下面用 4 个样本覆盖不同复杂度：  
（你未来遇到新模块时，可以把它归类到其中一种“玩法形态”。）

### 11.6.1 样本 A：`V3_3/CoinCollect.lua`（限时收集类：Gallery + TimeAxis + 变量计数）

文件：`resources/Scripts/Common/V3_3/CoinCollect.lua`  
引用它的 group 示例：`resources/Scripts/Scene/1/scene1_group111102094.lua`

#### A1) 输入接口（它依赖 group 侧提供什么）

- `defs`（示例字段）：
  - `hintTime/coinTime/totalTime/skillDuration/galleryId/maxRegion...`
- `defs_miscs.specialCoinTable`：
  - `specialCoinConfigId -> { coinConfigId1, coinConfigId2, ... }`
- `gadgets`：必须是 map（用 `gadgets[config_id]` 直接访问）
- `regions`：至少包含玩法范围 region（例如 `defs.maxRegion`）

#### A2) 注入内容（extraTriggers / extraVariables）

它会注入一批 trigger（节选）：

- `GROUP_LOAD`
- `ENTER_REGION` / `LEAVE_REGION`
- `TIME_AXIS_PASS`
- `VARIABLE_CHANGE`
- `GALLERY_START`
- `GROUP_WILL_UNLOAD`
- `SCENE_MP_PLAY_ALL_AVATAR_DIE`

以及变量（节选）：

- `final`（结算/终态）
- `collectedCoins`（计数）
- `levelStart`（开局标记）

并且会在初始化时“改写 gadgets 表”，给某些 coin gadget 附加字段：

- `gadgets[coinConfigId].specialCoin = <specialCoinConfigId>`

#### A3) 运行模型（把它当状态机读）

用“阶段/事件”视角描述更清晰：

1) **GROUP_LOAD**：恢复/初始化
2) **ENTER_REGION**：进入玩法区域 → 启动玩法（开始计时、可能开始 gallery）
3) **TIME_AXIS_PASS**：定时 tick（提示金币光柱、技能 CD/持续）
4) **VARIABLE_CHANGE**：收集计数变化 → 判断是否完成/结算
5) **LEAVE_REGION / MP_ALL_PLAYER_DIE / GROUP_WILL_UNLOAD**：兜底终止与清理

它文件里有一句非常关键的注释（原文语义）：

- 动态 group 卸载可能发生在 gallery 结束之前，所以不能只依赖 `EVENT_GALLERY_STOP`，要在 `GROUP_WILL_UNLOAD` 兜底。

这反映了“编排层必须适配引擎的生命周期现实”：  
**玩法会话（gallery）生命周期 ≠ group 生命周期**。

#### A4) 你复用/魔改时最容易踩的坑

1) `gadgets` 必须是 map（否则 `gadgets[configId]` 直接崩）
2) 它使用了大量 ScriptLib 接口（包括 SGV、temp value、gallery 相关），而在本仓库的 `ScriptLib.java` 里：
   - `SetTeamServerGlobalValue` 是 `unimplemented`
   - `GetGroupTempValue/SetGroupTempValue` 是 `unimplemented`
   - `IsGalleryStart` 等也可能是 `TODO`

因此你需要把它当成两层：

- **玩法设计范式**：可以直接学习与迁移
- **本引擎可运行性**：要先做 API 覆盖度审计（见 11.7）

---

### 11.6.2 样本 B：`BlackBoxPlay/MagneticGear.lua`（解谜类：TimeAxis 轮询 + 成功持久化 + suite 解锁）

文件：`resources/Scripts/Common/BlackBoxPlay/MagneticGear.lua`

#### B1) 典型结构特征

- 注入 triggers：
  - `GROUP_LOAD`
  - `TIME_AXIS_PASS`（source = `"checkSuccess"`）
- 注入持久变量：
  - `successed`（`no_refresh = true`）

#### B2) 运行模型（可迁移的“解谜模块”套路）

它展示了一个非常通用的解谜写法：

1) **GROUP_LOAD**：
   - 如果 `successed != 1`：启动循环 time axis（每秒检查一次）
   - 如果已成功：直接加载奖励 suite，并恢复机关状态/重建 gadget

2) **TIME_AXIS_PASS**：
   - 读取机关角度（rotation y）
   - 判断是否都对齐（误差阈值来自 `defs.minDiscrapancy`）
   - 全满足则：
     - `AddExtraGroupSuite(..., 2)` 解锁奖励/表现
     - `PauseTimeAxis("checkSuccess")`
     - `SetGroupVariableValue("successed", 1)` 持久化成功

这种模式的抽象是：

```
轮询检查（TimeAxis）→ 满足条件 → 切 suite + 写持久变量 → 停止轮询
重进场景（GroupLoad）→ 读持久变量 → 恢复到已完成形态
```

你把它当成“解谜组件”的通用模板就对了。

---

### 11.6.3 样本 C：`V2_5/UGCDungeon.lua`（大型活动：内置状态机 + 自定义地城事件流）

文件：`resources/Scripts/Common/V2_5/UGCDungeon.lua`  
引用它的 group 示例：`resources/Scripts/Scene/45058/scene45058_group245058002.lua`（该 group 同时也在用 Quest 事件）

#### C1) 为什么它代表“另一种复杂度层级”

UGCDungeon 不再是“一个小解谜”，而更像一个 **玩法模式运行时（Game Mode Runtime）**：

- 它定义了多组枚举/状态：
  - `DUNGEON_STATE`（NONE/TESTING/PLAYING/EDITING/OUT_STUCK…）
  - `DUNGEON_MODE`（EDIT_MODE/PLAY_MODE）
  - `PLAYER_STATE`（NORMAL/IMMUNE）
- 它监听大量事件：
  - `CUSTOM_DUNGEON_START / EXIT_TRY / OFFICIAL_RESTART / OUT_STUCK / REACTIVE / RESTART`
  - `CHALLENGE_SUCCESS/FAIL`
  - `QUEST_FINISH`（作为引导任务完成信号）
  - `ENTER/LEAVE_REGION`（断线重连/弱网拦截）
  - `SELECT_OPTION`（开始/编辑台）

它就是一个“用 group script 写出来的迷你引擎”。

#### C2) 注入方式（与 LF_Initialize_Group 同构）

它用的是 `UGC_Initialize()`：

- 遍历 `UGC_Triggers`，插入到 group 的 `triggers`
- 并把 trigger 名字插入 `suites[1].triggers`

这与 CoinCollect/TreasureSeelie 的注入模式同构，只是命名不同。

#### C3) 与 Quest 的联动点（活动常用套路）

UGCDungeon 有一个非常典型的“活动引导”做法：

- 监听 `EVENT_QUEST_FINISH`
- 用某个 subQuestId 表示“引导完成”
- 完成后开启 worktop 选项、创建起点 gadget、移除引导实体等

这说明：

**活动/小游戏经常把 Quest 当作“阶段门（Gate）/教学流程（Tutorial Flow）”。**  
Quest 负责叙事与阶段推进，活动模块负责玩法运行细节。

---

### 11.6.4 样本 D：`V3_0/Activity_TreasureSeelie.lua`（多阶段探索：进度持久化 + suite 分段加载）

文件：`resources/Scripts/Common/V3_0/Activity_TreasureSeelie.lua`

#### D1) 注入变量非常“编排层味”

它注入了大量变量（节选）：

- `current_challenge_stage`
- `stage_progress1/2/3`（`no_refresh = true`：跨刷新持久）
- `stage_counter`（总进度）
- `seelie_out`（仙灵离体）
- `element_used`（元素微粒使用计数）

这是一种很典型的活动写法：

> 用变量表达“剧情/探索阶段”，用 suite 表达“当前要加载的实体集合”，用 triggers 表达“阶段转换条件”。

#### D2) suite 的使用方式：按阶段 add/remove

它会在重置时：

- 移除额外 suites（`RemoveExtraGroupSuite`）
- `RefreshGroup(..., suite=1)` 回到初始

在达成某阶段时：

- `AddExtraGroupSuite` 加载宝箱/挖掘点等内容

这种“suite 分段加载”是活动模块的核心技法之一：  
**不用动态 group，也能通过 suite 做阶段化内容管理。**

#### D3) 依赖提醒：gallery/ability/SGV

它会调用如：

- `ScriptLib.IsGalleryStart(...)`（在本仓库 ScriptLib 中是 `TODO`）
- `ScriptLib.SetTeamServerGlobalValue(...)`（`unimplemented`）
- `ScriptLib.GetTeamAbilityFloatValue(...)`（是否实现需核对）

所以同样需要做 API 覆盖度审计。

---

## 11.7 模块可运行性审计：如何快速判断“这个 Common 模块在本引擎能不能跑”

由于 Grasscutter 的 `ScriptLib.java` 有不少 `TODO/unimplemented`，你复用模块前建议固定做一次审计：

### 11.7.1 第一步：列出模块调用的 ScriptLib API 清单

示例（CoinCollect）：

```bash
rg -n "ScriptLib\\." resources/Scripts/Common/V3_3/CoinCollect.lua
```

### 11.7.2 第二步：对照 `ScriptLib.java` 看是否实现

```bash
rg -n "public (int|boolean) <ApiName>\\(" Grasscutter/src/main/java/emu/grasscutter/scripts/ScriptLib.java
```

你会经常遇到两类信号：

- `logger.warn("[LUA] Call unimplemented ...")`：基本等于“现在跑不通”
- `TODO:`：代表行为未补齐或语义不完整（例如 time axis 多段延迟、gallery 系列接口）

### 11.7.3 第三步：决定策略（不下潜 vs 下潜）

按 `analysis/04-extensibility-and-engine-boundaries.md` 的判断标准：

- 如果缺的是“可替代能力”（比如用 group variable + time axis 就能替代 temp value）  
  → 改 Lua 绕开
- 如果缺的是“活动系统关键契约”（gallery/SGV/自定义地城事件）  
  → 你需要补 Java（或选择别的模块/简化玩法）

---

## 11.8 自己写一个 Vx_y 模块：建议的工程化规范

为了让你未来把它当“通用 ARPG 引擎脚本层”使用，建议你按下面的规范写新模块：

### 11.8.1 把模块当“组件”，把 `defs/defs_miscs` 当“组件输入”

建议约定：

- `defs`：只放标量（id、时长、阈值、关键 config_id）
- `defs_miscs`：放结构（映射、列表、房间图、分组）
- 不要在模块里硬编码 `group_id`（用 `base_info.group_id`）

### 11.8.2 注入时只做三件事（越少越稳）

1) 注入 triggers（并把名字挂到某个 suite 的 triggers 列表）
2) 注入 variables（并明确哪些要 `no_refresh=true`）
3) 预处理配置表（例如把 gadgets 分类、构建索引表）

不要在初始化阶段做“强副作用”（大量 Create/Remove），尽量放到 `GROUP_LOAD` 或明确的启动事件里做。

### 11.8.3 把玩法写成 FSM：变量驱动阶段迁移

建议你明确一个主状态变量：

- `stage`（0=未开始，1=进行中，2=成功，3=失败）

所有 action 都围绕它做：

- 进入区域若 stage==0 → stage=1 → start
- 收集完成若 stage==1 → stage=2 → success
- 超时/离开若 stage==1 → stage=3 → fail

这样你的玩法能天然支持：

- group refresh
- 重进场景恢复（取决于 no_refresh）
- debug（打印 stage 就知道卡在哪）

---

## 11.9 小结：Common/Vx_y 是“编排层标准库”，但需要正视引擎 API 边界

Common/Vx_y 模块范式的核心价值不在“某个活动的具体细节”，而在它提供了一套可迁移的脚本层设计：

- group 作为实例配置、模块作为可复用行为
- triggers/variables/suites 作为 DSL 的三大支柱
- time axis / variable change 作为脚本层时间与状态机工具
- Quest 作为活动阶段门与叙事编排

同时你也必须建立一个现实判断：

- **玩法范式可以直接迁移**
- **具体模块能不能直接跑，取决于 ScriptLib 覆盖度（以及客户端是否有对应表现/协议）**

掌握“范式 + 审计方法”，你就能把这套脚本层当成通用 ARPG 引擎编排层来用，而不是被某个私服工程的实现细节绑死。

---

## Revision Notes

- 2026-01-31：创建本文档（活动/小游戏 Common 模块专题初版）。  

