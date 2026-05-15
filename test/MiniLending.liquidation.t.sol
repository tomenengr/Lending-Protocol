// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MiniLendingTestBase} from "./helpers/MiniLendingTestBase.sol";

contract MiniLendingLiquidationTest is MiniLendingTestBase {
    event Liquidated(
        address indexed liquidator,
        address indexed borrower,
        address indexed collateralAsset,
        uint256 repaidUSDC,
        uint256 seizedCollateral
    );

    function test_revertLiquidateHealthyPosition() public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 2_000e6);

        vm.startPrank(bob);
        usdc.approve(address(lending), 1_000e6);
        vm.expectRevert(bytes("POSITION_HEALTHY"));
        lending.liquidate(alice, address(weth), 1_000e6);
        vm.stopPrank();
    }

    function test_liquidateAfterPriceDrop() public {
        _prepareAliceLiquidatable();

        vm.startPrank(bob);
        usdc.approve(address(lending), 1_000e6);
        lending.liquidate(alice, address(weth), 1_000e6);
        vm.stopPrank();

        assertEq(lending.debtUSDC(alice), 1_000e6);
    }

    function test_liquidatorRepaysDebt() public {
        _prepareAliceLiquidatable();
        uint256 bobBefore = usdc.balanceOf(bob);

        vm.startPrank(bob);
        usdc.approve(address(lending), 1_000e6);
        lending.liquidate(alice, address(weth), 1_000e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(bob), bobBefore - 1_000e6);
    }

    function test_liquidatorReceivesDiscountedCollateral() public {
        _prepareAliceLiquidatable();
        uint256 bobCollateralBefore = weth.balanceOf(bob);

        vm.startPrank(bob);
        usdc.approve(address(lending), 1_000e6);
        lending.liquidate(alice, address(weth), 1_000e6);
        vm.stopPrank();

        assertEq(weth.balanceOf(bob), bobCollateralBefore + 0.55 ether);
    }

    function test_liquidationReducesBorrowerDebt() public {
        _prepareAliceLiquidatable();

        vm.startPrank(bob);
        usdc.approve(address(lending), 500e6);
        lending.liquidate(alice, address(weth), 500e6);
        vm.stopPrank();

        assertEq(lending.debtUSDC(alice), 1_500e6);
    }

    function test_liquidationReducesBorrowerCollateral() public {
        _prepareAliceLiquidatable();

        vm.startPrank(bob);
        usdc.approve(address(lending), 1_000e6);
        lending.liquidate(alice, address(weth), 1_000e6);
        vm.stopPrank();

        assertEq(lending.collateralBalance(alice, address(weth)), 0.45 ether);
    }

    function test_liquidationCapsRepayToCloseFactor() public {
        _prepareAliceLiquidatable();
        uint256 bobBefore = usdc.balanceOf(bob);

        vm.startPrank(bob);
        usdc.approve(address(lending), 2_000e6);
        lending.liquidate(alice, address(weth), 2_000e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(bob), bobBefore - 1_000e6);
        assertEq(lending.debtUSDC(alice), 1_000e6);
        assertEq(lending.collateralBalance(alice, address(weth)), 0.45 ether);
    }

    function test_revertLiquidateZeroAmount() public {
        _prepareAliceLiquidatable();

        vm.prank(bob);
        vm.expectRevert(bytes("ZERO_AMOUNT"));
        lending.liquidate(alice, address(weth), 0);
    }

    function test_revertLiquidateUnsupportedCollateral() public {
        _prepareAliceLiquidatable();

        vm.prank(bob);
        vm.expectRevert(bytes("UNSUPPORTED_ASSET"));
        lending.liquidate(alice, unsupported, 1_000e6);
    }

    function test_liquidationEmitsEvent() public {
        _prepareAliceLiquidatable();

        vm.startPrank(bob);
        usdc.approve(address(lending), 1_000e6);
        vm.expectEmit(true, true, true, true);
        emit Liquidated(bob, alice, address(weth), 1_000e6, 0.55 ether);
        lending.liquidate(alice, address(weth), 1_000e6);
        vm.stopPrank();
    }

    function test_revertLiquidateWhenCollateralIsInsufficientToPayBonus() public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 2_250e6);
        _setWethPrice(1_100);

        vm.startPrank(bob);
        usdc.approve(address(lending), 1_125e6);
        vm.expectRevert(bytes("INSUFFICIENT_COLLATERAL_TO_SEIZE"));
        lending.liquidate(alice, address(weth), 1_125e6);
        vm.stopPrank();
    }
}
