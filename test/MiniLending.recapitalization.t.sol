// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MiniLendingTestBase} from "./helpers/MiniLendingTestBase.sol";

contract MiniLendingRecapitalizationTest is MiniLendingTestBase {
    event BadDebtRecapitalized(address indexed payer, uint256 amountUsdc);

    function test_recapitalizeBadDebtPartial() public {
        uint256 badDebt = _createBadDebt();
        uint256 amount = badDebt / 2;

        _recapitalize(bob, amount);

        assertEq(lending.badDebtUsdc(), badDebt - amount);
    }

    function test_recapitalizeBadDebtFull() public {
        uint256 badDebt = _createBadDebt();

        _recapitalize(bob, badDebt);

        assertEq(lending.badDebtUsdc(), 0);
    }

    function test_recapitalizeMoreThanBadDebtOnlyTakesBadDebt() public {
        uint256 badDebt = _createBadDebt();
        uint256 bobBefore = usdc.balanceOf(bob);

        _recapitalize(bob, badDebt + 1_000e6);

        assertEq(lending.badDebtUsdc(), 0);
        assertEq(usdc.balanceOf(bob), bobBefore - badDebt);
    }

    function test_recapitalizeTransfersUSDCToProtocol() public {
        uint256 badDebt = _createBadDebt();
        uint256 protocolBefore = usdc.balanceOf(address(lending));

        _recapitalize(bob, badDebt);

        assertEq(usdc.balanceOf(address(lending)), protocolBefore + badDebt);
    }

    function test_recapitalizeEmitsEvent() public {
        uint256 badDebt = _createBadDebt();

        vm.startPrank(bob);
        usdc.approve(address(lending), badDebt);
        vm.expectEmit(true, false, false, true);
        emit BadDebtRecapitalized(bob, badDebt);
        lending.recapitalizeBadDebt(badDebt);
        vm.stopPrank();
    }

    function test_recapitalizeIsPermissionless() public {
        uint256 badDebt = _createBadDebt();

        _recapitalize(alice, badDebt);

        assertEq(lending.badDebtUsdc(), 0);
    }

    function test_recapitalizeAllowedWhilePaused() public {
        uint256 badDebt = _createBadDebt();
        lending.setPaused(true);

        _recapitalize(bob, badDebt);

        assertEq(lending.badDebtUsdc(), 0);
    }

    function test_revertRecapitalizeZeroAmount() public {
        _createBadDebt();

        vm.prank(bob);
        vm.expectRevert(bytes("ZERO_AMOUNT"));
        lending.recapitalizeBadDebt(0);
    }

    function test_revertRecapitalizeWithoutBadDebt() public {
        vm.prank(bob);
        vm.expectRevert(bytes("NO_BAD_DEBT"));
        lending.recapitalizeBadDebt(1e6);
    }

    function test_revertRecapitalizeWithoutAllowance() public {
        uint256 badDebt = _createBadDebt();

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
