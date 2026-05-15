// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MiniLendingTestBase} from "./helpers/MiniLendingTestBase.sol";

contract MiniLendingSupplyTest is MiniLendingTestBase {
    event BaseSupplied(address indexed user, uint256 amountUSDC);
    event BaseWithdrawn(address indexed user, uint256 amountUSDC);

    function test_supplyBaseUpdatesUserBalance() public {
        uint256 amount = 1_000e6;
        _supplyBase(alice, amount);

        assertEq(lending.suppliedUSDC(alice), amount);
    }

    function test_supplyBaseUpdatesTotalSupplied() public {
        uint256 beforeTotal = lending.totalSuppliedUSDC();
        _supplyBase(alice, 1_000e6);

        assertEq(lending.totalSuppliedUSDC(), beforeTotal + 1_000e6);
    }

    function test_supplyBaseTransfersUSDCToProtocol() public {
        uint256 protocolBefore = usdc.balanceOf(address(lending));
        _supplyBase(alice, 2_000e6);

        assertEq(usdc.balanceOf(address(lending)), protocolBefore + 2_000e6);
    }

    function test_revertSupplyBaseZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(bytes("ZERO_AMOUNT"));
        lending.supplyBase(0);
    }

    function test_supplyBaseEmitsEvent() public {
        vm.startPrank(alice);
        usdc.approve(address(lending), 1_000e6);
        vm.expectEmit(true, false, false, true);
        emit BaseSupplied(alice, 1_000e6);
        lending.supplyBase(1_000e6);
        vm.stopPrank();
    }

    function test_withdrawBasePartial() public {
        _supplyBase(alice, 1_000e6);

        vm.prank(alice);
        lending.withdrawBase(400e6);

        assertEq(lending.suppliedUSDC(alice), 600e6);
    }

    function test_withdrawBaseFull() public {
        _supplyBase(alice, 1_000e6);

        vm.prank(alice);
        lending.withdrawBase(1_000e6);

        assertEq(lending.suppliedUSDC(alice), 0);
    }

    function test_revertWithdrawBaseMoreThanSupplied() public {
        _supplyBase(alice, 1_000e6);

        vm.prank(alice);
        vm.expectRevert(bytes("INSUFFICIENT_SUPPLY"));
        lending.withdrawBase(1_000e6 + 1);
    }

    function test_revertWithdrawBaseWhenLiquidityIsBorrowedOut() public {
        address smallSupplier = makeAddr("smallSupplier");
        usdc.mint(smallSupplier, 1_000e6);
        _supplyBase(smallSupplier, 1_000e6);
        _withdrawBase(charlie, 1_001_000e6);

        weth.mint(alice, 4_000 ether);
        _depositWeth(alice, 4_000 ether);
        _borrow(alice, lending.GLOBAL_BORROW_CAP_USDC());

        vm.prank(smallSupplier);
        vm.expectRevert(bytes("INSUFFICIENT_LIQUIDITY"));
        lending.withdrawBase(1_000e6);
    }

    function test_withdrawBaseEmitsEvent() public {
        _supplyBase(alice, 1_000e6);

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit BaseWithdrawn(alice, 250e6);
        lending.withdrawBase(250e6);
    }

    function test_getUtilizationAfterBorrow() public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 2_000e6);

        assertEq(lending.getUtilization(), 2_000e6 * WAD / 10_000_000e6);
    }

    function test_revertBorrowWhenBaseLiquidityIsInsufficient() public {
        address isolatedSupplier = makeAddr("isolatedSupplier");
        usdc.mint(isolatedSupplier, 100e6);

        vm.startPrank(isolatedSupplier);
        usdc.approve(address(lending), 100e6);
        lending.supplyBase(100e6);
        lending.withdrawBase(100e6);
        vm.stopPrank();

        _depositWeth(alice, 100 ether);

        vm.prank(alice);
        vm.expectRevert(bytes("INSUFFICIENT_LIQUIDITY"));
        lending.borrow(20_000_000e6);
    }
}
