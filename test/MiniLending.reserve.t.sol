// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MiniLendingTestBase} from "./helpers/MiniLendingTestBase.sol";

contract MiniLendingReserveTest is MiniLendingTestBase {
    event ReservesWithdrawn(address indexed recipient, uint256 amountUsdc);

    function test_withdrawReservesTransfersCashAndUpdatesAccounting() public {
        uint256 reserves = _generateCashBackedReserves();
        uint256 withdrawAmount = reserves / 2;
        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 availableBefore = lending.getAvailableLiquidity();

        vm.expectEmit(true, false, false, true);
        emit ReservesWithdrawn(bob, withdrawAmount);
        lending.withdrawReserves(bob, withdrawAmount);

        assertEq(usdc.balanceOf(bob), bobBefore + withdrawAmount);
        assertEq(lending.protocolReservesUsdc(), reserves - withdrawAmount);
        assertEq(lending.getAvailableLiquidity(), availableBefore);
    }

    function test_withdrawAllReservesAllowedWhilePaused() public {
        uint256 reserves = _generateCashBackedReserves();
        lending.setPaused(true);

        lending.withdrawReserves(bob, reserves);

        assertEq(lending.protocolReservesUsdc(), 0);
    }

    function test_revertWithdrawReservesInvalidCallerOrInput() public {
        uint256 reserves = _generateCashBackedReserves();

        vm.prank(alice);
        vm.expectRevert(bytes("ONLY_OWNER"));
        lending.withdrawReserves(alice, reserves);

        vm.expectRevert(bytes("ZERO_RECIPIENT"));
        lending.withdrawReserves(address(0), reserves);

        vm.expectRevert(bytes("ZERO_AMOUNT"));
        lending.withdrawReserves(bob, 0);

        vm.expectRevert(bytes("INSUFFICIENT_RESERVES"));
        lending.withdrawReserves(bob, reserves + 1);
    }

    function test_revertWithdrawReservesWhenReserveCashIsInsufficient() public {
        weth.mint(alice, 5_000 ether);
        _depositWeth(alice, 5_000 ether);
        _borrow(alice, 9_000_000e6);

        vm.warp(block.timestamp + 10 * 365 days);
        lending.accrueInterest();

        uint256 cash = usdc.balanceOf(address(lending));
        assertGt(lending.protocolReservesUsdc(), cash);

        vm.expectRevert(bytes("INSUFFICIENT_RESERVE_CASH"));
        lending.withdrawReserves(bob, cash + 1);
    }

    function _generateCashBackedReserves() internal returns (uint256 reserves) {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 1_000e6);

        vm.warp(block.timestamp + 365 days);
        _repay(alice, lending.debtUsdc(alice));

        reserves = lending.protocolReservesUsdc();
        assertGt(reserves, 0);
        assertGe(usdc.balanceOf(address(lending)), reserves);
    }
}
