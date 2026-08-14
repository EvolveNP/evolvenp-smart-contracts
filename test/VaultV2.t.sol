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
        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = word;
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
    event DonationEventExecuted(uint64 indexed cycleId, uint8 indexed eventIndex, uint256 amountIn, uint256 amountOut);
    event DonationExecutionFailed(bytes4 reason);

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
            validVrf
        );

        vm.expectRevert(Swap.ZeroAddress.selector);
        new VaultV2(
            address(usdc), 1 days, beneficiaries, address(registry), address(0), 100, address(factory), validVrf
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
            validVrf
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
            validVrf
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
            _vrfConfig()
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
            invalidVrf
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
            invalidVrf
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
            invalidVrf
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

    function testStartDonationWindowRequestsFirstVrfWithoutSavingEventTime() public {
        vm.warp(block.timestamp + 1 days + 1);
        fundraisingToken.mint(address(vault), 1_000);

        vm.expectEmit(true, true, true, true);
        emit DonationEventRandomnessRequested(1, 1, 1, uint64(block.timestamp));
        vm.expectEmit(true, true, false, true);
        emit DonationWindowStarted(1, 1, uint64(block.timestamp), uint64(block.timestamp + 7 days), 1_000);

        uint256 requestId = vault.startDonationWindow();
        (
            uint64 cycleId,
            uint64 startsAt,
            uint64 endsAt,
            uint64 lastRequestAt,
            uint64 lastEventAt,
            uint128 snapshotBalance,
            uint8 eventsExecuted,
            bool randomnessPending
        ) = vault.donationWindow();
        (uint64 requestCycleId, uint8 eventIndex) = vault.requestById(requestId);

        assertEq(requestId, 1);
        assertEq(cycleId, 1);
        assertEq(startsAt, block.timestamp);
        assertEq(endsAt, block.timestamp + 7 days);
        assertEq(lastRequestAt, block.timestamp);
        assertEq(lastEventAt, 0);
        assertEq(snapshotBalance, 1_000);
        assertEq(eventsExecuted, 0);
        assertTrue(randomnessPending);
        assertEq(requestCycleId, 1);
        assertEq(eventIndex, 1);
        assertEq(vrf.lastKeyHash(), keyHash);
        assertEq(vrf.lastSubId(), 1);
        assertEq(vrf.lastConfirmations(), 3);
        assertEq(vrf.lastCallbackGasLimit(), 500_000);
        assertEq(vrf.lastNumWords(), 1);
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
        vm.prank(address(factory));
        invalidPoolVault.setFundraisingToken(address(fundraisingToken));
        vm.prank(address(factory));
        invalidPoolVault.setHookAddress(address(hook));
        fundraisingToken.mint(address(invalidPoolVault), 100);
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

    function testVrfFulfillmentExecutesFirstDonationImmediately() public {
        uint256 requestId = _startWindow(1_000);
        _prepareSuccessfulSwap(95, 95);

        vm.expectEmit(true, true, false, true);
        emit DonationEventExecuted(1, 1, 10, 95);
        vrf.fulfill(address(vault), requestId, 123);

        (,,,, uint64 lastEventAt,, uint8 eventsExecuted, bool randomnessPending) = vault.donationWindow();
        assertEq(lastEventAt, block.timestamp);
        assertEq(eventsExecuted, 1);
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
        assertFalse(vault.canExecuteDonationEvent());
    }

    function testSecondDonationRequiresSpacingAndFreshVrfRequest() public {
        uint256 requestId = _startWindow(1_000);
        _prepareSuccessfulSwap(95, 190);
        vrf.fulfill(address(vault), requestId, 123);

        vm.expectRevert(VaultV2.EventNotEligible.selector);
        vault.requestDonationEvent();

        vm.warp(block.timestamp + vault.MIN_EVENT_SPACING());
        assertTrue(vault.canExecuteDonationEvent());

        vm.expectEmit(true, true, true, true);
        emit DonationEventRandomnessRequested(1, 2, 2, uint64(block.timestamp));
        uint256 secondRequestId = vault.requestDonationEvent();
        assertEq(secondRequestId, 2);
        assertFalse(vault.canExecuteDonationEvent());

        vm.expectEmit(true, true, false, true);
        emit DonationEventExecuted(1, 2, 10, 95);
        vrf.fulfill(address(vault), secondRequestId, 456);

        (,,,,,, uint8 eventsExecuted, bool randomnessPending) = vault.donationWindow();
        assertEq(eventsExecuted, 2);
        assertFalse(randomnessPending);
        assertEq(usdc.balanceOf(beneficiaryA), 62);
        assertEq(usdc.balanceOf(beneficiaryB), 62);
        assertEq(usdc.balanceOf(beneficiaryC), 66);
        assertFalse(vault.canExecuteDonationEvent());
    }

    function testDonationFailuresDoNotConsumeTrancheAndCanRequestAgain() public {
        uint256 requestId = _startWindow(1_000);

        hook.configure(0, 0, 0, true);
        vm.expectEmit(false, false, false, true);
        emit DonationExecutionFailed(VaultV2.SellCheckFailed.selector);
        vrf.fulfill(address(vault), requestId, 1);
        (,,,,,, uint8 eventsExecuted, bool randomnessPending) = vault.donationWindow();
        assertEq(eventsExecuted, 0);
        assertFalse(randomnessPending);
        assertEq(emergencyManager.lastEndpointFailure(), uint8(IIntegrationRegistry.Endpoint.STATE_VIEW));
        assertTrue(vault.canExecuteDonationEvent());

        hook.configure(0, 0, 0, false);
        uint256 retryRequestId = vault.requestDonationEvent();
        quoter.setQuote(0, true);
        vm.expectEmit(false, false, false, true);
        emit DonationExecutionFailed(VaultV2.QuoteFailed.selector);
        vrf.fulfill(address(vault), retryRequestId, 2);
        (,,,,,, eventsExecuted, randomnessPending) = vault.donationWindow();
        assertEq(eventsExecuted, 0);
        assertFalse(randomnessPending);
        assertEq(emergencyManager.quoteFailureCount(), 1);

        retryRequestId = vault.requestDonationEvent();
        quoter.setQuote(95, false);
        router.setSwapResult(address(usdc), 0, true);
        vm.expectEmit(false, false, false, true);
        emit DonationExecutionFailed(VaultV2.SwapFailed.selector);
        vrf.fulfill(address(vault), retryRequestId, 3);
        (,,,,,, eventsExecuted, randomnessPending) = vault.donationWindow();
        assertEq(eventsExecuted, 0);
        assertFalse(randomnessPending);
        assertEq(emergencyManager.swapFailureCount(), 1);
    }

    function testUnsafePriceEmergencyAndLowBalanceDoNotConsumeCallback() public {
        uint256 requestId = _startWindow(1_000);
        hook.configure(0, 1800 * 500, 0, false);

        vm.expectEmit(false, false, false, true);
        emit DonationExecutionFailed(VaultV2.UnsafePrice.selector);
        vrf.fulfill(address(vault), requestId, 1);
        (,,,,,, uint8 eventsExecuted, bool randomnessPending) = vault.donationWindow();
        assertEq(eventsExecuted, 0);
        assertFalse(randomnessPending);

        hook.configure(0, 0, 0, false);
        requestId = vault.requestDonationEvent();
        emergencyManager.setEmergencyActive(true);
        vm.expectEmit(false, false, false, true);
        emit DonationExecutionFailed(VaultV2.EmegerncyIsActive.selector);
        vrf.fulfill(address(vault), requestId, 2);
        (,,,,,, eventsExecuted, randomnessPending) = vault.donationWindow();
        assertEq(eventsExecuted, 0);
        assertFalse(randomnessPending);
        emergencyManager.setEmergencyActive(false);

        requestId = vault.requestDonationEvent();
        fundraisingToken.burn(address(vault), 991);
        vm.expectEmit(false, false, false, true);
        emit DonationExecutionFailed(VaultV2.InsufficientBalance.selector);
        vrf.fulfill(address(vault), requestId, 3);
        (,,,,,, eventsExecuted, randomnessPending) = vault.donationWindow();
        assertEq(eventsExecuted, 0);
        assertFalse(randomnessPending);
    }

    function testEndpointFailureRecordingCanFailWithoutBlockingRetry() public {
        uint256 requestId = _startWindow(1_000);
        emergencyManager.setEndpointFailureShouldRevert(true);
        hook.configure(0, 0, 0, true);

        vm.expectEmit(false, false, false, true);
        emit DonationExecutionFailed(VaultV2.SellCheckFailed.selector);
        vrf.fulfill(address(vault), requestId, 1);

        (,,,,,, uint8 eventsExecuted, bool randomnessPending) = vault.donationWindow();
        assertEq(eventsExecuted, 0);
        assertFalse(randomnessPending);
        assertEq(emergencyManager.lastEndpointFailure(), 0);
        assertTrue(vault.canExecuteDonationEvent());
    }

    function testCannotStartNextWindowUntilPreviousCompletesThenIntervalPasses() public {
        uint256 requestId = _startWindow(1_000);
        _prepareSuccessfulSwap(95, 190);
        vrf.fulfill(address(vault), requestId, 1);

        vm.warp(block.timestamp + vault.MIN_EVENT_SPACING());
        uint256 secondRequestId = vault.executeDonationEvent();
        vm.expectRevert(VaultV2.WindowAlreadyActive.selector);
        vault.startDonationWindow();

        vrf.fulfill(address(vault), secondRequestId, 2);
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

        vm.expectRevert(VaultV2.ZeroSwapAmount.selector);
        tinyVault.canExecuteDonationEvent();
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
            _vrfConfig()
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
