// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata} from "../interfaces/IERC20Metadata.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {SupplyBorrowLogic} from "./SupplyBorrowLogic.sol";
import {InterestRateLogic} from "../libraries/InterestRateLogic.sol";
import {RiskEngine} from "../RiskEngine.sol";

abstract contract LiquidationLogic is SupplyBorrowLogic {
    constructor(IERC20Metadata usdc_, IPriceOracle oracle_, RiskEngine riskEngine_)
        SupplyBorrowLogic(usdc_, oracle_, riskEngine_)
    {}

    function _executeLiquidate(address liquidator, address borrower, address collateralAsset, uint256 repayAmountUsdc)
        internal
    {
        require(isCollateralAsset[collateralAsset], "UNSUPPORTED_ASSET");

        uint256 borrowerDebt = _borrowPrincipal[borrower] * borrowIndex / WAD;
        (,,, uint256 healthFactor) = _getAccountDataWithDebt(borrower, borrowerDebt);
        require(healthFactor < MIN_HEALTH_FACTOR, "POSITION_HEALTHY");

        uint256 maxRepay = borrowerDebt * CLOSE_FACTOR_BPS / BPS;
        uint256 actualRepay = repayAmountUsdc > maxRepay ? maxRepay : repayAmountUsdc;
        require(actualRepay > 0, "ZERO_REPAY");
        uint256 received = _pullUsdc(liquidator, actualRepay);
        uint256 creditedRepay = received > maxRepay ? maxRepay : received;

        (uint256 principal, uint256 collateralToSeize) =
            _calculateLiquidationAmounts(borrower, collateralAsset, creditedRepay, borrowerDebt);

        _borrowPrincipal[borrower] -= principal;
        totalBorrowPrincipal -= principal;
        collateralBalance[borrower][collateralAsset] -= collateralToSeize;
        totalCollateral[collateralAsset] -= collateralToSeize;

        require(IERC20Metadata(collateralAsset).transfer(liquidator, collateralToSeize), "TRANSFER_FAILED");

        emit Liquidated(liquidator, borrower, collateralAsset, creditedRepay, collateralToSeize);
    }

    function _executeAbsorb(address absorber, address borrower) internal {
        uint256 borrowerDebt = _borrowPrincipal[borrower] * borrowIndex / WAD;
        (,,, uint256 healthFactor) = _getAccountDataWithDebt(borrower, borrowerDebt);
        require(healthFactor < MIN_HEALTH_FACTOR, "POSITION_HEALTHY");
        require(borrowerDebt > 0, "NO_DEBT");

        uint256 discountedCollateralValueUsd = 0;
        uint256 assetsLength = collateralAssets.length;
        for (uint256 i = 0; i < assetsLength; i++) {
            address asset = collateralAssets[i];
            uint256 balance = collateralBalance[borrower][asset];
            if (balance == 0) {
                continue;
            }

            uint256 collateralValueUsd = _assetToUsd(asset, balance);
            RiskEngine.RiskConfig memory config = RISK_ENGINE.getRiskConfig(asset);
            discountedCollateralValueUsd += collateralValueUsd * BPS / (BPS + config.liquidationBonusBps);

            collateralBalance[borrower][asset] = 0;
            totalCollateral[asset] -= balance;
            protocolCollateralBalance[asset] += balance;
        }

        uint256 borrowerDebtUsd = _debtToUsd(borrowerDebt);
        uint256 badDebtRecognized = 0;
        if (borrowerDebtUsd > discountedCollateralValueUsd) {
            badDebtRecognized = _usdToDebtRoundUp(borrowerDebtUsd - discountedCollateralValueUsd);
            _recognizeBadDebt(badDebtRecognized);
        }

        uint256 principal = _borrowPrincipal[borrower];
        _borrowPrincipal[borrower] = 0;
        totalBorrowPrincipal -= principal;

        emit Absorbed(absorber, borrower, borrowerDebt, badDebtRecognized);
    }

    function _executeBuyCollateral(
        address buyer,
        address collateralAsset,
        uint256 amountUsdc,
        uint256 minCollateralAmount
    ) internal {
        require(isCollateralAsset[collateralAsset], "UNSUPPORTED_ASSET");

        uint256 received = _pullUsdc(buyer, amountUsdc);
        uint256 repayValueUsd = _debtToUsd(received);
        uint256 collateralPriceE18 = ORACLE.getPrice(collateralAsset);
        uint8 collateralDecimals = IERC20Metadata(collateralAsset).decimals();
        uint256 collateralToBuy =
            RISK_ENGINE.calculateSeizeAmount(collateralAsset, repayValueUsd, collateralPriceE18, collateralDecimals);

        require(collateralToBuy >= minCollateralAmount, "SLIPPAGE");
        require(protocolCollateralBalance[collateralAsset] >= collateralToBuy, "INSUFFICIENT_PROTOCOL_COLLATERAL");

        protocolCollateralBalance[collateralAsset] -= collateralToBuy;

        require(IERC20Metadata(collateralAsset).transfer(buyer, collateralToBuy), "TRANSFER_FAILED");

        // Route the USDC proceeds to bad debt recovery first; any surplus goes to
        // protocol reserves so suppliers indirectly benefit from the collateral sale.
        _recoverBadDebt(received);

        emit CollateralPurchased(buyer, collateralAsset, received, collateralToBuy);
    }

    /// @notice Apply incoming USDC (from collateral sales) against outstanding bad debt.
    ///         Any surplus beyond the current bad debt balance is credited to protocol
    ///         reserves, which accrue to suppliers via the supply index over time.
    function _recoverBadDebt(uint256 amountUsdc) internal {
        uint256 currentBadDebt = badDebtUsdc;
        uint256 applied = amountUsdc > currentBadDebt ? currentBadDebt : amountUsdc;
        badDebtUsdc -= applied;
        uint256 surplus = amountUsdc - applied;
        if (surplus > 0) {
            protocolReservesUsdc += surplus;
        }
        if (applied > 0) {
            emit BadDebtRecovered(msg.sender, applied);
        }
    }

    function _recognizeBadDebt(uint256 amountUsdc) internal {
        uint256 reservesUsed = amountUsdc > protocolReservesUsdc ? protocolReservesUsdc : amountUsdc;
        protocolReservesUsdc -= reservesUsed;
        badDebtUsdc += amountUsdc - reservesUsed;
    }

    function _calculateLiquidationAmounts(
        address borrower,
        address collateralAsset,
        uint256 repayAmountUsdc,
        uint256 borrowerDebt
    ) internal view returns (uint256 principal, uint256 collateralToSeize) {
        uint256 repayValueUsd = _debtToUsd(repayAmountUsdc);
        uint256 collateralPriceE18 = ORACLE.getPrice(collateralAsset);
        uint8 collateralDecimals = IERC20Metadata(collateralAsset).decimals();
        collateralToSeize =
            RISK_ENGINE.calculateSeizeAmount(collateralAsset, repayValueUsd, collateralPriceE18, collateralDecimals);

        require(collateralBalance[borrower][collateralAsset] >= collateralToSeize, "INSUFFICIENT_COLLATERAL_TO_SEIZE");

        if (repayAmountUsdc >= borrowerDebt) {
            principal = _borrowPrincipal[borrower];
        } else {
            // Round up to match repay logic: ensures the borrower's principal is
            // fully cleared when repayAmountUsdc covers the full debt amount.
            principal = InterestRateLogic.principalForAmountRoundUp(repayAmountUsdc, borrowIndex, WAD);
            require(principal > 0, "ZERO_PRINCIPAL");
        }
    }
}
