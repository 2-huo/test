// SPDX-License-Identifier: agpl-3.0
pragma solidity ^0.6.8;
pragma experimental ABIEncoderV2;

import {SafeMath} from './SafeMath.sol';
import {IERC20} from './IERC20.sol';
import {VersionedInitializable} from './VersionedInitializable.sol';
import {ILendingPoolAddressesProvider} from './ILendingPoolAddressesProvider.sol';
import {IAToken} from './IAToken.sol';
import {Helpers} from './Helpers.sol';
import {Errors} from './Errors.sol';
import {WadRayMath} from './WadRayMath.sol';
import {PercentageMath} from './PercentageMath.sol';
import {ReserveLogic} from './ReserveLogic.sol';
import {GenericLogic} from './GenericLogic.sol';
import {ValidationLogic} from './ValidationLogic.sol';
import {ReserveConfiguration} from './ReserveConfiguration.sol';
import {UserConfiguration} from './UserConfiguration.sol';
import {IStableDebtToken} from './IStableDebtToken.sol';
import {IVariableDebtToken} from './IVariableDebtToken.sol';
import {DebtTokenBase} from './DebtTokenBase.sol';
import {IFlashLoanReceiver} from './IFlashLoanReceiver.sol';
import {LendingPoolCollateralManager} from './LendingPoolCollateralManager.sol';
import {IPriceOracleGetter} from './IPriceOracleGetter.sol';
import {SafeERC20} from './contracts/SafeERC20.sol';
import {ILendingPool} from './ILendingPool.sol';
import {LendingPoolStorage} from './LendingPoolStorage.sol';
import {IReserveInterestRateStrategy} from './IReserveInterestRateStrategy.sol';

/**
 * @title LendingPool contract
 * @notice Implements the actions of the LendingPool, and exposes accessory methods to fetch the users and reserve data
 * @author Aave
 **/
