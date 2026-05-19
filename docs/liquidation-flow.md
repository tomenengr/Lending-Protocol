# 清算流程

当 borrower 的健康因子低于 `1e18` 时，协议允许无许可清算。

```text
healthFactor = adjustedCollateralUsd * 1e18 / debtUsd
```

## 直接清算

`liquidate(borrower, collateralAsset, repayAmountUsdc)`：

1. 检查 borrower 健康因子低于 `1e18`。
2. 将实际偿还额限制在 close factor 内，当前最多为债务的 50%。
3. 清算人支付 MockUSDC。
4. borrower 债务减少，抵押品减少。
5. 清算人获得带 liquidation bonus 的抵押品。

计算公式：

```text
actualRepay = min(repayAmountUsdc, borrowerDebt * CLOSE_FACTOR_BPS / 10000)
seizeValueUsd = repayValueUsd * (10000 + liquidationBonusBps) / 10000
seizeAmount = seizeValueUsd * 10 ** collateralDecimals / collateralPriceE18
```

例子：

```text
Alice 抵押 1 WETH，WETH 价格从 3000 跌到 2000
Alice debt = 2000 USDC
healthFactor = 2000 * 80% / 2000 = 0.8

Bob 偿还 1000 USDC
liquidation bonus = 10%
Bob 获得价值 1100 USD 的 WETH = 0.55 WETH
```

## Absorb / Buy Collateral

两阶段清算把“处理坏仓位”和“出售抵押品”拆开：

```text
absorb(borrower)
    borrower debt -> 0
    borrower collateral -> protocolCollateralBalance

buyCollateral(asset, amountUsdc, minCollateralAmount)
    buyer pays MockUSDC
    buyer receives discounted protocol collateral
```

坏账按折价可回收价值识别：

```text
discountedCollateralValue = collateralMarketValue * 10000 / (10000 + liquidationBonusBps)
badDebt = max(debtValue - discountedCollateralValue, 0)
```

协议先用 `protocolReservesUsdc` 抵扣坏账，不足部分进入 `badDebtUsdc`。

## Revert 条件

清算会在以下情况失败：

- 抵押资产不受支持。
- repay amount 为 0。
- borrower 健康因子大于等于 `1e18`。
- borrower 选择的抵押资产不足以支付清算奖励。
- 买入协议抵押品时低于 `minCollateralAmount`。
- ERC20 转账失败。
