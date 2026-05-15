// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MiniLendingTestBase} from "./helpers/MiniLendingTestBase.sol";

contract MiniLendingReserveTest is MiniLendingTestBase {
    event ReservesWithdrawn(address indexed recipient, uint256 amountUSDC);

    function test_withdrawReservesTransfersUSDCToRecipient() public {
        uint256 reserves = _generateCashBackedReserves();
        uint256 ownerBefore = usdc.balanceOf(address(this));

        lending.withdrawReserves(address(this), reserves);

        assertEq(usdc.balanceOf(address(this)), ownerBefore + reserves);
        assertEq(lending.protocolReservesUSDC(), 0);
    }

    function test_withdrawPartialReserves() public {
        uint256 reserves = _generateCashBackedReserves();
        uint256 withdrawAmount = reserves / 2;
        uint256 bobBefore = usdc.balanceOf(bob);

        lending.withdrawReserves(bob, withdrawAmount);

        assertEq(usdc.balanceOf(bob), bobBefore + withdrawAmount);
        assertEq(lending.protocolReservesUSDC(), reserves - withdrawAmount);
    }

    function test_withdrawReservesDoesNotReduceAvailableLiquidity() public {
        uint256 reserves = _generateCashBackedReserves();
        uint256 availableBefore = lending.getAvailableLiquidity();

        lending.withdrawReserves(address(this), reserves / 2);

        assertEq(lending.getAvailableLiquidity(), availableBefore);
    }

    function test_withdrawReservesEmitsEvent() public {
        uint256 reserves = _generateCashBackedReserves();

        vm.expectEmit(true, false, false, true);
        emit ReservesWithdrawn(bob, reserves);
        lending.withdrawReserves(bob, reserves);
    }

    function test_revertWithdrawReservesByNonOwner() public {
        uint256 reserves = _generateCashBackedReserves();

        vm.prank(alice);
        vm.expectRevert(bytes("ONLY_OWNER"));
        lending.withdrawReserves(alice, reserves);
    }

    function test_revertWithdrawReservesToZeroAddress() public {
        uint256 reserves = _generateCashBackedReserves();

        vm.expectRevert(bytes("ZERO_RECIPIENT"));
        lending.withdrawReserves(address(0), reserves);
    }

    function test_revertWithdrawReservesZeroAmount() public {
        _generateCashBackedReserves();

        vm.expectRevert(bytes("ZERO_AMOUNT"));
        lending.withdrawReserves(bob, 0);
    }

    function test_revertWithdrawMoreThanReserves() public {
        uint256 reserves = _generateCashBackedReserves();

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
        uint256 reserves = lending.protocolReservesUSDC();
        assertGt(reserves, cash);

        vm.expectRevert(bytes("INSUFFICIENT_RESERVE_CASH"));
        lending.withdrawReserves(bob, cash + 1);
    }

    function test_withdrawReservesAllowedWhilePaused() public {
        uint256 reserves = _generateCashBackedReserves();
        lending.setPaused(true);

        lending.withdrawReserves(bob, reserves);

        assertEq(lending.protocolReservesUSDC(), 0);
    }

    function _generateCashBackedReserves() internal returns (uint256 reserves) {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 1_000e6);

        vm.warp(block.timestamp + 365 days);
        uint256 debtAfterInterest = lending.debtUSDC(alice);
        _repay(alice, debtAfterInterest);

        reserves = lending.protocolReservesUSDC();
        assertGt(reserves, 0);
        assertGe(usdc.balanceOf(address(lending)), reserves);
    }
}
