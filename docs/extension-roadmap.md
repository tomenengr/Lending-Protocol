# Aave + Compound III 混合扩展路线图

当前项目已经覆盖了借贷协议的最小风险链路，但如果作为找工作的项目经历，还可以继续扩成一个更有工程含量的 “Aave 风险模型 + Compound III 单一 base asset 架构”。

核心判断：不要把项目扩成完整 Aave，也不要把项目扩成完整 Compound。更好的方向是保留单一借款资产，让风险模型、利息模型、清算模型和测试体系逐步变强。

## 当前版本定位

当前版本已经有：

- Aave 风格健康因子。
- Aave 风格 liquidation threshold 和 liquidation bonus。
- Compound III 风格单一借款资产 MockUSDC。
- 多抵押资产 WETH/WBTC。
- 价格预言机、close factor、unit/fuzz/invariant 测试。

当前已经完成：

- USDC 供应池。
- `supplyBase` / `withdrawBase`。
- base asset liquidity accounting。
- `borrowIndex` / `supplyIndex` 利息累计。
- utilization-based kink rate model。
- reserve factor 和 `protocolReservesUSDC`。

当前仍缺少：

- bad debt accounting。
- Compound III 风格 absorb / buyCollateral 清算流程。
- 风险参数 cap 和 isolation mode。

## 建议扩展顺序

### V1.1：供应池和 base asset 会计

状态：已完成。

目标：让 MockUSDC 不再只是协议预先 mint 的资金，而是由 lender 存入。

新增接口：

```solidity
function supplyBase(uint256 amountUSDC) external;
function withdrawBase(uint256 amountUSDC) external;
function getUtilization() external view returns (uint256);
```

新增状态：

```solidity
mapping(address user => uint256 amount) public suppliedUSDC;
uint256 public totalSuppliedUSDC;
uint256 public totalBorrowedUSDC;
```

要讲清楚的问题：

- lender 存入 USDC 后，borrower 才能借出 USDC。
- utilization = total borrowed / total supplied。
- withdraw base 时必须保证协议仍有足够流动性。

测试重点：

- 供应者存入和取回 USDC。
- borrower 不能借超过池子可用流动性。
- total supplied / total borrowed / token balance 三者关系正确。

### V1.2：Compound 风格 borrow index

状态：已完成。

目标：引入利息累计，让债务随时间增长。

新增状态：

```solidity
uint256 public borrowIndex = 1e18;
uint256 public supplyIndex = 1e18;
uint256 public lastAccrualTimestamp;
```

用户债务和供应份额已经改成 principal/index 结构：

```solidity
mapping(address user => uint256 principal) private _borrowPrincipal;
mapping(address user => uint256 principal) private _baseSupplyPrincipal;
```

要讲清楚的问题：

- 为什么不逐个用户循环更新利息。
- 为什么使用全局 index。
- borrower 的实际债务如何从 principal 和 index 计算出来。

测试重点：

- 时间推进后债务增加。
- repay 时先结算利息。
- borrow index 单调递增。
- fuzz 测试长期时间跨度下不会出现明显 rounding 错误。

### V1.3：动态利率模型

状态：已完成。

目标：让利率跟 utilization 相关。

当前实现使用 kink model。低于 kink 时利率平缓上升，高于 kink 后高斜率惩罚高利用率：

```text
utilization <= kink:
    rate = base + utilization * slopeLow
utilization > kink:
    rate = base + kink * slopeLow + (utilization - kink) * slopeHigh
```

第一版把参数放在 `MiniLending.sol` 里作为常量，避免过早引入治理和管理员权限。后续如果要更贴近生产协议，可以拆成单独 `InterestRateModel.sol`，并把参数调整流程交给 timelock/governance。

### V1.4：协议储备金和坏账处理

状态：已完成。Reserve factor、reserve withdraw、bad debt accounting 和 bad debt recapitalization 都已完成。

目标：从“能清算”升级成“协议能处理坏账”。

已新增状态：

```solidity
uint256 public protocolReservesUSDC;
uint256 public constant RESERVE_FACTOR_BPS = 1_000;
```

利息的一部分进入协议储备：

```text
borrowInterest = userDebtIncrease
reserveIncrease = borrowInterest * RESERVE_FACTOR_BPS / 10000
supplierInterest = borrowInterest - reserveIncrease
```

要讲清楚的问题：

