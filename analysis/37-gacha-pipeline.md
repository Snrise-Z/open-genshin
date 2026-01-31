# 37 专题：Gacha/抽卡系统：`Banners.json` → 权重曲线/保底 → 记录页/战令触发

本文把“抽卡/招募（Gacha）”当成一个典型的 **配置驱动概率系统** 来拆：  
核心不在 Lua（几乎不走脚本编排），而在 **`data/Banners.json` 的“池子 + 概率曲线 + 保底状态机”** 与 Java 侧的 **统一抽取算法**。

与其他章节关系：

- `analysis/16-reward-drop-item.md`：抽到的东西最终都变成 Item（角色卡/武器/材料），走同一套入包与掉落物品语义。
- `analysis/28-achievement-watcher-battlepass.md`：抽卡会触发战令/Watcher（`TRIGGER_GACHA_NUM`）。
- `analysis/36-resource-layering-and-overrides.md`：`data/` 目录可覆盖 jar 内 defaults（Banners/ShopChest 等），是“只改数据”的工程抓手。

---

## 37.1 抽象模型：Gacha = Banner（规则）+ Pools（池子）+ PityState（保底状态）

用中性 ARPG 语言描述，一个抽卡系统通常由三层构成：

1. **Banner（横幅/卡池定义）**：时间窗口、花费、展示资源、池子组成、概率曲线、特殊规则（如定轨）。
2. **Pools（候选池）**：
   - 稀有度池：3★/4★/5★
   - “UP 池 vs 非 UP（歪）池”
   - “双池平衡”（比如 4★可能是角色/武器两类）
3. **PityState（玩家状态）**：
   - 稀有度保底计数：`pity4/pity5`
   - UP 失败计数（大保底）：`failedFeatured...`
   - 双池平衡计数：`pity4Pool1/2`、`pity5Pool1/2`
   - 定轨进度：`wishItemId` + `failedChosenItemPulls`

本仓库的实现非常“教科书”：**所有这些都明确落在数据与少量 Java 状态字段里**，便于你把它当作可移植的引擎模块研究。

---

## 37.2 数据层入口：你真正需要改的文件

### 37.2.1 `data/Banners.json`（最关键）

这是抽卡系统的“玩法配表”。每个对象大致可理解为：

- **身份**：
  - `scheduleId`：**本服务器用于标识一个 banner 实例**（同时也是 `GetGachaInfoRsp`/详情页的索引键）
  - `gachaType`：客户端协议层的 gacha 分类（同时写入抽卡记录，用于“按池子看记录”）
  - `bannerType`：决定默认参数与“属于哪一类保底槽位”（STANDARD/BEGINNER/CHARACTER/WEAPON 等）
- **展示/UI**：
  - `prefabPath`、`previewPrefabPath`、`titlePath`
- **时间/排序**：
  - `beginTime` / `endTime`：Unix 秒时间戳
  - `sortId`：客户端列表排序
- **成本**：
  - `costItemId`/`costItemAmount`、`costItemId10`/`costItemAmount10`
  - `gachaTimesLimit`：总抽数上限（新手池常用）
- **池子**：
  - `rateUpItems4` / `rateUpItems5`：UP 池（itemId 列表）
  - `fallbackItems3`：3★保底池
  - `fallbackItems4Pool1/2`、`fallbackItems5Pool1/2`：4★/5★“歪池”（可双池）
- **概率曲线（核心）**：
  - `weights4` / `weights5`：稀有度权重曲线（见 37.4）
  - `eventChance4` / `eventChance5`：抽到 4★/5★ 时，“是否为 UP”的 coinflip 概率
  - `poolBalanceWeights4/5`：双池平衡曲线（见 37.6）
- **特殊规则**（非原版/扩展项）：
  - `autoStripRateUpFromFallback`：从歪池中剔除 UP，避免“双重进入”
  - `removeC6FromPool`：过滤已满命角色（见 37.9.3）
  - `wishMaxProgress`：武器定轨上限（见 37.8）

### 37.2.2 `data/gacha/*`（记录页与详情页静态资源）

