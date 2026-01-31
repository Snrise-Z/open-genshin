# 76 玩家子系统专题：试用角色（Trial Avatar）与试用队伍（活动/副本强制编队）

本文从“玩家参加试用角色活动/秘境”视角，拆解 Grasscutter 的 **试用角色与试用队伍** 系统：试用角色如何由一套“模板装备 + 固定技能等级”构造、如何注入到玩家队伍并暂时锁定、以及你作为内容作者如何复用这一机制来做活动/教学关/体验关。

与其他章节关系：

- 活动/小游戏框架：`analysis/11-activities-deep-dive.md`
- 副本/秘境入口与结算：`analysis/18-dungeon-pipeline.md`
- 队伍系统底座：`analysis/75-team-and-resonance.md`
- 角色/武器/圣遗物/天赋/命座：`analysis/70` ~ `analysis/74`

---

## 76.1 玩家视角：试用角色活动是什么体验？

玩家看到的典型流程：

1. 在活动界面选择一个“试用关卡”
2. 进入专用秘境（或副本）
3. 队伍被替换为一组“试用角色”（等级、武器、圣遗物固定）
4. 通关后领取首通奖励
5. 离开秘境后，队伍恢复原状

对应到服务端心智模型：

- “试用角色”不是玩家永久拥有的 Avatar，而是一组临时构造的 Avatar 实例
- 临时 Avatar 会 **伪装成加入背包但不保存到数据库**
- 队伍切换与恢复由 TeamManager 的 trialTeam 流程完成

---

## 76.2 数据层：试用角色的 4 张表 + 可选自定义覆盖

### 76.2.1 试用角色基础参数：`TrialAvatarExcelConfigData.json`

文件：`resources/ExcelBinOutput/TrialAvatarExcelConfigData.json`（`TrialAvatarData`）

典型条目结构：

- `trialAvatarId`：试用角色 ID（注意：不是 avatarId）
- `trialAvatarParamList`：一个整数列表，Grasscutter 当前只用前两项：
  1) `param[0]`：真实 `avatarId`（角色本体）
  2) `param[1]`：试用等级（level）

### 76.2.2 试用模板：`TrialAvatarTemplateExcelConfigData.json`

文件：`resources/ExcelBinOutput/TrialAvatarTemplateExcelConfigData.json`（`TrialAvatarTemplateData`）

按“试用等级档位”提供模板：

- `TrialAvatarLevel`：模板档位（例如 1、10、20、30…）
- `TrialAvatarSkillLevel`：试用角色的天赋等级（统一设置）
- `TrialReliquaryList`：要装备哪些“试用圣遗物条目”（见下）

Grasscutter 会把试用等级向下取整到模板档位：

- `level<=9` → 模板 1
- 否则 `floor(level/10)*10`

### 76.2.3 试用圣遗物条目：`TrialReliquaryExcelConfigData.json`

文件：`resources/ExcelBinOutput/TrialReliquaryExcelConfigData.json`（`TrialReliquaryData`）

每条定义一个“固定圣遗物实例”：

- `ReliquaryId`：圣遗物 itemId
- `Level`：圣遗物等级
- `MainPropId`：指定主词条
- `AppendPropList`：指定副词条 roll 列表（直接给出 affixId 列表）

这意味着：试用角色的圣遗物不是随机生成，而是 **精确可控**。

### 76.2.4 活动/关卡调度：`TrialAvatarActivity*`

相关文件：

- `resources/ExcelBinOutput/TrialAvatarActivityExcelConfigData.json`
- `resources/ExcelBinOutput/TrialAvatarActivityDataExcelConfigData.json`

这两张表把：

- “活动 schedule”
- “试用关卡 index”
- “对应 dungeonId”
- “可用试用角色列表（battleAvatarsList）”
- “奖励/Watcher 触发配置”

串起来，供 `TrialAvatarActivityHandler` 使用。

### 76.2.5 自定义覆盖（可选）：`resources/CustomResources/TrialAvatarExcels/`

Grasscutter 支持从以下路径加载自定义试用配置（若存在）：

- `resources/CustomResources/TrialAvatarExcels/TrialAvatarData.json`（`TrialAvatarCustomData`）
- `resources/CustomResources/TrialAvatarExcels/TrialAvatarActivityExcelConfigData.json`
- `resources/CustomResources/TrialAvatarExcels/TrialAvatarActivityDataExcelConfigData.json`

自定义数据允许你用更灵活的方式指定：

- 试用武器（甚至“增强版武器”）
- 试用圣遗物列表
- 试用天赋/命座等级

（本仓库目前没有该目录，但机制存在。）

---

## 76.3 运行时：试用角色是怎么被“注入队伍”的？

核心代码在：

- `TeamManager.addTrialAvatars(...)`
- `TeamManager.addTrialAvatar(...)`
- `Avatar.setTrialAvatarInfo(...) / applyTrialItems() / equipTrialItems()`

把流程压缩成一张“作者可心算”的顺序图：

