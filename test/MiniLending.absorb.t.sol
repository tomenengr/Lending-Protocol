// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MiniLendingTestBase} from "./helpers/MiniLendingTestBase.sol";

contract MiniLendingAbsorbTest is MiniLendingTestBase {
    event Absorbed(
        address indexed absorber, address indexed borrower, uint256 debtAbsorbedUsdc, uint256 badDebtRecognizedUsdc
    );
    event CollateralPurchased(
        address indexed buyer, address indexed collateralAsset, uint256 paidUsdc, uint256 collateralPurchased
    );

    function test_revertAbsorbHealthyPosition() public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 2_000e6);

        vm.expectRevert(bytes("POSITION_HEALTHY"));
        lending.absorb(alice);
    }

    function test_absorbAfterPriceDropClearsDebtAndMovesCollateralToProtocol() public {
        _prepareAliceLiquidatable();

        lending.absorb(alice);

        assertEq(lending.debtUsdc(alice), 0);
        assertEq(lending.collateralBalance(alice, address(weth)), 0);
        assertEq(lending.protocolCollateralBalance(address(weth)), 1 ether);
    }

    function test_absorbRecordsBadDebtFromDiscountedCollateralRecovery() public {
        _prepareAliceLiquidatable();

        uint256 expectedBadDebt = 2_000e6 - (2_000e6 * BPS / 11_000);

        lending.absorb(alice);

        assertEq(lending.badDebtUsdc(), expectedBadDebt);
    }

    function test_absorbUsesProtocolReservesBeforeRecordingBadDebt() public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 2_000e6);

        vm.warp(block.timestamp + 365 days);
        uint256 debtBeforeAbsorb = lending.debtUsdc(alice);
        lending.accrueInterest();
        uint256 reservesBefore = lending.protocolReservesUsdc();

        _setWethPrice(2_000);
        usdcFeed.updateAnswer(1e8);
        uint256 discountedRecovery = 2_000e6 * BPS / 11_000;
        uint256 expectedBadDebtBeforeReserves = debtBeforeAbsorb - discountedRecovery;
        uint256 expectedBadDebtAfterReserves =
            expectedBadDebtBeforeReserves > reservesBefore ? expectedBadDebtBeforeReserves - reservesBefore : 0;

        lending.absorb(alice);

        assertEq(lending.badDebtUsdc(), expectedBadDebtAfterReserves);
        assertEq(lending.protocolReservesUsdc(), 0);
    }

    function test_absorbEmitsEvent() public {
        _prepareAliceLiquidatable();
        uint256 expectedBadDebt = 2_000e6 - (2_000e6 * BPS / 11_000);

        vm.expectEmit(true, true, false, true);
        emit Absorbed(address(this), alice, 2_000e6, expectedBadDebt);
        lending.absorb(alice);
    }

    function test_buyCollateralPurchasesProtocolCollateralWithDiscount() public {
        _prepareAliceLiquidatable();
        lending.absorb(alice);

        uint256 bobWethBefore = weth.balanceOf(bob);

        vm.startPrank(bob);
        usdc.approve(address(lending), 1_000e6);
        lending.buyCollateral(address(weth), 1_000e6, 0.55 ether);
        vm.stopPrank();

        assertEq(weth.balanceOf(bob), bobWethBefore + 0.55 ether);
        assertEq(lending.protocolCollateralBalance(address(weth)), 0.45 ether);
    }

    function test_buyCollateralTransfersUSDCToProtocol() public {
        _prepareAliceLiquidatable();
        lending.absorb(alice);

        uint256 protocolUsdcBefore = usdc.balanceOf(address(lending));

        vm.startPrank(bob);
        usdc.approve(address(lending), 1_000e6);
        lending.buyCollateral(address(weth), 1_000e6, 0);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(lending)), protocolUsdcBefore + 1_000e6);
    }

    function test_buyCollateralEmitsEvent() public {
        _prepareAliceLiquidatable();
        lending.absorb(alice);

        vm.startPrank(bob);
        usdc.approve(address(lending), 1_000e6);
        vm.expectEmit(true, true, false, true);
        emit CollateralPurchased(bob, address(weth), 1_000e6, 0.55 ether);
        lending.buyCollateral(address(weth), 1_000e6, 0);
        vm.stopPrank();
    }

    function test_revertBuyCollateralIfSlippageLimitIsNotMet() public {
        _prepareAliceLiquidatable();
        lending.absorb(alice);

        vm.startPrank(bob);
        usdc.approve(address(lending), 1_000e6);
        vm.expectRevert(bytes("SLIPPAGE"));
        lending.buyCollateral(address(weth), 1_000e6, 0.56 ether);
        vm.stopPrank();
    }

    function test_revertBuyCollateralIfProtocolCollateralIsInsufficient() public {
        _prepareAliceLiquidatable();
        lending.absorb(alice);

        vm.startPrank(bob);
        usdc.approve(address(lending), 2_000e6);
        vm.expectRevert(bytes("INSUFFICIENT_PROTOCOL_COLLATERAL"));
        lending.buyCollateral(address(weth), 2_000e6, 0);
        vm.stopPrank();
    }

    function test_revertBuyCollateralUnsupportedAsset() public {
        vm.expectRevert(bytes("UNSUPPORTED_ASSET"));
        lending.buyCollateral(unsupported, 1_000e6, 0);
    }

    function test_revertBuyCollateralZeroAmount() public {
        vm.expectRevert(bytes("ZERO_AMOUNT"));
        lending.buyCollateral(address(weth), 0, 0);
    }
}
