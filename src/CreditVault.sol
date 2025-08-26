// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {EIP712, ECDSA} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import "./libraries/ConstantsLib.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {SafeERC20} from "./libraries/SafeERC20.sol";
import {ICreditVault} from "./interfaces/ICreditVault.sol";
import {ReentrancyGuardTransient} from "./libraries/ReentrancyGuardTransient.sol";

import {NativeLPToken} from "./NativeLPToken.sol";

/// @title CreditVault - Manages trader positions and collateral
/// @notice Handles asset custody, position settlement, and LP token integration
contract CreditVault is ICreditVault, EIP712, Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;

    /*//////////////////////////////////////////////////////////////////////////
                                     STATE VARIABLES
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Address that can withdraw protocol fees
    address public feeWithdrawer;

    /// @notice signer for permissioned functions: liquidate, settle, removeCollateral, etc.
    address public signer;

    /// @notice epoch updater address
    address public epochUpdater;

    /// @notice A list of all markets
    NativeLPToken[] public allLPTokens;

    /// @notice Authorized Native Pool, enable market makers to lend funds from this vault for quoting
    /// @dev The credit pool lends tokens from the credit vault and must update the trader's position via a callback.
    mapping(address => bool) public creditPools;

    /// @notice Mapping of accumulated reserveFees per token (token => fee amount)
    mapping(address => uint256) public reserveFees;

    /// @notice (trader => timestamp)
    mapping(address => uint256) public lastEpochUpdateTimestamp;

    /// @notice map from underlying address to LP token
    mapping(address => NativeLPToken) public lpTokens;

    // @notice Mapping to track used nonces for preventing replay attacks
    mapping(uint256 => bool) public nonces;

    /// @notice  trader_address => underlying token => amount (positive for long, negative for short)
    mapping(address => mapping(address => int256)) public positions;

    /// @notice traders' collateral trader => token => amount
    mapping(address => mapping(address => uint256)) public collateral;

    /// @dev If a LP token is supported
    mapping(address => bool) public supportedMarkets;

    /// @notice whitelist for traders (Market Makers)
    mapping(address => bool) public traders;

    /// @notice Maps trader address to settler address which can settle positions on behalf of trader
    mapping(address => address) public traderToSettler;

    /// @notice maps trader to their recipient address
    /// @dev Address receives tokens from settlements and collateral operations
    mapping(address => address) public traderToRecipient;

    /// @notice whitelist traders that can bypass the credit check
    mapping(address => bool) public whitelistTraders;

    /// @notice whitelist for liquidators
    mapping(address => bool) public liquidators;

    /// @notice maps liquidator to their recipient address for liquidations
    mapping(address => address) public liquidatorToRecipient;

    /// @notice Tracks rebalance caps for each trader/liquidator and token
    mapping(address => mapping(address => RebalanceCap)) public rebalanceCaps;

    /*//////////////////////////////////////////////////////////////////////////
                                     CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    constructor() EIP712("Native Credit Vault", "1") {}

    /// @notice Callback function called by NativeRFQPool after swap execution to update trader positions
    /// @dev Only callable by whitelisted NativePools, it's called after the swap is executed
    /// @param trader The address of the market maker
    /// @param tokenIn The address of the token that is selling
    /// @param amountIn The amount of the token that is selling
    /// @param tokenOut The address of the token that is buying
    /// @param amountOut The amount of the token that is buying
    function swapCallback(
        address trader,
        address tokenIn,
        int256 amountIn,
        address tokenOut,
        int256 amountOut
    ) external {
        require(creditPools[msg.sender], ErrorsLib.OnlyCreditPool());
        require(
            address(lpTokens[tokenIn]) != address(0) && address(lpTokens[tokenOut]) != address(0),
            ErrorsLib.InvalidUnderlying()
        );

        positions[trader][tokenIn] += amountIn;
        positions[trader][tokenOut] -= amountOut;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    PERMISSIONED FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Updates funding fees for traders at the end of each epoch
    /// @dev Only callable by the epoch updater
    /// @param accruedFees Array of funding fee updates for different traders
    function epochUpdate(AccruedFundingFee[] calldata accruedFees) external {
        require(msg.sender == epochUpdater, ErrorsLib.OnlyEpochUpdater());

        for (uint256 i; i < accruedFees.length; ++i) {
            address trader = accruedFees[i].trader;

            if (block.timestamp - lastEpochUpdateTimestamp[trader] < EPOCH_UPDATE_INTERVAL) {
                revert ErrorsLib.EpochUpdateInCoolDown();
            }

            for (uint256 j; j < accruedFees[i].feeUpdates.length; ++j) {
                address token = accruedFees[i].feeUpdates[j].token;
                uint256 fundingFee = accruedFees[i].feeUpdates[j].fundingFee;
                uint256 reserveFee = accruedFees[i].feeUpdates[j].reserveFee;

                // Check if the underlying token is supported
                require(address(lpTokens[token]) != address(0), ErrorsLib.InvalidUnderlying());

                if (fundingFee > 0) {
                    uint256 beforeExchangeRate = lpTokens[token].exchangeRate();

                    // Distribute funding fee to all LPToken holders
                    lpTokens[token].distributeYield(fundingFee);

                    // Verify the exchange rate increase is not more than 1%
                    if (((lpTokens[token].exchangeRate() - beforeExchangeRate) * 10_000) > beforeExchangeRate * 100) {
                        revert ErrorsLib.ExchangeRateIncreaseTooMuch();
                    }
                }

                if (reserveFee > 0) {
                    reserveFees[token] += reserveFee;
                }
                // Subtract reserve fee and funding fee from the trader's position
                positions[trader][token] -= (reserveFee + fundingFee).toInt256();
            }

            lastEpochUpdateTimestamp[trader] = block.timestamp;
        }

        emit EpochUpdated(accruedFees);
    }

    /// @notice Called by traders to settle the positions
    /// @dev This transaction requires off-chain calculation to verify if the trader's credit meets the criteria.
    /// @param request The struct of the settlement request containing info of long and short positions to settle
    /// @param signature The signature of the settlement request
    function settle(
        SettlementRequest calldata request,
        bytes calldata signature
    ) external onlyTraderOrSettler(request.trader) nonReentrant {
        _verifySettleSignature(request, signature);

        _updatePositions(request.positionUpdates, request.trader);

        address recipient = traderToRecipient[request.trader];

        // execute token transfers
        for (uint256 i; i < request.positionUpdates.length; ++i) {
            address token = request.positionUpdates[i].token;
            int256 amount = request.positionUpdates[i].amount;

            if (amount > 0) {
                IERC20(token).safeTransferFrom(msg.sender, address(this), amount.toUint256());
            } else {
                /// Enforce rebalance cap before funds leave vault to ensure limit compliance
                _updateRebalanceCap(request.trader, token, (-amount).toUint256());

                IERC20(token).safeTransfer(recipient, (-amount).toUint256());
            }
        }

        emit Settled(request.trader, request.positionUpdates);
    }

    /// @notice Called by traders to remove collateral
    /// @dev This transaction requires off-chain calculation to verify if the trader's credit meets the criteria.
    /// @param request The struct of the remove collateral request containing info of collateral to remove
    /// @param signature The signature of the remove collateral request
    function removeCollateral(
        RemoveCollateralRequest calldata request,
        bytes calldata signature
    ) external onlyTraderOrSettler(request.trader) nonReentrant {
        _verifyRemoveCollateralSignature(request, signature);

        for (uint256 i; i < request.tokens.length; ++i) {
            collateral[request.trader][request.tokens[i].token] -= request.tokens[i].amount;
        }

        address recipient = traderToRecipient[request.trader];
        for (uint256 i; i < request.tokens.length; ++i) {
            address token = request.tokens[i].token;
            uint256 amount = request.tokens[i].amount;

            /// Enforce rebalance cap before funds leave vault
            _updateRebalanceCap(request.trader, token, amount);

            IERC20(token).safeTransfer(recipient, amount);
        }

        emit CollateralRemoved(request.trader, request.tokens);
    }

    /// @notice Repays trader's short positions
    /// @param positionUpdates Array of {token, amount} structs representing positions to repay
    /// @param trader Address of the trader whose positions are being repaid
    function repay(
        TokenAmountInt[] calldata positionUpdates,
        address trader
    ) external onlyTraderOrSettler(trader) nonReentrant {
        _updatePositions(positionUpdates, trader);

        // the safeCast to Uint256 will revert if the repayments amount is negative
        for (uint256 i; i < positionUpdates.length; ++i) {
            IERC20(positionUpdates[i].token).safeTransferFrom(
                msg.sender, address(this), positionUpdates[i].amount.toUint256()
            );
        }

        emit Repaid(trader, positionUpdates);
    }

    /// @notice Called by liquidators to liquidate the underwater positions
    /// @dev This transaction requires off-chain calculation to verify if the trader's credit meets the criteria.
    /// @param request The struct of the liquidation request containing info of long and short positions to liquidate
    /// @param signature The signature of the liquidation request
    function liquidate(
        LiquidationRequest calldata request,
        bytes calldata signature
    ) external onlyLiquidator nonReentrant {
        _verifyLiquidationSignature(request, signature);

        _updatePositions(request.positionUpdates, request.trader);

        address recipient = liquidatorToRecipient[msg.sender];

        for (uint256 i; i < request.claimCollaterals.length; ++i) {
            collateral[request.trader][request.claimCollaterals[i].token] -= request.claimCollaterals[i].amount;
        }

        for (uint256 i; i < request.positionUpdates.length; ++i) {
            address token = request.positionUpdates[i].token;
            int256 amount = request.positionUpdates[i].amount;

            if (amount > 0) {
                IERC20(token).safeTransferFrom(msg.sender, address(this), amount.toUint256());
            } else {
                /// Enforce rebalance cap before underlying token leave vault
                _updateRebalanceCap(msg.sender, token, (-amount).toUint256());

                IERC20(token).safeTransfer(recipient, (-amount).toUint256());
            }
        }

        for (uint256 i; i < request.claimCollaterals.length; ++i) {
            address token = request.claimCollaterals[i].token;

            /// Enforce rebalance cap before collateral token leave vault
            _updateRebalanceCap(msg.sender, token, request.claimCollaterals[i].amount);

            IERC20(token).safeTransfer(recipient, request.claimCollaterals[i].amount);
        }

        emit Liquidated(request.trader, msg.sender, request.positionUpdates, request.claimCollaterals);
    }

    /// @notice Transfers underlying assets from vault to recipient
    /// @dev Only callable by supported LP tokens
    /// @param to Recipient of the underlying assets
    /// @param amount Amount of underlying assets to transfer
    function pay(address to, uint256 amount) external {
        require(supportedMarkets[msg.sender], ErrorsLib.OnlyLpToken());
        require(amount <= NativeLPToken(msg.sender).totalUnderlying(), ErrorsLib.InsufficientUnderlying());

        // Each LP token can only transfer its own underlying token
        IERC20(NativeLPToken(msg.sender).underlying()).safeTransfer(to, amount);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    PERMISSIONLESS FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Adds collateral for a trader's position
    /// @dev PERMISSIONLESS: Anyone can add collateral for any trader
    /// @dev Off-chain system will update trader's credit limit off-chain via event emission
    /// @param tokens Array of {token, amount} structs to be added as collateral
    /// @param trader Address of the trader receiving the collateral
    function addCollateral(TokenAmountUint[] calldata tokens, address trader) external nonReentrant {
        require(traders[trader], ErrorsLib.OnlyTrader());

        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i].token;
            require(supportedMarkets[token], ErrorsLib.OnlyLpToken());

            uint256 amount = tokens[i].amount;
            collateral[trader][token] += amount;

            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        }

        emit CollateralAdded(trader, tokens);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Lists a new market (LP token)
    /// @dev Only callable by owner
    /// @param lpToken Address of the LP token to be listed
    function supportMarket(NativeLPToken lpToken) external onlyOwner {
        // Check if market is already listed
        require(!supportedMarkets[address(lpToken)], ErrorsLib.TokenAlreadyListed());

        address underlying = address(lpToken.underlying());

        // Verify market configuration
        require(
            address(lpTokens[underlying]) == address(0) && lpToken.creditVault() == address(this),
            ErrorsLib.InvalidMarket()
        );

        // Sanity check to make sure its really LPToken
        require(address(underlying) != address(0), ErrorsLib.InvalidLPToken());

        // Update storage
        lpTokens[underlying] = lpToken;
        supportedMarkets[address(lpToken)] = true;
        allLPTokens.push(lpToken);

        emit MarketListed(address(lpToken));
    }

    /// @notice Allows fee withdrawer to claim accumulated funding fees
    /// @dev Only callable by feeWithdrawer
    /// @param underlying The token address of the fees to withdraw
    /// @param recipient The address that will receive the fees
    /// @param amount The amount of fees to withdraw
    function withdrawReserve(address underlying, address recipient, uint256 amount) external {
        require(recipient != address(0), ErrorsLib.ZeroAddress());
        require(msg.sender == feeWithdrawer, ErrorsLib.OnlyFeeWithdrawer());
        require(amount <= reserveFees[underlying], ErrorsLib.InsufficientFundingFees());

        reserveFees[underlying] -= amount;

        // Withdraw underlying from vault
        IERC20(underlying).safeTransfer(recipient, amount);

        emit ReserveWithdrawn(underlying, recipient, amount);
    }

    /// @notice Updates credit pool status
    /// @param pool The address of credit pool
    /// @param isActive to whitelist, false to remove from whitelist
    function setCreditPool(address pool, bool isActive) external onlyOwner {
        require(pool != address(0), ErrorsLib.ZeroAddress());

        creditPools[pool] = isActive;

        emit CreditPoolUpdated(pool, isActive);
    }

    /// @notice Approves native pool to spend vault's underlying tokens
    /// @dev Only callable by owner
    /// @dev Pool must be whitelisted as native pool
    /// @param tokens Array of {token, amount} structs to approve
    /// @param pool Address of native pool to receive approval
    function setAllowance(TokenAmountUint[] calldata tokens, address pool) external onlyOwner {
        for (uint256 i; i < tokens.length; ++i) {
            require(address(lpTokens[tokens[i].token]) != address(0), ErrorsLib.InvalidUnderlying());

            IERC20(tokens[i].token).safeApprove(pool, tokens[i].amount);
        }
    }

    /// @notice Set or update the daily rebalance limit for a specific trader or liquidator and token
    /// @dev A limit of 0 means unlimited rebalancing is allowed
    /// @param operator The address of the trader or liquidator whose limit is being set
    /// @param token The token address for which the limit applies
    /// @param limit The maximum amount of tokens that can be rebalanced per day (0 for unlimited)
    function setRebalanceCap(address operator, address token, uint256 limit) external onlyOwner {
        require(token != address(0), ErrorsLib.ZeroAddress());
        require(traders[operator] || liquidators[operator], ErrorsLib.NotTraderOrLiquidator());

        // used will be reset to 0
        rebalanceCaps[operator][token] = RebalanceCap({limit: limit, used: 0, lastDay: block.timestamp / 86_400});

        emit RebalanceCapUpdated(operator, token, limit);
    }

    /// @notice Manages trader permissions and settlement addresses
    /// @dev Only callable by owner
    /// @param trader Address to configure trading permissions for
    /// @param settler Address authorized to settle positions on trader's behalf
    /// @param recipient Address authorized to receive tokens from settlements and collateral operations
    /// @param isTrader True to enable trading, false to revoke permissions
    /// @param isWhitelistTrader True to enable whitelist which can bypass credit check
    function setTrader(
        address trader,
        address settler,
        address recipient,
        bool isTrader,
        bool isWhitelistTrader
    ) external onlyOwner {
        require(trader != address(0) && settler != address(0) && recipient != address(0), ErrorsLib.ZeroAddress());
        require(recipient != trader && recipient != settler, ErrorsLib.TraderRecipientConflict());

        traders[trader] = isTrader;
        traderToSettler[trader] = settler;
        traderToRecipient[trader] = recipient;

        whitelistTraders[trader] = isWhitelistTrader;

        emit TraderSet(trader, isTrader, isWhitelistTrader, settler, recipient);
    }

    /// @notice Set or remove liquidator permissions
    /// @dev Only callable by owner
    /// @param liquidator The address to grant/revoke liquidator permissions
    /// @param recipient Address authorized to receive tokens from liquidations
    /// @param status True to whitelist, false to remove from whitelist
    function setLiquidator(address liquidator, address recipient, bool status) external onlyOwner {
        require(liquidator != address(0) && recipient != address(0), ErrorsLib.ZeroAddress());
        require(liquidator != recipient, ErrorsLib.LiquidatorRecipientConflict());

        liquidators[liquidator] = status;
        liquidatorToRecipient[liquidator] = recipient;

        emit LiquidatorSet(liquidator, status);
    }

    /// @notice Updates the authorized signer for permissioned operations
    /// @dev Only callable by owner
    /// @dev Signer verifies signatures for settlements, liquidations, and collateral removals
    /// @param _signer New signer address (cannot be zero address)
    function setSigner(address _signer) external onlyOwner {
        require(_signer != address(0), ErrorsLib.ZeroAddress());

        signer = _signer;

        emit SignerSet(_signer);
    }

    /// @notice Updates the authorized epoch updater address
    /// @dev Only callable by owner
    /// @dev Epoch updater is responsible for funding fee updates and distributions
    /// @param _epochUpdater New epoch updater address (cannot be zero address)
    function setEpochUpdater(address _epochUpdater) external onlyOwner {
        require(_epochUpdater != address(0), ErrorsLib.ZeroAddress());

        epochUpdater = _epochUpdater;

        emit EpochUpdaterSet(_epochUpdater);
    }

    /// @notice Updates the authorized fee withdrawer address
    /// @dev Only callable by owner
    /// @dev Fee withdrawer can claim accumulated funding fees from the vault
    /// @param _feeWithdrawer New fee withdrawer address (cannot be zero address)
    function setFeeWithdrawer(address payable _feeWithdrawer) external onlyOwner {
        require(_feeWithdrawer != address(0), ErrorsLib.ZeroAddress());

        feeWithdrawer = _feeWithdrawer;

        emit FeeWithdrawerSet(_feeWithdrawer);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function _updateNonce(uint256 nonce) internal {
        require(!nonces[nonce], ErrorsLib.NonceUsed());

        nonces[nonce] = true;
    }

    function _updatePositions(ICreditVault.TokenAmountInt[] memory positionUpdates, address trader) internal {
        uint256 updatesLength = positionUpdates.length;
        for (uint256 i; i < updatesLength; ++i) {
            address token = positionUpdates[i].token;
            int256 amount = positionUpdates[i].amount;
            int256 newPosition = positions[trader][token] + amount;
            // Make sure the token is supported underlying token
            require(address(lpTokens[token]) != address(0), ErrorsLib.InvalidLPToken());

            // Position must decrease without flipping its sign (e.g. long 100 -> long 50, not long 100 -> short 20)
            if (positions[trader][token] * amount >= 0 || positions[trader][token] * newPosition < 0) {
                revert ErrorsLib.InvalidPositionUpdateAmount();
            }

            positions[trader][token] = newPosition;
        }
    }

    /// @notice Check and update daily rebalance tracking for a trader's token position
    /// @param trader The address of the trader attempting to rebalance
    /// @param token The token address being rebalanced, can be underlying token or collateral token
    /// @param amount The amount of tokens being rebalanced
    function _updateRebalanceCap(address trader, address token, uint256 amount) internal {
        RebalanceCap storage cap = rebalanceCaps[trader][token];
        uint256 currentDay = block.timestamp / 86_400;
        uint256 newUsed;

        // Reset daily used amount if it's a new day, otherwise add to existing
        if (currentDay > cap.lastDay) {
            newUsed = amount;
        } else {
            newUsed = cap.used + amount;
        }

        // Check if rebalance would exceed daily limit, skip check if limit is 0 (unlimited)
        require(cap.limit == 0 || newUsed <= cap.limit, ErrorsLib.RebalanceLimitExceeded());

        // Update storage in a single write
        rebalanceCaps[trader][token] = RebalanceCap({limit: cap.limit, used: newUsed, lastDay: currentDay});
    }

    function _verifySettleSignature(
        ICreditVault.SettlementRequest calldata request,
        bytes calldata signature
    ) internal {
        require(request.deadline >= block.timestamp, ErrorsLib.RequestExpired());

        _updateNonce(request.nonce);

        bytes32 msgHash = keccak256(
            abi.encode(
                SETTLEMENT_REQUEST_SIGNATURE_HASH,
                request.nonce,
                request.deadline,
                request.trader,
                keccak256(abi.encode(request.positionUpdates)),
                traderToRecipient[request.trader]
            )
        );
        bytes32 digest = _hashTypedDataV4(msgHash);
        address recoveredSigner = ECDSA.recover(digest, signature);

        require(recoveredSigner == signer, ErrorsLib.InvalidSignature());
    }

    function _verifyRemoveCollateralSignature(
        ICreditVault.RemoveCollateralRequest calldata request,
        bytes calldata signature
    ) internal {
        require(request.deadline >= block.timestamp, ErrorsLib.RequestExpired());

        _updateNonce(request.nonce);

        bytes32 msgHash = keccak256(
            abi.encode(
                REMOVE_COLLATERAL_REQUEST_SIGNATURE_HASH,
                request.nonce,
                request.deadline,
                request.trader,
                keccak256(abi.encode(request.tokens)),
                traderToRecipient[request.trader]
            )
        );
        bytes32 digest = _hashTypedDataV4(msgHash);
        address recoveredSigner = ECDSA.recover(digest, signature);

        require(recoveredSigner == signer, ErrorsLib.InvalidSignature());
    }

    function _verifyLiquidationSignature(
        ICreditVault.LiquidationRequest calldata request,
        bytes calldata signature
    ) internal {
        require(request.deadline >= block.timestamp, ErrorsLib.RequestExpired());

        _updateNonce(request.nonce);

        bytes32 msgHash = keccak256(
            abi.encode(
                LIQUIDATION_REQUEST_SIGNATURE_HASH,
                request.nonce,
                request.deadline,
                request.trader,
                keccak256(abi.encode(request.positionUpdates)),
                keccak256(abi.encode(request.claimCollaterals)),
                liquidatorToRecipient[msg.sender]
            )
        );
        bytes32 digest = _hashTypedDataV4(msgHash);
        address recoveredSigner = ECDSA.recover(digest, signature);

        require(recoveredSigner == signer, ErrorsLib.InvalidSignature());
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     MODIFIERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Separate the trader and settler accounts, they have different operation frequency and security setup requirements
    modifier onlyTraderOrSettler(address trader) {
        require(
            (traders[trader] && trader == msg.sender) // Make sure a trader can only dispose of their own position
                || (traders[trader] && msg.sender == traderToSettler[trader]), // Trader's settler can also settle their own position
            ErrorsLib.OnlyTrader()
        );
        _;
    }

    modifier onlyLiquidator() {
        require(liquidators[msg.sender], ErrorsLib.OnlyLiquidator());
        _;
    }
}
