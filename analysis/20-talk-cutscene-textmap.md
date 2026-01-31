# 20 - Talk / Cutscene / TextMap：把“叙事”当成玩法编排层的事件链

> 本篇专题的定位不是“还原对话文本”，而是把叙事系统当作 **玩法编排层的事件源** 来理解：Talk 触发了什么、Cutscene 怎么被点火、TextMapHash 如何帮助我们在服务端侧读懂数据。
>
> 关键观点：
> - **Talk 的本质是一个可被触发的事件 ID**（带条件、优先级、NPC 绑定、完成时执行指令），而不是“文本本身”。
> - **Cutscene 是客户端资源**：服务端通常只负责“发一个 cutsceneId 的通知”，内容/镜头/对白由客户端演出。
> - **TextMap 是“数据可读性工具”**：服务端多数时候并不需要把 hash 翻译成字符串（客户端自己能显示），但我们做逆向/魔改需要它来读懂配置。
>
> 关联阅读：
> - `analysis/10-quests-deep-dive.md`：任务系统如何消费 Talk 事件（CompleteTalk/NotFinishPlot 等）
> - `analysis/13-event-contracts-and-scriptargs.md`：事件 ABI（尤其是“哪些字段用于匹配 trigger.source”）

---

## 1. Talk ID 从哪来？两份数据源的“交集”

在这个生态里，Talk 至少出现在两类数据里：

### 1.1 `BinOutput/Quest/<mainQuestId>.json` 里的 `talks[]`

例如 `resources/BinOutput/Quest/70674.json`：

- `talks[].id`：talkId（例如 7067401）
- 常见字段：`beginWay/activeMode/beginCond/priority/initDialog/npcId/questId/heroTalk/...`

这类字段多为“客户端叙事系统需要的元信息”。  
**服务端不一定完整使用**这些字段，但它们告诉我们：哪个 talkId 属于哪个主任务、绑定哪个 NPC、在什么条件下可触发。

### 1.2 `ExcelBinOutput/TalkExcelConfigData.json` 里的 talk 配置

服务端运行时主要依赖 `GameData.getTalkConfigDataMap()`（由 `TalkConfigData` 加载），其核心字段（服务端会关心）是：

- `id`：talkId
- `npcId[]`：允许触发该 talk 的 NPC id 列表（服务端会做校验）
- `finishExec[]`：对话完成时要执行的指令序列（TalkExec）
- `questId`：归属主任务（`TalkConfigData.onLoad()` 会在缺失时由 talkId 推导）

> 结论：对服务端来说，Talk 的“可执行部分”主要来自 `finishExec`，而不是对话文本/镜头。

---

## 2. 运行时链路：NpcTalkReq → TalkManager → TalkSystem → Quest 事件

### 2.1 客户端请求入口：`NpcTalkReq`

handler：`Grasscutter/src/main/java/emu/grasscutter/server/packet/recv/HandlerNpcTalkReq.java`

它做的事很直接：
- 解析 `talkId` 与 NPC 实体 id
- 调 `player.getTalkManager().triggerTalkAction(talkId, npcEntityId)`
- 回包 `PacketNpcTalkRsp`

### 2.2 `TalkManager.triggerTalkAction`：Talk 的“完成钩子”

代码：`Grasscutter/src/main/java/emu/grasscutter/game/talk/TalkManager.java`

它的行为可以按顺序理解：

1. 取 `talkData = GameData.getTalkConfigDataMap().get(talkId)`
2. 触发 `PlayerNpcTalkEvent`（插件可拦截）
3. 如果 `talkData != null`：
   - 校验 NPC：取 scene 实体 `npcEntityId`，用其 `configId` 作为 NPC ID；要求该 ID 在 `talkData.npcId` 内  
     （`TalkManager` 的注释写得很直白：实体的 configId 就是 NPC 的 ID）
   - 执行 `finishExec`：逐条调用 `TalkSystem.triggerExec(player, talkData, execParam)`
   - 记录该 talk 到主任务：`saveTalkToQuest(talkId, talkData.questId)`
