// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MiniLendingTestBase} from "./helpers/MiniLendingTestBase.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

contract MiniLendingDepositTest is MiniLendingTestBase {
    event CollateralDeposited(address indexed user, address indexed asset, uint256 amount);

    function test_depositCollateralUpdatesAccountingAndTransfersTokens() public {
        vm.startPrank(alice);
        weth.approve(address(lending), 1 ether);
        vm.expectEmit(true, true, false, true);
        emit CollateralDeposited(alice, address(weth), 1 ether);
        lending.depositCollateral(address(weth), 1 ether);
        vm.stopPrank();

        assertEq(lending.collateralBalance(alice, address(weth)), 1 ether);
        assertEq(lending.totalCollateral(address(weth)), 1 ether);
        assertEq(weth.balanceOf(address(lending)), 1 ether);
        assertEq(weth.balanceOf(alice), 99 ether);
    }

    function test_multipleDepositsAccumulateAcrossSupportedAssets() public {
        _depositWeth(alice, 1 ether);
        _depositWeth(alice, 2 ether);
        _depositWbtc(bob, 1e8);

        assertEq(lending.collateralBalance(alice, address(weth)), 3 ether);
        assertEq(lending.collateralBalance(bob, address(wbtc)), 1e8);
    }

    function test_revertDepositInvalidInputs() public {
        vm.prank(alice);
        vm.expectRevert(bytes("ZERO_AMOUNT"));
        lending.depositCollateral(address(weth), 0);

        MockERC20 dai = new MockERC20("Mock DAI", "DAI", 18);
        vm.prank(alice);
        vm.expectRevert(bytes("UNSUPPORTED_ASSET"));
        lending.depositCollateral(address(dai), 1 ether);
    }

    function test_revertDepositWithoutApproval() public {
        vm.prank(alice);
        vm.expectRevert(bytes("ERC20_INSUFFICIENT_ALLOWANCE"));
        lending.depositCollateral(address(weth), 1 ether);
    }
}