- reserve 是协议吸收坏账的第一层缓冲。
- reserve withdraw 只能提取已经落账且有现金支持的储备金。
- recapitalization 允许外部资金注入 USDC，降低已记录坏账。
- 如果抵押品暴跌，清算奖励可能不足以覆盖全部债务。
- bad debt 应该被记录，而不是静默忽略。

### V1.5：Compound III 风格 absorb / buyCollateral

状态：已完成。

项目现在同时保留 Aave 风格直接清算和 Compound III 风格两阶段清算。直接清算适合解释 health factor、close factor 和 liquidation bonus；两阶段清算适合解释协议账本、抵押品库存和坏账。

```text
1. absorb(borrower)
   协议把不健康账户的债务和抵押品吸收到协议账本。

2. buyCollateral(asset, baseAmount)
   清算人用 base asset 从协议买入折价抵押品。
```

可以设计：

```solidity
function absorb(address borrower) external;
function buyCollateral(address asset, uint256 baseAmount, uint256 minCollateralAmount) external;
```

新增状态：

```solidity
mapping(address asset => uint256 amount) public protocolCollateralBalance;
uint256 public badDebtUSDC;
```

要讲清楚的问题：

- absorb 和 buyCollateral 解耦后，清算人不一定直接面对 borrower。
- 协议先承担账户风险，再通过出售抵押品补充 base reserves。
- 这会更接近真实协议的工程流程，但实现复杂度明显更高。

测试重点：

- 健康账户不能 absorb。
- absorb 后 borrower debt 归零，collateral 归零或转入 protocolCollateral。
- badDebtUSDC 正确记录。
- buyCollateral 按折扣价格出售协议抵押品。
- 买入时使用 `minCollateralAmount` 防止价格或 rounding 导致滑点。

### V1.6：Aave 风格高级风险控制

状态：大部分完成。Supply cap、global borrow cap、isolation mode、全局 pause、资产 freeze 和 price heartbeat 已完成。

已完成：

- supply cap：限制每种抵押品总供应量。
- global borrow cap：限制 base asset 总借款量。
- isolation mode：高风险抵押品不能和其他抵押品混用，并且只能借到固定 debt ceiling。
- pause：协议级异常时暂停新增风险和资金流出。
- freeze：单个抵押品异常时冻结该资产的新风险敞口。
- price heartbeat：对不同资产设置更细的价格更新窗口。

还可以逐步加：

- eMode：相关性强的资产使用更高 collateral factor。
- 更完整的参数治理延迟和多签流程。

下一步建议优先做 auction。它能补齐风险管理里的“抵押品处置”和“坏账回收效率”两个常见面试追问点。

### V1.7：Keeper 和 fork test

新增 keeper 脚本：

```text
读取一组 borrower
调用 getHealthFactor
如果 HF < 1，执行 liquidate 或 absorb
```

新增 fork test：

- 读取 Sepolia 或主网 Chainlink feed。
- 验证不同 feed decimals。
- 验证 stale price 配置。

这部分可以提升项目“像真实工程”的感觉，但不要在核心协议不稳定时过早做。

## 简历上怎么讲

推荐表述：

> 基于 Solidity 和 Foundry 实现 Aave 风格风险模型与 Compound III 风格单一借款资产架构的迷你借贷协议，支持多抵押资产、MockUSDC 供应池、MockUSDC 借款、健康因子、预言机定价、按资产配置 price heartbeat、borrow/supply index、utilization kink rate、supply cap、global borrow cap、isolation mode、pause/freeze 应急控制、协议储备金提取、close factor、直接清算、absorb/buyCollateral 两阶段清算、坏账记录与再资本化、unit/fuzz/invariant 测试。

面试时重点讲：

- 为什么选择单一借款资产。
- collateral factor 和 liquidation threshold 的区别。
- 为什么健康因子用 liquidation threshold，而 borrow limit 用 collateral factor。
- 为什么 oracle decimals 和 token decimals 必须分开处理。
- 为什么 close factor 能降低一次性清算冲击。
- 如果扩展到 borrow index，为什么不能循环更新所有用户。

## 不建议优先做的功能

- 完整 Aave 多资产互借。
- aToken/cToken 完整实现。
- 闪电贷。
- 治理系统。
- 可升级代理。
- 复杂前端。

这些功能不是没价值，而是会稀释项目重点。对找工作项目来说，风险模型、利息模型、清算模型、测试体系和文档更有性价比。
