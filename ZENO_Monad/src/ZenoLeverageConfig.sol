// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract ZenoLeverageConfig is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    struct LeverageTier {
        uint256 maxLeverage;
        uint256 initialMarginBps;
        uint256 maintenanceMarginBps;
    }

    mapping(bytes32 => LeverageTier) public marketTiers;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        __Ownable_init(msg.sender); // Will be transferred to Timelock later
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function setLeverageTier(
        bytes32 marketId,
        uint256 maxLeverage,
        uint256 initialMarginBps,
        uint256 maintenanceMarginBps
    ) external onlyOwner {
        marketTiers[marketId] = LeverageTier({
            maxLeverage: maxLeverage,
            initialMarginBps: initialMarginBps,
            maintenanceMarginBps: maintenanceMarginBps
        });
    }

    function getLeverageTier(bytes32 marketId) external view returns (
        uint256 maxLeverage,
        uint256 initialMarginBps,
        uint256 maintenanceMarginBps
    ) {
        LeverageTier memory tier = marketTiers[marketId];
        return (tier.maxLeverage, tier.initialMarginBps, tier.maintenanceMarginBps);
    }

    function getEffectiveLeverage(bytes32 marketId, uint256 positionSize) external view returns (uint256) {
        uint256 maxLev = marketTiers[marketId].maxLeverage;

        if (positionSize < 100_000e18) {
            return maxLev;
        } else if (positionSize < 1_000_000e18) {
            return maxLev / 2;
        } else {
            return maxLev / 4;
        }
    }
}
