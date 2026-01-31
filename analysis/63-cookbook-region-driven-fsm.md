# 63 内容制作 Cookbook：区域触发链（Enter/Leave Region → 阶段机 → 成功/失败重置）

本文给你一份“区域驱动玩法”的通用配方：用一个 Region 作为玩法边界（开始/失败/离场），再用 group variable 做阶段机，实现一个**可反复测试、可重置、可扩展**的内容骨架。

与其他章节关系：

- `analysis/13-event-contracts-and-scriptargs.md`：Enter/LeaveRegion 的事件契约，以及本仓库对 region trigger 的特殊匹配规则（名字很关键）。
- `analysis/12-scene-and-group-lifecycle.md`：为什么区域玩法一定要考虑 group unload/重登恢复？
- `analysis/26-entity-state-persistence.md`：变量/宝箱等“做完又刷”的根因与处理策略。

参考现成案例（本仓库就有）：

- `resources/Scripts/Scene/1/scene1_group111102013.lua`：ENTER_REGION → AddExtraGroupSuite 刷怪 → 清怪解锁宝箱

---

## 63.1 成品效果（你要做出来的东西）

一个典型“区域玩法”应当至少具备：

1. 玩家进入区域：玩法开始（刷怪/激活机关/开始计时）
2. 玩家离开区域：判失败（回滚/重置/清场）
3. 玩法完成：进入完成态（奖励、变量标记、后续不再触发或提供重置入口）

这套骨架几乎可以复用到任何内容：

- 据点遭遇战
- 占点防守（区域内坚持 N 秒）
- 机关解谜房间（离开就重置）
- 小型活动（区域内收集/计分）

---

## 63.2 关键实现细节：本仓库对 Enter/LeaveRegion 的“名字路由”

本仓库的 `SceneScriptManager` 对 `EVENT_ENTER_REGION/LEAVE_REGION` 有特殊筛选逻辑：  
它会用 trigger 的 **name 后缀** 去匹配 region config_id（而不是仅靠 groupId）。换句话说：

> 你的 trigger 名字最好写成：`ENTER_REGION_<regionConfigId>` / `LEAVE_REGION_<regionConfigId>`  
> 否则可能出现“事件发生了，但你的 trigger 永远不进候选集”的情况。

这也是为什么官方/生态脚本几乎都遵循该命名约定。

---

## 63.3 配方原理：Region 边界 + 变量阶段机

把玩法抽象成：

```
stage=0 未开始
  └─ EnterRegion → stage=1 进行中
       ├─ 完成条件达成 → stage=2 完成
       └─ LeaveRegion → stage=0 重置
```

Region 给你“边界事件”，变量给你“状态”。两者结合，就能写出高成功率的内容。

---

## 63.4 Step-by-step（最小可行版本）

### Step 1：在 group 里定义 region

在 `regions = { ... }` 里新增一个球形区域（示意）：

```lua
regions = {
  { config_id = 30001, shape = RegionShape.SPHERE, radius = 10,
    pos = { x = 100.0, y = 200.0, z = -300.0 } }
}
```

注意：

- `config_id` 在本 group 内唯一即可
- `radius` 先给大一点，避免“进了但没触发”其实是没进入

### Step 2：定义 Enter/Leave trigger（名字必须带 region id）

```lua
triggers = {
  { config_id = 40001, name = "ENTER_REGION_30001", event = EventType.EVENT_ENTER_REGION,
    condition = "condition_enter_region_30001", action = "action_enter_region_30001" },
  { config_id = 40002, name = "LEAVE_REGION_30001", event = EventType.EVENT_LEAVE_REGION,
    condition = "condition_leave_region_30001", action = "action_leave_region_30001" },
}
```

并把它们挂进 suite（至少 suite1 要包含 region 与两个 trigger）。

### Step 3：EnterRegion 的条件写法（最少两道门）

1) 确认是目标 region：`evt.param1 == regionConfigId`  
2) 区域内至少有 1 个 Avatar（防止误触）：`GetRegionEntityCount >= 1`

示意：