- `data/gacha/records.html`：抽卡记录页面模板
- `data/gacha/details.html`：概率/可出物品展示页面模板
- `data/gacha/mappings.js`：前端映射（把 itemId 映射成名称/稀有度等，属于“展示层”）

它们不改变抽卡结果，只影响“怎么展示记录/详情”。

### 37.2.3 依赖的“物品/角色/武器”定义

`Banners.json` 里写的 `itemId` 最终都要能在 `GameData.getItemDataMap()` 找到 `ItemData`，否则会被跳过。  
因此你改池子时，经常需要同时确认：

- 这些 itemId 是否存在于资源包（ExcelBinOutput/BinOutput）中
- 对于角色卡：`InventorySystem.checkPlayerAvatarConstellationLevel(player, itemId)` 能识别它是“角色”还是“武器”

---

## 37.3 引擎侧关键类：抽卡算法在这些文件里定型

### 37.3.1 `GachaSystem`：加载/热重载/抽取/结算

文件：`Grasscutter/src/main/java/emu/grasscutter/game/gacha/GachaSystem.java`

你可以把它理解成三段：

1. **加载配置**：`load()`  
   - 读 `Banners` 表（支持 `.tsj/.json/.tsv`，见 `DataLoader.loadTableToList`）
   - 对每个 `GachaBanner` 调 `onLoad()` 以补齐默认值
   - 用 `scheduleId` 作为键放入 `gachaBanners`（注意要唯一）
2. **抽取主流程**：`doPulls(player, scheduleId, times)`  
   - 只允许 `times=1/10`
   - 扣成本（`banner.getCost(times)`）
   - 循环 `times` 次调用 `doPull(...)`
   - 结算：入包、星尘/星辉、角色命座物品、写记录、触发战令
3. **热重载（可选）**：`watchBannerJson(GameServerTickEvent)`  
   - `Configuration.GAME_OPTIONS.watchGachaConfig=true` 时，监听 `Banners.json` 变更自动 `load()`

### 37.3.2 `GachaBanner`：把 `Banners.json` 变成“可计算的参数集”

文件：`Grasscutter/src/main/java/emu/grasscutter/game/gacha/GachaBanner.java`

重点不在字段本身，而在 `onLoad()` 的“默认值逻辑”：

- 若未填 `weights4/weights5/eventChance*` 等，按 `bannerType` 的默认模板补齐
- `previewPrefabPath` 若为空，自动设为 `"UI_Tab_" + prefabPath`

它还定义了 BannerType → 默认参数的“范式模板”，这对做自定义池很有参考价值。

### 37.3.3 玩家持久化状态：`PlayerGachaInfo` / `PlayerGachaBannerInfo`

文件：

- `Grasscutter/src/main/java/emu/grasscutter/game/gacha/PlayerGachaInfo.java`
- `Grasscutter/src/main/java/emu/grasscutter/game/gacha/PlayerGachaBannerInfo.java`

关键点：**保底不是按 `scheduleId` 存的，而是按 BannerType 存的**：

- STANDARD / BEGINNER / EVENT(CHARACTER/CHARACTER2) / WEAPON 各有一套 `PlayerGachaBannerInfo`
- 这意味着：同类型 banner（例如两个角色活动池）会共享保底槽位与抽数统计

### 37.3.4 定轨请求入口：`GachaWishReq`

文件：`Grasscutter/src/main/java/emu/grasscutter/server/packet/recv/HandlerGachaWishReq.java`

- 客户端用 `gachaScheduleId` + `itemId` 提交“定轨目标”
- 服务器写入：
  - `gachaInfo.wishItemId = itemId`
  - `failedChosenItemPulls = 0`

---

## 37.4 概率曲线怎么读？`weights4/weights5` = 分段线性插值（lerp）

本仓库的概率曲线不是“softPity/hardPity 两个点”，而是更通用的：  
`weightsX = [[pityPoint, weight], ...]`

权重计算在：

- `Grasscutter/src/main/java/emu/grasscutter/utils/Utils.java` 的 `lerp(int x, int[][] xyArray)`

语义：

- `x` 是“当前保底计数（pity）”
- `xyArray` 给出若干控制点，区间内做线性插值，区间外 clamp 到端点

在抽稀有度时，系统会把 `weight5 / weight4` 当作 **以 10000 为分母的概率权重** 使用（见 37.5）。

