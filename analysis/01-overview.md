# 01 总览：脚本/数据层地图与心智架构图

本文记录“第一阶段：总览与地图构建”的结论：把本仓库里的 **Lua 脚本 + 配表/资源** 当成一套成熟 ARPG 引擎的“玩法编排层（Orchestration Layer）”来理解，而把 Java 代码当成“引擎层（Runtime/Core）”。  
后续章节关系：

- `analysis/02-lua-runtime-model.md`：Lua 的加载、上下文、事件系统、ScriptLib API。
- `analysis/03-data-model-and-linking.md`：ExcelBin/BinOutput/TextMap/Server 等数据模型与 ID 映射。
- `analysis/04-extensibility-and-engine-boundaries.md`：哪些能靠脚本/数据实现，哪些必须改引擎；以及抽象成通用 ARPG 模型。
- `analysis/10-quests-deep-dive.md`：任务系统专题（Quest/Talk/TriggerFire/LuaNotify/Exec 与 Lua/场景联动）。
- `analysis/11-activities-deep-dive.md`：活动/小游戏专题（Common/Vx_y 注入式模块范式与复用/审计方法）。
- `analysis/12-scene-and-group-lifecycle.md`：Scene/Block/Group/Suite 生命周期（加载/卸载/切 suite/持久化/动态 group）。
- `analysis/13-event-contracts-and-scriptargs.md`：事件 ABI（EventType→evt 参数语义、trigger 的 group/source 匹配规则）。
- `analysis/14-scriptlib-api-coverage.md`：ScriptLib 覆盖度与模块可运行性审计（缺口清单与优先级）。
- `analysis/15-gadget-controllers.md`：Gadget 控制器脚本体系（按 gadgetId 挂载的实体行为组件）。
- `analysis/16-reward-drop-item.md`：奖励/掉落/物品链路（RewardExcel、DropTable、drop_tag、subfield 掉落映射）。
- `analysis/17-challenge-gallery-sceneplay.md`：Challenge/Gallery/ScenePlay 专题（挑战与活动结算框架、实现边界）。
- `analysis/18-dungeon-pipeline.md`：Dungeon/副本专题（入口点→通关条件→结算/奖励→退出/重开）。
- `analysis/19-route-platform-timeaxis.md`：路线/移动平台/时间轴专题（Route 配表、到点事件、TimeAxis 简化实现与兼容）。
- `analysis/20-talk-cutscene-textmap.md`：Talk/Cutscene/TextMap 专题（叙事作为事件链、TalkExec 覆盖、文本 hash 解码）。
- `analysis/21-worktop-and-interaction-options.md`：Worktop/交互选项专题（SelectOption 事件、隐式/显式 API、任务联动）。

---

## 0.1 本工作区的“引擎层 vs 编排层”划分

### 引擎层（Java / Runtime）

在本工作区里主要是：

- `Grasscutter/`：Java 源码（网络、实体、战斗、存档、任务、脚本引擎接入等）。
- 其中与“脚本/数据层”直接相关的关键入口：
  - `Grasscutter/src/main/java/emu/grasscutter/data/ResourceLoader.java`：资源加载总入口。
  - `Grasscutter/src/main/java/emu/grasscutter/scripts/ScriptLoader.java`：LuaJ 引擎初始化、require 行为、脚本缓存。
  - `Grasscutter/src/main/java/emu/grasscutter/scripts/SceneScriptManager.java`：事件派发、Trigger 评估、调用 Lua 函数。
  - `Grasscutter/src/main/java/emu/grasscutter/scripts/ScriptLib.java`：暴露给 Lua 的“服务器 API”。
  - `Grasscutter/src/main/java/emu/grasscutter/scripts/EntityControllerScriptManager.java`：Gadget 控制器脚本加载。

### 编排层（Lua + 配表/资源包）

在本工作区里主要集中在：

- `resources/`：资源包根目录（就是“玩法编排层”的主体）。

---

## 0.2 `resources/`：脚本/数据层地图（最重要）

`resources/` 里对“玩法逻辑”最关键的子目录如下：

### `resources/Scripts/`（Lua 脚本：玩法编排 DSL）

结构（本仓库实际存在）：

- `resources/Scripts/Scene/`
  - `Scene/<sceneId>/scene<sceneId>.lua`：Scene 元数据（scene_config、blocks、block_rects…）
  - `Scene/<sceneId>/scene<sceneId>_block<blockId>.lua`：Block（区块）→ groups 列表（每个 group 的 id/pos/refresh_id…）
  - `Scene/<sceneId>/scene<sceneId>_group<groupId>.lua`：Group（玩法单元）配置与触发器函数/require
  - （可见但引擎不一定直接使用）`scene<sceneId>_dummy_points.lua` 等
