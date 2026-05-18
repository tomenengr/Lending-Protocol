// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata} from "../interfaces/IERC20Metadata.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {AccountLogic} from "./AccountLogic.sol";
import {InterestRateLogic} from "./InterestRateLogic.sol";
import {RiskEngine} from "../RiskEngine.sol";

abstract contract SupplyBorrowLogic is AccountLogic {
    constructor(IERC20Metadata usdc_, IPriceOracle oracle_, RiskEngine riskEngine_)
        AccountLogic(usdc_, oracle_, riskEngine_)
    {}

    function _executeSupplyBase(address user, uint256 amountUsdc) internal {
        uint256 principal = amountUsdc * WAD / supplyIndex;
        require(principal > 0, "ZERO_PRINCIPAL");

        _baseSupplyPrincipal[user] += principal;
        totalSupplyPrincipal += principal;

        require(USDC.transferFrom(user, address(this), amountUsdc), "TRANSFER_FAILED");
        emit BaseSupplied(user, amountUsdc);
    }

    function _executeWithdrawBase(address user, uint256 amountUsdc) internal {
        uint256 supplied = _baseSupplyPrincipal[user] * supplyIndex / WAD;
        require(supplied >= amountUsdc, "INSUFFICIENT_SUPPLY");
        require(_availableLiquidity() >= amountUsdc, "INSUFFICIENT_LIQUIDITY");

        uint256 principal = InterestRateLogic.principalForAmountRoundUp(amountUsdc, supplyIndex, WAD);
        require(principal <= _baseSupplyPrincipal[user], "INSUFFICIENT_SUPPLY");

        _baseSupplyPrincipal[user] -= principal;
        totalSupplyPrincipal -= principal;

        require(USDC.transfer(user, amountUsdc), "TRANSFER_FAILED");
        emit BaseWithdrawn(user, amountUsdc);
    }

    function _executeBorrow(address user, uint256 amountUsdc) internal {
        _requireNoFrozenCollateral(user);
        require(_availableLiquidity() >= amountUsdc, "INSUFFICIENT_LIQUIDITY");
        require(_totalBorrowedUsdcStored() + amountUsdc <= GLOBAL_BORROW_CAP_USDC, "BORROW_CAP_EXCEEDED");

        uint256 newDebt = _borrowPrincipal[user] * borrowIndex / WAD + amountUsdc;
        (, uint256 borrowableUsd, uint256 newDebtUsd, uint256 healthFactor) = _getAccountDataWithDebt(user, newDebt);

        require(newDebtUsd <= borrowableUsd, "BORROW_LIMIT_EXCEEDED");
        require(healthFactor >= MIN_HEALTH_FACTOR, "HF_TOO_LOW");

        uint256 principal = InterestRateLogic.principalForAmountRoundUp(amountUsdc, borrowIndex, WAD);
        _borrowPrincipal[user] += principal;
        totalBorrowPrincipal += principal;

        require(USDC.transfer(user, amountUsdc), "TRANSFER_FAILED");
        emit Borrowed(user, amountUsdc);
    }

    function _executeRepay(address user, uint256 amountUsdc) internal {
        uint256 debt = _borrowPrincipal[user] * borrowIndex / WAD;
        require(debt > 0, "NO_DEBT");

        uint256 repayAmount = amountUsdc > debt ? debt : amountUsdc;
        uint256 principal;
        if (repayAmount == debt) {
            principal = _borrowPrincipal[user];
        } else {
            principal = repayAmount * WAD / borrowIndex;
            require(principal > 0, "ZERO_PRINCIPAL");
        }

        _borrowPrincipal[user] -= principal;
        totalBorrowPrincipal -= principal;

        require(USDC.transferFrom(user, address(this), repayAmount), "TRANSFER_FAILED");
        emit Repaid(user, repayAmount);
    }

    function _availableLiquidity() internal view returns (uint256) {
        uint256 balance = USDC.balanceOf(address(this));
        if (balance <= protocolReservesUsdc) {
            return 0;
        }

        return balance - protocolReservesUsdc;
    }

    function _totalBorrowedUsdcStored() internal view returns (uint256) {
        return totalBorrowPrincipal * borrowIndex / WAD;
    }
}
