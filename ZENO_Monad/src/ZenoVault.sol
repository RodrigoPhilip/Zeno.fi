// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
    =====================================================================
                            ZENO VAULT
    =====================================================================

    Institutional-grade collateral vault for ZENO Protocol

    Core responsibilities:
    - Custody of protocol collateral (USDC primary asset)
    - Margin reservation (lockedMargin)
    - Gas sponsorship reservation (lockedGas)
    - Withdrawal protection
    - Liquidation settlement support
    - Solvency invariant enforcement
    - Emergency circuit breaker
    - Governance-safe upgradeability (UUPS + Timelock)

    Security philosophy:
    This contract is the financial root of protocol solvency.

    If Vault breaks:
    -> protocol breaks

    Therefore:
    simplicity > cleverness
    auditability > abstraction
    security > convenience
*/

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract ZenoVault is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    /*
    ============================================================
                            ROLES
    ============================================================

    Access must be granular.
    Never use broad admin power for financial operations.

    DEFAULT_ADMIN_ROLE:
    -> governance bootstrap only
    -> should be transferred to Timelock

    CONTROLLER_ROLE:
    -> ZenoController
    -> manages margin + liquidation settlement

    PAYMASTER_ROLE:
    -> ZenoPaymaster
    -> manages gas reservation logic

    GUARDIAN_ROLE:
    -> emergency pause only

    UPGRADER_ROLE:
    -> UUPS upgrade authority
    -> must be controlled by Timelock
    */

    bytes32 public constant CONTROLLER_ROLE =
        keccak256("CONTROLLER_ROLE");

    bytes32 public constant PAYMASTER_ROLE =
        keccak256("PAYMASTER_ROLE");

    bytes32 public constant GUARDIAN_ROLE =
        keccak256("GUARDIAN_ROLE");

    bytes32 public constant UPGRADER_ROLE =
        keccak256("UPGRADER_ROLE");

    /*
    ============================================================
                            STORAGE
    ============================================================
    */

    /*
        Launch asset:
        USDC only

        Multi-asset collateral is intentionally postponed.

        Reason:
        multi-asset significantly increases:
        - accounting complexity
        - oracle coupling
        - insolvency surface

        Institutional launch requires controlled simplicity.
    */
    IERC20 public usdc;

    /*
        User accounting model

        totalBalance:
        -> total collateral owned by user

        lockedMargin:
        -> reserved for open positions

        lockedGas:
        -> reserved by Paymaster for ERC-4337 gas sponsorship

        Withdrawals can ONLY use:
        totalBalance - lockedMargin - lockedGas
    */
    struct UserBalance {
        uint256 totalBalance;
        uint256 lockedMargin;
        uint256 lockedGas;
    }

    mapping(address => UserBalance) public balances;

    /*
        Critical solvency invariant tracker

        Must always satisfy:

        totalProtocolBalance
        <=
        physical USDC held by Vault

        Prevents:
        phantom balances
        silent insolvency
        accounting corruption
    */
    uint256 public totalProtocolBalance;

    /*
    ============================================================
                            EVENTS
    ============================================================
    */

    event Deposited(
        address indexed user,
        uint256 amount
    );

    event Withdrawn(
        address indexed user,
        uint256 amount
    );

    event MarginLocked(
        address indexed user,
        uint256 amount
    );

    event MarginUnlocked(
        address indexed user,
        uint256 amount
    );

    event GasLocked(
        address indexed user,
        uint256 amount
    );

    event GasUnlocked(
        address indexed user,
        uint256 amount
    );

    event LiquidationSettlement(
        address indexed user,
        uint256 amount
    );

    event EmergencyPaused(
        address indexed guardian
    );

    event EmergencyUnpaused(
        address indexed admin
    );

    /*
    ============================================================
                        CONSTRUCTOR
    ============================================================
    */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        /*
            Prevent implementation contract takeover.

            Required for upgradeable contracts.
        */
        _disableInitializers();
    }

    /*
    ============================================================
                        INITIALIZER
    ============================================================
    */

    function initialize(
        address _usdc,
        address admin
    ) external initializer {
        require(
            _usdc != address(0),
            "invalid usdc"
        );

        require(
            admin != address(0),
            "invalid admin"
        );

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        usdc = IERC20(_usdc);

        /*
            Bootstrap governance

            Must later migrate to:
            multisig -> timelock -> protocol
        */
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, admin);
    }

    /*
    ============================================================
                        USER ACTIONS
    ============================================================
    */

    /*
        Deposit USDC collateral

        Security:
        - nonReentrant
        - paused aware
        - amount validation
        - accounting before completion event
    */
    function deposit(
        uint256 amount
    )
        external
        nonReentrant
        whenNotPaused
    {
        require(
            amount > 0,
            "invalid amount"
        );

        /*
            Interaction:
            transfer funds first
        */
        usdc.safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );

        /*
            Effects:
            update accounting
        */
        balances[msg.sender].totalBalance += amount;
        totalProtocolBalance += amount;

        emit Deposited(
            msg.sender,
            amount
        );
    }

    /*
        Withdraw ONLY unlocked balance

        Critical invariant:

        withdrawable =
        totalBalance
        - lockedMargin
        - lockedGas

        Prevents:
        liquidation bypass
        paymaster insolvency
        hidden bad debt
    */
    function withdraw(
        uint256 amount
    )
        external
        nonReentrant
        whenNotPaused
    {
        require(
            amount > 0,
            "invalid amount"
        );

        UserBalance storage user =
            balances[msg.sender];

        uint256 available =
            user.totalBalance
            - user.lockedMargin
            - user.lockedGas;

        require(
            amount <= available,
            "insufficient unlocked balance"
        );

        /*
            Effects before interaction
            (CEI pattern)
        */
        user.totalBalance -= amount;
        totalProtocolBalance -= amount;

        /*
            Interaction last
        */
        usdc.safeTransfer(
            msg.sender,
            amount
        );

        emit Withdrawn(
            msg.sender,
            amount
        );
    }

    /*
    ============================================================
                    CONTROLLER OPERATIONS
    ============================================================
    */

    /*
        Reserve collateral for open position

        Called by:
        ZenoController only

        Prevents opening undercollateralized positions
    */
    function lockMargin(
        address user,
        uint256 amount
    )
        external
        onlyRole(CONTROLLER_ROLE)
    {
        UserBalance storage u =
            balances[user];

        require(
            u.totalBalance >=
            (
                u.lockedMargin +
                u.lockedGas +
                amount
            ),
            "insufficient balance"
        );

        u.lockedMargin += amount;

        emit MarginLocked(
            user,
            amount
        );
    }

    /*
        Release reserved margin

        Called after:
        closePosition()
        reducePosition()
        successful liquidation settlement
    */
    function unlockMargin(
        address user,
        uint256 amount
    )
        external
        onlyRole(CONTROLLER_ROLE)
    {
        UserBalance storage u =
            balances[user];

        require(
            u.lockedMargin >= amount,
            "invalid unlock"
        );

        u.lockedMargin -= amount;

        emit MarginUnlocked(
            user,
            amount
        );
    }

    /*
    ============================================================
                    PAYMASTER OPERATIONS
    ============================================================
    */

    /*
        Reserve gas sponsorship funds

        Called BEFORE execution.

        Protects:
        Paymaster solvency
        gas sponsorship abuse
    */
    function lockGas(
        address user,
        uint256 amount
    )
        external
        onlyRole(PAYMASTER_ROLE)
    {
        UserBalance storage u =
            balances[user];

        require(
            u.totalBalance >=
            (
                u.lockedMargin +
                u.lockedGas +
                amount
            ),
            "insufficient balance"
        );

        u.lockedGas += amount;

        emit GasLocked(
            user,
            amount
        );
    }

    /*
        Release gas reservation

        Called AFTER execution.

        Unused gas reserve is returned
        to available balance.
    */
    function unlockGas(
        address user,
        uint256 amount
    )
        external
        onlyRole(PAYMASTER_ROLE)
    {
        UserBalance storage u =
            balances[user];

        require(
            u.lockedGas >= amount,
            "invalid unlock"
        );

        u.lockedGas -= amount;

        emit GasUnlocked(
            user,
            amount
        );
    }

    /*
    ============================================================
                        LIQUIDATION
    ============================================================
    */

    /*
        Forced collateral settlement

        Used for:
        - liquidation
        - bad debt handling
        - protocol settlement

        Highly restricted:
        Controller only
    */
    function forceSettlement(
        address user,
        uint256 amount
    )
        external
        onlyRole(CONTROLLER_ROLE)
    {
        UserBalance storage u =
            balances[user];

        require(
            u.totalBalance >= amount,
            "insufficient balance"
        );

        /*
            Settlement must preserve invariant.
        */
        u.totalBalance -= amount;
        totalProtocolBalance -= amount;

        emit LiquidationSettlement(
            user,
            amount
        );
    }

    /*
    ============================================================
                    EMERGENCY CONTROL
    ============================================================
    */

    /*
        Instant emergency stop

        Used for:
        - oracle failure
        - liquidation bug
        - exploit response
        - abnormal protocol state

        Must bypass governance delay.
    */
    function pause()
        external
        onlyRole(GUARDIAN_ROLE)
    {
        _pause();

        emit EmergencyPaused(
            msg.sender
        );
    }

    /*
        Restore protocol operations

        Must be governance controlled.
        Never guardian controlled.
    */
    function unpause()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _unpause();

        emit EmergencyUnpaused(
            msg.sender
        );
    }

    /*
    ============================================================
                    UPGRADE AUTHORITY
    ============================================================
    */

    /*
        UUPS upgrade authorization

        Must be controlled by:
        Timelock only

        Never EOA long-term.
    */
    function _authorizeUpgrade(
        address
    )
        internal
        override
        onlyRole(UPGRADER_ROLE)
    {}
}