// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MiniLendingTestBase} from "./helpers/MiniLendingTestBase.sol";

contract MiniLendingIsolationTest is MiniLendingTestBase {
    function test_wbtcBorrowableIsCappedByIsolationDebtCeiling() public {
        _depositWbtc(alice, 1e8);

        (, uint256 borrowableUsd,,) = lending.getAccountData(alice);

        assertEq(borrowableUsd, 20_000e18);
    }

    function test_canBorrowUpToIsolationDebtCeiling() public {
        _depositWbtc(alice, 1e8);

        _borrow(alice, 20_000e6);

        assertEq(lending.debtUsdc(alice), 20_000e6);
    }

    function test_revertBorrowAboveIsolationDebtCeiling() public {
        _depositWbtc(alice, 1e8);

        vm.prank(alice);
        vm.expectRevert(bytes("BORROW_LIMIT_EXCEEDED"));
        lending.borrow(20_000e6 + 1);
    }

    function test_nonIsolatedWethKeepsNormalBorrowableValue() public {
        _depositWeth(alice, 1 ether);

        (, uint256 borrowableUsd,,) = lending.getAccountData(alice);

        assertEq(borrowableUsd, 2_250e18);
    }

    function test_revertDepositWethAfterIsolatedWbtc() public {
        _depositWbtc(alice, 1e8);

        vm.startPrank(alice);
        weth.approve(address(lending), 1 ether);
        vm.expectRevert(bytes("ISOLATION_MODE_COLLATERAL"));
        lending.depositCollateral(address(weth), 1 ether);
        vm.stopPrank();
    }

    function test_revertDepositWbtcAfterWeth() public {
        _depositWeth(alice, 1 ether);

        vm.startPrank(alice);
        wbtc.approve(address(lending), 1e8);
        vm.expectRevert(bytes("ISOLATION_MODE_COLLATERAL"));
        lending.depositCollateral(address(wbtc), 1e8);
        vm.stopPrank();
    }

    function test_canAddMoreOfSameIsolatedCollateral() public {
        _depositWbtc(alice, 1e8);
        _depositWbtc(alice, 1e8);

        assertEq(lending.collateralBalance(alice, address(wbtc)), 2e8);
        (, uint256 borrowableUsd,,) = lending.getAccountData(alice);
        assertEq(borrowableUsd, 20_000e18);
    }

    function test_canDepositWethAfterWithdrawingIsolatedWbtc() public {
        _depositWbtc(alice, 1e8);

        vm.prank(alice);
        lending.withdrawCollateral(address(wbtc), 1e8);

        _depositWeth(alice, 1 ether);
        assertEq(lending.collateralBalance(alice, address(weth)), 1 ether);
    }
}
