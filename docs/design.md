# 设计说明

Mini Lending Protocol 是一个迷你超额抵押借贷协议。设计目标不是做完整 Aave clone 或 Compound clone，而是组合两者适合简历项目展示的核心思想：

- Aave：健康因子、加权清算阈值、清算奖励、清算人无许可参与。
- Compound III：多个抵押资产只借一种 base asset，本项目里的 base asset 是 MockUSDC。

这种设计可以让项目保持足够小，同时覆盖借贷协议最关键的风险链路：抵押、借款、价格变化、健康因子下降、清算、账实一致。

## 范围

支持资产：

| 角色 | 资产 |
| --- | --- |
| 抵押资产 | MockWETH, MockWBTC |
| 借款资产 | MockUSDC |
| 价格来源 | Mock Chainlink-style feeds |

支持操作：

- `depositCollateral`
- `withdrawCollateral`
- `borrow`
- `repay`
- `liquidate`
- `absorb`
- `buyCollateral`
- `getHealthFactor`
- `getAccountData`

当前版本已经包含 USDC base asset pool、基于 index 的利息累计、utilization-based kink rate model、supply cap、global borrow cap、isolation mode、全局 pause、资产 freeze、协议储备金、坏账记录，以及 Compound III 风格的 `absorb / buyCollateral` 两阶段清算路径。但仍有意不做多借款资产、aToken/cToken、闪电贷、治理、可升级代理和前端。项目重点是把风险控制主链路、资金池会计、利息累计和清算账务做完整、测清楚、讲明白。

## 合约分层

### MiniLending

主合约，负责用户状态和资金流转。

- 记录用户每种抵押资产的余额。
- 只记录 MockUSDC 债务。
- 通过 `supplyBase` 和 `withdrawBase` 维护 MockUSDC 供应池。
- 使用 `borrowIndex` 和 `supplyIndex` 做利息累计。
- 根据资金利用率计算 kink borrow rate。
- 把 10% 借款利息计入协议储备金。
- 记录每种抵押资产的 `totalCollateral`，并执行 supply cap。
- 执行协议级 `GLOBAL_BORROW_CAP_USDC`，限制总借款规模。
- 对 WBTC 执行 isolation mode：不能混用其他抵押品，且可借额度受 debt ceiling 限制。
- 支持全局 pause，暂停新增抵押、供应、赎回、借款和协议抵押品购买。
- 支持单资产 freeze，阻止冻结资产继续新增抵押或继续支持新增借款。
- 借款时检查 collateral factor 和健康因子。
- 赎回抵押品时检查赎回后的健康因子。
- 当健康因子低于 `1e18` 时允许第三方清算。
- 支持 `absorb`，把不健康账户的债务清零并把抵押品转入协议账本。
- 支持 `buyCollateral`，让第三方用 MockUSDC 折价购买协议持有的抵押品。
- 记录 `badDebtUSDC`，并优先使用 `protocolReservesUSDC` 吸收坏账。

### PriceOracle

将资产映射到 Chainlink 风格 price feed，并把不同 feed 小数位统一转换成 18 位精度。

例子：

```text
ETH/USD feed answer = 3000e8
内部价格 = 3000e18
```

Oracle 会拒绝缺失价格、零价格、负价格、未来时间戳价格和 stale price。`stalePeriod` 是默认价格有效期，`setAssetHeartbeat(asset, heartbeat)` 可以为单个资产设置更短或更长的 heartbeat override。

### RiskEngine

保存资产风险参数并负责风险计算。

- 根据 collateral factor 计算可借额度。
- 根据 liquidation threshold 计算健康因子分子。
- 根据 liquidation bonus 计算清算可拿走的抵押品数量。
- 保存每个抵押资产的 supply cap。
- 保存每个抵押资产的 isolation flag 和 debt ceiling。

`RiskEngine` 不转账、不记录用户余额，只做风险参数和数学计算。

## 精度模型

| 数值 | 精度 |
| --- | --- |
| WETH 数量 | 18 token decimals |
| WBTC 数量 | 8 token decimals |
| USDC 数量 | 6 token decimals |
| Oracle 价格 | 统一转换成 1e18 |
| USD 价值 | 1e18 |
| 健康因子 | 1e18 |

抵押品 USD 价值：

```text
tokenAmount * priceE18 / 10 ** tokenDecimals
```

USDC 债务 USD 价值：

```text
usdcAmount * usdcPriceE18 / 10 ** 6
```

## 健康因子

```text
healthFactor = adjustedCollateralUsd * 1e18 / debtUsd
```

其中：

```text
adjustedCollateralUsd = sum(collateralValueUsd * liquidationThresholdBps / 10000)
```

如果 `debtUsd == 0`，健康因子返回 `type(uint256).max`，表示账户没有债务风险。

## 借款路径

借款使用 collateral factor。Collateral factor 通常低于 liquidation threshold，因此用户借到最大额度后仍然有一段缓冲。

```text
borrowableUsd = sum(collateralValueUsd * collateralFactorBps / 10000)
```

借款成功条件：

- 借款数量非零。
- 协议有足够 MockUSDC 可用流动性。
- 协议总借款不能超过 `GLOBAL_BORROW_CAP_USDC`。
- 新债务价值不能超过可借额度。
- 借款后的健康因子必须大于等于 `1e18`。
- 借款 principal 会按当前 `borrowIndex` 记录。

## 风险上限

Supply cap 控制单一抵押资产进入协议的总量：

```text
totalCollateral[asset] + depositAmount <= riskConfig.supplyCap
```

`totalCollateral` 只统计用户抵押品。直接清算会减少 `totalCollateral`，`absorb` 会把用户抵押品移入 `protocolCollateralBalance`，因此也会释放用户抵押品 supply cap 占用。

