# 14 ScriptLib 覆盖度专题：Common/活动脚本“能不能跑”的第一性判断

本文把 `ScriptLib` 当成脚本层的“系统调用表（Syscall Table）”来理解：  
Lua 编排层能做什么，本质取决于 `ScriptLib.java` 里 **哪些 API 已实现、哪些是 stub、哪些根本不存在**。

为什么这篇必须写？因为 `resources/Scripts/Common/`（大量 Vx_y 活动/小游戏模块）几乎都假定“官方服务器 API 完整可用”。而 Grasscutter 的现实是：  
**你看到一个模块，不等于它能跑。**

与其他章节关系：

- `analysis/11-activities-deep-dive.md`：Common 模块范式；本文补足“可运行性审计”与覆盖矩阵。
- `analysis/04-extensibility-and-engine-boundaries.md`：缺 API 时“绕开脚本 vs 下潜引擎”的判断标准。
- `analysis/13-event-contracts-and-scriptargs.md`：事件系统契约；很多缺失集中在 gallery/challenge/SGV/跨系统同步上。

---

## 14.1 ScriptLib 在运行时扮演什么角色？

在 Grasscutter 中：

- `ScriptLib` 是注入到 Lua 全局的 Java 对象（`ScriptLoader.init()` 中 `ctx.globals.set("ScriptLib", ...)`）
- 触发器函数 `action_*/condition_*` 的 `context` 参数，本质上就是 `ScriptLib`（见 `analysis/02`）
- `ScriptLib` 内部通过 ThreadLocal 保存“当前 group/当前事件/当前 entity”（由 `SceneScriptManager.callEvent` 或 `EntityController` 设置）

因此：

- 同一个 Lua API 在不同上下文下语义不同（例如：group trigger vs gadget controller）
- 你写脚本时看到的 `ScriptLib.*(context, ...)`，最终都会落到 `ScriptLib.java` 的方法实现

---

## 14.2 三类“不可用”情况：missing / unimplemented / implemented-but-wrong

你做 Common 模块复用时，遇到脚本不工作，通常属于下面三类之一：

### A) API 根本不存在（missing）

表现：

- Lua 报错类似 “attempt to call field 'Xxx' (a nil value)”（在 LuaJ 的 Java userdata 语义下表现略有差异，但核心是“没这个方法”）

判定方法：

- `rg -n "public .* Xxx\\(" Grasscutter/src/main/java/emu/grasscutter/scripts/ScriptLib.java`
  - 找不到就是 missing（或命名不一致）

### B) API 存在但标注 `Call unimplemented`（stub）

表现：

- 脚本不报错，但没有效果
- 日志里会出现：`[LUA] Call unimplemented Xxx ...`

判定方法：

- 在 `ScriptLib.java` 搜索该方法体里是否 `logger.warn("[LUA] Call unimplemented ...")`

### C) API 存在但“实现不完整/语义偏差”

典型例子：

- `InitTimeAxis` 只使用了 delays[0]（不支持多段时间轴语义）
- `RefreshGroup` 被标注 “improperly implemented”（行为可能与官方不一致）
- 一些 “Call unchecked” 的函数：实现了，但返回值/参数语义不一定与脚本作者预期一致

这种最坑：它不报错，也可能“有点效果”，但活动逻辑会微妙地错。

---

## 14.3 最实用的工作流：对一个 Common 模块做 60 秒可用性审计

### 14.3.1 列出它调用了哪些 ScriptLib API

```bash
rg -n "ScriptLib\\." resources/Scripts/Common/V3_3/CoinCollect.lua
```

你得到的就是它的“系统调用清单”。

### 14.3.2 对照 ScriptLib.java 判定三色状态

对每个 API 名：

1) 是否存在同名 `public` 方法？
2) 如果存在：是否 `Call unimplemented`？
3) 如果不是 unimplemented：是否有 “unchecked / improperly implemented / TODO 语义” 注释？

### 14.3.3 决策：绕开还是下潜？

按 `analysis/04` 的标准：

