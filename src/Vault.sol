// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IEmergencyManager} from "./interfaces/IEmergencyManager.sol";

contract Vault {
    /**
     * Errors
     */
    error EmegerncyIsActive();
    error NotDue();
    error InsufficientBalance();
    error UnsafePrice();

    address public immutable fundraisingToken; // The address of the fundraising token
    address public immutable underlyingAsset; // The address of the underlying asset
    uint256 public immutable intervalSeconds;
    uint256 public lastSuccessAt; // Timestamp of the last successful operation
    address[] public beneficiaries;
    uint256 public swapPercentage; // The percentage of the swap in 18 decimals (e.g., 500000000000000000 for 50%)
    address public integrationRegistry; // The address of the integration registry contract
    address public emergencyManager; // The address of the emergency manager contract
    uint256 public immutable minTokenBalanceToExecute;

    constructor(
        address _fundraisingToken,
        address _underlyingAsset,
        uint256 _intervalSeconds,
        address[] memory _beneficiaries,
        uint256 _swapPercentage,
        address _integrationRegistry,
        address _emergencyManager,
        uint256 _minTokenBalanceToExecute
    ) {
        fundraisingToken = _fundraisingToken;
        underlyingAsset = _underlyingAsset;
        intervalSeconds = _intervalSeconds;
        beneficiaries = _beneficiaries;
        swapPercentage = _swapPercentage;
        integrationRegistry = _integrationRegistry;
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

    function TWAPCheck() internal pure returns (bool) {
        // This function would contain logic to check the Time-Weighted Average Price (TWAP) of the underlying asset.
        // It would interact with the quoter or state view contract to get price data and determine if the price conditions are favorable for executing the monthly event.
        return true;
    }
}
