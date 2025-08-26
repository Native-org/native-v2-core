// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

interface ICreditVault {
    function swapCallback(
        address signer,
        address sellerToken,
        int256 amount0Delta,
        address buyerToken,
        int256 amount1Delta
    ) external;

    /// @notice Struct for tracking daily rebalance limits per trader/liquidator and token
    /// @param limit Daily rebalance limit
    /// @param used Amount rebalanced today
    /// @param lastDay Last rebalance day timestamp
    struct RebalanceCap {
        uint256 limit;
        uint256 used;
        uint256 lastDay;
    }

    /// @notice Epoch Funding fee updates for a specific trader
    /// @param trader The address of the trader
    /// @param feeUpdates Array of funding fee updates for different tokens
    struct AccruedFundingFee {
        address trader;
        FundingFeeAmount[] feeUpdates;
    }

    /// @notice Details of funding and reserve fees for a specific token
    /// @param token The unerlying token address
    /// @param fundingFee  Amount of fee distributed to LP holders
    /// @param reserveFee Amount of fee reserved for the protocol
    struct FundingFeeAmount {
        address token;
        uint256 fundingFee;
        uint256 reserveFee;
    }

    /// @notice Represents a token amount with unsigned integer value
    /// @param token The address of underlying token
    /// @param amount The unsigned amount of tokens
    struct TokenAmountUint {
        address token;
        uint256 amount;
    }

    /// @notice Represents a token amount with signed integer value (for positions)
    /// @param token The address of underlying token
    /// @param amount The signed amount (positive for long, negative for short)
    struct TokenAmountInt {
        address token;
        int256 amount;
    }

    /// @notice Request parameters for position settlement
    /// @param nonce Unique identifier to prevent replay attacks
    /// @param deadline Timestamp after which the request expires
    /// @param trader Address of the trader whose positions are being settled
    /// @param positionUpdates Array of position changes to be settled
    struct SettlementRequest {
        uint256 nonce;
        uint256 deadline;
        address trader;
        TokenAmountInt[] positionUpdates;
    }

    /// @notice Request parameters for collateral removal
    /// @param nonce Unique identifier to prevent replay attacks
    /// @param deadline Timestamp after which the request expires
    /// @param trader Address of the trader removing collateral
    /// @param tokens Array of collateral tokens to be removed
    struct RemoveCollateralRequest {
        uint256 nonce;
        uint256 deadline;
        address trader;
        TokenAmountUint[] tokens;
    }

    /// @notice Request parameters for position liquidation
    /// @param nonce Unique identifier to prevent replay attacks
    /// @param deadline Timestamp after which the request expires
    /// @param trader Address of the trader being liquidated
    /// @param positionUpdates Array of position changes from liquidation
    /// @param claimCollaterals Array of collateral tokens to be claimed
    struct LiquidationRequest {
        uint256 nonce;
        uint256 deadline;
        address trader;
        TokenAmountInt[] positionUpdates;
        TokenAmountUint[] claimCollaterals;
    }

    /// @notice Emitted when a new market (LP token) is listed
    /// @param lpToken The address of the newly listed LP token
    event MarketListed(address lpToken);

    /// @notice Emitted when epoch funding fees are updated for traders
    /// @param accruedFundingFees Array of funding fee updates for different traders
    event EpochUpdated(AccruedFundingFee[] accruedFundingFees);

    /// @notice Emitted when a trader's positions are repaid
    /// @param trader The address of the trader whose positions are being repaid
    /// @param repayments Array of token amounts being repaid
    event Repaid(address trader, TokenAmountInt[] repayments);

    /// @notice Emitted when a trader's positions are settled
    /// @param trader The address of the trader whose positions are being settled
    /// @param positionUpdates Array of position changes
    event Settled(address trader, TokenAmountInt[] positionUpdates);

    /// @notice Emitted when collateral is added for a trader
    /// @param trader The address of the trader receiving collateral
    /// @param collateralUpdates Array of collateral token amounts added
    event CollateralAdded(address trader, TokenAmountUint[] collateralUpdates);

    /// @notice Emitted when collateral is removed for a trader
    /// @param trader The address of the trader removing collateral
    /// @param collateralUpdates Array of collateral token amounts removed
    event CollateralRemoved(address trader, TokenAmountUint[] collateralUpdates);

    /// @notice Emitted when a trader's positions are liquidated
    /// @param trader The address of the trader being liquidated
    /// @param liquidator The address performing the liquidation
    /// @param positionUpdates Array of position changes from liquidation
    /// @param claimCollaterals Array of collateral tokens claimed by liquidator
    event Liquidated(
        address trader, address liquidator, TokenAmountInt[] positionUpdates, TokenAmountUint[] claimCollaterals
    );

    /// @notice Emitted when a credit pool's status is updated
    /// @param pool The address of the credit pool
    /// @param isActive The new status of the pool
    event CreditPoolUpdated(address indexed pool, bool isActive);

    /// @notice Emitted when a trader or liquidator's rebalance limit is updated for a token
    /// @param operator The trader or liquidator address
    /// @param token The token address
    /// @param limit The new daily limit (0 means unlimited)
    event RebalanceCapUpdated(address indexed operator, address indexed token, uint256 limit);

    /// @notice Emitted when a trader's info is updated
    /// @param trader The address of the trader whose info is being updated
    /// @param isTrader Whether the address is enabled for trading
    /// @param isWhitelistTrader Whether the trader can bypass credit checks
    /// @param settler The address authorized to settle positions for this trader
    /// @param recipient The address authorized to receive tokens from settlements

    event TraderSet(address indexed trader, bool isTrader, bool isWhitelistTrader, address settler, address recipient);

    /// @notice Emitted when liquidator is set
    event LiquidatorSet(address liquidator, bool status);

    /// @notice Emitted when signer is set
    event SignerSet(address signer);

    /// @notice Emitted when epoch updater is set
    event EpochUpdaterSet(address epochUpdater);

    /// @notice Emitted when fee withdrawer is set
    event FeeWithdrawerSet(address feeWithdrawer);

    /// @notice Emitted when reserve fees are withdrawn
    event ReserveWithdrawn(address underlying, address recipient, uint256 amount);
}