```lua
function condition_enter_region_30001(context, evt)
  if evt.param1 ~= 30001 then return false end
  if ScriptLib.GetRegionEntityCount(context, { region_eid = evt.source_eid, entity_type = EntityType.AVATAR }) < 1 then
    return false
  end
  -- 只允许从未开始态进入
  return ScriptLib.GetGroupVariableValue(context, "stage") == 0
end
```

### Step 4：EnterRegion 的动作：开始玩法

你可以任选一种“开始方式”：

- `AddExtraGroupSuite`：在原地叠加一套战斗/机关内容
- `GoToGroupSuite`：切换到“进行中”suite（更干净）

示意（叠加式）：

```lua
function action_enter_region_30001(context, evt)
  ScriptLib.SetGroupVariableValue(context, "stage", 1)
  ScriptLib.AddExtraGroupSuite(context, base_info.group_id, 2)
  return 0
end
```

### Step 5：LeaveRegion 的条件：只在进行中才判失败

```lua
function condition_leave_region_30001(context, evt)
  if evt.param1 ~= 30001 then return false end
  return ScriptLib.GetGroupVariableValue(context, "stage") == 1
end
```

### Step 6：LeaveRegion 的动作：重置（两种风格）

**风格 A（最简单）：RefreshGroup 到 suite1**

```lua
function action_leave_region_30001(context, evt)
  ScriptLib.SetGroupVariableValue(context, "stage", 0)
  ScriptLib.RefreshGroup(context, { group_id = base_info.group_id, suite = 1 })
  return 0
end
```

注意：本仓库的 `RefreshGroup` 有 “Kill and Respawn” 的倾向（见 ScriptLib 警告日志）。  
如果你不希望某些实体被强制清掉，考虑用风格 B。

**风格 B（更可控）：GoToGroupSuite + 手动清理**

```lua
function action_leave_region_30001(context, evt)
  ScriptLib.SetGroupVariableValue(context, "stage", 0)
  ScriptLib.GoToGroupSuite(context, base_info.group_id, 1)
  -- 如有需要：RemoveExtraGroupSuite / KillGroupEntity / 重置 gadget state
  return 0
end
```

---

## 63.5 “完成条件”怎么接进这套骨架？

你可以把“完成条件”独立成第三条链路：

- 清怪完成：`ANY_MONSTER_DIE` + `GetGroupMonsterCountByGroupId==0`
- 交互完成：`SELECT_OPTION` / `GADGET_STATE_CHANGE`
- 计时完成：`TIME_AXIS_PASS` / `TIMER_EVENT`

完成后统一进入：

- `stage=2`
- `GoToGroupSuite(settleSuite)`
- （可选）解锁宝箱/发奖励

这样你就得到一个完整的“三段式区域玩法”：进入开始 → 过程推进 → 完成结算；离开则失败重置。

---

## 63.6 常见坑与排障

1. **进入区域不触发**
   - trigger 名字没按 `ENTER_REGION_<id>` 命名（最常见）
   - region 半径太小/坐标错（先把 radius 调大验证）
2. **离开区域不触发**
   - 你实际上没有离开（球形半径过大）
   - stage 没设为 1，导致条件始终 false
3. **重置后状态异常**
   - group instance 有持久化变量/死亡记录（见 `analysis/26`）
   - `RefreshGroup` 的“kill”语义把你不想清掉的东西清了：改用 GoToGroupSuite + 手动清理

---

## 63.7 小结

- Region 玩法的成功关键在两点：**名字路由**（ENTER/LEAVE_REGION_XXX）与 **阶段变量**（stage）。
- 先做一个“进入开始、离开重置、完成结算”的骨架，再往里填具体玩法（刷怪/解谜/计分）。
- 重置策略要保守：开发期优先能重置干净；稳定后再优化为“手动精细清理”。

---

## Revision Notes

- 2026-01-31：首次撰写本配方；总结 Enter/LeaveRegion 的名字路由约定、区域边界 + 变量阶段机的通用骨架，并给出两种重置风格与排障要点。

