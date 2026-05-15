// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MiniLendingTestBase} from "./helpers/MiniLendingTestBase.sol";

contract MiniLendingPauseTest is MiniLendingTestBase {
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event PausedSet(bool paused);
    event AssetFrozenSet(address indexed asset, bool frozen);

    function test_ownerIsDeployer() public view {
        assertEq(lending.owner(), address(this));
    }

    function test_ownerCanTransferOwnership() public {
        address newOwner = makeAddr("newOwner");

        vm.expectEmit(true, true, false, true);
        emit OwnershipTransferred(address(this), newOwner);
        lending.transferOwnership(newOwner);

        assertEq(lending.owner(), newOwner);
    }

    function test_revertTransferOwnershipToZeroAddress() public {
        vm.expectRevert(bytes("ZERO_OWNER"));
        lending.transferOwnership(address(0));
    }

    function test_revertNonOwnerSetPaused() public {
        vm.prank(alice);
        vm.expectRevert(bytes("ONLY_OWNER"));
        lending.setPaused(true);
    }

    function test_pauseBlocksDepositCollateral() public {
        lending.setPaused(true);

        vm.startPrank(alice);
        weth.approve(address(lending), 1 ether);
        vm.expectRevert(bytes("PAUSED"));
        lending.depositCollateral(address(weth), 1 ether);
        vm.stopPrank();
    }

    function test_pauseBlocksBaseSupply() public {
        lending.setPaused(true);

        vm.startPrank(alice);
        usdc.approve(address(lending), 1_000e6);
        vm.expectRevert(bytes("PAUSED"));
        lending.supplyBase(1_000e6);
        vm.stopPrank();
    }

    function test_pauseBlocksBaseWithdraw() public {
        _supplyBase(alice, 1_000e6);
        lending.setPaused(true);

        vm.prank(alice);
        vm.expectRevert(bytes("PAUSED"));
        lending.withdrawBase(1_000e6);
    }

    function test_pauseBlocksCollateralWithdraw() public {
        _depositWeth(alice, 1 ether);
        lending.setPaused(true);

        vm.prank(alice);
        vm.expectRevert(bytes("PAUSED"));
        lending.withdrawCollateral(address(weth), 1 ether);
    }

    function test_pauseBlocksBorrow() public {
        _depositWeth(alice, 1 ether);
        lending.setPaused(true);

        vm.prank(alice);
        vm.expectRevert(bytes("PAUSED"));
        lending.borrow(1_000e6);
    }

    function test_pauseBlocksBuyCollateral() public {
        _prepareAliceLiquidatable();
        lending.absorb(alice);
        lending.setPaused(true);

        vm.startPrank(bob);
        usdc.approve(address(lending), 1_000e6);
        vm.expectRevert(bytes("PAUSED"));
        lending.buyCollateral(address(weth), 1_000e6, 0);
        vm.stopPrank();
    }

    function test_repayAllowedWhilePaused() public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 1_000e6);
        lending.setPaused(true);

        _repay(alice, 500e6);

        assertEq(lending.debtUSDC(alice), 500e6);
    }

    function test_liquidateAllowedWhilePaused() public {
        _prepareAliceLiquidatable();
        lending.setPaused(true);

        vm.startPrank(bob);
        usdc.approve(address(lending), 1_000e6);
        lending.liquidate(alice, address(weth), 1_000e6);
        vm.stopPrank();

        assertEq(lending.debtUSDC(alice), 1_000e6);
        assertEq(lending.collateralBalance(alice, address(weth)), 0.45 ether);
    }

    function test_absorbAllowedWhilePaused() public {
        _prepareAliceLiquidatable();
        lending.setPaused(true);

        lending.absorb(alice);

        assertEq(lending.debtUSDC(alice), 0);
        assertEq(lending.protocolCollateralBalance(address(weth)), 1 ether);
    }

    function test_setAssetFrozenEmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit AssetFrozenSet(address(weth), true);
        lending.setAssetFrozen(address(weth), true);

        assertTrue(lending.assetFrozen(address(weth)));
    }

    function test_revertFreezeUnsupportedAsset() public {
        vm.expectRevert(bytes("UNSUPPORTED_ASSET"));
        lending.setAssetFrozen(unsupported, true);
    }

    function test_revertNonOwnerFreezeAsset() public {
        vm.prank(alice);
        vm.expectRevert(bytes("ONLY_OWNER"));
        lending.setAssetFrozen(address(weth), true);
    }

    function test_freezeBlocksNewCollateralDepositForAsset() public {
        lending.setAssetFrozen(address(weth), true);

        vm.startPrank(alice);
        weth.approve(address(lending), 1 ether);
        vm.expectRevert(bytes("ASSET_FROZEN"));
        lending.depositCollateral(address(weth), 1 ether);
        vm.stopPrank();
    }

    function test_freezeBlocksBorrowAgainstFrozenCollateral() public {
        _depositWeth(alice, 1 ether);
        lending.setAssetFrozen(address(weth), true);

        vm.prank(alice);
        vm.expectRevert(bytes("FROZEN_COLLATERAL"));
        lending.borrow(1_000e6);
    }

    function test_freezeDoesNotBlockRepayOrWithdrawAfterDebtIsCleared() public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 1_000e6);
        lending.setAssetFrozen(address(weth), true);

        _repay(alice, 1_000e6);

        vm.prank(alice);
        lending.withdrawCollateral(address(weth), 1 ether);

        assertEq(lending.debtUSDC(alice), 0);
        assertEq(lending.collateralBalance(alice, address(weth)), 0);
    }

    function test_freezeDoesNotBlockLiquidation() public {
        _prepareAliceLiquidatable();
        lending.setAssetFrozen(address(weth), true);

        vm.startPrank(bob);
        usdc.approve(address(lending), 1_000e6);
        lending.liquidate(alice, address(weth), 1_000e6);
        vm.stopPrank();

        assertEq(lending.debtUSDC(alice), 1_000e6);
    }
}
