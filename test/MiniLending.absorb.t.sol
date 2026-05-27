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
    event BadDebtRecovered(address indexed buyer, uint256 amountUsdc);

    function test_absorbLiquidatableAccountClearsDebtAndMovesCollateral() public {
        _prepareAliceLiquidatable();
        uint256 expectedBadDebt = 2_000e6 - (2_000e6 * BPS / 11_000);

        vm.expectEmit(true, true, false, true);
        emit Absorbed(address(this), alice, 2_000e6, expectedBadDebt);
        lending.absorb(alice);

        assertEq(lending.debtUsdc(alice), 0);
        assertEq(lending.collateralBalance(alice, address(weth)), 0);
        assertEq(lending.protocolCollateralBalance(address(weth)), 1 ether);
        assertEq(lending.badDebtUsdc(), expectedBadDebt);
    }

    function test_absorbUsesProtocolReservesBeforeBadDebt() public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 2_000e6);

        vm.warp(block.timestamp + 365 days);
        uint256 debtBeforeAbsorb = lending.debtUsdc(alice);
        lending.accrueInterest();
        uint256 reservesBefore = lending.protocolReservesUsdc();

        _setWethPrice(2_000);
        usdcFeed.updateAnswer(1e8);
        uint256 expectedBadDebtBeforeReserves = debtBeforeAbsorb - (2_000e6 * BPS / 11_000);
        uint256 expectedBadDebt =
            expectedBadDebtBeforeReserves > reservesBefore ? expectedBadDebtBeforeReserves - reservesBefore : 0;

        lending.absorb(alice);

        assertEq(lending.badDebtUsdc(), expectedBadDebt);
        assertEq(lending.protocolReservesUsdc(), 0);
    }

    function test_buyCollateralUsesProtocolCollateralAndTransfersCash() public {
        _prepareAliceLiquidatable();
        lending.absorb(alice);

        // After absorb: collateral value at $2000 with 10% bonus discount =
        // 1 ether * 2000e6 / 1.1 => badDebt = 2000e6 - floor(2000e6*10000/11000) = 181818182
        uint256 badDebtBefore = lending.badDebtUsdc(); // 181818182
        uint256 bobWethBefore = weth.balanceOf(bob);
        uint256 protocolUsdcBefore = usdc.balanceOf(address(lending));

        // Buy 100e6 USDC worth (< badDebt), so entire 100e6 is applied against badDebt.
        // seizeAmount = 100e6 * 1e18 / 1e6 * 11000/10000 / (2000e18) = 0.055 ether
        uint256 purchase = 100e6;
        vm.startPrank(bob);
        usdc.approve(address(lending), purchase);
        // Emit order matches contract: BadDebtRecovered emitted inside _recoverBadDebt,
        // then CollateralPurchased emitted after.
        vm.expectEmit(true, false, false, true);
        emit BadDebtRecovered(bob, purchase); // 100e6 < badDebtBefore, fully applied
        vm.expectEmit(true, true, false, false);
        emit CollateralPurchased(bob, address(weth), purchase, 0); // data checked separately
        lending.buyCollateral(address(weth), purchase, 0);
        vm.stopPrank();

        // Collateral transferred to buyer (0.055 ether)
        assertEq(weth.balanceOf(bob), bobWethBefore + 0.055 ether);
        // USDC cash in contract increased
        assertEq(usdc.balanceOf(address(lending)), protocolUsdcBefore + purchase);
        // protocolCollateralBalance decreased
        assertEq(lending.protocolCollateralBalance(address(weth)), 1 ether - 0.055 ether);
        // Bad debt reduced by exactly the purchase amount
        assertEq(lending.badDebtUsdc(), badDebtBefore - purchase);
    }

    function test_revertAbsorbAndBuyCollateralInvalidInputs() public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 2_000e6);
        vm.expectRevert(bytes("POSITION_HEALTHY"));
        lending.absorb(alice);

        _setWethPrice(2_000);
        lending.absorb(alice);

        vm.expectRevert(bytes("ZERO_AMOUNT"));
        lending.buyCollateral(address(weth), 0, 0);

        vm.expectRevert(bytes("UNSUPPORTED_ASSET"));
        lending.buyCollateral(unsupported, 1_000e6, 0);
    }

    function test_revertBuyCollateralSlippageOrInsufficientInventory() public {
        _prepareAliceLiquidatable();
        lending.absorb(alice);

        vm.startPrank(bob);
        usdc.approve(address(lending), 3_000e6);
        vm.expectRevert(bytes("SLIPPAGE"));
        lending.buyCollateral(address(weth), 1_000e6, 0.56 ether);
        vm.expectRevert(bytes("INSUFFICIENT_PROTOCOL_COLLATERAL"));
        lending.buyCollateral(address(weth), 2_000e6, 0);
        vm.stopPrank();
    }

    /// @notice buyCollateral with amount exactly <= badDebt: bad debt decreases by that
    ///         exact amount, reserves unchanged.
    function test_buyCollateralReducesBadDebt() public {
        _prepareAliceLiquidatable();
        lending.absorb(alice);

        // badDebt after absorb = 2000e6 - floor(2000e6 * 10000 / 11000) = 181818182
        uint256 badDebtBefore = lending.badDebtUsdc();
        uint256 reservesBefore = lending.protocolReservesUsdc();
        require(badDebtBefore > 0, "setup: need bad debt");

        // Buy 100e6 USDC worth, which is strictly less than badDebt (181818182)
        // seize = 100e6 * 1e18/1e6 * 11000/10000 / 2000e18 = 0.055 ether
        uint256 purchase = 100e6;
        require(purchase < badDebtBefore, "setup: purchase must be < badDebt");

        vm.startPrank(bob);
        usdc.approve(address(lending), purchase);
        lending.buyCollateral(address(weth), purchase, 0);
        vm.stopPrank();

        // badDebt reduced by exactly the purchase amount
        assertEq(lending.badDebtUsdc(), badDebtBefore - purchase);
        // reserves untouched (purchase < badDebt, no surplus)
        assertEq(lending.protocolReservesUsdc(), reservesBefore);
    }

    /// @notice buyCollateral with amount > badDebt: bad debt goes to 0, surplus
    ///         is credited to protocolReservesUsdc.
    function test_buyCollateralSurplusGoesToReserves() public {
        _prepareAliceLiquidatable();
        lending.absorb(alice);

        uint256 badDebtBefore = lending.badDebtUsdc();
        uint256 reservesBefore = lending.protocolReservesUsdc();
        require(badDebtBefore > 0, "setup: need bad debt");

        // Buy all collateral: 1 ether at $2000/WETH with 10% bonus.
        // Buyer pays floor(1 ether * 2000 / 1.1) ≈ 1818.18 USDC → rounds to 1_818_181_818 (6 dec).
        // Use a generous approve; contract pulls only what it needs.
        // Seize: 1 ether of WETH costs repayValueUsd/price*1.1 = pay * 1.1.
        // Instead we calculate: to get 1 ether WETH → pay = 1e18*2000e6/1e18/1.1 ≈ 1818.18e6.
        // Round up slightly so we overpay relative to badDebt.
        uint256 purchaseAmountUsdc = badDebtBefore + 200e6; // deliberately > badDebt
        // Ensure we don't try to buy more collateral than available (1 ether)
        // Max spendable for 1 ether at $2000 with 10% bonus = 1 ether * 2000 / 1.1 ≈ 1818e6
        // badDebt ≈ 182e6 (2000 - 2000/1.1), so badDebt + 200 ≈ 382e6 << 1818e6 → safe
        vm.startPrank(bob);
        usdc.approve(address(lending), purchaseAmountUsdc);
        lending.buyCollateral(address(weth), purchaseAmountUsdc, 0);
        vm.stopPrank();

        // badDebt fully cleared
        assertEq(lending.badDebtUsdc(), 0);
        // surplus (purchaseAmountUsdc - badDebtBefore) credited to reserves
        assertEq(lending.protocolReservesUsdc(), reservesBefore + (purchaseAmountUsdc - badDebtBefore));
    }

    /// @notice When there is no bad debt, all buyCollateral proceeds go to reserves.
    function test_buyCollateralNoBadDebtGoesToReserves() public {
        _prepareAliceLiquidatable();
        lending.absorb(alice);

        uint256 badDebtBefore = lending.badDebtUsdc(); // 181818182

        // Recapitalize: the test contract needs enough USDC to cover the bad debt.
        // Mint it directly to address(this) (the test contract acts as the payer).
        usdc.mint(address(this), badDebtBefore);
        usdc.approve(address(lending), badDebtBefore);
        lending.recapitalizeBadDebt(badDebtBefore);
        assertEq(lending.badDebtUsdc(), 0);

        uint256 reservesBefore = lending.protocolReservesUsdc();

        // Now buy some collateral — no bad debt exists, so all USDC goes to reserves.
        uint256 purchase = 100e6;
        vm.startPrank(bob);
        usdc.approve(address(lending), purchase);
        lending.buyCollateral(address(weth), purchase, 0);
        vm.stopPrank();

        // No bad debt to apply against → entire purchase goes to reserves
        assertEq(lending.badDebtUsdc(), 0);
        assertEq(lending.protocolReservesUsdc(), reservesBefore + purchase);
    }
}
