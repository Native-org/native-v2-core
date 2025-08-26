// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockERC20 Contract
/// @notice A mock ERC20 token contract used for testing and development purposes.
/// @dev Extends the OpenZeppelin ERC20 standard implementation.
contract MockERC20 is ERC20 {
    /// @dev Address of the owner of the contract, typically set to the deployer.

    address private _owner;
    /// @dev Number of decimals the token uses, can be customized upon deployment.
    uint8 private _decimals = 18;

    /// @param name The name of the token.
    /// @param symbol The symbol of the token.
    /// @param _decimals_ The number of decimals the token should use.
    constructor(string memory name, string memory symbol, uint8 _decimals_) ERC20(name, symbol) {
        _owner = msg.sender;
        _decimals = _decimals_;
    }

    /// @notice Mints tokens to a specified address.
    /// @dev Only the owner of the contract can call this function.
    /// @param _to The address to which the tokens will be minted.
    /// @param _amount The amount of tokens to mint.
    function mint(address _to, uint256 _amount) public {
        require(msg.sender == _owner, "OnlyOwner");
        _mint(_to, _amount);
    }

    /// @notice Burns tokens from a specified address.
    /// @dev Only the owner of the contract can call this function.
    /// @param _to The address from which the tokens will be burned.
    /// @param _amount The amount of tokens to burn.
    function burn(address _to, uint256 _amount) public {
        require(msg.sender == _owner, "OnlyOwner");
        _burn(_to, _amount);
    }

    /// @notice Returns the number of decimals used to get its user representation.
    /// @dev Overridden to allow customization of decimals.
    /// @return uint8 The number of decimals the token uses.
    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}
