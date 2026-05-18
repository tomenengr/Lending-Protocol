// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MiniLendingTestBase} from "./helpers/MiniLendingTestBase.sol";

contract MiniLendingCapsTest is MiniLendingTestBase {
    function test_depositUpdatesTotalCollateral() public {
        _depositWeth(alice, 1 ether);
        _depositWbtc(bob, 2e8);

        assertEq(lending.totalCollateral(address(weth)), 1 ether);
        assertEq(lending.totalCollateral(address(wbtc)), 2e8);
    }

    function test_withdrawReducesTotalCollateral() public {
        _depositWeth(alice, 2 ether);

        vm.prank(alice);
        lending.withdrawCollateral(address(weth), 0.5 ether);

        assertEq(lending.totalCollateral(address(weth)), 1.5 ether);
    }

    function test_liquidationReducesTotalCollateral() public {
        _prepareAliceLiquidatable();

        vm.startPrank(bob);
        usdc.approve(address(lending), 1_000e6);
        lending.liquidate(alice, address(weth), 1_000e6);
        vm.stopPrank();

        assertEq(lending.totalCollateral(address(weth)), 0.45 ether);
    }

    function test_absorbMovesCollateralOutOfUserSupplyCapAccounting() public {
        _prepareAliceLiquidatable();

        lending.absorb(alice);

        assertEq(lending.totalCollateral(address(weth)), 0);
        assertEq(lending.protocolCollateralBalance(address(weth)), 1 ether);
    }

    function test_depositUpToSupplyCapSucceeds() public {
        weth.mint(alice, 10_000 ether);

        _depositWeth(alice, 10_000 ether);

        assertEq(lending.totalCollateral(address(weth)), 10_000 ether);
    }

    function test_revertDepositAboveSupplyCap() public {
        weth.mint(alice, 10_001 ether);

        vm.startPrank(alice);
        weth.approve(address(lending), 10_001 ether);
        vm.expectRevert(bytes("SUPPLY_CAP_EXCEEDED"));
        lending.depositCollateral(address(weth), 10_001 ether);
        vm.stopPrank();
    }

    function test_revertDepositThatWouldExceedRemainingSupplyCap() public {
        weth.mint(alice, 10_000 ether);
        weth.mint(bob, 1);
        _depositWeth(alice, 10_000 ether);

        vm.startPrank(bob);
        weth.approve(address(lending), 1);
        vm.expectRevert(bytes("SUPPLY_CAP_EXCEEDED"));
        lending.depositCollateral(address(weth), 1);
        vm.stopPrank();
    }

    function test_borrowUpToGlobalBorrowCapSucceeds() public {
        weth.mint(alice, 4_000 ether);
        _depositWeth(alice, 4_000 ether);

        _borrow(alice, lending.GLOBAL_BORROW_CAP_USDC());

        assertEq(lending.totalBorrowedUsdc(), lending.GLOBAL_BORROW_CAP_USDC());
    }

    function test_revertBorrowAboveGlobalBorrowCap() public {
        weth.mint(alice, 4_000 ether);
        _depositWeth(alice, 4_000 ether);
        _borrow(alice, lending.GLOBAL_BORROW_CAP_USDC());

        vm.prank(alice);
        vm.expectRevert(bytes("BORROW_CAP_EXCEEDED"));
        lending.borrow(1);
    }
}
