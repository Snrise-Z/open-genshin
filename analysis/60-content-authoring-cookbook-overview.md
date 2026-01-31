# 60 内容制作 Cookbook：总工作流、ID 规划与调试方法

本文是“内容制作 Cookbook”系列的总入口：把本仓库当作一套 ARPG 引擎的**玩法编排层（Lua + 配表/资源）**来使用时，你如何从 0 开始制作一个可玩的内容（Encounter/机关/小活动/任务片段），以及如何把它做成“可维护的内容包”而不是一次性魔改。

与其他章节关系（建议配合阅读）：

- `analysis/12-scene-and-group-lifecycle.md`：Group/Suite 的加载卸载、动态 group、持久化边界（内容制作的“运行时容器”）。
- `analysis/36-resource-layering-and-overrides.md`：`resources/Server` 覆盖层与 Mapping glue（内容制作的“工程化落点”）。
- `analysis/14-scriptlib-api-coverage.md`：ScriptLib 覆盖度（决定某个玩法模块能不能跑）。
- `analysis/10-quests-deep-dive.md`、`analysis/27-quest-conditions-and-execs-matrix.md`：当你需要“剧情/阶段机”时，Quest DSL 是最强的驱动器。
- `analysis/11-activities-deep-dive.md`：当你要复用现成活动/小游戏逻辑时，Common/Vx_y 模块范式是主要路径。
- `analysis/54-gm-handbook-and-admin-actions.md`：调试/测试的控制面（传送、刷怪、发物品）。

---

## 60.0 本 Cookbook 系列目录（建议按这个顺序做）

- `analysis/61-cookbook-new-group-encounter.md`：最小可玩内容（Worktop → 刷怪 → 清怪 → 宝箱）。
- `analysis/62-cookbook-timed-challenge-and-waves.md`：限时挑战 + 波次（成功/失败收尾、两种波次实现）。
- `analysis/63-cookbook-region-driven-fsm.md`：区域触发链（Enter/Leave Region → 阶段机 → 重置）。
- `analysis/64-cookbook-gadget-puzzle-and-chest.md`：机关解谜（GadgetState/变量/计时 → 宝箱）。
- `analysis/65-cookbook-quest-driven-dynamic-groups.md`：任务驱动动态 group（QuestExec 注册/卸载 + LuaNotify 推进）。
- `analysis/66-cookbook-dialogue-and-interaction-quest.md`：对白/交互轻量任务（CompleteTalk vs SelectOption+LuaNotify）。
- `analysis/67-cookbook-reward-drop-and-loot.md`：奖励/掉落制作（DropTable/drop_tag、宝箱/怪物、多人与归属）。
- `analysis/68-cookbook-reusing-common-vx-modules.md`：复用 Common/Vx_y 模块（注入式实例化、fastRequire 约束、审计方法）。
- `analysis/69-cookbook-dungeon-and-instanced-content.md`：副本/实例内容（/dungeon 进入 → Challenge 驱动通关 → DungeonSettle 收尾）。

---

## 60.1 先统一口径：你制作的“内容”在引擎里是什么？

在本仓库的脚本/数据层里，绝大多数可做的玩法内容都可以落到以下抽象：

- **Scene（场景）**：世界/副本的“容器”。
- **Group（玩法最小编排单元）**：一个房间/一段遭遇战/一个解谜/一个小活动实例。
- **Suite（阶段/组装件集合）**：Group 内“第 1 阶段/第 2 阶段”的素材集合（monsters/gadgets/regions/triggers 的子集）。
- **Trigger（事件→条件→动作）**：把运行时事件映射到 Lua 逻辑。
- **Quest（数据驱动状态机）**：当你需要“可存档的流程/阶段/叙事驱动”时，用它做上层编排。
- **Common/Vx_y（可复用玩法组件库）**：当你需要“活动/小游戏模板”时，用它当标准库，group 脚本当实例配置。

Cookbook 的目标是：给你一套稳定的“落地配方”，让你能**只改脚本/数据**就能做出可玩的内容；并能判断哪些点必须下潜引擎层。

---

## 60.2 内容制作的“改动面”：你要动哪些目录？

把常见目标映射到“需要改的层”（优先级从轻到重）：

