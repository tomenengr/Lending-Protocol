# 清算流程

清算是无许可的。只要 borrower 的健康因子低于 `1e18`，协议支持两条路径：

- Aave 风格直接清算：清算人替 borrower 偿还部分 MockUSDC 债务，并拿走带奖励的抵押品。
- Compound III 风格两阶段清算：协议先 `absorb` 不健康账户，再让第三方通过 `buyCollateral` 折价买入协议持有的抵押品。

## 核心公式

健康因子：

```text
healthFactor = adjustedCollateralUsd * 1e18 / debtUsd
```

清算可拿走的抵押品：

```text
seizeValueUsd = repayValueUsd * (10000 + liquidationBonusBps) / 10000
seizeAmount = seizeValueUsd * 10 ** collateralDecimals / collateralPriceE18
```

## 数字例子

初始状态：

```text
Alice 抵押 1 WETH
WETH 价格 = 3000 USD
WETH liquidation threshold = 80%
Alice 借出 2000 USDC
```

健康因子：

```text
adjustedCollateral = 3000 * 80% = 2400
debt = 2000
healthFactor = 2400 / 2000 = 1.2
```

Alice 当前是健康仓位。

然后 WETH 下跌：

```text
WETH 价格 = 2000 USD
adjustedCollateral = 2000 * 80% = 1600
debt = 2000
healthFactor = 1600 / 2000 = 0.8
```

Alice 进入可清算状态。

Bob 发起清算：

```text
Bob 偿还 1000 USDC
Liquidation bonus = 10%
Bob 获得价值 1100 USD 的 WETH
WETH 价格 = 2000 USD
Seized WETH = 1100 / 2000 = 0.55 WETH
```

最终状态：

```text
Alice debt: 2000 USDC -> 1000 USDC
Alice collateral: 1 WETH -> 0.45 WETH
Bob USDC: -1000 USDC
Bob WETH: +0.55 WETH
```

## Close Factor

协议使用：

```text
CLOSE_FACTOR_BPS = 5000
```

这表示每次清算最多偿还 borrower 当前债务的 50%。如果清算人传入的 repay amount 超过 close factor，`MiniLending` 会自动把实际还款额 cap 到 close factor 上限。

例子：

```text
Borrower debt = 2000 USDC
Max repay = 2000 * 50% = 1000 USDC
Liquidator passes repayAmount = 2000 USDC
Actual repay = 1000 USDC
```

事件会记录实际偿还金额和实际拿走的抵押品数量。

## 失败场景

清算会在以下情况 revert：

- 选择的抵押资产不受支持。
- repay amount 为零。
- borrower 的健康因子大于等于 `1e18`。
- borrower 选择的抵押资产余额不足以支付清算奖励。
- USDC 或抵押品转账失败。

## Absorb / Buy Collateral

两阶段清算把“处理 borrower 风险”和“向市场出售抵押品”拆开。

流程：

```text
1. absorb: 协议吸收不健康账户，把债务清零，并把 borrower 抵押品转入 protocolCollateralBalance。
2. buyCollateral: 清算人再用 base asset 从协议储备中折价买入抵押品。
```

数字例子：

```text
Alice debt = 2000 USDC
Alice collateral = 1 WETH
WETH price = 2000 USD
Liquidation bonus = 10%
```

`absorb(Alice)` 后：

```text
Alice debt: 2000 -> 0
Alice collateral: 1 WETH -> 0
protocolCollateralBalance[WETH]: 0 -> 1 WETH
```

因为协议会按 10% bonus 折价卖出抵押品，所以 1 WETH 的可回收 USDC 不是 2000，而是：

```text
discountedRecovery = 2000 / 1.1 = 1818.18 USDC
badDebt = 2000 - 1818.18 = 181.82 USDC
```

协议会先使用 `protocolReservesUSDC` 抵扣坏账，不足部分记录到 `badDebtUSDC`。

Bob 之后可以购买协议抵押品：

```text
Bob pays 1000 USDC
Bob receives 1000 * 1.1 / 2000 = 0.55 WETH
protocolCollateralBalance[WETH]: 1 -> 0.45 WETH
```

这个模型更工程化：清算人不直接面对 borrower，而是和协议的抵押品库存交易。
