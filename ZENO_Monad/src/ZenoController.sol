// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

interface IZenoVault {
    function adjustBalances(address tokenIn, address userIn, uint256 amountIn, address tokenOut, address userOut, uint256 amountOut) external;
    function lockMargin(address user, address token, uint256 amount) external;
    function releaseMargin(address user, address token, uint256 amount) external;
    function getBalance(address token, address user) external view returns (uint256 total, uint256 lockedMargin, uint256 lockedGas);
}

interface IZenoOracleRouter {
    function getPrice(bytes32 marketId) external view returns (int64 price, int32 expo, uint256 publishTime, uint64 conf);
}

interface ILeverageConfig {
    function getLeverageTier(bytes32 marketId) external view returns (uint256 maxLeverage, uint256 initialMarginBps, uint256 maintenanceMarginBps);
    function getEffectiveLeverage(bytes32 marketId, uint256 positionSize) external view returns (uint256);
}

contract ZenoController is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    address public vault;
    address public oracleRouter;
    address public leverageConfig;

    struct Position {
        bool isActive;
        int256 size;
        uint256 entryPrice;
        address baseToken;
        address quoteToken;
    }

    mapping(bytes32 => Position) public positions;

    event PositionOpened(bytes32 indexed marketId, address indexed user, bool isLong, uint256 marginAmount, uint256 positionSize);
    event PositionLiquidated(bytes32 indexed marketId, address indexed user);
    event PositionClosed(bytes32 indexed marketId, address indexed user);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _vault, address _oracleRouter, address _leverageConfig) public initializer {
        __Ownable_init(msg.sender);
        vault = _vault;
        oracleRouter = _oracleRouter;
        leverageConfig = _leverageConfig;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function abs(int256 x) private pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }

    function normalizePrice(int64 price, int32 expo) private pure returns (uint256) {
        if (price < 0) revert("Negative price");
        uint256 absPrice = uint256(int256(price));
        if (expo < 0) {
            uint256 expNum = uint256(int256(-expo));
            if (18 >= expNum) {
                return absPrice * (10 ** (18 - expNum));
            } else {
                return absPrice / (10 ** (expNum - 18));
            }
        } else {
            uint256 expNum = uint256(int256(expo));
            return absPrice * (10 ** (18 + expNum));
        }
    }

    function openPosition(
        bytes32 marketId,
        bool isLong,
        uint256 marginAmount,
        uint256 positionSize,
        address baseToken,
        address quoteToken
    ) external {
        IZenoVault(vault).lockMargin(msg.sender, quoteToken, marginAmount);

        (int64 price, int32 expo, , ) = IZenoOracleRouter(oracleRouter).getPrice(marketId);
        uint256 entryPrice = normalizePrice(price, expo);

        int256 size = isLong ? int256(positionSize) : -int256(positionSize);

        bytes32 posKey = keccak256(abi.encodePacked(msg.sender, marketId));
        positions[posKey] = Position({
            isActive: true,
            size: size,
            entryPrice: entryPrice,
            baseToken: baseToken,
            quoteToken: quoteToken
        });

        emit PositionOpened(marketId, msg.sender, isLong, marginAmount, positionSize);
    }

    function getHealthFactor(address user, bytes32 marketId) public view returns (uint256) {
        bytes32 posKey = keccak256(abi.encodePacked(user, marketId));
        Position memory pos = positions[posKey];
        if (!pos.isActive) return 100 * 1e18;

        (int64 price, int32 expo, , ) = IZenoOracleRouter(oracleRouter).getPrice(marketId);
        uint256 currentPrice = normalizePrice(price, expo);

        int256 unrealizedPnl = (int256(currentPrice) - int256(pos.entryPrice)) * pos.size / int256(1e18);
        uint256 positionValue = (currentPrice * abs(pos.size)) / 1e18;

        (uint256 total, uint256 lockedMargin, ) = IZenoVault(vault).getBalance(pos.quoteToken, user);
        uint256 freeCollateral = total - lockedMargin;

        // A lógica de sinal já está no size negativo (Short).
        int256 totalValue = int256(freeCollateral) + unrealizedPnl;

        (, , uint256 maintenanceMarginBps) = ILeverageConfig(leverageConfig).getLeverageTier(marketId);
        uint256 requiredMargin = (positionValue * maintenanceMarginBps) / 10000;

        if (requiredMargin == 0) {
            return 100 * 1e18;
        }

        if (totalValue <= 0) {
            return 0; // Liquidável
        }

        return (uint256(totalValue) * 1e18) / requiredMargin;
    }

    function liquidate(address user, bytes32 marketId) external {
        uint256 hf = getHealthFactor(user, marketId);
        require(hf < 1e18, "Position is healthy");

        bytes32 posKey = keccak256(abi.encodePacked(user, marketId));
        Position storage pos = positions[posKey];
        require(pos.isActive, "No active position");

        uint256 sizeAbsoluto = abs(pos.size);

        (, , uint256 maintenanceMarginBps) = ILeverageConfig(leverageConfig).getLeverageTier(marketId);
        (int64 price, int32 expo, , ) = IZenoOracleRouter(oracleRouter).getPrice(marketId);
        uint256 currentPrice = normalizePrice(price, expo);

        uint256 positionValue = (currentPrice * sizeAbsoluto) / 1e18;
        uint256 requiredMargin = (positionValue * maintenanceMarginBps) / 10000;

        uint256 liquidacaoLiquida = (requiredMargin * 5) / 100;

        IZenoVault(vault).releaseMargin(user, pos.baseToken, sizeAbsoluto);
        IZenoVault(vault).adjustBalances(pos.quoteToken, user, liquidacaoLiquida, pos.quoteToken, msg.sender, 0);

        pos.isActive = false;
        emit PositionLiquidated(marketId, user);
    }

    function closePosition(bytes32 marketId) external {
        bytes32 posKey = keccak256(abi.encodePacked(msg.sender, marketId));
        Position storage pos = positions[posKey];
        require(pos.isActive, "No active position");

        (int64 price, int32 expo, , ) = IZenoOracleRouter(oracleRouter).getPrice(marketId);
        uint256 currentPrice = normalizePrice(price, expo);

        int256 unrealizedPnl = (int256(currentPrice) - int256(pos.entryPrice)) * pos.size / int256(1e18);
        uint256 sizeAbsoluto = abs(pos.size);

        IZenoVault(vault).releaseMargin(msg.sender, pos.baseToken, sizeAbsoluto);

        if (unrealizedPnl > 0) {
            IZenoVault(vault).adjustBalances(pos.quoteToken, msg.sender, uint256(unrealizedPnl), address(0), address(0), 0);
        } else if (unrealizedPnl < 0) {
            IZenoVault(vault).adjustBalances(address(0), address(0), 0, pos.quoteToken, msg.sender, uint256(-unrealizedPnl));
        }

        pos.isActive = false;
        emit PositionClosed(marketId, msg.sender);
    }
}
