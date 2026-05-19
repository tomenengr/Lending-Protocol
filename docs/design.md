# 设计说明

Mini Lending Protocol 是一个简化版超额抵押借贷协议。设计重点是把风险控制、资金池会计、利息累计和清算账务做完整，而不是堆叠完整 Aave / Compound 的全部功能。

## 范围

| 类型 | 当前实现 |
| --- | --- |
| 抵押资产 | MockWETH, MockWBTC |
| 借款资产 | MockUSDC |
| 价格源 | Mock Chainlink-style feeds |
| 核心操作 | deposit, withdraw, supply, borrow, repay, liquidate, absorb, buyCollateral |

## 合约边界

```text
MiniLending
  -> LendingCore
    -> LiquidationLogic
      -> SupplyBorrowLogic
        -> AccountLogic
          -> LendingStorage
```

- `MiniLending`：外部入口，做参数检查并在状态变更前结算利息。
- `LendingStorage`：集中保存常量、状态、事件和 modifier，方便审查 storage layout。
- `AccountLogic`：账户估值、健康因子、债务 USD 换算、isolation/freeze 检查。
- `SupplyBorrowLogic`：USDC 供应池、借款、还款和 base asset 流动性。
- `LiquidationLogic`：直接清算、协议吸收、抵押品出售和坏账识别。
- `LendingCore`：owner、pause、asset freeze、reserve withdraw、bad debt recapitalization。
- `RiskEngine`：只保存风险参数和风险数学，不持有资金。
- `PriceOracle`：读取 feed，校验价格有效性，并统一到 1e18 精度。

## 主要流程

### 供应和借款

供应者通过 `supplyBase` 存入 MockUSDC，借款人通过抵押 MockWETH / MockWBTC 借出 MockUSDC。协议借款检查三类约束：

- 账户约束：新债务不能超过 collateral factor 对应可借额度，健康因子不能低于 `1e18`。
- 池子约束：协议必须有足够可用 MockUSDC 流动性。
- 协议约束：总借款不能超过 `GLOBAL_BORROW_CAP_USDC`。

### 风险控制

- WETH：普通抵押资产，75% collateral factor，80% liquidation threshold。
- WBTC：隔离抵押资产，70% collateral factor，75% liquidation threshold，20,000 USD debt ceiling。
- Supply cap 限制单个抵押资产的协议级敞口。
- Pause 用于协议级异常，暂停新增风险和资金流出。
- Freeze 用于单资产异常，阻止该资产新增抵押或继续支持新增借款。

`repay`、`liquidate` 和 `absorb` 在 pause 下仍允许执行，因为这些路径会降低债务或处理不健康仓位。

### 利息和储备金

协议使用 `borrowIndex` / `supplyIndex` 累计利息，用户只记录 principal。这样状态更新不需要遍历所有用户。

借款利率来自 utilization kink model。借款利息中 90% 分配给供应者，10% 计入 `protocolReservesUsdc`。储备金可用于吸收坏账，也可在有实际 USDC cash 支持时由 owner 提取。

### 清算

账户健康因子低于 `1e18` 后，可以走两条路径：

- `liquidate`：清算人直接偿还 borrower 部分债务，并拿走带 bonus 的抵押品。
- `absorb / buyCollateral`：协议先接管不健康账户，再把协议持有的抵押品折价卖给第三方。

两阶段清算会根据抵押品折价可回收价值识别坏账，先消耗储备金，不足部分记录到 `badDebtUsdc`。`recapitalizeBadDebt` 允许任何地址注入 MockUSDC 修复坏账。

## 精度模型

| 数值 | 精度 |
| --- | --- |
| Token 数量 | token 自身 decimals |
| Oracle 价格 | 1e18 |
| USD 价值 | 1e18 |
| 健康因子 | 1e18 |

```text
collateralUsd = tokenAmount * priceE18 / 10 ** tokenDecimals
debtUsd = usdcAmount * usdcPriceE18 / 10 ** USDC_DECIMALS
healthFactor = adjustedCollateralUsd * 1e18 / debtUsd
```

## 测试策略

测试按风险面拆分：

- Unit：每个外部入口的成功路径、revert 条件、事件和账本变化。
- Fuzz：借款上限、赎回健康因子、价格下跌清算、清算奖励、USDC decimals。
- Invariant：抵押品账实一致、base pool 偿付能力、债务账本一致、健康账户不可清算、成功 borrow/withdraw 后账户仍健康。