```
addTrialAvatars(trialAvatarIds):
  setupTrialAvatars(saveOriginalTeam)
  for each trialAvatarId:
    params = TrialAvatarData[trialAvatarId].trialAvatarParamList
    avatar = new Avatar(params[0] /*真实avatarId*/)
    avatar.setOwner(player)
    avatar.setTrialAvatarInfo(level=params[1], trialAvatarId, reason, questId)
      ├─ applyTrialSkillLevels()  // 统一天赋等级
      └─ applyTrialItems()        // 装备试用武器+圣遗物
    avatar.equipTrialItems()      // 生成武器实体/绑定owner/挂装备
    send PacketAvatarAddNotify(avatar, save=false)
    addAvatarToTrialTeam(avatar)  // 替换 activeTeam 实体
  trialAvatarTeamPostUpdate(selectIndex)
```

### 76.3.1 试用武器怎么选？

默认（无自定义试用数据）：

- 取角色的 `initialWeapon`
- 如果存在 `initialWeapon + 100` 这个 itemId，则优先用“增强版”（一种私服生态常见技巧）

然后把武器的：

- `level = trialLevel`
- `promoteLevel = minPromoteLevel(trialLevel)`

### 76.3.2 试用圣遗物怎么装？

来自模板的 `TrialReliquaryList`：

- 每个条目指定 `ReliquaryId/Level/MainPropId/AppendPropList`
- 直接构造 `GameItem(reliquaryId)`，然后覆写其主副词条与等级

因此你可以精确做出“教学用面板”或“活动特化 Build”。

### 76.3.3 为什么试用队伍能“锁队”？

试用队伍模式会：

- `usingTrialTeam = true`
- 把原队伍备份到 `trialAvatarTeam`（save=true 时）
- 并发送 `PacketAvatarTeamUpdateNotify` 等包，模拟官方“队伍不可编辑”的状态

离开试用玩法后，通过 `removeTrialAvatar/removeTrialAvatarTeam/unsetTrialAvatarTeam` 恢复。

---

## 76.4 试用角色从哪里触发？（任务 vs 活动）

### 76.4.1 任务侧：QuestExec 授予/移除试用角色

存在两条 Exec（见任务指令集矩阵 `analysis/27`）：

- `QUEST_EXEC_GRANT_TRIAL_AVATAR`
- `QUEST_EXEC_REMOVE_TRIAL_AVATAR`

它们分别调用：

- `TeamManager.addTrialAvatar(trialAvatarId, questMainId)`
- `TeamManager.removeTrialAvatar(trialAvatarId)`

这条链路非常适合做：

- 新手引导关：任务推进到某阶段 → 给试用角色 → 触发教学房间 → 结束后移除

### 76.4.2 活动侧：TrialAvatarActivityHandler 进入试用秘境

活动 handler 会：

- 选择某个 trialAvatarIndexId
- 计算对应 dungeonId
- 调用 DungeonSystem 进入副本
- 设置 selectedTrialAvatarIndex
- DungeonManager 在进入时把 trialTeam 注入 TeamManager

这更适合做：

- 周期活动/关卡列表
- 首通奖励/Watcher 进度

---

## 76.5 内容作者如何复用它做“自制活动”？

推荐的制作路线（最少改引擎）：

1. 先选一种触发方式：
   - “任务触发试用队伍”（QuestExec）
   - “活动触发试用秘境”（ActivityHandler + Dungeon）
2. 用试用模板控制 Build：
   - 需要稳定面板 → 用 `TrialReliquary` 固定主副词条
   - 需要稳定技能手感 → 用模板的 `TrialAvatarSkillLevel`
3. 把玩法写在“秘境 group Lua”里（遭遇战/解谜/挑战），这部分回到 Cookbook（60~69）

最典型的组合是：

> 试用队伍（固定 Build） + 秘境房间脚本（挑战/波次） + 首通奖励

---

## 76.6 常见坑与排查

1. **试用角色进队但没有武器/圣遗物**
   - 排查模板是否存在；`TrialReliquaryList` 指向的条目是否存在
2. **试用等级与模板不匹配**
   - 记住模板档位的向下取整规则（<=9 用 1；否则 floor(level/10)*10）
3. **离开后队伍没恢复**
   - 排查 remove/unset 流程是否被中断（例如异常退出副本）
4. **改了试用表不生效**
   - 资源启动时加载；改完重启

---

## 76.7 小结

试用角色/试用队伍是一个非常适合“把服务器当玩法编排引擎用”的机制：

- 它把“Build/数值”固定下来（模板化）
- 把“玩法/脚本”留给关卡脚本去编排
- 并提供自然的“活动/教学/体验关”结构

如果你希望未来“只改脚本/数据就能做新玩法”，这套机制值得优先复用，而不是从零造一个队伍锁定系统。

---

## Revision Notes

- 2026-01-31：初稿。整理 TrialAvatar 数据拼装（TrialAvatar→Template→TrialReliquary→队伍注入）与任务/活动两条触发链路，并标注自定义覆盖目录。

