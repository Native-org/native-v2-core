// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata as IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "./libraries/ConstantsLib.sol";
import {CreditVault} from "./CreditVault.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {ReentrancyGuardTransient} from "./libraries/ReentrancyGuardTransient.sol";

/// @title NativeLPToken - Yield-bearing LP token contract
/// @notice A token contract that represents liquidity provider positions and distributes yield
/// @dev This contract manages LP shares and underlying assets, accruing yield based on protocol revenue
contract NativeLPToken is ERC20, Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////////////////
                                     STATE VARIABLES
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Whether deposit operations are paused
    bool public depositPaused;

    /// @notice Whether redeem operations are paused
    bool public redeemPaused;

    /// @notice The underlying token that this LP token represents
    IERC20 public underlying;

    /// @notice The address of the credit vault contract
    address public creditVault;

    /// @notice The number of decimals for this token, matching the underlying token's decimals
    uint8 private _decimals;

    /// @notice Total amount of underlying assets deposited by LPs
    uint256 public totalUnderlying;

    /// @notice Total number of shares issued
    uint256 public totalShares;

    /// @notice Early withdrawal fee in basis points (1 bip = 0.01%)
    /// @dev Applied to prevent front-running by users who deposit right before yield distribution and immediately redeem after
    uint256 public earlyWithdrawFeeBips;

    /// @notice Accumulated early withdrawal fee
    uint256 public accEarlyWithdrawFee;

    /// @notice Minimum time interval between deposit and redeem (in seconds)
    uint256 public minRedeemInterval;

    /// @notice Minimum amount required for deposits
    uint256 public minDeposit;

    /// @notice Mapping of user addresses to their share balances
    mapping(address => uint256) public shares;

    /// @notice Mapping of trusted operators who can call depositFor and redeemTo functions
    mapping(address => bool) public trustedOperators;

    /// @notice Mapping of user addresses to their last deposit timestamp
    mapping(address => uint256) public lastDepositTimestamp;

    /// @notice Mapping of addresses exempt from redeem cooldown period and early withdrawal fees
    mapping(address => bool) public redeemCooldownExempt;

    /*//////////////////////////////////////////////////////////////////////////
                                        EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Event emitted when deposit operation is paused
    event DepositPaused();

    /// @notice Event emitted when deposit operation is unpaused
    event DepositUnpaused();

    /// @notice Event emitted when redeem operation is paused
    event RedeemPaused();

    /// @notice Event emitted when redeem operation is unpaused
    event RedeemUnpaused();

    /// @notice Event emitted when yield is distributed to LP holders
    event YieldDistributed(uint256 yieldAmount);

    /// @notice Event emitted when minimum redeem interval is updated
    event MinRedeemIntervalUpdated(uint256 newInterval);

    /// @notice Event emitted when shares are transferred between addresses
    event TransferShares(address indexed from, address indexed to, uint256 shares);

    /// @notice Event emitted when new shares are minted
    event SharesMinted(address indexed from, address indexed to, uint256 shares, uint256 underlyingAmount);

    /// @notice Event emitted when shares are burned
    event SharesBurned(address indexed from, address indexed to, uint256 shares, uint256 underlyingAmount);

    /// @notice Event emitted when minimum deposit amount is updated
    event MinDepositUpdated(uint256 oldAmount, uint256 newAmount);

    /// @notice Event emitted when early withdraw fee is updated
    event EarlyWithdrawFeeBipsUpdated(uint256 oldFeeBips, uint256 newFeeBips);

    /// @notice Event emitted when a trusted operator status is updated
    event TrustedOperatorUpdated(address indexed account, bool status);

    /// @notice Event emitted when an address's redeem cooldown exemption status is updated
    event RedeemCooldownExemptUpdated(address indexed account, bool status);

    /// @notice Event emitted when early withdrawal fees are withdrawn
    event EarlyWithdrawFeeWithdrawn(address indexed recipient, uint256 amount);

    /*//////////////////////////////////////////////////////////////////////////
                                     CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    constructor(
        string memory _name,
        string memory _symbol,
        address _underlying,
        address _creditVault
    ) ERC20(_name, _symbol) {
        underlying = IERC20(_underlying);
        creditVault = _creditVault;

        _decimals = IERC20(address(underlying)).decimals();
    }

    /// @notice Deposit underlying tokens to mint LP tokens
    /// @param amount Amount of underlying tokens to deposit
    /// @return sharesToMint Amount of LP tokens minted
    function deposit(uint256 amount)
        external
        nonReentrant
        whenNotPaused(depositPaused)
        returns (uint256 sharesToMint)
    {
        sharesToMint = _deposit(msg.sender, msg.sender, amount);
    }

    /// @notice Deposit underlying tokens on behalf of another address
    /// @param to The address to mint shares to
    /// @param amount Amount of underlying tokens to deposit
    /// @return sharesToMint Amount of LP tokens minted
    function depositFor(
        address to,
        uint256 amount
    ) external nonReentrant whenNotPaused(depositPaused) returns (uint256 sharesToMint) {
        require(to != address(0), ErrorsLib.ZeroAddress());
        require(trustedOperators[msg.sender], ErrorsLib.NotTrustedOperator());
        sharesToMint = _deposit(msg.sender, to, amount);
    }

    /// @notice Redeem LP tokens for underlying tokens
    /// @param sharesToBurn Amount of LP tokens to burn
    /// @return underlyingAmount Amount of underlying tokens received
    function redeem(uint256 sharesToBurn)
        external
        nonReentrant
        whenNotPaused(redeemPaused)
        returns (uint256 underlyingAmount)
    {
        underlyingAmount = _redeem(sharesToBurn, msg.sender);
    }

    /// @notice Redeem LP tokens and send underlying tokens to a specified address
    /// @param sharesToBurn Amount of LP tokens to burn from caller's balance
    /// @param to Address that will receive the underlying tokens
    /// @return underlyingAmount Amount of underlying tokens sent to the recipient
    function redeemTo(
        uint256 sharesToBurn,
        address to
    ) external nonReentrant whenNotPaused(redeemPaused) returns (uint256 underlyingAmount) {
        require(to != address(0), ErrorsLib.ZeroAddress());
        require(trustedOperators[msg.sender], ErrorsLib.NotTrustedOperator());
        underlyingAmount = _redeem(sharesToBurn, to);
    }

    /// @notice Transfers shares from sender to recipient
    /// @param recipient The address to transfer shares to
    /// @param sharesAmount The number of shares to transfer
    /// @return The amount of underlying tokens the shares represent
    function transferShares(address recipient, uint256 sharesAmount) external returns (uint256) {
        _transferShares(msg.sender, recipient, sharesAmount);
        uint256 tokensAmount = getUnderlyingByShares(sharesAmount);
        _emitTransferEvents(msg.sender, recipient, tokensAmount, sharesAmount);
        return tokensAmount;
    }

    /// @notice Distributes yield to LP token holders
    /// @param yieldAmount Amount of yield to distribute
    /// @dev Can only be called by the credit vault
    function distributeYield(uint256 yieldAmount) external {
        require(totalShares > 0, ErrorsLib.PoolNotInitialized());
        require(yieldAmount > 0, ErrorsLib.NoYieldToDistribute());
        require(msg.sender == creditVault, ErrorsLib.OnlyCreditVault());

        totalUnderlying += yieldAmount;

        emit YieldDistributed(yieldAmount);
    }

    /// @notice Gets the underlying token balance of an account
    /// @param account The address to check the balance for
    /// @return The amount of underlying tokens the account effectively owns
    function balanceOf(address account) public view override returns (uint256) {
        return getUnderlyingByShares(shares[account]);
    }

    /// @notice Gets the total supply of underlying tokens in the pool
    /// @return The total amount of underlying tokens managed by this contract
    function totalSupply() public view override returns (uint256) {
        return totalUnderlying;
    }

    /// @notice Gets the number of shares owned by an account
    /// @param account The address to check shares for
    /// @return The number of shares owned by the account
    function sharesOf(address account) public view returns (uint256) {
        return shares[account];
    }

    /// @notice Calculates the underlying token amount for a given number of shares
    /// @param sharesAmount The number of shares to convert
    /// @return The corresponding amount of underlying tokens
    function getUnderlyingByShares(uint256 sharesAmount) public view returns (uint256) {
        if (totalShares == 0) {
            return sharesAmount;
        }
        return (sharesAmount * totalUnderlying) / totalShares;
    }

    /// @notice Calculates the number of shares for a given amount of underlying tokens
    /// @param underlyingAmount The amount of underlying tokens to convert
    /// @return The corresponding number of shares
    function getSharesByUnderlying(uint256 underlyingAmount) public view returns (uint256) {
        if (totalShares == 0) {
            return underlyingAmount;
        }
        return (underlyingAmount * totalShares) / totalUnderlying;
    }

    /// @notice Gets the current exchange rate between shares and underlying tokens
    /// @return The exchange rate scaled by 1e18 (1:1 = 1e18)
    function exchangeRate() public view returns (uint256) {
        if (totalShares == 0) {
            return 1e18; // Initial exchange rate 1:1
        }
        return (totalUnderlying * 1e18) / totalShares;
    }

    /// @notice Gets the number of decimals for this token
    /// @return The number of decimals, matching the underlying token
    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    OWNER ONLY OPERATIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Sets the minimum deposit amount
    /// @param _minDeposit New minimum deposit amount
    /// @dev Can only be called by the owner
    function setMinDeposit(uint256 _minDeposit) external onlyOwner {
        uint256 oldAmount = minDeposit;
        minDeposit = _minDeposit;
        emit MinDepositUpdated(oldAmount, _minDeposit);
    }

    /// @notice Sets the minimum time interval required between deposit and redeem
    /// @param _interval New minimum interval in seconds
    /// @dev Can only be called by the owner
    function setMinRedeemInterval(uint256 _interval) external onlyOwner {
        minRedeemInterval = _interval;

        emit MinRedeemIntervalUpdated(_interval);
    }

    /// @notice Sets the early withdrawal fee in basis points (BIPs)
    /// @param _earlyWithdrawFeeBips New early withdrawal fee in BIPs
    /// @dev Can only be called by the owner
    function setEarlyWithdrawFeeBips(uint256 _earlyWithdrawFeeBips) external onlyOwner {
        require(_earlyWithdrawFeeBips <= MAX_EARLY_WITHDRAW_FEE_BIPS, ErrorsLib.InvalidFeeBips());

        uint256 oldFeeBips = earlyWithdrawFeeBips;
        earlyWithdrawFeeBips = _earlyWithdrawFeeBips;

        emit EarlyWithdrawFeeBipsUpdated(oldFeeBips, _earlyWithdrawFeeBips);
    }

    /// @notice Sets the trusted operator status for multiple addresses
    /// @param accounts The addresses to update
    /// @param statuses The new operator statuses corresponding to each account
    function setTrustedOperator(address[] calldata accounts, bool[] calldata statuses) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            require(accounts[i] != address(0), ErrorsLib.ZeroAddress());

            trustedOperators[accounts[i]] = statuses[i];
            emit TrustedOperatorUpdated(accounts[i], statuses[i]);
        }
    }

    /// @notice Sets the redeem cooldown exemption status for multiple addresses
    /// @param accounts The addresses to update
    /// @param statuses The new exemption statuses corresponding to each account
    /// @dev Can only be called by the owner
    function setRedeemCooldownExempt(address[] calldata accounts, bool[] calldata statuses) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            require(accounts[i] != address(0), ErrorsLib.ZeroAddress());

            redeemCooldownExempt[accounts[i]] = statuses[i];
            emit RedeemCooldownExemptUpdated(accounts[i], statuses[i]);
        }
    }

    /// @notice Withdraws accumulated early withdrawal fees
    /// @param recipient The address to receive the withdrawn fees
    function withdrawEarlyFees(address recipient) external onlyOwner {
        require(recipient != address(0), ErrorsLib.ZeroAddress());

        // Transfer fees from credit vault to recipient
        CreditVault(creditVault).pay(recipient, accEarlyWithdrawFee);

        emit EarlyWithdrawFeeWithdrawn(recipient, accEarlyWithdrawFee);

        accEarlyWithdrawFee = 0;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     PAUSE OPERATIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Function to pause deposit operation
    function pauseDeposit() external onlyOwner {
        depositPaused = true;
        emit DepositPaused();
    }

    /// @notice Function to unpause deposit operation
    function unpauseDeposit() external onlyOwner {
        depositPaused = false;
        emit DepositUnpaused();
    }

    /// @notice Function to pause redeem operation
    function pauseRedeem() external onlyOwner {
        redeemPaused = true;
        emit RedeemPaused();
    }

    /// @notice Function to unpause redeem operation
    function unpauseRedeem() external onlyOwner {
        redeemPaused = false;
        emit RedeemUnpaused();
    }

    modifier whenNotPaused(bool feature) {
        if (feature) {
            revert ErrorsLib.FeaturePaused();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function _deposit(address from, address to, uint256 amount) internal returns (uint256 sharesToMint) {
        require(amount >= minDeposit && amount > 0, ErrorsLib.BelowMinimumDeposit());

        // Transfer underlying to vault
        uint256 balanceBefore = underlying.balanceOf(creditVault);
        underlying.safeTransferFrom(from, creditVault, amount);
        amount = underlying.balanceOf(creditVault) - balanceBefore;

        // Calculate shares to mint
        if (totalShares == 0) {
            // Lock 1000 shares from first depositor to prevent inflation attack
            _mintShares(address(0), MINIMUM_SHARE);
            sharesToMint = amount - MINIMUM_SHARE;
        } else {
            sharesToMint = (amount * totalShares) / totalUnderlying;
        }

        // Mint shares
        _mintShares(to, sharesToMint);

        // Update total underlying
        totalUnderlying += amount;

        lastDepositTimestamp[to] = block.timestamp;

        emit SharesMinted(from, to, sharesToMint, amount);
    }

    function _redeem(uint256 sharesToBurn, address to) internal returns (uint256 underlyingAmount) {
        require(sharesToBurn > 0, ErrorsLib.ZeroAmount());
        require(shares[msg.sender] >= sharesToBurn, ErrorsLib.InsufficientShares());

        // Calculate underlying amount
        uint256 grossUnderlyingAmount = (sharesToBurn * totalUnderlying) / totalShares;
        underlyingAmount = grossUnderlyingAmount;

        if (
            block.timestamp < lastDepositTimestamp[msg.sender] + minRedeemInterval && earlyWithdrawFeeBips > 0
                && !redeemCooldownExempt[msg.sender]
        ) {
            uint256 fee = (underlyingAmount * earlyWithdrawFeeBips) / 10_000;

            accEarlyWithdrawFee += fee;
            underlyingAmount -= fee;
        }

        // Burn shares first
        _burnShares(msg.sender, sharesToBurn);

        // Transfer underlying from vault to msg.sender
        CreditVault(creditVault).pay(to, underlyingAmount);

        // Update total underlying
        totalUnderlying -= grossUnderlyingAmount;

        emit SharesBurned(msg.sender, to, sharesToBurn, grossUnderlyingAmount);
    }

    function _mintShares(address to, uint256 shareAmount) internal {
        require(shareAmount > 0, ErrorsLib.ZeroAmount());

        shares[to] += shareAmount;
        totalShares += shareAmount;
    }

    function _burnShares(address from, uint256 shareAmount) internal {
        require(shareAmount > 0, ErrorsLib.ZeroAmount());
        require(from != address(0), ErrorsLib.ZeroAddress());

        shares[from] -= shareAmount;
        totalShares -= shareAmount;
    }

    /// @notice Override ERC20's _transfer to handle yield-bearing LP token transfers
    /// @dev Since this is a yield-bearing token, the actual transfer is done by transferring shares
    ///      rather than token amounts directly. The shares represent the user's proportion of the
    ///      total underlying assets including yield.
    /// @param from The address to transfer from
    /// @param to The address to transfer to
    /// @param amount The underlying token amount to transfer
    function _transfer(address from, address to, uint256 amount) internal override {
        uint256 sharesToTransfer = getSharesByUnderlying(amount);
        _transferShares(from, to, sharesToTransfer);
        _emitTransferEvents(from, to, amount, sharesToTransfer);
    }

    function _transferShares(address from, address to, uint256 _shares) internal {
        require(from != address(0) && to != address(0), ErrorsLib.ZeroAddress());
        require(from != to, ErrorsLib.TransferSelf());
        require(to != address(this), ErrorsLib.TransferToContract());

        _validateTransferCooldown(from);

        shares[from] -= _shares;
        shares[to] += _shares;
    }

    function _validateTransferCooldown(address user) internal view {
        // During cooldown period, user can't transfer shares, but can still redeem
        require(
            lastDepositTimestamp[user] + minRedeemInterval <= block.timestamp || redeemCooldownExempt[user],
            ErrorsLib.TransferInCooldown()
        );
    }

    function _emitTransferEvents(address from, address to, uint256 tokenAmount, uint256 sharesAmount) internal {
        emit Transfer(from, to, tokenAmount);
        emit TransferShares(from, to, sharesAmount);
    }
}
