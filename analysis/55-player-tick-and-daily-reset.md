# 55 专题：Player.onTick / DailyReset：1 秒驱动器如何串起“异步玩法”（派遣/锻造/树脂/饱腹/任务）

本文把 `Player.onTick()` 当成一个“系统调度器（System Driver）”来理解：  
它不是某个具体玩法，但它决定了大量玩法系统的 **时间语义**（什么时候刷新、什么时候完成、什么时候发包同步）。

本仓库的关键点是：

- `GameServer` 用 `Timer.scheduleAtFixedRate(..., period=1000ms)` 驱动 tick
- 每秒调用一次 `Player.onTick()`（对每个在线玩家）

与其他章节关系：

- `analysis/42-expedition-system.md`：派遣完成状态推进依赖 tick（Player.onTick 会把 state 从 1→2）。
- `analysis/39-forging-pipeline.md`：锻造队列的状态/通知依赖 tick（sendPlayerForgingUpdate）。
- `analysis/49-resin-and-timegates.md`：树脂回充依赖 tick（rechargeResin）。
- `analysis/50-buffs-food-satiation.md`：服务器 buff 过期与饱腹衰减依赖 tick。
- `analysis/10-quests-deep-dive.md`：任务系统有自己的 tick（QuestManager.onTick）。

---

## 55.1 全局调度：`GameServer.onTick()` 每秒做三件事

文件：`Grasscutter/src/main/java/emu/grasscutter/server/game/GameServer.java`

每秒执行（简化）：

1. `worlds.removeIf(World::onTick)`：tick 世界/场景（Scene.onTick 等）
2. `players.values().forEach(Player::onTick)`：tick 在线玩家
3. `scheduler.runTasks()`：跑全局调度器任务（延迟任务/定时任务）

这说明本仓库的“时间驱动”分两层：

- **世界层 tick**：决定场景实体、挑战、地脉等
- **玩家层 tick**：决定玩家异步系统（派遣/锻造/树脂…）

---

## 55.2 `Player.onTick()`：每秒串起的系统清单（按出现顺序）

文件：`Grasscutter/src/main/java/emu/grasscutter/game/player/Player.java#onTick`

### 55.2.1 连接与请求过期

- ping 检查（异常则 `session.close()`）
- coop 请求过期：`coopRequests.removeIf(expireCoopRequest)`
- enter-home 请求过期：`enterHomeRequests.removeIf(expireEnterHomeRequest)`

这些属于“网络/会话层的 housekeeping”，与玩法编排关系较弱，但会影响多人/家园体验。

### 55.2.2 Buff tick（服务器 buff 过期）

- `buffManager.onTick()`  
  见 `analysis/50-buffs-food-satiation.md`

### 55.2.3 多人同步心跳（RTT 与位置）

当玩家存在 world 时：

- 高频：`PacketWorldPlayerRTTNotify`（注释强调“very important to send this often”）
- 每 5 秒（多人且有 scene）：发送
  - `PacketWorldPlayerLocationNotify`
  - `PacketScenePlayerLocationNotify`

这决定了多人房间里“别人位置更新”的频率与开销。

### 55.2.4 Daily Reset（按天重置）

- `doDailyReset()`（见 55.3）

### 55.2.5 Expedition（派遣完成状态推进）

遍历 `expeditionInfo`：

- 若 `state == 1` 且 `now - startTime >= hourTime * 3600`：
  - `state = 2`
  - 标记 needNotify

needNotify 时：

- `player.save()`
- `send PacketAvatarExpeditionDataNotify(...)`

因此派遣的“完成”不是在 GetRewardReq 时计算，而是由 tick 主动推进状态。

### 55.2.6 Forging（锻造队列更新）

- `forgingManager.sendPlayerForgingUpdate()`

它的作用是：

- 若队列状态变化/需要推送，则发对应 notify（具体见锻造专题）

### 55.2.7 Resin（树脂回充）

- `resinManager.rechargeResin()`

树脂的离线补偿也是在这里被动完成：当玩家上线并进入 tick 后，会按 `nextResinRefresh` 计算补点。

### 55.2.8 Satiation（饱腹衰减）

- `satiationManager.reduceSatiation()`

对应食物系统的“每秒衰减与发包”。

### 55.2.9 Home resources（家园资源小时更新）

- `home.updateHourlyResources(this)`

这说明家园的资源产出也挂在玩家 tick 上（而不是纯世界 tick）。

### 55.2.10 Quest tick（任务系统 tick）

- `questManager.onTick()`

任务系统的“计时器/延迟执行/某些条件轮询”一般会在这里推进。

---

## 55.3 `doDailyReset()`：按 LocalDate 的“跨天重置”语义

文件：`Grasscutter/src/main/java/emu/grasscutter/game/player/Player.java#doDailyReset`

### 55.3.1 判定方式：比较 LocalDate（受服务器时区影响）

- `currentDate = LocalDate.ofInstant(nowEpochSeconds, ZoneId.systemDefault())`
- `lastResetDate = LocalDate.ofInstant(lastDailyReset, ZoneId.systemDefault())`
- `if (!currentDate.isAfter(lastResetDate)) return;`

因此“每天几点重置”取决于服务器的系统时区（ZoneId.systemDefault）。  
如果你未来做跨区部署或希望固定到某个时区，需要显式化这个策略。

### 55.3.2 当前实现包含的日常重置项

跨天后会执行：

1. `setForgePoints(300_000)`：重置锻造点
2. `battlePassManager.resetDailyMissions()`：重置日常战令任务
3. `battlePassManager.triggerMission(TRIGGER_LOGIN)`：让在线玩家在重置后也能完成“登录”类任务
4. 若当天是周一：`resetWeeklyMissions()`
5. `setResinBuyCount(0)`：重置每日买树脂次数
6. `setLastDailyReset(now)`

可以看到它目前覆盖的是一小部分“每日系统”，并非全量（例如委托、商店刷新等可能在其它模块或未实现）。

---

## 55.4 对“玩法编排层”的启示：异步系统优先挂在 tick，而不是到处写 Timer

从架构风格上看，本仓库倾向于：

- 用 **统一 tick** 推进所有“需要时间”的系统状态（派遣、树脂、buff、饱腹…）
- 避免每个系统自己创建线程/定时器（更易控、更可审计）

当你未来想做新的异步玩法（例如：活动积分结算、挂机收益、制作队列、限时挑战倒计时）时，判断标准可以是：

- **是否需要“离线补偿/跨会话持续”？**  
  - 是：应把关键时间戳持久化，并在 tick 中用 `now - startTime` 推进
- **是否需要“高频精确到毫秒”？**  
  - 若只是 UI 级倒计时，tick 足够；若要战斗级精度，可能要走更底层的 scheduler/战斗循环

---

## 55.5 小结

- `Player.onTick` 是本仓库里很多玩法系统的“时间心跳”，决定异步系统何时完成、何时发包、何时重置。
- 当前 tick 周期为 1 秒；DailyReset 使用服务器本地时区的 LocalDate 跨天判定。
- 研究与魔改时，优先把“异步玩法”当成 tick 驱动的状态机，而不是散落的 Timer——这样更接近可复用引擎模块的形态。

---

## Revision Notes

- 2026-01-31：首次撰写本专题；梳理 GameServer→Player 的 1 秒 tick 驱动链路、Player.onTick 的系统调用顺序与 doDailyReset 的跨天语义（含时区影响）。

