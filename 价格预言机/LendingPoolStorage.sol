// SPDX-License-Identifier: agpl-3.0
pragma solidity ^0.6.8;

import {UserConfiguration} from './UserConfiguration.sol';
import {ReserveConfiguration} from './ReserveConfiguration.sol';
import {ReserveLogic} from './ReserveLogic.sol';
import {ILendingPoolAddressesProvider} from './ILendingPoolAddressesProvider.sol';

contract LendingPoolStorage {
  using ReserveLogic for ReserveLogic.ReserveData;
  using ReserveConfiguration for ReserveConfiguration.Map;
  using UserConfiguration for UserConfiguration.Map;

  ILendingPoolAddressesProvider internal _addressesProvider;

  mapping(address => ReserveLogic.ReserveData) internal _reserves;
  mapping(address => UserConfiguration.Map) internal _usersConfig;

  // the list of the available reserves, structured as a mapping for gas savings reasons
  mapping(uint256 => address) internal _reservesList;

  uint256 internal _reservesCount;

  bool internal _paused;
}