// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MiniLendingTestBase} from "./helpers/MiniLendingTestBase.sol";

contract MiniLendingWithdrawTest is MiniLendingTestBase {
    event CollateralWithdrawn(address indexed user, address indexed asset, uint256 amount);

    function test_withdrawWithoutDebt() public {
        _depositWeth(alice, 1 ether);

        vm.prank(alice);
        lending.withdrawCollateral(address(weth), 1 ether);

        assertEq(lending.collateralBalance(alice, address(weth)), 0);
        assertEq(weth.balanceOf(alice), 100 ether);
    }

    function test_withdrawPartialCollateralWithHealthyPosition() public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 1_000e6);

        vm.prank(alice);
        lending.withdrawCollateral(address(weth), 0.5 ether);

        assertEq(lending.collateralBalance(alice, address(weth)), 0.5 ether);
        assertGe(lending.getHealthFactor(alice), 1e18);
    }

    function test_revertWithdrawTooMuch() public {
        _depositWeth(alice, 1 ether);

        vm.prank(alice);
        vm.expectRevert(bytes("INSUFFICIENT_COLLATERAL"));
        lending.withdrawCollateral(address(weth), 1 ether + 1);
    }

    function test_revertWithdrawIfHealthFactorTooLow() public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 2_000e6);

        vm.prank(alice);
        vm.expectRevert(bytes("HF_TOO_LOW"));
        lending.withdrawCollateral(address(weth), 0.2 ether);
    }

    function test_withdrawAfterRepay() public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 2_000e6);
        _repay(alice, 1_000e6);

        vm.prank(alice);
        lending.withdrawCollateral(address(weth), 0.5 ether);

        assertEq(lending.collateralBalance(alice, address(weth)), 0.5 ether);
    }

    function test_withdrawTransfersTokenBack() public {
        _depositWeth(alice, 1 ether);

        vm.prank(alice);
        lending.withdrawCollateral(address(weth), 0.25 ether);

        assertEq(weth.balanceOf(alice), 99.25 ether);
        assertEq(weth.balanceOf(address(lending)), 0.75 ether);
    }

    function test_revertWithdrawZeroAmount() public {
        _depositWeth(alice, 1 ether);

        vm.prank(alice);
        vm.expectRevert(bytes("ZERO_AMOUNT"));
        lending.withdrawCollateral(address(weth), 0);
    }

    function test_revertWithdrawUnsupportedAsset() public {
        vm.prank(alice);
        vm.expectRevert(bytes("UNSUPPORTED_ASSET"));
        lending.withdrawCollateral(unsupported, 1);
    }

    function test_withdrawEmitsEvent() public {
        _depositWeth(alice, 1 ether);

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit CollateralWithdrawn(alice, address(weth), 0.5 ether);
        lending.withdrawCollateral(address(weth), 0.5 ether);
    }

    function test_getAccountDataAfterWithdraw() public {
        _depositWeth(alice, 1 ether);

        vm.prank(alice);
        lending.withdrawCollateral(address(weth), 0.25 ether);

        (uint256 totalCollateralUsd, uint256 borrowableUsd,,) = lending.getAccountData(alice);
        assertEq(totalCollateralUsd, 2_250e18);
        assertEq(borrowableUsd, 1_687.5e18);
    }
}
