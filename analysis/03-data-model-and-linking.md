# 03 数据层（表格/资源）与脚本的联动：模型、ID 映射与数据驱动流程

本文对应“第三阶段：数据层与脚本联动”。重点不是列全所有表，而是把 **“脚本里写的 id 到底对应哪张表/哪类配置”** 这件事系统化，方便你未来只改脚本/数据就能编排新玩法。

与其他章节关系：

- `analysis/01-overview.md`：目录地图与核心概念关系。
- `analysis/02-lua-runtime-model.md`：Trigger/事件系统与 ScriptLib API。
- `analysis/04-extensibility-and-engine-boundaries.md`：哪些需求靠表+脚本可做，哪些必须改引擎。

---

## 3.1 数据目录的“职责分层”

把 `resources/` 下的数据按“稳定性/抽象层次”分三层最容易建立心智模型：

### A 层：设计态配表（ExcelBinOutput）

- 典型特征：结构相对平、字段语义强、id 稳定
- 典型例子：`GadgetExcelConfigData.json / MonsterExcelConfigData.json / QuestExcelConfigData.json / TalkExcelConfigData.json`
- 用途：告诉你“这个 id 是什么类型/名字/描述/大类”

### B 层：运行态/配置态（BinOutput）

- 典型特征：更接近引擎需要的配置（能力、战斗组件、交互逻辑参数），文件可能分散且命名较“工程化”
- 典型例子：
  - `BinOutput/Gadget/*` → `ConfigEntityGadget`
  - `BinOutput/Monster/*` → `ConfigEntityMonster`
  - `BinOutput/LevelDesign/Routes/*` → 路线/平台移动等
  - `BinOutput/Quest/*` → 任务运行数据

### C 层：服务器补丁/映射层（Server）

这是 Grasscutter 类项目最有价值的一层：它把 A/B 层与脚本层粘在一起。

- `Server/GadgetMapping.json`：gadgetId → serverController（关联到 `Scripts/Gadget/*.lua`）
- `Server/MonsterMapping.json`：monsterId → monsterJson（关联到 `BinOutput/Monster/` 的配置名）
- 以及一些 Drop/Subfield 相关映射：把“采集/碎裂/掉落”串到 drop_id 上

> 关键点：Java 侧读取某些 Excel 表时会优先从 `resources/Server/` 取（见 `FileUtils.getExcelPath`）。  
> 这意味着你可以把“修补/覆盖的表”放在 Server 目录，而不是直接改原始 ExcelBinOutput。

---

## 3.2 按玩法域整理：你真正常用的表（不求全，只求可编排）

### 场景/关卡（Scene/Level）

- `ExcelBinOutput/SceneExcelConfigData.json`：Scene 的基础类型与脚本/实体配置入口
- `Scripts/Scene/<sceneId>/scene<sceneId>.lua`：Scene 的空间边界与 block 切分
- `Scripts/Scene/<sceneId>/scene<sceneId>_block*.lua`：block → groups 列表
- `Scripts/Scene/<sceneId>/scene<sceneId>_group*.lua`：最终的玩法编排单元

### 实体（Monster/Gadget/NPC）与战斗相关

- `ExcelBinOutput/GadgetExcelConfigData.json`：gadgetId → `jsonName/type/nameTextMapHash/...`
- `BinOutput/Gadget/*`：`ConfigEntityGadget`（更底层的能力/战斗/交互配置）
- `Server/GadgetMapping.json`：gadgetId → `serverController`（服务端行为脚本）

对应的链路（非常关键）：

1. group 脚本里写 `gadget_id`（全局类型 ID）
2. 运行时 `EntityGadget` 会从 `GameData.getGadgetDataMap()` 找到 `GadgetData`
3. `GadgetData.jsonName` 用来从 `GameData.getGadgetConfigData()` 找 `ConfigEntityGadget`
4. `Server/GadgetMapping.json` 决定是否挂载 `Scripts/Gadget/<controller>.lua`

Monster 类似：

- `ExcelBinOutput/MonsterExcelConfigData.json`：monsterId → 基本属性、nameTextMapHash…
- `Server/MonsterMapping.json`：monsterId → monsterJson（配置名）
- `BinOutput/Monster/<monsterJson>.json`：`ConfigEntityMonster`

