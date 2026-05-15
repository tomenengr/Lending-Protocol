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
        assertGt(lending.debtUSDC(alice), 1_000e6);
    }

    function test_supplyIndexAccruesFromBorrowInterest() public {
        uint256 suppliedBefore = lending.suppliedUSDC(charlie);

        _depositWeth(alice, 1 ether);
        _borrow(alice, 1_000e6);

        vm.warp(block.timestamp + 365 days);
        lending.accrueInterest();

        assertGt(lending.supplyIndex(), WAD);
        assertGt(lending.suppliedUSDC(charlie), suppliedBefore);
    }

    function test_debtViewIncludesPendingInterestBeforeAccrue() public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 1_000e6);

        vm.warp(block.timestamp + 365 days);

        assertGt(lending.debtUSDC(alice), 1_000e6);
    }

    function test_repayAfterInterestPaysAccruedDebt() public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 1_000e6);

        vm.warp(block.timestamp + 365 days);
        uint256 debtAfterInterest = lending.debtUSDC(alice);

        _repay(alice, debtAfterInterest);

        assertEq(lending.debtUSDC(alice), 0);
    }

    function test_interestAccrualIncreasesTotalBorrowedAndSupplied() public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 1_000e6);

        uint256 borrowedBefore = lending.totalBorrowedUSDC();
        uint256 suppliedBefore = lending.totalSuppliedUSDC();

        vm.warp(block.timestamp + 365 days);
        lending.accrueInterest();

        assertGt(lending.totalBorrowedUSDC(), borrowedBefore);
        assertGt(lending.totalSuppliedUSDC(), suppliedBefore);
    }

    function test_supplyWithdrawCanClaimInterestAfterRepayAddsLiquidity() public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 1_000e6);

        vm.warp(block.timestamp + 365 days);
        uint256 debtAfterInterest = lending.debtUSDC(alice);
        _repay(alice, debtAfterInterest);

        uint256 charlieBalanceBefore = usdc.balanceOf(charlie);
        uint256 withdrawAmount = lending.suppliedUSDC(charlie);

        vm.prank(charlie);
        lending.withdrawBase(withdrawAmount);

        assertGt(usdc.balanceOf(charlie), charlieBalanceBefore + 10_000_000e6);
        assertEq(lending.suppliedUSDC(charlie), 0);
    }
}
