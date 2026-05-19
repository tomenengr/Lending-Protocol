# 利息模型

协议使用 Compound 风格的全局 index 结算利息。用户只记录 principal，余额通过当前 index 计算，避免每次状态变化时遍历所有用户。

## 核心状态

```solidity
uint256 public borrowIndex;
uint256 public supplyIndex;
uint256 public lastAccrualTimestamp;
uint256 public protocolReservesUsdc;

mapping(address user => uint256 principal) private _borrowPrincipal;
mapping(address user => uint256 principal) private _baseSupplyPrincipal;
```

## 余额计算

```text
debtUsdc(user) = userBorrowPrincipal * currentBorrowIndex / 1e18
suppliedUsdc(user) = userSupplyPrincipal * currentSupplyIndex / 1e18
```

`borrowIndex` 增长代表借款人债务增加；`supplyIndex` 增长代表供应者可领取余额增加。

## Kink Rate Model

```text
utilization = totalBorrowedUsdc / totalSuppliedUsdc
```

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
reserve factor = 10%
```

当资金利用率超过 80% 后，借款利率快速上升，用来抑制继续借款并激励还款或新增供应。

## Accrual

状态变更前调用 `accrueInterest()`：

```text
elapsed = block.timestamp - lastAccrualTimestamp
borrowRate = f(storedUtilization)
newBorrowIndex = borrowIndex + borrowIndex * borrowRate * elapsed / 1e18
interestAccrued = totalBorrowPrincipal * (newBorrowIndex - borrowIndex) / 1e18
reserveInterest = interestAccrued * 10%
supplierInterest = interestAccrued - reserveInterest
```

之后更新 `borrowIndex`、`supplyIndex`、`protocolReservesUsdc` 和 `lastAccrualTimestamp`。

## 储备金

`protocolReservesUsdc` 是协议收入和坏账缓冲。`withdrawReserves` 只能提取已经落账且有实际 USDC cash 支持的储备金：

```text
amountUsdc <= protocolReservesUsdc
USDC.balanceOf(lending) >= amountUsdc
```

`getAvailableLiquidity()` 会扣除储备金，避免供应者取走协议 reserve。

## 坏账再资本化

`absorb` 识别坏账时会先消耗 `protocolReservesUsdc`，不足部分记录到 `badDebtUsdc`。任何地址都可以调用：

```text
recapitalizeBadDebt(amountUsdc)
```

协议实际收取 `min(amountUsdc, badDebtUsdc)`，并减少对应坏账。
