// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MiniLendingTestBase} from "./helpers/MiniLendingTestBase.sol";

contract MiniLendingRecapitalizationTest is MiniLendingTestBase {
    event BadDebtRecapitalized(address indexed payer, uint256 amountUsdc);

    function test_recapitalizeBadDebtPartialAndFull() public {
        uint256 badDebt = _createBadDebt();
        uint256 half = badDebt / 2;

        _recapitalize(bob, half);
        assertEq(lending.badDebtUsdc(), badDebt - half);

        _recapitalize(bob, badDebt);
        assertEq(lending.badDebtUsdc(), 0);
    }

    function test_recapitalizeTakesOnlyOutstandingDebtAndTransfersCash() public {
        uint256 badDebt = _createBadDebt();
        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 protocolBefore = usdc.balanceOf(address(lending));

        vm.startPrank(bob);
        usdc.approve(address(lending), badDebt + 1_000e6);
        vm.expectEmit(true, false, false, true);
        emit BadDebtRecapitalized(bob, badDebt);
        lending.recapitalizeBadDebt(badDebt + 1_000e6);
        vm.stopPrank();

        assertEq(lending.badDebtUsdc(), 0);
        assertEq(usdc.balanceOf(bob), bobBefore - badDebt);
        assertEq(usdc.balanceOf(address(lending)), protocolBefore + badDebt);
    }

    function test_recapitalizeIsPermissionlessAndAllowedWhilePaused() public {
        uint256 badDebt = _createBadDebt();
        lending.setPaused(true);

        _recapitalize(alice, badDebt);

        assertEq(lending.badDebtUsdc(), 0);
    }

    function test_revertRecapitalizeInvalidInputOrAllowance() public {
        vm.prank(bob);
        vm.expectRevert(bytes("NO_BAD_DEBT"));
        lending.recapitalizeBadDebt(1e6);

        uint256 badDebt = _createBadDebt();
        vm.prank(bob);
        vm.expectRevert(bytes("ZERO_AMOUNT"));
        lending.recapitalizeBadDebt(0);

        vm.prank(bob);
        vm.expectRevert(bytes("ERC20_INSUFFICIENT_ALLOWANCE"));
        lending.recapitalizeBadDebt(badDebt);
    }

    function _createBadDebt() internal returns (uint256 badDebt) {
        _prepareAliceLiquidatable();
        lending.absorb(alice);

        badDebt = lending.badDebtUsdc();
        assertGt(badDebt, 0);
    }

    function _recapitalize(address payer, uint256 amountUsdc) internal {
        vm.startPrank(payer);
        usdc.approve(address(lending), amountUsdc);
        lending.recapitalizeBadDebt(amountUsdc);
        vm.stopPrank();
    }
}
