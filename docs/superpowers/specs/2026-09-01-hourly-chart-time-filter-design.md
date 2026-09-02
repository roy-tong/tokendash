# PRD: Hourly 图表时间范围筛选（Today / 3H / 1H）

> 状态：已批准（2026-09-02 用户确认全部开放问题：5min 节流 ✓ / tabs 写回 Settings ✓ / daemon 先行两步交付 ✓）
> 日期：2026-09-01
> 影响面：Swift 菜单栏 app（popover + Settings）+ Node daemon（blocks API + 5 个 agent parser）

## 1. 背景与问题

菜单栏 popover 的 HOURLY 图表固定展示**今天 0–23 点**、小时粒度（`HourlyChartView` 的 `chartXScale(domain: 0...23)`）。当用户想看「刚刚这会儿」的消耗节奏（比如最近一次任务的 token 波峰）时：

- 24 小时全宽视图里，最近一小时只占图表宽度的 ~4%，细节被压扁；
- 小时粒度下，当前小时的量是一个不断增长的"进行中"值，无法分辨小时内的节奏。

## 2. 目标 / 非目标

**目标**

1. HOURLY 图表支持三档时间范围：

| 档位 | 窗口 | 桶粒度 | 桶数 |
|------|------|--------|------|
| Today（现状） | 今天 00:00 → now | 1h | ≤24 |
| 3H | now−3h → now | 15min | 12 |
| 1H | now−1h → now | 5min | 12 |

2. `Settings → General` 新增 "Hourly Chart" 配置项，设定**默认**档位；
3. popover 图表头部提供三档快速切换 tabs（用户已确认：Settings 设默认 + 图表头部可切换）；
4. daemon 提供细粒度（15min / 5min）blocks 数据，全部 5 个 agent（claude / codex / opencode / openclaw / pi）一致支持。

**非目标**

- 不做自定义时间范围/自定义粒度（只有三档）；
- 不恢复 Pulse 实时速率图（`pulseEnabled` 维持 false，本次只复用其 modeTabs UI 骨架）；
- 不改 Dashboard web 端；
- 不改 7-day Trend / Usage 等其他区块。

## 3. 关键交互定义

- **单一数据源**：图表头部 tabs 与 Settings Picker 双向绑定同一个 `SettingsStore.hourlyRange`。在图表上切换 = 同时更新默认档位（免维护"临时态/默认态"两层状态，两边永不不一致）。
- **默认档位 = Today**：老用户升级后视图不变（符合既有偏好：新视图照顾性地加，默认保持老视图）。
- **3H / 1H 的窗口是滚动窗口**，可跨天（凌晨 1 点看 3H，含昨天 22:00 起）；桶边界按粒度对齐（15min 桶对齐 :00/:15/:30/:45；5min 桶对齐 :00/:05…），最后一个桶为进行中的部分时长桶。
- **切换控件风格**：沿用 `modeTabs` 现有胶囊样式（圆角 6/8、accentGreen 选中态），跨区块统一。
- **刷新节奏**：3H / 1H 档位下，popover 打开时的自动刷新节流从 30min 收紧到 **5min**（细粒度视图对数据新鲜度更敏感）；Today 档位维持现状；手动刷新按钮不受影响。

## 4. 技术方案

### 4.1 daemon 侧（数据源，必须改——现有 API 只有小时粒度）

**方案 A（推荐）：`/api/blocks` 增加可选 `granularity` 查询参数**

- `granularity ∈ {hour(缺省), 15m, 5m}`；缺省时行为与响应完全不变（向后兼容）。
- 各 parser 的 `getBlocksResponse` 接收 granularity，把小时桶 key（`getHourKey` → `yyyy-MM-ddTHH`）泛化为分钟对齐桶 key（`yyyy-MM-ddTHH:mm`，按粒度截断）。原始数据（JSONL 行、DB 事件）本就有精确时间戳，只是聚合时被截断到小时——本次只是把截断点下移。
- 缓存 key：`blocks:{agent}:{project}` → 传 granularity 时追加 `:{granularity}`；缺省不追加，**旧缓存 key 原样命中**。
- 响应结构不变（`BlockEntry[]`，`startTime` 仍是 ISO 字符串，只是分钟位不再恒为 00）。

方案 B（不推荐）：blocks 固定输出 5min 细粒度、Swift 端自行聚合出 15min/1h——daemon 改动集中但全量数据每天 288 桶，缓存与传输膨胀，Swift 聚合逻辑复杂化，且向后兼容性差。

