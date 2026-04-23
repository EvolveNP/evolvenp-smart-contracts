// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {FundraisingTokenHook} from "../src/FundraisingTokenHook.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IFactory} from "../src/interfaces/IFactory.sol";

contract MockHookToken is ERC20 {
    constructor() ERC20("Fund", "FUND") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ZeroSupplyHookToken is ERC20 {
    constructor() ERC20("Zero", "ZERO") {}
}

contract MockHookPoolManager {
    address public lastTakeCurrency;
    address public lastTakeTo;
    uint256 public lastTakeAmount;

    function take(Currency currency, address to, uint256 amount) external {
        lastTakeCurrency = Currency.unwrap(currency);
        lastTakeTo = to;
        lastTakeAmount = amount;
    }
}

contract MockHookStateView {
    int24 internal currentTick;
    uint128 internal currentLiquidity;

    function setState(int24 tick_, uint128 liquidity_) external {
        currentTick = tick_;
        currentLiquidity = liquidity_;
    }

    function getSlot0(PoolId) external view returns (uint160, int24, uint24, uint24) {
        return (0, currentTick, 0, 0);
    }

    function getLiquidity(PoolId) external view returns (uint128) {
        return currentLiquidity;
    }
}

contract MockHookRegistry {
    address public router;
    address public permit2;
    address public quoter;
    address public poolManager;
    address public positionManager;
    address public stateView;
    address public hookDeployer;
    address public emergencyManager;

    constructor(address router_, address quoter_, address stateView_) {
        router = router_;
        quoter = quoter_;
        stateView = stateView_;
    }
}

contract MockHookFactory {
    mapping(address => IFactory.FundraisingProtocol) internal protocols;

    function setProtocol(IFactory.FundraisingProtocol memory protocol) external {
        protocols[protocol.fundraisingToken] = protocol;
    }

    function getProtocol(address fundraisingToken) external view returns (IFactory.FundraisingProtocol memory) {
        return protocols[fundraisingToken];
    }
}

contract MockMsgSender {
    address internal nextSender;

    function setMsgSender(address sender_) external {
        nextSender = sender_;
    }

    function msgSender() external view returns (address) {
        return nextSender;
    }
}

contract FundraisingTokenHookHarness is FundraisingTokenHook {
    constructor(address poolManager, address factoryAddress, address usdc, address registry)
        FundraisingTokenHook(poolManager, factoryAddress, usdc, registry)
    {}

    function validateHookAddress(BaseHook) internal pure override {}

    function exposedBeforeInitialize(PoolKey calldata key, uint160 price) external returns (bytes4) {
        return _beforeInitialize(address(0), key, price);
    }

    function exposedAfterInitialize(PoolKey calldata key, uint160 price, int24 tick) external returns (bytes4) {
        return _afterInitialize(address(0), key, price, tick);
    }

    function exposedBeforeAddLiquidity(
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4) {
        return _beforeAddLiquidity(address(0), key, params, hookData);
    }

    function exposedBeforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4, BeforeSwapDelta, uint24) {
        return _beforeSwap(sender, key, params, hookData);
    }

    function exposedAfterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4, int128) {
        return _afterSwap(sender, key, params, delta, hookData);
    }

    function exposedTreasuryBalancePercent(PoolKey calldata key) external view returns (uint256) {
        return getTreasuryBalanceInPerecent(key);
    }

    function exposedCheckIfTaxIncurred(PoolKey calldata key, address sender) external view returns (bool) {
        return checkIfTaxIncurred(key, sender);
    }

    function exposedGetMsgSender(address sender) external view returns (address) {
        return getMsgSender(sender);
    }
}

