// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IFactory} from "./interfaces/IFactory.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {VaultV2} from "./VaultV2.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IIntegrationRegistry} from "./interfaces/IIntegrationRegistry.sol";
import {IEmergencyManager} from "./interfaces/IEmergencyManager.sol";
import {Helper} from "./libraries/Helper.sol";
import {FactoryLibrary} from "./libraries/FactoryLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolInitializer_v4} from "@uniswap/v4-periphery/src/interfaces/IPoolInitializer_v4.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Factory is IFactory, Ownable {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20Metadata;
    error ZeroAddress();
    error ZeroAmount();
    error FundraisingVaultNotCreated();
    error PoolAlreadyExists();
    error UnsupportedUnderlyingAsset();
    error OnlySelf();
    error PositionManagerCallFailed();
    error InsufficientFundraisingTokenBalance();
    error HookNotConfigured();

    address public immutable registryAddress;
    address public immutable emergencyManagerAddress;
    address public immutable usdcAddress;
    address public immutable vrfCoordinator;
    bytes32 public immutable vrfKeyHash;
    uint64 public immutable vrfSubscriptionId;
    uint16 public immutable vrfRequestConfirmations;
    uint32 public immutable vrfCallbackGasLimit;
    uint8 public immutable slotsPerWindow;
    uint8 public immutable firstEventStartSlot;
    uint8 public immutable firstEventEndSlot;
    uint8 public immutable secondEventStartSlot;
    uint8 public immutable secondEventEndSlot;

    /**
     * @notice Mapping storing fundraising protocol details by non-profit owner address.
     * @dev Contains fundraising token, wallets, hook, owner, and LP creation state.
     */
    mapping(address => FundraisingProtocol) internal protocols;
    /**
     * @notice Mapping storing Uniswap pool keys by fundraising token address.
     * @dev Used to quickly access pool details for a given fundraising token.
     */
    mapping(address => PoolKey) public poolKeys;
    mapping(address => bytes32) internal pendingHookPoolIds;

    /**
     *  @notice Emitted when a new fundraising vault is created.
     * @dev Contains the fundraising token, treasury wallet, donation wallet, and owner addresses.
     * @param fundraisingToken The address of the fundraising token.
     * @param vault The address of the vault.
     */
    event FundraisingVaultCreated(address fundraisingToken, address vault);

    /**
     *  @notice Emitted when a new liquidity pool is created.
     * @dev Contains the currency addresses and owner.
     * @param currency0 The address of the first currency.
     * @param currency1 The address of the second currency.
     * @param owner The address of the owner.
     */
    event LiquidityPoolCreated(address currency0, address currency1, address owner);
    event PoolCreationFailed(address fundraisingToken, bytes4 reason, IIntegrationRegistry.Endpoint endpoint);

    constructor(
        address _registryAddress,
        address _emergencyManagerAddress,
        address _usdcAddress,
        VaultV2.VrfConfig memory _vrfConfig,
        VaultV2.SlotConfig memory _slotConfig
    ) Ownable(msg.sender) {
        _requireNonZeroAddress(_registryAddress);
        _requireNonZeroAddress(_emergencyManagerAddress);
        _requireNonZeroAddress(_usdcAddress);
        _requireValidVrfConfig(_vrfConfig);
        _requireValidSlotConfig(_slotConfig);

        registryAddress = _registryAddress;
        emergencyManagerAddress = _emergencyManagerAddress;
        usdcAddress = _usdcAddress;
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
    }

    function createFundraisingVault(
        string calldata _tokenName,
        string calldata _tokenSymbol,
        address _underlyingAddress,
        address[] memory _beneficiaries,
        uint256 _intervalSeconds,
        uint256,
        uint256 _minTokenBalanceToExecute,
        uint256 _totalSupply
    ) external onlyOwner {
        if (_underlyingAddress != usdcAddress) revert UnsupportedUnderlyingAsset();

        uint8 _decimals = IERC20Metadata(usdcAddress).decimals();

        address _registryAddress = registryAddress;
        address _emergencyManager = emergencyManagerAddress;
        (address vaultAddress, address fundraisingTokenAddress) = FactoryLibrary.deployFundraisingVault(
            FactoryLibrary.DeployFundraisingVaultParams({
                tokenName: _tokenName,
                tokenSymbol: _tokenSymbol,
                underlyingAddress: _underlyingAddress,
                beneficiaries: _beneficiaries,
                intervalSeconds: _intervalSeconds,
                registryAddress: _registryAddress,
                emergencyManager: _emergencyManager,
                minTokenBalanceToExecute: _minTokenBalanceToExecute,
                factory: address(this),
                vrfCoordinator: vrfCoordinator,
                vrfKeyHash: vrfKeyHash,
                vrfSubscriptionId: vrfSubscriptionId,
                vrfRequestConfirmations: vrfRequestConfirmations,
                vrfCallbackGasLimit: vrfCallbackGasLimit,
                slotsPerWindow: slotsPerWindow,
                firstEventStartSlot: firstEventStartSlot,
                firstEventEndSlot: firstEventEndSlot,
                secondEventStartSlot: secondEventStartSlot,
                secondEventEndSlot: secondEventEndSlot,
                totalSupply: _totalSupply,
                decimals: _decimals
            })
        );
        IEmergencyManager(_emergencyManager).setReporter(vaultAddress, true);

        protocols[fundraisingTokenAddress] = FundraisingProtocol({
            fundraisingToken: fundraisingTokenAddress,
            underlyingAddress: _underlyingAddress,
            vault: vaultAddress,
            hook: address(0),
            isLPCreated: false
        });

        emit FundraisingVaultCreated(fundraisingTokenAddress, vaultAddress);
    }

    /**
     * @notice Creates a Uniswap V4 liquidity pool for a fundraising token and an underlying asset.
     * @dev Only callable by the factory contract owner.
     *      - Handles ERC20 or native asset transfers, pool initialization, liquidity provisioning,
     *        and deployment of a custom hook for swap-based donation processing.
     *      - Requires that the fundraising protocol is already registered for `_owner`.
     *      - Reverts if the fundraising vault or treasury wallet is missing,
     *        or if a liquidity pool for the owner has already been created.
     *      - The `_sqrtPriceX96` value is derived using Uniswap's Q96 price encoding formula
     *        via `encodeSqrtPriceX96(amount1, amount0)`.
     *
     * @param _fundraisingToken The fundraising token address used as the protocol key.
     * @param _amount0 The liquidity amount for token0 (can be native ETH if `address(0)` is underlying).
     * @param _amount1 The liquidity amount for token1 (fundraising token).
     * @custom:security Caller must ensure:
     *                  - ERC20 approvals are granted to this contract for both tokens.
     *                  - Sufficient balances are available.
     *                  - A valid shared hook has already been deployed and registered in IntegrationRegistry.
     *
     * @custom:effects
     *      - Transfers liquidity assets into the contract.
     *      - Initializes the pool and mints initial liquidity.
     *      - Marks protocol as LP-created and stores hook and pool metadata.
     *
     * @custom:event Emits {LiquidityPoolCreated} with underlying token, fundraising token, and owner.
     */

    function createPool(address _fundraisingToken, uint256 _amount0, uint256 _amount1) external onlyOwner {
        _requireNonZeroAddress(_fundraisingToken);
        _requireNonZeroAmount(_amount0);
        _requireNonZeroAmount(_amount1);

        IIntegrationRegistry registry = IIntegrationRegistry(registryAddress);
        address positionManager = registry.positionManager();
        address permit2 = registry.permit2();
        address hookAddress = registry.hookAddress();

        bytes[] memory params = new bytes[](2);

        FundraisingProtocol storage _protocol = protocols[_fundraisingToken];
        if (_protocol.fundraisingToken == address(0) || _protocol.vault == address(0)) {
            revert FundraisingVaultNotCreated();
        }
        if (_protocol.isLPCreated) revert PoolAlreadyExists();
        if (_protocol.underlyingAddress != usdcAddress) revert UnsupportedUnderlyingAsset();
        if (hookAddress == address(0)) revert HookNotConfigured();

        address _currency0 = _protocol.underlyingAddress;
        address _currency1 = _protocol.fundraisingToken;
        uint256 amount0 = _amount0;
        uint256 amount1 = _amount1;

        if (IERC20Metadata(_currency1).balanceOf(address(this)) < amount1) {
            revert InsufficientFundraisingTokenBalance();
        }

        IERC20Metadata(_protocol.underlyingAddress).safeTransferFrom(msg.sender, address(this), _amount0);

        if (_currency0 > _currency1) {
            (_currency0, _currency1) = (_currency1, _currency0);
            (amount0, amount1) = (amount1, amount0);
        }

        uint160 _startingPrice = Helper.encodeSqrtPriceX96(amount1, amount0);

        // wrap currencies
        Currency currency0 = Currency.wrap(_currency0);
        Currency currency1 = Currency.wrap(_currency1);

        PoolKey memory pool = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 0,
            tickSpacing: TickMath.MAX_TICK_SPACING,
            hooks: IHooks(hookAddress)
        });

        pendingHookPoolIds[_protocol.fundraisingToken] = PoolId.unwrap(pool.toId());

        params[0] = abi.encodeWithSelector(IPoolInitializer_v4.initializePool.selector, pool, _startingPrice);
        params[1] = getModifyLiqiuidityParams(pool, amount0, amount1, _startingPrice);

        uint256 deadline = block.timestamp + 1000;

        IERC20Metadata(_currency0).approve(address(permit2), amount0);
        try IPermit2(permit2).approve(_currency0, positionManager, uint160(amount0), uint48(deadline)) {}
        catch {
            _handlePoolCreationFailure(
                _protocol.fundraisingToken,
                _protocol.underlyingAddress,
                _amount0,
                PositionManagerCallFailed.selector,
                IIntegrationRegistry.Endpoint.PERMIT2
            );
            return;
        }
        IERC20Metadata(_currency1).approve(address(permit2), amount1);
        try IPermit2(permit2).approve(_currency1, positionManager, uint160(amount1), uint48(deadline)) {}
        catch {
            _handlePoolCreationFailure(
                _protocol.fundraisingToken,
                _protocol.underlyingAddress,
                _amount0,
                PositionManagerCallFailed.selector,
                IIntegrationRegistry.Endpoint.PERMIT2
            );
            return;
        }

        try this.positionManagerMulticall(positionManager, params) {}
        catch {
            _handlePoolCreationFailure(
                _protocol.fundraisingToken,
                _protocol.underlyingAddress,
                _amount0,
                PositionManagerCallFailed.selector,
                IIntegrationRegistry.Endpoint.POSITION_MANAGER
            );
            return;
        }

        _protocol.isLPCreated = true;
        _protocol.hook = hookAddress;
        poolKeys[_protocol.fundraisingToken] = pool;
        delete pendingHookPoolIds[_protocol.fundraisingToken];
        VaultV2(_protocol.vault).setHookAddress(hookAddress);

        emit LiquidityPoolCreated(_protocol.underlyingAddress, _protocol.fundraisingToken, _fundraisingToken);
    }

    function getProtocol(address _owner) external view returns (FundraisingProtocol memory) {
        return protocols[_owner];
    }

    function getPoolKeys(address _fundraisingTokenAddress) external view returns (PoolKey memory) {
        return poolKeys[_fundraisingTokenAddress];
    }

    function isAuthorizedHookPool(address fundraisingToken, PoolKey calldata key, address hookAddress)
        external
        view
        returns (bool)
    {
        bytes32 poolId = PoolId.unwrap(key.toId());
        if (pendingHookPoolIds[fundraisingToken] == poolId) {
            return address(key.hooks) == hookAddress;
        }

        FundraisingProtocol memory protocol = protocols[fundraisingToken];
        if (!protocol.isLPCreated || protocol.hook != hookAddress) {
            return false;
        }

        PoolKey memory storedPool = poolKeys[fundraisingToken];
        return PoolId.unwrap(storedPool.toId()) == poolId && address(storedPool.hooks) == hookAddress;
    }

    /**
     * @notice Generates the parameters for adding initial liquidity to a Uniswap V4 pool.
     * @dev Prepares the actions and parameters required for the IPositionManager.modifyLiquidities call.
     * @param key The PoolKey struct representing the pool.
     * @param _amount0 The amount of currency0 to add as liquidity.
     * @param _amount1 The amount of currency1 to add as liquidity.
     * @param _startingPrice The initial sqrtPriceX96 for the pool.
     * @return Encoded bytes for the modifyLiquidities multicall.
     * @custom:netspec Returns encoded parameters for IPositionManager.modifyLiquidities to add initial liquidity to the pool.
     */
    function getModifyLiqiuidityParams(PoolKey memory key, uint256 _amount0, uint256 _amount1, uint160 _startingPrice)
        internal
        view
        returns (bytes memory)
    {
        return FactoryLibrary.getModifyLiqiuidityParams(key, _amount0, _amount1, _startingPrice);
    }

    function positionManagerMulticall(address positionManager, bytes[] calldata params) external {
        if (msg.sender != address(this)) revert OnlySelf();
        IPositionManager(positionManager).multicall(params);
    }

    function _requireNonZeroAddress(address target) internal pure {
        FactoryLibrary.requireNonZeroAddress(target);
    }

    function _requireNonZeroAmount(uint256 amount) internal pure {
        FactoryLibrary.requireNonZeroAmount(amount);
    }

    function _requireValidVrfConfig(VaultV2.VrfConfig memory vrfConfig) internal pure {
        try FactoryLibrary.requireValidVrfConfig(vrfConfig) {}
        catch (bytes memory reason) {
            if (bytes4(reason) == FactoryLibrary.InvalidVrfConfig.selector) revert VaultV2.InvalidVrfConfig();
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }
    }

    function _requireValidSlotConfig(VaultV2.SlotConfig memory slotConfig) internal pure {
        if (slotConfig.slotsPerWindow == 0) revert VaultV2.InvalidSlotConfig();
        if (30 days % slotConfig.slotsPerWindow != 0) revert VaultV2.InvalidSlotConfig();
        if (slotConfig.firstEventStartSlot > slotConfig.firstEventEndSlot) revert VaultV2.InvalidSlotConfig();
        if (slotConfig.secondEventStartSlot > slotConfig.secondEventEndSlot) revert VaultV2.InvalidSlotConfig();
        if (slotConfig.firstEventEndSlot >= slotConfig.secondEventStartSlot) revert VaultV2.InvalidSlotConfig();
        if (slotConfig.secondEventEndSlot >= slotConfig.slotsPerWindow) revert VaultV2.InvalidSlotConfig();
    }

    function _tryRecordEndpointFailure(IIntegrationRegistry.Endpoint endpoint) internal {
        try IEmergencyManager(emergencyManagerAddress).recordEndpointFailure(uint8(endpoint)) {} catch {}
    }

    function _handlePoolCreationFailure(
        address fundraisingToken,
        address underlying,
        uint256 refundAmount,
        bytes4 reason,
        IIntegrationRegistry.Endpoint endpoint
    ) internal {
        _tryRecordEndpointFailure(endpoint);
        delete pendingHookPoolIds[fundraisingToken];
        if (refundAmount != 0) {
            IERC20Metadata(underlying).safeTransfer(msg.sender, refundAmount);
        }
        emit PoolCreationFailed(fundraisingToken, reason, endpoint);
    }
}
