# 42 专题：Expedition/派遣系统：`ExpeditionReward.json` → Start/Callback/GetReward → 派遣上限

本文把“派遣（Expedition）”当成一种典型的 **异步奖励系统（Async Reward Job）** 来拆：  
它本质是“把某个角色（avatar）登记到一个任务槽位里 → 未来领取奖励”。  
在本仓库中，派遣是一个相对“薄”的实现：数据主要影响奖励内容，时间/校验逻辑相对简化。

与其他章节关系：

- `analysis/16-reward-drop-item.md`：派遣奖励最终仍然是 Item 入包（并走 `ItemAddHintNotify`）。
- `analysis/24-openstate-and-progress-gating.md`：派遣这种系统在官方常被 OpenState/任务进度限制；本仓库主要提供基础接口与奖励表。

---

## 42.1 抽象模型：Expedition = JobSlot（占用角色）+ RewardProfile（奖励档位）+ Limit（上限）

用中性 ARPG 语言描述：

- **Job Instance（一次派遣任务）**：
  - 绑定一个角色（avatarGuid）
  - 绑定一个奖励档（expId）
  - 绑定一个时长档（hourTime）
  - 记录开始时间（startTime）
- **Reward Profile（奖励档）**：
  - `expId` 代表“派遣地点/类型/奖励组”
  - `hourTime` 代表“4h/8h/12h/20h …”这种时长档
  - 每个档位给一组随机数量的奖励条目
- **Limit（派遣上限）**：
  - 决定同时能派遣多少个角色

---

## 42.2 数据层入口：`data/ExpeditionReward.json`

加载入口：

- `Grasscutter/src/main/java/emu/grasscutter/game/expedition/ExpeditionSystem.java`

结构（从 `ExpeditionRewardInfo/ExpeditionRewardDataList/ExpeditionRewardData` 反推）：

```text
[
  {
    "expId": <int>,
    "expeditionRewardDataList": [
      {
        "hourTime": <int>,                   // 时长档（单位小时）
        "expeditionRewardData": [
          { "itemId": <int>, "minCount": <int>, "maxCount": <int> },
          ...
        ]
      },
      ...
    ]
  }
]
```

奖励生成规则：

- 每条奖励用 `Utils.randomRange(minCount, maxCount)` 取一个随机数量
- `expeditionRewardDataList.hourTime` 与玩家派遣记录中的 `hourTime` 做等值匹配

### 42.2.1 一个细节：JSON 里可能存在未被读取的字段

你工作区的 `ExpeditionReward.json` 中存在 `rewardMora` 字段，但 `ExpeditionRewardDataList` 类并没有对应字段；  
因此它不会影响实际奖励（Gson 会忽略未知字段）。

如果你要在派遣里“额外给 Mora”，应当把 Mora(202) 当成普通 `expeditionRewardData` 条目写入。

---

## 42.3 引擎侧数据结构：`Player.expeditionInfo` 与 `ExpeditionInfo`

### 42.3.1 玩家持久化结构

玩家侧字段：

- `Player.expeditionInfo: Map<Long, ExpeditionInfo>`  
  - key 是 `avatarGuid`（不是 avatarId）

增删接口在 `Player`：

- `addExpeditionInfo(avatarGuid, expId, hourTime, startTime)`
- `removeExpeditionInfo(avatarGuid)`
- `getExpeditionInfo(avatarGuid)`

### 42.3.2 `ExpeditionInfo` 内容

文件：`Grasscutter/src/main/java/emu/grasscutter/game/expedition/ExpeditionInfo.java`

字段：

- `state`
- `expId`
- `hourTime`
- `startTime`

并可转 proto `AvatarExpeditionInfo`。

---

## 42.4 协议入口：派遣的三类请求（AllData / Start / GetReward / CallBack）

### 42.4.1 获取派遣信息与上限：`AvatarExpeditionAllDataReq`

文件：`Grasscutter/src/main/java/emu/grasscutter/server/packet/recv/HandlerAvatarExpeditionAllDataReq.java`

- 回包 `PacketAvatarExpeditionAllDataRsp(expeditionInfo, expeditionLimit)`

### 42.4.2 开始派遣：`AvatarExpeditionStartReq`

文件：`Grasscutter/src/main/java/emu/grasscutter/server/packet/recv/HandlerAvatarExpeditionStartReq.java`

- `startTime = Utils.getCurrentSeconds()`
- `player.addExpeditionInfo(avatarGuid, expId, hourTime, startTime)`
- 回包 `PacketAvatarExpeditionStartRsp(player.getExpeditionInfo())`

当前实现中，这个入口几乎不做额外校验（比如“是否超过上限”“expId 是否合法”等），更多依赖客户端/UI。

### 42.4.3 领取奖励：`AvatarExpeditionGetRewardReq`

文件：`Grasscutter/src/main/java/emu/grasscutter/server/packet/recv/HandlerAvatarExpeditionGetRewardReq.java`

奖励生成：