---

## 37.5 一次抽卡（单抽）的决策树：稀有度 → UP/歪 → 双池 → 定轨

核心逻辑在 `GachaSystem.doPull(...)` / `doRarePull(...)` / `doFallbackRarePull(...)`。

把实现压缩成可心算伪代码：

```text
// 1) 先把所有 pity 计数 +1（因此 pity 计算是 1-indexed）
pity4++, pity5++, pity4Pool1++, pity4Pool2++, pity5Pool1++, pity5Pool2++

// 2) 用权重曲线算“本抽的 5★/4★ 权重”
w5 = lerp(pity5, weights5)
w4 = lerp(pity4, weights4)

// 3) 以 10000 为硬上限做轮盘
roll in [0..9999]
if roll < w5: rarity=5
else if roll < w5+w4: rarity=4
else rarity=3

// 4) 若 5★/4★：处理 UP coinflip / 大保底 / 双池平衡 /（武器池）定轨
```

注意：实现里并不是直接写 roll，而是 `drawRoulette(weights, cutoff=10000)`，但等价于上述分段判断。

---

## 37.6 “歪池双池平衡”是什么？`poolBalanceWeights*` + `pity*Pool1/2`

对 4★/5★ 的“歪池”，本仓库允许配置两个池：

- `fallbackItems*Pool1`
- `fallbackItems*Pool2`

当两池都不为空时，`doFallbackRarePull(...)` 会：

1. 根据“距离上次抽中该池”计算权重：
   - `pityPool1 = lerp(pityPool1Count, poolBalanceWeights*)`
   - `pityPool2 = lerp(pityPool2Count, poolBalanceWeights*)`
2. 用一个两项轮盘选池（同样用 cutoff=10000 的机制）
3. 选中池的计数清零（`setPityPool(rarity, pool, 0)`），另一池继续累积

你可以把它理解成一种通用模块：**“类别均衡器”**。  
在不改变稀有度概率的前提下，它控制“同稀有度下的子类别产出占比”（例如 4★角色/4★武器）。

---

## 37.7 UP coinflip 与“大保底”：`eventChance*` + `failedFeatured*ItemPulls`

对 4★/5★ 的 UP 逻辑，`doRarePull(...)` 的思路是：

- `rollFeatured`：本次 coinflip 是否成功（`random(1..100) <= eventChance`）
- `pityFeatured`：上次是否歪过（`failedFeaturedItemPulls >= 1`）
- `pullFeatured = pityFeatured || rollFeatured`

结果：

- 若 `pullFeatured=true` 且 `rateUpItems*` 非空 → 从 UP 池抽
  - 并清零 `failedFeaturedItemPulls`
- 否则 → 从歪池抽
  - 并 `failedFeaturedItemPulls += 1`（确保下一次同稀有度“必 UP”）

实现细节：4★与5★分别有各自的失败计数（`failedFeatured4ItemPulls` 与 `failedFeaturedItemPulls`）。

---

## 37.8 武器池定轨（Epitomized）：`wishItemId` + `failedChosenItemPulls`

本仓库把“定轨”视为 **武器池（BannerType.WEAPON）的专属能力**：

- `GachaBanner.hasEpitomized()`：仅当 `bannerType == WEAPON` 为真
- `PlayerGachaBannerInfo` 保存：
  - `wishItemId`：定轨目标 itemId
  - `failedChosenItemPulls`：没抽到目标时的累计次数（命定值）

在 `doRarePull(...)` 中：

- 若 `failedChosenItemPulls >= wishMaxProgress` → 直接给 `wishItemId`（并清零命定值）
- 否则：
  - 抽到目标 → 命定值清零
  - 没抽到目标 → 命定值 +1

配置/交互入口：

- 客户端通过 `GachaWishReq`（`HandlerGachaWishReq`）设置 `wishItemId` 并把进度清零。

---

## 37.9 抽卡结算：入包、角色命座物品、星尘/星辉

抽到 itemId 后，`doPulls(...)` 的结算逻辑要点：

