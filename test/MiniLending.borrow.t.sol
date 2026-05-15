// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MiniLendingTestBase} from "./helpers/MiniLendingTestBase.sol";

contract MiniLendingBorrowTest is MiniLendingTestBase {
    event Borrowed(address indexed user, uint256 amountUSDC);

    function test_borrowWithinLimit() public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 2_000e6);

        assertEq(usdc.balanceOf(alice), 1_002_000e6);
    }

    function test_revertBorrowWithoutCollateral() public {
        vm.prank(alice);
        vm.expectRevert(bytes("BORROW_LIMIT_EXCEEDED"));
        lending.borrow(1e6);
    }

    function test_revertBorrowAboveLimit() public {
        _depositWeth(alice, 1 ether);

        vm.prank(alice);
        vm.expectRevert(bytes("BORROW_LIMIT_EXCEEDED"));
        lending.borrow(2_250e6 + 1);
    }

    function test_borrowUpdatesDebt() public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 2_000e6);

        assertEq(lending.debtUSDC(alice), 2_000e6);
    }

    function test_borrowTransfersUSDC() public {
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 protocolBefore = usdc.balanceOf(address(lending));

        _depositWeth(alice, 1 ether);
        _borrow(alice, 1_500e6);

        assertEq(usdc.balanceOf(alice), aliceBefore + 1_500e6);
        assertEq(usdc.balanceOf(address(lending)), protocolBefore - 1_500e6);
    }

    function test_healthFactorAfterBorrow() public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 2_000e6);

        assertEq(lending.getHealthFactor(alice), 1.2e18);
    }

    function test_borrowMaxCollateralFactorAllowed() public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 2_250e6);

        assertEq(lending.debtUSDC(alice), 2_250e6);
        assertGt(lending.getHealthFactor(alice), 1e18);
    }

    function test_multipleBorrowsRespectTotalDebtLimit() public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 1_000e6);
        _borrow(alice, 1_000e6);

        vm.prank(alice);
        vm.expectRevert(bytes("BORROW_LIMIT_EXCEEDED"));
        lending.borrow(251e6);
    }

    function test_borrowAgainstWBTC() public {
        _depositWbtc(alice, 1e8);
        _borrow(alice, 42_000e6);

        assertEq(lending.debtUSDC(alice), 42_000e6);
        assertEq(lending.getHealthFactor(alice), 60_000e18 * 7_500 / BPS * WAD / 42_000e18);
    }

    function test_revertBorrowZeroAmount() public {
        _depositWeth(alice, 1 ether);

        vm.prank(alice);
        vm.expectRevert(bytes("ZERO_AMOUNT"));
        lending.borrow(0);
    }

    function test_borrowEmitsEvent() public {
        _depositWeth(alice, 1 ether);

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit Borrowed(alice, 1_000e6);
        lending.borrow(1_000e6);
    }
}
