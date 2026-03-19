// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IFactory} from "./interfaces/IFactory.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHookDeployer} from "./interfaces/IHookDeployer.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {FundraisingToken} from "./FundraisingToken.sol";
import {Vault} from "./Vault.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IIntegrationRegistry} from "./interfaces/IIntegrationRegistry.sol";
import {Helper} from "./libraries/Helper.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolInitializer_v4} from "@uniswap/v4-periphery/src/interfaces/IPoolInitializer_v4.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Factory is IFactory, Ownable {
    using SafeERC20 for IERC20Metadata;
    error ZeroAddress();
    error ZeroAmount();
    error VaultAlreadyExists();
    error FundraisingVaultNotCreated();
    error PoolAlreadyExists();
    error InvalidAmount0();

    address public immutable registryAddress;
    address public immutable emergencyManagerAddress;
    IHookDeployer public immutable hookDeployer;

    /**
     * @notice Mapping storing fundraising protocol details by non-profit owner address.
     * @dev Contains fundraising token, wallets, hook, owner, and LP creation state.
     */
    mapping(address => FundraisingProtocol) internal protocols;

    /**
     * @notice Mapping storing Uniswap pool keys by owner.
     * @dev Used to quickly access pool details for a given non-profit owner.
     */
    mapping(address => PoolKey) public poolKeys;

    /**
     *  @notice Emitted when a new fundraising vault is created.
     * @dev Contains the fundraising token, treasury wallet, donation wallet, and owner addresses.
     * @param fundraisingToken The address of the fundraising token.
     * @param treasuryWallet The address of the treasury wallet.
     * @param donationWallet The address of the donation wallet.
     * @param owner The address of the owner.
     */
    event FundraisingVaultCreated(
        address fundraisingToken, address treasuryWallet, address donationWallet, address owner
    );

    /**
     *  @notice Emitted when a new liquidity pool is created.
     * @dev Contains the currency addresses and owner.
     * @param currency0 The address of the first currency.
     * @param currency1 The address of the second currency.
     * @param owner The address of the owner.
     */
    event LiquidityPoolCreated(address currency0, address currency1, address owner);

    /**
     * @notice Ensures that the provided address is not the zero address.
     * @dev Reverts with `ZeroAddress()` if `_address` is the zero address.
     * @param _address The address to validate.
     * @custom:netmod This modifier should be used to prevent zero address assignments in contract logic.
     */
    modifier nonZeroAddress(address _address) {
        if (_address == address(0)) revert ZeroAddress();
        _;
    }

    /**
     * @notice Ensures that the provided amount is not zero.
     * @dev Reverts with ZeroAmount() if `_amount` is zero.
     * @param _amount The amount to check for non-zero value.
     * @custom:netmod Guarantees that the function using this modifier will not execute with a zero amount.
     */
    modifier nonZeroAmount(uint256 _amount) {
        if (_amount == 0) revert ZeroAmount();
        _;
    }

    constructor(address _registryAddress, address _emergencyManagerAddress, address _hookDeployer)
        Ownable(msg.sender)
        nonZeroAddress(_registryAddress)
        nonZeroAddress(_emergencyManagerAddress)
        nonZeroAddress(_hookDeployer)
    {
        registryAddress = _registryAddress;
        emergencyManagerAddress = _emergencyManagerAddress;
        hookDeployer = IHookDeployer(_hookDeployer);
    }

    function createFundraisingVault(
        string calldata _tokenName,
        string calldata _tokenSymbol,
        address _underlyingAddress,
        address _owner,
        address[] memory _beneficiaries
    ) external nonZeroAddress(_owner) onlyOwner {
        if (protocols[_owner].fundraisingToken != address(0)) {
            revert VaultAlreadyExists();
        }
        // deploy donation wallet
        //  DonationWallet donationWallet = DonationWallet(payable(address(new BeaconProxy(donationWalletBeacon, ""))));

        // deploy treasury wallet
        //   TreasuryWallet treasuryWallet = TreasuryWallet(payable(address(new BeaconProxy(treasuryWalletBeacon, ""))));

        uint8 _decimals = 18;
        if (_underlyingAddress != address(0)) {
            // set the decimals of the fundraising token same as underlying token
            _decimals = IERC20Metadata(_underlyingAddress).decimals();
        }

        // Deploy fundraising token
        FundraisingToken fundraisingToken =
            new FundraisingToken(_tokenName, _tokenSymbol, _decimals, owner(), address(20), 1e9 * 10 ** _decimals);

        address _registryAddress = registryAddress;
        address _emergencyManager = emergencyManagerAddress;
        Vault vault = new Vault(
            address(fundraisingToken),
            _underlyingAddress,
            30,
            _beneficiaries,
            20,
            _emergencyManager,
            _registryAddress,
            1000 * 10 ** _decimals, //TODO
            address(this)
        );

        protocols[_owner] = FundraisingProtocol(
            address(fundraisingToken), _underlyingAddress, address(vault), address(30), address(0), _owner, false
        );

        emit FundraisingVaultCreated(address(fundraisingToken), address(30), address(20), _owner);
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
     * @param _owner The address representing the non-profit organization owner.
     * @param _amount0 The liquidity amount for token0 (can be native ETH if `address(0)` is underlying).
     * @param _amount1 The liquidity amount for token1 (fundraising token).
     * @param _salt The deterministic CREATE2 salt for deploying the FundraisingTokenHook,
     *             typically obtained from a `findSalt` helper function.
     *
     * @custom:security Caller must ensure:
     *                  - ERC20 approvals are granted to this contract for both tokens.
     *                  - Sufficient balances are available.
     *                  - The salt is pre-mined for a valid hook deployment address
     *                    compatible with Uniswap V4 hook flag requirements.
     *
     * @custom:effects
     *      - Transfers liquidity assets into the contract.
     *      - Deploys hook using CREATE2 for deterministic pool addressing.
     *      - Initializes the pool and mints initial liquidity.
     *      - Marks protocol as LP-created and stores hook and pool metadata.
     *
     * @custom:event Emits {LiquidityPoolCreated} with underlying token, fundraising token, and owner.
     */

    function createPool(address _owner, uint256 _amount0, uint256 _amount1, bytes32 _salt)
        external
        payable
        nonZeroAddress(_owner)
        nonZeroAmount(_amount0)
        nonZeroAmount(_amount1)
        onlyOwner
    {
        address positionManager = IIntegrationRegistry(registryAddress).positionManager();
        address router = IIntegrationRegistry(registryAddress).router();
        address quoter = IIntegrationRegistry(registryAddress).quoter();
        address stateView = IIntegrationRegistry(registryAddress).stateView();
        address poolManager = IIntegrationRegistry(registryAddress).poolManager();
        address permit2 = IIntegrationRegistry(registryAddress).permit2();
        IPositionManager _positionManager = IPositionManager(positionManager);

        bytes[] memory params = new bytes[](2);

        FundraisingProtocol storage _protocol = protocols[_owner];
        if (_protocol.fundraisingToken == address(0) || _protocol.treasuryWallet == address(0)) {
            revert FundraisingVaultNotCreated();
        }
        if (_protocol.isLPCreated) revert PoolAlreadyExists();

        address _currency0 = _protocol.underlyingAddress;
        address _currency1 = _protocol.fundraisingToken;
        uint256 amount0 = _amount0;
        uint256 amount1 = _amount1;

        if (_currency0 != address(0)) {
            IERC20Metadata(_currency0).safeTransferFrom(msg.sender, address(this), amount0);
        } else {
            if (amount0 != msg.value) revert InvalidAmount0();
        }

        IERC20Metadata(_currency1).safeTransferFrom(msg.sender, address(this), amount1);

        if (_currency0 > _currency1) {
            (_currency0, _currency1) = (_currency1, _currency0);
            (amount0, amount1) = (amount1, amount0);
        }

        uint160 _startingPrice = Helper.encodeSqrtPriceX96(amount1, amount0);

        // wrap currencies
        Currency currency0 = Currency.wrap(_currency0);
        Currency currency1 = Currency.wrap(_currency1);

        // deploy hook
        address hook = hookDeployer.deployHook(
            poolManager,
            _protocol.fundraisingToken,
            _protocol.treasuryWallet,
            _protocol.donationWallet,
            router,
            quoter,
            stateView,
            _salt
        );

        // transfer assets to this contract;

        PoolKey memory pool = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 0,
            tickSpacing: TickMath.MAX_TICK_SPACING,
            hooks: IHooks(hook)
        });

        params[0] = abi.encodeWithSelector(IPoolInitializer_v4.initializePool.selector, pool, _startingPrice);
        params[1] = getModifyLiqiuidityParams(pool, amount0, amount1, _startingPrice);

        uint256 deadline = block.timestamp + 1000;

        // Eth is always currency 0 as it is zero address
        uint256 valueToPass = pool.currency0.isAddressZero() ? amount0 : 0;

        // ether is always currency0
        if (!pool.currency0.isAddressZero()) {
            IERC20Metadata(_currency0).approve(address(permit2), amount0);
            IPermit2(permit2).approve(_currency0, positionManager, uint160(amount0), uint48(deadline));
        }

        IERC20Metadata(_currency1).approve(address(permit2), amount1);
        IPermit2(permit2).approve(_currency1, positionManager, uint160(amount1), uint48(deadline));

        _protocol.isLPCreated = true;
        _protocol.hook = hook;

        // store pool key for easy access
        poolKeys[_owner] = pool;

        _positionManager.multicall{value: valueToPass}(params);

        emit LiquidityPoolCreated(_protocol.underlyingAddress, _protocol.fundraisingToken, _owner);
    }

    function getProtocol(address _owner) external view returns (FundraisingProtocol memory) {
        return protocols[_owner];
    }

    function getPoolKeys(address _owner) external view returns (PoolKey memory) {
        return poolKeys[_owner];
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
        bytes memory actions;
        bytes[] memory params;
        address _currency0 = Currency.unwrap(key.currency0);
        address _currency1 = Currency.unwrap(key.currency1);

        bool isETHPair = ((_currency0 == address(0)) || (_currency1 == address(0)));
        if (!isETHPair) {
            actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
            params = new bytes[](2);
        } else {
            // For ETH liquidity positions
            actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
            params = new bytes[](3);

            params[2] = abi.encode(address(0), owner()); // only for ETH liquidity positions
        }

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
}
