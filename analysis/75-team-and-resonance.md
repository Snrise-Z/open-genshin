# 75 玩家子系统专题：队伍（编队 / 出战切换 / 元素共鸣 / 联机队伍）

本文从“玩家队伍界面”视角，梳理 Grasscutter 的队伍系统：队伍数据如何存、出战角色如何在 Scene 中表现为实体、元素共鸣在服务端如何计算并通知客户端，以及作为内容作者（只改脚本/数据）通常能动到哪些边界。

与其他章节关系：

- 多人/房主语义：`analysis/30-multiplayer-and-ownership-boundaries.md`
- Ability/技能与元素类型来源（SkillDepot → ElementType）：`analysis/73-talent-proudskill-skilldepot.md`
- 试用队伍/活动强制编队：`analysis/76-trial-avatar-and-trial-team.md`

---

## 75.1 玩家视角：队伍子系统的 4 个动作

1. **配置队伍**：保存多套队伍（队伍 1/2/3/4…）
2. **出战队伍**：选中某套队伍进入大世界/副本
3. **切换角色**：在队伍内切当前出战角色（currentCharacterIndex）
4. **联机队伍**：多人世界里队伍上限与分配方式不同（每人通常不是 4 人满编）

这些动作中，“配置队伍”更多是数据存储；“出战/切换”涉及 Scene 实体增删与客户端通知；“元素共鸣”是对当前队伍的派生状态计算。

---

## 75.2 数据层：队伍数据主要不在 Excel，而在玩家存档

队伍并不是像任务/场景那样强依赖 Excel 表，而是主要存于玩家数据（数据库）：

- `Player.teamManager.teams`：`teamIndex -> TeamInfo`
- `TeamInfo.avatars`：一组 avatarId（不是 guid）
- `currentTeamIndex`：当前选中的队伍槽位
- `currentCharacterIndex`：当前出战角色索引

ExcelBinOutput 在队伍系统里最关键的贡献反而是：

- 角色的 `SkillDepot` 决定元素类型（`AvatarSkillDepotData.elementType`）
- 元素类型映射到共鸣 ID 与 configHash（见 `ElementType` 枚举）

此外还有两处“配置层”入口：

- `config.json` 的 `server.game.gameOptions.avatarLimits.singlePlayerTeam/multiplayerTeam`：队伍人数上限
- `GameConstants.DEFAULT_TEAM_ABILITY_STRINGS`：队伍基础能力胚（影响 Ability 控制块）

---

## 75.3 运行时模型：TeamManager 的三层结构

对应类：`Grasscutter/src/main/java/emu/grasscutter/game/player/TeamManager.java`

你可以把 TeamManager 心算成三层：

1. **存档层（TeamInfo）**：保存“这套队伍有哪些 avatarId”
2. **实体层（activeTeam）**：当前 Scene 中“出战角色实体列表（EntityAvatar）”
3. **派生状态（共鸣/能力胚）**：由 activeTeam 计算出的 teamResonances、teamAbilityEmbryos 等

核心关系：

- 切队/改队伍 = 更新 TeamInfo
- 进场/切出战角色 = 更新 activeTeam（实体增删）
- 共鸣/能力 = 基于 activeTeam 重新计算并广播

---

## 75.4 出战与切换：Scene 里的“角色实体”如何变化？

TeamManager 的关键行为包括：

- `updateTeamEntities(...)`：根据 TeamInfo 重建 activeTeam 的 `EntityAvatar` 列表
- `getCurrentAvatarEntity()`：按 `currentCharacterIndex` 取当前出战实体
- `updateTeamProperties()`：
  - 重新计算元素共鸣（见 75.5）
  - 广播 `PacketSceneTeamUpdateNotify`（让同世界玩家看到你的队伍状态）
  - 下发技能次数信息（命座导致的 charge map）

作者提示：当你做“副本/活动强制队伍”时，很多问题不是 Excel，而是“实体层与存档层不同步”。这类内容建议优先复用“试用队伍”机制（见 76）。

---

## 75.5 元素共鸣：当前实现的真实边界

### 75.5.1 共鸣计算规则（当前实现）

`updateTeamResonances()` 的规则非常直白：

- **要求满编**：activeTeam.size < 4 直接 return（官方共鸣需要 4 人满队）
- 统计每个元素出现次数（从 `Avatar.skillDepot.elementType` 来）
- 若某元素数量 >=2，则加入该元素的共鸣：
  - `teamResonanceId = ElementType.getTeamResonanceId()`
  - `teamResonancesConfig` 也会加入 `ElementType.getConfigHash()`（用于客户端/能力系统识别）
- 若元素种类 >=4，则加入 “四元素共鸣”（`ElementType.Default`）

### 75.5.2 重要边界：没有读 TeamResonance 表

代码里明确写了 TODO：官方的共鸣条件应读取 `TeamResonanceExcelConfigData.json`。  
但当前版本是 **硬编码**，这带来两个现实影响：

1. 你靠“只改数据”很难做出完全自定义的共鸣规则
2. 若未来资源侧新增元素/改共鸣条件，现实现可能不跟随

作者建议：把“元素共鸣规则”归类为 **引擎层边界**；内容侧更适合做“队伍 Buff（通过 Ability/OpenConfig 注入）”而不是改共鸣判定。

---

## 75.6 队伍 Ability 胚：为什么它也会影响玩法？

TeamManager 会构建 `AbilityControlBlock`，把一些“队伍级别能力”下发给客户端：

来源包括：

1. `GameConstants.DEFAULT_TEAM_ABILITY_STRINGS`（默认）
2. `teamAbilityEmbryos`（会从 levelEntityConfig 等处收集，影响某些场景/副本特效）

如果你遇到“某些副本圈/场景特效不生效”，有时不是怪物/机关脚本问题，而是队伍层的能力胚没注入到位（需要回到 Ability 专题排查）。

---

## 75.7 只改数据/脚本能做什么？哪些需要改引擎？

### 75.7.1 内容层可控（推荐路径）

- 通过任务/副本把玩家“导向某套队伍”（引导、限制入口、给予试用队伍）
- 用试用角色/试用装备构建活动玩法（见 76）
- 用 Ability/OpenConfig 给队伍附加活动 Buff（不改共鸣规则本身）

### 75.7.2 高概率需要改引擎

- 自定义共鸣条件与效果（当前是硬编码且效果链路复杂）
- 让 Lua 脚本直接改队伍/强制切人（涉及协议与客户端状态机）

---

## 75.8 调试建议

- 验证共鸣是否刷新：切换队伍成员后观察是否触发 `PacketSceneTeamUpdateNotify`
- 联机下队伍人数上限：注意 `multiplayerTeam` 会按世界人数做分配（房主/客人不同）

---

## 75.9 小结

队伍系统本质上是：

- 存档层（TeamInfo）保存配置
- 实体层（activeTeam）承载“当前场景里真正出战的角色实体”
- 派生层（共鸣/能力胚）根据实体层计算并下发

在“只改脚本/数据”的内容制作视角里：队伍更多是你要适配的运行时边界，而不是一个你能随意改规则的 DSL。

---

## Revision Notes

- 2026-01-31：初稿。明确共鸣计算硬编码边界、以及 TeamAbilityEmbryos 对某些玩法特效的影响路径。

