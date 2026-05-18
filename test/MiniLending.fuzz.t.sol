// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MiniLendingTestBase} from "./helpers/MiniLendingTestBase.sol";

contract MiniLendingFuzzTest is MiniLendingTestBase {
    function testFuzz_MaxBorrow(uint256 collateralAmount, uint256 priceUsd) public {
        collateralAmount = bound(collateralAmount, 0.01 ether, 100 ether);
        priceUsd = bound(priceUsd, 100, 10_000);
        _setWethPrice(priceUsd);

        _depositWeth(alice, collateralAmount);

        (, uint256 borrowableUsd,,) = lending.getAccountData(alice);
        uint256 expectedCollateralValueUsd = collateralAmount * priceUsd * 1e18 / 1e18;
        uint256 expectedBorrowableUsd = expectedCollateralValueUsd * 7_500 / BPS;

        assertEq(borrowableUsd, expectedBorrowableUsd);
    }

    function testFuzz_BorrowCannotExceedLimit(uint256 collateralAmount, uint256 borrowAmountUsdc) public {
        collateralAmount = bound(collateralAmount, 0.01 ether, 100 ether);
        _depositWeth(alice, collateralAmount);

        (, uint256 borrowableUsd,,) = lending.getAccountData(alice);
        uint256 maxBorrowUsdc = borrowableUsd * 1e6 / 1e18;
        borrowAmountUsdc = bound(borrowAmountUsdc, 1, maxBorrowUsdc + 1_000e6);

        vm.prank(alice);
        if (borrowAmountUsdc > maxBorrowUsdc) {
            vm.expectRevert(bytes("BORROW_LIMIT_EXCEEDED"));
            lending.borrow(borrowAmountUsdc);
        } else {
            lending.borrow(borrowAmountUsdc);
            assertEq(lending.debtUsdc(alice), borrowAmountUsdc);
        }
    }

    function testFuzz_WithdrawCannotMakeHealthFactorTooLow(uint256 withdrawAmount) public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 2_000e6);

        withdrawAmount = bound(withdrawAmount, 1, 1 ether);
        uint256 remainingCollateral = 1 ether - withdrawAmount;
        uint256 adjustedCollateralUsd = remainingCollateral * 3_000e18 / 1e18 * 8_000 / BPS;
        uint256 expectedHealthFactor = adjustedCollateralUsd * 1e18 / 2_000e18;

        vm.prank(alice);
        if (expectedHealthFactor < 1e18) {
            vm.expectRevert(bytes("HF_TOO_LOW"));
            lending.withdrawCollateral(address(weth), withdrawAmount);
        } else {
            lending.withdrawCollateral(address(weth), withdrawAmount);
            assertGe(lending.getHealthFactor(alice), 1e18);
        }
    }

    function testFuzz_PriceDropTriggersLiquidation(uint256 priceAfterDrop) public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 2_000e6);

        priceAfterDrop = bound(priceAfterDrop, 1_500, 3_000);
        _setWethPrice(priceAfterDrop);

        vm.startPrank(bob);
        usdc.approve(address(lending), 1_000e6);
        if (lending.getHealthFactor(alice) < 1e18) {
            lending.liquidate(alice, address(weth), 1_000e6);
            assertEq(lending.debtUsdc(alice), 1_000e6);
        } else {
            vm.expectRevert(bytes("POSITION_HEALTHY"));
            lending.liquidate(alice, address(weth), 1_000e6);
        }
        vm.stopPrank();
    }

    function testFuzz_LiquidationBonusCalculation(uint256 repayAmountUsdc, uint256 collateralPriceUsd) public view {
        repayAmountUsdc = bound(repayAmountUsdc, 1e6, 10_000e6);
        collateralPriceUsd = bound(collateralPriceUsd, 500, 10_000);

        uint256 repayValueUsd = repayAmountUsdc * 1e18 / 1e6;
        uint256 expectedSeizeAmount = repayValueUsd * 11_000 / BPS * 1e18 / (collateralPriceUsd * 1e18);

        uint256 actualSeizeAmount =
            riskEngine.calculateSeizeAmount(address(weth), repayValueUsd, collateralPriceUsd * 1e18, 18);

        assertEq(actualSeizeAmount, expectedSeizeAmount);
    }

    function testFuzz_DebtValueUsesUSDCDecimals(uint256 amountUsdc) public {
        amountUsdc = bound(amountUsdc, 1e6, 2_250e6);
        _depositWeth(alice, 1 ether);
        _borrow(alice, amountUsdc);

        (,, uint256 debtUsd,) = lending.getAccountData(alice);
        assertEq(debtUsd, amountUsdc * 1e18 / 1e6);
    }
}
