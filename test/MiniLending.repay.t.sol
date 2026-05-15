// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MiniLendingTestBase} from "./helpers/MiniLendingTestBase.sol";

contract MiniLendingRepayTest is MiniLendingTestBase {
    event Repaid(address indexed user, uint256 amountUSDC);

    function setUp() public override {
        super.setUp();
        _depositWeth(alice, 1 ether);
        _borrow(alice, 2_000e6);
    }

    function test_repayPartialDebt() public {
        _repay(alice, 500e6);

        assertEq(lending.debtUSDC(alice), 1_500e6);
    }

    function test_repayFullDebt() public {
        _repay(alice, 2_000e6);

        assertEq(lending.debtUSDC(alice), 0);
    }

    function test_repayMoreThanDebtOnlyTakesDebt() public {
        uint256 aliceBefore = usdc.balanceOf(alice);
        _repay(alice, 3_000e6);

        assertEq(lending.debtUSDC(alice), 0);
        assertEq(usdc.balanceOf(alice), aliceBefore - 2_000e6);
    }

    function test_revertRepayZero() public {
        vm.prank(alice);
        vm.expectRevert(bytes("ZERO_AMOUNT"));
        lending.repay(0);
    }

    function test_revertRepayWithoutDebt() public {
        vm.startPrank(bob);
        usdc.approve(address(lending), 100e6);
        vm.expectRevert(bytes("NO_DEBT"));
        lending.repay(100e6);
        vm.stopPrank();
    }

    function test_repayImprovesHealthFactor() public {
        uint256 beforeHealthFactor = lending.getHealthFactor(alice);
        _repay(alice, 1_000e6);

        assertGt(lending.getHealthFactor(alice), beforeHealthFactor);
    }

    function test_repayTransfersUSDCToProtocol() public {
        uint256 protocolBefore = usdc.balanceOf(address(lending));
        _repay(alice, 750e6);

        assertEq(usdc.balanceOf(address(lending)), protocolBefore + 750e6);
    }

    function test_multipleRepaysReduceDebt() public {
        _repay(alice, 400e6);
        _repay(alice, 600e6);

        assertEq(lending.debtUSDC(alice), 1_000e6);
    }

    function test_repayEmitsEvent() public {
        vm.startPrank(alice);
        usdc.approve(address(lending), 500e6);
        vm.expectEmit(true, false, false, true);
        emit Repaid(alice, 500e6);
        lending.repay(500e6);
        vm.stopPrank();
    }

    function test_revertRepayWithoutAllowance() public {
        vm.prank(alice);
        vm.expectRevert(bytes("ERC20_INSUFFICIENT_ALLOWANCE"));
        lending.repay(500e6);
    }
}