### 4.2 Swift 侧

1. **`SettingsStore`**：新增 `HourlyRange` enum（`today / threeHours / oneHour`，label：`Today / Last 3 Hours / Last Hour`），UserDefaults key `settings.hourlyRange`，默认 `.today`。模式照抄现有 `RefreshInterval`。
2. **`SettingsView.generalCard`**：新增一行（icon `chart.xyaxis.line`，title "Hourly Chart"，右侧 menu 风格 Picker），与 Background Refresh 行视觉一致。
3. **`BadgeUpdater`**：
   - `performFullUpdate` 按当前 `hourlyRange` 请求对应 granularity 的 blocks（Today→缺省/`hour`，3H→`15m`，1H→`5m`）；
   - `computeHourly` 泛化为 `computeBuckets`：解析 `startTime` 为 `Date`，按 range 落桶；多 agent 求和逻辑不变；
   - 档位切换时（观察 `SettingsStore.hourlyRange` 变化）触发一次 detail 刷新（走缓存优先，不强制 `refresh:true`）；
   - popover 打开节流：range ≠ today 时 `popoverRefreshInterval` 生效值取 `min(30min, 5min)`。
4. **`HourBucket` 泛化** → `TimeBucket { start: Date, minutes: Int, tokens: Int, isPeak: Bool }`（id 用 `start`）。`HourBucket` 是纯 UI model，仅 Swift 内部使用，不影响 API 契约。
5. **`HourlyChartView`**：
   - 恢复/改造 `modeTabs` 为三档（Today / 3H / 1H），绑定 `settings.hourlyRange`；
   - X 轴：Today 维持 0,3,6…21 整点；3H/1H 显示 `HH:mm`，抽稀为 4 个左右标签；当前进行中的桶高亮（沿用 accentGreen）；
   - tooltip：3H/1H 显示桶起始 `HH:mm`（Today 维持 `HH:00`）；
   - 空态与图表高度不变。

### 4.3 边界情况

- **跨天窗口**：3H/1H 按绝对时间落桶，不按"今天"过滤（与 Today 的 `prefix(10) == today` 过滤不同）。
- **窗口内无数据**：显示全 0 折线（不是空态文案；空态仍仅用于 Today 全 0 的场景）。
- **旧 daemon / 参数被忽略**：Swift 端检测返回 buckets 的粒度与请求不符（分钟位全为 00 且 range 为细粒度）时，降级按 Today 渲染，不打断。
- **时区**：沿用各 parser 现有 `DEFAULT_TZ`（Asia/Shanghai）偏移逻辑，不引入新时区处理。

## 5. 测试计划

- **daemon 单测**（vitest，`src/__tests__/server/`）：
  - 各 parser：15m/5m 桶边界对齐、跨天窗口、granularity 缺省时输出与现状逐字节一致（回归保护）；
  - 路由：`granularity` 参数透传与缓存 key 区分。
- **Swift 单测**（`TokenDashTests`）：
  - `computeBuckets`：三档落桶、多 agent 求和、跨天、空数据、粒度不符降级；
  - `SettingsStore.hourlyRange` 持久化与默认值；
  - 刷新节流：细粒度档位 5min 节流生效。
- **手动验收**：Settings 切默认档、图表 tabs 切换、悬浮 tooltip、跨天时段（凌晨）目测。

## 6. 交付与发布

- 分两步交付，每步独立可测：
  1. daemon 细粒度 API + 单测（可先合入，向后兼容）；
  2. Swift 端（Settings + BadgeUpdater + 图表）+ 单测。
- 版本：minor bump（1.9.0），CHANGELOG 记录；Swift 与 daemon 随 app 一同发布。
- 按 CLAUDE.md 测试流程：每次修改后自动构建、替换 bundle 内二进制（`install_name_tool -add_rpath` + 重签）并重启 app 供验证。

## 7. 开放问题（评审时请确认）

1. 3H/1H 档位 popover 打开自动刷新节流收紧到 5min——是否接受（略增刷新频率）？
2. 图表 tabs 切换**会写回** Settings 默认档（单一数据源）——确认这个语义 OK？（替代方案：tabs 仅会话内生效，Settings 永远是启动默认。）
3. 3H/1H 的空窗口（无任何用量）显示 0 折线而非空态文案——确认 OK？
