# 风险参数

所有 bps 参数都使用 `10_000 = 100%`。

## 当前参数

| 资产 | Collateral Factor | Liquidation Threshold | Liquidation Bonus | Supply Cap |
| --- | ---: | ---: | ---: | ---: |
| WETH | 75% | 80% | 10% | 10,000 WETH |
| WBTC | 70% | 75% | 10% | 1,000 WBTC |

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

## 参数管理

`RiskEngine` 使用 owner-controlled setter 保存风险参数。测试中还提供 `lock()` 路径，用于在 invariant 测试里冻结管理面，让随机测试专注用户行为。

生产级协议应该用治理、timelock、多签和参数变更事件来管理风险参数。本项目第一版只保留最小管理能力。