### 任务/对白（Quest/Talk）

核心表：

- `ExcelBinOutput/QuestExcelConfigData.json`：子任务（subQuest）的 accept/finish/fail 条件与 exec
- `ExcelBinOutput/MainQuestExcelConfigData.json`（在 Java 中对应 `data/binout/MainQuestData`）：主任务信息、talks、subQuests 附加数据
- `ExcelBinOutput/TalkExcelConfigData.json`：对白节点的 finishExec（例如传送到 dummy point）

辅助 Lua 数据：

- `Scripts/Quest/Share/Q*ShareConfig.lua`：提供 `quest_data` / `rewind_data`
- `ScriptSceneData/flat.luas.scenes.full_globals.lua.json`：dummy_points（对白/任务执行的坐标来源）

> 这里的关键理解：Quest/Talk 体系是“数据驱动状态机”，Lua（ShareConfig、dummy_points）在很大程度上被当作结构化数据源来用。

### 奖励与掉落（Reward/Drop/Item）

本仓库里你会遇到两类文件：

- `ExcelBinOutput/RewardExcelConfigData.json`、以及 `Drop*`/`Item*` 等表（设计态）
- `Server/DropTableExcelConfigData.json` 等（可能是覆盖/补丁版，且文件可能是压缩成一行的 JSON）

如果你的目标是“只靠表改奖励”，优先策略通常是：

1. 在 `Server/` 放覆盖表（不动原始 ExcelBinOutput）
2. 确认 Java 侧读取路径：`FileUtils.getExcelPath(...)`（Server 优先）

---

## 3.3 ID 字典：脚本里出现的每个 id 应该怎么理解？

这张表是脚本/数据联动的核心。

| id 名称（脚本常见） | 你应该把它当成 | 主要“定义处” | 主要“使用处” |
|---|---|---|---|
| `scene_id` | 场景/关卡 ID（Level） | `SceneExcelConfigData.json` + `Scripts/Scene/<scene_id>/` | 场景切换、group 加载、dummy point 查找 |
| `block_id` | 空间区块 ID（Chunk） | `scene<scene_id>.lua` 的 blocks + `scene<scene_id>_block*.lua` 文件名 | 影响 group 流式加载/卸载 |
| `group_id` | 玩法单元 ID（Encounter/Puzzle 单元） | block 脚本 `groups[].id` + group 脚本文件名 | 变量/套件/实体归属、事件派发的分区 |
| `config_id` | **实体实例 ID（Group 内唯一）** | group 脚本 `monsters/gadgets/regions` | trigger 参数、按 configId 查 entity、CreateMonster/CreateGadget |
| `monster_id` | 怪物类型 ID（全局） | `MonsterExcelConfigData.json` | 生成怪物实体、战斗属性查表、MonsterMapping |
| `gadget_id` | 机关/物件类型 ID（全局） | `GadgetExcelConfigData.json` | 生成机关实体、交互与 controller 映射 |
| `region config_id` | 区域实例 ID（本质也是 config_id） | group 脚本 `regions` | enter/leave region 事件的 `evt.param1` |
| `suite`（suite_id） | group 内阶段/集合 | group 脚本 `suites` | `RefreshGroup / AddExtraGroupSuite / GoToGroupSuite` |
| `route_id / point_array_id` | 路线/点阵 ID | `BinOutput/LevelDesign/Routes/`（以及 ScenePoint/PointArray 相关） | 平台移动、巡逻路线、机关路径 |
| `quest_id` / `main_id` / `sub_id` | 任务节点 ID | Quest/MainQuest/Talk 表 + ShareConfig | 任务状态机、对白执行、传送点 |
| `TextMapHash` | 文本哈希 ID | Excel 表的 `*TextMapHash` 字段 | `TextMap*.json` 本地化 |

> 一个非常实用的记忆法：  
> **`*_id`（monster_id/gadget_id）是“类型”，`config_id` 是“实例”。**  
> 编排层脚本主要操纵“实例”，而数据层表格定义“类型”。

---

## 3.4 “脚本如何引用表”的典型套路（从引擎代码反推）

这里用“引擎侧实际怎么查”的方式说明映射关系（不用猜）：

