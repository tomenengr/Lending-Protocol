// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {MiniLending} from "../src/MiniLending.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {RiskEngine} from "../src/RiskEngine.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockV3Aggregator} from "../src/mocks/MockV3Aggregator.sol";

contract Deploy is Script {
    function run()
        external
        returns (
            MiniLending lending,
            PriceOracle oracle,
            RiskEngine riskEngine,
            MockERC20 weth,
            MockERC20 wbtc,
            MockERC20 usdc
        )
    {
        vm.startBroadcast();

        weth = new MockERC20("Mock WETH", "WETH", 18);
        wbtc = new MockERC20("Mock WBTC", "WBTC", 8);
        usdc = new MockERC20("Mock USDC", "USDC", 6);

        MockV3Aggregator wethFeed = new MockV3Aggregator(8, 3_000e8);
        MockV3Aggregator wbtcFeed = new MockV3Aggregator(8, 60_000e8);
        MockV3Aggregator usdcFeed = new MockV3Aggregator(8, 1e8);

        address[] memory oracleAssets = new address[](3);
        address[] memory feeds = new address[](3);
        oracleAssets[0] = address(weth);
        oracleAssets[1] = address(wbtc);
        oracleAssets[2] = address(usdc);
        feeds[0] = address(wethFeed);
        feeds[1] = address(wbtcFeed);
        feeds[2] = address(usdcFeed);
        oracle = new PriceOracle(oracleAssets, feeds, 1 days);

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

        usdc.mint(msg.sender, 1_000_000e6);
        usdc.approve(address(lending), 1_000_000e6);
        lending.supplyBase(1_000_000e6);

        vm.stopBroadcast();
    }
}
