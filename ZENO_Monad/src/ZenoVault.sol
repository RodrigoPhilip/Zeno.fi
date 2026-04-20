// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ZenoVault is Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Balance {
        uint256 total;
        uint256 lockedMargin;
        uint256 lockedGas;
    }

    // address token => address user => Balance
    mapping(address => mapping(address => Balance)) public balances;

    address public controller;
    address public paymaster;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _controller, address _paymaster) public initializer {
        __Ownable_init(msg.sender);

        controller = _controller;
        paymaster = _paymaster;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    modifier onlyControllerOrPaymaster() {
        require(msg.sender == controller || msg.sender == paymaster, "Unauthorized access");
        _;
    }

    function deposit(address token, uint256 amount) external nonReentrant {
        require(amount > 0, "Deposit amount must be greater than zero");

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        balances[token][msg.sender].total += amount;
    }

    function withdraw(address token, uint256 amount) external nonReentrant {
        require(amount > 0, "Withdraw amount must be greater than zero");

        Balance storage userBal = balances[token][msg.sender];
        uint256 freeBalance = userBal.total - userBal.lockedMargin - userBal.lockedGas;
        require(freeBalance >= amount, "Margin or Gas locked");

        userBal.total -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    function adjustBalances(
        address tokenIn,
        address userIn,
        uint256 amountIn,
        address tokenOut,
        address userOut,
        uint256 amountOut
    ) external onlyControllerOrPaymaster {
        // Lógica de Crédito (Usuário recebe ativo)
        if (amountIn > 0) {
            balances[tokenIn][userIn].total += amountIn;
        }

        // Lógica de Débito (Usuário perde ativo)
        if (amountOut > 0) {
            Balance storage bOut = balances[tokenOut][userOut];
            require(bOut.total >= amountOut, "Insufficient balance to adjust");

            uint256 newTotal = bOut.total - amountOut;

            // A DEFESA DO PAYMASTER: Não permite saque se quebrar o lock
            require(newTotal >= bOut.lockedMargin + bOut.lockedGas, "Adjustment breaks margin/gas lock");

            bOut.total = newTotal;
        }
    }
}
