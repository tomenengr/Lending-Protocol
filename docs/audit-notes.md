# 审计备注

项目定位是教学和简历展示级 mini protocol，但核心借贷风险已经在代码和测试里显式处理。

## 已检查内容

### 静态分析

已运行 `slither .`，并根据结果补充：

- ownership / updater / price update 事件。
- `MiniLending` 依赖合约的 `immutable` 标记。
- Chainlink round 完整性检查：`answeredInRound >= roundId`、`startedAt <= updatedAt`、`updatedAt <= block.timestamp`。
- `src/logic/` 和 `src/libraries/` 分层，区分 stateful logic 与 stateless library。

剩余 Slither 提示主要是设计性风险：定点数取整、timestamp 用于利息和 oracle freshness、有限抵押资产数组循环、ERC20 transfer 后 emit event 的 reentrancy-events 提示。

### Oracle

- 拒绝缺失 feed、零价格、负价格、未来时间戳和 stale price。
- 将不同 feed decimals 统一转换为 1e18。
- 支持默认 stale period 和单资产 heartbeat。

### 借款和风险上限

- 无抵押不能借款。
- 借款不能超过 collateral factor、可用流动性和 global borrow cap。
- Borrow / withdraw 后健康因子必须大于等于 `1e18`。
- Supply cap 限制单资产协议级敞口。
- WBTC isolation mode 限制混合抵押和最大 debt ceiling。

### Pause / Freeze

- 只有 owner 可以设置 pause 和 asset freeze。
- pause 阻止新增风险和资金流出，但允许 `repay`、`liquidate`、`absorb`。
- freeze 阻止冻结资产新增抵押和继续支持新增借款，但允许还款、赎回和清算。

### 利息和账本

- 借款和供应使用 principal + index，不遍历用户。
- `getAvailableLiquidity()` 扣除 `protocolReservesUsdc`，避免供应者取走协议储备金。
- `withdrawReserves` 只能提取已落账且有实际 USDC cash 支持的储备金。
- `debtUsdc(user)` 包含尚未落账的 pending interest。

### 清算和坏账

- 健康仓位不能被清算或 absorb。
- close factor 限制单次清算规模。
- liquidation bonus 计入清算人可拿走的抵押品。
- `absorb` 会把 borrower 债务清零，并把抵押品转入协议账本。
- 折价可回收价值不足以覆盖债务时，协议先用 reserves，再记录 `badDebtUsdc`。
- `recapitalizeBadDebt` 是 permissionless，且最多只收当前坏账金额。
- `buyCollateral` 使用 `minCollateralAmount` 做滑点保护。

## Invariant

Invariant 测试覆盖：

- 用户抵押品合计等于 `totalCollateral`。
- 用户抵押品和协议抵押品合计等于协议实际 token balance。
- base pool cash + borrowed 覆盖供应者 claim 和协议 reserve。
- 用户债务账本与 handler ghost debt 一致。
- 成功 borrow / withdraw 后账户不会低于健康因子。
- 健康账户不能被成功清算。
- shortfall 不超过已记录的 `badDebtUsdc`。

## 已知限制

- 未接入真实 Chainlink feed、sequencer uptime feed 或治理 timelock。
- 未加入 `ReentrancyGuard`；当前 mock ERC20 不会 callback，生产版本应补上。
- 单次直接清算只选择一种抵押资产。
- 没有 auction、动态 close factor、多借款资产和真实 token 兼容性处理。

## 后续审计重点

- 接入真实 oracle 后，重点审查 stale period、feed decimals、sequencer、异常价格和 fallback 行为。
- 加入 auction 后，重点审查折价曲线、坏账边界和抵押品处置效率。
- 引入治理后，重点审查权限、timelock、参数变更延迟和紧急暂停流程。
