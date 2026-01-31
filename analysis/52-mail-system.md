# 52 专题：Mail/邮件系统：DB（Morphia）→ 玩家邮箱列表（index mailId）→ 附件领取/星标/删除（关键风险点）

本文把“邮件”当成一个典型的 **异步奖励投递通道（Async Reward Delivery Channel）** 来拆：  
它适合承载“登录补偿/活动奖励/运营投放/GM 发放”，并提供“可读文本 + 附件物品 + 过期时间 + 状态位”这一套通用能力。

但本仓库的邮件系统还有一个非常值得强调的实现选择：**协议里的 `mailId` 不是数据库主键，而是玩家邮箱列表的 index**。  
这会带来一系列“删邮件/重排/越界”风险，做扩展前必须先理解这个边界。

与其他章节关系：

- `analysis/16-reward-drop-item.md`：邮件附件最终仍然是物品入包（ActionReason.MailAttachment），并触发常规的背包变更通知。
- `analysis/54-gm-handbook-and-admin-actions.md`：GM 工具/控制台通常会把“发邮件”作为一类基础管理动作；本仓库也提供了命令入口。
- `analysis/43-announcement-system.md`：公告与邮件同属“运营内容投递”，但公告偏广播，邮件偏定向/可领取附件。

---

## 52.1 抽象模型：Mail = Content + Attachments + Flags + Expiry

用中性 ARPG 语言抽象，一个邮件条目通常包含：

1. **Content（文本）**：title/content/sender
2. **Attachments（附件）**：一组物品条目（itemId、数量、等级…）
3. **Flags（状态位）**：
   - 是否已读
   - 是否已领取附件
   - 是否星标
   - 属于哪个“邮箱分栏”（普通/礼物等）
4. **Time（时间语义）**：
   - sendTime
   - expireTime（过期后不可见/可删除）

协议侧常见操作：

- 拉取列表
- 标记已读/星标
- 领取附件
- 删除

---

## 52.2 数据持久化：`Mail` 是 Morphia Entity，但 proto mailId 用的是“列表下标”

文件：`Grasscutter/src/main/java/emu/grasscutter/game/mail/Mail.java`

### 52.2.1 Mail 的存储字段（简要）

- `@Entity(value="mail")`
- `@Id ObjectId id`：数据库主键
- `@Indexed int ownerUid`：归属玩家 UID
- `MailContent mailContent`：title/content/sender
- `List<MailItem> itemList`：附件
- `sendTime / expireTime`：秒级时间戳
- `importance`：星标（0/1）
- `isRead / isAttachmentGot`
- `stateValue`：邮箱分栏（注释：1=默认，3=礼物箱）

### 52.2.2 proto mailId 的生成方式（最关键）

`Mail.toProto(Player)` 会执行：

- `setMailId(player.getMailId(this))`

而 `player.getMailId(mail)` 实际是：

- `MailHandler.getMailIndex(mail)` → `mailList.indexOf(message)`

也就是说：

> 客户端看到的 `mailId` 是“当前邮箱列表里的 index”，不是 Mail 的数据库 ObjectId，也不是稳定的自增 id。

### 52.2.3 直接推论：删除/插入会改变 mailId

一旦你：

- 删除一封位于中间的邮件
- 或者未来实现“按时间排序/置顶/过滤”

那么后面的 index 都会变化，客户端缓存的 mailId 可能立刻失效。  
这在协议层属于高风险设计点，建议你把它视为“引擎边界/需要重构”的候选项（见 52.7）。

---

## 52.3 运行态管理：`MailHandler` 用 `List<Mail>` 作为邮箱

文件：`Grasscutter/src/main/java/emu/grasscutter/game/mail/MailHandler.java`

### 52.3.1 加载：`loadFromDatabase()`

- `DatabaseHelper.getAllMail(player)` 拉全量
- 逐个 append 到 `this.mail` 列表

当前没有：

- 统一排序（按 sendTime）
- 自动清理过期邮件（只在 `Mail.save()` 时会删）

### 52.3.2 发送：`sendMail(Mail message)`

关键步骤：

1. 触发事件 `PlayerReceiveMailEvent`（可取消/可修改 message）
2. `message.ownerUid = player.uid`
3. `message.save()`（写库）
4. append 到 `mail` 列表
5. 若玩家在线：发送 `PacketMailChangeNotify(player, message)`

这让邮件成为一个可扩展的“运营投递”入口：

- 插件可以拦截/过滤/二次加工 mail（例如统一模板、敏感词审计、附加奖励等）

### 52.3.3 删除：按 index 删除（并设置 expireTime=0）

- `deleteMail(int mailId)`：
  - `mail.get(mailId)` 取到 message
  - `mail.remove(mailId)`（按 index 删除，导致后续 index 改变）
  - `message.expireTime = 0; message.save()`  
    `Mail.save()` 发现过期（expireTime*1000 < now）会 `DatabaseHelper.deleteMail(this)`

批量删除时（`deleteMail(List<Integer>)`）有一个正确的工程小技巧：

- 会把 id 列表按 **降序排序** 后逐个删除  
  这样能避免“先删小 index 导致大 index 变化”的问题