- 玩法核心依赖缺失 API（gallery/SGV/跨系统）→ 多半要下潜 Java
- 缺的是可替代能力（临时变量/计数/提示）→ 多半可以改 Lua 绕开

---

## 14.4 用数据说话：Common 模块最常调用哪些 ScriptLib？

我对 `resources/Scripts/Common/` 做过一次简单统计（命令如下）：

```bash
rg -o --no-filename "ScriptLib\\.([A-Za-z0-9_]+)" resources/Scripts/Common \
  | sed 's/ScriptLib\\.//' | sort | uniq -c | sort -nr | head
```

高频前列大致是：

- `PrintContextLog`
- `GetGroupVariableValue` / `SetGroupVariableValue`
- `GetGroupTempValue` / `SetGroupTempValue`
- `InitTimeAxis` / `EndTimeAxis`
- `AddExtraGroupSuite` / `RemoveExtraGroupSuite`
- `SetGadgetStateByConfigId` / `SetGroupGadgetStateByConfigId`
- `CreateGadget` / `RemoveEntityByConfigId`
- `UpdatePlayerGalleryScore`（但它是 unimplemented）
- 以及大量 “在 ScriptLib 里只有 TODO 注释”的函数（例如 `ExecuteGroupLua`、`MarkGroupLuaAction` 等）

这直接给你一个“补齐优先级”：

> **只要 `GroupTempValue + TeamServerGlobalValue + ExecuteGroupLua + Gallery/Challenge` 这几块不补，Common 里大部分活动模块无法按原样运行。**

---

## 14.5 本仓库里最关键的“覆盖缺口”（建议优先关注）

下面列的是“在 Common 里调用频率很高，但在当前 ScriptLib 中缺失/不可用”的类别（对活动/小游戏影响最大）。

### 14.5.1 GroupTempValue（高频、目前 unimplemented + 还缺 Change）

现状（`ScriptLib.java`）：

- `GetGroupTempValue(...)`：`Call unimplemented`
- `SetGroupTempValue(...)`：`Call unimplemented`
- `ChangeGroupTempValue`：只有 TODO 注释（missing）

影响：

- 大量活动脚本把它当作“临时状态容器”（按 uid/key 存计数/状态）
- 缺失会导致玩法状态机失效（例如计数不变、状态不迁移）

建议：

- 如果你不想下潜 Java：在 Lua 层改为使用 `variables`（GroupVariable）替代 temp value
- 如果你要支持通用模块：这是优先级极高的引擎扩展点

### 14.5.2 TeamServerGlobalValue（SGV）（高频、目前 unimplemented）

现状：

- `SetTeamServerGlobalValue(...)`：`Call unimplemented`
- `GetTeamServerGlobalValue`：TODO（missing）

影响：

- Common 模块经常用 SGV 驱动客户端表现/能力（例如活动技能开关、仙灵状态、玩法 buff）
- 没 SGV，很多模块“逻辑上完成了，但客户端表现/能力不生效”

### 14.5.3 ExecuteGroupLua / MarkGroupLuaAction（缺失，且 Common 使用量很大）

现状：

- `ExecuteGroupLua`：TODO（missing）
- `MarkGroupLuaAction`：TODO（missing）

影响：

- 很多官方活动模块通过 ExecuteGroupLua 触发“跨 group 的 Lua 执行”或“触发某个 group 的特定逻辑入口”
- MarkGroupLuaAction 常用于埋点/状态上报/统一行为标记（即使你不需要埋点，也可能被脚本当作流程必需节点）

### 14.5.4 Gallery 系列（大量 TODO / unimplemented）

你会经常看到：

- `IsGalleryStart`（TODO）
- `SetPlayerStartGallery`（TODO）
- `StopGallery`（是否实现需逐个核对；Common 里调用很多）
- `UpdatePlayerGalleryScore`（unimplemented）

影响：

- 活动/小游戏常把 gallery 当作“会话”（计时/计分/UI/结算）
- gallery 缺失时，玩法可勉强用变量/计时器跑，但 UI/结算常断

