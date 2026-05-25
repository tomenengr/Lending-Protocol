// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MiniLendingTestBase} from "./helpers/MiniLendingTestBase.sol";

contract MiniLendingWithdrawTest is MiniLendingTestBase {
    event CollateralWithdrawn(address indexed user, address indexed asset, uint256 amount);

    function test_withdrawCollateralUpdatesAccountingAndTransfersTokens() public {
        _depositWeth(alice, 1 ether);

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit CollateralWithdrawn(alice, address(weth), 0.4 ether);
        lending.withdrawCollateral(address(weth), 0.4 ether);

        assertEq(lending.collateralBalance(alice, address(weth)), 0.6 ether);
        assertEq(lending.totalCollateral(address(weth)), 0.6 ether);
        assertEq(weth.balanceOf(alice), 99.4 ether);
    }

    function test_withdrawRequiresHealthyPosition() public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 2_000e6);

        vm.prank(alice);
        vm.expectRevert(bytes("HF_TOO_LOW"));
        lending.withdrawCollateral(address(weth), 0.5 ether);
    }

    function test_withdrawAfterRepayCanClearCollateral() public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 2_000e6);
        _repay(alice, 2_000e6);

        vm.prank(alice);
        lending.withdrawCollateral(address(weth), 1 ether);

        assertEq(lending.collateralBalance(alice, address(weth)), 0);
    }

    function test_revertWithdrawInvalidInputs() public {
        vm.prank(alice);
        vm.expectRevert(bytes("ZERO_AMOUNT"));
        lending.withdrawCollateral(address(weth), 0);

        vm.prank(alice);
        vm.expectRevert(bytes("UNSUPPORTED_ASSET"));
        lending.withdrawCollateral(unsupported, 1 ether);

        _depositWeth(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("INSUFFICIENT_COLLATERAL"));
        lending.withdrawCollateral(address(weth), 1 ether + 1);
    }
}
