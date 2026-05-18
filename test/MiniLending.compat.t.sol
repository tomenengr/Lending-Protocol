// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MiniLendingTestBase} from "./helpers/MiniLendingTestBase.sol";

contract MiniLendingCompatTest is MiniLendingTestBase {
    function test_dependencyGettersExposeConfiguredContracts() public view {
        assertEq(address(lending.usdc()), address(usdc));
        assertEq(address(lending.oracle()), address(oracle));
        assertEq(address(lending.riskEngine()), address(riskEngine));
    }

    function test_legacyUsdcGettersMirrorMixedCaseGetters() public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 1_000e6);

        assertEq(lending.suppliedUSDC(charlie), lending.suppliedUsdc(charlie));
        assertEq(lending.debtUSDC(alice), lending.debtUsdc(alice));
        assertEq(lending.totalSuppliedUSDC(), lending.totalSuppliedUsdc());
        assertEq(lending.totalBorrowedUSDC(), lending.totalBorrowedUsdc());
        assertEq(lending.protocolReservesUSDC(), lending.protocolReservesUsdc());
        assertEq(lending.badDebtUSDC(), lending.badDebtUsdc());
    }

    function test_legacyReserveAndBadDebtGettersAfterAccountingChanges() public {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 2_000e6);

        vm.warp(block.timestamp + 365 days);
        lending.accrueInterest();
        assertEq(lending.protocolReservesUSDC(), lending.protocolReservesUsdc());

        _setWethPrice(1_000);
        usdcFeed.updateAnswer(1e8);
        lending.absorb(alice);
        assertEq(lending.badDebtUSDC(), lending.badDebtUsdc());
    }
}
