// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title FundraisingToken
 * @notice ERC20 issued for a fundraising protocol.
 * @dev The constructor mints 75% of supply to the factory for initial liquidity and 25% to the protocol vault.
 * The token has no privileged mint, burn, pause, or admin mutation after deployment.
 */
contract FundraisingToken is ERC20 {
    /**
     * Errors
     */
    error ZeroAddress();
    error ZeroAmount();
    error OnlyTreasury();
    error SameAddress();

    address public immutable factoryAddress; // Factory that receives the LP-side token allocation.
    address public immutable vault; // Vault that receives the protocol-side token allocation.
    uint8 _decimals;

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
     * @param _amount The amount to validate.
     */
    modifier nonZeroAmount(uint256 _amount) {
        if (_amount == 0) revert ZeroAmount();
        _;
    }

    /**
     * @notice Deploys a fundraising token and mints the initial supply.
     * @param name Token name.
     * @param symbol Token symbol.
     * @param decimals_ Number of decimals the token uses.
     * @param _factoryAddress Factory address that receives 75% of supply for pool creation.
     * @param _vault Vault address that receives 25% of supply for scheduled fundraising execution.
     * @param _totalSupply Total token supply to mint at deployment.
     * @dev Reverts if either recipient is zero, both recipients are equal, or total supply is zero.
     */
    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals_,
        address _factoryAddress,
        address _vault,
        uint256 _totalSupply
    ) ERC20(name, symbol) nonZeroAddress(_factoryAddress) nonZeroAddress(_vault) nonZeroAmount(_totalSupply) {
        if (_factoryAddress == _vault) revert SameAddress();
        factoryAddress = _factoryAddress;
        vault = _vault;
        _decimals = decimals_;

        // mint 75% to LP manager 100% = 1e18
        _mint(factoryAddress, (_totalSupply * 75e16) / 1e18);
        // mint 25% to treasury wallet
        _mint(vault, (_totalSupply * 25e16) / 1e18);
    }

    /**
     * @notice Returns the number of decimals used by the token.
     * @return Number of decimals configured at deployment.
     */
    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }
}
