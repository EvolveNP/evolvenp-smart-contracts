// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IFactory} from "./interfaces/IFactory.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {FundraisingToken} from "./FundraisingToken.sol";
import {Vault} from "./Vault.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IIntegrationRegistry} from "./interfaces/IIntegrationRegistry.sol";
import {IEmergencyManager} from "./interfaces/IEmergencyManager.sol";
import {Helper} from "./libraries/Helper.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolInitializer_v4} from "@uniswap/v4-periphery/src/interfaces/IPoolInitializer_v4.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title Factory
 * @notice Creates USDC-backed fundraising vaults and their canonical Uniswap v4 pools.
 * @dev Protocol records are keyed by fundraising token address. The factory deploys each vault/token pair,
 * registers the vault as an emergency reporter, holds the LP-side token allocation, and later initializes
 * the single authorized fundraising-token/USDC pool using the global hook stored in IntegrationRegistry.
 */
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

    /// @notice Fundraising protocol metadata keyed by fundraising token address.
    mapping(address => FundraisingProtocol) internal protocols;

    /// @notice Canonical Uniswap v4 pool key keyed by fundraising token address.
    mapping(address => PoolKey) public poolKeys;

    /// @notice Temporary pool id authorization used only during factory-driven pool initialization.
    mapping(address => bytes32) internal pendingHookPoolIds;

    /**
     * @notice Emitted when a fundraising token and vault are deployed.
     * @param fundraisingToken The address of the fundraising token.
     * @param vault The address of the vault for that fundraising token.
     */
    event FundraisingVaultCreated(address fundraisingToken, address vault);

    /**
     * @notice Emitted when a fundraising-token/USDC pool is successfully initialized and funded.
     * @param currency0 The first currency in the sorted pool key.
     * @param currency1 The second currency in the sorted pool key.
     * @param owner The fundraising token used as the protocol key.
     */
    event LiquidityPoolCreated(address currency0, address currency1, address owner);

    /**
     * @notice Emitted when pool creation fails after assets have been pulled in.
     * @param fundraisingToken The fundraising token whose pool creation failed.
     * @param reason Selector describing the failed internal operation.
     * @param endpoint Integration endpoint attributed to the failure.
     */
    event PoolCreationFailed(address fundraisingToken, bytes4 reason, IIntegrationRegistry.Endpoint endpoint);

    /**
     * @notice Reverts when an address argument is zero.
     * @param _address The address to validate.
     */
    modifier nonZeroAddress(address _address) {
        if (_address == address(0)) revert ZeroAddress();
        _;
    }

    /**
     * @notice Reverts when an amount argument is zero.
     * @param _amount The amount to check for non-zero value.
     */
    modifier nonZeroAmount(uint256 _amount) {
        if (_amount == 0) revert ZeroAmount();
        _;
    }

    /**
     * @notice Restricts an external helper to calls made by this factory itself.
     */
    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelf();
        _;
    }

    /**
     * @notice Deploys the factory.
     * @param _registryAddress IntegrationRegistry used for Uniswap endpoint lookup.
     * @param _emergencyManagerAddress EmergencyManager used for reporter registration and endpoint failure reports.
     * @param _usdcAddress The only supported underlying asset for fundraising pools.
     */
    constructor(address _registryAddress, address _emergencyManagerAddress, address _usdcAddress)
        Ownable(msg.sender)
        nonZeroAddress(_registryAddress)
        nonZeroAddress(_emergencyManagerAddress)
        nonZeroAddress(_usdcAddress)
    {
        registryAddress = _registryAddress;
        emergencyManagerAddress = _emergencyManagerAddress;
        usdcAddress = _usdcAddress;
    }

    /**
     * @notice Creates a fundraising vault and ERC20 fundraising token backed by USDC.
     * @param _tokenName Name for the fundraising token.
     * @param _tokenSymbol Symbol for the fundraising token.
     * @param _underlyingAddress Must equal the factory's configured USDC address.
     * @param _beneficiaries Addresses that receive monthly USDC proceeds from the vault.
     * @param _intervalSeconds Minimum delay between successful vault executions.
     * @param _swapPercentage Percentage of vault-held fundraising tokens to sell per execution, scaled by 1e18.
     * @param _minTokenBalanceToExecute Minimum fundraising token balance required before execution.
     * @param _totalSupply Whole-token supply before applying the USDC decimals.
     * @dev The vault validates beneficiary inputs. The factory receives 75% of token supply for LP creation,
     * and the vault receives 25%. The newly created vault is registered as an emergency reporter.
     */
    function createFundraisingVault(
        string calldata _tokenName,
        string calldata _tokenSymbol,
        address _underlyingAddress,
        address[] memory _beneficiaries,
        uint256 _intervalSeconds,
        uint256 _swapPercentage,
        uint256 _minTokenBalanceToExecute,
        uint256 _totalSupply
    ) external onlyOwner {
        if (_underlyingAddress != usdcAddress) revert UnsupportedUnderlyingAsset();

        uint8 _decimals = IERC20Metadata(usdcAddress).decimals();

        address _registryAddress = registryAddress;
        address _emergencyManager = emergencyManagerAddress;
        Vault vault = new Vault(
            _underlyingAddress,
            _intervalSeconds,
            _beneficiaries,
            _swapPercentage,
            _registryAddress,
            _emergencyManager,
            _minTokenBalanceToExecute,
            address(this)
        );
        IEmergencyManager(_emergencyManager).setReporter(address(vault), true);

        // Deploy fundraising token
        FundraisingToken fundraisingToken = new FundraisingToken(
            _tokenName, _tokenSymbol, _decimals, address(this), address(vault), _totalSupply * 10 ** _decimals
        );

        // set fundraising token addrress in vault
        vault.setFundraisingToken(address(fundraisingToken));

        protocols[address(fundraisingToken)] = FundraisingProtocol({
            fundraisingToken: address(fundraisingToken),
            underlyingAddress: _underlyingAddress,
            vault: address(vault),
            hook: address(0),
            isLPCreated: false
        });

        emit FundraisingVaultCreated(address(fundraisingToken), address(vault));
    }

    /**
     * @notice Creates and funds the canonical Uniswap v4 pool for a fundraising token.
     * @param _fundraisingToken The fundraising token address used as the protocol key.
     * @param _amount0 USDC amount to provide before token sorting.
     * @param _amount1 Fundraising token amount to provide before token sorting.
     * @dev Uses the single global hook stored in IntegrationRegistry. Permit2 or position manager failures are
     * recorded in EmergencyManager, the pulled USDC is refunded, and the protocol remains uncreated.
     */
    function createPool(address _fundraisingToken, uint256 _amount0, uint256 _amount1)
        external
        nonZeroAddress(_fundraisingToken)
        nonZeroAmount(_amount0)
        nonZeroAmount(_amount1)
        onlyOwner
    {
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
        Vault(_protocol.vault).setHookAddress(hookAddress);

        emit LiquidityPoolCreated(_protocol.underlyingAddress, _protocol.fundraisingToken, _fundraisingToken);
    }

    /**
     * @notice Returns the protocol record for a fundraising token.
     * @param _owner Historical parameter name; this value is interpreted as the fundraising token address.
     */
    function getProtocol(address _owner) external view returns (FundraisingProtocol memory) {
        return protocols[_owner];
    }

    /**
     * @notice Returns the canonical pool key for a fundraising token.
     * @param _fundraisingTokenAddress Fundraising token used as the protocol key.
     */
    function getPoolKeys(address _fundraisingTokenAddress) external view returns (PoolKey memory) {
        return poolKeys[_fundraisingTokenAddress];
    }

    /**
     * @notice Returns whether a hook may act for a pool/fundraising-token pair.
     * @param fundraisingToken Fundraising token whose pool is being checked.
     * @param key Pool key supplied by the hook callback.
     * @param hookAddress Hook address supplied by the hook for self-verification.
     * @dev During pool creation, the pending pool id is accepted. After creation, only the stored canonical pool
     * and stored hook are accepted.
     */
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
     * @notice Encodes the PositionManager call data for adding full-range initial liquidity.
     * @param key The PoolKey struct representing the pool.
     * @param _amount0 The amount of currency0 to add as liquidity.
     * @param _amount1 The amount of currency1 to add as liquidity.
     * @param _startingPrice The initial sqrtPriceX96 for the pool.
     * @return Encoded `modifyLiquidities` call for the position manager multicall.
     */
    function getModifyLiqiuidityParams(PoolKey memory key, uint256 _amount0, uint256 _amount1, uint160 _startingPrice)
        internal
        view
        returns (bytes memory)
    {
        bytes memory actions;
        bytes[] memory params;
        actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        params = new bytes[](2);

        int24 maxTickSpacing = TickMath.MAX_TICK_SPACING;

        int24 tickLower = TickMath.minUsableTick(maxTickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(maxTickSpacing);

        uint160 sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceBX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        uint128 _liquidity =
            LiquidityAmounts.getLiquidityForAmounts(_startingPrice, sqrtPriceAX96, sqrtPriceBX96, _amount0, _amount1);

        params[0] = abi.encode(key, tickLower, tickUpper, _liquidity, _amount0, _amount1, 0xdead, bytes(""));

        params[1] = abi.encode(key.currency0, key.currency1);

        uint256 deadline = block.timestamp + 1000;

        return
            abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector, abi.encode(actions, params), deadline);
    }

    /**
     * @notice Calls the Uniswap position manager multicall.
     * @param positionManager Position manager endpoint read from IntegrationRegistry.
     * @param params Multicall payload containing pool initialization and liquidity minting.
     * @dev This function is external so `createPool` can use try/catch while still restricting access to self-calls.
     */
    function positionManagerMulticall(address positionManager, bytes[] calldata params) external onlySelf {
        IPositionManager(positionManager).multicall(params);
    }

    /**
     * @notice Best-effort report of an endpoint failure to EmergencyManager.
     * @param endpoint Integration endpoint associated with the failed pool creation step.
     */
    function _tryRecordEndpointFailure(IIntegrationRegistry.Endpoint endpoint) internal {
        try IEmergencyManager(emergencyManagerAddress).recordEndpointFailure(uint8(endpoint)) {} catch {}
    }

    /**
     * @notice Handles non-reverting pool creation failures.
     * @param fundraisingToken Fundraising token whose pool creation failed.
     * @param underlying USDC token used for refunding pulled liquidity.
     * @param refundAmount USDC amount to refund to the caller.
     * @param reason Selector describing the failure reason.
     * @param endpoint Integration endpoint attributed to the failure.
     */
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
