// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata} from "../interfaces/IERC20Metadata.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {LendingStorage} from "../LendingStorage.sol";
import {RiskEngine} from "../RiskEngine.sol";

abstract contract AccountLogic is LendingStorage {
    constructor(IERC20Metadata usdc_, IPriceOracle oracle_, RiskEngine riskEngine_)
        LendingStorage(usdc_, oracle_, riskEngine_)
    {}

    function _getAccountDataWithDebt(address user, uint256 debtAmountUsdc)
        internal
        view
        returns (uint256 totalCollateralUsd, uint256 borrowableUsd, uint256 debtUsd, uint256 healthFactor)
    {
        uint256 adjustedCollateralUsd = 0;
        uint256 isolationDebtCeilingUsd = type(uint256).max;

        uint256 assetsLength = collateralAssets.length;
        for (uint256 i = 0; i < assetsLength; i++) {
            address asset = collateralAssets[i];
            uint256 balance = collateralBalance[user][asset];
            if (balance == 0) {
                continue;
            }

            uint256 collateralValueUsd = _assetToUsd(asset, balance);
            RiskEngine.RiskConfig memory config = RISK_ENGINE.getRiskConfig(asset);
            totalCollateralUsd += collateralValueUsd;
            borrowableUsd += collateralValueUsd * config.collateralFactorBps / BPS;
            adjustedCollateralUsd += RISK_ENGINE.calculateLiquidationThresholdUsd(asset, collateralValueUsd);
            if (config.isolated && config.debtCeilingUsd < isolationDebtCeilingUsd) {
                isolationDebtCeilingUsd = config.debtCeilingUsd;
            }
        }

        if (borrowableUsd > isolationDebtCeilingUsd) {
            borrowableUsd = isolationDebtCeilingUsd;
        }

        debtUsd = _debtToUsd(debtAmountUsdc);
        healthFactor = debtUsd == 0 ? type(uint256).max : adjustedCollateralUsd * WAD / debtUsd;
    }

    function _assetToUsd(address asset, uint256 amount) internal view returns (uint256) {
        uint256 priceE18 = ORACLE.getPrice(asset);
        uint8 decimals = IERC20Metadata(asset).decimals();
        return amount * priceE18 / (10 ** decimals);
    }

    function _debtToUsd(uint256 amountUsdc) internal view returns (uint256) {
        uint256 priceE18 = ORACLE.getPrice(address(USDC));
        return amountUsdc * priceE18 / (10 ** USDC.decimals());
    }

    function _enforceIsolationOnDeposit(address user, address depositAsset, RiskEngine.RiskConfig memory depositConfig)
        internal
        view
    {
        uint256 assetsLength = collateralAssets.length;
        for (uint256 i = 0; i < assetsLength; i++) {
            address asset = collateralAssets[i];
            if (asset == depositAsset || collateralBalance[user][asset] == 0) {
                continue;
            }

            RiskEngine.RiskConfig memory existingConfig = RISK_ENGINE.getRiskConfig(asset);
            require(!depositConfig.isolated && !existingConfig.isolated, "ISOLATION_MODE_COLLATERAL");
        }
    }

    function _requireNoFrozenCollateral(address user) internal view {
        uint256 assetsLength = collateralAssets.length;
        for (uint256 i = 0; i < assetsLength; i++) {
            address asset = collateralAssets[i];
            if (assetFrozen[asset] && collateralBalance[user][asset] > 0) {
                revert("FROZEN_COLLATERAL");
            }
        }
    }

    function _usdToDebtRoundUp(uint256 valueUsd) internal view returns (uint256) {
        uint256 priceE18 = ORACLE.getPrice(address(USDC));
        uint256 debtUnit = 10 ** USDC.decimals();
        return (valueUsd * debtUnit + priceE18 - 1) / priceE18;
    }
}
