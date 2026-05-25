// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MiniLendingTestBase} from "./helpers/MiniLendingTestBase.sol";

contract MiniLendingPauseTest is MiniLendingTestBase {
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event AssetFrozenSet(address indexed asset, bool frozen);

    function test_ownerCanTransferOwnershipAndRejectsInvalidAdminActions() public {
        address newOwner = makeAddr("newOwner");
        assertEq(lending.owner(), address(this));

        vm.expectEmit(true, true, false, true);
        emit OwnershipTransferred(address(this), newOwner);
        lending.transferOwnership(newOwner);
        assertEq(lending.owner(), newOwner);

        vm.prank(newOwner);
        vm.expectRevert(bytes("ZERO_OWNER"));
        lending.transferOwnership(address(0));

        vm.prank(alice);
        vm.expectRevert(bytes("ONLY_OWNER"));
        lending.setPaused(true);
    }

    function test_pauseBlocksUserEntryPointsButAllowsRiskResolution() public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 1_000e6);
        lending.setPaused(true);

        vm.startPrank(alice);
        weth.approve(address(lending), 1 ether);
        vm.expectRevert(bytes("PAUSED"));
        lending.depositCollateral(address(weth), 1 ether);
        vm.expectRevert(bytes("PAUSED"));
        lending.withdrawCollateral(address(weth), 0.1 ether);
        vm.expectRevert(bytes("PAUSED"));
        lending.borrow(1e6);
        vm.stopPrank();

        _repay(alice, 500e6);
        assertEq(lending.debtUsdc(alice), 500e6);
    }

    function test_pauseBlocksBaseSupplyWithdrawAndBuyCollateral() public {
        _supplyBase(alice, 1_000e6);
        _prepareAliceLiquidatable();
        lending.absorb(alice);
        lending.setPaused(true);

        vm.startPrank(alice);
        usdc.approve(address(lending), 1_000e6);
        vm.expectRevert(bytes("PAUSED"));
        lending.supplyBase(1_000e6);
        vm.expectRevert(bytes("PAUSED"));
        lending.withdrawBase(1_000e6);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(lending), 1_000e6);
        vm.expectRevert(bytes("PAUSED"));
        lending.buyCollateral(address(weth), 1_000e6, 0);
        vm.stopPrank();
    }

    function test_liquidateAndAbsorbAllowedWhilePaused() public {
        _prepareAliceLiquidatable();
        lending.setPaused(true);

        vm.startPrank(bob);
        usdc.approve(address(lending), 1_000e6);
        lending.liquidate(alice, address(weth), 1_000e6);
        vm.stopPrank();
        assertEq(lending.debtUsdc(alice), 1_000e6);

        lending.absorb(alice);
        assertEq(lending.debtUsdc(alice), 0);
    }

    function test_freezeBlocksNewDepositsAndBorrowButAllowsUnwind() public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 1_000e6);

        vm.expectEmit(true, false, false, true);
        emit AssetFrozenSet(address(weth), true);
        lending.setAssetFrozen(address(weth), true);

        vm.startPrank(bob);
        weth.approve(address(lending), 1 ether);
        vm.expectRevert(bytes("ASSET_FROZEN"));
        lending.depositCollateral(address(weth), 1 ether);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(bytes("FROZEN_COLLATERAL"));
        lending.borrow(1e6);

        _repay(alice, 1_000e6);
        vm.prank(alice);
        lending.withdrawCollateral(address(weth), 1 ether);
        assertEq(lending.collateralBalance(alice, address(weth)), 0);
    }

    function test_revertFreezeInvalidCallerOrAsset() public {
        vm.expectRevert(bytes("UNSUPPORTED_ASSET"));
        lending.setAssetFrozen(unsupported, true);

        vm.prank(alice);
        vm.expectRevert(bytes("ONLY_OWNER"));
        lending.setAssetFrozen(address(weth), true);
    }
}