但它仍然无法解决“客户端侧 mailId 稳定性”的根问题。

### 52.3.4 访问越界风险（需要知道）

`getMailById(int index)` 直接 `return this.mail.get(index)`，没有 bounds check。  
如果客户端传了错误的 mailId，会抛异常（属于鲁棒性缺口）。

---

## 52.4 协议：邮箱的四类常见交互

### 52.4.1 拉取列表：`GetAllMailNotify` → `GetAllMailResultNotify`

- recv：`HandlerGetAllMailNotify`
- send：`PacketGetAllMailResultNotify`

逻辑：

- `isCollected=false`（普通邮箱）时：
  - 过滤 `stateValue == 1`
  - 过滤 `expireTime > now`
  - 返回 `mail.toProto(player)` 列表
- `isCollected=true`（礼物邮箱）：
  - 当前直接返回空（TODO：gift mailbox 未实现）

因此目前你能稳定使用的是“默认邮箱（stateValue=1）”。

### 52.4.2 标记已读：`ReadMailNotify`

文件：`HandlerReadMailNotify`

行为：

- 对每个 mailId：
  - `message.isRead = true`
  - `replaceMailByIndex(mailId, message)`（保存）
- 回包：`PacketMailChangeNotify(updatedMail)`

### 52.4.3 星标/取消星标：`ChangeMailStarNotify`

文件：`HandlerChangeMailStarNotify`

行为：

- `message.importance = req.isStar ? 1 : 0`
- `replaceMailByIndex(...)`
- `PacketMailChangeNotify(updatedMail)`

### 52.4.4 领取附件：`GetMailItemReq` → `GetMailItemRsp` + `MailChangeNotify`

send：`PacketGetMailItemRsp`

关键语义：

- 对每个 mailId：
  - 若 `!message.isAttachmentGot`：
    - 遍历 `message.itemList`：
      - 构造 `GameItem`（设置 count/level/promoteLevel）
      - `player.inventory.addItem(..., ActionReason.MailAttachment)`
    - `message.isAttachmentGot = true`
    - `replaceMailByIndex(mailId, message)`（保存）
- Rsp 里返回：
  - claimed mailId list（再次通过 `player.getMailId(message)` 求 index）
  - claimed item list（EquipParam）
- 然后额外发送一次 `PacketMailChangeNotify(player, claimedMessages)`

一个内容层要注意的边界：

- 领取附件逻辑没有再次检查 `expireTime/stateValue`  
  正常情况下客户端不会请求“看不见的邮件”，但从服务端鲁棒性角度仍属于可补强点。

---

## 52.5 内容/运营侧如何发邮件？

### 52.5.1 代码入口（服务端直接调用）

`Player.sendMail(Mail message)` → `MailHandler.sendMail(message)`

因此任何系统只要拿到 Player，就可以把邮件当作一个“奖励投递 API”。

### 52.5.2 GM 命令入口：`/sendMail`

文件：`Grasscutter/src/main/java/emu/grasscutter/command/commands/SendMailCommand.java`

它提供了一个“交互式构建邮件”的流程（start composition → 填标题/内容/附件 → finish），并支持发给：

- 单个 UID
- 或 all（遍历全体玩家）

从“把项目当引擎”角度，GM 命令是一种很有用的“内容验证/运营投放工具”。

---

## 52.6 “只改数据/脚本”能做到什么？

邮件系统本身不是 Lua 编排驱动的，它更像引擎提供的基础服务。  
因此只改数据/脚本能做的事情有限，常见是：

- 改 TextMap/模板，让邮件内容本地化更完善（如果你把邮件内容也数据化）

真正要用邮件做玩法链路（任务完成→发邮件附件），通常需要：

- 在任务 Exec 或脚本事件里调用“发邮件”的引擎 API  
  而本仓库默认并没有把“发邮件”暴露成 ScriptLib 能直接调用的稳定接口（需要引擎扩展/插件）。

---

## 52.7 引擎边界与建议（mailId=index 是最大风险）

1. **mailId 不稳定**：删/插/排序都会改变 index，客户端缓存会失效  
   - 更稳的方案：proto mailId 使用数据库 ObjectId（或稳定自增 id），并在 MailHandler 建立 map
2. **越界/异常风险**：`getMailById` 无 bounds check  
3. **礼物邮箱未实现**：`isCollected=true` 分支直接返回空  
4. **过期清理是惰性的**：只在 `Mail.save()` 时会删过期，长期在线可能积累过期数据

---

## 52.8 小结

- 邮件是一个标准的“异步奖励投递通道”：文本 + 附件 + 状态位 + 过期。
- 当前实现的最大特征（也是最大风险）是：**客户端 mailId = 邮箱列表 index**。
- 如果你未来要把它当成可扩展引擎模块，建议优先重构 mailId 的稳定性与越界鲁棒性，再考虑礼物邮箱/排序/批量操作等增强功能。

---

## Revision Notes

- 2026-01-31：首次撰写本专题；梳理 Mail/MailHandler 的存储与协议操作闭环，并重点标注“mailId=index”导致的不稳定与风险边界。

