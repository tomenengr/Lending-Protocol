// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MiniLendingTestBase} from "./helpers/MiniLendingTestBase.sol";

contract MiniLendingRateTest is MiniLendingTestBase {
    function test_borrowRateStartsAtBaseRateWhenUtilizationIsZero() public view {
        assertEq(lending.getUtilization(), 0);
        assertEq(lending.getBorrowRatePerSecond(), lending.BASE_RATE_PER_SECOND());
    }

    function test_borrowRateUsesLowSlopeBelowKink() public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 2_000e6);

        uint256 utilization = lending.getUtilization();
        uint256 expectedRate = lending.BASE_RATE_PER_SECOND() + utilization * lending.SLOPE_LOW_PER_SECOND() / WAD;

        assertLt(utilization, lending.KINK_UTILIZATION());
        assertEq(lending.getBorrowRatePerSecond(), expectedRate);
    }

    function test_borrowRateUsesHighSlopeAboveKink() public {
        weth.mint(alice, 5_000 ether);
        _depositWeth(alice, 5_000 ether);
        _borrow(alice, 9_000_000e6);

        uint256 utilization = lending.getUtilization();
        uint256 normalRate =
            lending.BASE_RATE_PER_SECOND() + lending.KINK_UTILIZATION() * lending.SLOPE_LOW_PER_SECOND() / WAD;
        uint256 expectedRate =
            normalRate + (utilization - lending.KINK_UTILIZATION()) * lending.SLOPE_HIGH_PER_SECOND() / WAD;

        assertGt(utilization, lending.KINK_UTILIZATION());
        assertEq(lending.getBorrowRatePerSecond(), expectedRate);
    }

    function test_accrualSendsReserveFactorToProtocolReserves() public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 1_000e6);

        uint256 borrowIndexBefore = lending.borrowIndex();
        uint256 totalBorrowPrincipal = lending.totalBorrowPrincipal();

        vm.warp(block.timestamp + 365 days);
        uint256 currentBorrowIndex = lending.getCurrentBorrowIndex();
        uint256 expectedInterest = totalBorrowPrincipal * (currentBorrowIndex - borrowIndexBefore) / WAD;
        uint256 expectedReserves = expectedInterest * lending.RESERVE_FACTOR_BPS() / BPS;

        lending.accrueInterest();

        assertEq(lending.protocolReservesUsdc(), expectedReserves);
    }

    function test_supplierGetsInterestNetOfReserveFactor() public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 1_000e6);

        uint256 supplyIndexBefore = lending.supplyIndex();
        uint256 totalSupplyPrincipal = lending.totalSupplyPrincipal();
        uint256 borrowIndexBefore = lending.borrowIndex();
        uint256 totalBorrowPrincipal = lending.totalBorrowPrincipal();

        vm.warp(block.timestamp + 365 days);
        uint256 currentBorrowIndex = lending.getCurrentBorrowIndex();
        uint256 interestAccrued = totalBorrowPrincipal * (currentBorrowIndex - borrowIndexBefore) / WAD;
        uint256 supplierInterest = interestAccrued * (BPS - lending.RESERVE_FACTOR_BPS()) / BPS;
        uint256 expectedSupplyIndex = supplyIndexBefore + supplierInterest * WAD / totalSupplyPrincipal;

        lending.accrueInterest();

        assertEq(lending.supplyIndex(), expectedSupplyIndex);
    }

    function test_availableLiquidityExcludesProtocolReserves() public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 1_000e6);

        vm.warp(block.timestamp + 365 days);
        uint256 debtAfterInterest = lending.debtUsdc(alice);
        _repay(alice, debtAfterInterest);

        assertEq(lending.getAvailableLiquidity(), usdc.balanceOf(address(lending)) - lending.protocolReservesUsdc());
    }
}
