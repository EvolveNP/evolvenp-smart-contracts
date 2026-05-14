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
import {IFactory} from "./interfaces/IFactory.sol";
import {IEmergencyManager} from "./interfaces/IEmergencyManager.sol";

/**
 * @title FundraisingTokenHook
 * @notice Global Uniswap v4 hook for all factory-created fundraising-token/USDC pools.
 * @dev The hook resolves the fundraising token and target vault from Factory on each callback. It authorizes only
 * factory-approved pools, records oracle observations, applies launch buy protections, and routes buy/sell tax to
 * the vault for the specific fundraising token. Tax is skipped while EmergencyManager reports active emergency mode.
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
    error InvalidPool();

    /// @notice Oracle pools do not have fees because they exist to serve as an oracle for a pair of tokens
    error OnlyOneOraclePoolAllowed();

    /// @notice Oracle positions must be full range
    error OraclePositionsMustBeFullRange();

    /// @notice Oracle pools must have liquidity locked so that they cannot become more susceptible to price manipulation
    error OraclePoolMustLockLiquidity();

    uint256 internal constant perWalletCoolDownPeriod = 1 minutes;
    uint256 internal constant maxBuySize = 333e13; // 0.333% of total supply (scaled by 1e18)
    uint256 internal constant blocksToHold = 10; // Number of blocks after launch during which transfers are restricted
    uint256 internal constant timeToHold = 1 hours; // Number of seconds after launch during which special hold rules apply

    address public immutable factoryAddress; // The factory used to resolve fundraising token protocol context
    address public immutable usdcAddress; // The shared underlying asset for fundraising pools
    IIntegrationRegistry public immutable integrationRegistry; // current integration endpoints source
    uint256 public constant maximumThreshold = 30e16; // The maximum threshold for the liquidity pool 30% = 30e16
    mapping(address => uint256) public launchTimestampByToken; // fundraising token => launch timestamp
    mapping(address => uint256) public launchBlockByToken; // fundraising token => launch block
    mapping(address => mapping(address => uint256)) public lastBuyTimestamp; // fundraising token => account => timestamp

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
     * @notice Deploys the global fundraising hook.
     * @param _poolManager The address of the Uniswap V4 PoolManager contract.
     * @param _factoryAddress Factory used to resolve protocol records and authorized pools.
     * @param _usdcAddress Shared USDC token used by all fundraising pools.
     * @param _integrationRegistry Registry used to resolve mutable peripheral endpoints.
     */
    constructor(address _poolManager, address _factoryAddress, address _usdcAddress, address _integrationRegistry)
        BaseHook(IPoolManager(_poolManager))
    {
        factoryAddress = _factoryAddress;
        usdcAddress = _usdcAddress;
        integrationRegistry = IIntegrationRegistry(_integrationRegistry);
    }

    /**
     * @notice Returns oracle cumulative values for a pool.
     * @param key Pool key whose observations are read.
     * @param secondsAgos Lookback offsets used by the truncated oracle.
     * @return tickCumulatives Tick cumulative values at the requested lookbacks.
     * @return secondsPerLiquidityCumulativeX128s Seconds-per-liquidity cumulative values.
     */
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

    /**
     * @notice Returns the current tick for a pool from StateView.
     * @param key Pool key to inspect.
     */
    function getCurrentTick(PoolKey calldata key) public view returns (int24) {
        (, int24 tick,,) = IStateView(stateView()).getSlot0(key.toId());
        return tick;
    }

    /**
     * @notice Defines the hook permissions required by this contract for Uniswap V4 integration.
     * @return permissions Enabled callbacks and return-delta flags required by this hook.
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

    /**
     * @notice Validates pool initialization before Uniswap creates the pool.
     * @param key Pool key being initialized.
     * @return Hook selector expected by PoolManager.
     * @dev Allows only zero-fee, max tick-spacing, factory-authorized fundraising-token/USDC pools.
     */
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal virtual override returns (bytes4) {
        if (key.fee != 0 || key.tickSpacing != TickMath.MAX_TICK_SPACING) {
            revert OnlyOneOraclePoolAllowed();
        }

        (address fundraisingTokenAddress,) = _getFundraisingContext(key);

        if (!IFactory(factoryAddress).isAuthorizedHookPool(fundraisingTokenAddress, key, address(this))) {
            revert InvalidPool();
        }
        return BaseHook.beforeInitialize.selector;
    }

    /**
     * @notice Initializes launch metadata and the oracle observation buffer for a newly created pool.
     * @param key Pool key that was initialized.
     * @param tick Initial pool tick.
     * @return Hook selector expected by PoolManager.
     */
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        internal
        virtual
        override
        returns (bytes4)
    {
        bytes32 id = PoolId.unwrap(key.toId());
        (address fundraisingTokenAddress,) = _getFundraisingContext(key);

        launchTimestampByToken[fundraisingTokenAddress] = block.timestamp;

        launchBlockByToken[fundraisingTokenAddress] = block.number;

        (states[id].cardinality, states[id].cardinalityNext) = observations[id].initialize(_blockTimestamp(), tick);

        return BaseHook.afterInitialize.selector;
    }

    /**
     * @notice Validates liquidity additions and updates the oracle observation.
     * @param key Pool receiving liquidity.
     * @param params Liquidity modification parameters.
     * @return Hook selector expected by PoolManager.
     * @dev Only full-range positive liquidity additions are accepted.
     */
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
     * @notice Hook executed before a swap — applies sell-side tax logic for exact-input sells.
     * @dev Exact-output sells are taxed in `_afterSwap`, where the actual fundraising-token input is known.
     * The function also writes a fresh oracle observation before returning.
     * @param sender PoolManager-provided swap sender.
     * @param key The Uniswap V4 pool key containing currencies, fee tier, and hook configuration.
     * @param params Swap parameters indicating direction, amount, and bounds.
     * @return selector Always returns `BaseHook.beforeSwap.selector` to signal successful execution.
     * @return returnDelta Before-swap delta charging exact-input sell tax in the specified currency.
     * @return fee Additional LP fee override, always zero.
     */
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        address caller = getMsgSender(sender);
        (address fundraisingTokenAddress, address vault) = _getFundraisingContext(key);

        bool isFundraisingTokenCurrency0 = Currency.unwrap(key.currency0) == fundraisingTokenAddress;
        bool isSelling =
            (isFundraisingTokenCurrency0 && params.zeroForOne) || (!isFundraisingTokenCurrency0 && !params.zeroForOne);

        uint256 feeAmount;
        bool isTaxCutEnabled = checkIfTaxIncurred(key, caller);
        if (isSelling && isTaxCutEnabled && params.amountSpecified < 0) {
            uint256 swapAmount = uint256(-params.amountSpecified);
            feeAmount = (swapAmount * TAX_FEE_PERCENTAGE) / TAX_FEE_DENOMINATOR;

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
     * @notice Hook executed after a swap — enforces buy restrictions and collects applicable swap fees.
     * @param sender PoolManager-provided swap sender.
     * @param key Pool key containing currencies, fee tier, tick spacing, and hooks.
     * @param params Swap parameters defining direction and amount deltas.
     * @param delta Balance delta object representing the change in token balances for this swap.
     * @return selector Always returns `BaseHook.afterSwap.selector` to indicate successful hook execution.
     * @return feeDelta Hook delta for collected buy or exact-output sell tax.
     * @dev Buy tax is based on actual fundraising-token output. Exact-output sell tax is based on actual
     * fundraising-token input consumed by the swap.
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
        (address fundraisingTokenAddress, address vault) = _getFundraisingContext(key);

        bool isFundraisingTokenIsCurrencyZero = currency0 == fundraisingTokenAddress;
        bool isBuying = (isFundraisingTokenIsCurrencyZero && !params.zeroForOne)
            || (!isFundraisingTokenIsCurrencyZero && params.zeroForOne);
        bool isSelling = (isFundraisingTokenIsCurrencyZero && params.zeroForOne)
            || (!isFundraisingTokenIsCurrencyZero && !params.zeroForOne);

        uint256 feeAmount;
        bool isTaxCutEnabled = checkIfTaxIncurred(key, caller);
        if (isBuying) {
            int256 _amountOut = params.zeroForOne ? delta.amount1() : delta.amount0();
            if (_amountOut <= 0) {
                return (BaseHook.afterSwap.selector, 0);
            }
            // use provided sender (not tx.origin)
            isTransferBlocked(fundraisingTokenAddress, caller, _amountOut);

            if (block.timestamp < launchTimestampByToken[fundraisingTokenAddress] + timeToHold) {
                lastBuyTimestamp[fundraisingTokenAddress][caller] = block.timestamp;
            }

            if (isTaxCutEnabled) {
                feeAmount = (uint256(_amountOut) * TAX_FEE_PERCENTAGE) / TAX_FEE_DENOMINATOR;
                if (feeAmount >= ((uint256(1) << 127) - 1)) revert FeeToLarge();
                poolManager.take(Currency.wrap(fundraisingTokenAddress), vault, feeAmount);
            }
        } else if (isSelling && isTaxCutEnabled && params.amountSpecified > 0) {
            int256 fundraisingTokenDelta = isFundraisingTokenIsCurrencyZero ? delta.amount0() : delta.amount1();
            if (fundraisingTokenDelta >= 0) {
                return (BaseHook.afterSwap.selector, 0);
            }

            uint256 actualInputUsed = uint256(-fundraisingTokenDelta);
            feeAmount = (actualInputUsed * TAX_FEE_PERCENTAGE) / TAX_FEE_DENOMINATOR;
            if (feeAmount >= ((uint256(1) << 127) - 1)) revert FeeToLarge();

            poolManager.take(Currency.wrap(fundraisingTokenAddress), vault, feeAmount);
        }
        return (BaseHook.afterSwap.selector, int128(int256(feeAmount)));
    }

    /**
     * @notice Checks whether a token transfer should be blocked due to launch protection, cooldowns, or buy limits.
     * @param fundraisingTokenAddress Fundraising token being bought.
     * @param _account The address of the account attempting the transfer.
     * @param _amount Fundraising token amount received by the account.
     * @dev Reverts while block-based protection is active, when amount exceeds max-buy size during the hold window,
     * or when the account is still inside its cooldown period.
     */
    function isTransferBlocked(address fundraisingTokenAddress, address _account, int256 _amount) internal view {
        // Block transfers during launch protection (by block count)
        if (block.number < launchBlockByToken[fundraisingTokenAddress] + blocksToHold) {
            revert BlockToHoldNotPassed();
        }

        if (block.timestamp < launchTimestampByToken[fundraisingTokenAddress] + timeToHold) {
            // Block transfers if within time to hold after launch
            uint256 lastBuy = lastBuyTimestamp[fundraisingTokenAddress][_account];

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
     * @notice Calculates the vault's fundraising token balance as a percentage of total supply.
     * @param key Pool key used to resolve the fundraising token and vault.
     * @return percentage Vault balance percentage scaled by 1e18.
     */
    function getTreasuryBalanceInPerecent(PoolKey calldata key) internal view returns (uint256) {
        (address fundraisingTokenAddress, address vault) = _getFundraisingContext(key);
        uint256 treasuryBalance = IERC20(fundraisingTokenAddress).balanceOf(vault);
        uint256 totalSupply = IERC20(fundraisingTokenAddress).totalSupply();
        if (totalSupply == 0) return 0;
        return (treasuryBalance * 1e18) / totalSupply;
    }

    /**
     * @notice Determines whether a swap should route tax to the protocol vault.
     * @param key Pool key used to resolve protocol context.
     * @param sender The address initiating the transaction.
     * @return True when emergency is inactive, the vault balance is below threshold, and sender is not the vault.
     */
    function checkIfTaxIncurred(PoolKey calldata key, address sender) internal view returns (bool) {
        (, address vault) = _getFundraisingContext(key);
        if (IEmergencyManager(integrationRegistry.emergencyManager()).isEmergencyActive()) {
            return false;
        }
        return (getTreasuryBalanceInPerecent(key) < maximumThreshold) && sender != vault;
    }

    /**
     * @notice Resolves the effective user address for router and quoter initiated swaps.
     * @param sender PoolManager-provided sender.
     * @return Effective account used for tax and launch-protection checks.
     */
    function getMsgSender(address sender) internal view returns (address) {
        if (sender == quoter()) {
            return IMsgSender(sender).msgSender();
        }
        if (sender == router()) {
            return IMsgSender(sender).msgSender();
        }
        // for antisniping protection we are using tx.origin the EOA account that initiates the transaction
        // In addtion if the swap is initiated from other router address we tx.origin as default caller
        // and we incur tax for all swap transactions initiated from other routers
        return tx.origin;
    }

    /**
     * @notice Writes a new oracle observation for the pool.
     * @param key Pool key whose current tick and liquidity are sampled.
     */
    function _updatePool(PoolKey calldata key) private {
        bytes32 id = PoolId.unwrap(key.toId());

        (, int24 tick,,) = IStateView(stateView()).getSlot0(key.toId());

        uint128 liquidity = IStateView(stateView()).getLiquidity(key.toId());

        (states[id].index, states[id].cardinality) = observations[id].write(
            states[id].index, _blockTimestamp(), tick, liquidity, states[id].cardinality, states[id].cardinalityNext
        );
    }

    /**
     * @notice Returns the current block timestamp truncated to 32 bits for oracle storage.
     */
    function _blockTimestamp() internal view virtual returns (uint32) {
        return uint32(block.timestamp);
    }

    /**
     * @notice Returns the current router endpoint from IntegrationRegistry.
     */
    function router() public view returns (address) {
        return integrationRegistry.router();
    }

    /**
     * @notice Returns the current quoter endpoint from IntegrationRegistry.
     */
    function quoter() public view returns (address) {
        return integrationRegistry.quoter();
    }

    /**
     * @notice Returns the current StateView endpoint from IntegrationRegistry.
     */
    function stateView() public view returns (address) {
        return integrationRegistry.stateView();
    }

    /**
     * @notice Resolves fundraising token and vault for a pool key.
     * @param key Pool key expected to contain USDC and a factory-created fundraising token.
     * @return fundraisingTokenAddress Fundraising token identified from the pool pair.
     * @return vault Vault that receives tax for the fundraising token.
     * @dev Reverts unless the pool is USDC paired, registered in Factory, and authorized for this hook.
     */
    function _getFundraisingContext(PoolKey calldata key)
        internal
        view
        returns (address fundraisingTokenAddress, address vault)
    {
        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);

        if (currency0 == usdcAddress && currency1 != address(0)) {
            fundraisingTokenAddress = currency1;
        } else if (currency1 == usdcAddress && currency0 != address(0)) {
            fundraisingTokenAddress = currency0;
        } else {
            revert InvalidPool();
        }

        IFactory.FundraisingProtocol memory protocol = IFactory(factoryAddress).getProtocol(fundraisingTokenAddress);
        if (protocol.fundraisingToken != fundraisingTokenAddress || protocol.vault == address(0)) revert InvalidPool();
        if (!IFactory(factoryAddress).isAuthorizedHookPool(fundraisingTokenAddress, key, address(this))) {
            revert InvalidPool();
        }

        vault = protocol.vault;
    }
}
