// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";

import {VaultV2} from "../src/VaultV2.sol";
import {Swap} from "../src/abstracts/Swap.sol";
import {IIntegrationRegistry} from "../src/interfaces/IIntegrationRegistry.sol";

contract MockV2Token is ERC20 {
    uint8 internal immutable tokenDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return tokenDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function burnFromVault(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

contract MockV2EmergencyManager {
    bool internal emergencyActive;
    uint256 public quoteFailureCount;
    uint256 public quoteSuccessCount;
    uint256 public swapFailureCount;
    uint256 public swapSuccessCount;
    uint8 public lastEndpointFailure;
    bool internal endpointFailureShouldRevert;

    function setEmergencyActive(bool active) external {
        emergencyActive = active;
    }

    function isEmergencyActive() external view returns (bool) {
        return emergencyActive;
    }

    function recordQuoteFailure() external {
        ++quoteFailureCount;
    }

    function recordQuoteSuccess() external {
        ++quoteSuccessCount;
    }

    function recordSwapFailure() external {
        ++swapFailureCount;
    }

    function recordSwapSuccess() external {
        ++swapSuccessCount;
    }

    function recordEndpointFailure(uint8 endpoint) external {
        if (endpointFailureShouldRevert) revert("endpoint record failed");
        lastEndpointFailure = endpoint;
    }

    function setEndpointFailureShouldRevert(bool shouldRevert) external {
        endpointFailureShouldRevert = shouldRevert;
    }
}

contract MockV2Permit2 {
    address public lastToken;
    address public lastSpender;
    uint160 public lastAmount;
    uint48 public lastExpiration;

    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        lastToken = token;
        lastSpender = spender;
        lastAmount = amount;
        lastExpiration = expiration;
    }
}

contract MockV2Quoter {
    bool internal shouldRevert;
    uint256 internal amountOut;
    bool public lastZeroForOne;
    uint128 public lastExactAmount;

    function setQuote(uint256 newAmountOut, bool revertQuote) external {
        amountOut = newAmountOut;
        shouldRevert = revertQuote;
    }

    function quoteExactInputSingle(IV4Quoter.QuoteExactSingleParams calldata params)
        external
        returns (uint256 quotedAmountOut, uint256 gasEstimate)
    {
        if (shouldRevert) revert("quote failed");
        lastZeroForOne = params.zeroForOne;
        lastExactAmount = params.exactAmount;
        return (amountOut, 0);
    }
}

contract MockV2Router {
    bool internal shouldRevert;
    address internal payoutToken;
    uint256 internal payoutAmount;

    function setSwapResult(address token, uint256 amount, bool revertSwap) external {
        payoutToken = token;
        payoutAmount = amount;
        shouldRevert = revertSwap;
    }

    function execute(bytes calldata, bytes[] calldata, uint256) external {
        if (shouldRevert) revert("swap failed");
        IERC20(payoutToken).transfer(msg.sender, payoutAmount);
    }
}

contract MockV2Registry {
    address public router;
    address public permit2;
    address public quoter;

    constructor(address router_, address permit2_, address quoter_) {
        router = router_;
        permit2 = permit2_;
        quoter = quoter_;
    }
}

contract MockV2Factory {
    PoolKey internal poolKey;

    function setPoolKey(PoolKey memory newPoolKey) external {
        poolKey = newPoolKey;
    }

    function getPoolKeys(address) external view returns (PoolKey memory) {
        return poolKey;
    }

    function isAuthorizedHookPool(address, PoolKey calldata, address) external pure returns (bool) {
        return true;
    }
}

contract MockV2Hook {
    bool internal observeShouldRevert;
    int48[2] internal cumulatives;
    int24 internal currentTick;

    function configure(int48 cumulative0, int48 cumulative1, int24 tick, bool shouldRevert_) external {
        cumulatives[0] = cumulative0;
        cumulatives[1] = cumulative1;
        currentTick = tick;
        observeShouldRevert = shouldRevert_;
    }

    function observe(PoolKey calldata, uint32[] calldata)
        external
        view
        returns (int48[] memory tickCumulatives, uint144[] memory secondsPerLiquidityCumulativeX128s)
    {
        if (observeShouldRevert) revert("observe failed");
        tickCumulatives = new int48[](2);
        tickCumulatives[0] = cumulatives[0];
        tickCumulatives[1] = cumulatives[1];
        secondsPerLiquidityCumulativeX128s = new uint144[](2);
    }

    function getCurrentTick(PoolKey calldata) external view returns (int24) {
        return currentTick;
    }
}

contract MockV2VrfCoordinator {
    uint256 public nextRequestId = 1;
    bytes32 public lastKeyHash;
    uint64 public lastSubId;
    uint16 public lastConfirmations;
    uint32 public lastCallbackGasLimit;
    uint32 public lastNumWords;

    function requestRandomWords(
        bytes32 keyHash,
        uint64 subId,
        uint16 minimumRequestConfirmations,
        uint32 callbackGasLimit,
        uint32 numWords
    ) external returns (uint256 requestId) {
        requestId = nextRequestId++;
        lastKeyHash = keyHash;
        lastSubId = subId;
        lastConfirmations = minimumRequestConfirmations;
        lastCallbackGasLimit = callbackGasLimit;
        lastNumWords = numWords;
    }

    function fulfill(address vault, uint256 requestId, uint256 word) external {
        uint256[] memory randomWords = new uint256[](2);
        randomWords[0] = word;
        randomWords[1] = uint256(keccak256(abi.encode(word)));
        VaultV2(vault).rawFulfillRandomWords(requestId, randomWords);
    }

    function fulfillWithEmptyWords(address vault, uint256 requestId) external {
        uint256[] memory randomWords = new uint256[](0);
        VaultV2(vault).rawFulfillRandomWords(requestId, randomWords);
    }
}

contract VaultV2Test is Test {
    MockV2Token internal fundraisingToken;
    MockV2Token internal usdc;
    MockV2EmergencyManager internal emergencyManager;
    MockV2Permit2 internal permit2;
    MockV2Quoter internal quoter;
    MockV2Router internal router;
    MockV2Registry internal registry;
    MockV2Factory internal factory;
    MockV2Hook internal hook;
    MockV2VrfCoordinator internal vrf;
    VaultV2 internal vault;

    address[] internal beneficiaries;
    address internal beneficiaryA = address(0xA1);
    address internal beneficiaryB = address(0xB2);
    address internal beneficiaryC = address(0xC3);
    bytes32 internal keyHash = keccak256("keyHash");

    event DonationWindowStarted(
        uint64 indexed cycleId, uint256 indexed requestId, uint64 startsAt, uint64 endsAt, uint128 snapshotBalance
    );
    event DonationEventRandomnessRequested(
        uint64 indexed cycleId, uint8 indexed eventIndex, uint256 indexed requestId, uint64 requestedAt
    );
    event DonationSlotEvaluated(
        uint64 indexed cycleId, uint8 indexed eventIndex, uint8 selectedSlot, uint8 requestedSlot, bool executed
    );
    event DonationEventExecuted(uint64 indexed cycleId, uint8 indexed eventIndex, uint256 amountIn, uint256 amountOut);
    event DonationBurnExecuted(uint64 indexed cycleId, uint8 indexed eventIndex, uint256 burnAmount);
    event DonationExecutionFailed(bytes4 reason);

    uint8 internal constant UPKEEP_START_WINDOW = 1;
    uint8 internal constant UPKEEP_REQUEST_DONATION_EVENT = 2;

    function setUp() public {
        fundraisingToken = new MockV2Token("Fund", "FUND", 6);
        usdc = new MockV2Token("USD Coin", "USDC", 6);
        emergencyManager = new MockV2EmergencyManager();
        permit2 = new MockV2Permit2();
        quoter = new MockV2Quoter();
        router = new MockV2Router();
        registry = new MockV2Registry(address(router), address(permit2), address(quoter));
        factory = new MockV2Factory();
        hook = new MockV2Hook();
        vrf = new MockV2VrfCoordinator();

        beneficiaries.push(beneficiaryA);
        beneficiaries.push(beneficiaryB);
        beneficiaries.push(beneficiaryC);

        vault = _deployVault(1 days, beneficiaries, 100);

        vm.prank(address(factory));
        vault.setFundraisingToken(address(fundraisingToken));
        vm.prank(address(factory));
        vault.setHookAddress(address(hook));

        _setPoolKey(address(fundraisingToken), address(usdc));
        hook.configure(0, 0, 0, false);
    }

    function testConstructorRejectsInvalidConfig() public {
        VaultV2.VrfConfig memory validVrf = _vrfConfig();

        vm.expectRevert(Swap.ZeroAddress.selector);
        new VaultV2(
            address(0),
            1 days,
            beneficiaries,
            address(registry),
            address(emergencyManager),
            100,
            address(factory),
            validVrf,
            _slotConfig()
        );

        vm.expectRevert(Swap.ZeroAddress.selector);
        new VaultV2(
            address(usdc),
            1 days,
            beneficiaries,
            address(registry),
            address(0),
            100,
            address(factory),
            validVrf,
            _slotConfig()
        );

        vm.expectRevert(Swap.ZeroAddress.selector);
        new VaultV2(
            address(usdc),
            1 days,
            beneficiaries,
            address(registry),
            address(emergencyManager),
            100,
            address(0),
            validVrf,
            _slotConfig()
        );

        validVrf.coordinator = address(0);
        vm.expectRevert(Swap.ZeroAddress.selector);
        new VaultV2(
            address(usdc),
            1 days,
            beneficiaries,
            address(registry),
            address(emergencyManager),
            100,
            address(factory),
            validVrf,
            _slotConfig()
        );

        vm.expectRevert(VaultV2.InvalidInterval.selector);
        new VaultV2(
            address(usdc),
            0,
            beneficiaries,
            address(registry),
            address(emergencyManager),
            100,
            address(factory),
            _vrfConfig(),
            _slotConfig()
        );

        VaultV2.VrfConfig memory invalidVrf = _vrfConfig();
        invalidVrf.subscriptionId = 0;
        vm.expectRevert(VaultV2.InvalidVrfConfig.selector);
        new VaultV2(
            address(usdc),
            1 days,
            beneficiaries,
            address(registry),
            address(emergencyManager),
            100,
            address(factory),
            invalidVrf,
            _slotConfig()
        );

        invalidVrf = _vrfConfig();
        invalidVrf.requestConfirmations = 0;
        vm.expectRevert(VaultV2.InvalidVrfConfig.selector);
        new VaultV2(
            address(usdc),
            1 days,
            beneficiaries,
            address(registry),
            address(emergencyManager),
            100,
            address(factory),
            invalidVrf,
            _slotConfig()
        );

        invalidVrf = _vrfConfig();
        invalidVrf.callbackGasLimit = 0;
        vm.expectRevert(VaultV2.InvalidVrfConfig.selector);
        new VaultV2(
            address(usdc),
            1 days,
            beneficiaries,
            address(registry),
            address(emergencyManager),
            100,
            address(factory),
            invalidVrf,
            _slotConfig()
        );
    }

    function testConstructorRejectsInvalidBeneficiaries() public {
        address[] memory empty = new address[](0);
        vm.expectRevert(VaultV2.NoBeneficiaries.selector);
        _deployVault(1 days, empty, 100);

        address[] memory zero = new address[](1);
        zero[0] = address(0);
        vm.expectRevert(VaultV2.ZeroBeneficiary.selector);
        _deployVault(1 days, zero, 100);

        address[] memory duplicate = new address[](2);
        duplicate[0] = beneficiaryA;
        duplicate[1] = beneficiaryA;
        vm.expectRevert(VaultV2.DuplicateBeneficiary.selector);
        _deployVault(1 days, duplicate, 100);
    }

    function testConstructorRejectsInvalidSlotConfig() public {
        VaultV2.SlotConfig memory invalid = _slotConfig();
        invalid.slotsPerWindow = 0;
        vm.expectRevert(VaultV2.InvalidSlotConfig.selector);
        _deployVaultWithSlotConfig(invalid);

        invalid = _slotConfig();
        invalid.slotsPerWindow = 7;
        vm.expectRevert(VaultV2.InvalidSlotConfig.selector);
        _deployVaultWithSlotConfig(invalid);

        invalid = _slotConfig();
        invalid.firstEventStartSlot = 2;
        invalid.firstEventEndSlot = 1;
        vm.expectRevert(VaultV2.InvalidSlotConfig.selector);
        _deployVaultWithSlotConfig(invalid);

        invalid = _slotConfig();
        invalid.firstEventEndSlot = 2;
        vm.expectRevert(VaultV2.InvalidSlotConfig.selector);
        _deployVaultWithSlotConfig(invalid);

        invalid = _slotConfig();
        invalid.secondEventEndSlot = 4;
        vm.expectRevert(VaultV2.InvalidSlotConfig.selector);
        _deployVaultWithSlotConfig(invalid);
    }

    function testStartDonationWindowRequestsFirstVrfWithoutSavingEventTime() public {
        vm.warp(block.timestamp + 1 days + 1);
        fundraisingToken.mint(address(vault), 1_000);

        vm.expectEmit(true, true, true, true);
        emit DonationEventRandomnessRequested(1, 1, 1, uint64(block.timestamp));
        vm.expectEmit(true, true, false, true);
        emit DonationWindowStarted(1, 1, uint64(block.timestamp), uint64(block.timestamp + 30 days), 1_000);

        uint256 requestId = vault.startDonationWindow();
        (
            uint64 cycleId,
            uint64 startsAt,
            uint64 endsAt,
            uint64 lastRequestAt,
            uint64 lastEventAt,
            uint128 snapshotBalance,
            uint8 eventsExecuted,
            uint8 nextSlotToRequest,
            bool randomnessPending
        ) = vault.donationWindow();
        (uint64 requestCycleId, uint8 eventIndex, uint8 slotIndex) = vault.requestById(requestId);

        assertEq(requestId, 1);
        assertEq(cycleId, 1);
        assertEq(startsAt, block.timestamp);
        assertEq(endsAt, block.timestamp + 30 days);
        assertEq(lastRequestAt, block.timestamp);
        assertEq(lastEventAt, 0);
        assertEq(snapshotBalance, 1_000);
        assertEq(eventsExecuted, 0);
        assertEq(nextSlotToRequest, 0);
        assertTrue(randomnessPending);
        assertEq(requestCycleId, 1);
        assertEq(eventIndex, 1);
        assertEq(slotIndex, 0);
        assertEq(vrf.lastKeyHash(), keyHash);
        assertEq(vrf.lastSubId(), 1);
        assertEq(vrf.lastConfirmations(), 3);
        assertEq(vrf.lastCallbackGasLimit(), 500_000);
        assertEq(vrf.lastNumWords(), 2);
        assertFalse(vault.canExecuteDonationEvent());
    }

    function testStartDonationWindowRevertsForAllGates() public {
        emergencyManager.setEmergencyActive(true);
        vm.expectRevert(VaultV2.EmegerncyIsActive.selector);
        vault.startDonationWindow();
        emergencyManager.setEmergencyActive(false);

        VaultV2 unconfiguredTokenVault = _deployVault(1 days, beneficiaries, 100);
        vm.expectRevert(VaultV2.FundraisingTokenNotConfigured.selector);
        unconfiguredTokenVault.startDonationWindow();

        VaultV2 unconfiguredHookVault = _deployVault(1 days, beneficiaries, 100);
        vm.prank(address(factory));
        unconfiguredHookVault.setFundraisingToken(address(fundraisingToken));
        vm.expectRevert(VaultV2.HookNotConfigured.selector);
        unconfiguredHookVault.startDonationWindow();

        vm.expectRevert(VaultV2.NotDue.selector);
        vault.startDonationWindow();

        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(VaultV2.InsufficientBalance.selector);
        vault.startDonationWindow();

        fundraisingToken.mint(address(vault), 100);
        vault.startDonationWindow();
        vm.expectRevert(VaultV2.WindowAlreadyActive.selector);
        vault.startDonationWindow();
    }

    function testStartDonationWindowRejectsSnapshotOverflowAndInvalidPool() public {
        vm.warp(block.timestamp + 1 days);
        fundraisingToken.mint(address(vault), uint256(type(uint128).max) + 1);

        vm.expectRevert(VaultV2.InsufficientBalance.selector);
        vault.startDonationWindow();

        VaultV2 invalidPoolVault = _deployVault(1 days, beneficiaries, 100);
        MockV2Token invalidPoolFundraisingToken = new MockV2Token("Invalid Pool Fund", "IPF", 6);
        vm.prank(address(factory));
        invalidPoolVault.setFundraisingToken(address(invalidPoolFundraisingToken));
        vm.prank(address(factory));
        invalidPoolVault.setHookAddress(address(hook));
        invalidPoolFundraisingToken.mint(address(invalidPoolVault), 1_000);
        _setPoolKey(address(0x1111), address(usdc));
        vm.warp(block.timestamp + 1 days + 1);

        vm.expectRevert(VaultV2.PoolNotConfigured.selector);
        invalidPoolVault.startDonationWindow();
    }

    function testRawFulfillRandomWordsOnlyCoordinatorAndValidatesRequest() public {
        uint256 requestId = _startWindow(1_000);
        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = 1;

        vm.expectRevert(VaultV2.OnlyCoordinator.selector);
        vault.rawFulfillRandomWords(requestId, randomWords);

        vm.expectRevert(VaultV2.UnknownRequest.selector);
        vrf.fulfill(address(vault), requestId + 1, 1);

        vm.expectRevert(VaultV2.InvalidVrfConfig.selector);
        vrf.fulfillWithEmptyWords(address(vault), requestId);
    }

    function testVrfFulfillmentExecutesWhenRandomSlotMatchesCurrentSlot() public {
        uint256 requestId = _startWindow(1_000);
        _prepareSuccessfulSwap(95, 95);
        uint256 matchingWord = _wordForSelectedSlot(1, 0);

        vm.expectEmit(true, true, false, true);
        emit DonationEventExecuted(1, 1, 10, 95);
        vm.expectEmit(true, true, false, true);
        emit DonationBurnExecuted(1, 1, 10);
        vm.expectEmit(true, true, true, true);
        emit DonationSlotEvaluated(1, 1, 0, 0, true);
        vrf.fulfill(address(vault), requestId, matchingWord);

        (,,,, uint64 lastEventAt,, uint8 eventsExecuted, uint8 nextSlotToRequest, bool randomnessPending) =
            vault.donationWindow();
        assertEq(lastEventAt, block.timestamp);
        assertEq(eventsExecuted, 1);
        assertEq(nextSlotToRequest, 2);
        assertFalse(randomnessPending);
        assertEq(emergencyManager.quoteSuccessCount(), 1);
        assertEq(emergencyManager.swapSuccessCount(), 1);
        assertEq(quoter.lastExactAmount(), 10);
        assertTrue(quoter.lastZeroForOne());
        assertEq(permit2.lastToken(), address(fundraisingToken));
        assertEq(permit2.lastSpender(), address(router));
        assertEq(permit2.lastAmount(), 10);
        assertEq(usdc.balanceOf(beneficiaryA), 31);
        assertEq(usdc.balanceOf(beneficiaryB), 31);
        assertEq(usdc.balanceOf(beneficiaryC), 33);
        assertEq(fundraisingToken.balanceOf(address(vault)), 990);
        assertEq(fundraisingToken.totalSupply(), 990);
        assertFalse(vault.canExecuteDonationEvent());
    }

    function testRandomSlotMissAdvancesThenSecondSlotCanExecute() public {
        uint256 requestId = _startWindow(1_000);
        _prepareSuccessfulSwap(95, 190);
        uint256 missWord = _wordForSelectedSlot(1, 1);

        vm.expectEmit(true, true, true, true);
        emit DonationSlotEvaluated(1, 1, 1, 0, false);
        vrf.fulfill(address(vault), requestId, missWord);

        (,,,,, uint128 snapshotBalance, uint8 eventsExecuted, uint8 nextSlotToRequest, bool randomnessPending) =
            vault.donationWindow();
        assertEq(snapshotBalance, 1_000);
        assertEq(eventsExecuted, 0);
        assertEq(nextSlotToRequest, 1);
        assertFalse(randomnessPending);

        vm.expectRevert(VaultV2.EventNotEligible.selector);
        vault.requestDonationEvent();

        vm.warp(block.timestamp + 8 days);
        (bool upkeepNeeded, bytes memory performData) = vault.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertEq(abi.decode(performData, (uint8)), UPKEEP_REQUEST_DONATION_EVENT);

        vm.expectEmit(true, true, true, true);
        emit DonationEventRandomnessRequested(1, 1, 2, uint64(block.timestamp));
        uint256 retryRequestId = vault.requestDonationEvent();
        assertEq(retryRequestId, 2);
        uint256 matchingWord = _wordForSelectedSlot(1, 1);
        vm.expectEmit(true, true, false, true);
        emit DonationEventExecuted(1, 1, 10, 95);
        vm.expectEmit(true, true, true, true);
        emit DonationSlotEvaluated(1, 1, 1, 1, true);
        vrf.fulfill(address(vault), retryRequestId, matchingWord);

        (,,,,,, eventsExecuted, nextSlotToRequest, randomnessPending) = vault.donationWindow();
        assertEq(eventsExecuted, 1);
        assertEq(nextSlotToRequest, 2);
        assertFalse(randomnessPending);
        assertEq(usdc.balanceOf(beneficiaryA), 31);
        assertEq(usdc.balanceOf(beneficiaryB), 31);
        assertEq(usdc.balanceOf(beneficiaryC), 33);
    }

    function testSecondDonationUsesSecondHalfSlotsAndFinalSlotFallback() public {
        uint256 requestId = _startWindow(1_000);
        _prepareSuccessfulSwap(95, 190);
        vrf.fulfill(address(vault), requestId, _wordForSelectedSlot(1, 0));

        vm.warp(block.timestamp + 15 days + 1);
        (bool upkeepNeeded, bytes memory performData) = vault.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertEq(abi.decode(performData, (uint8)), UPKEEP_REQUEST_DONATION_EVENT);

        vm.expectEmit(true, true, true, true);
        emit DonationEventRandomnessRequested(1, 2, 2, uint64(block.timestamp));
        uint256 secondRequestId = vault.requestDonationEvent();

        vm.expectEmit(true, true, true, true);
        emit DonationSlotEvaluated(1, 2, 3, 2, false);
        vrf.fulfill(address(vault), secondRequestId, _wordForSelectedSlot(2, 3));

        (,,,,,, uint8 eventsExecuted, uint8 nextSlotToRequest, bool randomnessPending) = vault.donationWindow();
        assertEq(eventsExecuted, 1);
        assertEq(nextSlotToRequest, 3);
        assertFalse(randomnessPending);

        vm.warp(block.timestamp + 8 days);
        secondRequestId = vault.requestDonationEvent();
        vm.expectEmit(true, true, false, true);
        emit DonationEventExecuted(1, 2, 10, 95);
        vrf.fulfill(address(vault), secondRequestId, _wordForSelectedSlot(2, 2));

        (,,,,,, eventsExecuted,, randomnessPending) = vault.donationWindow();
        assertEq(eventsExecuted, 2);
        assertFalse(randomnessPending);
        assertEq(usdc.balanceOf(beneficiaryA), 62);
        assertEq(usdc.balanceOf(beneficiaryB), 62);
        assertEq(usdc.balanceOf(beneficiaryC), 66);
    }

    function testCheckAndPerformUpkeepStartWindow() public {
        (bool upkeepNeeded, bytes memory performData) = vault.checkUpkeep("");
        assertFalse(upkeepNeeded);
        assertEq(performData.length, 0);

        vm.warp(block.timestamp + 1 days + 1);
        fundraisingToken.mint(address(vault), 1_000);

        (upkeepNeeded, performData) = vault.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertEq(abi.decode(performData, (uint8)), UPKEEP_START_WINDOW);

        vm.expectEmit(true, true, true, true);
        emit DonationEventRandomnessRequested(1, 1, 1, uint64(block.timestamp));
        vault.performUpkeep(performData);

        (,,,,,, uint8 eventsExecuted,, bool randomnessPending) = vault.donationWindow();
        assertEq(eventsExecuted, 0);
        assertTrue(randomnessPending);
        assertEq(vrf.lastNumWords(), 2);
    }

    function testCheckAndPerformUpkeepRequestsNextSlotAfterCallbackExecution() public {
        uint256 requestId = _startWindow(1_000);
        _prepareSuccessfulSwap(95, 190);
        vrf.fulfill(address(vault), requestId, _wordForSelectedSlot(1, 0));

        (bool upkeepNeeded,) = vault.checkUpkeep("");
        assertFalse(upkeepNeeded);

        vm.warp(block.timestamp + 15 days);
        bytes memory performData;
        (upkeepNeeded, performData) = vault.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertEq(abi.decode(performData, (uint8)), UPKEEP_REQUEST_DONATION_EVENT);

        vm.expectEmit(true, true, true, true);
        emit DonationEventRandomnessRequested(1, 2, 2, uint64(block.timestamp));
        vault.performUpkeep(performData);

        (,,,,,, uint8 eventsExecuted,, bool randomnessPending) = vault.donationWindow();
        assertEq(eventsExecuted, 1);
        assertTrue(randomnessPending);
    }

    function testPerformUpkeepRejectsStaleOrInvalidActions() public {
        vm.expectRevert(VaultV2.EventNotEligible.selector);
        vault.performUpkeep(abi.encode(UPKEEP_START_WINDOW));

        uint256 requestId = _startWindow(1_000);
        _prepareSuccessfulSwap(95, 95);
        vm.expectRevert(VaultV2.EventNotEligible.selector);
        vault.performUpkeep(abi.encode(UPKEEP_REQUEST_DONATION_EVENT));

        vm.expectRevert(VaultV2.InvalidUpkeepAction.selector);
        vault.performUpkeep(abi.encode(uint8(99)));

        vrf.fulfill(address(vault), requestId, _wordForSelectedSlot(1, 0));
    }

    function testDonationFailuresDoNotConsumeTrancheAndCanRequestAgain() public {
        uint256 requestId = _startWindow(1_000);

        hook.configure(0, 0, 0, true);
        vm.expectEmit(false, false, false, true);
        emit DonationExecutionFailed(VaultV2.SellCheckFailed.selector);
        vrf.fulfill(address(vault), requestId, _wordForSelectedSlot(1, 0));
        (,,,,,, uint8 eventsExecuted,, bool randomnessPending) = vault.donationWindow();
        assertEq(eventsExecuted, 0);
        assertFalse(randomnessPending);
        assertEq(emergencyManager.lastEndpointFailure(), uint8(IIntegrationRegistry.Endpoint.STATE_VIEW));
        (bool upkeepNeeded, bytes memory performData) = vault.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertEq(abi.decode(performData, (uint8)), UPKEEP_REQUEST_DONATION_EVENT);

        hook.configure(0, 0, 0, false);
        uint256 retryRequestId = vault.requestDonationEvent();
        quoter.setQuote(0, true);
        vm.expectEmit(false, false, false, true);
        emit DonationExecutionFailed(VaultV2.QuoteFailed.selector);
        vrf.fulfill(address(vault), retryRequestId, _wordForSelectedSlot(1, 0));
        (,,,,,, eventsExecuted,, randomnessPending) = vault.donationWindow();
        assertEq(eventsExecuted, 0);
        assertFalse(randomnessPending);
        assertEq(emergencyManager.quoteFailureCount(), 1);

        retryRequestId = vault.requestDonationEvent();
        quoter.setQuote(95, false);
        router.setSwapResult(address(usdc), 0, true);
        vm.expectEmit(false, false, false, true);
        emit DonationExecutionFailed(VaultV2.SwapFailed.selector);
        vrf.fulfill(address(vault), retryRequestId, _wordForSelectedSlot(1, 0));
        (,,,,,, eventsExecuted,, randomnessPending) = vault.donationWindow();
        assertEq(eventsExecuted, 0);
        assertFalse(randomnessPending);
        assertEq(emergencyManager.swapFailureCount(), 1);
    }

    function testUnsafePriceEmergencyAndLowBalanceDoNotConsumeCallback() public {
        uint256 requestId = _startWindow(1_000);
        hook.configure(0, 1800 * 500, 0, false);

        vm.expectEmit(false, false, false, true);
        emit DonationExecutionFailed(VaultV2.UnsafePrice.selector);
        vrf.fulfill(address(vault), requestId, _wordForSelectedSlot(1, 0));
        (,,,,,, uint8 eventsExecuted,, bool randomnessPending) = vault.donationWindow();
        assertEq(eventsExecuted, 0);
        assertFalse(randomnessPending);

        hook.configure(0, 0, 0, false);
        requestId = vault.requestDonationEvent();
        emergencyManager.setEmergencyActive(true);
        vm.expectEmit(false, false, false, true);
        emit DonationExecutionFailed(VaultV2.EmegerncyIsActive.selector);
        vrf.fulfill(address(vault), requestId, _wordForSelectedSlot(1, 0));
        (,,,,,, eventsExecuted,, randomnessPending) = vault.donationWindow();
        assertEq(eventsExecuted, 0);
        assertFalse(randomnessPending);
        emergencyManager.setEmergencyActive(false);

        _prepareSuccessfulSwap(95, 95);
        requestId = vault.requestDonationEvent();
        vrf.fulfill(address(vault), requestId, _wordForSelectedSlot(1, 0));
        vm.warp(block.timestamp + 15 days);
        requestId = vault.requestDonationEvent();
        fundraisingToken.burn(address(vault), 975);
        vm.expectEmit(false, false, false, true);
        emit DonationExecutionFailed(VaultV2.InsufficientBalance.selector);
        vrf.fulfill(address(vault), requestId, _wordForSelectedSlot(2, 2));
        assertFalse(vault.canExecuteDonationEvent());
    }

    function testPreservationTreasuryModeBlocksWindowStart() public {
        VaultV2 preservationVault = _deployVault(1 days, beneficiaries, 1);
        vm.prank(address(factory));
        preservationVault.setFundraisingToken(address(fundraisingToken));
        vm.prank(address(factory));
        preservationVault.setHookAddress(address(hook));

        fundraisingToken.mint(address(preservationVault), 40);
        fundraisingToken.mint(address(0xD00D), 960);
        vm.warp(block.timestamp + 1 days);

        assertEq(uint8(preservationVault.currentTreasuryMode()), uint8(VaultV2.TreasuryMode.PRESERVATION));
        vm.expectRevert(VaultV2.PreservationTreasuryReserve.selector);
        preservationVault.startDonationWindow();
    }

    function testPreservationTreasuryModeSkipsFundraisingAndBurnInCallback() public {
        uint256 requestId = _startWindow(1_000);
        fundraisingToken.mint(address(0xD00D), 20_000);

        assertEq(uint8(vault.currentTreasuryMode()), uint8(VaultV2.TreasuryMode.PRESERVATION));
        vm.expectEmit(false, false, false, true);
        emit DonationExecutionFailed(VaultV2.PreservationTreasuryReserve.selector);
        vrf.fulfill(address(vault), requestId, _wordForSelectedSlot(1, 0));

        (,,,,,, uint8 eventsExecuted,, bool randomnessPending) = vault.donationWindow();
        assertEq(eventsExecuted, 0);
        assertFalse(randomnessPending);
        assertEq(fundraisingToken.balanceOf(address(vault)), 1_000);
        assertEq(fundraisingToken.totalSupply(), 21_000);
        assertEq(usdc.balanceOf(beneficiaryA), 0);
    }

    function testConservationModeExecutesFundraisingOnlyWithoutBurn() public {
        VaultV2 conservationVault = _deployVault(1 days, beneficiaries, 1);
        vm.prank(address(factory));
        conservationVault.setFundraisingToken(address(fundraisingToken));
        vm.prank(address(factory));
        conservationVault.setHookAddress(address(hook));

        fundraisingToken.mint(address(conservationVault), 100);
        fundraisingToken.mint(address(0xD00D), 900);
        _prepareSuccessfulSwap(95, 95);
        vm.warp(block.timestamp + 1 days);
        uint256 requestId = conservationVault.startDonationWindow();

        assertEq(uint8(conservationVault.currentTreasuryMode()), uint8(VaultV2.TreasuryMode.CONSERVATION));
        vm.expectEmit(true, true, false, true);
        emit DonationEventExecuted(1, 1, 1, 95);
        vrf.fulfill(address(conservationVault), requestId, _wordForSelectedSlot(1, 0));

        (,,,,,, uint8 eventsExecuted,, bool randomnessPending) = conservationVault.donationWindow();
        assertEq(eventsExecuted, 1);
        assertFalse(randomnessPending);
        assertEq(fundraisingToken.balanceOf(address(conservationVault)), 100);
        assertEq(fundraisingToken.totalSupply(), 1_000);
        assertEq(usdc.balanceOf(beneficiaryA), 31);
    }

    function testNormalModeExecutesFundraisingAndBurn() public {
        uint256 requestId = _startWindow(1_000);
        _prepareSuccessfulSwap(95, 95);

        assertEq(uint8(vault.currentTreasuryMode()), uint8(VaultV2.TreasuryMode.NORMAL));
        vm.expectEmit(true, true, false, true);
        emit DonationEventExecuted(1, 1, 10, 95);
        vm.expectEmit(true, true, false, true);
        emit DonationBurnExecuted(1, 1, 10);
        vrf.fulfill(address(vault), requestId, _wordForSelectedSlot(1, 0));

        assertEq(fundraisingToken.balanceOf(address(vault)), 990);
        assertEq(fundraisingToken.totalSupply(), 990);
        assertEq(usdc.balanceOf(beneficiaryC), 33);
    }

    function testTreasuryModeHysteresisRecoveryThresholds() public {
        VaultV2 hysteresisVault = _deployVault(1 days, beneficiaries, 1);
        vm.prank(address(factory));
        hysteresisVault.setFundraisingToken(address(fundraisingToken));
        vm.prank(address(factory));
        hysteresisVault.setHookAddress(address(hook));

        fundraisingToken.mint(address(hysteresisVault), 40);
        fundraisingToken.mint(address(0xD00D), 960);
        assertEq(uint8(hysteresisVault.syncTreasuryMode()), uint8(VaultV2.TreasuryMode.PRESERVATION));

        fundraisingToken.mint(address(hysteresisVault), 50);
        assertEq(uint8(hysteresisVault.currentTreasuryMode()), uint8(VaultV2.TreasuryMode.PRESERVATION));

        fundraisingToken.mint(address(hysteresisVault), 20);
        assertEq(uint8(hysteresisVault.currentTreasuryMode()), uint8(VaultV2.TreasuryMode.CONSERVATION));
        assertEq(uint8(hysteresisVault.syncTreasuryMode()), uint8(VaultV2.TreasuryMode.CONSERVATION));

        fundraisingToken.mint(address(hysteresisVault), 80);
        assertEq(uint8(hysteresisVault.currentTreasuryMode()), uint8(VaultV2.TreasuryMode.CONSERVATION));

        fundraisingToken.mint(address(hysteresisVault), 80);
        assertEq(uint8(hysteresisVault.currentTreasuryMode()), uint8(VaultV2.TreasuryMode.NORMAL));
    }

    function testExpiredIncompleteWindowCanRestartAfterTreasuryRecovers() public {
        uint256 requestId = _startWindow(1_000);
        fundraisingToken.burn(address(vault), 985);

        vm.expectEmit(false, false, false, true);
        emit DonationExecutionFailed(VaultV2.InsufficientBalance.selector);
        vrf.fulfill(address(vault), requestId, _wordForSelectedSlot(1, 0));

        vm.warp(block.timestamp + vault.DONATION_WINDOW() + 1);
        fundraisingToken.mint(address(vault), 1_000);

        assertTrue(vault.canStartDonationWindow());
        uint256 newRequestId = vault.startDonationWindow();
        (uint64 cycleId,,,,, uint128 snapshotBalance, uint8 eventsExecuted,, bool randomnessPending) =
            vault.donationWindow();

        assertEq(cycleId, 2);
        assertEq(snapshotBalance, 1_015);
        assertEq(eventsExecuted, 0);
        assertTrue(randomnessPending);
        assertEq(newRequestId, 2);
    }

    function testEndpointFailureRecordingCanFailWithoutBlockingRetry() public {
        uint256 requestId = _startWindow(1_000);
        emergencyManager.setEndpointFailureShouldRevert(true);
        hook.configure(0, 0, 0, true);

        vm.expectEmit(false, false, false, true);
        emit DonationExecutionFailed(VaultV2.SellCheckFailed.selector);
        vrf.fulfill(address(vault), requestId, _wordForSelectedSlot(1, 0));

        (,,,,,, uint8 eventsExecuted,, bool randomnessPending) = vault.donationWindow();
        assertEq(eventsExecuted, 0);
        assertFalse(randomnessPending);
        assertEq(emergencyManager.lastEndpointFailure(), 0);
        (bool upkeepNeeded, bytes memory performData) = vault.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertEq(abi.decode(performData, (uint8)), UPKEEP_REQUEST_DONATION_EVENT);
    }

    function testCannotStartNextWindowUntilPreviousCompletesThenIntervalPasses() public {
        uint256 requestId = _startWindow(1_000);
        _prepareSuccessfulSwap(95, 190);
        vrf.fulfill(address(vault), requestId, _wordForSelectedSlot(1, 0));

        vm.warp(block.timestamp + 15 days);
        uint256 secondRequestId = vault.requestDonationEvent();
        vm.expectRevert(VaultV2.WindowAlreadyActive.selector);
        vault.startDonationWindow();

        vrf.fulfill(address(vault), secondRequestId, _wordForSelectedSlot(2, 2));
        assertFalse(vault.canStartDonationWindow());

        vm.warp(block.timestamp + 1 days);
        fundraisingToken.mint(address(vault), 1_000);
        assertTrue(vault.canStartDonationWindow());
        assertEq(vault.startDonationWindow(), 3);
    }

    function testOnlySelfOnlyFactoryAndReadHelpers() public {
        vm.expectRevert(VaultV2.OnlySelf.selector);
        vault.quoteFundraisingTokenSwap(1);

        vm.expectRevert(VaultV2.OnlySelf.selector);
        vault.swapFundraisingToken(1, 1);

        vm.expectRevert(VaultV2.OnlySelf.selector);
        vault.checkShouldAllowSell();

        vm.expectRevert(VaultV2.NotFactory.selector);
        vault.setHookAddress(address(0x1234));

        vm.expectRevert(VaultV2.NotFactory.selector);
        vault.setFundraisingToken(address(0x5678));

        _setPoolKey(address(usdc), address(fundraisingToken));
        hook.configure(0, 0, 500, false);
        assertFalse(vault.shouldAllowSell());

        hook.configure(0, 0, 100, false);
        assertTrue(vault.shouldAllowSell());

        VaultV2 noHookVault = _deployVault(1 days, beneficiaries, 100);
        vm.prank(address(factory));
        noHookVault.setFundraisingToken(address(fundraisingToken));
        vm.expectRevert(VaultV2.HookNotConfigured.selector);
        noHookVault.shouldAllowSell();
    }

    function testCanStartDonationWindowReflectsState() public {
        assertFalse(vault.canStartDonationWindow());

        vm.warp(block.timestamp + 1 days);
        assertFalse(vault.canStartDonationWindow());

        fundraisingToken.mint(address(vault), 100);
        assertTrue(vault.canStartDonationWindow());

        emergencyManager.setEmergencyActive(true);
        assertFalse(vault.canStartDonationWindow());
    }

    function testCanStartDonationWindowReturnsFalseWhenTokenOrHookMissing() public {
        VaultV2 missingTokenVault = _deployVault(1 days, beneficiaries, 100);
        vm.warp(block.timestamp + 1 days);
        assertFalse(missingTokenVault.canStartDonationWindow());

        VaultV2 missingHookVault = _deployVault(1 days, beneficiaries, 100);
        vm.prank(address(factory));
        missingHookVault.setFundraisingToken(address(fundraisingToken));
        fundraisingToken.mint(address(missingHookVault), 100);
        assertFalse(missingHookVault.canStartDonationWindow());
    }

    function testZeroTrancheAmountRevertsDuringEligibility() public {
        VaultV2 tinyVault = _deployVault(1 days, beneficiaries, 1);
        vm.prank(address(factory));
        tinyVault.setFundraisingToken(address(fundraisingToken));
        vm.prank(address(factory));
        tinyVault.setHookAddress(address(hook));
        vm.warp(block.timestamp + 1 days);
        fundraisingToken.mint(address(tinyVault), 1);
        uint256 requestId = tinyVault.startDonationWindow();
        vrf.fulfill(address(tinyVault), requestId, 1);

        assertFalse(tinyVault.canExecuteDonationEvent());
        (bool upkeepNeeded,) = tinyVault.checkUpkeep("");
        assertFalse(upkeepNeeded);
    }

    function _startWindow(uint256 balance) internal returns (uint256 requestId) {
        vm.warp(block.timestamp + 1 days);
        fundraisingToken.mint(address(vault), balance);
        requestId = vault.startDonationWindow();
    }

    function _prepareSuccessfulSwap(uint256 quotedAmountOut, uint256 routerBalance) internal {
        quoter.setQuote(quotedAmountOut, false);
        router.setSwapResult(address(usdc), quotedAmountOut, false);
        usdc.mint(address(router), routerBalance);
    }

    function _wordForSelectedSlot(uint8 eventIndex, uint8 targetSlot) internal pure returns (uint256 word) {
        (uint8 startSlot, uint8 endSlot) = eventIndex == 1 ? (uint8(0), uint8(1)) : (uint8(2), uint8(3));
        for (uint256 i; i < 10_000; ++i) {
            uint256 secondWord = uint256(keccak256(abi.encode(i)));
            uint256 seed = uint256(keccak256(abi.encode(i, secondWord, uint64(1), eventIndex)));
            uint8 selectedSlot = uint8(startSlot + (seed % (uint256(endSlot) - startSlot + 1)));
            if (selectedSlot == targetSlot) return i;
        }
        revert("word not found");
    }

    function _deployVault(uint256 intervalSeconds, address[] memory vaultBeneficiaries, uint256 minBalance)
        internal
        returns (VaultV2)
    {
        return new VaultV2(
            address(usdc),
            intervalSeconds,
            vaultBeneficiaries,
            address(registry),
            address(emergencyManager),
            minBalance,
            address(factory),
            _vrfConfig(),
            _slotConfig()
        );
    }

    function _deployVaultWithSlotConfig(VaultV2.SlotConfig memory slotConfig) internal returns (VaultV2) {
        return new VaultV2(
            address(usdc),
            1 days,
            beneficiaries,
            address(registry),
            address(emergencyManager),
            100,
            address(factory),
            _vrfConfig(),
            slotConfig
        );
    }

    function _vrfConfig() internal view returns (VaultV2.VrfConfig memory) {
        return VaultV2.VrfConfig({
            coordinator: address(vrf),
            keyHash: keyHash,
            subscriptionId: 1,
            requestConfirmations: 3,
            callbackGasLimit: 500_000
        });
    }

    function _slotConfig() internal pure returns (VaultV2.SlotConfig memory) {
        return VaultV2.SlotConfig({
            slotsPerWindow: 4,
            firstEventStartSlot: 0,
            firstEventEndSlot: 1,
            secondEventStartSlot: 2,
            secondEventEndSlot: 3
        });
    }

    function _setPoolKey(address currency0, address currency1) internal {
        factory.setPoolKey(
            PoolKey({
                currency0: Currency.wrap(currency0),
                currency1: Currency.wrap(currency1),
                fee: 0,
                tickSpacing: 1,
                hooks: IHooks(address(0))
            })
        );
    }
}
