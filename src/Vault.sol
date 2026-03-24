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

contract Vault is Swap {
    using SafeERC20 for IERC20;
    /**
     * Errors
     */
    error EmegerncyIsActive();
    error NotDue();
    error InsufficientBalance();
    error UnsafePrice();
    error TransferFailed();
    error NotFactory();
    error NoBeneficiaries();
    error ZeroSwapAmount();

    address public immutable fundraisingToken; // The address of the fundraising token
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
     * @notice This event is used to log successful transfers to non-profit organizations.
     * @param recipient The address of the non-profit receiving funds.
     * @param amount The amount of funds transferred.
     * @dev Emitted when funds are transferred to a non-profit recipient.
     */
    event FundsTransferredToNonProfit(address recipient, uint256 amount);

    modifier onlyFactory() {
        if (msg.sender != factoryAddress) revert NotFactory();
        _;
    }

    constructor(
        address _fundraisingToken,
        address _underlyingAsset,
        uint256 _intervalSeconds,
        address[] memory _beneficiaries,
        uint256 _swapPercentage,
        address _integrationRegistry,
        address _emergencyManager,
        uint256 _minTokenBalanceToExecute,
        address _factoryAddress
    ) Swap(_integrationRegistry) {
        fundraisingToken = _fundraisingToken;
        underlyingAsset = _underlyingAsset;
        intervalSeconds = _intervalSeconds;
        beneficiaries = _beneficiaries;
        swapPercentage = _swapPercentage;
        emergencyManager = _emergencyManager;
        minTokenBalanceToExecute = _minTokenBalanceToExecute;
        factoryAddress = _factoryAddress;
    }

    function executeMonthlyEvent() external {
        if (IEmergencyManager(emergencyManager).isEmergencyActive()) revert EmegerncyIsActive();
        if (block.timestamp < lastSuccessAt + intervalSeconds) revert NotDue();
        if (IERC20(fundraisingToken).balanceOf(address(this)) < minTokenBalanceToExecute) revert InsufficientBalance();
        if (!shouldAllowSell()) revert UnsafePrice();

        uint256 amountOut = swapFundraisingToken();
        _distributeProceeds(amountOut);
        lastSuccessAt = block.timestamp;
    }

    function isDue() external view returns (bool) {
        if (
            block.timestamp >= lastSuccessAt + intervalSeconds
                && !IEmergencyManager(emergencyManager).isEmergencyActive()
                && IERC20(fundraisingToken).balanceOf(address(this)) >= minTokenBalanceToExecute
        ) return true;
        return false;
    }

    /**
     * @notice Swaps all fundraising tokens held by the contract to underlying currency and transfers the proceeds to the non-profit organization wallet.
     * @dev This function is intended to be called by Chainlink Automation (Keepers).
     *      It determines the correct pool, calculates minimum expected output, performs the swap,
     *      and then transfers the swapped funds (ETH or ERC20) to the owner's address.
     *      Reverts if the token transfer or ETH transfer fails.
     *
     * Emits a {FundsTransferredToNonProfit} event indicating the owner and amount transferred.
     */
    function swapFundraisingToken() internal returns (uint256 amountOut) {
        uint256 tokenBalance = IERC20(fundraisingToken).balanceOf(address(this));
        uint256 amountIn = (tokenBalance * swapPercentage) / 1e18;
        if (amountIn == 0) revert ZeroSwapAmount();

        PoolKey memory key = IFactory(factoryAddress).getPoolKeys(fundraisingToken);

        address currency0 = Currency.unwrap(key.currency0);
        bool isCurrency0FundraisingToken = currency0 == address(fundraisingToken);

        uint256 minAmountOut = getMinAmountOut(key, isCurrency0FundraisingToken, uint128(amountIn), bytes(""));

        amountOut = swapExactInputSingle(key, uint128(amountIn), uint128(minAmountOut), isCurrency0FundraisingToken);
    }

    function shouldAllowSell() public view returns (bool) {
        IHook hook = IHook(hookAddress);
        PoolKey memory key = IFactory(factoryAddress).getPoolKeys(fundraisingToken);

        uint32 interval = oracleObservationInterval;

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = interval;
        secondsAgos[1] = 0;

        (int48[] memory tickCumulatives,) = hook.observe(key, secondsAgos);

        int56 tickDelta = int56(tickCumulatives[1]) - int56(tickCumulatives[0]);

        int24 avgTick = int24(tickDelta / int56(uint56(interval)));

        int24 currentTick = hook.getCurrentTick(key);

        bool fundraisingIsToken0 = Currency.unwrap(key.currency0) == address(fundraisingToken);

        if (fundraisingIsToken0) {
            // FundraisingToken DOWN too much → block
            if (avgTick - currentTick > maxTickDeviation) {
                return false;
            }
        } else {
            // FundraisingToken DOWN too much → block
            if (currentTick - avgTick > maxTickDeviation) {
                return false;
            }
        }

        // UP, SAME, or small dip → allowed
        return true;
    }

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

    function setHookAddress(address _hookAddress) external onlyFactory {
        hookAddress = _hookAddress;
    }
}
