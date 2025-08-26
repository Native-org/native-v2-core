# Native v2 Core
Native is an on-chain platform to build token liquidity that is openly accessible and cost effective. It serves as an alternative to traditional AMMs through integration of two innovative designs: the [Native Swap Engine](https://docs.native.org/native-dev/solution/native-swap-engine) and [Native Credit Pool](https://docs.native.org/native-dev/solution/native-credit-pool).

The vision of Native is to transform on-chain liquidity from `inventory-based` to `credit-based`. Native is designed to address the limitations of current onchain marketplaces, including liquidity fragmentation and capital inefficiency, by decoupling the pricing capability and inventory provision, paving the way for a new era in decentralized finance.

## How Native V2 Core Works

Native v2 offers RFQ quotes with zero slippage loss. Furthermore, the `Native swap engine` allows `private market makers` to transition from a `credit-based` model to an `inventory-based` model.

Example:

Suppose Alice wants to sell 10 ETH at 4,000 USDC each to a market maker. In a traditional inventory-based system, the market maker would need to hold 40,000 USDC upfront. With Native v2’s credit-based system, however, market makers can borrow assets directly from Native’s credit vault (up to their credit limit). They only pay borrowing fees after a certain period, with rates referencing perpetual DEX funding rates. This approach reduces the need for pre-funded capital and improves on-chain liquidity while maintaining more competitive pricing.


## Repository Structure

This repository only provides the source code for Native v2’s core smart contracts (`CreditVault` and `NativeLPToken`). Due to our modular design, components such as `NativeRouter` and `NativeRFQPool` are continuously evolving, for their source code, please reference their latest deployment addresses.

[`NativeLPToken.sol`](./src/NativeLPToken.sol) is a yield-bearing token. Each underlying asset corresponds to a unique LP token contract. LP investors can deposit assets through this contract, but unlike traditional ERC20 tokens, deposited assets are transferred to the `CreditVault` contract instead of remaining in the LP token contract.

The yield for NativeLPToken comes from borrowing fees generated when market makers utilize funds from the credit vault.

[`CreditVault.sol`](./src/CreditVault.sol) is Native's core contract holding most assets. All market maker swaps using credit vault assets are executed through this contract.

Example: When Alice sells one ETH at 4000 USDC/ETH, and Halo (market maker) trades using the credit vault, the position changes are reflected as:

```solidity
position[pmmAddress][ETH] += 1;
position[pmmAddress][USDC] -= 4000;
```

The CreditVault contract provides key functions:
* `settle`: Market makers can close positions
* `repay`: Market makers can repay borrowed assets
* `addCollateral`: Market makers can provide NativeLPToken as collateral
* `removeCollateral`: Market makers can reduce collateral
* `liquidation`: Trusted liquidators can liquidate underwater market maker positions

## Audits

All audit reports can be found at this [link](https://docs.native.org/native-dev/resources/audits)

## Usage

### Build

```shell
$ forge build
```

### Format

```shell
$ forge fmt
```