1. **写抽卡记录**：`DatabaseHelper.saveGachaRecord(new GachaRecord(itemId, uid, gachaType))`
2. **识别“武器/新角色/已有角色”**
   - `InventorySystem.checkPlayerAvatarConstellationLevel(player, itemId)` 的返回值语义（从调用点反推）：
     - `-2`：武器
     - `-1`：新角色（第一次获得）
     - `0..6`：已有角色的当前命座层数
3. **星尘/星辉发放（简化规则）**
   - 武器：按稀有度给星尘/星辉
   - 角色：
     - 新角色：标记 `isGachaItemNew=true`
     - 已有角色：
       - 满命（≥6）：给更多“安慰星辉”
       - 未满命：会额外给一个“命座道具”

### 37.9.1 “命座道具”的查找是一个潜在风险点

实现使用了一个简化假设：

- 命座道具 id ≈ `avatarItemId + 100`

代码里也明确写了注释：**未来角色不一定遵循这个规律**。  
如果你要做更严谨的自定义内容（新角色/新命座规则），这里通常是必须下潜引擎的边界之一。

### 37.9.2 `autoStripRateUpFromFallback`：避免“UP 又在歪池里”

BannerPools 构造时（`new BannerPools(banner)`）会在开关开启时：

- 从 `fallbackItems*Pool*` 中剔除所有 `rateUpItems*`

效果：你歪的时候不会再“歪到 UP”（这在做自定义池时很重要，否则玩家体验会很怪）。

### 37.9.3 `removeC6FromPool`：过滤满命角色（非原版）

如果开启：

- 会对 UP 池与歪池的所有候选 itemId 调 `removeC6FromPool(...)`
- 满命（≥6）的角色会被剔除，避免抽到“C7…”

这是一种“服务器特化型保底”，不属于典型官方逻辑，但对“做单机化/内容体验优先”的私有环境很实用。

---

## 37.10 记录页与概率详情页：HTTP 展示链路

这条链路不影响抽卡结果，但很适合你做“玩法说明/可视化”：

- `Grasscutter/src/main/java/emu/grasscutter/server/http/handlers/GachaHandler.java`
  - `/gacha`：渲染 records.html（通过 dispatch 拉记录）
  - `/gacha/details`：渲染 details.html（把当前 banner 的可出物品拼进模板）
  - `/gacha/mappings`：输出 mappings.js

同时 `GachaBanner.toProto(player)` 会把这些 URL 作为字段下发给客户端（记录/详情入口由此出现）。

---

## 37.11 “只改数据/脚本”能做什么？哪些要改引擎？

### 37.11.1 只改数据就能做（推荐优先走这条路）

- 新增/替换 banner：改 `data/Banners.json`
  - 时间、成本、UP、歪池、概率曲线、双池平衡、定轨上限
- 做“自定义概率活动”：只要你接受 `weights*` 的曲线表达方式，就能自由拼出 soft/hard pity
- 做“体验优化型规则”：例如 `removeC6FromPool`、`autoStripRateUpFromFallback`
- 做展示层：改 `data/gacha/*` 做自己的概率说明与记录页

### 37.11.2 明显的引擎边界（需要改 Java）

- 更严谨的“角色/命座道具”映射（不能依赖 `itemId+100`）
- 更复杂的 UP 规则（例如多阶段 UP、按角色池分别计数、或跨 banner 的特殊继承）
- 防作弊的服务端校验（例如更严格地验证客户端请求与 UI 状态）

---

## 37.12 小结

- 抽卡系统在本仓库是高度配置化的：`Banners.json` 几乎就是“玩法 DSL”，Java 只负责执行一个稳定的状态机。
- 概率由 `weights4/weights5` 的 lerp 曲线决定；UP 由 `eventChance*` + `failedFeatured*` 决定；双池均衡由 `poolBalanceWeights*` + `pity*Pool1/2` 决定。
- 你做魔改时，优先从“改 Banner 配置与池子内容”入手；真正要下潜引擎的点集中在“道具映射/更复杂规则/反作弊”。

---

## Revision Notes

- 2026-01-31：首次撰写本专题；梳理 `Banners.json → GachaSystem → pity/UP/定轨 → 记录页/战令触发` 的完整链路，并把权重曲线与双池均衡解释成可迁移的通用模型。

