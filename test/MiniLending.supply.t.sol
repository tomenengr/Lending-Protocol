// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MiniLendingTestBase} from "./helpers/MiniLendingTestBase.sol";

contract MiniLendingSupplyTest is MiniLendingTestBase {
    event BaseSupplied(address indexed user, uint256 amountUsdc);
    event BaseWithdrawn(address indexed user, uint256 amountUsdc);

    function test_supplyAndWithdrawBaseUpdatesAccountingAndBalances() public {
        uint256 protocolBefore = usdc.balanceOf(address(lending));

        vm.startPrank(alice);
        usdc.approve(address(lending), 1_000e6);
        vm.expectEmit(true, false, false, true);
        emit BaseSupplied(alice, 1_000e6);
        lending.supplyBase(1_000e6);
        vm.expectEmit(true, false, false, true);
        emit BaseWithdrawn(alice, 400e6);
        lending.withdrawBase(400e6);
        vm.stopPrank();

        assertEq(lending.suppliedUsdc(alice), 600e6);
        assertEq(usdc.balanceOf(address(lending)), protocolBefore + 600e6);
    }

    function test_withdrawBaseFullClearsSupply() public {
        _supplyBase(alice, 1_000e6);
        _withdrawBase(alice, 1_000e6);

        assertEq(lending.suppliedUsdc(alice), 0);
    }

    function test_revertSupplyAndWithdrawInvalidAmounts() public {
        vm.prank(alice);
        vm.expectRevert(bytes("ZERO_AMOUNT"));
        lending.supplyBase(0);

        _supplyBase(alice, 1_000e6);
        vm.prank(alice);
        vm.expectRevert(bytes("INSUFFICIENT_SUPPLY"));
        lending.withdrawBase(1_000e6 + 1);
    }

    function test_revertWithdrawBaseWhenLiquidityIsInsufficient() public {
        address smallSupplier = makeAddr("smallSupplier");
        usdc.mint(smallSupplier, 1_000e6);
        _supplyBase(smallSupplier, 1_000e6);
        _withdrawBase(charlie, 1_001_000e6);

        weth.mint(alice, 4_000 ether);
        _depositWeth(alice, 4_000 ether);
        _borrow(alice, lending.globalBorrowCapUsdc());

        vm.prank(smallSupplier);
        vm.expectRevert(bytes("INSUFFICIENT_LIQUIDITY"));
        lending.withdrawBase(1_000e6);
    }

    function test_borrowUsesBaseLiquidityAndUpdatesUtilization() public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 2_000e6);

        // utilization = totalBorrows / (cash + totalBorrows - reserves)
        // cash = 10_000_000e6 - 2_000e6 = 9_998_000e6, reserves ≈ 0, borrows = 2_000e6
        // util = 2_000e6 / (9_998_000e6 + 2_000e6) = 2_000e6 / 10_000_000e6
        uint256 cash = usdc.balanceOf(address(lending));
        uint256 reserves = lending.protocolReservesUsdc();
        uint256 borrows = lending.totalBorrowedUsdc();
        uint256 expectedUtil = borrows * WAD / ((cash - reserves) + borrows);
        assertEq(lending.getUtilization(), expectedUtil);
    }
}
