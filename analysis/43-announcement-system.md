# 43 专题：公告系统：In‑game ServerAnnounce（模板+定时广播）与 HTTP 公告页（getAnnList/getAnnContent）

本文把“公告（Announcement）”拆成两套完全不同的子系统，因为它们服务的场景不同、数据入口不同：

1. **In‑game ServerAnnounce**：登录后游戏内弹出的系统公告/倒计时公告（走游戏包）
2. **HTTP 公告页**：登录前/菜单页的公告列表与内容（走 HTTP 接口与静态资源）

它们共同点是：**都几乎不依赖 Lua**，而是“数据 + 系统服务”的典型模块。

与其他章节关系：

- `analysis/36-resource-layering-and-overrides.md`：公告 JSON 来自 `data/`，可覆盖 jar defaults；HTTP 公告页的图片等也可通过 `data/` 挂载。

---

## 43.1 In‑game 公告的抽象模型：Template（模板）+ Policy（调度策略）+ Broadcast（广播）

用中性模型描述：

- **Template**：一条公告模板（内容、类型、频率、有效期、是否定时推送）
- **Scheduler**：按“任务 cron”定时检查哪些模板需要推送
- **Broadcast**：把公告下发给所有在线玩家

本仓库实现的关键在于：**模板来自 `Announcement.json`，调度来自 `AnnouncementTask`，广播由 `AnnouncementSystem` 完成**。

---

## 43.2 In‑game 公告的数据入口：`data/Announcement.json`

加载入口：

- `Grasscutter/src/main/java/emu/grasscutter/game/systems/AnnouncementSystem.java` 的 `loadConfig()`

结构（从 `AnnounceConfigItem` 反推）：

```text
[
  {
    "templateId": <int>,
    "type": "CENTER|COUNTDOWN",
    "frequency": <int>,
    "content": <string>,
    "beginTime": <ISO datetime>,
    "endTime": <ISO datetime>,
    "tick": <bool>,
    "interval": <int>
  }
]
```

字段语义：

- `type`：
  - `CENTER`：居中系统提示
  - `COUNTDOWN`：倒计时提示
- `frequency`：客户端侧展示频率字段（由 proto 携带）
- `tick`：是否纳入定时任务自动广播
- `interval`：定时任务的“间隔计数阈值”（见 43.4，单位与任务频率一致）
- `beginTime/endTime`：用于控制“在什么时候允许广播”（被任务过滤）

---

## 43.3 引擎侧核心：`AnnouncementSystem`

文件：`Grasscutter/src/main/java/emu/grasscutter/game/systems/AnnouncementSystem.java`

它提供四个能力：

1. **读取配置**：`refresh()`（内部调用 `loadConfig()`）
2. **获取在线玩家**：`getOnlinePlayers()`
3. **广播模板列表**：`broadcast(List<AnnounceConfigItem>)`
4. **撤销公告**：`revoke(tplId)`

### 43.3.1 `AnnounceConfigItem.toProto()` 的一个细节：时间字段并未真正使用

`toProto()` 里把 begin/end 时间写成了：

- beginTime = now + 1
- endTime = now + 10

并且注释直接写了“time is useless”。  
因此：

- `Announcement.json` 里的 begin/end 时间主要用于 **“是否发送”** 的过滤
- proto 里的 begin/end 更像是 **“客户端展示所需字段占位”**

如果你希望“客户端按时间自动结束显示”，这属于更深入的引擎兼容问题。

---

## 43.4 定时广播：`AnnouncementTask`（每分钟 tick）

文件：`Grasscutter/src/main/java/emu/grasscutter/task/tasks/AnnouncementTask.java`

它通过 Quartz task 定义：

- cron：`0 * * * * ?`（每分钟执行一次）

执行逻辑（简化为可读伪代码）：