### 14.5.5 时间轴 API 不完整（Pause/Resume 缺失，多段 delay 语义缺失）

现状：

- `InitTimeAxis`：实现了，但只支持单一 delay（取 `delays[0]`）
- `EndTimeAxis`：实现了
- `PauseTimeAxis/ResumeTimeAxis`：TODO（missing）

影响：

- 很多 Common 模块用多段 delay（例如 `{1,2,3}` 分段）或 Pause/Resume 控制轮询
- 你可能需要改 Lua 或扩展 Java 才能完整支持

### 14.5.6 一些“看起来很小但很致命”的缺失

例如：

- `GetGadgetConfigId`：TODO（missing），但 Common 与 Gadget controller 中不少脚本会用
- `GetSceneOwnerUid`：TODO（missing），很多多人/主机判断依赖它
- `SetPlayerGroupVisionType` / `AddPlayerGroupVisionType`：存在但 unimplemented/unchecked，影响多人视野玩法

---

## 14.6 你可以把 ScriptLib 分成 4 个“可靠度等级”

### Level 1：稳定可依赖（建议优先用它们做自制玩法）

典型例子（以当前仓库实现为准，非穷举）：

- group variable：`GetGroupVariableValue* / SetGroupVariableValue* / ChangeGroupVariableValue`
- suite 编排：`AddExtraGroupSuite / RemoveExtraGroupSuite / RefreshGroupSuite(...)`（注意 `RefreshGroup` 的实现质量见下）
- 实体：`CreateGadget / CreateMonster / RemoveEntityByConfigId / KillEntityByConfigId`
- gadget 状态：`SetGadgetStateByConfigId / SetGroupGadgetStateByConfigId / GetGadgetStateByConfigId`
- time axis：`InitTimeAxis / EndTimeAxis`（但不保证官方语义完整）

这些足够你做很多“关卡式玩法”（解谜/挑战房/遭遇战）。

### Level 2：实现了但标注 unchecked（要测试）

例如：

- `GetSceneUidList`、`GetServerTime` 等

策略：

- 把它当“可能对，但别当 ABI 保证”
- 做活动前先写一个小 group 打日志验证返回值

### Level 3：有实现但标注不完整（要谨慎依赖）

最典型：

- `RefreshGroup`：方法体内直接写了 “improperly implemented”

策略：

- 优先用 `RefreshGroupSuite` / `AddExtraGroupSuite` 等更明确的 API
- 真的要用 RefreshGroup 时，用小范围玩法先验证副作用（变量重置、实体清理等）

### Level 4：unimplemented 或 missing（不要指望它）

这类就是你在 Common 模块里最常踩的坑来源（见 14.5）。

---

## 14.7 给“想让 Common 活动大量可用”的人：补齐优先级建议

如果你的目标是“最大化复用 Common/Vx_y 模块”，经验上优先补这几类（从通用性与调用频率综合考虑）：

1) `Get/Set/ChangeGroupTempValue`
2) `Set/GetTeamServerGlobalValue`（SGV）
3) `ExecuteGroupLua` / `MarkGroupLuaAction`
4) Gallery 基础：`IsGalleryStart` / `SetPlayerStartGallery` / `StopGallery` / `UpdatePlayerGalleryScore`
5) TimeAxis 完整语义：多段 delays + Pause/Resume

补齐后再去追“更冷门”的活动 API（各种 chess/mechanicus/rogue 玩法）。

---

## 14.8 小结：把 ScriptLib 当“引擎边界表”

当你把 Grasscutter 当作 ARPG 引擎研究时，`ScriptLib` 就是最清晰的引擎边界：

- 它定义了脚本层能做的动作空间
- 它决定了 Common 模块库的可复用范围
- 它也是你最推荐的“按需下潜点”（只在缺口处补 Java，而不是全盘改引擎）

换句话说：

> 未来你写新玩法时，先问自己：“我需要的动作是否在 ScriptLib 已实现？”  
> 这比任何“猜测能不能做”都可靠。

---

## Revision Notes

- 2026-01-31：创建本文档（ScriptLib 覆盖度专题初版）。

