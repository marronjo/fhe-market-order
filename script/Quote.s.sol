// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";

import {Constants} from "./base/Constants.sol";
import {Config} from "./base/Config.sol";

contract QuoteScript is Script, Constants, Config {

    uint24 lpFee = 3000; // 0.30%
    int24 tickSpacing = 60;

    function run() external {

        PoolKey memory pool = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: hookContract
        });

        IV4Quoter.QuoteExactSingleParams memory params = IV4Quoter.QuoteExactSingleParams({
            poolKey: pool,
            zeroForOne: true,
            exactAmount: 1e18,
            hookData: bytes("")     
        });

        vm.broadcast();
        IV4Quoter(0x61B3f2011A92d183C7dbaDBdA940a7555Ccf9227).quoteExactInputSingle(params);
    }
}
