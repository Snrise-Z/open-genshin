# 79 玩家子系统专题：好感度（羁绊/Fetter）与名片奖励

本文从“玩家角色资料/好感度界面”视角，梳理 Grasscutter 的 **好感度（Fetter）** 实现：好感等级与经验曲线、好感条目（故事/语音/表情等）在数据层的组织方式、名片领取流程，以及当前版本在“解锁条件/状态机”上的简化边界。

与其他章节关系：

- Talk/TextMap（故事/语音文案 hash 解码）：`analysis/20-talk-cutscene-textmap.md`
- 家园系统（好感经验存储/领取）：`analysis/34-homeworld-pipeline.md`

---

## 79.1 玩家视角：好感度系统提供了什么？

玩家在“角色资料”里常见的好感度体验：

1. 好感等级从 1 升到 10（显示经验条）
2. 解锁资料内容（故事/语音/表情/动作等）
3. 好感等级达到 10 后可领取该角色的 **名片**

在 Grasscutter 的实现里：

- “等级/经验条”是相对完整的（有经验需求表）
- “资料内容解锁条件”目前大幅简化（很多条目直接标记 FINISH）
- “名片领取”有专门的请求/响应与奖励逻辑

---

## 79.2 数据层：好感度相关表与奖励链路

### 79.2.1 好感等级经验需求：`AvatarFettersLevelExcelConfigData.json`

文件：`resources/ExcelBinOutput/AvatarFettersLevelExcelConfigData.json`（`AvatarFetterLevelData`）

- `fetterLevel` → `needExp`
- 服务端查询：`GameData.getAvatarFetterLevelExpRequired(level)`

### 79.2.2 好感条目（故事/语音等）：`Fetter*` 系列表

Grasscutter 把多张表统一加载为 `FetterData`：

- `resources/ExcelBinOutput/FetterInfoExcelConfigData.json`
- `resources/ExcelBinOutput/FettersExcelConfigData.json`
- `resources/ExcelBinOutput/FetterStoryExcelConfigData.json`

`FetterData` 里保留了：

- `avatarId`
- `fetterId`
- `openCond[]`（开放条件）

同时 `GameData.getFetterDataEntries()` 会把这些条目按 `avatarId` 聚合成：

- `avatarId -> [fetterId...]`

### 79.2.3 名片奖励映射：`FetterCharacterCardExcelConfigData.json` → Reward

文件：

- `resources/ExcelBinOutput/FetterCharacterCardExcelConfigData.json`（`FetterCharacterCardData`）
  - `avatarId -> rewardId`
- `resources/ExcelBinOutput/RewardExcelConfigData.json`（`RewardData`）
  - `rewardId -> rewardItemList[]`

`AvatarData.onLoad()` 会做两步缓存：

1. `nameCardRewardId = FetterCharacterCard.rewardId`
2. `nameCardId = RewardData[nameCardRewardId].rewardItemList[0].itemId`

因此“好感 10 名片”并不是硬写 itemId，而是一个稳定的两段映射。

---

## 79.3 运行时：Avatar 如何存好感度？

对应类：`Grasscutter/src/main/java/emu/grasscutter/game/avatar/Avatar.java`

关键字段：

- `fetterLevel`（默认 1）
- `fetterExp`
- `fetters`（fetterId 列表，来自 `AvatarData.getFetters()`）
- `nameCardRewardId/nameCardId`

### 79.3.1 好感经验如何升级？

实现入口：`InventorySystem.upgradeAvatarFetterLevel(player, avatar, expGain)`

逻辑与“角色等级升级”类似：

- 逐级扣 `AvatarFettersLevel.needExp`
- 上限目前硬写为 `maxLevel=10`
- 升级后会下发：
  - `PacketAvatarPropNotify`
  - `PacketAvatarFetterDataNotify`

好感经验的来源在当前生态里常见两类：

- 家园资源（见 34）：`GameHome.takeHomeFetter` 会把存储的好感经验分配给角色
- 其他玩法来源：不同分支实现差异较大（有些服会插件化）

---

## 79.4 好感条目状态：当前实现的“简化边界”

`PacketAvatarFetterDataNotify` 里构造 fetterList 时：

- 对 avatar 的每个 `fetterId`，直接下发 `FetterState.FINISH`

也就是说：

- `openCond`（开放条件）当前并没有在“下发状态”时逐条校验
- 很多资料内容会表现为“全部已解锁”

如果你希望做“资料内容随好感等级/任务逐步解锁”的体验，这属于：

- 需要补齐引擎层状态机（或插件/二次开发）
- 仅改数据无法完全实现

---

## 79.5 名片领取：请求处理与防重复

客户端会发 `AvatarFetterLevelRewardReq` 来领取好感等级奖励（名片）。

服务端处理（`HandlerAvatarFetterLevelRewardReq`）的关键逻辑：

1. 若 `fetterLevel < 10`：直接回响应（不发奖励）
2. 否则：
   - 取 `avatar.nameCardRewardId` → 找 `RewardData` → 得到 `cardId`
   - 若玩家已拥有该 `cardId`（`player.nameCardList`）则不重复给
   - 否则将 `cardId` 加入背包并发送 `PacketUnlockNameCardNotify`
3. 更新 fetter 数据与 avatar 数据通知

作者提示：这条链路是“好感度系统”里相对完整闭环的一段，适合作为你做自定义名片/资料奖励的入口。

---

## 79.6 只改数据能做什么？哪些必须改引擎？

### 79.6.1 只改数据能做的（稳定）

- 改好感升级所需经验：`AvatarFettersLevelExcelConfigData`
- 改好感 10 名片奖励：
  - `FetterCharacterCardExcelConfigData` 改 rewardId
  - `RewardExcelConfigData` 改 rewardItemList
- 改资料条目集合（fetterId 列表的组成）：调整 Fetter* 表（但解锁条件未必生效）

### 79.6.2 高概率要改引擎的

- 让 `openCond` 真正参与“资料条目解锁状态”（从 FINISH 改为按条件变化）
- 支持好感等级上限 >10（当前升级函数 maxLevel=10）

---

## 79.7 调试建议

- GM 指令：
  - `/setFetterLevel <0..10>`：直接设置当前出战角色好感等级
- 排查名片领取：
  - 若好感已 10 但领不到：检查 `FetterCharacterCard` 是否有该 avatarId；对应 rewardId 是否存在；rewardItemList 是否为空

---

## 79.8 小结

好感度系统在 Grasscutter 当前实现中呈现出“数值层完整、状态机层简化”的特点：

- 等级/经验曲线可改（数据驱动）
- 名片领取链路可用（奖励驱动）
- 资料条目解锁条件未充分实现（需要引擎/插件）

如果你把服务器当 ARPG 编排引擎来用：好感度更适合作为“叙事/收集/奖励系统”的素材库，而不是严格的逐步解锁玩法（除非你准备补齐状态机）。

---

## Revision Notes

- 2026-01-31：初稿。梳理好感等级经验表、名片奖励两段映射，并指出 fetter 条目状态目前直接下发 FINISH 的简化边界。

