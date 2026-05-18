// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata} from "../interfaces/IERC20Metadata.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {LiquidationLogic} from "./LiquidationLogic.sol";
import {RiskEngine} from "../RiskEngine.sol";

abstract contract AdminLogic is LiquidationLogic {
    constructor(IERC20Metadata usdc_, IPriceOracle oracle_, RiskEngine riskEngine_)
        LiquidationLogic(usdc_, oracle_, riskEngine_)
    {}

    function _executeTransferOwnership(address newOwner) internal {
        require(newOwner != address(0), "ZERO_OWNER");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function _executeSetPaused(bool paused_) internal {
        paused = paused_;
        emit PausedSet(paused_);
    }

    function _executeSetAssetFrozen(address asset, bool frozen) internal {
        require(isCollateralAsset[asset], "UNSUPPORTED_ASSET");
        assetFrozen[asset] = frozen;
        emit AssetFrozenSet(asset, frozen);
    }

    function _executeWithdrawReserves(address recipient, uint256 amountUsdc) internal {
        require(recipient != address(0), "ZERO_RECIPIENT");
        require(amountUsdc <= protocolReservesUsdc, "INSUFFICIENT_RESERVES");
        require(USDC.balanceOf(address(this)) >= amountUsdc, "INSUFFICIENT_RESERVE_CASH");

        protocolReservesUsdc -= amountUsdc;

        require(USDC.transfer(recipient, amountUsdc), "TRANSFER_FAILED");
        emit ReservesWithdrawn(recipient, amountUsdc);
    }

    function _executeRecapitalizeBadDebt(address payer, uint256 amountUsdc) internal {
        uint256 badDebt = badDebtUsdc;
        require(badDebt > 0, "NO_BAD_DEBT");

        uint256 actualAmount = amountUsdc > badDebt ? badDebt : amountUsdc;
        badDebtUsdc = badDebt - actualAmount;

        require(USDC.transferFrom(payer, address(this), actualAmount), "TRANSFER_FAILED");
        emit BadDebtRecapitalized(payer, actualAmount);
    }
}
