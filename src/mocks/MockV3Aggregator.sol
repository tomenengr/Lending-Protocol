// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";

contract MockV3Aggregator is IAggregatorV3 {
    uint8 public immutable decimals;
    address public owner;
    bool public locked;
    mapping(address updater => bool allowed) public isUpdater;

    uint80 private _roundId;
    int256 private _answer;
    uint256 private _startedAt;
    uint256 private _updatedAt;
    uint80 private _answeredInRound;

    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);
    event NewRound(uint256 indexed roundId, address indexed startedBy, uint256 startedAt);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event UpdaterSet(address indexed updater, bool allowed);

    constructor(uint8 decimals_, int256 initialAnswer) {
        decimals = decimals_;
        owner = msg.sender;
        updateAnswer(initialAnswer);
    }

    modifier onlyUpdater() {
        require(msg.sender == owner || isUpdater[msg.sender], "ONLY_UPDATER");
        require(!locked, "LOCKED");
        _;
    }

    function setUpdater(address updater, bool allowed) external {
        require(msg.sender == owner, "ONLY_OWNER");
        require(!locked, "LOCKED");
        isUpdater[updater] = allowed;
        emit UpdaterSet(updater, allowed);
    }

    function transferOwnership(address newOwner) external {
        require(msg.sender == owner, "ONLY_OWNER");
        require(!locked, "LOCKED");
        require(newOwner != address(0), "ZERO_OWNER");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function lock() external {
        require(msg.sender == owner, "ONLY_OWNER");
        locked = true;
    }

    function updateAnswer(int256 newAnswer) public onlyUpdater {
        _roundId += 1;
        _answer = newAnswer;
        _startedAt = block.timestamp;
        _updatedAt = block.timestamp;
        _answeredInRound = _roundId;
        emit NewRound(_roundId, msg.sender, _startedAt);
        emit AnswerUpdated(newAnswer, _roundId, _updatedAt);
    }

    function updateRoundData(
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) external onlyUpdater {
        _roundId = roundId;
        _answer = answer;
        _startedAt = startedAt;
        _updatedAt = updatedAt;
        _answeredInRound = answeredInRound;
        emit NewRound(roundId, msg.sender, startedAt);
        emit AnswerUpdated(answer, roundId, updatedAt);
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _answer, _startedAt, _updatedAt, _answeredInRound);
    }
}
