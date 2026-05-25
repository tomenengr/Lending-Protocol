// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata} from "../interfaces/IERC20Metadata.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {AccountLogic} from "./AccountLogic.sol";
import {InterestRateLogic} from "../libraries/InterestRateLogic.sol";
import {RiskEngine} from "../RiskEngine.sol";

abstract contract SupplyBorrowLogic is AccountLogic {
    constructor(IERC20Metadata usdc_, IPriceOracle oracle_, RiskEngine riskEngine_)
        AccountLogic(usdc_, oracle_, riskEngine_)
    {}

    function _executeSupplyBase(address user, uint256 amountUsdc) internal {
        uint256 received = _pullUsdc(user, amountUsdc);

        uint256 principal = received * WAD / supplyIndex;
        require(principal > 0, "ZERO_PRINCIPAL");

        _baseSupplyPrincipal[user] += principal;
        totalSupplyPrincipal += principal;

        emit BaseSupplied(user, received);
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
        require(_totalBorrowedUsdcStored() + amountUsdc <= globalBorrowCapUsdc, "BORROW_CAP_EXCEEDED");

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
        uint256 received = _pullUsdc(user, repayAmount);

        uint256 principal;
        if (received >= debt) {
            principal = _borrowPrincipal[user];
        } else {
            // Round up the principal reduction so the protocol never under-collects.
            // Without rounding up, repeated partial repayments could leave a dust
            // principal that never fully clears due to integer truncation.
            principal = InterestRateLogic.principalForAmountRoundUp(received, borrowIndex, WAD);
            require(principal > 0, "ZERO_PRINCIPAL");
        }

        _borrowPrincipal[user] -= principal;
        totalBorrowPrincipal -= principal;

        emit Repaid(user, received);
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

    function _pullUsdc(address from, uint256 amountUsdc) internal returns (uint256) {
        uint256 balanceBefore = USDC.balanceOf(address(this));
        require(USDC.transferFrom(from, address(this), amountUsdc), "TRANSFER_FAILED");
        uint256 received = USDC.balanceOf(address(this)) - balanceBefore;
        require(received > 0, "ZERO_RECEIVED");
        return received;
    }
}
