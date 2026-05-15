// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

contract PriceOracle is IPriceOracle {
    uint256 public constant WAD = 1e18;

    address public owner;
    bool public locked;
    uint256 public stalePeriod;

    mapping(address asset => IAggregatorV3 feed) public feeds;
    mapping(address asset => uint256 heartbeat) public assetHeartbeat;

    event FeedSet(address indexed asset, address indexed feed);
    event StalePeriodSet(uint256 stalePeriod);
    event AssetHeartbeatSet(address indexed asset, uint256 heartbeat);

    modifier onlyOwner() {
        require(msg.sender == owner, "ONLY_OWNER");
        require(!locked, "LOCKED");
        _;
    }

    constructor(address[] memory assets, address[] memory feedAddresses, uint256 stalePeriod_) {
        require(assets.length == feedAddresses.length, "LENGTH_MISMATCH");
        require(stalePeriod_ > 0, "ZERO_STALE_PERIOD");

        owner = msg.sender;
        stalePeriod = stalePeriod_;

        for (uint256 i = 0; i < assets.length; i++) {
            _setFeed(assets[i], feedAddresses[i]);
        }
    }

    function setFeed(address asset, address feed) external onlyOwner {
        _setFeed(asset, feed);
    }

    function setStalePeriod(uint256 stalePeriod_) external onlyOwner {
        require(stalePeriod_ > 0, "ZERO_STALE_PERIOD");
        stalePeriod = stalePeriod_;
        emit StalePeriodSet(stalePeriod_);
    }

    function setAssetHeartbeat(address asset, uint256 heartbeat) external onlyOwner {
        require(address(feeds[asset]) != address(0), "NO_FEED");
        require(heartbeat > 0, "ZERO_HEARTBEAT");
        assetHeartbeat[asset] = heartbeat;
        emit AssetHeartbeatSet(asset, heartbeat);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "ZERO_OWNER");
        owner = newOwner;
    }

    function lock() external onlyOwner {
        locked = true;
    }

    function getPrice(address asset) external view returns (uint256 priceE18) {
        IAggregatorV3 feed = feeds[asset];
        require(address(feed) != address(0), "NO_FEED");

        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        require(answer > 0, "INVALID_PRICE");
        require(updatedAt <= block.timestamp, "STALE_PRICE");
        require(block.timestamp - updatedAt <= _heartbeatFor(asset), "STALE_PRICE");

        return _scaleToE18(uint256(answer), feed.decimals());
    }

    function _setFeed(address asset, address feed) internal {
        require(asset != address(0), "ZERO_ASSET");
        require(feed != address(0), "ZERO_FEED");
        feeds[asset] = IAggregatorV3(feed);
        emit FeedSet(asset, feed);
    }

    function _scaleToE18(uint256 value, uint8 feedDecimals) internal pure returns (uint256) {
        if (feedDecimals == 18) {
            return value;
        }
        if (feedDecimals < 18) {
            return value * (10 ** (18 - feedDecimals));
        }
        return value / (10 ** (feedDecimals - 18));
    }

    function _heartbeatFor(address asset) internal view returns (uint256) {
        uint256 heartbeat = assetHeartbeat[asset];
        return heartbeat == 0 ? stalePeriod : heartbeat;
    }
}