| 目标 | 优先改动 | 典型文件 |
|---|---|---|
| 做一个遭遇战/机关/小玩法（不走任务） | Scene/Group Lua | `resources/Scripts/Scene/<sceneId>/scene<sceneId>_group<groupId>.lua` + `scene<sceneId>_block*.lua` |
| 复用一个活动/小游戏模块 | Group Lua + Common 模块 | `resources/Scripts/Common/Vx_y/*.lua` + group 里的 `defs/defs_miscs` |
| 做“有阶段机/可存档”的流程 | Quest Excel +（可选）Group/脚本 | `resources/ExcelBinOutput/QuestExcelConfigData.json` + `resources/BinOutput/Quest/<mainId>.json` + Lua |
| 做“对白触发/对白完成推进” | Talk Excel（注意实现边界） | `resources/ExcelBinOutput/TalkExcelConfigData.json` |
| 想让某类 gadget 有通用实体行为 | GadgetMapping + Gadget 控制器脚本 | `resources/Server/GadgetMapping.json` + `resources/Scripts/Gadget/*.lua` |
| 调整掉落/奖励策略 | Server 覆盖层 | `resources/Server/DropTableExcelConfigData.json` 等 |
| 服务器策略参数（非官方表） | data/ | `data/*.json` |

> 实务原则：**尽量不要直接污染 `resources/ExcelBinOutput/` 基底**。能用 `resources/Server/` 覆盖就用覆盖（见 `analysis/36`）。  
> 但也要接受现实：Quest/Talk 这类巨大表目前是“整表加载”，你新增条目往往逃不过编辑原表或引入自己的构建/合并管线（本 cookbook 会给建议）。

---

## 60.3 ID 与命名空间：不规划就必踩坑

内容制作最大的问题不是“写不出 Lua”，而是：**ID 冲突、引用错行、持久化缓存污染、调试定位困难**。

### 60.3.1 Group/Config/Trigger 的 ID 策略

- `group_id`：全局唯一（至少在同一 scene 内必须唯一）。  
  建议策略：
  1) **跟随场景的既有前缀**：例如 scene 1 的 group 多为 `111101xxx/111102xxx`；你就挑同前缀递增一个没用过的尾号。  
  2) 或建立你自己的“自定义命名空间”：例如 `99<sceneId><序号>`（保证小于 2^31）。
- `config_id`：只需在 group 内唯一，但建议也分段规划：
  - gadget: `10xxx`
  - monster: `20xxx`
  - region: `30xxx`
  - trigger: `40xxx`（配合 name `EVENT_xxx_<configId>`）
- trigger `name`：建议统一生成规则：
  - `GROUP_LOAD` / `ENTER_REGION_<region>` / `SELECT_OPTION_<gadget>` / `ANY_MONSTER_DIE_<mark>` …
  - 这样你看 `TriggerExcelConfigData` / 日志时能直接反推对象。

### 60.3.2 Quest/Talk 与 “param_str key” 的命名策略

当你用任务系统做阶段机时，你会频繁用到两类“标识符”：

1) **数字 ID**：`mainId/subId/talkId`  
2) **字符串 key**：`QUEST_CONTENT_LUA_NOTIFY` 常用 `param_str=key`，由 `ScriptLib.AddQuestProgress(key)` 上报

建议做法：

- `mainId/subId`：预留一个大段区间只给自制内容，例如 `900000+`；并用表格记录占用情况。
- LuaNotify key：不要用“随便一个字符串”，用可检索、可分组、可复用的命名：
  - `CQ_<mainId>_<stage>`（Content Quest）
  - `EV_<groupId>_<event>`（Event）
  - 这样你在 `QuestExcelConfigData.json` 里全局搜索就能看到所有引用点。

### 60.3.3 建立你的 “ID Ledger”（强烈建议）

建议你在仓库外维护一个简单表格（或在 `analysis/` 之外建 `docs/ids.md` 也行）：

- 自制 group 列表：`sceneId/groupId/blockId/用途/坐标/是否 dynamic_load`
- 自制 quest 列表：`mainId/subId/key/关联 group`
- 自制 drop/reward：`drop_id/chest_drop_id/drop_tag/rewardId`

> 这件事看似“非技术”，但它决定你后续是否能规模化做内容。

---

## 60.4 最推荐的“从 0 到可玩”工作流（按成功率排序）

**路径 A（最稳）**：先做“无任务的 Group 玩法”，只用 Lua + 现成怪物/机关 ID。

1. 选一个你熟悉的 scene（大世界）与一个坐标点
2. 新建一个 group：`scene<sceneId>_group<groupId>.lua`
3. 把 group 挂到某个 block：`scene<sceneId>_block<blockId>.lua` 的 `groups = { ... }`
4. 用 Worktop 选项/进入区域触发 → 刷怪/切 suite → 结算/刷宝箱
5. 验证多人/重登/离开区域的行为是否符合预期（持久化与卸载边界）

**路径 B（可扩展）**：复用 Common/Vx_y 模块做活动/小游戏。

1. 先从 `resources/Scripts/Common/Vx_y/` 找到一个模块
2. 审计它用到的 ScriptLib（见 `analysis/14`），确认“能跑”
3. 用 group 脚本提供 `defs/defs_miscs` 与 gadget/region/suite 的“实例配置”
4. 让模块注入 triggers/variables 并由事件驱动运行

**路径 C（最强但成本最高）**：用 Quest 做上层阶段机，驱动动态 group。

