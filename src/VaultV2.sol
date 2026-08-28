// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {Swap} from "./abstracts/Swap.sol";
import {IFactory} from "./interfaces/IFactory.sol";
import {IHook} from "./interfaces/IHook.sol";
import {IIntegrationRegistry} from "./interfaces/IIntegrationRegistry.sol";
import {IEmergencyManager} from "./interfaces/IEmergencyManager.sol";
import {IVRFCoordinatorV2} from "./interfaces/IVRFCoordinatorV2Plus.sol";

/**
 * @title VaultV2
 * @notice Executes two randomized monthly donation events from fundraising-token reserves to nonprofit beneficiaries.
 * @dev
 * Step-by-step lifecycle:
 * 1. Anyone calls {startDonationWindow} after the monthly interval has elapsed.
 * 2. The Vault snapshots its fundraising-token balance and requests Chainlink VRF for the first event.
 * 3. Chainlink calls {rawFulfillRandomWords}; the Vault maps the random word to one slot in the event range.
 * 4. If the selected slot is the current slot, the callback executes the donation immediately.
 * 5. If the selected slot is not current, the Vault advances to the next eligible slot without publishing a timestamp.
 * 6. The final slot in each range executes as a fallback so a valid monthly event cannot be skipped forever.
 * 7. Each successful execution swaps exactly 1% of the opening snapshot balance and distributes USDC to beneficiaries.
 * 8. If safety/integration checks fail, the event is not consumed and a new VRF request may be made later.
 *
 * No future event timestamp is stored. Randomness is requested sequentially per eligible slot, and execution happens
 * during the VRF callback only when the random slot selection matches the requested slot.
 */
