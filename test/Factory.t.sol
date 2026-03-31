// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Factory} from "../src/Factory.sol";
import {IFactory} from "../src/interfaces/IFactory.sol";
import {IIntegrationRegistry} from "../src/interfaces/IIntegrationRegistry.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract MockFactoryToken is ERC20 {
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

contract MockFactoryEmergencyManager {
    address public lastReporter;
    bool public lastAllowed;

    function setReporter(address reporter, bool allowed) external {
        lastReporter = reporter;
        lastAllowed = allowed;
    }

    function recordEndpointFailure(uint8) external {}
}

contract MockFactoryHookDeployer {
    address public hookToReturn;
    bool public shouldRevert;
    address public lastFundraisingToken;
    address public lastVault;
    bytes32 public lastSalt;

    function configure(address hook_, bool revert_) external {
        hookToReturn = hook_;
        shouldRevert = revert_;
    }

    function deployHook(address fundraisingToken, address vault, bytes32 salt) external returns (address) {
        lastFundraisingToken = fundraisingToken;
        lastVault = vault;
        lastSalt = salt;
        if (shouldRevert) revert("hook deploy failed");
        return hookToReturn;
    }
}

contract MockFactoryPermit2 {
    address public lastToken;
    address public lastSpender;
    uint160 public lastAmount;
    uint48 public lastExpiration;
    bool public shouldRevert;

    function setShouldRevert(bool revert_) external {
        shouldRevert = revert_;
    }

    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        if (shouldRevert) revert("permit2 failed");
        lastToken = token;
        lastSpender = spender;
        lastAmount = amount;
        lastExpiration = expiration;
    }
}

contract MockFactoryPositionManager {
    bool public shouldRevert;
    bytes[] public lastParams;

    function setShouldRevert(bool revert_) external {
        shouldRevert = revert_;
    }

    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results) {
        if (shouldRevert) revert("multicall failed");
        delete lastParams;
        for (uint256 i; i < data.length; ++i) {
            lastParams.push(data[i]);
        }
        results = new bytes[](data.length);
    }
}

contract MockFactoryRegistry {
    address public router;
    address public permit2;
    address public quoter;
    address public poolManager;
    address public positionManager;
    address public stateView;
    address public hookDeployer;
    address public emergencyManager;

    constructor(address _permit2, address _positionManager, address _hookDeployer) {
        permit2 = _permit2;
        positionManager = _positionManager;
        hookDeployer = _hookDeployer;
    }

    function isAllowedCodehash(uint8, bytes32) external pure returns (bool) {
        return false;
    }
}

contract FactoryHarness is Factory {
    constructor(address registry, address emergencyManager, address usdc) Factory(registry, emergencyManager, usdc) {}

    function exposedGetModifyLiqiuidityParams(
        PoolKey memory key,
        uint256 amount0,
        uint256 amount1,
        uint160 startingPrice
    ) external view returns (bytes memory) {
        return getModifyLiqiuidityParams(key, amount0, amount1, startingPrice);
    }
}

