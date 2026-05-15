// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MiniLending} from "../../src/MiniLending.sol";
import {PriceOracle} from "../../src/PriceOracle.sol";
import {RiskEngine} from "../../src/RiskEngine.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockV3Aggregator} from "../../src/mocks/MockV3Aggregator.sol";

abstract contract MiniLendingTestBase is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WETH_PRICE = 3_000;
    uint256 internal constant WBTC_PRICE = 60_000;
    uint256 internal constant USDC_PRICE = 1;
    uint256 internal constant STALE_PERIOD = 1 days;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal charlie = makeAddr("charlie");
    address internal unsupported = makeAddr("unsupported");

    MockERC20 internal weth;
    MockERC20 internal wbtc;
    MockERC20 internal usdc;
    MockV3Aggregator internal wethFeed;
    MockV3Aggregator internal wbtcFeed;
    MockV3Aggregator internal usdcFeed;
    PriceOracle internal oracle;
    RiskEngine internal riskEngine;
    MiniLending internal lending;

    function setUp() public virtual {
        vm.warp(10 days);

        weth = new MockERC20("Mock WETH", "WETH", 18);
        wbtc = new MockERC20("Mock WBTC", "WBTC", 8);
        usdc = new MockERC20("Mock USDC", "USDC", 6);

        wethFeed = new MockV3Aggregator(8, int256(WETH_PRICE * 1e8));
        wbtcFeed = new MockV3Aggregator(8, int256(WBTC_PRICE * 1e8));
        usdcFeed = new MockV3Aggregator(8, int256(USDC_PRICE * 1e8));

        address[] memory oracleAssets = new address[](3);
        address[] memory feedAddresses = new address[](3);
        oracleAssets[0] = address(weth);
        oracleAssets[1] = address(wbtc);
        oracleAssets[2] = address(usdc);
        feedAddresses[0] = address(wethFeed);
        feedAddresses[1] = address(wbtcFeed);
        feedAddresses[2] = address(usdcFeed);
        oracle = new PriceOracle(oracleAssets, feedAddresses, STALE_PERIOD);

        address[] memory collateralAssets = new address[](2);
        RiskEngine.RiskConfig[] memory configs = new RiskEngine.RiskConfig[](2);
        collateralAssets[0] = address(weth);
        collateralAssets[1] = address(wbtc);
        configs[0] = RiskEngine.RiskConfig({
            collateralFactorBps: 7_500,
            liquidationThresholdBps: 8_000,
            liquidationBonusBps: 1_000,
            supplyCap: 10_000 ether,
            enabled: true
        });
        configs[1] = RiskEngine.RiskConfig({
            collateralFactorBps: 7_000,
            liquidationThresholdBps: 7_500,
            liquidationBonusBps: 1_000,
            supplyCap: 1_000e8,
            enabled: true
        });
        riskEngine = new RiskEngine(collateralAssets, configs);
        lending = new MiniLending(usdc, oracle, riskEngine, collateralAssets);

        weth.mint(alice, 100 ether);
        weth.mint(bob, 100 ether);
        wbtc.mint(alice, 100e8);
        wbtc.mint(bob, 100e8);
        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
        usdc.mint(charlie, 10_000_000e6);
        _supplyBase(charlie, 10_000_000e6);
    }

    function _depositCollateral(address user, MockERC20 asset, uint256 amount) internal {
        vm.startPrank(user);
        asset.approve(address(lending), amount);
        lending.depositCollateral(address(asset), amount);
        vm.stopPrank();
    }

    function _depositWeth(address user, uint256 amount) internal {
        _depositCollateral(user, weth, amount);
    }

    function _depositWbtc(address user, uint256 amount) internal {
        _depositCollateral(user, wbtc, amount);
    }

    function _borrow(address user, uint256 amountUSDC) internal {
        vm.prank(user);
        lending.borrow(amountUSDC);
    }

    function _supplyBase(address user, uint256 amountUSDC) internal {
        vm.startPrank(user);
        usdc.approve(address(lending), amountUSDC);
        lending.supplyBase(amountUSDC);
        vm.stopPrank();
    }

    function _withdrawBase(address user, uint256 amountUSDC) internal {
        vm.prank(user);
        lending.withdrawBase(amountUSDC);
    }

    function _repay(address user, uint256 amountUSDC) internal {
        vm.startPrank(user);
        usdc.approve(address(lending), amountUSDC);
        lending.repay(amountUSDC);
        vm.stopPrank();
    }

    function _prepareAliceLiquidatable() internal {
        _depositWeth(alice, 1 ether);
        _borrow(alice, 2_000e6);
        _setWethPrice(2_000);
    }

    function _setWethPrice(uint256 priceUsd) internal {
        wethFeed.updateAnswer(int256(priceUsd * 1e8));
    }

    function _setWbtcPrice(uint256 priceUsd) internal {
        wbtcFeed.updateAnswer(int256(priceUsd * 1e8));
    }

    function _usd(uint256 amount) internal pure returns (uint256) {
        return amount * WAD;
    }

    function _usdc(uint256 amount) internal pure returns (uint256) {
        return amount * 1e6;
    }
}
