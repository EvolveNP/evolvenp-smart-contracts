// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IEmergencyManager} from "./interfaces/IEmergencyManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Swap} from "./abstracts/Swap.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IFactory} from "./interfaces/IFactory.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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

    address public immutable fundraisingToken; // The address of the fundraising token
    address public immutable underlyingAsset; // The address of the underlying asset
    uint256 public immutable intervalSeconds;
    uint256 public lastSuccessAt; // Timestamp of the last successful operation
    address[] public beneficiaries;
    uint256 public swapPercentage; // The percentage of the swap in 18 decimals (e.g., 500000000000000000 for 50%)
    address public emergencyManager; // The address of the emergency manager contract
    uint256 public immutable minTokenBalanceToExecute;
    address public immutable factoryAddress;

    /**
     * @notice This event is used to log successful transfers to non-profit organizations.
     * @param recipient The address of the non-profit receiving funds.
     * @param amount The amount of funds transferred.
     * @dev Emitted when funds are transferred to a non-profit recipient.
     */
    event FundsTransferredToNonProfit(address recipient, uint256 amount);

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
    }

    function executeMonthlyEvent() external {
        if (IEmergencyManager(emergencyManager).isEmergencyActive()) revert EmegerncyIsActive();
        if (block.timestamp < lastSuccessAt + intervalSeconds) revert NotDue();
        if (IERC20(fundraisingToken).balanceOf(address(this)) < minTokenBalanceToExecute) revert InsufficientBalance();
        if (!TWAPCheck()) revert UnsafePrice();
    }

    function isDue() external view returns (bool) {
        if (
            block.timestamp >= lastSuccessAt + intervalSeconds
                && IEmergencyManager(emergencyManager).isEmergencyActive()
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
    function swapFundraisingToken() internal {
        address owner = address(20); //TODO change with split with beneficiries
        uint256 amountIn = IERC20(fundraisingToken).balanceOf(address(this));

        PoolKey memory key = IFactory(factoryAddress).getPoolKeys(owner);

        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        bool isCurrency0FundraisingToken = currency0 == address(fundraisingToken);

        uint256 minAmountOut = getMinAmountOut(key, isCurrency0FundraisingToken, uint128(amountIn), bytes(""));

        uint256 amountOut =
            swapExactInputSingle(key, uint128(amountIn), uint128(minAmountOut), isCurrency0FundraisingToken);

        if (currency0 == address(0)) {
            (bool success,) = owner.call{value: amountOut}("");
            if (!success) revert TransferFailed();
        } else {
            isCurrency0FundraisingToken
                ? IERC20(currency1).safeTransfer(owner, amountOut)
                : IERC20(currency0).safeTransfer(owner, amountOut);
        }
        emit FundsTransferredToNonProfit(owner, amountOut);
    }

    function TWAPCheck() internal pure returns (bool) {
        // This function would contain logic to check the Time-Weighted Average Price (TWAP) of the underlying asset.
        // It would interact with the quoter or state view contract to get price data and determine if the price conditions are favorable for executing the monthly event.
        return true;
    }
}
