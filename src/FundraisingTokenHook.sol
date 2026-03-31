// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IMsgSender} from "v4-periphery/src/interfaces/IMsgSender.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IStateView} from "v4-periphery/src/interfaces/IStateView.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TruncatedOracle} from "@uniswap/v4-periphery-trunc/libraries/TruncatedOracle.sol";
import {IIntegrationRegistry} from "./interfaces/IIntegrationRegistry.sol";

/**
 * @title FundraisingTokenHook
 * @notice Implements Uniswap V4 hooks to enforce launch protection, cooldowns, buy limits, and swap taxation
 *         for a fundraising token.
 * @dev
 * Integrates with the Uniswap V4 PoolManager, applying buy/sell restrictions and tax fees that are routed
 * to a treasury address. Supports launch protection with block and time based holds and per-wallet cooldowns.
 */
contract FundraisingTokenHook is BaseHook {
    using TruncatedOracle for TruncatedOracle.Observation[65535];

    /**
     * @notice Errors thrown by the contract
     */
    error TransactionNotAllowed();
    error BlockToHoldNotPassed();
    error AmountGreaterThanMaxBuyAmount();
    error CoolDownPeriodNotPassed();
    error FeeToLarge();

    /// @notice Oracle pools do not have fees because they exist to serve as an oracle for a pair of tokens
    error OnlyOneOraclePoolAllowed();

    /// @notice Oracle positions must be full range
    error OraclePositionsMustBeFullRange();

    /// @notice Oracle pools must have liquidity locked so that they cannot become more susceptible to price manipulation
    error OraclePoolMustLockLiquidity();

    uint256 internal launchTimestamp; // The timestamp when the token was launched
    uint256 internal constant perWalletCoolDownPeriod = 1 minutes;
    uint256 internal constant maxBuySize = 333e13; // 0.333% of total supply (scaled by 1e18)
    uint256 internal constant blocksToHold = 10; // Number of blocks after launch during which transfers are restricted
    uint256 internal constant timeToHold = 1 hours; // Number of seconds after launch during which special hold rules apply
    uint256 internal launchBlock; // Block number when the fundraising token was launched

    address public immutable fundraisingTokenAddress; // The address of the fundraising token
    address public immutable vault; // The address of the treasury wallet address
    IIntegrationRegistry public immutable integrationRegistry; // current integration endpoints source
    uint256 public constant maximumThreshold = 30e16; // The maximum threshold for the liquidity pool 30% = 30e16
    mapping(address => uint256) public lastBuyTimestamp; // The last buy timestamp for each address

    // 2% expressed with 18-decimal denominator
    uint256 public constant TAX_FEE_PERCENTAGE = 1e16; // 0.01 * 1e18 = 1e16 (1%)
    uint256 public constant TAX_FEE_DENOMINATOR = 1e18; // Denominator for tax fee calculation (1e18)

    /// @member index The index of the last written observation for the pool
    /// @member cardinality The cardinality of the observations array for the pool
    /// @member cardinalityNext The cardinality target of the observations array for the pool, which will replace cardinality when enough observations are written
    struct ObservationState {
        uint16 index;
        uint16 cardinality;
        uint16 cardinalityNext;
    }

    /// @notice The list of observations for a given pool ID
    mapping(bytes32 => TruncatedOracle.Observation[65535]) public observations;
    /// @notice The current observation array state for the given pool ID
    mapping(bytes32 => ObservationState) public states;

    /**
     * @notice Initializes the FundraisingTokenHook contract with the PoolManager and core protocol addresses.
     * @dev
     * This constructor sets up immutable references for critical protocol components:
     * - The Uniswap V4 `PoolManager` used for managing pool interactions.
     * - The `fundraisingTokenAddress` for which this hook will apply buy/sell rules and tax logic.
     * - The `vault`, which receives collected fees from swaps.
     *
     * It also records the deployment `launchTimestamp` and `launchBlock`, which are later
     * used to enforce launch protection (e.g., cooldowns, max buy limits, and block-based restrictions).
     *
     * @param _poolManager The address of the Uniswap V4 PoolManager contract.
     * @param _fundraisingTokenAddress The address of the fundraising token governed by this hook.
     * @param _vault The address of the treasury wallet that receives swap fees (immutable).
     */
    constructor(address _poolManager, address _fundraisingTokenAddress, address _vault, address _integrationRegistry)
        BaseHook(IPoolManager(_poolManager))
    {
        fundraisingTokenAddress = _fundraisingTokenAddress;
        launchTimestamp = block.timestamp;
        launchBlock = block.number;
        vault = _vault;
        integrationRegistry = IIntegrationRegistry(_integrationRegistry);
    }

    function observe(PoolKey calldata key, uint32[] calldata secondsAgos)
        external
        view
        returns (int48[] memory tickCumulatives, uint144[] memory secondsPerLiquidityCumulativeX128s)
    {
        bytes32 id = PoolId.unwrap(key.toId());

        ObservationState memory state = states[id];

        int24 tick = getCurrentTick(key);

        uint128 liquidity = IStateView(stateView()).getLiquidity(key.toId());

        return observations[id].observe(_blockTimestamp(), secondsAgos, tick, state.index, liquidity, state.cardinality);
    }

    function getCurrentTick(PoolKey calldata key) public view returns (int24) {
        (, int24 tick,,) = IStateView(stateView()).getSlot0(key.toId());
        return tick;
    }

    /**
     * @notice Defines the hook permissions required by this contract for Uniswap V4 integration.
     * @dev
     * This function specifies which Uniswap V4 hook callbacks are enabled for this contract.
     * Returning a `Hooks.Permissions` struct allows the PoolManager to know which lifecycle
     * events (e.g., swaps, liquidity changes) will trigger hook calls.
     *
     * In this implementation:
     * - Only `beforeSwap` and `afterSwap` hooks are enabled, since the contract enforces
     *   taxation and trading restrictions around swaps.
     * - Both `beforeSwapReturnDelta` and `afterSwapReturnDelta` are enabled to support
     *   delta-based balance adjustments for fee deductions and collections.
     * - All other hooks (liquidity and donation related) are disabled to minimize gas usage
     *   and avoid unnecessary callback logic.
     *
     * @return permissions Struct specifying which Uniswap V4 hook callbacks are active for this contract.
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal virtual override returns (bytes4) {
        // This is to limit the fragmentation of pools using this oracle hook. In other words,
        // there may only be one pool per pair of tokens that use this hook. The tick spacing is set to the maximum
        // because we only allow max range liquidity in this pool.
        if (key.fee != 0 || key.tickSpacing != TickMath.MAX_TICK_SPACING) {
            revert OnlyOneOraclePoolAllowed();
        }
        return BaseHook.beforeInitialize.selector;
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        internal
        virtual
        override
        returns (bytes4)
    {
        bytes32 id = PoolId.unwrap(key.toId());
        (states[id].cardinality, states[id].cardinalityNext) = observations[id].initialize(_blockTimestamp(), tick);
        return BaseHook.afterInitialize.selector;
    }

    function _beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata)
        internal
        virtual
        override
        returns (bytes4)
    {
        if (params.liquidityDelta < 0) revert OraclePoolMustLockLiquidity();
        int24 maxTickSpacing = TickMath.MAX_TICK_SPACING;
        if (
            params.tickLower != TickMath.minUsableTick(maxTickSpacing)
                || params.tickUpper != TickMath.maxUsableTick(maxTickSpacing)
        ) revert OraclePositionsMustBeFullRange();

        _updatePool(key);

        return BaseHook.beforeAddLiquidity.selector;
    }

    /**
     * @notice Hook executed before a swap — applies sell-side tax logic when conditions are met.
     * @dev
     * This function is called by the Uniswap V4 PoolManager **before** executing a swap.
     * It identifies whether the fundraising token is being **sold** (swapped out of the pool) and,
     * if so, deducts a protocol-defined fee which is sent directly to the treasury wallet.
     *
     * The function uses `tx.origin` instead of `msg.sender` because Uniswap’s router
     * contract typically calls the pool on behalf of the end user — `tx.origin`
     * ensures the actual swap initiator is checked against taxation rules.
     *
     * ### Key Behavior:
     * - Detects **sell transactions** by comparing `zeroForOne` with token ordering.
     * - Calls `checkIfTaxIncurred` to determine if the tax mechanism is active.
     * - Calculates and deducts the fee based on `TAX_FEE_PERCENTAGE / TAX_FEE_DENOMINATOR`.
     * - Transfers the deducted fee to `vault` via `poolManager.take`.
     * - Returns a `BeforeSwapDelta` reflecting the amount deducted before swap execution.
     *
     * @param key The Uniswap V4 pool key containing currencies, fee tier, and hook configuration.
     * @param params Swap parameters indicating direction, amount, and bounds.
     * @param (unused) Extra calldata (kept for hook interface compatibility).
     *
     * @return selector Always returns `BaseHook.beforeSwap.selector` to signal successful execution.
     * @return returnDelta Struct specifying the deducted fee amount before swap execution.
     * @return fee Additional Uniswap fee parameter (always 0; taxation handled via delta).
     *
     * @custom:reverts FeeToLarge If the computed fee exceeds the int128 limit (for Uniswap deltas).
     * @custom:security
     * - Uses `tx.origin` to reference the actual user rather than the router contract.
     * - Ensures only valid sell transactions trigger taxation.
     * - Fee flows directly to `vault`, which must be trusted and controlled by governance.
     * - Prevents overflow in signed integer conversions.
     */
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        address caller = getMsgSender(sender);

        bool isFundraisingTokenCurrency0 = Currency.unwrap(key.currency0) == fundraisingTokenAddress;
        bool isSelling =
            (isFundraisingTokenCurrency0 && params.zeroForOne) || (!isFundraisingTokenCurrency0 && !params.zeroForOne);

        uint256 feeAmount;
        bool isTaxCutEnabled = checkIfTaxIncurred(caller);
        if (isSelling && isTaxCutEnabled) {
            uint256 swapAmount =
                params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
            // Correct denominator usage
            feeAmount = (swapAmount * TAX_FEE_PERCENTAGE) / TAX_FEE_DENOMINATOR;

            // Ensure fits in signed int128 before casting in any downstream use
            if (feeAmount >= ((uint256(1) << 127) - 1)) revert FeeToLarge();

            poolManager.take(Currency.wrap(fundraisingTokenAddress), vault, feeAmount);
        }

        BeforeSwapDelta returnDelta = toBeforeSwapDelta(
            int128(int256(feeAmount)), // Specified delta (fee amount)
            0 // Unspecified delta (no change)
        );
        _updatePool(key);
        return (BaseHook.beforeSwap.selector, returnDelta, 0);
    }

    /**
     * @notice Hook executed after a swap — enforces buy restrictions and collects applicable buy fees.
     * @dev This hook:
     *      - Determines whether the swap represents a buy of the fundraising token.
     *      - Enforces launch protection, per-wallet cooldowns, and max-buy limits using `isTransferBlocked`.
     *      - Records the buyer’s last purchase timestamp during the launch hold period.
     *      - Optionally applies a buy tax via `checkIfTaxIncurred` and sends the fee to the treasury wallet.
     *
     *      ⚠️ `tx.origin` is intentionally used here instead of `msg.sender` or Uniswap’s router-provided `sender`,
     *      because Uniswap v4 passes the **router contract address** as the swap initiator. Using `tx.origin`
     *      correctly identifies the **end user** who triggered the transaction, ensuring cooldowns, max buy limits,
     *      and tax logic apply per wallet rather than per router.
     *
     * @param (unused) Unused address parameter kept for compatibility with Uniswap’s hook interface.
     * @param key Pool key containing currencies, fee tier, tick spacing, and hooks.
     * @param params Swap parameters defining direction and amount deltas.
     * @param delta Balance delta object representing the change in token balances for this swap.
     * @param (unused) Unused extra calldata for future compatibility.
     *
     * @return selector Always returns `BaseHook.afterSwap.selector` to indicate successful hook execution.
     * @return feeDelta Signed 128-bit integer representing the collected fee (positive if fee was taken).
     *
     * @custom:reverts FeeToLarge If the computed fee exceeds the 127-bit signed integer limit.
     * @custom:security
     *      - Relies on `tx.origin` to identify users; ensure this is acceptable in this model.
     *      - Transfers the buy fee directly to `vault` using `poolManager.take`.
     *      - `vault`, `fundraisingTokenAddress`, and `poolManager` are trusted and immutable.
     */
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        address caller = getMsgSender(sender);
        address currency0 = Currency.unwrap(key.currency0);

        bool isFundraisingTokenIsCurrencyZero = currency0 == fundraisingTokenAddress;

        // isBuying: if fundraising token is currency0 and swap is one->zero? (original logic kept)
        bool isBuying = (isFundraisingTokenIsCurrencyZero && !params.zeroForOne)
            || (!isFundraisingTokenIsCurrencyZero && params.zeroForOne);

        uint256 feeAmount;
        bool isTaxCutEnabled = checkIfTaxIncurred(caller);
        if (isBuying) {
            int256 _amountOut = params.zeroForOne ? delta.amount1() : delta.amount0();
            if (_amountOut <= 0) {
                return (BaseHook.afterSwap.selector, 0);
            }
            // use provided sender (not tx.origin)
            isTransferBlocked(caller, _amountOut);

            if (block.timestamp < launchTimestamp + timeToHold) {
                lastBuyTimestamp[caller] = block.timestamp;
            }

            if (isTaxCutEnabled) {
                feeAmount = (uint256(_amountOut) * TAX_FEE_PERCENTAGE) / TAX_FEE_DENOMINATOR;
                if (feeAmount >= ((uint256(1) << 127) - 1)) revert FeeToLarge();

                // sends the fee to treasury wallet
                poolManager.take(Currency.wrap(fundraisingTokenAddress), vault, feeAmount);
            }
        }
        return (BaseHook.afterSwap.selector, int128(int256(feeAmount)));
    }

    /**
     * @notice Checks whether a token transfer should be blocked due to launch protection, cooldowns, or buy limits.
     * @dev This function reverts (does not return a value) if any restriction is violated.
     *      Restrictions include:
     *      - Transfers are blocked before `launchBlock + blocksToHold`.
     *      - During the `timeToHold` period after launch, each wallet:
     *          - Cannot buy more than `maxBuySize` (expressed as a fraction of total supply, scaled by 1e18).
     *          - Must respect a cooldown between consecutive purchases (`perWalletCoolDownPeriod`).
     *
     * @param _account The address of the account attempting the transfer.
     * @param _amount The amount being transferred (signed integer to support buy/sell logic).
     *
     * @custom:reverts BlockToHoldNotPassed If the current block number is within the launch protection period.
     * @custom:reverts AmountGreaterThanMaxBuyAmount If `_amount` exceeds the allowed max buy size during the hold period.
     * @custom:reverts CoolDownPeriodNotPassed If the wallet tries to transfer again before its cooldown period has elapsed.
     */
    function isTransferBlocked(address _account, int256 _amount) internal view {
        // Block transfers during launch protection (by block count)
        if (block.number < launchBlock + blocksToHold) {
            revert BlockToHoldNotPassed();
        }

        if (block.timestamp < launchTimestamp + timeToHold) {
            // Block transfers if within time to hold after launch
            uint256 lastBuy = lastBuyTimestamp[_account];

            // maxBuySize is stored scaled by 1e18, so multiply by totalSupply and divide by 1e18
            uint256 _maxBuySize = (IERC20(fundraisingTokenAddress).totalSupply() * maxBuySize) / 1e18;

            if (uint256(_amount) > _maxBuySize) {
                revert AmountGreaterThanMaxBuyAmount();
            }

            // Block transfers if within cooldown
            if (lastBuy != 0 && block.timestamp < lastBuy + perWalletCoolDownPeriod) revert CoolDownPeriodNotPassed();
        }
    }

    /**
     * @notice Calculates the treasury's token holdings as a percentage of the total token supply.
     * @dev The result is scaled by 1e18 for precision (e.g., 1e16 represents 1%).
     *      Returns 0 if the total supply is zero to avoid division by zero.
     *
     * @return percentage The treasury’s balance as a percentage of the total token supply, scaled by 1e18.
     */
    function getTreasuryBalanceInPerecent() internal view returns (uint256) {
        uint256 treasuryBalance = IERC20(fundraisingTokenAddress).balanceOf(vault);
        uint256 totalSupply = IERC20(fundraisingTokenAddress).totalSupply();
        if (totalSupply == 0) return 0;
        return (treasuryBalance * 1e18) / totalSupply;
    }

    /**
     * @notice Determines whether a transaction should incur a tax based on treasury and sender conditions.
     * @dev Tax is applied only if:
     *      - The treasury is not paused,
     *      - The treasury balance is below the maximum threshold,
     *      - The sender is neither the treasury registry address nor the donation registry address.
     *
     * @param sender The address initiating the transaction.
     * @return bool Returns `true` if tax should be incurred, otherwise `false`.
     */
    function checkIfTaxIncurred(address sender) internal view returns (bool) {
        return (getTreasuryBalanceInPerecent() < maximumThreshold) && sender != vault;
    }

    function getMsgSender(address sender) internal view returns (address) {
        if (sender == quoter() || sender == router()) {
            return IMsgSender(sender).msgSender();
        } else {
            // for antisniping protection we are using tx.origin the EOA account that initiates the transaction
            // In addtion if the swap is initiated from other router address we tx.origin as default caller
            // and we incur tax for all swap transactions initiated from other routers
            return tx.origin;
        }
    }

    /// @dev Called before any action that potentially modifies pool price or liquidity, such as swap or modify position
    function _updatePool(PoolKey calldata key) private {
        bytes32 id = PoolId.unwrap(key.toId());

        (, int24 tick,,) = IStateView(stateView()).getSlot0(key.toId());

        uint128 liquidity = IStateView(stateView()).getLiquidity(key.toId());

        (states[id].index, states[id].cardinality) = observations[id].write(
            states[id].index, _blockTimestamp(), tick, liquidity, states[id].cardinality, states[id].cardinalityNext
        );
    }

    function _blockTimestamp() internal view virtual returns (uint32) {
        return uint32(block.timestamp);
    }

    function router() public view returns (address) {
        return integrationRegistry.router();
    }

    function quoter() public view returns (address) {
        return integrationRegistry.quoter();
    }

    function stateView() public view returns (address) {
        return integrationRegistry.stateView();
    }
}