- `resources/Scripts/Common/`
  - 通用玩法模块库（大量 `Vx_y/`、`BlackBoxPlay/` 等）
  - 常见模式：模块通过 `LF_Initialize_Group(...)` 之类函数把 triggers/variables/suites 注入到 group 脚本的表里
- `resources/Scripts/Gadget/`
  - **实体控制器脚本（Entity Controller）**：针对某些 gadgetId 的服务端行为回调
  - 常见函数：`OnClientExecuteReq / OnDie / OnBeHurt / OnTimer`
- `resources/Scripts/Quest/Share/`
  - Quest Share Config（偏数据）：`QxxxxShareConfig.lua`，提供 `quest_data`、`rewind_data` 等

> 脚本加载的“逻辑路径”是以 `Scripts/` 为根（默认 `resources:Scripts/`），Java 侧通常以 `Scene/...`、`Common/...`、`Gadget/...`、`Quest/...` 这种相对路径去找脚本（见 `ScriptLoader`）。

### `resources/ExcelBinOutput/`（Excel 配表：设计态数据）

大量 `*ExcelConfigData.json`，用于定义：

- `SceneExcelConfigData.json`：Scene 基础信息（sceneType、scriptData、levelEntityConfig…）
- `GadgetExcelConfigData.json`：gadgetId → type/jsonName/nameTextMapHash…
- `MonsterExcelConfigData.json`：monsterId → 各类属性（含 nameTextMapHash、serverScript…）
- `QuestExcelConfigData.json`、`MainQuestExcelConfigData.json`、`TalkExcelConfigData.json`：任务/对白驱动数据
- `RewardExcelConfigData.json` 等：奖励、掉落、物品相关

### `resources/BinOutput/`（BinOutput 转 JSON：运行态/配置态数据）

常见用途：

- `BinOutput/Gadget/`：`ConfigEntityGadget`（能力、交互、战斗属性等更底层配置）
- `BinOutput/Monster/`：`ConfigEntityMonster`
- `BinOutput/Avatar/`：`ConfigEntityAvatar`
- `BinOutput/Quest/`：任务相关 JSON（每个 questId 一个文件，供任务系统使用）
- `BinOutput/LevelDesign/Routes/`：路线数据（platform/point array 等）
- `BinOutput/Scene/Point/`：场景点位（传送点、路标等）

### `resources/TextMap/`（文本资源）

例如 `TextMapCHS.json / TextMapEN.json ...`：TextMapHash → 文本，用于把 Excel 表里的 `nameTextMapHash/descTextMapHash` 转成人类可读文字。

### `resources/Server/`（“服务端自定义层”：映射/覆盖/补丁）

这里的文件通常不是“官方资源原始表”，而是 **Grasscutter/私服生态为了让运行更顺而额外引入的映射层**，典型例子：

- `GadgetMapping.json`：gadgetId → serverController（映射到 `Scripts/Gadget/*.lua`）
- `MonsterMapping.json`：monsterId → monsterJson（映射到 `BinOutput/Monster/` 中的配置名）
- `SubfieldMapping.json`、`DropSubfieldMapping.json`：采集物/碎裂物 → drop_id 等
- 一些 Drop 表也可能放在这里（因为 Java 侧会优先从 `Server/` 找 Excel 表覆盖项，见 `FileUtils.getExcelPath`）

### `resources/ScriptSceneData/`（预扁平化的场景脚本数据）

本仓库里存在：

- `flat.luas.scenes.full_globals.lua.json`：把原本的 `scene*_dummy_points.lua` 之类内容扁平化成 JSON，供任务/对白执行时查 dummy point。

---

## 0.3 运行时“加载与关联”鸟瞰（从资源到玩法）

把运行时链路压缩成一张“可心算”的顺序图：

1. **路径与资源根目录**
   - `config.json` / `ConfigContainer.Structure` 定义 resources/scripts 路径
   - `FileUtils.getResourcePath(...)`、`FileUtils.getScriptPath(...)` 将逻辑路径映射到磁盘
2. **资源加载总入口**
   - `ResourceLoader.loadAll()`：
     - `ScriptLoader.init()`：初始化 LuaJ、注入 `EventType/GadgetState/RegionShape/ScriptLib`
     - 加载 ExcelBinOutput（GameResource 反射加载）
     - 加载 BinOutput（ConfigEntityAvatar/Monster/Gadget…）
     - 加载 Quest/Spawn/Routes/ScenePoints 等
     - 加载 `Server/` 映射（GadgetMapping/MonsterMapping…）
     - `EntityControllerScriptManager.load()`：加载 `Scripts/Gadget/*.lua` 控制器脚本
