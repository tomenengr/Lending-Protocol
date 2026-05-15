# 审计备注

这个项目是教学和简历展示级别的 mini protocol，但核心借贷风险已经在代码和测试里显式处理。

## 已检查性质

### 静态分析

- 已运行 `slither .`。
- 已根据 Slither 结果补充 ownership / updater / price update 事件。
- 已将 `MiniLending` 的 `oracle` 和 `riskEngine` 标记为 `immutable`。
- 已缓存用户抵押资产遍历中的数组长度。
- 已补充 Chainlink round 完整性检查：`answeredInRound >= roundId`、`startedAt <= updatedAt`、`updatedAt <= block.timestamp`。
- 剩余 Slither 告警主要是设计性提示：固定精度整数运算中的先除后乘、严格等于零判断、对有限 collateral assets 数组的外部只读调用、timestamp 用于利息和 oracle freshness、以及 ERC20 transfer 后 emit 事件的 reentrancy-events 提示。
- 当前未发现会直接导致资金被盗或账本失衡的高危问题；生产化版本仍应加入 `ReentrancyGuard`、真实 token 兼容性处理和更严格的 oracle / governance 保护。

### Oracle 安全

- 拒绝缺失 feed。
- 拒绝零价格和负价格。
- 拒绝 stale price。
- 拒绝未来 `updatedAt` 时间戳。
- 将不同 feed decimals 统一转换成 18 位精度。
- 支持全局默认 stale period。
- 支持按资产配置 heartbeat override。
- 单资产 heartbeat 可以比默认值更短或更长，测试覆盖两种路径。

### 借款安全

- 用户不能无抵押借款。
- 用户不能超过 collateral factor 对应的最大可借额度。
- 用户不能借出超过 base asset pool 可用流动性的 MockUSDC。
- 用户不能让协议总借款超过 `GLOBAL_BORROW_CAP_USDC`。
- borrow 和 withdraw 都要求操作后的健康因子大于等于 `1e18`。

### 风险上限安全

- `depositCollateral` 会检查资产级 supply cap。
- `withdrawCollateral`、`liquidate` 和 `absorb` 会同步减少用户抵押品的 `totalCollateral` 统计。
- `absorb` 转入协议账本的抵押品不再占用用户侧 supply cap。
- `borrow` 会检查协议级 borrow cap。
- WBTC isolation mode 会阻止 WBTC 和 WETH 混合作为同一账户抵押品。
- WBTC 的可借额度会被 20,000 USD debt ceiling 截断。

### 应急控制安全

- 只有 owner 可以设置全局 pause 和资产 freeze。
- pause 会阻止新增抵押、供应、赎回、借款和购买协议抵押品。
- pause 不阻止 `repay`、`liquidate` 和 `absorb`，因此紧急状态下仍能降低债务和处理不健康仓位。
- asset freeze 会阻止冻结资产的新抵押和基于冻结资产的新增借款。
- asset freeze 不阻止还款、赎回和清算，避免冻结后用户无法降低风险。

### 供应池和利息安全

- `supplyBase` 使用 supply principal 和 `supplyIndex` 记录供应者余额。
- `borrow` 使用 borrow principal 和 `borrowIndex` 记录债务。
- 利息累计更新全局 index，不遍历用户。
- 借款利率由 utilization-based kink model 决定。
- 10% 借款利息进入 `protocolReservesUSDC`。
- `withdrawBase` 检查用户供应余额和协议可用流动性。
- `getAvailableLiquidity` 会扣除协议储备金，避免供应者取走 reserve。
- `withdrawReserves` 只能由 owner 调用。
- `withdrawReserves` 只能提取已经落账的 `protocolReservesUSDC`。
- `withdrawReserves` 要求协议实际 USDC cash 足够，避免提取尚未回流的账面储备金。
- 提取储备金会同步减少 reserve accounting 和 USDC cash，因此不会降低供应者可用流动性。
- 债务视图 `debtUSDC(user)` 会包含尚未落账的 pending interest。

### 清算安全

- 健康仓位不能被清算。
- close factor 将单次清算限制在当前债务的 50%。
- liquidation bonus 会加到清算人可拿走的抵押品价值里。
- 如果 borrower 选择的抵押品不足以支付清算奖励，清算会 revert。
- `absorb` 只能处理健康因子低于 `1e18` 的账户。
- `absorb` 会把 borrower 债务清零，并把 borrower 抵押品转入 `protocolCollateralBalance`。
- `badDebtUSDC` 使用折价可回收价值计算，并优先由 `protocolReservesUSDC` 抵扣。
- `recapitalizeBadDebt` 是 permissionless 的，任何地址都可以用 MockUSDC 降低坏账。
- `recapitalizeBadDebt` 最多只扣除当前 `badDebtUSDC`，多传金额不会被多收。
- `buyCollateral` 使用 `minCollateralAmount` 做滑点保护。

### 账本安全

Invariant 测试检查：

- 记录的 WETH 抵押品总和等于协议实际持有的 WETH。
- 记录的 WBTC 抵押品总和等于协议实际持有的 WBTC。
- 用户抵押品合计等于 `totalCollateral`。
- 用户抵押品和协议持有抵押品的合计等于协议实际 token balance。
- base pool 的 cash + borrowed 至少覆盖 total supplied。
- base pool 的 cash + borrowed 至少覆盖 total supplied + protocol reserves。
- 如果 absorb 后出现 shortfall，shortfall 不能超过已记录的 `badDebtUSDC`。
- 用户债务总和等于 handler ghost debt。
- 成功 borrow 和 withdraw 后，账户不会低于健康因子。
- 成功清算永远不会发生在健康账户上。

## 已知限制

- 没有抵押品 auction 管理流程。
- 没有接入真实 Chainlink feed 地址。
- 没有 governance timelock。当前 owner 权限适合项目展示，不适合作为生产治理模型。
- 没有 reentrancy guard。当前 mock ERC20 不会 callback，但生产级集成应该加。
- 单次清算只能选择一种抵押资产。
- 没有针对深度资不抵债账户的动态 close factor。

## 有意简化

债务只使用 MockUSDC 计价。这样可以避免多债务资产的加权计算，让健康因子逻辑聚焦在抵押资产风险和 base asset pool 会计上。

Oracle 是 Chainlink-style mock。这样测试是确定性的，同时仍然覆盖 feed decimals、stale price、asset heartbeat 和 invalid price。

`lock()` 函数用于在 invariant 测试和固定参数部署场景里冻结管理面。它不是生产级治理方案，生产环境应该使用 timelock、多签和完整权限管理。

## 后续审计重点

如果继续扩展，审计重点应该跟着模块变化：

- 扩展 auction 后，重点看折价报价、清算人套利、坏账边界和抵押品处置效率。
- 加真实 oracle 后，重点看 stale period、feed decimals、sequencer uptime 和异常价格保护。
