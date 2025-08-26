// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

/// @title Custom error definitions for the protocol
/// @notice This library contains all the error definitions used throughout the contract
/// @dev The errors are arranged in alphabetical order
library ErrorsLib {
    /// @notice Thrown when actual amount deviation exceeds 10%
    error AmountDeviationExceeds();

    /// @notice Thrown when deposit amount is below minimum required
    error BelowMinimumDeposit();

    /// @notice Thrown when epoch update is attempted before minimum interval
    error EpochUpdateInCoolDown();

    /// @notice Thrown when LP token exchange rate increases more than allowed
    error ExchangeRateIncreaseTooMuch();

    /// @notice Thrown when feature is paused
    error FeaturePaused();

    /// @notice Thrown when there are insufficient funding fees to withdraw
    error InsufficientFundingFees();

    /// @notice Thrown when LP token shares are insufficient
    error InsufficientShares();

    /// @notice Thrown when LP token underlying is insufficient
    error InsufficientUnderlying();

    /// @notice Thrown when there is insufficient WETH9 to unwrap
    error InsufficientWETH9();

    /// @notice Thrown when an amount parameter is invalid
    error InvalidAmount();

    /// @notice Thrown when confidence factor E is invalid
    error InvalidConfidenceFactorE();

    /// @notice Thrown when confidence factor N is invalid
    error InvalidConfidenceFactorN();

    /// @notice Thrown when fee rate in basis points exceeds maximum (10000)
    error InvalidFeeBips();

    /// @notice Thrown when LP token address is invalid
    error InvalidLPToken();

    /// @notice Thrown when underlying are not supported in the credit vault
    error InvalidUnderlying();

    /// @notice Thrown when market (LP token) is invalid
    error InvalidMarket();

    /// @notice Thrown when position update amount is invalid
    error InvalidPositionUpdateAmount();

    /// @notice Thrown when the pool address is invalid Native pool
    error InvalidNativePool();

    /// @notice Thrown when signature verification fails
    error InvalidSignature();

    /// @notice Thrown when signer is not authorized
    error InvalidSigner();

    /// @notice Thrown when WETH9 unwrap amount is zero or exceeds balance
    error InvalidWETH9Amount();

    /// @notice Thrown when widget fee rate is invalid
    error InvalidWidgetFeeRate();

    /// @notice Thrown when liquidator and recipient are the same
    error LiquidatorRecipientConflict();

    /// @notice Thrown when nonce is used
    error NonceUsed();

    /// @notice Thrown when output amount is less than minimum required
    error NotEnoughAmountOut(uint256 amountOut, uint256 amountOutMinimum);

    /// @notice Thrown the address is not a trader or liquidator
    error NotTraderOrLiquidator();

    /// @notice Error when caller is not a trusted operator
    error NotTrustedOperator();

    /// @notice Thrown when there is no yield to distribute
    error NoYieldToDistribute();

    /// @notice Thrown when caller is not the credit pool
    error OnlyCreditPool();

    /// @notice Thrown when caller is not the credit vault
    error OnlyCreditVault();

    /// @notice Thrown when caller is not the epoch updater
    error OnlyEpochUpdater();

    /// @notice Thrown when caller is not the fee withdrawer
    error OnlyFeeWithdrawer();

    /// @notice Thrown when caller is not an authorized liquidator
    error OnlyLiquidator();

    /// @notice Thrown when caller is not an LP token
    error OnlyLpToken();

    /// @notice Thrown when caller is not the native router
    error OnlyNativeRouter();

    /// @notice Thrown when caller is not an authorized trader
    error OnlyTrader();

    /// @notice Thrown when caller is not the WETH9 contract
    error OnlyWETH9();

    /// @notice Thrown when arithmetic operation would overflow
    error Overflow();

    /// @notice Thrown when LP pool has no deposits yet
    error PoolNotInitialized();

    /// @notice Thrown when quote has expired
    error QuoteExpired();

    /// @notice Thrown when rebalance limit is exceeded
    error RebalanceLimitExceeded();

    /// @notice Thrown when request has expired
    error RequestExpired();

    /// @notice Thrown when token is already listed
    error TokenAlreadyListed();

    /// @notice Thrown when trader, settler and recipient are the same
    error TraderRecipientConflict();

    /// @notice Thrown when transfer is in cooldown period
    error TransferInCooldown();

    /// @notice Thrown when transfer to self
    error TransferSelf();

    /// @notice Thrown when transfer to current contract
    error TransferToContract();

    /// @notice Thrown when unexpected msg.value is sent
    error UnexpectedMsgValue();

    /// @notice Thrown when zero address is provided
    error ZeroAddress();

    /// @notice Thrown when amount is zero
    error ZeroAmount();

    /// @notice Thrown when input is zero or empty
    error ZeroInput();
}
