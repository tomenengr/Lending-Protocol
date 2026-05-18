// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MiniLendingTestBase} from "./helpers/MiniLendingTestBase.sol";

contract MiniLendingInterestTest is MiniLendingTestBase {
    function test_borrowIndexAccruesOverTime() public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 1_000e6);

        vm.warp(block.timestamp + 365 days);
        lending.accrueInterest();

        assertGt(lending.borrowIndex(), WAD);
        assertGt(lending.debtUsdc(alice), 1_000e6);
    }

    function test_supplyIndexAccruesFromBorrowInterest() public {
        uint256 suppliedBefore = lending.suppliedUsdc(charlie);

        _depositWeth(alice, 1 ether);
        _borrow(alice, 1_000e6);

        vm.warp(block.timestamp + 365 days);
        lending.accrueInterest();

        assertGt(lending.supplyIndex(), WAD);
        assertGt(lending.suppliedUsdc(charlie), suppliedBefore);
    }

    function test_debtViewIncludesPendingInterestBeforeAccrue() public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 1_000e6);

        vm.warp(block.timestamp + 365 days);

        assertGt(lending.debtUsdc(alice), 1_000e6);
    }

    function test_repayAfterInterestPaysAccruedDebt() public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 1_000e6);

        vm.warp(block.timestamp + 365 days);
        uint256 debtAfterInterest = lending.debtUsdc(alice);

        _repay(alice, debtAfterInterest);

        assertEq(lending.debtUsdc(alice), 0);
    }

    function test_interestAccrualIncreasesTotalBorrowedAndSupplied() public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 1_000e6);

        uint256 borrowedBefore = lending.totalBorrowedUsdc();
        uint256 suppliedBefore = lending.totalSuppliedUsdc();

        vm.warp(block.timestamp + 365 days);
        lending.accrueInterest();

        assertGt(lending.totalBorrowedUsdc(), borrowedBefore);
        assertGt(lending.totalSuppliedUsdc(), suppliedBefore);
    }

    function test_supplyWithdrawCanClaimInterestAfterRepayAddsLiquidity() public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 1_000e6);

        vm.warp(block.timestamp + 365 days);
        uint256 debtAfterInterest = lending.debtUsdc(alice);
        _repay(alice, debtAfterInterest);

        uint256 charlieBalanceBefore = usdc.balanceOf(charlie);
        uint256 withdrawAmount = lending.suppliedUsdc(charlie);

        vm.prank(charlie);
        lending.withdrawBase(withdrawAmount);

        assertGt(usdc.balanceOf(charlie), charlieBalanceBefore + 10_000_000e6);
        assertEq(lending.suppliedUsdc(charlie), 0);
    }
}
