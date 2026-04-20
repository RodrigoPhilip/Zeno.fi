// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

interface IZenoVault {
    function adjustBalances(
        address tokenIn,
        address userIn,
        uint256 amountIn,
        address tokenOut,
        address userOut,
        uint256 amountOut
    ) external;
}

contract ZenoBook is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    address public vault;
    address public sequencer;

    mapping(bytes32 => bool) public isMarketPaused;

    event TradeSettled(bytes32 indexed marketId, address indexed taker);
    event SequencerUpdated(address indexed oldSequencer, address indexed newSequencer);
    event MarketPaused(bytes32 indexed marketId);
    event MarketUnpaused(bytes32 indexed marketId);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _vault, address _sequencer) public initializer {
        __Ownable_init(msg.sender); // transferred to Timelock later
        vault = _vault;
        sequencer = _sequencer;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    modifier onlySequencer() {
        require(msg.sender == sequencer, "Only Sequencer");
        _;
    }

    modifier whenNotPaused(bytes32 marketId) {
        require(marketId != bytes32(0) && !isMarketPaused[marketId], "Market paused or invalid");
        _;
    }

    function setSequencer(address _sequencer) external onlyOwner {
        require(_sequencer != address(0), "Invalid sequencer");
        emit SequencerUpdated(sequencer, _sequencer);
        sequencer = _sequencer;
    }

    function pauseMarket(bytes32 marketId) external onlyOwner {
        isMarketPaused[marketId] = true;
        emit MarketPaused(marketId);
    }

    function unpauseMarket(bytes32 marketId) external onlyOwner {
        isMarketPaused[marketId] = false;
        emit MarketUnpaused(marketId);
    }

    function settleTrade(
        bytes32 marketId,
        address taker,
        bytes calldata executionData
    ) external onlySequencer whenNotPaused(marketId) {
        require(executionData.length > 0, "Empty execution data");

        (
            address[] memory makers,
            address[] memory tokensIn,
            uint256[] memory amountsIn,
            address[] memory tokensOut,
            uint256[] memory amountsOut
        ) = abi.decode(executionData, (address[], address[], uint256[], address[], uint256[]));

        require(makers.length == amountsIn.length && amountsIn.length == amountsOut.length, "Length mismatch");

        for (uint256 i = 0; i < makers.length; i++) {
            // Note: ZenoVault adjustBalances expects:
            // (tokenIn, userIn, amountIn, tokenOut, userOut, amountOut)
            // Where 'In' is credit (receives) and 'Out' is debit (pays).

            IZenoVault(vault).adjustBalances(
                tokensIn[i],
                makers[i],
                amountsIn[i],
                tokensOut[i],
                taker,
                amountsOut[i]
            );
        }

        emit TradeSettled(marketId, taker);
    }

    function resolveTrade(
        bytes32 marketId,
        address user,
        uint256 id,
        bytes calldata executionData
    ) external view returns (bool) {
        // Off-chain view simulation for Frontend PnL calculations
        // (Function does not mutate state and relies on valid executionData)
        return !isMarketPaused[marketId];
    }
}
