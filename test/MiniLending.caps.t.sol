// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MiniLendingTestBase} from "./helpers/MiniLendingTestBase.sol";

contract MiniLendingCapsTest is MiniLendingTestBase {
    event GlobalBorrowCapSet(uint256 newCapUsdc);

    function test_totalCollateralTracksDepositWithdrawLiquidationAndAbsorb() public {
        _depositWeth(alice, 2 ether);

        vm.prank(alice);
        lending.withdrawCollateral(address(weth), 0.5 ether);
        assertEq(lending.totalCollateral(address(weth)), 1.5 ether);

        _borrow(alice, 2_250e6);
        _setWethPrice(1_500);
        vm.startPrank(bob);
        usdc.approve(address(lending), 1_125e6);
        lending.liquidate(alice, address(weth), 1_125e6);
        vm.stopPrank();
        assertEq(lending.totalCollateral(address(weth)), 0.675 ether);

        lending.absorb(alice);
        assertEq(lending.totalCollateral(address(weth)), 0);
        assertEq(lending.protocolCollateralBalance(address(weth)), 0.675 ether);
    }

    function test_supplyCapAllowsExactCapAndRejectsExcess() public {
        weth.mint(alice, 10_000 ether);
        _depositWeth(alice, 10_000 ether);
        assertEq(lending.totalCollateral(address(weth)), 10_000 ether);

        weth.mint(bob, 1);
        vm.startPrank(bob);
        weth.approve(address(lending), 1);
        vm.expectRevert(bytes("SUPPLY_CAP_EXCEEDED"));
        lending.depositCollateral(address(weth), 1);
        vm.stopPrank();
    }

    function test_revertSingleDepositAboveSupplyCap() public {
        weth.mint(alice, 10_001 ether);

        vm.startPrank(alice);
        weth.approve(address(lending), 10_001 ether);
        vm.expectRevert(bytes("SUPPLY_CAP_EXCEEDED"));
        lending.depositCollateral(address(weth), 10_001 ether);
        vm.stopPrank();
    }

    function test_globalBorrowCapAllowsExactCapAndRejectsExcess() public {
        weth.mint(alice, 4_000 ether);
        _depositWeth(alice, 4_000 ether);
        _borrow(alice, lending.globalBorrowCapUsdc());
        assertEq(lending.totalBorrowedUsdc(), lending.globalBorrowCapUsdc());

        vm.prank(alice);
        vm.expectRevert(bytes("BORROW_CAP_EXCEEDED"));
        lending.borrow(1);
    }

    function test_setGlobalBorrowCapUpdatesAndEmitsEvent() public {
        uint256 newCap = 5_000_000e6;
        vm.expectEmit(false, false, false, true);
        emit GlobalBorrowCapSet(newCap);
        lending.setGlobalBorrowCap(newCap);
        assertEq(lending.globalBorrowCapUsdc(), newCap);
    }

    function test_setGlobalBorrowCapRevertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(bytes("ONLY_OWNER"));
        lending.setGlobalBorrowCap(1_000_000e6);
    }

    function test_setGlobalBorrowCapRevertsForZero() public {
        vm.expectRevert(bytes("ZERO_BORROW_CAP"));
        lending.setGlobalBorrowCap(0);
    }
}
