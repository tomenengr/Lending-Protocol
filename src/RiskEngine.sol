// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract RiskEngine {
    uint256 public constant BPS = 10_000;
    uint256 public constant WAD = 1e18;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant CLOSE_FACTOR_BPS = 5_000;

    struct RiskConfig {
        uint256 collateralFactorBps;
        uint256 liquidationThresholdBps;
        uint256 liquidationBonusBps;
        uint256 supplyCap;
        bool enabled;
    }

    address public owner;
    bool public locked;
    mapping(address asset => RiskConfig config) private _riskConfigs;

    event RiskConfigSet(
        address indexed asset,
        uint256 collateralFactorBps,
        uint256 liquidationThresholdBps,
        uint256 liquidationBonusBps,
        uint256 supplyCap,
        bool enabled
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "ONLY_OWNER");
        require(!locked, "LOCKED");
        _;
    }

    constructor(address[] memory assets, RiskConfig[] memory configs) {
        require(assets.length == configs.length, "LENGTH_MISMATCH");
        owner = msg.sender;

        for (uint256 i = 0; i < assets.length; i++) {
            _setRiskConfig(assets[i], configs[i]);
        }
    }

    function setRiskConfig(address asset, RiskConfig calldata config) external onlyOwner {
        _setRiskConfig(asset, config);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "ZERO_OWNER");
        owner = newOwner;
    }

    function lock() external onlyOwner {
        locked = true;
    }

    function getRiskConfig(address asset) external view returns (RiskConfig memory) {
        return _riskConfigs[asset];
    }

    function isEnabled(address asset) external view returns (bool) {
        return _riskConfigs[asset].enabled;
    }

    function calculateBorrowableUsd(address asset, uint256 collateralValueUsd) external view returns (uint256) {
        RiskConfig memory config = _requireEnabled(asset);
        return collateralValueUsd * config.collateralFactorBps / BPS;
    }

    function calculateLiquidationThresholdUsd(address asset, uint256 collateralValueUsd)
        external
        view
        returns (uint256)
    {
        RiskConfig memory config = _requireEnabled(asset);
        return collateralValueUsd * config.liquidationThresholdBps / BPS;
    }

    function calculateSeizeAmount(
        address collateralAsset,
        uint256 repayValueUsd,
        uint256 collateralPriceE18,
        uint8 collateralDecimals
    ) external view returns (uint256) {
        RiskConfig memory config = _requireEnabled(collateralAsset);
        require(collateralPriceE18 > 0, "INVALID_PRICE");

        uint256 seizeValueUsd = repayValueUsd * (BPS + config.liquidationBonusBps) / BPS;
        return seizeValueUsd * (10 ** collateralDecimals) / collateralPriceE18;
    }

    function _setRiskConfig(address asset, RiskConfig memory config) internal {
        require(asset != address(0), "ZERO_ASSET");
        if (config.enabled) {
            require(config.collateralFactorBps > 0, "INVALID_COLLATERAL_FACTOR");
            require(config.collateralFactorBps <= BPS, "INVALID_COLLATERAL_FACTOR");
            require(config.liquidationThresholdBps >= config.collateralFactorBps, "INVALID_LIQ_THRESHOLD");
            require(config.liquidationThresholdBps <= BPS, "INVALID_LIQ_THRESHOLD");
            require(config.liquidationBonusBps <= BPS, "INVALID_LIQ_BONUS");
            require(config.supplyCap > 0, "INVALID_SUPPLY_CAP");
        }

        _riskConfigs[asset] = config;
        emit RiskConfigSet(
            asset,
            config.collateralFactorBps,
            config.liquidationThresholdBps,
            config.liquidationBonusBps,
            config.supplyCap,
            config.enabled
        );
    }

    function _requireEnabled(address asset) internal view returns (RiskConfig memory config) {
        config = _riskConfigs[asset];
        require(config.enabled, "UNSUPPORTED_ASSET");
    }
}