### 3.4.1 gadget_id → GadgetData → ConfigEntityGadget → Controller

引擎侧（关键逻辑在 `EntityGadget`）的查询链路：

1. `gadget_id` → `GameData.getGadgetDataMap().get(gadget_id)`（来自 `GadgetExcelConfigData.json`）
2. `GadgetData.jsonName` → `GameData.getGadgetConfigData().get(jsonName)`（来自 `BinOutput/Gadget/*`）
3. `GameData.getGadgetMappingMap().get(gadget_id).serverController`（来自 `Server/GadgetMapping.json`）
4. `Scripts/Gadget/<serverController>.lua`（如果存在则作为 entity controller）

这条链路是“只改数据/脚本就能改机关行为”的核心杠杆点。

### 3.4.2 monster_id → MonsterMapping → ConfigEntityMonster

引擎侧（关键逻辑在 `EntityMonster`）：

1. `monster_id` → `Server/MonsterMapping.json` 找 `monsterJson`
2. `monsterJson` → `BinOutput/Monster/<monsterJson>.json` 得到 `ConfigEntityMonster`

### 3.4.3 Quest/Talk → dummy_points（ScriptSceneData）

对白执行里常见 “传送到 dummy point”：

- TalkExec `TRANS_SCENE_DUMMY_POINT` 会：
  1. 取 `ScriptSceneData/flat.luas.scenes.full_globals.lua.json`
  2. 用 key `"<sceneId>/scene<sceneId>_dummy_points.lua"` 找 dummy_points 表
  3. 再用 `"SomePointName.pos"` 找坐标

因此：即便你不运行 dummy_points 的 Lua 文件，引擎仍然可以靠 `ScriptSceneData` 提供坐标数据（这也是为什么资源包里会额外带 ScriptSceneData）。

---

## 3.5 数据驱动流程抽象：从“进入区域”到“刷怪/奖励/推进”

把整条链路抽象成一个“可复用的 ARPG 编排流程”：

### 流程 A：玩家进入区域 → 触发刷怪/机关变化

1. 玩家在 Scene 中移动（Scene/Block/Group 已按位置加载）
2. 区域组件（Region）检测到 enter/leave
3. 引擎创建事件 `evt = ScriptArgs(group_id, EVENT_ENTER_REGION, region_config_id)`（并设置 source_eid/target_eid）
4. `SceneScriptManager.callEvent(evt)`：
   - 找到 `triggers` 里 `event=EVENT_ENTER_REGION` 的项
   - 运行 `condition(...)`（可选）
   - 运行 `action(...)`
5. action 内调用 `ScriptLib`：
   - `AddExtraGroupSuite` / `CreateMonster` / `SetGadgetStateByConfigId` / `SetGroupVariableValue` 等
6. 引擎生成实体、广播同步，玩法变化在客户端可见

涉及到的数据/脚本：

- group 脚本里的 `regions/triggers/suites`
- 触发的 `condition/action` 函数（可能在 group 脚本本体，也可能在 `Common/` 模块里）
- `ScriptLib` API（引擎能力边界）

### 流程 B：玩家交互机关 → Controller 回调 → 触发 group 事件/推进

1. 玩家对 gadget 交互（或客户端 execute request）
2. gadgetId 通过 `Server/GadgetMapping.json` 找到 controller 脚本
3. 触发 controller 函数 `OnClientExecuteReq(context, p1, p2, p3)`
4. controller 内通常调用 `ScriptLib.SetGadgetState(context, state)` 改变当前 gadget
5. gadget 状态变化会触发 `EVENT_GADGET_STATE_CHANGE`（evt.param1/2/3）
6. group trigger（监听 `EVENT_GADGET_STATE_CHANGE`）进一步执行“编排逻辑”

涉及到的数据/脚本：

- gadgetId → controllerName（Server/GadgetMapping）
- controller 脚本（Scripts/Gadget）
- group 脚本 triggers（监听 gadget state change）

> 这两条流程拼起来，就是一个典型 ARPG “数据驱动玩法回路”：  
> **世界状态变化（位置/交互/死亡/变量）→ 事件 → 规则（trigger）→ 行为（ScriptLib）→ 新状态**。

