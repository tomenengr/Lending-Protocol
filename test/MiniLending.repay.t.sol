// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MiniLendingTestBase} from "./helpers/MiniLendingTestBase.sol";

contract MiniLendingRepayTest is MiniLendingTestBase {
    event Repaid(address indexed user, uint256 amountUsdc);

    function setUp() public override {
        super.setUp();
        _depositWeth(alice, 1 ether);
        _borrow(alice, 2_000e6);
    }

    function test_repayPartialDebtUpdatesDebtHealthAndCash() public {
        uint256 protocolBefore = usdc.balanceOf(address(lending));
        uint256 healthBefore = lending.getHealthFactor(alice);

        vm.startPrank(alice);
        usdc.approve(address(lending), 500e6);
        vm.expectEmit(true, false, false, true);
        emit Repaid(alice, 500e6);
        lending.repay(500e6);
        vm.stopPrank();

        assertEq(lending.debtUsdc(alice), 1_500e6);
        assertGt(lending.getHealthFactor(alice), healthBefore);
        assertEq(usdc.balanceOf(address(lending)), protocolBefore + 500e6);
    }

    function test_repayMoreThanDebtOnlyTakesOutstandingDebt() public {
        uint256 aliceBefore = usdc.balanceOf(alice);
        _repay(alice, 3_000e6);

        assertEq(lending.debtUsdc(alice), 0);
        assertEq(usdc.balanceOf(alice), aliceBefore - 2_000e6);
    }

    function test_multipleRepaysCanClearDebt() public {
        _repay(alice, 400e6);
        _repay(alice, 1_600e6);

        assertEq(lending.debtUsdc(alice), 0);
    }

    function test_revertRepayInvalidStateOrAmount() public {
        vm.prank(alice);
        vm.expectRevert(bytes("ZERO_AMOUNT"));
        lending.repay(0);

        vm.startPrank(bob);
        usdc.approve(address(lending), 100e6);
        vm.expectRevert(bytes("NO_DEBT"));
        lending.repay(100e6);
        vm.stopPrank();
    }

    function test_revertRepayWithoutAllowance() public {
        vm.prank(alice);
        vm.expectRevert(bytes("ERC20_INSUFFICIENT_ALLOWANCE"));
        lending.repay(500e6);
    }
}
