# 34 专题：家园（HomeWorld）管线：Realm/模块 → Outdoor/Indoor Scene → 摆放数据 → 套装事件/奖励

本文把家园当成一个独立的“**玩家可编辑的持久化世界（Player Housing Sandbox）**”系统来拆解。  
它与大世界 Scene/Group/Lua 脚本体系的关系是：**同属 ARPG 引擎的一部分，但运行模型完全不同**——家园基本不走 `resources/Scripts/Scene` 的 Lua 编排，而是走 HomeWorld 专用的数据结构与管理器。

与其他章节关系：

- `analysis/12-scene-and-group-lifecycle.md`：普通 Scene 的 Block/Group/Suite 生命周期（家园对比用）。
- `analysis/35-world-resource-refresh.md`：大世界 Spawn/刷新；家园 `HomeScene` 明确禁用了这些管线。
- `analysis/04-extensibility-and-engine-boundaries.md`：家园很多扩展点更偏“系统机制”，下潜概率高。

---

## 34.1 抽象模型：HomeWorld = 永久在线世界 + 模块（Realm）切换 + 摆放存档

你可以把家园抽象成：

- 一个 **Home（玩家家园存档）**：存摆放、等级、资源累积、已解锁模块等
- 一个 **HomeWorld（家园世界实例）**：一个 World，允许多人进入参观
- 一个 **Module/Realm（模块/洞天）**：决定你当前使用哪一套 Outdoor/Indoor 场景
- 两张 **Scene（户外/室内）**：实体来自“摆放数据”，而不是 Lua group 刷出来
- 一套 **套装事件（Suite Events）**：某些套装 + 某些角色组合会触发奖励/召唤事件

这更像“建造/装扮”子系统，而不是“关卡脚本”子系统。

---

## 34.2 数据依赖清单（家园内容主要在哪些资源里）

### 34.2.1 场景与模块（Realm）

- Scene 类型来自 SceneExcel（sceneType）：
  - `SCENE_HOME_WORLD` / `SCENE_HOME_ROOM`
- 模块/洞天配置：
  - `resources/ExcelBinOutput/HomeworldModuleExcelConfigData.json`
- 家园等级与成长：
  - `resources/ExcelBinOutput/HomeworldLevelExcelConfigData.json`

### 34.2.2 默认摆放（初始布局）

默认摆放来自 BinOutput：

- `resources/BinOutput/HomeworldDefaultSave/scene*_home_config.json`

加载入口：`Grasscutter/src/main/java/emu/grasscutter/data/ResourceLoader.java` 的 `loadHomeworldDefaultSaveData()`

含义：

- 新玩家/新模块的初始布局靠这些文件生成
- 你想“只改数据改默认布局”，主要就是改这套 `scene*_home_config.json`

### 34.2.3 家园对象与事件数据（家具/NPC/动物/BGM/事件）

ExcelBinOutput 中的家园相关表：

- `HomeWorldFurnitureExcelConfigData.json`
- `HomeWorldNPCExcelConfigData.json`
- `HomeworldAnimalExcelConfigData.json`
- `HomeWorldEventExcelConfigData.json`
- `HomeWorldBgmExcelConfigData.json`

这些表决定“家园里有什么内容/套装怎么触发/奖励是什么”。

---

## 34.3 引擎侧核心对象：`GameHome`、`HomeWorld`、`HomeScene`、`HomeModuleManager`

### 34.3.1 `GameHome`：家园存档（DB: homes）

文件：`Grasscutter/src/main/java/emu/grasscutter/game/home/GameHome.java`

它存了大量持久化字段，例如：

- `level/exp/storedCoin/storedFetterExp`：成长与资源
- `sceneMap/mainHouseMap`：各 scene 的摆放数据（`HomeSceneItem`）
- `unlockedHomeBgmList`、奖励事件完成记录等

并提供：

- `getHomeSceneItem(sceneId)`：取某个场景的摆放数据，若不存在会用默认布局初始化
- `getMainHouseItem(outdoorSceneId)`：户外对应的室内主宅布局

### 34.3.2 `HomeWorld`：家园世界实例（World 的一个变体）

文件：`Grasscutter/src/main/java/emu/grasscutter/game/home/HomeWorld.java`

关键特性：

