// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title 1 Million Dollar (1MD)
/// @notice A plain, fixed-supply ERC-20. The whole supply of 1,000,000,000 tokens (18 decimals) is
///         minted exactly once, to the deployer, in the constructor. Nothing can mint afterwards.
/// @dev Deliberately minimal:
///      - no owner, no admin role, no pause, no blocklist, no fee or tax on transfer;
///      - no `mint`, `burn` or `burnFrom` entry points, so the supply can never grow and no third
///        party can reduce a holder's balance;
///      - no proxy, no `delegatecall`, no `selfdestruct`;
///      - the constructor takes no arguments and makes no external calls, so it deploys on an empty
///        chain and the deployer (the launch factory) receives every minor unit of the supply.
///      The Solidity identifier is short on purpose (the launch records it as 32 bytes); the token's
///      human-readable name and symbol are what `name()` and `symbol()` return.
contract OneMillionDollarToken is ERC20 {
    /// @notice ERC-20 name, as returned by `name()`.
    string public constant TOKEN_NAME = "1 Million Dollar";

    /// @notice ERC-20 symbol, as returned by `symbol()`.
    string public constant TOKEN_SYMBOL = "1MD";

    /// @notice Decimals, as returned by `decimals()` (the OpenZeppelin default of 18).
    uint8 public constant TOKEN_DECIMALS = 18;

    /// @notice The entire supply in minor units: 1,000,000,000 * 10**18. Minted once, never again.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** uint256(TOKEN_DECIMALS);

    /// @notice Mints the whole fixed supply to the deployer (`msg.sender`).
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
