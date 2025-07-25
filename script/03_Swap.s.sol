// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {Constants} from "./base/Constants.sol";
import {Config} from "./base/Config.sol";

contract SwapScript is Script, Constants, Config {
    // slippage tolerance to allow for unlimited price impact
    uint160 public constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 public constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    /////////////////////////////////////
    // --- Parameters to Configure --- //
    /////////////////////////////////////

    // PoolSwapTest Contract address, default to the anvil address
    // SEPOLIA
    PoolSwapTest swapRouter = PoolSwapTest(0x9B6b46e2c869aa39918Db7f52f5557FE577B6eEe);

    // --- pool configuration --- //
    // fees paid by swappers that accrue to liquidity providers
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

        // approve tokens to the swap router
        vm.startBroadcast();
        token0.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(hookContract), type(uint256).max);
        
        token1.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(hookContract), type(uint256).max);
        vm.stopBroadcast();

        // ------------------------------ //
        // Swap 100e18 token0 into token1 //
        // ------------------------------ //
        bool zeroForOne = true;
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: 1e18,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT // unlimited impact
        });

        // in v4, users have the option to receieve native ERC20s or wrapped ERC1155 tokens
        // here, we'll take the ERC20s
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        bytes memory hookData = new bytes(0);
        vm.broadcast();
        swapRouter.swap(pool, params, testSettings, hookData);
    }
}
