# 风险参数

所有 bps 参数都使用 `10_000 = 100%`。

## 当前参数

| 资产 | Collateral Factor | Liquidation Threshold | Liquidation Bonus | Supply Cap | Isolation | Debt Ceiling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| WETH | 75% | 80% | 10% | 10,000 WETH | No | - |
| WBTC | 70% | 75% | 10% | 1,000 WBTC | Yes | 20,000 USD |

协议级常量：

| 参数 | 值 |
| --- | ---: |
| `BPS` | 10,000 |
| `WAD` | 1e18 |
| `MIN_HEALTH_FACTOR` | 1e18 |
| `CLOSE_FACTOR_BPS` | 5,000 |
| `GLOBAL_BORROW_CAP_USDC` | 9,000,000 USDC |

## 为什么 collateral factor 低于 liquidation threshold

Collateral factor 控制用户能借多少。Liquidation threshold 控制已有仓位什么时候进入可清算状态。

如果 liquidation threshold 高于 collateral factor，用户借到最大额度后仍然有健康因子缓冲。以 WETH 为例：

```text
抵押品 = 1 WETH
WETH 价格 = 3000 USD
可借额度 = 3000 * 75% = 2250 USDC
清算调整后抵押价值 = 3000 * 80% = 2400 USD
最大借款时健康因子 = 2400 / 2250 = 1.0666
```

如果两者相等，用户刚借满就可能处在清算边缘，风险体验不合理。

## 为什么 WETH 是 75% / 80%

WETH 在这个 mini protocol 里被视为流动性更好的抵押资产。75% collateral factor 可以让用户借出有意义的 USDC，同时 80% liquidation threshold 保留 5 个百分点的清算缓冲。

## 为什么 WBTC 是 70% / 75%

WBTC 参数比 WETH 更保守。它代表 wrapped asset 和流动性风险更高的资产类型，因此 collateral factor 和 liquidation threshold 都略低。

此外，WBTC 启用 isolation mode。即使 1 WBTC 按 70% collateral factor 理论上可以借：

```text
60000 * 70% = 42000 USDC
```

实际可借额度也会被 debt ceiling 截断：

```text
borrowable = min(42000, 20000) = 20000 USDC
```

## 为什么 liquidation bonus 是 10%

清算人需要经济激励来替不健康账户偿还债务。10% 奖励简单、直观，也方便写测试和解释：

```text
清算人偿还 1000 USDC
清算人获得价值 1100 USD 的抵押品
```

代价是 borrower 的抵押品会比债务下降得更快。当前项目固定使用 10%，重点展示清算机制，而不是动态风险调参。

## 为什么加入 supply cap

Supply cap 限制某个抵押资产在协议内的总存入量。它不是账户级风险参数，而是协议级风险参数：

```text
totalCollateral[asset] + depositAmount <= supplyCap
```

这样可以避免单一抵押资产占协议风险敞口过高。当前参数设置得比较宽松，主要用于展示风险控制链路：

```text
WETH supply cap = 10,000 WETH
WBTC supply cap = 1,000 WBTC
```

## 为什么加入 borrow cap

Global borrow cap 限制 MockUSDC 总借款规模：

```text
totalBorrowedUSDC + borrowAmount <= GLOBAL_BORROW_CAP_USDC
```

即使用户抵押品足够、资金池流动性足够，协议也不会允许总借款超过上限。这个参数用于控制协议整体债务规模，避免 base asset pool 在极端情况下暴露过大。

## 为什么加入 isolation mode

Isolation mode 用于限制高风险抵押品的传染风险。当前版本把 WBTC 设为 isolated collateral：

```text
isolated = true
debtCeilingUsd = 20,000e18
```

规则：

- 隔离资产不能和其他抵押品混用。
- 使用隔离资产时，可借额度会被 `debtCeilingUsd` 截断。
- 用户可以继续追加同一种隔离资产，但不能同时存入 WETH。

这模拟了真实协议里“资产可以作为抵押品，但风险敞口必须受限”的设计。

## 为什么加入 pause / freeze

真实借贷协议需要在异常情况下有降风险手段。当前版本把应急控制拆成两层：

```text
全局 pause：协议级异常时暂停新增风险和资金流出。
资产 freeze：单个抵押品异常时冻结该资产的新风险敞口。
```

全局 pause 会阻止 `depositCollateral`、`supplyBase`、`withdrawBase`、`withdrawCollateral`、`borrow` 和 `buyCollateral`。它不阻止 `repay`、`liquidate` 和 `absorb`，因为这些路径会降低债务或处理坏仓位。

资产 freeze 会阻止该资产的新抵押，并阻止持有冻结抵押品的账户继续借款。但它不阻止还款、赎回和清算，避免用户在资产被降级后无法主动降低风险。

## 参数管理

`RiskEngine` 使用 owner-controlled setter 保存风险参数。`MiniLending` 使用 owner-controlled setter 管理 pause 和 asset freeze。测试中还提供 `lock()` 路径，用于在 invariant 测试里冻结管理面，让随机测试专注用户行为。

生产级协议应该用治理、timelock、多签和参数变更事件来管理风险参数。本项目第一版只保留最小管理能力。
