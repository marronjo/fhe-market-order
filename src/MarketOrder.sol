// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

//Uniswap Imports
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {EpochLibrary, Epoch} from "./lib/EpochLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

//Custom Queue for FHE values
import {Queue} from "./Queue.sol";

//Token Imports
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

//FHE Imports
import {FHE, InEuint128, euint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

contract MarketOrder is BaseHook {
    event MarketOrderExecuted(uint128 amount0, uint128 amount1);

    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using EpochLibrary for Epoch;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;

    // NOTE: ---------------------------------------------------------
    // more natural syntax with euint operations by using FHE library
    // all euint types are wrapped forms of uint256
    // therefore using library for uint256 works for all euint types
    // ---------------------------------------------------------------
    using FHE for uint256;

    struct QueueInfo {
        Queue zeroForOne;
        Queue oneForZero;
    }

    bytes internal constant ZERO_BYTES = bytes("");

    mapping(PoolId key => mapping(uint256 handle => address user)) private userOrders;

    // each pool has 2 separate decryption queues
    // one for each trade direction
    mapping(PoolId key => QueueInfo queues) private poolQueue;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    //if queue does not exist for given pool and direction, deploy new queue
    function getPoolQueue(PoolKey calldata key, bool zeroForOne) public returns(Queue queue){
        QueueInfo storage queueInfo = poolQueue[key.toId()];

        if(zeroForOne){
            if(address(queueInfo.zeroForOne) == address(0)){
                queueInfo.zeroForOne = new Queue();
            }
            queue = queueInfo.zeroForOne;
        } else {
            if(address(queueInfo.oneForZero) == address(0)){
                queueInfo.oneForZero = new Queue();
            }
            queue = queueInfo.oneForZero;
        }
    }

    function getUserOrder(PoolKey calldata key, uint256 handle) public view returns(address){
        return userOrders[key.toId()][handle];
    }

    // -----------------------------------------------
    // NOTE: see IHooks.sol for function documentation
    // -----------------------------------------------

    //TODO ... ADD APPROVALS!!!
    function placeMarketOrder(PoolKey calldata key, bool zeroForOne, InEuint128 calldata liquidity) external {
        euint128 _liquidity = FHE.asEuint128(liquidity);
        uint256 handle = euint128.unwrap(_liquidity);

        userOrders[key.toId()][handle] = msg.sender;
        FHE.decrypt(_liquidity);

        getPoolQueue(key, zeroForOne).push(_liquidity);
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _settleDecryptedOrders(key, true);
        _settleDecryptedOrders(key, false);

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _settleDecryptedOrders(PoolKey calldata key, bool zeroForOne) private returns(uint128 liquidity, bool decrypted){
        Queue queue = getPoolQueue(key, zeroForOne);
        while(!queue.isEmpty()){
            euint128 handle = queue.peek();
            (liquidity, decrypted) = FHE.getDecryptResultSafe(handle);
            if(decrypted){
                address user = _depositUserTokens(key, handle, liquidity, zeroForOne);
                _executeDecryptedOrder(key, user, liquidity, zeroForOne);
                queue.pop();
            } else {
                break;  //avoid looping until decryption ready
            }
        }
    }

    //What to do if transfer fails ? just skip or delete user order entirely ??
    //This will affect queue consistency eother way, could process intermedite orders and re-add to start of queue
    function _depositUserTokens(PoolKey calldata key, euint128 handle, uint128 amount, bool zeroForOne) private returns(address user){
        user = userOrders[key.toId()][euint128.unwrap(handle)];
        address token = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        IERC20(token).safeTransferFrom(user, address(this), uint256(amount));
    }

    function _executeDecryptedOrder(PoolKey calldata key, address user, uint128 decryptedLiquidity, bool zeroForOne) private returns(uint128 amount0, uint128 amount1) {
        BalanceDelta delta = _swapPoolManager(key, zeroForOne, -int256(uint256(decryptedLiquidity))); 

        if(zeroForOne){
            amount0 = uint128(-delta.amount0()); // hook sends in -amount0 and receives +amount1
            amount1 = uint128(delta.amount1());
        } else {
            amount0 = uint128(delta.amount0()); // hook sends in -amount1 and receives +amount0
            amount1 = uint128(-delta.amount1());
        }

        // settle with pool manager the unencrypted FHERC20 tokens
        // send in tokens owed to pool and take tokens owed to the hook
        if (delta.amount0() < 0) {
            key.currency0.settle(poolManager, address(this), uint256(amount0), false);
            key.currency1.take(poolManager, address(this), uint256(amount1), false);

            IERC20(Currency.unwrap(key.currency1)).safeTransfer(user, uint256(amount1));
        } else {
            key.currency1.settle(poolManager, address(this), uint256(amount1), false);
            key.currency0.take(poolManager, address(this), uint256(amount0), false);

            IERC20(Currency.unwrap(key.currency0)).safeTransfer(user, amount0);
        }
    }

    function _swapPoolManager(PoolKey calldata key, bool zeroForOne, int256 amountSpecified) private returns(BalanceDelta delta) {
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ?
                        TickMath.MIN_SQRT_PRICE + 1 :   // increasing price of token 1, lower ratio
                        TickMath.MAX_SQRT_PRICE - 1
        });

        delta = poolManager.swap(key, params, ZERO_BYTES);
    }
}
