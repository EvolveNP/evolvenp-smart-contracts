// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Vault} from "../src/Vault.sol";
import {IIntegrationRegistry} from "../src/interfaces/IIntegrationRegistry.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";

contract MockERC20Token is ERC20 {
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
}

contract MockVaultEmergencyManager {
    bool internal emergencyActive;
    uint256 public quoteFailureCount;
    uint256 public quoteSuccessCount;
    uint256 public swapFailureCount;
    uint256 public swapSuccessCount;
    uint8 public lastEndpointFailure;

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
        lastEndpointFailure = endpoint;
    }
}

contract MockVaultPermit2 {
    function approve(address, address, uint160, uint48) external {}
}

contract MockVaultQuoter {
    bool internal shouldRevert;
    uint256 internal amountOut;

    function setQuote(uint256 newAmountOut, bool revertQuote) external {
        amountOut = newAmountOut;
        shouldRevert = revertQuote;
    }

    function quoteExactInputSingle(IV4Quoter.QuoteExactSingleParams calldata)
        external
        view
        returns (uint256 quotedAmountOut, uint256 gasEstimate)
    {
        if (shouldRevert) revert("quote failed");
        return (amountOut, 0);
    }
}

contract MockVaultRouter {
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

contract MockVaultIntegrationRegistry {
    address public router;
    address public permit2;
    address public quoter;

    constructor(address _router, address _permit2, address _quoter) {
        router = _router;
        permit2 = _permit2;
        quoter = _quoter;
    }
}

contract MockVaultFactory {
    PoolKey internal poolKey;

    function setPoolKey(PoolKey memory newPoolKey) external {
        poolKey = newPoolKey;
    }

    function getPoolKeys(address) external view returns (PoolKey memory) {
        return poolKey;
    }
}

contract MockVaultHook {
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

contract VaultTest is Test {
    MockERC20Token internal fundraisingToken;
    MockERC20Token internal usdc;
    MockVaultEmergencyManager internal emergencyManager;
    MockVaultPermit2 internal permit2;
    MockVaultQuoter internal quoter;
    MockVaultRouter internal router;
    MockVaultIntegrationRegistry internal registry;
    MockVaultFactory internal factory;
    MockVaultHook internal hook;
    Vault internal vault;

    address[] internal beneficiaries;
    address internal beneficiaryA = address(0xA1);
    address internal beneficiaryB = address(0xB2);
    address internal beneficiaryC = address(0xC3);

    function setUp() public {
        fundraisingToken = new MockERC20Token("Fund", "FUND", 6);
        usdc = new MockERC20Token("USD Coin", "USDC", 6);
        emergencyManager = new MockVaultEmergencyManager();
        permit2 = new MockVaultPermit2();
        quoter = new MockVaultQuoter();
        router = new MockVaultRouter();
        registry = new MockVaultIntegrationRegistry(address(router), address(permit2), address(quoter));
        factory = new MockVaultFactory();
        hook = new MockVaultHook();

        beneficiaries.push(beneficiaryA);
        beneficiaries.push(beneficiaryB);
        beneficiaries.push(beneficiaryC);

        vault = new Vault(
            address(usdc),
            1 days,
            beneficiaries,
            5e17,
            address(registry),
            address(emergencyManager),
            100,
            address(factory)
        );

        vm.prank(address(factory));
        vault.setFundraisingToken(address(fundraisingToken));
        vm.prank(address(factory));
        vault.setHookAddress(address(hook));

        factory.setPoolKey(
            PoolKey({
                currency0: Currency.wrap(address(fundraisingToken)),
                currency1: Currency.wrap(address(usdc)),
                fee: 0,
                tickSpacing: 1,
                hooks: IHooks(address(0))
            })
        );
    }

    function testExecuteMonthlyEventRevertsWhenEmergencyIsActive() public {
        emergencyManager.setEmergencyActive(true);

        vm.expectRevert(Vault.EmegerncyIsActive.selector);
        vault.executeMonthlyEvent();
    }

    function testExecuteMonthlyEventRevertsWhenNotDue() public {
        vm.expectRevert(Vault.NotDue.selector);
        vault.executeMonthlyEvent();
    }

    function testExecuteMonthlyEventRevertsWhenBalanceIsTooLow() public {
        vm.warp(block.timestamp + 1 days);

        vm.expectRevert(Vault.InsufficientBalance.selector);
        vault.executeMonthlyEvent();
    }

    function testExecuteMonthlyEventRecordsEndpointFailureWhenSellCheckReverts() public {
        vm.warp(block.timestamp + 1 days);
        fundraisingToken.mint(address(vault), 100);
        hook.configure(0, 0, 0, true);

        vm.expectCall(
            address(emergencyManager),
            abi.encodeCall(
                MockVaultEmergencyManager.recordEndpointFailure, (uint8(IIntegrationRegistry.Endpoint.STATE_VIEW))
            )
        );

        vm.expectRevert(Vault.SellCheckFailed.selector);
        vault.executeMonthlyEvent();
    }

    function testExecuteMonthlyEventRevertsWhenPriceIsUnsafe() public {
        vm.warp(block.timestamp + 1 days);
        fundraisingToken.mint(address(vault), 100);
        hook.configure(0, 1800 * 500, 0, false);

        vm.expectRevert(Vault.UnsafePrice.selector);
        vault.executeMonthlyEvent();
    }

    function testExecuteMonthlyEventRecordsQuoteFailure() public {
        vm.warp(block.timestamp + 1 days);
        fundraisingToken.mint(address(vault), 200);
        hook.configure(0, 0, 0, false);
        quoter.setQuote(0, true);

        vm.expectRevert(Vault.QuoteFailed.selector);
        vault.executeMonthlyEvent();
    }

    function testExecuteMonthlyEventRecordsQuoteAndSwapSuccess() public {
        vm.warp(block.timestamp + 1 days);
        fundraisingToken.mint(address(vault), 200);
        hook.configure(0, 0, 0, false);
        quoter.setQuote(95, false);
        router.setSwapResult(address(usdc), 95, false);
        usdc.mint(address(router), 95);

        vault.executeMonthlyEvent();

        assertEq(emergencyManager.quoteSuccessCount(), 1);
        assertEq(emergencyManager.swapSuccessCount(), 1);
        assertEq(emergencyManager.quoteFailureCount(), 0);
        assertEq(emergencyManager.swapFailureCount(), 0);
    }

    function testExecuteMonthlyEventRecordsSwapFailure() public {
        vm.warp(block.timestamp + 1 days);
        fundraisingToken.mint(address(vault), 200);
        hook.configure(0, 0, 0, false);
        quoter.setQuote(150, false);
        router.setSwapResult(address(usdc), 0, true);

        vm.expectRevert(Vault.SwapFailed.selector);
        vault.executeMonthlyEvent();
    }

    function testExecuteMonthlyEventRevertsWhenSwapAmountRoundsToZero() public {
        address[] memory oneBeneficiary = new address[](1);
        oneBeneficiary[0] = beneficiaryA;

        Vault smallVault = new Vault(
            address(usdc), 1 days, oneBeneficiary, 1, address(registry), address(emergencyManager), 1, address(factory)
        );

        vm.prank(address(factory));
        smallVault.setFundraisingToken(address(fundraisingToken));
        vm.prank(address(factory));
        smallVault.setHookAddress(address(hook));

        vm.warp(block.timestamp + 1 days);
        fundraisingToken.mint(address(smallVault), 1);
        hook.configure(0, 0, 0, false);

        vm.expectRevert(Vault.ZeroSwapAmount.selector);
        smallVault.executeMonthlyEvent();
    }

    function testExecuteMonthlyEventRevertsWithoutBeneficiaries() public {
        Vault emptyVault = new Vault(
            address(usdc),
            1 days,
            new address[](0),
            1e18,
            address(registry),
            address(emergencyManager),
            1,
            address(factory)
        );

        vm.prank(address(factory));
        emptyVault.setFundraisingToken(address(fundraisingToken));
        vm.prank(address(factory));
        emptyVault.setHookAddress(address(hook));

        vm.warp(block.timestamp + 1 days);
        fundraisingToken.mint(address(emptyVault), 10);
        hook.configure(0, 0, 0, false);
        quoter.setQuote(9, false);
        router.setSwapResult(address(usdc), 9, false);
        usdc.mint(address(router), 9);

        vm.expectRevert(Vault.NoBeneficiaries.selector);
        emptyVault.executeMonthlyEvent();
    }

    function testExecuteMonthlyEventSwapsAndSplitsProceedsWithRemainder() public {
        vm.warp(block.timestamp + 1 days);
        fundraisingToken.mint(address(vault), 200);
        hook.configure(0, 0, 0, false);
        quoter.setQuote(95, false);
        router.setSwapResult(address(usdc), 95, false);
        usdc.mint(address(router), 95);

        vault.executeMonthlyEvent();

        assertEq(usdc.balanceOf(beneficiaryA), 31);
        assertEq(usdc.balanceOf(beneficiaryB), 31);
        assertEq(usdc.balanceOf(beneficiaryC), 33);
        assertEq(vault.lastSuccessAt(), block.timestamp);
    }

    function testIsDueReflectsState() public {
        assertFalse(vault.isDue());

        vm.warp(block.timestamp + 1 days);
        fundraisingToken.mint(address(vault), 100);
        assertTrue(vault.isDue());

        emergencyManager.setEmergencyActive(true);
        assertFalse(vault.isDue());
    }

    function testQuoteSwapAndSellCheckAreOnlySelf() public {
        vm.expectRevert(Vault.OnlySelf.selector);
        vault.quoteFundraisingTokenSwap(1);

        vm.expectRevert(Vault.OnlySelf.selector);
        vault.swapFundraisingToken(1, 1);

        vm.expectRevert(Vault.OnlySelf.selector);
        vault.checkShouldAllowSell();
    }

    function testSettersAreOnlyFactory() public {
        vm.expectRevert(Vault.NotFactory.selector);
        vault.setHookAddress(address(0x1234));

        vm.expectRevert(Vault.NotFactory.selector);
        vault.setFundraisingToken(address(0x5678));
    }

    function testShouldAllowSellHandlesFundraisingTokenAsCurrencyOne() public {
        factory.setPoolKey(
            PoolKey({
                currency0: Currency.wrap(address(usdc)),
                currency1: Currency.wrap(address(fundraisingToken)),
                fee: 0,
                tickSpacing: 1,
                hooks: IHooks(address(0))
            })
        );

        hook.configure(0, 0, 500, false);
        assertFalse(vault.shouldAllowSell());

        hook.configure(0, 0, 100, false);
        assertTrue(vault.shouldAllowSell());
    }
}