contract FactoryTest is Test {
    FactoryHarness internal factory;
    MockFactoryToken internal usdc;
    MockFactoryEmergencyManager internal emergencyManager;
    MockFactoryHookDeployer internal hookDeployer;
    MockFactoryPermit2 internal permit2;
    MockFactoryPositionManager internal positionManager;
    MockFactoryRegistry internal registry;

    address internal protocolAdmin = address(0xA11CE);
    address internal thirdParty = address(0xB0B);
    address internal fakeHook = address(0x9999);

    function setUp() public {
        vm.prank(protocolAdmin);
        usdc = new MockFactoryToken("USD Coin", "USDC", 6);
        emergencyManager = new MockFactoryEmergencyManager();
        hookDeployer = new MockFactoryHookDeployer();
        permit2 = new MockFactoryPermit2();
        positionManager = new MockFactoryPositionManager();
        registry = new MockFactoryRegistry(address(permit2), address(positionManager), address(hookDeployer));

        vm.prank(protocolAdmin);
        factory = new FactoryHarness(address(registry), address(emergencyManager), address(usdc));
    }

    function testConstructorRejectsZeroAddresses() public {
        vm.expectRevert(Factory.ZeroAddress.selector);
        new FactoryHarness(address(0), address(emergencyManager), address(usdc));
    }

    function testCreateFundraisingVaultOnlyOwner() public {
        vm.prank(thirdParty);
        vm.expectRevert();
        factory.createFundraisingVault(
            "Fund", "FUND", address(usdc), thirdParty, _beneficiaries(), 30 days, 5e17, 1e6, 1000
        );
    }

    function testCreateFundraisingVaultRejectsInvalidInputs() public {
        vm.prank(protocolAdmin);
        vm.expectRevert(Factory.ZeroAddress.selector);
        factory.createFundraisingVault(
            "Fund", "FUND", address(usdc), address(0), _beneficiaries(), 30 days, 5e17, 1e6, 1000
        );

        vm.prank(protocolAdmin);
        vm.expectRevert(Factory.UnsupportedUnderlyingAsset.selector);
        factory.createFundraisingVault(
            "Fund", "FUND", address(0x1234), thirdParty, _beneficiaries(), 30 days, 5e17, 1e6, 1000
        );
    }

    function testCreateFundraisingVaultDeploysVaultAndToken() public {
        vm.recordLogs();
        vm.prank(protocolAdmin);
        factory.createFundraisingVault(
            "Fund", "FUND", address(usdc), thirdParty, _beneficiaries(), 30 days, 5e17, 1e6, 1000
        );

        (address fundraisingToken, address vault) = _decodeCreatedVault();
        assertTrue(fundraisingToken != address(0));
        assertTrue(vault != address(0));
        assertEq(emergencyManager.lastReporter(), vault);
        assertTrue(emergencyManager.lastAllowed());

        IFactory.FundraisingProtocol memory protocol = factory.getProtocol(fundraisingToken);
        assertEq(protocol.fundraisingToken, fundraisingToken);
        assertEq(protocol.underlyingAddress, address(usdc));
        assertEq(protocol.vault, vault);
        assertEq(protocol.hook, address(0));
        assertFalse(protocol.isLPCreated);
    }

    function testCreatePoolRejectsInvalidInputs() public {
        vm.prank(protocolAdmin);
        vm.expectRevert(Factory.ZeroAddress.selector);
        factory.createPool(address(0), 1, 1, bytes32("salt"));

        vm.prank(protocolAdmin);
        vm.expectRevert(Factory.ZeroAmount.selector);
        factory.createPool(address(0x1), 0, 1, bytes32("salt"));

        vm.prank(protocolAdmin);
        vm.expectRevert(Factory.ZeroAmount.selector);
        factory.createPool(address(0x1), 1, 0, bytes32("salt"));
    }

    function testCreatePoolRejectsMissingProtocol() public {
        vm.prank(protocolAdmin);
        vm.expectRevert(Factory.FundraisingVaultNotCreated.selector);
        factory.createPool(address(0x1234), 1, 1, bytes32("salt"));
    }

    function testCreatePoolRejectsUnsupportedUnderlying() public {
        address tokenKey = address(0xCAFE);
        _storeProtocol(tokenKey, address(0xBEEF), address(0xD00D), address(0), false);

        vm.prank(protocolAdmin);
        vm.expectRevert(Factory.UnsupportedUnderlyingAsset.selector);
        factory.createPool(tokenKey, 1, 1, bytes32("salt"));
    }

    function testCreatePoolHappyPathStoresHookAndPoolKey() public {
        vm.recordLogs();
        vm.prank(protocolAdmin);
        factory.createFundraisingVault(
            "Fund", "FUND", address(usdc), thirdParty, _beneficiaries(), 30 days, 5e17, 1e6, 1000
        );

        (address fundraisingToken,) = _decodeCreatedVault();
        hookDeployer.configure(fakeHook, false);

        usdc.mint(protocolAdmin, 1_000_000e6);

        vm.startPrank(protocolAdmin);
        usdc.approve(address(factory), type(uint256).max);
        MockFactoryToken(fundraisingToken).approve(address(factory), type(uint256).max);
        factory.createPool(fundraisingToken, 100e6, 200e6, bytes32("salt"));
        vm.stopPrank();

        IFactory.FundraisingProtocol memory protocol = factory.getProtocol(fundraisingToken);
        assertTrue(protocol.isLPCreated);
        assertEq(protocol.hook, fakeHook);
        assertEq(hookDeployer.lastFundraisingToken(), fundraisingToken);

        PoolKey memory poolKey = factory.getPoolKeys(fundraisingToken);
        address storedCurrency0 = Currency.unwrap(poolKey.currency0);
        address storedCurrency1 = Currency.unwrap(poolKey.currency1);
        assertTrue(
            (storedCurrency0 == address(usdc) && storedCurrency1 == fundraisingToken)
                || (storedCurrency0 == fundraisingToken && storedCurrency1 == address(usdc))
        );
        assertEq(address(poolKey.hooks), fakeHook);
        assertEq(permit2.lastSpender(), address(positionManager));
        bytes memory firstMulticallParam = positionManager.lastParams(0);
        assertGt(firstMulticallParam.length, 0);
    }

    function testCreatePoolRevertsWhenHookDeploymentFails() public {
        vm.recordLogs();
        vm.prank(protocolAdmin);
        factory.createFundraisingVault(
            "Fund", "FUND", address(usdc), thirdParty, _beneficiaries(), 30 days, 5e17, 1e6, 1000
        );
        (address fundraisingToken,) = _decodeCreatedVault();

        hookDeployer.configure(address(0), true);
        usdc.mint(protocolAdmin, 100e6);

        vm.expectCall(
            address(emergencyManager),
            abi.encodeCall(
                MockFactoryEmergencyManager.recordEndpointFailure, (uint8(IIntegrationRegistry.Endpoint.HOOK_DEPLOYER))
            )
        );

        vm.startPrank(protocolAdmin);
        usdc.approve(address(factory), type(uint256).max);
        MockFactoryToken(fundraisingToken).approve(address(factory), type(uint256).max);
        vm.expectRevert(Factory.HookDeploymentFailed.selector);
        factory.createPool(fundraisingToken, 10e6, 20e6, bytes32("salt"));
        vm.stopPrank();
    }

    function testCreatePoolRevertsWhenPermit2Fails() public {
        vm.recordLogs();
        vm.prank(protocolAdmin);
        factory.createFundraisingVault(
            "Fund", "FUND", address(usdc), thirdParty, _beneficiaries(), 30 days, 5e17, 1e6, 1000
        );
        (address fundraisingToken,) = _decodeCreatedVault();

        hookDeployer.configure(fakeHook, false);
        permit2.setShouldRevert(true);
        usdc.mint(protocolAdmin, 100e6);

        vm.expectCall(
            address(emergencyManager),
            abi.encodeCall(
                MockFactoryEmergencyManager.recordEndpointFailure, (uint8(IIntegrationRegistry.Endpoint.PERMIT2))
            )
        );

        vm.startPrank(protocolAdmin);
        usdc.approve(address(factory), type(uint256).max);
        MockFactoryToken(fundraisingToken).approve(address(factory), type(uint256).max);
        vm.expectRevert(Factory.PositionManagerCallFailed.selector);
        factory.createPool(fundraisingToken, 10e6, 20e6, bytes32("salt"));
        vm.stopPrank();
    }

    function testCreatePoolRevertsWhenPositionManagerFails() public {
        vm.recordLogs();
        vm.prank(protocolAdmin);
        factory.createFundraisingVault(
            "Fund", "FUND", address(usdc), thirdParty, _beneficiaries(), 30 days, 5e17, 1e6, 1000
        );
        (address fundraisingToken,) = _decodeCreatedVault();

        hookDeployer.configure(fakeHook, false);
        positionManager.setShouldRevert(true);
        usdc.mint(protocolAdmin, 100e6);

        vm.expectCall(
            address(emergencyManager),
            abi.encodeCall(
                MockFactoryEmergencyManager.recordEndpointFailure,
                (uint8(IIntegrationRegistry.Endpoint.POSITION_MANAGER))
            )
        );

        vm.startPrank(protocolAdmin);
        usdc.approve(address(factory), type(uint256).max);
        MockFactoryToken(fundraisingToken).approve(address(factory), type(uint256).max);
        vm.expectRevert(Factory.PositionManagerCallFailed.selector);
        factory.createPool(fundraisingToken, 10e6, 20e6, bytes32("salt"));
        vm.stopPrank();
    }

    function testCreatePoolRevertsWhenAlreadyCreated() public {
        vm.recordLogs();
        vm.prank(protocolAdmin);
        factory.createFundraisingVault(
            "Fund", "FUND", address(usdc), thirdParty, _beneficiaries(), 30 days, 5e17, 1e6, 1000
        );
        (address fundraisingToken,) = _decodeCreatedVault();

        hookDeployer.configure(fakeHook, false);
        usdc.mint(protocolAdmin, 100e6);

        vm.startPrank(protocolAdmin);
        usdc.approve(address(factory), type(uint256).max);
        MockFactoryToken(fundraisingToken).approve(address(factory), type(uint256).max);
        factory.createPool(fundraisingToken, 10e6, 20e6, bytes32("salt"));
        vm.expectRevert(Factory.PoolAlreadyExists.selector);
        factory.createPool(fundraisingToken, 10e6, 20e6, bytes32("salt"));
        vm.stopPrank();
    }

    function testSelfOnlyEntryPointsRejectExternalCall() public {
        vm.expectRevert(Factory.OnlySelf.selector);
        factory.deployHookFromFactory(address(1), address(2), bytes32("salt"));

        bytes[] memory params = new bytes[](0);
        vm.expectRevert(Factory.OnlySelf.selector);
        factory.positionManagerMulticall(address(positionManager), params);
    }

    function testGetModifyLiquidityParamsReturnsEncodedCall() public view {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(usdc)),
            currency1: Currency.wrap(address(0x1234)),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });

        bytes memory encoded = factory.exposedGetModifyLiqiuidityParams(key, 10e6, 20e6, uint160(1 << 96));
        assertGt(encoded.length, 4);
    }

    function _beneficiaries() internal pure returns (address[] memory beneficiaries) {
        beneficiaries = new address[](2);
        beneficiaries[0] = address(0x1111);
        beneficiaries[1] = address(0x2222);
    }

    function _decodeCreatedVault() internal view returns (address fundraisingToken, address vault) {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 expectedTopic = keccak256("FundraisingVaultCreated(address,address)");
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == expectedTopic) {
                (fundraisingToken, vault) = abi.decode(entries[i].data, (address, address));
                return (fundraisingToken, vault);
            }
        }
        revert("event not found");
    }

    function _storeProtocol(address key, address underlying, address vault, address hook, bool isCreated) internal {
        bytes32 slot = keccak256(abi.encode(key, uint256(1)));
        vm.store(address(factory), slot, bytes32(uint256(uint160(key))));
        vm.store(address(factory), bytes32(uint256(slot) + 1), bytes32(uint256(uint160(underlying))));
        vm.store(address(factory), bytes32(uint256(slot) + 2), bytes32(uint256(uint160(vault))));
        vm.store(address(factory), bytes32(uint256(slot) + 3), bytes32(uint256(uint160(hook))));
        vm.store(address(factory), bytes32(uint256(slot) + 4), bytes32(uint256(isCreated ? 1 : 0)));
    }
}