4. 无论 talkData 是否存在，都会向 QuestManager 投递事件：
   - `QUEST_CONTENT_COMPLETE_ANY_TALK`（param=talkId）
   - `QUEST_CONTENT_COMPLETE_TALK`（param=talkId）
   - `QUEST_COND_COMPLETE_TALK`（param=talkId）

**玩法编排层理解：**
- Talk 就像一个“剧情节点开关”；你可以在任务条件里监听“某 talk 被完成”，也可以在 finishExec 里直接做推进。

---

## 3. TalkExec：对话完成后能做什么？哪些在本仓库可用？

### 3.1 TalkExec 列表（概念层）

枚举：`Grasscutter/src/main/java/emu/grasscutter/game/talk/TalkExec.java`

可见的指令类型包括：

- `TALK_EXEC_SET_GADGET_STATE`
- `TALK_EXEC_SET_GAME_TIME`
- `TALK_EXEC_NOTIFY_GROUP_LUA`
- `TALK_EXEC_SET/INC/DEC_QUEST_VAR`
- `TALK_EXEC_SET/INC/DEC_QUEST_GLOBAL_VAR`
- `TALK_EXEC_TRANS_SCENE_DUMMY_POINT`
- `TALK_EXEC_SAVE_TALK_ID`

### 3.2 TalkExecHandler 覆盖情况（实现层）

执行器注册在：
- `Grasscutter/src/main/java/emu/grasscutter/game/talk/TalkSystem.java`

它通过反射扫描 `TalkExecHandler` 子类（带 `@TalkValueExec` 注解）进行注册。  
当前仓库中可见的 exec 实现（`Grasscutter/src/main/java/emu/grasscutter/game/talk/exec/`）包括：

- `ExecSetQuestVar / ExecIncQuestVar / ExecDecQuestVar`
- `ExecSetQuestGlobalVar / ExecIncQuestGlobalVar / ExecDecQuestGlobalVar`
- `ExecSetGameTime`
- `ExecTransSceneDummyPoint`

缺失/未实现的典型项：
- `TALK_EXEC_NOTIFY_GROUP_LUA`
- `TALK_EXEC_SET_GADGET_STATE`
- `TALK_EXEC_SAVE_TALK_ID`

当 `finishExec` 里出现“服务端没有 handler 的类型”时：
- `TalkSystem.triggerExec` 会 debug 日志并跳过，不会报错中断。

**对魔改的直接含义：**
- 你可以在不动 Java 的前提下，优先利用“已实现”的 exec 类型来推进任务变量/全局变量/传送/时间。
- 如果你依赖 `NOTIFY_GROUP_LUA`（把剧情推进直接通知到某个 group 脚本），那就是典型的引擎边界：要么补 Java handler，要么改数据/脚本走其他链路（例如 QuestExec、Lua `AddQuestProgress`）。

---

## 4. Talk 与 Quest 的关系：主任务/子任务如何消费“对话完成”

你会在主任务的 `subQuests[].finishCond` 里见到：
- `QUEST_CONTENT_COMPLETE_TALK`
- `QUEST_CONTENT_COMPLETE_ANY_TALK`
- 以及 “plot/talk 未完成”之类的条件（具体见 Quest content 实现）

而 TalkManager 在触发对话时，会主动 `queueEvent` 这些 QuestContent。  
因此从“编排层”角度，你可以把 Talk 当作：

> Quest 的输入事件之一：Talk 完成 → Quest 条件满足 → QuestExec 执行 → 再反过来驱动 group/lua

这条链比“在 Lua 里硬编码剧情状态机”更数据驱动，也更接近 ARPG 引擎的叙事编排思路。

---

## 5. Cutscene：服务端只负责“点火”，内容在客户端

### 5.1 Lua 触发 cutscene：`ScriptLib.PlayCutScene`

实现：`Grasscutter/src/main/java/emu/grasscutter/scripts/ScriptLib.java`