contract VaultV2 is Swap {
    using SafeERC20 for IERC20;

    /// @notice Fixed length of the randomized monthly event-selection window.
    uint256 public constant DONATION_WINDOW = 30 days;
    /// @notice Number of donation tranches required per window.
    uint8 public constant EVENTS_PER_WINDOW = 2;
    /// @notice Each tranche swaps 1% of the Vault balance snapshotted at window start.
    uint256 public constant TRANCHE_PERCENTAGE = 1e16;
    /// @notice Percentage denominator used by {TRANCHE_PERCENTAGE}.
    uint256 public constant PERCENTAGE_DENOMINATOR = 1e18;
    /// @notice Oracle observation interval used by the TWAP sell-safety check.
    uint32 public constant oracleObservationInterval = 1800;
    /// @notice Maximum allowed tick deviation between current price and TWAP.
    int24 public constant maxTickDeviation = 198;

    error EmegerncyIsActive();
    error InvalidInterval();
    error InvalidVrfConfig();
    error NotDue();
    error InsufficientBalance();
    error UnsafePrice();
    error NotFactory();
    error OnlySelf();
    error OnlyCoordinator();
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
    error WindowAlreadyActive();
    error WindowNotActive();
    error EventNotEligible();
    error WindowComplete();
    error UnknownRequest();
    error RandomnessPending();
    error InvalidUpkeepAction();
    error InvalidSlotConfig();

    /// @notice Chainlink Automation action marker for starting a new donation window.
    uint8 internal constant UPKEEP_START_WINDOW = 1;
    /// @notice Chainlink Automation action marker for requesting the next hidden-timing donation event.
    uint8 internal constant UPKEEP_REQUEST_DONATION_EVENT = 2;

    /// @notice Chainlink VRF configuration used to request donation-window randomness.
    struct VrfConfig {
        address coordinator;
        bytes32 keyHash;
        uint64 subscriptionId;
        uint16 requestConfirmations;
        uint32 callbackGasLimit;
    }

    /// @notice Configurable slot ranges used by sequential VRF donation selection.
    struct SlotConfig {
        uint8 slotsPerWindow;
        uint8 firstEventStartSlot;
        uint8 firstEventEndSlot;
        uint8 secondEventStartSlot;
        uint8 secondEventEndSlot;
    }

    /// @notice Donation-window state for the active or most recently completed cycle.
    struct DonationWindow {
        uint64 cycleId;
        uint64 startsAt;
        uint64 endsAt;
        uint64 lastRequestAt;
        uint64 lastEventAt;
        uint128 snapshotBalance;
        uint8 eventsExecuted;
        uint8 nextSlotToRequest;
        bool randomnessPending;
    }

    /// @notice Pending VRF request metadata for one donation attempt.
    struct DonationRequest {
        uint64 cycleId;
        uint8 eventIndex;
        uint8 slotIndex;
    }

    address public fundraisingToken;
    address public immutable underlyingAsset;
    address public immutable emergencyManager;
    address public immutable factoryAddress;
    address public immutable vrfCoordinator;
    bytes32 public immutable vrfKeyHash;
    uint64 public immutable vrfSubscriptionId;
    uint16 public immutable vrfRequestConfirmations;
    uint32 public immutable vrfCallbackGasLimit;
    uint256 public immutable intervalSeconds;
    uint256 public immutable minTokenBalanceToExecute;
    uint8 public immutable slotsPerWindow;
    uint8 public immutable firstEventStartSlot;
    uint8 public immutable firstEventEndSlot;
    uint8 public immutable secondEventStartSlot;
    uint8 public immutable secondEventEndSlot;

    uint256 public lastSuccessAt;
    address public hookAddress;
    address[] public beneficiaries;
    DonationWindow public donationWindow;

    mapping(uint256 => DonationRequest) public requestById;

    /**
     * @notice Emitted when a donation window starts and the first hidden-timing VRF request is sent.
     * @param cycleId Monthly donation cycle id.
     * @param requestId Chainlink VRF request id.
     * @param startsAt Start timestamp of the 7-day window.
     * @param endsAt End timestamp of the 7-day window.
     * @param snapshotBalance Fundraising-token balance used to size both 1% tranches.
     */
    event DonationWindowStarted(
        uint64 indexed cycleId, uint256 indexed requestId, uint64 startsAt, uint64 endsAt, uint128 snapshotBalance
    );

    /**
     * @notice Emitted when a hidden-timing donation attempt is requested from Chainlink VRF.
     * @param cycleId Monthly donation cycle id.
     * @param eventIndex One-based tranche index being requested.
     * @param requestId Chainlink VRF request id.
     * @param requestedAt Timestamp at which the VRF request was made.
     */
    event DonationEventRandomnessRequested(
        uint64 indexed cycleId, uint8 indexed eventIndex, uint256 indexed requestId, uint64 requestedAt
    );

    /**
     * @notice Emitted when VRF schedules the next permissionless donation execution time.
     * @param cycleId Monthly donation cycle id.
     * @param eventIndex One-based tranche index scheduled for execution.
     * @param selectedSlot Slot selected by VRF inside the event range.
     * @param requestedSlot Slot for which the VRF request was made.
     * @param executed True when the donation executed during this callback.
     */
    event DonationSlotEvaluated(
        uint64 indexed cycleId, uint8 indexed eventIndex, uint8 selectedSlot, uint8 requestedSlot, bool executed
    );

    /**
     * @notice Emitted after a successful tranche swap and distribution.
     * @param cycleId Monthly donation cycle id.
     * @param eventIndex One-based tranche index, either 1 or 2.
     * @param amountIn Fundraising-token amount swapped.
     * @param amountOut USDC amount distributed to beneficiaries.
     */
    event DonationEventExecuted(uint64 indexed cycleId, uint8 indexed eventIndex, uint256 amountIn, uint256 amountOut);

    /**
     * @notice Emitted when USDC proceeds are transferred to a nonprofit beneficiary.
     * @param recipient Beneficiary receiving USDC.
     * @param amount USDC amount transferred.
     */
    event FundsTransferredToNonProfit(address recipient, uint256 amount);

    /**
     * @notice Emitted when a selected donation event attempt fails without consuming the tranche.
     * @param reason Selector describing the failed safety or integration step.
     */
    event DonationExecutionFailed(bytes4 reason);

    modifier onlyFactory() {
        if (msg.sender != factoryAddress) revert NotFactory();
        _;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelf();
        _;
    }

    /**
     * @notice Deploys a VaultV2 with immutable donation-window and Chainlink VRF configuration.
     * @param _underlyingAsset USDC token distributed to beneficiaries.
     * @param _intervalSeconds Minimum time between monthly donation windows.
     * @param _beneficiaries Nonprofit beneficiary addresses.
     * @param _integrationRegistry Registry used by Swap for Uniswap endpoints.
     * @param _emergencyManager Emergency manager that can block donation execution.
     * @param _minTokenBalanceToExecute Minimum fundraising-token balance required to start a window.
     * @param _factoryAddress Factory allowed to configure the fundraising token and hook.
     * @param _vrfConfig Chainlink VRF request configuration.
     * @param _slotConfig Slot ranges used to decide which monthly slot may execute each donation event.
     */
    constructor(
        address _underlyingAsset,
        uint256 _intervalSeconds,
        address[] memory _beneficiaries,
        address _integrationRegistry,
        address _emergencyManager,
        uint256 _minTokenBalanceToExecute,
        address _factoryAddress,
        VrfConfig memory _vrfConfig,
        SlotConfig memory _slotConfig
    )
        Swap(_integrationRegistry)
        nonZeroAddress(_underlyingAsset)
        nonZeroAddress(_emergencyManager)
        nonZeroAddress(_factoryAddress)
        nonZeroAddress(_vrfConfig.coordinator)
    {
        if (_intervalSeconds == 0) revert InvalidInterval();
        if (_vrfConfig.subscriptionId == 0) revert InvalidVrfConfig();
        if (_vrfConfig.requestConfirmations == 0) revert InvalidVrfConfig();
        if (_vrfConfig.callbackGasLimit == 0) revert InvalidVrfConfig();
        _validateBeneficiaries(_beneficiaries);
        _validateSlotConfig(_slotConfig);

        underlyingAsset = _underlyingAsset;
        intervalSeconds = _intervalSeconds;
        beneficiaries = _beneficiaries;
        emergencyManager = _emergencyManager;
        minTokenBalanceToExecute = _minTokenBalanceToExecute;
        factoryAddress = _factoryAddress;
        vrfCoordinator = _vrfConfig.coordinator;
        vrfKeyHash = _vrfConfig.keyHash;
        vrfSubscriptionId = _vrfConfig.subscriptionId;
        vrfRequestConfirmations = _vrfConfig.requestConfirmations;
        vrfCallbackGasLimit = _vrfConfig.callbackGasLimit;
        slotsPerWindow = _slotConfig.slotsPerWindow;
        firstEventStartSlot = _slotConfig.firstEventStartSlot;
        firstEventEndSlot = _slotConfig.firstEventEndSlot;
        secondEventStartSlot = _slotConfig.secondEventStartSlot;
        secondEventEndSlot = _slotConfig.secondEventEndSlot;
        lastSuccessAt = block.timestamp;
    }

    /**
     * @notice Starts the next monthly donation window and requests VRF for the first hidden-timing event.
     * @dev Permissionless by design. The caller starts a due window but cannot choose execution time or amounts.
     * @return requestId Chainlink VRF request id for the first donation attempt.
     */
    function startDonationWindow() external returns (uint256 requestId) {
        IEmergencyManager manager = IEmergencyManager(emergencyManager);
        if (manager.isEmergencyActive()) revert EmegerncyIsActive();
        if (fundraisingToken == address(0)) revert FundraisingTokenNotConfigured();
        if (hookAddress == address(0)) revert HookNotConfigured();
        if (_hasIncompleteWindow()) revert WindowAlreadyActive();
        if (block.timestamp < lastSuccessAt + intervalSeconds) revert NotDue();

        uint256 balance = IERC20(fundraisingToken).balanceOf(address(this));
        if (balance < minTokenBalanceToExecute) revert InsufficientBalance();
        if (balance > type(uint128).max) revert InsufficientBalance();
        _getPoolKey();

        uint64 cycleId = donationWindow.cycleId + 1;
        uint64 startsAt = uint64(block.timestamp);
        uint64 endsAt = uint64(block.timestamp + DONATION_WINDOW);

        donationWindow = DonationWindow({
            cycleId: cycleId,
            startsAt: startsAt,
            endsAt: endsAt,
            lastRequestAt: 0,
            lastEventAt: 0,
            snapshotBalance: uint128(balance),
            eventsExecuted: 0,
            nextSlotToRequest: firstEventStartSlot,
            randomnessPending: false
        });
        requestId = _requestDonationRandomness(1, firstEventStartSlot);

        emit DonationWindowStarted(cycleId, requestId, startsAt, endsAt, uint128(balance));
    }

    /**
     * @notice Chainlink VRF fulfillment entrypoint.
     * @dev Only the configured coordinator may call this function.
     * @param requestId Chainlink VRF request id.
     * @param randomWords Random words returned by Chainlink VRF.
     */
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        if (msg.sender != vrfCoordinator) revert OnlyCoordinator();
        DonationRequest memory request = requestById[requestId];
        if (request.cycleId == 0 || request.cycleId != donationWindow.cycleId) revert UnknownRequest();
        delete requestById[requestId];
        donationWindow.randomnessPending = false;
        _fulfillRandomWords(request, randomWords);
    }

    /**
     * @notice Requests Chainlink VRF for the next eligible donation attempt.
     * @dev Each request is bound to the current eligible slot for the next donation event.
     * @return requestId Chainlink VRF request id for the donation attempt.
     */
    function requestDonationEvent() public returns (uint256 requestId) {
        IEmergencyManager manager = IEmergencyManager(emergencyManager);
        if (manager.isEmergencyActive()) revert EmegerncyIsActive();
        if (!_canRequestDonationEvent()) revert EventNotEligible();

        requestId = _requestDonationRandomness(donationWindow.eventsExecuted + 1, donationWindow.nextSlotToRequest);
    }

    /**
     * @notice Chainlink Automation-compatible readiness check.
     * @dev
     * Returns encoded perform data for exactly one permissionless action:
     * - `UPKEEP_START_WINDOW` when a monthly window is due.
     * - `UPKEEP_REQUEST_DONATION_EVENT` when the next hidden-timing VRF request is eligible.
     * @return upkeepNeeded True when Chainlink Automation should call {performUpkeep}.
     * @return performData ABI-encoded upkeep action id.
     */
    function checkUpkeep(bytes calldata) external view returns (bool upkeepNeeded, bytes memory performData) {
        if (canStartDonationWindow()) {
            return (true, abi.encode(UPKEEP_START_WINDOW));
        }
        if (_canRequestDonationEvent()) {
            return (true, abi.encode(UPKEEP_REQUEST_DONATION_EVENT));
        }
        return (false, bytes(""));
    }

    /**
     * @notice Chainlink Automation-compatible execution entrypoint.
     * @dev Re-checks current state before executing, so stale perform data cannot force an ineligible action.
     * @param performData ABI-encoded action id returned by {checkUpkeep}.
     */
    function performUpkeep(bytes calldata performData) external {
        uint8 action = abi.decode(performData, (uint8));
        if (action == UPKEEP_START_WINDOW) {
            if (!canStartDonationWindow()) revert EventNotEligible();
            this.startDonationWindow();
            return;
        }
        if (action == UPKEEP_REQUEST_DONATION_EVENT) {
            if (!_canRequestDonationEvent()) revert EventNotEligible();
            requestDonationEvent();
            return;
        }
        revert InvalidUpkeepAction();
    }

    /**
     * @notice Executes the next eligible 1% donation event.
     * @dev Safety failures do not consume the event; only a successful swap/distribution increments the event count.
     */
    function _executeDonationEvent() internal returns (bool success) {
        IEmergencyManager manager = IEmergencyManager(emergencyManager);
        if (manager.isEmergencyActive()) {
            emit DonationExecutionFailed(EmegerncyIsActive.selector);
            return false;
        }
        uint256 amountIn = _trancheAmountIn();
        if (amountIn == 0) {
            emit DonationExecutionFailed(ZeroSwapAmount.selector);
            return false;
        }
        if (IERC20(fundraisingToken).balanceOf(address(this)) < amountIn) {
            emit DonationExecutionFailed(InsufficientBalance.selector);
            return false;
        }

        (bool sellCheckSucceeded, bytes memory sellCheckResult) =
            address(this).staticcall(abi.encodeCall(this.checkShouldAllowSell, ()));
        if (!sellCheckSucceeded) {
            _tryRecordEndpointFailure(manager);
            emit DonationExecutionFailed(SellCheckFailed.selector);
            return false;
        }
        bool shouldSell = abi.decode(sellCheckResult, (bool));
        if (!shouldSell) {
            emit DonationExecutionFailed(UnsafePrice.selector);
            return false;
        }

        (bool quoteSucceeded, bytes memory quoteResult) =
            address(this).call(abi.encodeCall(this.quoteFundraisingTokenSwap, (uint128(amountIn))));
        if (!quoteSucceeded) {
            manager.recordQuoteFailure();
            emit DonationExecutionFailed(QuoteFailed.selector);
            return false;
        }
        uint256 minAmountOut = abi.decode(quoteResult, (uint256));
        manager.recordQuoteSuccess();

        (bool swapSucceeded, bytes memory swapResult) =
            address(this).call(abi.encodeCall(this.swapFundraisingToken, (uint128(amountIn), uint128(minAmountOut))));
        if (!swapSucceeded) {
            manager.recordSwapFailure();
            emit DonationExecutionFailed(SwapFailed.selector);
            return false;
        }
        uint256 amountOut = abi.decode(swapResult, (uint256));
        manager.recordSwapSuccess();
        _finalizeSuccessfulDonation(amountIn, amountOut);
        return true;
    }

    /**
     * @notice Returns true when a new monthly donation window can be started.
     * @dev Useful for Chainlink Automation checkUpkeep logic.
     */
    function canStartDonationWindow() public view returns (bool) {
        if (fundraisingToken == address(0)) return false;
        if (hookAddress == address(0)) return false;
        if (_hasIncompleteWindow()) return false;
        if (block.timestamp < lastSuccessAt + intervalSeconds) return false;
        if (IEmergencyManager(emergencyManager).isEmergencyActive()) return false;
        return IERC20(fundraisingToken).balanceOf(address(this)) >= minTokenBalanceToExecute;
    }

    /**
     * @notice Returns true when the next randomized donation event is scheduled and due.
     * @dev Useful for Chainlink Automation and permissionless callers.
     */
    function canExecuteDonationEvent() public pure returns (bool) {
        return false;
    }

    /**
     * @notice Returns true when Automation or any caller may request VRF for the next donation attempt.
     * @dev Uses non-reverting tranche math so Automation checks remain safe even for tiny balances.
     */
    function _canRequestDonationEvent() internal view returns (bool) {
        DonationWindow memory window = donationWindow;
        if (!_hasIncompleteWindow()) return false;
        if (window.randomnessPending) return false;
        if (IEmergencyManager(emergencyManager).isEmergencyActive()) return false;
        uint256 amountIn = _trancheAmountIn();
        if (amountIn == 0) return false;
        if (IERC20(fundraisingToken).balanceOf(address(this)) < amountIn) return false;
        return _currentSlot() >= window.nextSlotToRequest && _slotInEventRange(window.eventsExecuted + 1, window.nextSlotToRequest);
    }

    /**
     * @notice Quotes the fundraising-token to USDC swap for a donation tranche.
     * @param amountIn Exact fundraising-token input amount.
     * @return minAmountOut Minimum USDC output after the Swap slippage buffer.
     */
    function quoteFundraisingTokenSwap(uint128 amountIn) external onlySelf returns (uint256 minAmountOut) {
        (PoolKey memory key, bool isCurrency0FundraisingToken) = _getPoolKey();
        minAmountOut = getMinAmountOut(key, isCurrency0FundraisingToken, amountIn, bytes(""));
    }

    /**
     * @notice Swaps fundraising tokens into USDC through the configured Uniswap V4 pool.
     * @param amountIn Exact fundraising-token input amount.
     * @param minAmountOut Minimum USDC output required.
     * @return amountOut Actual USDC output received by the Vault.
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
     * @notice Checks whether the current pool price is close enough to TWAP to allow a sell.
     * @return True when the current tick is within the configured TWAP deviation bound.
     */
    function checkShouldAllowSell() external view onlySelf returns (bool) {
        return shouldAllowSell();
    }

    /**
     * @notice Public read helper for Vault sell-safety checks.
     * @return True when current pool price is safe enough for donation execution.
     */
    function shouldAllowSell() public view returns (bool) {
        if (hookAddress == address(0)) revert HookNotConfigured();
        IHook hook = IHook(hookAddress);
        (PoolKey memory key, bool fundraisingIsToken0) = _getPoolKey();

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = oracleObservationInterval;
        secondsAgos[1] = 0;

        (int48[] memory tickCumulatives,) = hook.observe(key, secondsAgos);
        int56 tickDelta = int56(tickCumulatives[1]) - int56(tickCumulatives[0]);
        int24 avgTick = int24(tickDelta / int56(uint56(oracleObservationInterval)));
        int24 currentTick = hook.getCurrentTick(key);

        if (fundraisingIsToken0) return avgTick - currentTick <= maxTickDeviation;
        return currentTick - avgTick <= maxTickDeviation;
    }

    /**
     * @notice Configures the hook used for TWAP reads.
     * @dev Only callable by the factory that created this Vault.
     * @param _hookAddress Shared fundraising token hook address.
     */
    function setHookAddress(address _hookAddress) external onlyFactory {
        hookAddress = _hookAddress;
    }

    /**
     * @notice Configures the fundraising token held by this Vault.
     * @dev Only callable by the factory that created this Vault.
     * @param _fundraisingToken Fundraising token address.
     */
    function setFundraisingToken(address _fundraisingToken) external onlyFactory {
        fundraisingToken = _fundraisingToken;
    }

    /**
     * @notice Consumes a VRF fulfillment and evaluates whether the requested slot should execute.
     * @dev No future timestamp is stored; missed slots simply advance the cursor to the next slot in range.
     * @param request Pending donation request metadata.
     * @param randomWords Chainlink VRF random words.
     */
    function _fulfillRandomWords(DonationRequest memory request, uint256[] calldata randomWords) internal {
        if (!_hasIncompleteWindow()) revert WindowNotActive();
        if (request.eventIndex != donationWindow.eventsExecuted + 1) revert UnknownRequest();
        if (randomWords.length < 2) revert InvalidVrfConfig();
        if (request.slotIndex != donationWindow.nextSlotToRequest) revert UnknownRequest();
        if (!_slotInEventRange(request.eventIndex, request.slotIndex)) revert UnknownRequest();

        (uint8 startSlot, uint8 endSlot) = _eventSlotRange(request.eventIndex);
        uint8 selectedSlot = _selectDonationSlot(startSlot, endSlot, request, randomWords);
        bool shouldExecute = selectedSlot == request.slotIndex || request.slotIndex == endSlot;
        bool executed;

        if (shouldExecute) {
            executed = _executeDonationEvent();
            if (executed && donationWindow.eventsExecuted < EVENTS_PER_WINDOW) {
                donationWindow.nextSlotToRequest = secondEventStartSlot;
            }
        }

        if (!executed) {
            if (request.slotIndex < endSlot && !shouldExecute) {
                donationWindow.nextSlotToRequest = request.slotIndex + 1;
            }
        }

        emit DonationSlotEvaluated(request.cycleId, request.eventIndex, selectedSlot, request.slotIndex, executed);
    }

    /**
     * @notice Derives the slot selected by Chainlink VRF inside an event's configured range.
     * @dev A request in the final slot executes regardless of this value to guarantee progress.
     * @param startSlot First slot in the event range.
     * @param endSlot Final slot in the event range.
     * @param request Pending donation request metadata.
     * @param randomWords Chainlink VRF random words.
     * @return selectedSlot Slot selected by the VRF seed.
     */
    function _selectDonationSlot(
        uint8 startSlot,
        uint8 endSlot,
        DonationRequest memory request,
        uint256[] calldata randomWords
    )
        internal
        pure
        returns (uint8 selectedSlot)
    {
        uint256 seed = uint256(keccak256(abi.encode(randomWords[0], randomWords[1], request.cycleId, request.eventIndex)));
        selectedSlot = uint8(startSlot + (seed % (uint256(endSlot) - startSlot + 1)));
    }

    /**
     * @notice Returns the fixed tranche amount for the current donation window.
     * @dev Uses the opening snapshot so both events are exactly 1% of the same balance.
     */
    function _getTrancheAmountIn() internal view returns (uint256 amountIn) {
        amountIn = _trancheAmountIn();
        if (amountIn == 0) revert ZeroSwapAmount();
    }

    /**
     * @notice Calculates the current window tranche amount without reverting.
     * @return amountIn Fundraising-token amount for one donation tranche.
     */
    function _trancheAmountIn() internal view returns (uint256 amountIn) {
        amountIn = (uint256(donationWindow.snapshotBalance) * TRANCHE_PERCENTAGE) / PERCENTAGE_DENOMINATOR;
    }

    /**
     * @notice Distributes USDC swap proceeds equally across all beneficiaries.
     * @param amountOut USDC amount received from the donation swap.
     */
    function _distributeProceeds(uint256 amountOut) internal {
        uint256 beneficiaryCount = beneficiaries.length;
        uint256 amountPerBeneficiary = amountOut / beneficiaryCount;
        uint256 remainder = amountOut % beneficiaryCount;

        for (uint256 i; i < beneficiaryCount; ++i) {
            uint256 payout = amountPerBeneficiary;
            if (i == beneficiaryCount - 1) payout += remainder;
            IERC20(underlyingAsset).safeTransfer(beneficiaries[i], payout);
            emit FundsTransferredToNonProfit(beneficiaries[i], payout);
        }
    }

    /**
     * @notice Marks a donation tranche complete after successful swap and distribution.
     * @param amountIn Fundraising-token amount swapped.
     * @param amountOut USDC amount distributed.
     */
    function _finalizeSuccessfulDonation(uint256 amountIn, uint256 amountOut) internal {
        _distributeProceeds(amountOut);

        unchecked {
            ++donationWindow.eventsExecuted;
        }
        lastSuccessAt = block.timestamp;
        donationWindow.lastEventAt = uint64(block.timestamp);

        emit DonationEventExecuted(donationWindow.cycleId, donationWindow.eventsExecuted, amountIn, amountOut);
    }

    /**
     * @notice Requests Chainlink VRF for one donation attempt in a specific slot.
     * @param eventIndex One-based donation event index being requested.
     * @param slotIndex Slot currently being tested for execution.
     * @return requestId Chainlink VRF request id.
     */
    function _requestDonationRandomness(uint8 eventIndex, uint8 slotIndex) internal returns (uint256 requestId) {
        if (donationWindow.randomnessPending) revert RandomnessPending();
        requestId = IVRFCoordinatorV2(vrfCoordinator)
            .requestRandomWords(vrfKeyHash, vrfSubscriptionId, vrfRequestConfirmations, vrfCallbackGasLimit, 2);
        donationWindow.randomnessPending = true;
        donationWindow.lastRequestAt = uint64(block.timestamp);
        requestById[requestId] =
            DonationRequest({cycleId: donationWindow.cycleId, eventIndex: eventIndex, slotIndex: slotIndex});

        emit DonationEventRandomnessRequested(donationWindow.cycleId, eventIndex, requestId, uint64(block.timestamp));
    }

    /**
     * @notice Returns the current zero-based slot for the active donation window.
     * @return slotIndex Current slot index capped to the final configured slot.
     */
    function _currentSlot() internal view returns (uint8 slotIndex) {
        DonationWindow memory window = donationWindow;
        if (block.timestamp <= window.startsAt) return 0;
        uint256 elapsed = block.timestamp - window.startsAt;
        uint256 slotDuration = DONATION_WINDOW / slotsPerWindow;
        uint256 slot = elapsed / slotDuration;
        if (slot >= slotsPerWindow) return slotsPerWindow - 1;
        return uint8(slot);
    }

    /**
     * @notice Returns the configured slot range for a one-based donation event index.
     * @param eventIndex Donation event index, either 1 or 2.
     * @return startSlot First allowed slot for the event.
     * @return endSlot Final allowed slot for the event.
     */
    function _eventSlotRange(uint8 eventIndex) internal view returns (uint8 startSlot, uint8 endSlot) {
        if (eventIndex == 1) return (firstEventStartSlot, firstEventEndSlot);
        if (eventIndex == 2) return (secondEventStartSlot, secondEventEndSlot);
        revert WindowComplete();
    }

    /**
     * @notice Checks whether a slot belongs to the configured range for an event.
     * @param eventIndex Donation event index, either 1 or 2.
     * @param slotIndex Slot to validate.
     * @return True when the slot is in the event's configured range.
     */
    function _slotInEventRange(uint8 eventIndex, uint8 slotIndex) internal view returns (bool) {
        (uint8 startSlot, uint8 endSlot) = _eventSlotRange(eventIndex);
        return slotIndex >= startSlot && slotIndex <= endSlot;
    }

    /**
     * @notice Attempts to record StateView endpoint failures without blocking the Vault.
     * @param manager Emergency manager used for objective failure tracking.
     */
    function _tryRecordEndpointFailure(IEmergencyManager manager) internal {
        try manager.recordEndpointFailure(uint8(IIntegrationRegistry.Endpoint.STATE_VIEW)) {} catch {}
    }

    /**
     * @notice Validates immutable beneficiary configuration.
     * @param _beneficiaries Beneficiary addresses to validate.
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
     * @notice Validates the immutable donation slot configuration.
     * @dev Event ranges must be ordered, non-overlapping, and contained within the monthly slot count.
     * @param config Slot configuration to validate.
     */
    function _validateSlotConfig(SlotConfig memory config) internal pure {
        if (config.slotsPerWindow == 0) revert InvalidSlotConfig();
        if (DONATION_WINDOW % config.slotsPerWindow != 0) revert InvalidSlotConfig();
        if (config.firstEventStartSlot > config.firstEventEndSlot) revert InvalidSlotConfig();
        if (config.secondEventStartSlot > config.secondEventEndSlot) revert InvalidSlotConfig();
        if (config.firstEventEndSlot >= config.secondEventStartSlot) revert InvalidSlotConfig();
        if (config.secondEventEndSlot >= config.slotsPerWindow) revert InvalidSlotConfig();
    }

    /**
     * @notice Loads and validates the canonical Uniswap V4 pool key for the fundraising token.
     * @return key Factory-registered pool key.
     * @return isCurrency0FundraisingToken True if fundraising token is pool currency0.
     */
    function _getPoolKey() internal view returns (PoolKey memory key, bool isCurrency0FundraisingToken) {
        key = IFactory(factoryAddress).getPoolKeys(fundraisingToken);
        bool isCurrency0 = Currency.unwrap(key.currency0) == fundraisingToken;
        bool isCurrency1 = Currency.unwrap(key.currency1) == fundraisingToken;
        bool hasUnderlyingAsCurrency0 = Currency.unwrap(key.currency0) == underlyingAsset;
        bool hasUnderlyingAsCurrency1 = Currency.unwrap(key.currency1) == underlyingAsset;
        if (isCurrency0 && hasUnderlyingAsCurrency1) return (key, true);
        if (isCurrency1 && hasUnderlyingAsCurrency0) return (key, false);
        revert PoolNotConfigured();
    }

    /**
     * @notice Returns true while a donation cycle exists and still has unexecuted tranches.
     * @dev The cycle intentionally remains incomplete after `endsAt` if safety checks delayed execution.
     */
    function _hasIncompleteWindow() internal view returns (bool) {
        return donationWindow.startsAt != 0 && donationWindow.eventsExecuted < EVENTS_PER_WINDOW;
    }
}