- `isMultiplayer()` 永远返回 true（家园天生允许多人参观）
- `getActiveOutdoorSceneId() = currentRealmId + 2000`
- `getActiveIndoorSceneId()` 从 outdoor 的 `HomeSceneItem.roomSceneId` 推出
- `onTick()` 会驱动 moduleManager tick，并广播时间包

它相当于“家园的运行时容器”。

### 34.3.3 `HomeScene`：禁用 Spawn/NPC 的特殊 Scene

文件：`Grasscutter/src/main/java/emu/grasscutter/game/home/HomeScene.java`

它重写并关闭了许多大世界逻辑：

- `checkNpcGroup()`：空实现
- `checkSpawns()`：空实现
- `loadNpcForPlayerEnter()`：空实现
- `addItemEntity()`：空实现

并提供编辑模式钩子：

- `onEnterEditModeFinish()`：移除动物实体
- `onLeaveEditMode()`：按摆放数据重新 add 动物

结论：**家园不是靠 Lua group 刷实体，而是靠 HomeSceneItem 的摆放数据生成实体**。

### 34.3.4 `HomeModuleManager`：模块（Realm）管理与套装事件

文件：`Grasscutter/src/main/java/emu/grasscutter/game/home/HomeModuleManager.java`

它负责：

- 同时 tick 户外与室内 scene
- `onUpdateArrangement()`：当摆放更新时：
  - 重新计算所有“套装奖励事件”（rewardEvents）
  - 取消不再满足条件的召唤事件（summonEvents）
- `claimAvatarRewards(eventId)`：领取套装奖励
- `fireAvatarSummonEvent(...)`：触发召唤事件（并下发 notify）

这套机制把“摆放系统”与“奖励/事件系统”连起来，是家园玩法的核心编排点。

---

## 34.4 家园的“玩法编排层”在哪里？（与 Lua 编排的差异）

普通大世界玩法的编排主线是：

> Scene → Block → Group → Suite → Trigger（Lua）→ ScriptLib 改世界状态

家园的编排主线更像：

> Module/Realm → Outdoor/Indoor Scene → HomeSceneItem（摆放数据）→ SuiteEvent（套装规则）→ Reward/Event

因此你想“在家园里写 Lua 机关/刷怪挑战”，在当前仓库实现里并不是天然路线；家园更偏 UI/摆放/套装奖励，而不是战斗关卡。

---

## 34.5 只改数据能做什么？（务实建议）

### 34.5.1 改默认布局（新号/新洞天初始样子）

- 修改 `resources/BinOutput/HomeworldDefaultSave/scene*_home_config.json`
- 注意 sceneId 对应关系：
  - 户外通常是 `2001~200x`
  - 室内通常是 `2201~220x`

### 34.5.2 改家具/NPC/动物/套装事件的数据内容

- 通过 `HomeWorldFurnitureExcelConfigData.json` 等表增删改条目
- 套装事件与奖励主要看：
  - `HomeWorldEventExcelConfigData.json`
  - Reward 表（见 `analysis/16-reward-drop-item.md`）

### 34.5.3 改模块/洞天解锁与成长曲线

- `HomeworldModuleExcelConfigData.json`
- `HomeworldLevelExcelConfigData.json`

---

## 34.6 哪些扩展大概率需要下潜引擎？

家园的机制更“系统化”，下潜需求更常见：

- 新增一种全新的摆放交互/编辑规则
- 让家园支持战斗/刷怪/副本式玩法（需要重开 Spawn/NPC/脚本管线）
- 更复杂的套装事件逻辑（目前事件类型在 Java 枚举/实现里固定）

---

## 34.7 小结

- HomeWorld 是一个与大世界 Lua 编排体系并行的子系统：它靠 HomeSceneItem 摆放数据驱动实体，而不是靠 SceneGroup Lua。
- `GameHome` 是持久化存档；`HomeWorld` 是多人世界容器；`HomeScene` 禁用了大世界 Spawn/NPC；`HomeModuleManager` 负责模块切换与套装事件/奖励。
- “只改数据”最适合做：默认布局、家具/套装/奖励内容、模块成长曲线；而“新增玩法机制”更容易触及引擎边界。

---

## Revision Notes

- 2026-01-31：首次撰写本专题；梳理家园系统的核心对象、数据依赖与它相对 Lua 编排体系的差异化运行模型。