```text
configs = AnnouncementSystem.configs
active = configs where tick==true and beginTime<=now<=endTime

intervalMap[tplId]++ for tplId in active

toSend = tplId where intervalMap[tplId] >= config.interval
broadcast(toSend)
intervalMap[tplId]=0 for tplId in toSend
```

因此 `interval` 的单位就是“分钟”（因为任务每分钟跑一次，计数 +1）。  
这对你写 `Announcement.json` 很重要：`interval=5` 就意味着 5 分钟发一次。

---

## 43.5 管理入口：`announce` 命令（即时广播/模板广播/刷新/撤销）

文件：`Grasscutter/src/main/java/emu/grasscutter/command/commands/AnnounceCommand.java`

支持四类用法：

- `announce <content>`：即时广播一条纯文本公告（随机生成 configId）
- `announce tpl <templateId>`：广播某个模板
- `announce refresh`：重新加载 `Announcement.json`
- `announce revoke <templateId>`：撤销某个模板 id

这使得“公告系统”很适合作为运维/活动运营的基础设施：  
模板化公告走 `Announcement.json`，临时公告走命令。

---

## 43.6 HTTP 公告页：两份 JSON + 静态资源目录

这套公告是“登录前/菜单页”的那套，入口在：

- `Grasscutter/src/main/java/emu/grasscutter/server/http/handlers/AnnouncementsHandler.java`

### 43.6.1 两个核心接口

- `/common/hk4e_global/announcement/api/getAnnList`
  - 读取：`data/GameAnnouncementList.json`
- `/common/hk4e_global/announcement/api/getAnnContent`
  - 读取：`data/GameAnnouncement.json`

并对内容做模板替换：

- `{{DISPATCH_PUBLIC}}` → 根据配置拼出来的域名（http/https + host + port）
- `{{SYSTEM_TIME}}` → `System.currentTimeMillis()`

然后包一层：

```json
{"retcode":0,"message":"OK","data": <你的json内容>}
```

### 43.6.2 静态资源：`/hk4e/announcement/*`

`AnnouncementsHandler` 还会把 `/hk4e/announcement/*` 映射成“从 data 目录读取文件”：

- 例如 `data/hk4e/announcement/image/banner1.jpg`

`GameAnnouncementList.json` 里引用的 `.../hk4e/announcement/image/...` 就是走这条链路。

对内容层而言，这非常友好：你不用改 Java，只要在 `data/` 下放图片/HTML/CSS/JS 即可。

---

## 43.7 “只改数据”能做什么？哪些属于引擎边界？

### 43.7.1 只改数据就能做

- In‑game 公告：
  - 改 `data/Announcement.json`（内容/类型/是否定时/间隔/有效期）
- HTTP 公告页：
  - 改 `data/GameAnnouncementList.json` 与 `data/GameAnnouncement.json`
  - 在 `data/hk4e/announcement/` 下放图片/页面资源

### 43.7.2 明显的引擎边界

- 更真实的“公告有效期”与客户端展示时长（当前 proto begin/end 并未按配置传递）
- 更复杂的调度策略（当前任务粒度是 1 分钟，interval 也是按分钟计数）
- 公告多语言/多渠道投放策略（目前主要靠写多份 JSON 或手动占位符）

---

## 43.8 小结

- In‑game 公告：`Announcement.json` 定义模板，`AnnouncementTask` 定时筛选并 `broadcast`，`announce` 命令提供人工触发与管理。
- HTTP 公告页：`GameAnnouncement*.json` 由 HTTP handler 原样包装返回，并支持把 `data/` 目录当“静态站点根目录”来挂资源。
- 两套系统都很适合做“玩法编排层的外围基础设施”：它们不需要 Lua，但能承载活动公告、运维提示、版本信息等内容。

---

## Revision Notes

- 2026-01-31：首次撰写本专题；将公告拆成 In‑game 与 HTTP 两条链路，补齐 `AnnouncementTask` 的 interval 语义与 `announce` 命令的管理面，并记录 proto 时间字段未按配置传递的边界点。

