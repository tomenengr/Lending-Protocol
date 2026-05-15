// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MiniLendingTestBase} from "./helpers/MiniLendingTestBase.sol";
import {MockV3Aggregator} from "../src/mocks/MockV3Aggregator.sol";

contract PriceOracleTest is MiniLendingTestBase {
    function test_getWethPrice() public view {
        assertEq(oracle.getPrice(address(weth)), 3_000e18);
    }

    function test_getWbtcPrice() public view {
        assertEq(oracle.getPrice(address(wbtc)), 60_000e18);
    }

    function test_getUsdcPrice() public view {
        assertEq(oracle.getPrice(address(usdc)), 1e18);
    }

    function test_revertIfPriceIsZero() public {
        wethFeed.updateAnswer(0);

        vm.expectRevert(bytes("INVALID_PRICE"));
        oracle.getPrice(address(weth));
    }

    function test_revertIfPriceIsNegative() public {
        wethFeed.updateAnswer(-1);

        vm.expectRevert(bytes("INVALID_PRICE"));
        oracle.getPrice(address(weth));
    }

    function test_revertIfPriceIsStale() public {
        vm.warp(block.timestamp + STALE_PERIOD + 1);

        vm.expectRevert(bytes("STALE_PRICE"));
        oracle.getPrice(address(weth));
    }

    function test_revertIfUpdatedAtIsInFuture() public {
        wethFeed.updateRoundData(1, 3_000e8, block.timestamp, block.timestamp + 1, 1);

        vm.expectRevert(bytes("STALE_PRICE"));
        oracle.getPrice(address(weth));
    }

    function test_handlesDifferentFeedDecimals() public {
        MockV3Aggregator sixDecimalFeed = new MockV3Aggregator(6, 1_234e6);
        oracle.setFeed(address(weth), address(sixDecimalFeed));

        assertEq(oracle.getPrice(address(weth)), 1_234e18);
    }

    function test_revertIfNoFeed() public {
        vm.expectRevert(bytes("NO_FEED"));
        oracle.getPrice(unsupported);
    }

    function test_onlyOwnerCanSetFeed() public {
        MockV3Aggregator newFeed = new MockV3Aggregator(8, 2_500e8);

        vm.prank(alice);
        vm.expectRevert(bytes("ONLY_OWNER"));
        oracle.setFeed(address(weth), address(newFeed));
    }
}
