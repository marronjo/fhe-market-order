// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title MarketOrder
 * @dev A Uniswap V4 hook that enables front-running resistant market orders using Fully Homomorphic Encryption (FHE)
 * 
 * This contract allows users to place front-running resistant market orders that are queued and executed
 * when liquidity becomes available. Orders are processed in FIFO order and use FHE to
 * maintain privacy of order amounts until execution.
 * 
 * Key Features:
 * - Private order amounts using FHE encryption
 * - FIFO order queue per pool per direction
 * - Automatic order settlement during swaps
 * - Manual flush capability for immediate processing
 * - Reentrancy protection
 */

// Uniswap Imports
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
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

// Custom Queue for FHE values
import {Queue} from "./Queue.sol";

// Token Imports
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

// FHE Imports
import {FHE, InEuint128, euint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

contract MarketOrder is BaseHook, IUnlockCallback, ReentrancyGuardTransient {

    // =============================================================
    //                           EVENTS
    // =============================================================
    
    event OrderPlaced(address indexed user, euint128 indexed handle);
    event OrderSettled(address indexed user, euint128 indexed handle);
    event OrderFailed(address indexed user, euint128 indexed handle);

    // =============================================================
    //                          LIBRARIES
    // =============================================================
    
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using EpochLibrary for Epoch;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;

    // NOTE: More natural syntax with euint operations by using FHE library
    // All euint types are wrapped forms of uint256, therefore using library
    // for uint256 works for all euint types
    using FHE for uint256;

    // =============================================================
    //                          STRUCTS
    // =============================================================
    
    /**
     * @dev Contains the two order queues for each pool (one per direction)
     */
    struct QueueInfo {
        Queue zeroForOne;  // Queue for token0 -> token1 swaps
        Queue oneForZero;  // Queue for token1 -> token0 swaps
    }

    // =============================================================
    //                         CONSTANTS
    // =============================================================
    
    bytes internal constant ZERO_BYTES = bytes("");

    // =============================================================
    //                      STATE VARIABLES
    // =============================================================
    
    /// @dev Maps pool ID and order handle to the user who placed the order
    mapping(PoolId key => mapping(uint256 handle => address user)) private userOrders;

    /// @dev Each pool has 2 separate decryption queues, one for each trade direction
    mapping(PoolId key => QueueInfo queues) private poolQueue;

    // =============================================================
    //                        CONSTRUCTOR
    // =============================================================
    
    /**
     * @dev Initializes the MarketOrder hook with the pool manager
     * @param _poolManager The Uniswap V4 pool manager instance
     */
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    // =============================================================
    //                      HOOK CONFIGURATION
    // =============================================================
    
    /**
     * @dev Defines which hook functions this contract implements
     * @return Hooks.Permissions struct with only beforeSwap enabled
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,                    // Enable to process queued orders
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // =============================================================
    //                      PUBLIC FUNCTIONS
    // =============================================================
    
    /**
     * @dev Gets or creates a queue for a specific pool and swap direction
     * @param key The pool key identifying the specific pool
     * @param zeroForOne True for token0->token1 swaps, false for token1->token0
     * @return queue The Queue contract instance for this pool and direction
     */
    function getPoolQueue(PoolKey memory key, bool zeroForOne) public returns(Queue queue) {
        QueueInfo storage queueInfo = poolQueue[key.toId()];

        if (zeroForOne) {
            if (address(queueInfo.zeroForOne) == address(0)) {
                queueInfo.zeroForOne = new Queue();
            }
            queue = queueInfo.zeroForOne;
        } else {
            if (address(queueInfo.oneForZero) == address(0)) {
                queueInfo.oneForZero = new Queue();
            }
            queue = queueInfo.oneForZero;
        }
    }

    /**
     * @dev Gets the user address for a specific order handle in a pool
     * @param key The pool key
     * @param handle The encrypted order handle
     * @return The address of the user who placed the order
     */
    function getUserOrder(PoolKey calldata key, uint256 handle) public view returns(address) {
        return userOrders[key.toId()][handle];
    }

    /**
     * @dev Checks if an encrypted order has been decrypted and is ready for execution
     * @param handle The encrypted order handle to check
     * @return decrypted True if the order has been decrypted, false otherwise
     */
    function getOrderDecryptStatus(euint128 handle) external view returns(bool decrypted) {
        (, decrypted) = FHE.getDecryptResultSafe(handle);
    }

    /**
     * @dev Places a new encrypted market order in the queue
     * @param key The pool key for the target pool
     * @param zeroForOne True for token0->token1 swap, false for token1->token0
     * @param liquidity Encrypted amount of input tokens to swap
     */
    function placeMarketOrder(PoolKey calldata key, bool zeroForOne, InEuint128 calldata liquidity) external {
        // Flush existing orders from the queue to avoid build up
        flushOrder(key);

        euint128 _liquidity = FHE.asEuint128(liquidity);
        uint256 handle = euint128.unwrap(_liquidity);

        // Store the order owner for later settlement
        userOrders[key.toId()][handle] = msg.sender;
        
        // Request decryption of the encrypted amount
        FHE.decrypt(_liquidity);

        // Add order to the appropriate queue
        getPoolQueue(key, zeroForOne).push(_liquidity);

        emit OrderPlaced(msg.sender, _liquidity);
    }

    // =============================================================
    //                     HOOK IMPLEMENTATIONS
    // =============================================================
    
    /**
     * @dev Hook called before each swap to process any decrypted orders
     * @param key The pool key for the swap
     * @return selector The function selector to confirm hook execution
     * @return BeforeSwapDelta Zero delta as we don't modify the swap
     * @return uint24 Zero dynamic fee as we don't charge additional fees
     */
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Process decrypted orders in both directions
        _settleDecryptedOrders(key, true);   // token0 -> token1
        _settleDecryptedOrders(key, false);  // token1 -> token0

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // =============================================================
    //                      PRIVATE FUNCTIONS
    // =============================================================
    
    /**
     * @dev Processes all decrypted orders in a queue for a specific direction
     * @param key The pool key
     * @param zeroForOne The swap direction to process
     */
    function _settleDecryptedOrders(PoolKey memory key, bool zeroForOne) private {
        Queue queue = getPoolQueue(key, zeroForOne);
        
        while (!queue.isEmpty()) {
            euint128 handle = queue.peek();
            (uint128 liquidity, bool decrypted) = FHE.getDecryptResultSafe(handle);
            
            if (decrypted) {
                // Attempt to collect user tokens for the swap
                (address user, bool success) = _depositUserTokens(key, handle, liquidity, zeroForOne);
                if (!success) {
                    emit OrderFailed(user, handle);
                    queue.pop();
                    break; // Stop processing if token transfer fails
                }
                
                // Execute the swap and settle with the user
                _executeDecryptedOrder(key, user, liquidity, zeroForOne);
                queue.pop();
                emit OrderSettled(user, handle);
            } else {
                break; // Stop processing if decryption not ready
            }
        }
    }
    
    /**
     * @dev Manually flushes decrypted orders from the queue
     * This method needs to acquire a lock to swap with the pool manager.
     * It's called when placing new orders to prevent queue buildup.
     * @param key The pool key to flush orders for
     */
    function flushOrder(PoolKey calldata key) public nonReentrant {
        poolManager.unlock(abi.encode(key));
    }

    /**
     * @dev Callback function called when pool manager lock is acquired
     * @param data Encoded PoolKey data
     * @return Empty bytes as no return data needed
     */
    function unlockCallback(bytes calldata data) external override onlyPoolManager returns(bytes memory) {
        PoolKey memory key = abi.decode(data, (PoolKey));
        _settleDecryptedOrders(key, true);   // Process token0 -> token1 orders
        _settleDecryptedOrders(key, false);  // Process token1 -> token0 orders
        return ZERO_BYTES;
    }

    /**
     * @dev Attempts to collect input tokens from the user for their order
     * @param key The pool key
     * @param handle The order handle to identify the user
     * @param amount The decrypted amount to collect
     * @param zeroForOne The swap direction
     * @return user The address of the user who placed the order
     * @return success True if token transfer succeeded, false otherwise
     */
    function _depositUserTokens(PoolKey memory key, euint128 handle, uint128 amount, bool zeroForOne) 
        private 
        returns(address user, bool success) 
    {
        user = userOrders[key.toId()][euint128.unwrap(handle)];
        address token = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        success = IERC20(token).trySafeTransferFrom(user, address(this), uint256(amount));
    }

    /**
     * @dev Executes a decrypted order by performing the swap and settling with the user
     * @param key The pool key
     * @param user The user address to send output tokens to
     * @param decryptedLiquidity The decrypted input amount
     * @param zeroForOne The swap direction
     * @return amount0 The absolute amount of token0 involved in the swap
     * @return amount1 The absolute amount of token1 involved in the swap
     */
    function _executeDecryptedOrder(PoolKey memory key, address user, uint128 decryptedLiquidity, bool zeroForOne) 
        private 
        returns(uint128 amount0, uint128 amount1) 
    {
        // Execute the swap with the pool manager
        BalanceDelta delta = _swapPoolManager(key, zeroForOne, -int256(uint256(decryptedLiquidity))); 

        // Calculate absolute amounts based on swap direction
        if (zeroForOne) {
            amount0 = uint128(-delta.amount0()); // Hook sends in -amount0 and receives +amount1
            amount1 = uint128(delta.amount1());
        } else {
            amount0 = uint128(delta.amount0());  // Hook sends in -amount1 and receives +amount0
            amount1 = uint128(-delta.amount1());
        }

        // Settle with pool manager - send tokens owed to pool and take tokens owed to hook
        if (delta.amount0() < 0) {
            // Hook owes token0 to pool, pool owes token1 to hook
            key.currency0.settle(poolManager, address(this), uint256(amount0), false);
            key.currency1.take(poolManager, address(this), uint256(amount1), false);
            // Send output tokens to user
            IERC20(Currency.unwrap(key.currency1)).safeTransfer(user, uint256(amount1));
        } else {
            // Hook owes token1 to pool, pool owes token0 to hook
            key.currency1.settle(poolManager, address(this), uint256(amount1), false);
            key.currency0.take(poolManager, address(this), uint256(amount0), false);
            // Send output tokens to user
            IERC20(Currency.unwrap(key.currency0)).safeTransfer(user, amount0);
        }
    }

    /**
     * @dev Executes a swap with the pool manager
     * @param key The pool key
     * @param zeroForOne The swap direction
     * @param amountSpecified The amount to swap (negative for exact input)
     * @return delta The balance changes from the swap
     */
    function _swapPoolManager(PoolKey memory key, bool zeroForOne, int256 amountSpecified) 
        private 
        returns(BalanceDelta delta) 
    {
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ?
                        TickMath.MIN_SQRT_PRICE + 1 :   // Minimum price for token0->token1
                        TickMath.MAX_SQRT_PRICE - 1     // Maximum price for token1->token0
        });

        delta = poolManager.swap(key, params, ZERO_BYTES);
    }
}
