// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

/// @title Transient storage utils
library TStorage {
    /// @notice Loads a boolean value from transient storage at a given slot.
    /// @param slot The storage slot to read from.
    /// @return value The boolean value stored at the specified slot.
    function tload(bytes32 slot) internal view returns (bool value) {
        assembly {
            value := tload(slot)
        }
    }

    /// @notice Stores a boolean value in transient storage at a given slot.
    /// @param slot The storage slot to write to.
    /// @param value The boolean value to store at the specified slot.
    function tstore(bytes32 slot, bool value) internal {
        assembly {
            tstore(slot, value)
        }
    }
}
