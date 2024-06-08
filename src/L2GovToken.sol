// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC20VotesPartialDelegationUpgradeable} from "src/ERC20VotesPartialDelegationUpgradeable.sol";

/**
 * @title L2GovToken
 * @notice An upgradeable L2 token contract supporting partial delegation via ERC20VotesPartialDelegationUpgradeable.
 */
contract L2GovToken is UUPSUpgradeable, AccessControlUpgradeable, ERC20VotesPartialDelegationUpgradeable {
  bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
  bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /**
   * @notice Initializes the contract with the provided admin. Should be called during deployment.
   * @param _admin The admin address.
   * @dev Reverts if the provided admin address is zero.
   */
  function initialize(address _admin) public initializer {
    __ERC20_init("L2 Governance Token", "gL2");
    __EIP712_init("L2 Governance Token", "1");
    __ERC20Permit_init("L2 Governance Token");
    __AccessControl_init();
    if (_admin == address(0)) {
      revert InvalidAddressZero();
    }
    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
  }

  /**
   * @notice Mints `_amount` of tokens to `_account`.
   * @param _account The account to mint tokens to.
   * @param _amount The amount of tokens to mint.
   * @dev Reverts if the caller does not have the MINTER_ROLE.
   */
  function mint(address _account, uint256 _amount) public onlyRole(MINTER_ROLE) {
    _mint(_account, _amount);
  }

  /**
   * @notice Burns `_value` of tokens from `_account`.
   * @param _account The account to burn tokens from.
   * @param _value The amount of tokens to burn.
   * @dev Reverts if the caller does not have the BURNER_ROLE.
   */
  function burn(address _account, uint256 _value) public onlyRole(BURNER_ROLE) {
    _burn(_account, _value);
  }

  /**
   * @dev Limit UUPS upgrade to DEFAULT_ADMIN_ROLE.
   */
  function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
