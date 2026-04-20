// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "pyth-sdk-solidity/IPyth.sol";
import "pyth-sdk-solidity/PythStructs.sol";

contract ZenoOracleRouter is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    struct FeedConfig {
        address oracle;
        bytes32 feedId;
        uint256 maxStaleness;
        uint256 maxConfidence;
    }

    struct PriceData {
        int64 price;
        int32 expo;
        uint256 publishTime;
        uint64 conf;
    }

    mapping(bytes32 => FeedConfig) public marketFeeds;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        __Ownable_init(msg.sender); // Will be transferred to Timelock later
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function addMarket(
        bytes32 marketId,
        address oracle,
        bytes32 feedId,
        uint256 maxStaleness,
        uint256 maxConfidence
    ) external onlyOwner {
        marketFeeds[marketId] = FeedConfig({
            oracle: oracle,
            feedId: feedId,
            maxStaleness: maxStaleness,
            maxConfidence: maxConfidence
        });
    }

    function updateOracle(bytes32 marketId, address oracle) external onlyOwner {
        marketFeeds[marketId].oracle = oracle;
    }

    function getPrice(bytes32 marketId) external view returns (PriceData memory) {
        FeedConfig memory config = marketFeeds[marketId];
        require(config.oracle != address(0), "Market not configured");

        PythStructs.Price memory pythPrice = IPyth(config.oracle).getPriceUnsafe(config.feedId);

        require(block.timestamp - pythPrice.publishTime <= config.maxStaleness, "Stale price");
        require(pythPrice.conf <= config.maxConfidence, "Low confidence");

        return PriceData({
            price: pythPrice.price,
            expo: pythPrice.expo,
            publishTime: pythPrice.publishTime,
            conf: pythPrice.conf
        });
    }
}