- `PlayCutScene(cutsceneId, ...)` 会广播 `PacketCutsceneBeginNotify(cutsceneId)`
- `PlayCutSceneWithParam` 在本仓库是 `unimplemented`

这说明：
- 服务端几乎不参与 cutscene 的“内容构建”
- cutsceneId 的含义主要来自客户端资源（你需要客户端数据才能知道它具体演什么）

### 5.2 Cutscene 也可能出现在入口点数据

在 `scene*_point.json` 的 `DungeonEntry` 点里，你可能看到 `cutsceneList`（例如 `resources/BinOutput/Scene/Point/scene3_point.json` 的某些入口点）。

这类字段通常用于“玩家进入/交互某入口点时客户端播放过场”，服务端未必需要主动干预。

---

## 6. TextMap：把一堆 `xxxTextMapHash` 变成可读文本（为逆向与魔改服务）

### 6.1 TextMap 的存在意义

你会在各种数据里看到：
- `titleTextMapHash`（主任务标题）
- `descTextMapHash`（任务描述）
- `nameTextMapHash`（物品/怪物/NPC 名称）

这些 hash 的“真实字符串”不在 Excel/BinOutput 中，而在：
- `resources/TextMap/TextMap*.json`

### 6.2 服务端如何加载 TextMap（工具/调试用途）

实现：`Grasscutter/src/main/java/emu/grasscutter/utils/lang/Language.java`

要点：
- 会把 `TextMap/TextMapCache.bin` 缓存到 `cache/TextMap/` 下（加速加载）
- 若资源更新时间晚于缓存，会重新生成缓存
- 生成缓存时会先 `ResourceLoader.loadAll()`，然后收集“用到的 hash”（并不是加载全量 TextMap）
- 查字符串用：`Language.getTextMapKey(hash)`，返回一个 `TextStrings`（按语言取值）

### 6.3 玩法编排层的常用用法：把 hash 翻译成人话

典型场景：
- 你在 `BinOutput/Quest/70674.json` 看到 `titleTextMapHash: 252999167`，想知道任务名是什么。
- 你可以用 TextMapCHS 查 key=252999167 的值（或用 `Language.getTextMapKey` 读出来）。

注意一个现实边界：
- 客户端 UI 通常不依赖服务端 TextMap（客户端自己有资源），所以你在服务端改 TextMap **未必能让客户端显示变化**；它更常用于“我们读懂数据/做离线分析”。

---

## 7. 面向“只改脚本/数据”的叙事实践建议

1. **把 Talk 当作“剧情节点事件”来用**
   - 在任务 finishCond 里监听 `COMPLETE_TALK`
   - 或在 talk 的 `finishExec` 里做 `SetQuestVar/SetGameTime/TransSceneDummyPoint`

2. **把 Cutscene 当作“演出触发器”**
   - 在关键节点（例如 `EVENT_QUEST_START` / `EVENT_ENTER_REGION` / `EVENT_CHALLENGE_SUCCESS`）里 `PlayCutScene(cutsceneId, ...)`
   - 避免在服务端侧尝试“拼装 cutscene 内容”（那是客户端资源域）

3. **用 TextMap 解决“看不懂 hash”的痛点**
   - 把 TextMapHash 翻译成字符串，建立可读的索引/笔记（对长期逆向非常重要）

---

## 8. 常见坑与定位

1. **NPC 校验失败导致 talk 不生效**
   - `TalkManager` 会校验 `talkData.npcId` 包含 NPC 的 `configId`
   - 如果你改了 NPC 或 talk 配置，注意同步 `npcId` 列表

2. **finishExec 没效果**
   - 看 `TalkExec` 类型是否有对应的 `TalkExecHandler`
   - 没有 handler 的类型会被跳过（只打 debug 日志）

3. **TextMap 改了但工具输出没变**
   - TextMap 有缓存：`cache/TextMap/TextMapCache.bin`
   - 需要让 `Language.loadTextMaps(true)` bypass cache，或清理缓存文件

