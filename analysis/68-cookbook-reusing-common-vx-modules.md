# 68 内容制作 Cookbook：复用 Common/Vx_y 模块（注入式玩法组件库的实例化流程）

本文是一份“如何把 Common/Vx_y 当玩法组件库来用”的实操配方：  
你不是从零写一个复杂活动，而是**挑一个模块**（CoinCollect/平台/计分/机关套件…），再写一个 group 脚本当“实例配置”，把模块注入到你的关卡里。

与其他章节关系：

- `analysis/11-activities-deep-dive.md`：Common/Vx_y 注入式模块范式的整体心智模型。
- `analysis/14-scriptlib-api-coverage.md`：模块能不能跑，关键看 ScriptLib 覆盖度。
- `analysis/60-content-authoring-cookbook-overview.md`：fastRequire 与脚本缓存等工程细节（本配方会点名一个特别重要的坑）。

参考现成案例：

- `resources/Scripts/Scene/1/scene1_group111102094.lua`：一个 CoinCollect 的实例化 group（defs/defs_miscs + gadgets/regions map 形状 + require）
- `resources/Scripts/Common/V3_3/CoinCollect.lua`：模块本体（头部注释给 defs 模板，底部执行注入）

---

## 68.1 先讲清“模块实例化”的本质

Common 模块通常不是提供一个 `return {}` 的库，而是：

1. group 脚本先定义好 `base_info/triggers/suites/variables/gadgets/regions/defs/defs_miscs`
2. `require "Vx_y/SomeModule"`
3. 模块在加载时执行，把 `extraTriggers/extraVariables` 注入到这些表里
4. 模块最后往往会直接调用初始化函数，例如：
   - `LF_Initialize_Group(triggers, suites, variables, gadgets, regions)`

因此 group 脚本更像“Prefab Instance Config”，模块更像“可复用行为组件”。

---

## 68.2 一个最隐蔽但致命的工程前提：`server.fastRequire` 必须匹配你的脚本写法

本仓库的 `config.json` 里：

- `server.fastRequire` 当前为 `false`

这件事会直接影响 Common 模块是否能正常拿到 `defs/defs_miscs`：

### 当 `fastRequire=false`（本仓库默认）

ScriptLoader 会把 `require "Vx_y/Module"` 这种行**预处理为“把模块源码直接拼进当前脚本”**。  
结果：模块代码和 group 脚本属于**同一个 Lua chunk**，因此模块能访问 group 里写的 `local defs/local defs_miscs`。

### 当 `fastRequire=true`

require 会作为独立脚本执行（不同 chunk），它**访问不到 group 脚本的 local 变量**。  
结果：大量现成 group 脚本会直接失效（因为它们把 defs 写成 `local`）。

内容制作结论：

- 你要复用现成生态脚本 → **保持 `fastRequire=false`** 最省事
- 你未来想开 `fastRequire=true` 做性能/工程优化 → 需要把 defs/defs_miscs 改成全局（不要 local），或重构模块接口

---

## 68.3 Step-by-step：复用一个 Common 模块（以 CoinCollect 为例）

### Step 1：选模块并读它的“输入契约”

打开 `resources/Scripts/Common/Vx_y/<Module>.lua`：

- 先看头部注释：一般会给出 `defs/defs_miscs` 模板
- 再快速扫一遍它如何访问：
  - `gadgets` 是 `gadgets[configId]` 还是 `gadgets[i]`？
  - `suites[1]` 是否被强依赖？
  - 是否会往 `regions[defs.xxx]` 写字段？

这一步决定你 group 脚本的数据结构必须长什么样。

### Step 2：审计 ScriptLib 依赖（决定“能不能跑”）

模块里通常会大量调用 `ScriptLib.*`。做自制内容前建议你做一次“快速审计”：

1. grep 模块里的 `ScriptLib.` 调用清单
2. 对照 `analysis/14-scriptlib-api-coverage.md` 看这些函数是否实现

如果模块依赖了大量 `unimplemented` 函数：

- 选另一个模块（最快）
- 或接受“只有部分逻辑有效”
- 或下潜引擎补齐缺口（见 `analysis/04` 的边界判断）

### Step 3：写 group 脚本（实例配置）

以 `resources/Scripts/Scene/1/scene1_group111102094.lua` 为模板，你至少要提供：

1) `base_info = { group_id = ... }`  
2) `local defs = { ... }`  
3) `local defs_miscs = { ... }`  
4) `gadgets/regions` 的“表形状”对齐模块要求（CoinCollect 要求 map 形状）  
5) `init_config/suites/triggers/variables`（让模块能注入到 suite1）

CoinCollect 实例的关键点：

- `gadgets`/`regions` 用 map 形态：
  - `gadgets = { [94001] = {config_id=94001,...}, ... }`
- suite1 的 `gadgets` 列表仍然写 config_id 数组：
  - `gadgets = { 94001, 94002, ... }`

### Step 4：require 模块（注入发生点）

把 require 放在 group 脚本的“触发器区域”末尾（一般文件底部）：

```lua
require "V3_3/CoinCollect"
```

这样模块执行时能看到 group 已经定义好的表，并把 triggers/variables 注入进去。

### Step 5：挂载到场景并测试

1) 把 group 挂进 block（`scene*_block*.lua`）  
2) 重启服务器（脚本缓存）  
3) 传送到该点位，观察模块是否起效  

建议用 `/quest grouptriggers <groupId>` 看注入后的 triggers 是否存在（如果没有，说明 require/注入根本没跑）。

---

## 68.4 常见坑与排障（模块复用里最常见的 6 个）

1. **模块完全没生效**
   - `fastRequire=true` 导致模块拿不到 `local defs` → 直接报错或静默失效
2. **gadgets/regions 形状不匹配**
   - 模块写 `gadgets[configId]`，你却给了数组 → 运行时报 nil
3. **模块假设 suite1 存在**
   - 你 `init_config.suite` 不是 1，或 suites[1] 没有 triggers 列表可插入
4. **模块依赖未实现 ScriptLib**
   - 典型：`SetTeamServerGlobalValue` 这类函数在 ScriptLib 里仍是 TODO  
     → 你会看到日志 warn，模块逻辑可能无法完整运行
5. **动态 group 卸载与 gallery/模块生命周期冲突**
   - 一些模块明确注释“GROUP_WILL_UNLOAD 是保底清理点”  
     → 说明它们已经在对抗运行时卸载顺序了，别轻易改生命周期
6. **改了模块/实例脚本但没生效**
   - ScriptLoader 缓存：重启服务器（见 `analysis/60`）

---

## 68.5 小结

- Common/Vx_y 的正确用法是“实例配置 + 模块注入”，不是把逻辑复制到每个 group。
- 复用的关键在三件事：**输入契约（defs/表形状）**、**ScriptLib 覆盖度**、**fastRequire 模式**。
- 你可以把它当作“玩法组件库”，把 group 脚本当作“玩法 prefab 实例”来规模化制作内容。

---

## Revision Notes

- 2026-01-31：首次撰写本配方；强调 fastRequire 对模块可用性的决定性影响，给出模块输入契约/ScriptLib 审计/实例化步骤与常见排障清单。

