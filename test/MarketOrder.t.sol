// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

//Foundry Imports
import "forge-std/Test.sol";

//Uniswap Imports
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {SortTokens} from "./utils/SortTokens.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {MarketOrder} from "../src/MarketOrder.sol";
import {Token} from "../src/Token.sol";

//FHE Imports
import {FHE, InEuint128, euint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {CoFheTest} from "@fhenixprotocol/cofhe-mock-contracts/CoFheTest.sol";

contract MarketOrderTest is Test, Fixtures, CoFheTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    MarketOrder hook;
    address hookAddr;
    PoolId poolId;

    Token token0;
    Token token1;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    uint128 private constant LIQUIDITY_1E8 = 1e8;
    uint128 private constant LIQUIDITY_1E9 = 1e9;
    bool private constant ZERO_FOR_ONE = true;
    bool private constant ONE_FOR_ZERO = false;

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        deployFreshManagerAndRouters();

        deployMintAndApprove2Currencies();

        (token0, token1) = (Token(Currency.unwrap(currency0)), Token(Currency.unwrap(currency1)));

        deployAndApprovePosm(manager);

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );
        bytes memory constructorArgs = abi.encode(manager); //Add all the necessary constructor arguments from the hook
        deployCodeTo("MarketOrder.sol:MarketOrder", constructorArgs, flags);
        hook = MarketOrder(flags);

        hookAddr = address(hook);

        vm.label(hookAddr, "hook");
        vm.label(address(this), "test");
        vm.label(address(token0), "token0");
        vm.label(address(token1), "token1");

        // Create the pool
        key = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);

        // Provide full-range liquidity to the pool
        tickLower = TickMath.minUsableTick(key.tickSpacing);
        tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        uint128 liquidityAmount = 100e18;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        (tokenId,) = posm.mint(
            key,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );

        token0.approve(hookAddr, type(uint256).max);
        token1.approve(hookAddr, type(uint256).max);
    }

    function test_placeOrderTokenBalances() public {
        (uint256 t0, uint256 t1, uint256 h0, uint256 h1) = _getBalances();

        InEuint128 memory liquidity = createInEuint128(LIQUIDITY_1E8, address(this));
        hook.placeMarketOrder(key, ZERO_FOR_ONE, liquidity);

        (uint256 t2, uint256 t3, uint256 h2, uint256 h3) = _getBalances();

        assertEq(t0, t2);
        assertEq(t1, t3);
        assertEq(h0, h2);
        assertEq(h1, h3);
    }

    function test_QueueContainsOrder() public {
        InEuint128 memory liquidity = createInEuint128(LIQUIDITY_1E8, address(this));
        hook.placeMarketOrder(key, ZERO_FOR_ONE, liquidity);

        euint128 top = hook.getPoolQueue(key, ZERO_FOR_ONE).peek();
        assertHashValue(top, LIQUIDITY_1E8);

        address user = hook.getUserOrder(key, euint128.unwrap(top));
        assertEq(user, address(this));
    }

    function test_BeforeSwapOrderExecutes() public {
        (uint256 t0, uint256 t1,,) = _getBalances();

        InEuint128 memory liquidity = createInEuint128(LIQUIDITY_1E8, address(this));
        hook.placeMarketOrder(key, ZERO_FOR_ONE, liquidity);

        vm.warp(block.timestamp + 11); //ensure decryption is finished

        vm.recordLogs();

        _swap(ONE_FOR_ZERO, 1e5);  //perform swap e.g. trigger beforeSwap hook

        Vm.Log[] memory entries = vm.getRecordedLogs();
        
        assertEq(entries[5].topics.length, 3);
        assertEq(entries[5].topics[0], keccak256("OrderSettled(address,uint256)"));
        assertEq(entries[5].topics[1], bytes32(abi.encode(address(this))));
        assertEq(entries[5].topics[2], bytes32(liquidity.ctHash));

        (uint256 t2, uint256 t3,,) = _getBalances();

        assertGt(t0, t2);   // user balance t0 decreases
        assertLt(t1, t3);   // user balance t1 increases
    }

    function test_secondOrderFlushed() public {
        InEuint128 memory liquidity = createInEuint128(LIQUIDITY_1E8, address(this));
        hook.placeMarketOrder(key, ZERO_FOR_ONE, liquidity);

        vm.warp(block.timestamp + 11);

        euint128 top = hook.getPoolQueue(key, ZERO_FOR_ONE).peek();
        assertHashValue(top, LIQUIDITY_1E8);

        InEuint128 memory liquidity2 = createInEuint128(LIQUIDITY_1E9, address(this));
        hook.placeMarketOrder(key, ONE_FOR_ZERO, liquidity2);

        assertTrue(hook.getPoolQueue(key, ZERO_FOR_ONE).isEmpty()); //first order should be flushed

        euint128 top2 = hook.getPoolQueue(key, ONE_FOR_ZERO).peek();// second order should top of other queue
        assertHashValue(top2, LIQUIDITY_1E9);
    }

    function test_OrderFailed() public {
        (,, uint256 h0, uint256 h1) = _getBalances();

        InEuint128 memory liquidity = createInEuint128(LIQUIDITY_1E8, address(this));
        hook.placeMarketOrder(key, ZERO_FOR_ONE, liquidity);

        vm.warp(block.timestamp + 11);

        token0.burn(token0.balanceOf(address(this)));

        vm.recordLogs();

        // make sure this does not revert
        _swap(ONE_FOR_ZERO, 1e5);

        Vm.Log[] memory entries = vm.getRecordedLogs();

        // Market Order Events:
        // order failed

        // Regular Swap Events:
        // swap
        // transfer (in)
        // transfer (out)
        assertEq(entries.length, 4);

        assertEq(entries[0].topics.length, 3);
        assertEq(entries[0].topics[0], keccak256("OrderFailed(address,uint256)"));
        assertEq(entries[0].topics[1], bytes32(abi.encode(address(this))));
        assertEq(entries[0].topics[2], bytes32(liquidity.ctHash));

        (,, uint256 h2, uint256 h3) = _getBalances();

        // ensure queue is empty
        assertEq(hook.getPoolQueue(key, ZERO_FOR_ONE).isEmpty(), true);

        // assert hook balances don't change
        assertEq(h0, h2);
        assertEq(h1, h3);
    }

    // ---------------------------
    //
    //      Helper Functions
    //
    // ---------------------------
    function _getBalances() private returns(uint256 t0, uint256 t1, uint256 h0, uint256 h1) {
        t0 = token0.balanceOf(address(this));
        t1 = token1.balanceOf(address(this));
        h0 = token0.balanceOf(hookAddr);
        h1 = token1.balanceOf(hookAddr);
    }

    function _swap(bool zeroForOne, int256 amount) private returns(BalanceDelta){
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amount,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });
        return swapRouter.swap(key, params, _defaultTestSettings(), ZERO_BYTES);
    }

    function _defaultTestSettings() internal pure returns (PoolSwapTest.TestSettings memory testSetting) {
        return PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false});
    }
}