3. **大世界/场景的脚本解析**
   - `SceneMeta` 解析 `Scripts/Scene/<sceneId>/scene<sceneId>.lua`
   - `SceneBlock` 解析 `scene<sceneId>_block<blockId>.lua` 得到 groups 列表
   - `SceneGroup` 解析 `scene<sceneId>_group<groupId>.lua` 得到 monsters/gadgets/regions/triggers/suites/variables
4. **运行时事件 → Trigger → Lua**
   - 引擎侧构造 `ScriptArgs(evt)`（param1/param2/source 等）
   - `SceneScriptManager.callEvent(evt)`：筛选 triggers → 调 condition → 调 action
   - Lua action 里通过 `ScriptLib.*` 操作“世界状态”（刷怪/改机关/加 suite/写变量/加进度…）

---

## 0.4 心智架构图：把它当作“关卡脚本 + 数据驱动事件系统”

下面这张图用“谁引用谁 / 谁驱动谁”的方式，给出最重要的概念关系：

```
Scene(scene_id)
  ├─ 数据：ExcelBinOutput/SceneExcelConfigData.json (sceneType/scriptData/...)
  ├─ 脚本：Scripts/Scene/<scene_id>/scene<scene_id>.lua
  │     ├─ scene_config（出生点、边界、die_y...）
  │     └─ blocks + block_rects（空间分块）
  └─ Block(block_id)  <由 scene_config 决定何时加载/卸载>
        └─ Scripts/Scene/<scene_id>/scene<scene_id>_block<block_id>.lua
              └─ groups[{id, pos, refresh_id, dynamic_load, ...}]
                    └─ Group(group_id) = 玩法最小编排单元（Encounter/Room/Puzzle）
                          ├─ 脚本：scene<scene_id>_group<group_id>.lua
                          │     ├─ monsters/gadgets/regions/triggers/variables（配置表）
                          │     ├─ suites（把“配置对象”编排成若干阶段/集合）
                          │     └─ condition_* / action_* 或 require Common 模块
                          ├─ 运行态：SceneGroupInstance
                          │     ├─ active_suite_id
                          │     ├─ group variables（变量）
                          │     └─ cached gadget states / dead entities（持久化/刷新相关）
                          └─ Entity Instances（实体实例）
                                ├─ Monster(config_id -> monster_id)
                                ├─ Gadget(config_id -> gadget_id)
                                ├─ Region(config_id -> shape/pos/radius/...)
                                └─ Trigger(name -> event/source/condition/action)
```

再把“实体 ID 的两层含义”单独拎出来（非常关键）：

- `config_id`：**关卡内局部实例 ID**（Group 内唯一），Trigger 主要围绕它工作
- `monster_id / gadget_id`：**全局类型 ID**，用来查 ExcelBinOutput/BinOutput 得到实体的“类型定义”

---

## 0.5 核心概念速查（用中性 ARPG 语言）

| 概念 | 你可以把它理解成 | 主要来源 |
|---|---|---|
| Scene | 一张大地图/一个副本（Level） | `SceneExcelConfigData.json` + `Scripts/Scene/<sceneId>/scene<sceneId>.lua` |
| Block | Scene 的空间分块（Chunk） | `scene<sceneId>.lua` 的 `blocks/block_rects` + `scene<sceneId>_block*.lua` |
| Group | 玩法单元（Encounter / Puzzle / Room） | `scene<sceneId>_block*.lua` 的 `groups` + `scene<sceneId>_group*.lua` |
| Suite | Group 内的“阶段/集合/刷怪波次”（State/Snapshot） | group 脚本 `suites` |
| Trigger | 事件订阅（Event → handler） | group 脚本 `triggers` |
| Condition/Action | handler 的条件与行为函数 | group 脚本里的函数名（字符串引用） |
| Variable | Group 的持久状态（FSM 状态/计数器） | group 脚本 `variables` + `ScriptLib.Set/GetGroupVariableValue` |
| Gadget Controller | 单个 gadget 实体的“脚本组件/行为脚本” | `Server/GadgetMapping.json` + `Scripts/Gadget/*.lua` |
| TextMapHash | 文本 ID（多语言索引） | ExcelBinOutput 里的 `*TextMapHash` + `TextMap*.json` |

---

## 0.6 阶段小结（第一阶段）

1. **玩法编排层的核心入口不在 Java 代码里散落**，而是集中在 `resources/Scripts/*`（Lua DSL）与 `resources/*BinOutput*`（表格/配置）这套“数据+脚本”体系里。
2. **Scene → Block → Group → Suite → Trigger** 是最稳定的心智主线：它决定“内容在哪里定义、如何加载、怎样被事件驱动”。
3. `resources/Server/` 是一个“兼容/映射/覆盖”层：它把 excelId ↔ binConfig ↔ gadget controller 串起来，是做“只改数据/脚本”的关键抓手。
