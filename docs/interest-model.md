# 利息模型

当前版本实现了一个简化版 Compound 风格 index 利息模型，并使用 utilization-based kink rate model 计算借款利率。

## 设计目标

借贷协议不能在每次区块推进时遍历所有 borrower 和 supplier 更新余额。正确做法是维护全局 index：

- borrower 的债务通过 `borrowIndex` 增长。
- supplier 的可领取余额通过 `supplyIndex` 增长。
- 用户只记录 principal。

## 状态变量

```solidity
uint256 public borrowIndex;
uint256 public supplyIndex;
uint256 public lastAccrualTimestamp;
uint256 public protocolReservesUSDC;
uint256 public badDebtUSDC;

mapping(address user => uint256 principal) private _baseSupplyPrincipal;
mapping(address user => uint256 principal) private _borrowPrincipal;
```

## 债务计算

```text
debtUSDC(user) = userBorrowPrincipal * currentBorrowIndex / 1e18
```

如果用户借出 1000 USDC，之后 `borrowIndex` 上涨 10%，用户债务约为：

```text
1000 * 1.1 = 1100 USDC
```

## 供应者余额计算

```text
suppliedUSDC(user) = userSupplyPrincipal * currentSupplyIndex / 1e18
```

当前版本把 borrower 产生的 90% 利息分配给供应者，因此 `supplyIndex` 会随着净供应者利息增长。剩余 10% 进入 `protocolReservesUSDC`。

## Kink Rate Model

借款利率由资金利用率决定：

```text
utilization = totalBorrowedUSDC / totalSuppliedUSDC
```

利率曲线：

```text
utilization <= 80%:
    rate = baseRate + utilization * slopeLow

utilization > 80%:
    rate = baseRate + 80% * slopeLow + (utilization - 80%) * slopeHigh
```

当前参数：

```text
base APR ~= 2%
slopeLow APR ~= 8%
slopeHigh APR ~= 100%
kink utilization = 80%
```

这表示资金池使用率越高，借款利率越高；当 utilization 超过 80% 后，利率上升速度明显变快，以抑制继续借款并激励还款或新增供应。

## Accrual 流程

状态变更前调用 `accrueInterest()`：

```text
elapsed = block.timestamp - lastAccrualTimestamp
borrowRate = f(storedUtilization)
newBorrowIndex = borrowIndex + borrowIndex * borrowRate * elapsed / 1e18
interestAccrued = totalBorrowPrincipal * (newBorrowIndex - borrowIndex) / 1e18
reserveInterest = interestAccrued * 10% 
supplierInterest = interestAccrued - reserveInterest
newSupplyIndex = supplyIndex + supplierInterest * 1e18 / totalSupplyPrincipal
```

然后更新：

```text
borrowIndex = newBorrowIndex
supplyIndex = newSupplyIndex
protocolReservesUSDC += reserveInterest
lastAccrualTimestamp = block.timestamp
```

## 当前简化

- reserve factor 固定为 10%，不能动态调整。
- 没有 supplier reserve shares。
- 没有区分 stable/variable debt。

## 储备金提取

`withdrawReserves(recipient, amountUSDC)` 允许 owner 提取已经落账的协议储备金：

```text
amountUSDC <= protocolReservesUSDC
usdc.balanceOf(lending) >= amountUSDC
```

第二个条件很重要。`protocolReservesUSDC` 是会计储备金，利息可能已经累积到债务里，但 borrower 还没有还款，协议未必已经收到对应 USDC cash。只有在现金足够时，owner 才能提取。

提取会同时减少：

```text
protocolReservesUSDC
USDC cash
```

因此 `getAvailableLiquidity()` 不会因为储备金提取而下降。

## 坏账处理

```text
discountedCollateralValue = collateralMarketValue * 10000 / (10000 + liquidationBonusBps)
badDebt = max(debtValue - discountedCollateralValue, 0)
```

`absorb` 会先用 `protocolReservesUSDC` 抵扣坏账，不足部分记录到 `badDebtUSDC`。这里使用折价可回收价值，而不是抵押品市场价值，因为协议后续会通过 `buyCollateral` 按 liquidation bonus 折价出售协议持有的抵押品。

记录坏账后，任何地址都可以调用 `recapitalizeBadDebt(amountUSDC)` 注入 MockUSDC：

```text
actualAmount = min(amountUSDC, badDebtUSDC)
badDebtUSDC -= actualAmount
USDC cash += actualAmount
```

这个设计让坏账从“只记录”变成“可修复”。它仍然保持简化：没有发行 recapitalization shares，也没有复杂 auction，只验证再注资对协议偿付能力的影响。
