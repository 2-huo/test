// SPDX-License-Identifier: agpl-3.0
pragma solidity ^0.6.8;
pragma experimental ABIEncoderV2;

import {StableDebtToken} from './StableDebtToken.sol';
import {VariableDebtToken} from './VariableDebtToken.sol';
import {LendingRateOracle} from './LendingRateOracle.sol';
import {Ownable} from './Ownable.sol';
import {StringLib} from './StringLib.sol';

contract StableAndVariableTokensHelper is Ownable {
  address payable private pool;
  address private addressesProvider;
  event deployedContracts(address stableToken, address variableToken);

  constructor(address payable _pool, address _addressesProvider) public {
    pool = _pool;
    addressesProvider = _addressesProvider;
  }

  function initDeployment(
    address[] calldata tokens,
    string[] calldata symbols,
    address incentivesController
  ) external onlyOwner {
    require(tokens.length == symbols.length, 'Arrays not same length');
    require(pool != address(0), 'Pool can not be zero address');
    for (uint256 i = 0; i < tokens.length; i++) {
      emit deployedContracts(
        address(
          new StableDebtToken(
            pool,
            tokens[i],
            StringLib.concat('Aave stable debt bearing ', symbols[i]),
            StringLib.concat('stableDebt', symbols[i]),
            incentivesController
          )
        ),
        address(
          new VariableDebtToken(
            pool,
            tokens[i],
            StringLib.concat('Aave variable debt bearing ', symbols[i]),
            StringLib.concat('variableDebt', symbols[i]),
            incentivesController
          )
        )
      );
    }
  }

  function setOracleBorrowRates(
    address[] calldata assets,
    uint256[] calldata rates,
    address oracle
  ) external onlyOwner {
    require(assets.length == rates.length, 'Arrays not same length');

    for (uint256 i = 0; i < assets.length; i++) {
      // LendingRateOracle owner must be this contract
      LendingRateOracle(oracle).setMarketBorrowRate(assets[i], rates[i]);
    }
  }

  function setOracleOwnership(address oracle, address admin) external onlyOwner {
    require(admin != address(0), 'owner can not be zero');
    require(LendingRateOracle(oracle).owner() == address(this), 'helper is not owner');
    LendingRateOracle(oracle).transferOwnership(admin);
  }
}