contract FundraisingTokenHookTest is Test {
    using BalanceDeltaLibrary for BalanceDelta;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    MockHookToken internal token;
    MockHookPoolManager internal poolManager;
    MockHookStateView internal stateView;
    MockMsgSender internal router;
    MockMsgSender internal quoter;
    MockHookRegistry internal registry;
    MockHookFactory internal factory;
    FundraisingTokenHookHarness internal hook;
    MockHookToken internal usdc;

    address internal vault = address(0xA11CE);
    address internal user = address(0xB0B);

    function setUp() public {
        token = new MockHookToken();
        poolManager = new MockHookPoolManager();
        stateView = new MockHookStateView();
        router = new MockMsgSender();
        quoter = new MockMsgSender();
        factory = new MockHookFactory();
        usdc = new MockHookToken();
        registry = new MockHookRegistry(address(router), address(quoter), address(stateView));

        hook = new FundraisingTokenHookHarness(address(poolManager), address(factory), address(usdc), address(registry));
        factory.setProtocol(
            IFactory.FundraisingProtocol({
                fundraisingToken: address(token),
                underlyingAddress: address(usdc),
                vault: vault,
                hook: address(hook),
                isLPCreated: true
            })
        );

        token.mint(user, 1_000_000 ether);
        stateView.setState(0, 1_000_000);
    }

    function testConstructorAndPermissions() public view {
        assertEq(hook.factoryAddress(), address(factory));
        assertEq(hook.usdcAddress(), address(usdc));
        assertEq(hook.router(), address(router));
        assertEq(hook.quoter(), address(quoter));
        assertEq(hook.stateView(), address(stateView));

        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.beforeInitialize);
        assertTrue(permissions.afterInitialize);
        assertTrue(permissions.beforeAddLiquidity);
        assertTrue(permissions.beforeSwap);
        assertTrue(permissions.afterSwap);
        assertTrue(permissions.beforeSwapReturnDelta);
        assertTrue(permissions.afterSwapReturnDelta);
        assertFalse(permissions.beforeDonate);
    }

    function testObserveAndGetCurrentTick() public {
        PoolKey memory key = _poolKey(address(token), address(usdc));
        hook.exposedAfterInitialize(key, 0, 5);

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 0;
        secondsAgos[1] = 0;

        (int48[] memory tickCumulatives, uint144[] memory liquidityCumulatives) = hook.observe(key, secondsAgos);
        assertEq(tickCumulatives.length, 2);
        assertEq(liquidityCumulatives.length, 2);
        assertEq(hook.getCurrentTick(key), 0);
    }

    function testBeforeInitializeRejectsNonOraclePoolConfig() public {
        PoolKey memory invalidFee = PoolKey({
            currency0: Currency.wrap(address(token)),
            currency1: Currency.wrap(address(usdc)),
            fee: 1,
            tickSpacing: TickMath.MAX_TICK_SPACING,
            hooks: IHooks(address(0))
        });

        vm.expectRevert(FundraisingTokenHook.OnlyOneOraclePoolAllowed.selector);
        hook.exposedBeforeInitialize(invalidFee, 0);
    }

    function testBeforeInitializeAcceptsOraclePoolConfig() public {
        PoolKey memory key = _poolKey(address(token), address(usdc));
        assertEq(hook.exposedBeforeInitialize(key, 0), BaseHook.beforeInitialize.selector);
    }

    function testBeforeAddLiquidityBranches() public {
        PoolKey memory key = _poolKey(address(token), address(usdc));
        hook.exposedAfterInitialize(key, 0, 0);

        ModifyLiquidityParams memory negativeDelta =
            ModifyLiquidityParams({tickLower: 0, tickUpper: 0, liquidityDelta: -1, salt: bytes32(0)});
        vm.expectRevert(FundraisingTokenHook.OraclePoolMustLockLiquidity.selector);
        hook.exposedBeforeAddLiquidity(key, negativeDelta, bytes(""));

        ModifyLiquidityParams memory wrongRange =
            ModifyLiquidityParams({tickLower: 0, tickUpper: 1, liquidityDelta: 1, salt: bytes32(0)});
        vm.expectRevert(FundraisingTokenHook.OraclePositionsMustBeFullRange.selector);
        hook.exposedBeforeAddLiquidity(key, wrongRange, bytes(""));

        int24 maxTickSpacing = TickMath.MAX_TICK_SPACING;
        ModifyLiquidityParams memory valid = ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(maxTickSpacing),
            tickUpper: TickMath.maxUsableTick(maxTickSpacing),
            liquidityDelta: 1,
            salt: bytes32(0)
        });
        assertEq(hook.exposedBeforeAddLiquidity(key, valid, bytes("")), BaseHook.beforeAddLiquidity.selector);
    }

    function testBeforeSwapNonSellingPathDoesNotTakeFee() public {
        PoolKey memory key = _poolKey(address(token), address(usdc));
        hook.exposedAfterInitialize(key, 0, 0);

        SwapParams memory params = SwapParams({zeroForOne: false, amountSpecified: -100 ether, sqrtPriceLimitX96: 0});
        (, BeforeSwapDelta delta,) = hook.exposedBeforeSwap(user, key, params, bytes(""));

        assertEq(int256(delta.getSpecifiedDelta()), 0);
        assertEq(poolManager.lastTakeAmount(), 0);
    }

    function testBeforeSwapSellingPathTakesFee() public {
        PoolKey memory key = _poolKey(address(token), address(usdc));
        hook.exposedAfterInitialize(key, 0, 0);

        vm.roll(block.number + 20);
        vm.warp(block.timestamp + 2 hours);

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: 0});
        (, BeforeSwapDelta delta,) = hook.exposedBeforeSwap(user, key, params, bytes(""));

        assertEq(int256(delta.getSpecifiedDelta()), int256(1 ether));
        assertEq(poolManager.lastTakeCurrency(), address(token));
        assertEq(poolManager.lastTakeTo(), vault);
        assertEq(poolManager.lastTakeAmount(), 1 ether);
    }

    function testBeforeSwapRejectsOversizedFeeCast() public {
        PoolKey memory key = _poolKey(address(token), address(usdc));
        hook.exposedAfterInitialize(key, 0, 0);

        vm.roll(block.number + 20);
        vm.warp(block.timestamp + 2 hours);

        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: int256(1 << 134), sqrtPriceLimitX96: 0});
        vm.expectRevert(FundraisingTokenHook.FeeToLarge.selector);
        hook.exposedBeforeSwap(user, key, params, bytes(""));
    }

    function testAfterSwapHandlesMaxDeltaWithoutOverflow() public {
        PoolKey memory key = _poolKey(address(token), address(usdc));
        hook.exposedAfterInitialize(key, 0, 0);

        vm.roll(block.number + 20);
        vm.warp(block.timestamp + 2 hours);

        SwapParams memory buying = SwapParams({zeroForOne: false, amountSpecified: -10 ether, sqrtPriceLimitX96: 0});
        (, int128 fee) = hook.exposedAfterSwap(user, key, buying, toBalanceDelta(type(int128).max, 0), bytes(""));

        assertEq(fee, int128(type(int128).max / 100));
    }

    function testAfterSwapNonBuyingAndZeroOutputBranches() public {
        PoolKey memory key = _poolKey(address(token), address(usdc));
        hook.exposedAfterInitialize(key, 0, 0);

        SwapParams memory notBuying = SwapParams({zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: 0});
        (, int128 fee0) = hook.exposedAfterSwap(user, key, notBuying, toBalanceDelta(0, 10 ether), bytes(""));
        assertEq(fee0, 0);

        SwapParams memory buying = SwapParams({zeroForOne: false, amountSpecified: -10 ether, sqrtPriceLimitX96: 0});
        (, int128 fee1) = hook.exposedAfterSwap(user, key, buying, toBalanceDelta(0, 0), bytes(""));
        assertEq(fee1, 0);
    }

    function testAfterSwapBuyRestrictionsAndCooldown() public {
        PoolKey memory key = _poolKey(address(token), address(usdc));
        hook.exposedAfterInitialize(key, 0, 0);

        SwapParams memory buying = SwapParams({zeroForOne: false, amountSpecified: -10 ether, sqrtPriceLimitX96: 0});
        router.setMsgSender(user);

        vm.expectRevert(FundraisingTokenHook.BlockToHoldNotPassed.selector);
        hook.exposedAfterSwap(address(router), key, buying, toBalanceDelta(5 ether, 0), bytes(""));

        vm.roll(block.number + 20);
        vm.expectRevert(FundraisingTokenHook.AmountGreaterThanMaxBuyAmount.selector);
        hook.exposedAfterSwap(address(router), key, buying, toBalanceDelta(4_000 ether, 0), bytes(""));

        (, int128 fee) = hook.exposedAfterSwap(address(router), key, buying, toBalanceDelta(100 ether, 0), bytes(""));
        assertEq(fee, int128(int256(1 ether)));
        assertEq(hook.lastBuyTimestamp(address(token), user), block.timestamp);

        vm.expectRevert(FundraisingTokenHook.CoolDownPeriodNotPassed.selector);
        hook.exposedAfterSwap(address(router), key, buying, toBalanceDelta(100 ether, 0), bytes(""));
    }

    function testAfterSwapNoTaxWhenSenderIsExemptOrThresholdReached() public {
        PoolKey memory key = _poolKey(address(token), address(usdc));
        hook.exposedAfterInitialize(key, 0, 0);

        vm.roll(block.number + 20);
        vm.warp(block.timestamp + 2 hours);

        SwapParams memory buying = SwapParams({zeroForOne: false, amountSpecified: -10 ether, sqrtPriceLimitX96: 0});
        router.setMsgSender(vault);

        (, int128 feeFromVaultSender) =
            hook.exposedAfterSwap(address(router), key, buying, toBalanceDelta(100 ether, 0), bytes(""));
        assertEq(feeFromVaultSender, 0);

        token.mint(vault, 500_000 ether);
        router.setMsgSender(user);
        (, int128 feeWhenThresholdReached) =
            hook.exposedAfterSwap(address(router), key, buying, toBalanceDelta(100 ether, 0), bytes(""));
        assertEq(feeWhenThresholdReached, 0);
    }

    function testTreasuryPercentTaxFlagAndMsgSenderBranches() public {
        PoolKey memory key = _poolKey(address(token), address(usdc));
        assertEq(hook.exposedTreasuryBalancePercent(key), 0);
        assertTrue(hook.exposedCheckIfTaxIncurred(key, user));
        assertFalse(hook.exposedCheckIfTaxIncurred(key, vault));

        router.setMsgSender(user);
        quoter.setMsgSender(vault);
        assertEq(hook.exposedGetMsgSender(address(router)), user);
        assertEq(hook.exposedGetMsgSender(address(quoter)), vault);

        vm.startPrank(address(0xDEAD), address(0xDEAD));
        assertEq(hook.exposedGetMsgSender(address(0x1234)), address(0xDEAD));
        vm.stopPrank();
    }

    function testTreasuryPercentReturnsZeroWhenTotalSupplyIsZero() public {
        ZeroSupplyHookToken zeroSupplyToken = new ZeroSupplyHookToken();
        factory.setProtocol(
            IFactory.FundraisingProtocol({
                fundraisingToken: address(zeroSupplyToken),
                underlyingAddress: address(usdc),
                vault: vault,
                hook: address(0),
                isLPCreated: true
            })
        );
        FundraisingTokenHookHarness zeroSupplyHook =
            new FundraisingTokenHookHarness(address(poolManager), address(factory), address(usdc), address(registry));

        assertEq(zeroSupplyHook.exposedTreasuryBalancePercent(_poolKey(address(zeroSupplyToken), address(usdc))), 0);
    }

    function _poolKey(address currency0, address currency1) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: 0,
            tickSpacing: TickMath.MAX_TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }
}
