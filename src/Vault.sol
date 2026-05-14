// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IEmergencyManager} from "./interfaces/IEmergencyManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Swap} from "./abstracts/Swap.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IFactory} from "./interfaces/IFactory.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IHook} from "./interfaces/IHook.sol";
import {IIntegrationRegistry} from "./interfaces/IIntegrationRegistry.sol";

/**
 * @title Vault
 * @notice Holds protocol token allocations and periodically sells fundraising tokens for USDC beneficiaries.
 * @dev The factory configures the fundraising token and shared hook after deployment. Monthly execution checks
 * emergency state, timing, token balance, pool configuration, and hook oracle safety before swapping a configured
 * percentage of fundraising tokens to USDC and splitting proceeds across beneficiaries.
 */
contract Vault is Swap {
    using SafeERC20 for IERC20;
    /**
     * Errors
     */
    error EmegerncyIsActive();
    error InvalidInterval();
    error InvalidSwapPercentage();
    error NotDue();
    error InsufficientBalance();
    error UnsafePrice();
    error TransferFailed();
    error NotFactory();
    error OnlySelf();
    error NoBeneficiaries();
    error ZeroBeneficiary();
    error DuplicateBeneficiary();
    error ZeroSwapAmount();
    error SellCheckFailed();
    error QuoteFailed();
    error SwapFailed();
    error FundraisingTokenNotConfigured();
    error HookNotConfigured();
    error PoolNotConfigured();

    address public fundraisingToken; // The address of the fundraising token
    address public immutable underlyingAsset; // The address of the underlying asset
    uint256 public immutable intervalSeconds;
    uint256 public lastSuccessAt; // Timestamp of the last successful operation
    address[] public beneficiaries;
    uint256 public swapPercentage; // The percentage of the swap in 18 decimals (e.g., 500000000000000000 for 50%)
    address public emergencyManager; // The address of the emergency manager contract
    uint256 public immutable minTokenBalanceToExecute; //
    address public immutable factoryAddress;
    address public hookAddress;
    uint32 public constant oracleObservationInterval = 1800; // Oracle observation interval in seconds -> 30 mins
    int24 public constant maxTickDeviation = 198; // Maximum tick deviation for swaps 2%

    /**
     * @notice Emitted when USDC proceeds are sent to a beneficiary.
     * @param recipient Beneficiary receiving funds.
     * @param amount USDC amount transferred.
     */
    event FundsTransferredToNonProfit(address recipient, uint256 amount);

    /**
     * @notice Emitted when monthly execution records a recoverable integration failure and exits without reverting.
     * @param reason Selector identifying the failed step.
     */
    event MonthlyExecutionFailed(bytes4 reason);

    /**
     * @notice Restricts configuration functions to the factory that deployed the vault.
     */
    modifier onlyFactory() {
        if (msg.sender != factoryAddress) revert NotFactory();
        _;
    }

    /**
     * @notice Restricts helper functions to external self-calls used for try/catch failure recording.
     */
    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelf();
        _;
    }

    /**
     * @notice Deploys a vault for one fundraising protocol.
     * @param _underlyingAsset USDC token distributed to beneficiaries.
     * @param _intervalSeconds Minimum delay between successful monthly executions.
     * @param _beneficiaries Recipients of swapped USDC proceeds.
     * @param _swapPercentage Percentage of fundraising token balance to swap per execution, scaled by 1e18.
     * @param _integrationRegistry Registry used by the inherited swap helper.
     * @param _emergencyManager EmergencyManager used to block execution and record failures.
     * @param _minTokenBalanceToExecute Minimum fundraising token balance required before execution.
     * @param _factoryAddress Factory allowed to configure the fundraising token and hook.
     */
    constructor(
        address _underlyingAsset,
        uint256 _intervalSeconds,
        address[] memory _beneficiaries,
        uint256 _swapPercentage,
        address _integrationRegistry,
        address _emergencyManager,
        uint256 _minTokenBalanceToExecute,
        address _factoryAddress
    )
        Swap(_integrationRegistry)
        nonZeroAddress(_underlyingAsset)
        nonZeroAddress(_emergencyManager)
        nonZeroAddress(_factoryAddress)
    {
        if (_intervalSeconds == 0) revert InvalidInterval();
        if (_swapPercentage == 0 || _swapPercentage > 1e18) revert InvalidSwapPercentage();
        _validateBeneficiaries(_beneficiaries);
        underlyingAsset = _underlyingAsset;
        intervalSeconds = _intervalSeconds;
        beneficiaries = _beneficiaries;
        swapPercentage = _swapPercentage;
        emergencyManager = _emergencyManager;
        minTokenBalanceToExecute = _minTokenBalanceToExecute;
        factoryAddress = _factoryAddress;
        lastSuccessAt = block.timestamp;
    }

    /**
     * @notice Executes the scheduled fundraising-token sale and USDC beneficiary distribution.
     * @dev Reverts for hard precondition failures. Quote, swap, and state-view failures are recorded in
     * EmergencyManager and emitted as `MonthlyExecutionFailed` without reverting so counters persist.
     */
    function executeMonthlyEvent() external {
        IEmergencyManager manager = IEmergencyManager(emergencyManager);

        if (manager.isEmergencyActive()) revert EmegerncyIsActive();
        if (fundraisingToken == address(0)) revert FundraisingTokenNotConfigured();
        if (block.timestamp < lastSuccessAt + intervalSeconds) revert NotDue();
        if (IERC20(fundraisingToken).balanceOf(address(this)) < minTokenBalanceToExecute) revert InsufficientBalance();
        if (hookAddress == address(0)) revert HookNotConfigured();
        _getPoolKey();
        bool shouldSell;
        try this.checkShouldAllowSell() returns (bool allowed) {
            shouldSell = allowed;
        } catch {
            _tryRecordEndpointFailure(manager);
            emit MonthlyExecutionFailed(SellCheckFailed.selector);
            return;
        }
        if (!shouldSell) revert UnsafePrice();

        uint256 amountIn = _getSwapAmountIn();
        uint256 minAmountOut;
        try this.quoteFundraisingTokenSwap(uint128(amountIn)) returns (uint256 quotedMinAmountOut) {
            minAmountOut = quotedMinAmountOut;
            manager.recordQuoteSuccess();
        } catch {
            manager.recordQuoteFailure();
            emit MonthlyExecutionFailed(QuoteFailed.selector);
            return;
        }

        uint256 amountOut;
        try this.swapFundraisingToken(uint128(amountIn), uint128(minAmountOut)) returns (uint256 swappedAmountOut) {
            amountOut = swappedAmountOut;
            manager.recordSwapSuccess();
        } catch {
            manager.recordSwapFailure();
            emit MonthlyExecutionFailed(SwapFailed.selector);
            return;
        }

        _finalizeSuccessfulExecution(amountOut);
    }

    /**
     * @notice Returns whether this vault currently satisfies the basic execution conditions.
     * @dev Checks time, emergency state, and fundraising token balance. Pool and oracle safety are checked in execution.
     */
    function isDue() external view returns (bool) {
        if (
            block.timestamp >= lastSuccessAt + intervalSeconds
                && !IEmergencyManager(emergencyManager).isEmergencyActive()
                && IERC20(fundraisingToken).balanceOf(address(this)) >= minTokenBalanceToExecute
        ) return true;
        return false;
    }

    /**
     * @notice Quotes the fundraising-token to USDC swap and applies slippage tolerance.
     * @param amountIn Fundraising token amount to quote.
     * @return minAmountOut Minimum acceptable USDC output after slippage.
     * @dev External self-call target so `executeMonthlyEvent` can catch quote failures.
     */
    function quoteFundraisingTokenSwap(uint128 amountIn) external onlySelf returns (uint256 minAmountOut) {
        (PoolKey memory key, bool isCurrency0FundraisingToken) = _getPoolKey();
        minAmountOut = getMinAmountOut(key, isCurrency0FundraisingToken, amountIn, bytes(""));
    }

    /**
     * @notice Swaps fundraising tokens held by the vault for USDC.
     * @param amountIn Fundraising token amount to sell.
     * @param minAmountOut Minimum acceptable USDC output.
     * @return amountOut Actual USDC received by the vault.
     * @dev External self-call target so `executeMonthlyEvent` can catch swap failures.
     */
    function swapFundraisingToken(uint128 amountIn, uint128 minAmountOut)
        external
        onlySelf
        returns (uint256 amountOut)
    {
        (PoolKey memory key, bool isCurrency0FundraisingToken) = _getPoolKey();
        amountOut = swapExactInputSingle(key, amountIn, minAmountOut, isCurrency0FundraisingToken);
    }

    /**
     * @notice Calculates the fundraising token amount to sell this execution.
     * @return amountIn Token amount based on current vault balance and configured percentage.
     */
    function _getSwapAmountIn() internal view returns (uint256 amountIn) {
        uint256 tokenBalance = IERC20(fundraisingToken).balanceOf(address(this));
        amountIn = (tokenBalance * swapPercentage) / 1e18;
        if (amountIn == 0) revert ZeroSwapAmount();
    }

    /**
     * @notice External self-call wrapper around `shouldAllowSell`.
     * @return True if the hook oracle price check allows the vault to sell.
     */
    function checkShouldAllowSell() external view onlySelf returns (bool) {
        return shouldAllowSell();
    }

    /**
     * @notice Checks whether the current pool price is within the allowed TWAP deviation.
     * @return True when the current tick is not too far from the 30-minute average tick.
     * @dev Uses the shared hook oracle observations for the canonical fundraising-token/USDC pool.
     */
    function shouldAllowSell() public view returns (bool) {
        if (hookAddress == address(0)) revert HookNotConfigured();
        IHook hook = IHook(hookAddress);
        (PoolKey memory key, bool fundraisingIsToken0) = _getPoolKey();

        uint32 interval = oracleObservationInterval;

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = interval;
        secondsAgos[1] = 0;

        (int48[] memory tickCumulatives,) = hook.observe(key, secondsAgos);

        int56 tickDelta = int56(tickCumulatives[1]) - int56(tickCumulatives[0]);

        int24 avgTick = int24(tickDelta / int56(uint56(interval)));

        int24 currentTick = hook.getCurrentTick(key);

        if (fundraisingIsToken0) return avgTick - currentTick <= maxTickDeviation;
        return currentTick - avgTick <= maxTickDeviation;
    }

    /**
     * @notice Splits received USDC proceeds across configured beneficiaries.
     * @param amountOut Total USDC amount received by the vault.
     * @dev Remainder dust is added to the last beneficiary.
     */
    function _distributeProceeds(uint256 amountOut) internal {
        uint256 beneficiaryCount = beneficiaries.length;
        if (beneficiaryCount == 0) revert NoBeneficiaries();

        uint256 amountPerBeneficiary = amountOut / beneficiaryCount;
        uint256 remainder = amountOut % beneficiaryCount;

        for (uint256 i; i < beneficiaryCount; ++i) {
            uint256 payout = amountPerBeneficiary;
            if (i == beneficiaryCount - 1) {
                payout += remainder;
            }
            // Only USDC supproted
            IERC20(underlyingAsset).safeTransfer(beneficiaries[i], payout);

            emit FundsTransferredToNonProfit(beneficiaries[i], payout);
        }
    }

    /**
     * @notice Sets the shared hook address after successful pool creation.
     * @param _hookAddress Hook address stored in IntegrationRegistry and used by the canonical pool.
     */
    function setHookAddress(address _hookAddress) external onlyFactory {
        hookAddress = _hookAddress;
    }

    /**
     * @notice Sets the fundraising token controlled by this vault.
     * @param _fundraisingToken Fundraising token deployed by the factory.
     */
    function setFundraisingToken(address _fundraisingToken) external onlyFactory {
        fundraisingToken = _fundraisingToken;
    }

    /**
     * @notice Best-effort endpoint failure report for state-view / hook oracle failures.
     * @param manager EmergencyManager receiving the failure report.
     */
    function _tryRecordEndpointFailure(IEmergencyManager manager) internal {
        try manager.recordEndpointFailure(uint8(IIntegrationRegistry.Endpoint.STATE_VIEW)) {} catch {}
    }

    /**
     * @notice Completes successful execution by distributing proceeds and updating `lastSuccessAt`.
     * @param amountOut USDC amount received from the swap.
     */
    function _finalizeSuccessfulExecution(uint256 amountOut) internal {
        _distributeProceeds(amountOut);
        lastSuccessAt = block.timestamp;
    }

    /**
     * @notice Validates the beneficiary list used for USDC distributions.
     * @param _beneficiaries Beneficiary list supplied at deployment.
     * @dev Rejects empty lists, zero addresses, and duplicates.
     */
    function _validateBeneficiaries(address[] memory _beneficiaries) internal pure {
        uint256 beneficiaryCount = _beneficiaries.length;
        if (beneficiaryCount == 0) revert NoBeneficiaries();

        for (uint256 i; i < beneficiaryCount; ++i) {
            address beneficiary = _beneficiaries[i];
            if (beneficiary == address(0)) revert ZeroBeneficiary();

            for (uint256 j = i + 1; j < beneficiaryCount; ++j) {
                if (beneficiary == _beneficiaries[j]) revert DuplicateBeneficiary();
            }
        }
    }

    /**
     * @notice Loads and validates the canonical pool key for this vault's fundraising token.
     * @return key Pool key stored in the factory.
     * @return isCurrency0FundraisingToken True when the fundraising token is currency0 in the pool.
     */
    function _getPoolKey() internal view returns (PoolKey memory key, bool isCurrency0FundraisingToken) {
        key = IFactory(factoryAddress).getPoolKeys(fundraisingToken);
        bool isCurrency0 = Currency.unwrap(key.currency0) == fundraisingToken;
        bool isCurrency1 = Currency.unwrap(key.currency1) == fundraisingToken;
        bool hasUnderlyingAsCurrency0 = Currency.unwrap(key.currency0) == underlyingAsset;
        bool hasUnderlyingAsCurrency1 = Currency.unwrap(key.currency1) == underlyingAsset;
        bool isExpectedPair = (isCurrency0 && hasUnderlyingAsCurrency1) || (isCurrency1 && hasUnderlyingAsCurrency0);
        if (!isExpectedPair) revert PoolNotConfigured();
        return (key, isCurrency0);
    }
}