Global borrow cap 控制 base asset 总债务规模：

```text
totalBorrowedUSDC + borrowAmount <= GLOBAL_BORROW_CAP_USDC
```

这两个参数不替代 health factor，而是补充协议级风险约束：health factor 约束单个账户，cap 约束协议整体敞口。

Isolation mode 控制高风险抵押品的账户级组合方式。当前 WBTC 是 isolated collateral：

```text
RiskConfig({
    isolated: true,
    debtCeilingUsd: 20_000e18
})
```

规则：

```text
如果账户已经有 WBTC 抵押，不能再存入 WETH
如果账户已经有 WETH 抵押，不能再存入 WBTC
如果账户只使用 WBTC，borrowableUsd = min(wbtcBorrowableUsd, debtCeilingUsd)
```

这和 health factor 的作用不同：health factor 判断账户是否健康，isolation mode 限制高风险资产可以产生的最大债务规模。

## 应急控制

`MiniLending` 自带 owner 管理的两类应急开关：

```text
setPaused(bool)
setAssetFrozen(asset, bool)
```

全局 pause 适合协议级异常，例如 oracle 异常、资金池会计异常或正在处理的安全事件。pause 后会阻止：

- `depositCollateral`
- `supplyBase`
- `withdrawBase`
- `withdrawCollateral`
- `borrow`
- `buyCollateral`

pause 不阻止 `repay`、`liquidate` 和 `absorb`。这些操作会降低用户债务或处理不健康账户，属于风险收敛路径。

资产 freeze 适合单个抵押品出现风险，例如资产脱锚、流动性明显下降或价格源异常。freeze 后：

- 不能继续存入该资产作为新抵押品。
- 如果账户持有冻结资产抵押品，不能继续借出新的 USDC。
- 仍然允许还款、赎回抵押品和清算。

这套设计不是完整治理系统，但足够展示真实借贷协议里常见的“全局停机”和“单资产降风险”控制面。

## USDC 供应池

MockUSDC 是协议的 base asset。供应者通过 `supplyBase` 把 USDC 存入协议，borrower 从这部分流动性中借出 USDC。

供应者余额不是直接累加的普通 mapping，而是通过 principal 和 index 计算：

```text
suppliedUSDC(user) = userSupplyPrincipal * currentSupplyIndex / 1e18
```

这样做的好处是，利息累计时只需要更新全局 `supplyIndex`，不需要遍历所有供应者。

`withdrawBase` 会同时检查：

- 用户当前供应余额是否足够。
- 协议当前 USDC cash 是否足够。

如果大部分 USDC 已经被 borrower 借出，供应者可能暂时不能全部赎回，这符合资金池流动性约束。

## 利息累计

债务通过 `borrowIndex` 累计：

```text
debtUSDC(user) = userBorrowPrincipal * currentBorrowIndex / 1e18
```

当前版本使用 utilization-based kink rate model。每次状态变更前调用 `accrueInterest()`：

```text
borrowRate = f(storedUtilization)
newBorrowIndex = borrowIndex + borrowIndex * borrowRate * elapsed / 1e18
interestAccrued = totalBorrowPrincipal * (newBorrowIndex - borrowIndex) / 1e18
reserveInterest = interestAccrued * reserveFactor / 10000
supplierInterest = interestAccrued - reserveInterest
newSupplyIndex = supplyIndex + supplierInterest * 1e18 / totalSupplyPrincipal
```

利率曲线：

```text
utilization <= kink:
    rate = baseRate + utilization * slopeLow
utilization > kink:
    rate = baseRate + kink * slopeLow + (utilization - kink) * slopeHigh
```

当前参数：

```text
base APR ~= 2%
low slope APR ~= 8%
kink utilization = 80%
high slope APR ~= 100%
reserve factor = 10%
```

## 清算路径

清算是无许可的，但只能对不健康账户执行。

### 直接清算

清算人偿还 MockUSDC，并获得带奖励的抵押品：

```text
seizeValueUsd = repayValueUsd * (10000 + liquidationBonusBps) / 10000
seizeAmount = seizeValueUsd * 10 ** collateralDecimals / collateralPriceE18
```

当前版本使用 50% close factor。如果清算人传入的 repay amount 超过上限，协议会自动 cap 到当前债务的 50%，并在事件里记录实际还款额和实际拿走的抵押品数量。

### 协议吸收再出售

`absorb` 和 `buyCollateral` 是另一条更接近 Compound III 的路径：

```text
absorb(borrower)
    borrower debt -> 0
    borrower collateral -> protocolCollateralBalance
    bad debt -> protocolReservesUSDC first, then badDebtUSDC

buyCollateral(asset, amountUSDC, minCollateralAmount)
    buyer pays MockUSDC
    buyer receives discounted protocol collateral
```

坏账不是用抵押品市场价值直接计算，而是用折价可回收价值计算。原因是协议后续会把抵押品按 liquidation bonus 对外出售：

```text
discountedCollateralValue = collateralMarketValue * 10000 / (10000 + liquidationBonusBps)
badDebt = max(debtValue - discountedCollateralValue, 0)
```

这能更真实地反映协议在清算折扣下可能承担的经济损失。

## 测试策略

测试按行为拆分：

- Unit tests：oracle、price heartbeat、deposit、supply、borrow、repay、withdraw、liquidation、absorb、buyCollateral、caps、isolation、pause、freeze、interest、rate。
- Fuzz tests：借款上限、赎回健康因子、价格下跌清算、清算奖励计算、USDC decimals。
- Invariant tests：抵押品账实一致、协议持有抵押品账实一致、base pool 偿付能力、坏账 shortfall 边界、债务账本一致、健康仓位不能被清算、成功 borrow/withdraw 后账户不能低于健康因子。
