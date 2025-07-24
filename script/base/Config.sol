// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice Shared configuration between scripts
contract Config {
    /// @dev populated with default anvil addresses
    IERC20 constant token0 = IERC20(address(0x2f4eD4942BdF443aE5da11ac3cAB7bee8d6FaF45));       // CPH
    IERC20 constant token1 = IERC20(address(0xbD313aDE73Cc114184CdBEf96788dd55118d4911));       // MSK
    IHooks constant hookContract = IHooks(address(0x31f5b2DbC1497fA726C0240417E6E2c6089EC080)); // Market Order Hook

    Currency constant currency0 = Currency.wrap(address(token0));
    Currency constant currency1 = Currency.wrap(address(token1));
}