1. 用 Quest Excel 定义 subQuest 的 Accept/Finish 条件
2. 用 Quest Exec 注册动态 group（`REGISTER_DYNAMIC_GROUP`）并用 `LUA_NOTIFY` 推进
3. 用 `UNREGISTER_DYNAMIC_GROUP` 清理，避免残留

---

## 60.5 迭代与热更新：为什么“我改了脚本但没生效”？

这是本仓库内容制作最容易卡住的点之一：

- Lua 脚本由 `ScriptLoader` 缓存（`scriptsCache/scriptSources`），**不会因为文件修改自动失效**。  
  结论：开发期最稳的方式是 **重启服务器** 来确保脚本生效。
- 即使你没改脚本，只改了 group 里的变量初值/套件内容，运行时的 `SceneGroupInstance` 也可能从 DB/缓存恢复旧状态（见 `analysis/26-entity-state-persistence.md`）。

建议的迭代策略（从轻到重）：

1) 只改“新增文件”，避免修改已缓存脚本（第一次加载一定生效）  
2) 实在要改同一文件：重启服务器  
3) 状态污染：换一个全新的 `group_id`（最快排除持久化影响）  
4) 需要清档：清理对应 group instance/玩家任务存档（代价最大）

---

## 60.6 调试工具箱（本仓库就地可用）

### 60.6.1 GM Handbook（HTTP 控制面）

见 `analysis/54-gm-handbook-and-admin-actions.md`。在内容制作中最常用的能力：

- Teleport：快速去到你布置的 sceneId（以及默认点）
- Spawn：刷怪测试战斗/触发器
- Give Item：发道具测试 ItemUse/奖励链路

### 60.6.2 命令行/聊天指令（特别适合任务调试）

本仓库内建 `/quest` 命令（`Grasscutter/.../QuestCommand.java`），常用：

- `/quest add <mainId>`：把主任务加入玩家（用于自制任务验证）
- `/quest finish <subId>`：强制完成某个子任务
- `/quest running <subId>`：查看子任务状态
- `/quest triggers <subId>`：看该子任务注册了哪些 trigger
- `/quest grouptriggers <groupId>`：打印 group 脚本里 triggers（用于确认 group 是否被加载）
- `/quest debug <mainId>`：切换该主任务的日志输出（便于看事件投递与条件命中）

> 提醒：这组命令对“自制任务”极其关键，因为你不一定能依赖客户端自然触发 Accept 条件。

### 60.6.3 Lua 侧日志与断点替代

- `ScriptLib.PrintContextLog(context, "...")`：最常用
- 统一加前缀：例如 `@@ MYMOD:`，便于在 `logs/` 里 grep

---

## 60.7 常见故障速查（按发生频率排序）

1. **Group 没加载**
   - 没把 group 写进 `scene*_block*.lua` 的 `groups` 列表
   - 或 `group_id` 与文件名不匹配（引擎按命名约定找）
   - 用 `/quest grouptriggers <groupId>` 快速验证是否加载
2. **触发器不触发**
   - event 类型选错（比如应该 `EVENT_SELECT_OPTION` 却写成别的）
   - `source` 填错导致筛选失败（见 `analysis/13`）
   - condition 里忘记校验 `evt.param1/param2` 或写错 config_id
3. **Worktop 选项不出现**
   - 没在 `GROUP_LOAD`/`GADGET_CREATE` 时调用 `SetWorktopOptionsByGroupId`
   - gadget 状态不对（某些 gadget 只有 Default 才可交互）
4. **怪没刷出来**
   - suite 没切/没 AddExtraGroupSuite
   - monster 的 `monster_id` 没有对应数据或 Mapping（见 `analysis/36`）
5. **宝箱/掉落不对**
   - `chest_drop_id/drop_id/drop_tag` 走了不同掉落栈（见 `analysis/51`）
6. **改了脚本没生效**
   - ScriptLoader 缓存，重启服务器（见 60.5）
7. **重登后状态异常**
   - group instance 持久化了变量/死亡记录（见 `analysis/26`）

---

## 60.8 小结

- 内容制作优先从 **Group（Lua）** 入手：可控、可迭代、对客户端依赖最小（复用现成资源 ID 即可）。
- 需要流程/存档/跨场景驱动时，引入 **Quest DSL**；需要快速复用玩法时，引入 **Common/Vx_y 模块**。
- 工程上务必掌握：`resources/Server` 覆盖层、Mapping glue、脚本缓存与持久化污染排障。

---

## Revision Notes

- 2026-01-31：首次撰写本 Cookbook 总览；给出内容制作的分层地图、ID 规划策略、推荐工作流与调试速查清单。
- 2026-01-31：补充本 Cookbook 系列目录（60→69 的导航），便于按难度/依赖递进阅读与实操。
