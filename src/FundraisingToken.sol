// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title FundraisingToken
 * @notice ERC20 Fundraising token.
 *         Initial supply is minted to the liquidity pool manager and treasury wallet.
 * @dev Tokens can be burned only by the treasury wallet to reduce supply.
 */
contract FundraisingToken is ERC20 {
    /**
     * Errors
     */
    error ZeroAddress();
    error ZeroAmount();
    error OnlyTreasury();
    error SameAddress();

    /**
     * State Variables
     */
    address public immutable lpManager; // The address of the liquidity pool manager
    address public immutable treasuryAddress; //The address of the treasury wallet
    uint8 _decimals;

    /**
     * @notice Modifier to ensure the address is not zero.
     * @param _address The address to validate.
     */
    modifier nonZeroAddress(address _address) {
        if (_address == address(0)) revert ZeroAddress();
        _;
    }

    /**
     * @notice Modifier to ensure the amount is not zero.
     * @param _amount The amount to validate.
     */
    modifier nonZeroAmount(uint256 _amount) {
        if (_amount == 0) revert ZeroAmount();
        _;
    }

    /**
     * @notice Constructs the FundRaisingToken contract.
     * @param name The name of the token.
     * @param symbol The symbol of the token.
     * @param decimals_ Number of decimals the token uses.
     * @param _lpManager The address of the liquidity pool manager.
     * @param _treasuryAddress The address of the treasury wallet.
     * @param _totalSupply The total supply of tokens to mint initially.
     * @dev Mints 75% of total supply to the liquidity pool manager and 25% to the treasury wallet.
     */
    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals_,
        address _lpManager,
        address _treasuryAddress,
        uint256 _totalSupply
    ) ERC20(name, symbol) nonZeroAddress(_lpManager) nonZeroAddress(_treasuryAddress) nonZeroAmount(_totalSupply) {
        if (_lpManager == _treasuryAddress) revert SameAddress();
        lpManager = _lpManager;
        treasuryAddress = _treasuryAddress;
        _decimals = decimals_;

        // mint 75% to LP manager 100% = 1e18
        _mint(lpManager, (_totalSupply * 75e16) / 1e18);
        // mint 25% to treasury wallet
        _mint(treasuryAddress, (_totalSupply * 25e16) / 1e18);
    }

    /**
     * @notice Returns the number of decimals used by the token.
     * @return The decimals of the token.
     */
    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }
}