contract LendingPool is VersionedInitializable, ILendingPool, LendingPoolStorage {
  using SafeMath for uint256;
  using WadRayMath for uint256;
  using PercentageMath for uint256;
  using SafeERC20 for IERC20;

  //main configuration parameters
  uint256 public constant REBALANCE_UP_LIQUIDITY_RATE_THRESHOLD = 4000;
  uint256 public constant REBALANCE_UP_USAGE_RATIO_THRESHOLD = 0.95 * 1e27; //usage ratio of 95%
  uint256 public constant MAX_STABLE_RATE_BORROW_SIZE_PERCENT = 2500;
  uint256 public constant FLASHLOAN_PREMIUM_TOTAL = 9;
  uint256 public constant MAX_NUMBER_RESERVES = 128;
  uint256 public constant LENDINGPOOL_REVISION = 0x2;

  /**
   * @dev only lending pools configurator can use functions affected by this modifier
   **/
  function _onlyLendingPoolConfigurator() internal view {
    require(
      _addressesProvider.getLendingPoolConfigurator() == msg.sender,
      Errors.LP_CALLER_NOT_LENDING_POOL_CONFIGURATOR
    );
  }

  /**
   * @dev Function to make a function callable only when the contract is not paused.
   *
   * Requirements:
   *
   * - The contract must not be paused.
   */
  function _whenNotPaused() internal view {
    require(!_paused, Errors.LP_IS_PAUSED);
  }

  function getRevision() internal override pure returns (uint256) {
    return LENDINGPOOL_REVISION;
  }

  /**
   * @dev this function is invoked by the proxy contract when the LendingPool contract is added to the
   * AddressesProvider.
   * @param provider the address of the LendingPoolAddressesProvider registry
   **/
  function initialize(ILendingPoolAddressesProvider provider) public initializer {
    _addressesProvider = provider;
  }

  /**
   * @dev deposits The underlying asset into the reserve. A corresponding amount of the overlying asset (aTokens)
   * is minted.
   * @param asset the address of the reserve
   * @param amount the amount to be deposited
   * @param referralCode integrators are assigned a referral code and can potentially receive rewards.
   **/
  function deposit(
    address asset,
    uint256 amount,
    address onBehalfOf,
    uint16 referralCode
  ) external override {
    _whenNotPaused();
    ReserveLogic.ReserveData storage reserve = _reserves[asset];

    ValidationLogic.validateDeposit(reserve, amount);

    address aToken = reserve.aTokenAddress;

    reserve.updateState();
    reserve.updateInterestRates(asset, aToken, amount, 0);

    bool isFirstDeposit = IAToken(aToken).mint(onBehalfOf, amount, reserve.liquidityIndex);

    if (isFirstDeposit) {
      _usersConfig[onBehalfOf].setUsingAsCollateral(reserve.id, true);
      emit ReserveUsedAsCollateralEnabled(asset, onBehalfOf);
    }

    //transfer to the aToken contract
    IERC20(asset).safeTransferFrom(msg.sender, aToken, amount);

    emit Deposit(asset, msg.sender, onBehalfOf, amount, referralCode);
  }

  /**
   * @dev withdraws the _reserves of user.
   * @param asset the address of the reserve
   * @param amount the underlying amount to be redeemed
   * @param to address that will receive the underlying
   **/
  function withdraw(
    address asset,
    uint256 amount,
    address to
  ) external override {
    _whenNotPaused();
    ReserveLogic.ReserveData storage reserve = _reserves[asset];

    address aToken = reserve.aTokenAddress;

    uint256 userBalance = IAToken(aToken).balanceOf(msg.sender);

    uint256 amountToWithdraw = amount;

    //if amount is equal to uint(-1), the user wants to redeem everything
    if (amount == type(uint256).max) {
      amountToWithdraw = userBalance;
    }

    ValidationLogic.validateWithdraw(
      asset,
      amountToWithdraw,
      userBalance,
      _reserves,
      _usersConfig[msg.sender],
      _reservesList,
      _reservesCount,
      _addressesProvider.getPriceOracle()
    );

    reserve.updateState();

    reserve.updateInterestRates(asset, aToken, 0, amountToWithdraw);

    if (amountToWithdraw == userBalance) {
      _usersConfig[msg.sender].setUsingAsCollateral(reserve.id, false);
      emit ReserveUsedAsCollateralDisabled(asset, msg.sender);
    }

    IAToken(aToken).burn(msg.sender, to, amountToWithdraw, reserve.liquidityIndex);

    emit Withdraw(asset, msg.sender, to, amountToWithdraw);
  }

  /**
   * @dev Allows users to borrow a specific amount of the reserve currency, provided that the borrower
   * already deposited enough collateral.
   * @param asset the address of the reserve
   * @param amount the amount to be borrowed
   * @param interestRateMode the interest rate mode at which the user wants to borrow. Can be 0 (STABLE) or 1 (VARIABLE)
   * @param referralCode a referral code for integrators
   * @param onBehalfOf address of the user who will receive the debt
   **/
  function borrow(
    address asset,
    uint256 amount,
    uint256 interestRateMode,
    uint16 referralCode,
    address onBehalfOf
  ) external override {
    _whenNotPaused();
    ReserveLogic.ReserveData storage reserve = _reserves[asset];

    _executeBorrow(
      ExecuteBorrowParams(
        asset,
        msg.sender,
        onBehalfOf,
        amount,
        interestRateMode,
        reserve.aTokenAddress,
        referralCode,
        true
      )
    );
  }

  /**
   * @notice repays a borrow on the specific reserve, for the specified amount (or for the whole amount, if uint256(-1) is specified).
   * @dev the target user is defined by onBehalfOf. If there is no repayment on behalf of another account,
   * onBehalfOf must be equal to msg.sender.
   * @param asset the address of the reserve on which the user borrowed
   * @param amount the amount to repay, or uint256(-1) if the user wants to repay everything
   * @param onBehalfOf the address for which msg.sender is repaying.
   **/
  function repay(
    address asset,
    uint256 amount,
    uint256 rateMode,
    address onBehalfOf
  ) external override {
    _whenNotPaused();

    ReserveLogic.ReserveData storage reserve = _reserves[asset];

    (uint256 stableDebt, uint256 variableDebt) = Helpers.getUserCurrentDebt(onBehalfOf, reserve);

    ReserveLogic.InterestRateMode interestRateMode = ReserveLogic.InterestRateMode(rateMode);

    ValidationLogic.validateRepay(
      reserve,
      amount,
      interestRateMode,
      onBehalfOf,
      stableDebt,
      variableDebt
    );

    //default to max amount
    uint256 paybackAmount = interestRateMode == ReserveLogic.InterestRateMode.STABLE
      ? stableDebt
      : variableDebt;

    if (amount < paybackAmount) {
      paybackAmount = amount;
    }

    reserve.updateState();

    //burns an equivalent amount of debt tokens
    if (interestRateMode == ReserveLogic.InterestRateMode.STABLE) {
      IStableDebtToken(reserve.stableDebtTokenAddress).burn(onBehalfOf, paybackAmount);
    } else {
      IVariableDebtToken(reserve.variableDebtTokenAddress).burn(
        onBehalfOf,
        paybackAmount,
        reserve.variableBorrowIndex
      );
    }

    address aToken = reserve.aTokenAddress;
    reserve.updateInterestRates(asset, aToken, paybackAmount, 0);

    if (stableDebt.add(variableDebt).sub(paybackAmount) == 0) {
      _usersConfig[onBehalfOf].setBorrowing(reserve.id, false);
    }

    IERC20(asset).safeTransferFrom(msg.sender, aToken, paybackAmount);

    emit Repay(asset, onBehalfOf, msg.sender, paybackAmount);
  }

  /**
   * @dev borrowers can user this function to swap between stable and variable borrow rate modes.
   * @param asset the address of the reserve on which the user borrowed
   * @param rateMode the rate mode that the user wants to swap
   **/
  function swapBorrowRateMode(address asset, uint256 rateMode) external override {
    _whenNotPaused();
    ReserveLogic.ReserveData storage reserve = _reserves[asset];

    (uint256 stableDebt, uint256 variableDebt) = Helpers.getUserCurrentDebt(msg.sender, reserve);

    ReserveLogic.InterestRateMode interestRateMode = ReserveLogic.InterestRateMode(rateMode);

    ValidationLogic.validateSwapRateMode(
      reserve,
      _usersConfig[msg.sender],
      stableDebt,
      variableDebt,
      interestRateMode
    );

    reserve.updateState();

    if (interestRateMode == ReserveLogic.InterestRateMode.STABLE) {
      //burn stable rate tokens, mint variable rate tokens
      IStableDebtToken(reserve.stableDebtTokenAddress).burn(msg.sender, stableDebt);
      IVariableDebtToken(reserve.variableDebtTokenAddress).mint(
        msg.sender,
        msg.sender,
        stableDebt,
        reserve.variableBorrowIndex
      );
    } else {
      //do the opposite
      IVariableDebtToken(reserve.variableDebtTokenAddress).burn(
        msg.sender,
        variableDebt,
        reserve.variableBorrowIndex
      );
      IStableDebtToken(reserve.stableDebtTokenAddress).mint(
        msg.sender,
        msg.sender,
        variableDebt,
        reserve.currentStableBorrowRate
      );
    }

    reserve.updateInterestRates(asset, reserve.aTokenAddress, 0, 0);

    emit Swap(asset, msg.sender, rateMode);
  }

  /**
   * @dev rebalances the stable interest rate of a user. Users can be rebalanced if the following conditions are satisfied:
   * 1. Usage ratio is above 95%
   * 2. the current deposit APY is below REBALANCE_UP_THRESHOLD * maxVariableBorrowRate, which means that too much has been
   *    borrowed at a stable rate and depositors are not earning enough.
   * @param asset the address of the reserve
   * @param user the address of the user to be rebalanced
   **/
  function rebalanceStableBorrowRate(address asset, address user) external override {
    _whenNotPaused();

    ReserveLogic.ReserveData storage reserve = _reserves[asset];

    IERC20 stableDebtToken = IERC20(reserve.stableDebtTokenAddress);
    IERC20 variableDebtToken = IERC20(reserve.variableDebtTokenAddress);
    address aTokenAddress = reserve.aTokenAddress;

    uint256 stableBorrowBalance = IERC20(stableDebtToken).balanceOf(user);

    //if the usage ratio is below 95%, no rebalances are needed
    uint256 totalBorrows = stableDebtToken
      .totalSupply()
      .add(variableDebtToken.totalSupply())
      .wadToRay();
    uint256 availableLiquidity = IERC20(asset).balanceOf(aTokenAddress).wadToRay();
    uint256 usageRatio = totalBorrows == 0
      ? 0
      : totalBorrows.rayDiv(availableLiquidity.add(totalBorrows));

    //if the liquidity rate is below REBALANCE_UP_THRESHOLD of the max variable APR at 95% usage,
    //then we allow rebalancing of the stable rate positions.

    uint256 currentLiquidityRate = reserve.currentLiquidityRate;
    uint256 maxVariableBorrowRate = IReserveInterestRateStrategy(
      reserve
        .interestRateStrategyAddress
    )
      .getMaxVariableBorrowRate();

    require(
      usageRatio >= REBALANCE_UP_USAGE_RATIO_THRESHOLD &&
        currentLiquidityRate <=
        maxVariableBorrowRate.percentMul(REBALANCE_UP_LIQUIDITY_RATE_THRESHOLD),
      Errors.LP_INTEREST_RATE_REBALANCE_CONDITIONS_NOT_MET
    );

    reserve.updateState();

    IStableDebtToken(address(stableDebtToken)).burn(user, stableBorrowBalance);
    IStableDebtToken(address(stableDebtToken)).mint(
      user,
      user,
      stableBorrowBalance,
      reserve.currentStableBorrowRate
    );

    reserve.updateInterestRates(asset, aTokenAddress, 0, 0);

    emit RebalanceStableBorrowRate(asset, user);
  }

  /**
   * @dev allows depositors to enable or disable a specific deposit as collateral.
   * @param asset the address of the reserve
   * @param useAsCollateral true if the user wants to use the deposit as collateral, false otherwise.
   **/
  function setUserUseReserveAsCollateral(address asset, bool useAsCollateral) external override {
    _whenNotPaused();
    ReserveLogic.ReserveData storage reserve = _reserves[asset];

    ValidationLogic.validateSetUseReserveAsCollateral(
      reserve,
      asset,
      _reserves,
      _usersConfig[msg.sender],
      _reservesList,
      _reservesCount,
      _addressesProvider.getPriceOracle()
    );

    _usersConfig[msg.sender].setUsingAsCollateral(reserve.id, useAsCollateral);

    if (useAsCollateral) {
      emit ReserveUsedAsCollateralEnabled(asset, msg.sender);
    } else {
      emit ReserveUsedAsCollateralDisabled(asset, msg.sender);
    }
  }

  /**
   * @dev users can invoke this function to liquidate an undercollateralized position.
   * @param asset the address of the collateral to liquidated
   * @param asset the address of the principal reserve
   * @param user the address of the borrower
   * @param purchaseAmount the amount of principal that the liquidator wants to repay
   * @param receiveAToken true if the liquidators wants to receive the aTokens, false if
   * he wants to receive the underlying asset directly
   **/
  function liquidationCall(
    address collateral,
    address asset,
    address user,
    uint256 purchaseAmount,
    bool receiveAToken
  ) external override {
    _whenNotPaused();
    address collateralManager = _addressesProvider.getLendingPoolCollateralManager();

    //solium-disable-next-line
    (bool success, bytes memory result) = collateralManager.delegatecall(
      abi.encodeWithSignature(
        'liquidationCall(address,address,address,uint256,bool)',
        collateral,
        asset,
        user,
        purchaseAmount,
        receiveAToken
      )
    );
    require(success, Errors.LP_LIQUIDATION_CALL_FAILED);

    (uint256 returnCode, string memory returnMessage) = abi.decode(result, (uint256, string));

    if (returnCode != 0) {
      //error found
      revert(string(abi.encodePacked(returnMessage)));
    }
  }

  struct FlashLoanLocalVars {
    IFlashLoanReceiver receiver;
    address oracle;
    uint256 i;
    address currentAsset;
    address currentATokenAddress;
    uint256 currentAmount;
    uint256 currentPremium;
    uint256 currentAmountPlusPremium;
    address debtToken;
  }

  /**
   * @dev allows smartcontracts to access the liquidity of the pool within one transaction,
   * as long as the amount taken plus a fee is returned. NOTE There are security concerns for developers of flashloan receiver contracts
   * that must be kept into consideration. For further details please visit https://developers.aave.com
   * @param receiverAddress The address of the contract receiving the funds. The receiver should implement the IFlashLoanReceiver interface.
   * @param assets The addresss of the assets being flashborrowed
   * @param amounts The amounts requested for this flashloan for each asset
   * @param modes Types of the debt to open if the flash loan is not returned. 0 -> Don't open any debt, just revert, 1 -> stable, 2 -> variable
   * @param onBehalfOf If mode is not 0, then the address to take the debt onBehalfOf. The onBehalfOf address must already have approved `msg.sender` to incur the debt on their behalf.
   * @param params Variadic packed params to pass to the receiver as extra information
   * @param referralCode Referral code of the flash loan
   **/
  function flashLoan(
    address receiverAddress,
    address[] calldata assets,
    uint256[] calldata amounts,
    uint256[] calldata modes,
    address onBehalfOf,
    bytes calldata params,
    uint16 referralCode
  ) external override {
    _whenNotPaused();

    FlashLoanLocalVars memory vars;

    ValidationLogic.validateFlashloan(assets, amounts);

    address[] memory aTokenAddresses = new address[](assets.length);
    uint256[] memory premiums = new uint256[](assets.length);

    vars.receiver = IFlashLoanReceiver(receiverAddress);

    for (vars.i = 0; vars.i < assets.length; vars.i++) {
      aTokenAddresses[vars.i] = _reserves[assets[vars.i]].aTokenAddress;

      premiums[vars.i] = amounts[vars.i].mul(FLASHLOAN_PREMIUM_TOTAL).div(10000);

      //transfer funds to the receiver
      IAToken(aTokenAddresses[vars.i]).transferUnderlyingTo(receiverAddress, amounts[vars.i]);
    }

    //execute action of the receiver
    require(
      vars.receiver.executeOperation(assets, amounts, premiums, msg.sender, params),
      Errors.LP_INVALID_FLASH_LOAN_EXECUTOR_RETURN
    );

    for (vars.i = 0; vars.i < assets.length; vars.i++) {
      vars.currentAsset = assets[vars.i];
      vars.currentAmount = amounts[vars.i];
      vars.currentPremium = premiums[vars.i];
      vars.currentATokenAddress = aTokenAddresses[vars.i];
      vars.currentAmountPlusPremium = vars.currentAmount.add(vars.currentPremium);

      if (ReserveLogic.InterestRateMode(modes[vars.i]) == ReserveLogic.InterestRateMode.NONE) {
        _reserves[vars.currentAsset].updateState();
        _reserves[vars.currentAsset].cumulateToLiquidityIndex(
          IERC20(vars.currentATokenAddress).totalSupply(),
          vars.currentPremium
        );
        _reserves[vars.currentAsset].updateInterestRates(
          vars.currentAsset,
          vars.currentATokenAddress,
          vars.currentPremium,
          0
        );

        IERC20(vars.currentAsset).safeTransferFrom(
          receiverAddress,
          vars.currentATokenAddress,
          vars.currentAmountPlusPremium
        );
      } else {
        //if the user didn't choose to return the funds, the system checks if there
        //is enough collateral and eventually open a position
        _executeBorrow(
          ExecuteBorrowParams(
            vars.currentAsset,
            msg.sender,
            onBehalfOf,
            vars.currentAmount,
            modes[vars.i],
            vars.currentATokenAddress,
            referralCode,
            false
          )
        );
      }
      emit FlashLoan(
        receiverAddress,
        msg.sender,
        vars.currentAsset,
        vars.currentAmount,
        vars.currentPremium,
        referralCode
      );
    }
  }

  /**
   * @dev returns the state and configuration of the reserve
   * @param asset the address of the reserve
   * @return the state of the reserve
   **/
  function getReserveData(address asset)
    external
    override
    view
    returns (ReserveLogic.ReserveData memory)
  {
    return _reserves[asset];
  }

  /**
   * @dev returns the user account data across all the reserves
   * @param user the address of the user
   * @return totalCollateralETH the total collateral in ETH of the user
   * @return totalDebtETH the total debt in ETH of the user
   * @return availableBorrowsETH the borrowing power left of the user
   * @return currentLiquidationThreshold the liquidation threshold of the user
   * @return ltv the loan to value of the user
   * @return healthFactor the current health factor of the user
   **/
  function getUserAccountData(address user)
    external
    override
    view
    returns (
      uint256 totalCollateralETH,
      uint256 totalDebtETH,
      uint256 availableBorrowsETH,
      uint256 currentLiquidationThreshold,
      uint256 ltv,
      uint256 healthFactor
    )
  {
    (
      totalCollateralETH,
      totalDebtETH,
      ltv,
      currentLiquidationThreshold,
      healthFactor
    ) = GenericLogic.calculateUserAccountData(
      user,
      _reserves,
      _usersConfig[user],
      _reservesList,
      _reservesCount,
      _addressesProvider.getPriceOracle()
    );

    availableBorrowsETH = GenericLogic.calculateAvailableBorrowsETH(
      totalCollateralETH,
      totalDebtETH,
      ltv
    );
  }

  /**
   * @dev returns the configuration of the reserve
   * @param asset the address of the reserve
   * @return the configuration of the reserve
   **/
  function getConfiguration(address asset)
    external
    override
    view
    returns (ReserveConfiguration.Map memory)
  {
    return _reserves[asset].configuration;
  }

  /**
   * @dev returns the configuration of the user across all the reserves
   * @param user the user
   * @return the configuration of the user
   **/
  function getUserConfiguration(address user)
    external
    override
    view
    returns (UserConfiguration.Map memory)
  {
    return _usersConfig[user];
  }

  /**
   * @dev returns the normalized income per unit of asset
   * @param asset the address of the reserve
   * @return the reserve normalized income
   */
  function getReserveNormalizedIncome(address asset)
    external
    virtual
    override
    view
    returns (uint256)
  {
    return _reserves[asset].getNormalizedIncome();
  }

  /**
   * @dev returns the normalized variable debt per unit of asset
   * @param asset the address of the reserve
   * @return the reserve normalized debt
   */
  function getReserveNormalizedVariableDebt(address asset)
    external
    override
    view
    returns (uint256)
  {
    return _reserves[asset].getNormalizedDebt();
  }

  /**
   * @dev Returns if the LendingPool is paused
   */
  function paused() external override view returns (bool) {
    return _paused;
  }

  /**
   * @dev returns the list of the initialized reserves
   **/
  function getReservesList() external override view returns (address[] memory) {
    address[] memory _activeReserves = new address[](_reservesCount);

    for (uint256 i = 0; i < _reservesCount; i++) {
      _activeReserves[i] = _reservesList[i];
    }
    return _activeReserves;
  }

  /**
   * @dev returns the addresses provider
   **/
  function getAddressesProvider() external override view returns (ILendingPoolAddressesProvider) {
    return _addressesProvider;
  }

  /**
   * @dev validates and finalizes an aToken transfer
   * @param asset the address of the reserve
   * @param from the user from which the aTokens are transferred
   * @param to the user receiving the aTokens
   * @param amount the amount being transferred/redeemed
   * @param balanceFromBefore the balance of the from user before the transfer
   * @param balanceToBefore the balance of the to user before the transfer
   */
  function finalizeTransfer(
    address asset,
    address from,
    address to,
    uint256 amount,
    uint256 balanceFromBefore,
    uint256 balanceToBefore
  ) external override {
    _whenNotPaused();

    require(msg.sender == _reserves[asset].aTokenAddress, Errors.LP_CALLER_MUST_BE_AN_ATOKEN);

    ValidationLogic.validateTransfer(
      from,
      _reserves,
      _usersConfig[from],
      _reservesList,
      _reservesCount,
      _addressesProvider.getPriceOracle()
    );

    uint256 reserveId = _reserves[asset].id;

    if (from != to) {
      if (balanceFromBefore.sub(amount) == 0) {
        UserConfiguration.Map storage fromConfig = _usersConfig[from];
        fromConfig.setUsingAsCollateral(reserveId, false);
        emit ReserveUsedAsCollateralDisabled(asset, from);
      }

      if (balanceToBefore == 0 && amount != 0) {
        UserConfiguration.Map storage toConfig = _usersConfig[to];
        toConfig.setUsingAsCollateral(reserveId, true);
        emit ReserveUsedAsCollateralEnabled(asset, to);
      }
    }
  }

  /**
   * @dev avoids direct transfers of ETH
   **/
  receive() external payable {
    revert();
  }

  /**
   * @dev initializes a reserve
   * @param asset the address of the reserve
   * @param aTokenAddress the address of the overlying aToken contract
   * @param interestRateStrategyAddress the address of the interest rate strategy contract
   **/
  function initReserve(
    address asset,
    address aTokenAddress,
    address stableDebtAddress,
    address variableDebtAddress,
    address interestRateStrategyAddress
  ) external override {
    _onlyLendingPoolConfigurator();
    _reserves[asset].init(
      aTokenAddress,
      stableDebtAddress,
      variableDebtAddress,
      interestRateStrategyAddress
    );
    _addReserveToList(asset);
  }

  /**
   * @dev updates the address of the interest rate strategy contract
   * @param asset the address of the reserve
   * @param rateStrategyAddress the address of the interest rate strategy contract
   **/
  function setReserveInterestRateStrategyAddress(address asset, address rateStrategyAddress)
    external
    override
  {
    _onlyLendingPoolConfigurator();
    _reserves[asset].interestRateStrategyAddress = rateStrategyAddress;
  }

  /**
   * @dev sets the configuration map of the reserve
   * @param asset the address of the reserve
   * @param configuration the configuration map
   **/
  function setConfiguration(address asset, uint256 configuration) external override {
    _onlyLendingPoolConfigurator();
    _reserves[asset].configuration.data = configuration;
  }

  /**
   * @dev Set the _pause state
   * @param val the boolean value to set the current pause state of LendingPool
   */
  function setPause(bool val) external override {
    _onlyLendingPoolConfigurator();

    _paused = val;
    if (_paused) {
      emit Paused();
    } else {
      emit Unpaused();
    }
  }

  // internal functions
  struct ExecuteBorrowParams {
    address asset;
    address user;
    address onBehalfOf;
    uint256 amount;
    uint256 interestRateMode;
    address aTokenAddress;
    uint16 referralCode;
    bool releaseUnderlying;
  }

  /**
   * @dev Internal function to execute a borrowing action, allowing to transfer or not the underlying
   * @param vars Input struct for the borrowing action, in order to avoid STD errors
   **/
  function _executeBorrow(ExecuteBorrowParams memory vars) internal {
    ReserveLogic.ReserveData storage reserve = _reserves[vars.asset];
    UserConfiguration.Map storage userConfig = _usersConfig[vars.onBehalfOf];

    address oracle = _addressesProvider.getPriceOracle();

    uint256 amountInETH = IPriceOracleGetter(oracle).getAssetPrice(vars.asset).mul(vars.amount).div(
      10**reserve.configuration.getDecimals()
    );

    ValidationLogic.validateBorrow(
      vars.asset,
      reserve,
      vars.onBehalfOf,
      vars.amount,
      amountInETH,
      vars.interestRateMode,
      MAX_STABLE_RATE_BORROW_SIZE_PERCENT,
      _reserves,
      userConfig,
      _reservesList,
      _reservesCount,
      oracle
    );

    reserve.updateState();

    //caching the current stable borrow rate
    uint256 currentStableRate = 0;

    bool isFirstBorrowing = false;
    if (
      ReserveLogic.InterestRateMode(vars.interestRateMode) == ReserveLogic.InterestRateMode.STABLE
    ) {
      currentStableRate = reserve.currentStableBorrowRate;

      isFirstBorrowing = IStableDebtToken(reserve.stableDebtTokenAddress).mint(
        vars.user,
        vars.onBehalfOf,
        vars.amount,
        currentStableRate
      );
    } else {
      isFirstBorrowing = IVariableDebtToken(reserve.variableDebtTokenAddress).mint(
        vars.user,
        vars.onBehalfOf,
        vars.amount,
        reserve.variableBorrowIndex
      );
    }

    if (isFirstBorrowing) {
      userConfig.setBorrowing(reserve.id, true);
    }

    reserve.updateInterestRates(
      vars.asset,
      vars.aTokenAddress,
      0,
      vars.releaseUnderlying ? vars.amount : 0
    );

    if (vars.releaseUnderlying) {
      IAToken(vars.aTokenAddress).transferUnderlyingTo(vars.user, vars.amount);
    }

    emit Borrow(
      vars.asset,
      vars.user,
      vars.onBehalfOf,
      vars.amount,
      vars.interestRateMode,
      ReserveLogic.InterestRateMode(vars.interestRateMode) == ReserveLogic.InterestRateMode.STABLE
        ? currentStableRate
        : reserve.currentVariableBorrowRate,
      vars.referralCode
    );
  }

  /**
   * @dev adds a reserve to the array of the _reserves address
   **/
  function _addReserveToList(address asset) internal {
    uint256 reservesCount = _reservesCount;

    require(reservesCount < MAX_NUMBER_RESERVES, Errors.LP_NO_MORE_RESERVES_ALLOWED);

    bool reserveAlreadyAdded = _reserves[asset].id != 0 || _reservesList[0] == asset;

    if (!reserveAlreadyAdded) {
      _reserves[asset].id = uint8(reservesCount);
      _reservesList[reservesCount] = asset;

      _reservesCount++;
    }
  }
}