1. 取 `expInfo = player.getExpeditionInfo(avatarGuid)`
2. 找奖励表：`expeditionRewardDataLists = ExpeditionSystem.map.get(expInfo.expId)`
3. 过滤 `hourTime`：
   - `r.getHourTime() == expInfo.getHourTime()`
4. 对匹配到的 `ExpeditionRewardDataList`：
   - `getRewards()` 生成 `List<GameItem>`（每项 min/max 随机）
5. `player.getInventory().addItems(items)`
6. 发送 `PacketItemAddHintNotify(items, ActionReason.ExpeditionReward)`
7. 清理派遣记录并回包 `PacketAvatarExpeditionGetRewardRsp(...)`

### 42.4.4 取消/召回：`AvatarExpeditionCallBackReq`

文件：`Grasscutter/src/main/java/emu/grasscutter/server/packet/recv/HandlerAvatarExpeditionCallBackReq.java`

- 遍历请求里的 avatarGuid 列表，逐个 `removeExpeditionInfo`
- 回包 `PacketAvatarExpeditionCallBackRsp`

---

## 42.5 派遣上限：`PlayerLevelExcelConfigData` 驱动（但基值写死）

派遣上限计算在：

- `Player.getExpeditionLimit()`

规则（代码注释明确指出是 TODO）：

- 基值：`CONST_VALUE_EXPEDITION_INIT_LIMIT = 2`（目前硬编码）
- 叠加：对 1..玩家等级 的每级 `PlayerLevelData.expeditionLimitAdd`

数据来源：

- `resources/ExcelBinOutput/PlayerLevelExcelConfigData.json`

这对内容层的意义：

- 你可以通过改 `expeditionLimitAdd` 来“随等级解锁更多派遣槽位”
- 但“初始上限”目前需要改 Java（或补 ConstValue 读取）

---

## 42.6 当前实现的“时间语义”部分存在，但领取端不做强校验（重要边界）

这章最容易产生误解的点是：**派遣的“完成”并不是完全缺失**，但“领奖强校验”确实缺口很大。

### 42.6.1 完成状态推进：在 `Player.onTick()` 每秒推进

文件：`Grasscutter/src/main/java/emu/grasscutter/game/player/Player.java#onTick`

每秒会遍历 `expeditionInfo`：

- 若 `state == 1` 且 `now - startTime >= hourTime * 3600`：
  - `state = 2`
  - 保存并发送 `PacketAvatarExpeditionDataNotify`

因此派遣至少具备了“异步完成 → UI 变为可领奖”的基础时间语义（离线补偿也能通过上线后的 tick 推进）。

### 42.6.2 领奖入口：`GetRewardReq` 不检查 state/time（可提前领奖）

文件：`Grasscutter/src/main/java/emu/grasscutter/server/packet/recv/HandlerAvatarExpeditionGetRewardReq.java`

当前实现没有校验：

- `expInfo.state == 2`（已完成）
- 或 `now - startTime >= hourTime * 3600`

就直接按 `expId + hourTime` 生成奖励并入包，然后删除派遣记录。  
这意味着：**只要客户端（或工具）能发送请求，就可能提前领奖**（客户端 UI 只是“表现层限制”，不是服务器强约束）。

把它当成“引擎边界”更合适：

- **做架构研究/私有实验**：可以把派遣当作“可配置的奖励兑换”
- **做更真实的异步系统**：领奖端的完成校验、异常保护（expInfo 为空/越界）、取消返还、离线完成一致性等都需要补齐

---

## 42.7 “只改数据”能做什么？

### 42.7.1 改派遣奖励内容

- 改 `data/ExpeditionReward.json`：
  - `expId`：一组奖励档
  - `hourTime`：不同档位的奖励列表（4/8/12/20h…）
  - `minCount/maxCount`：随机区间

### 42.7.2 改派遣上限曲线（随等级增长）

- 改 `PlayerLevelExcelConfigData.json` 的 `expeditionLimitAdd`

---

## 42.8 小结

- 派遣系统在本仓库更像“可配置的奖励兑换”：`expId + hourTime` 定位奖励档，奖励数量按 min/max 随机。
- 玩家侧只持久化 `avatarGuid → ExpeditionInfo`，上限由“固定基值 + 等级表增量”决定。
- 如果你要把它当成通用 ARPG 引擎模块，建议把“领奖完成校验（state/time 强校验）/异常保护（expInfo 为空或越界）/离线完成一致性与取消返还”等明确列为引擎层待补功能。

---

## Revision Notes

- 2026-01-31：首次撰写本专题；梳理 `ExpeditionReward.json → ExpeditionSystem → Player.expeditionInfo → Start/Reward/Callback` 的闭环，并标注“时间校验缺失”这一明显的引擎边界。
- 2026-01-31：修正：`Player.onTick()` 已实现 `now-startTime >= hourTime*3600` 的完成状态推进（state 1→2 并 Notify）；但 `GetRewardReq` 仍不检查 state/time，提前领奖仍然可能。
