# 风险参数

所有 bps 参数都使用 `10_000 = 100%`。

## 当前参数

| 资产 | Collateral Factor | Liquidation Threshold | Liquidation Bonus | Supply Cap | Isolation | Debt Ceiling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| WETH | 75% | 80% | 10% | 10,000 WETH | No | - |
| WBTC | 70% | 75% | 10% | 1,000 WBTC | Yes | 20,000 USD |

协议级参数：

| 参数 | 值 | 作用 |
| --- | ---: | --- |
| `MIN_HEALTH_FACTOR` | 1e18 | 低于该值可被清算 |
| `CLOSE_FACTOR_BPS` | 5,000 | 单次最多清算 50% 债务 |
| `GLOBAL_BORROW_CAP_USDC` | 9,000,000 USDC | 限制协议总借款 |
| `KINK_UTILIZATION` | 80% | 利率曲线拐点 |
| `RESERVE_FACTOR_BPS` | 1,000 | 10% 利息进入协议储备金 |

## 参数含义

- Collateral factor：决定用户最多能借多少。
- Liquidation threshold：决定已有仓位什么时候变成不健康。
- Liquidation bonus：补偿清算人承担的资金和执行风险。
- Supply cap：限制单个抵押资产进入协议的总规模。
- Global borrow cap：限制 MockUSDC 总债务规模。
- Isolation mode：限制高风险抵押品不能与其他抵押品混用，并用 debt ceiling 截断可借额度。

Collateral factor 通常低于 liquidation threshold。以 WETH 为例，用户抵押 1 WETH，价格 3000 USD：

```text
最大可借 = 3000 * 75% = 2250 USDC
清算调整后抵押价值 = 3000 * 80% = 2400 USD
借满时健康因子 = 2400 / 2250 = 1.0666
```

这让用户借到最大额度后仍有一段价格缓冲。

## Isolation Mode

WBTC 被配置为 isolated collateral：

```text
isolated = true
debtCeilingUsd = 20,000e18
```

规则：

- 已存入 WBTC 的账户不能再存入 WETH。
- 已存入 WETH 的账户不能再存入 WBTC。
- 使用 WBTC 时，可借额度为 `min(wbtcBorrowableUsd, debtCeilingUsd)`。

## Pause / Freeze

全局 pause 会阻止：

- `depositCollateral`
- `supplyBase`
- `withdrawBase`
- `withdrawCollateral`
- `borrow`
- `buyCollateral`

pause 不阻止 `repay`、`liquidate` 和 `absorb`，因为这些操作会降低风险。

资产 freeze 会阻止该资产新增抵押，并阻止持有冻结抵押品的账户继续借款；但不阻止还款、赎回和清算，避免用户无法主动降低风险。

## 管理方式

当前版本使用 owner-controlled setter 管理风险参数、pause 和 freeze。测试中提供 `lock()` 用于冻结管理面，让 invariant 测试聚焦用户行为。生产版本应改为多签、timelock 和治理流程。
